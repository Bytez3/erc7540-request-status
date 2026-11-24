import { createPublicClient, fallback, http, type Address, type PublicClient } from "viem";
import { mainnet } from "viem/chains";

import { erc7540Abi, fifoVaultAbi, lensAbi } from "./abi";
import type { ChainDef, QueueDef } from "./deployments";
import { RequestState, Source } from "./format";
import { amountReaders, lidoEstimates } from "./readers";

export interface TrackedRequest {
  queue: QueueDef;
  requestId: bigint;
  controller: Address;
  source: Source;
  ok: boolean;
  state: RequestState;
  queuedAhead: bigint;
  earliest: bigint;
  latest: bigint;
  /** Pending and Claimable amounts, in the queue's unit, when they can be read. */
  pending?: bigint;
  claimable?: bigint;
  /** The protocol's own off-chain estimate, if it publishes one. */
  estimate?: { at: Date; reason: string };
}

export interface LookupResult {
  requests: TrackedRequest[];
  /** Queues that could not be fully checked. Their requests may be missing from `requests`. */
  failed: QueueDef[];
}

export interface QueueOverview {
  outstanding: bigint;
  cycleLength: bigint;
  nextCycleAt: bigint;
  capacity: bigint;
  suspended: boolean;
  impaired: boolean;
}

const LOG_CHUNK = 25_000n; // stays under public-RPC eth_getLogs range limits (ethpandaops allows 30,000)
// Every refresh re-scans this many recent blocks. Load-balanced public RPCs can answer eth_getLogs from a
// node a few blocks behind the one that answered eth_blockNumber; without the overlap those logs are lost.
const RESCAN_BLOCKS = 64n;
const BATCH = 40;

// Concurrent reads are combined into JSON-RPC batches, except on gateways that price a batch as one request:
// Tenderly's public gateway answers HTTP 429 to as few as two eth_getLogs or ten eth_calls in one batch, but
// accepts the same calls sent in parallel.
const RPC_BATCH = { batchSize: 50, wait: 16 };
const NO_BATCH_HOSTS = ["gateway.tenderly.co"];

// One client per chain, so JSON-RPC batching and the log cache are shared across refreshes.
const clients = new Map<string, PublicClient>();

export function clientFor(chain: ChainDef): PublicClient {
  const key = `${chain.key}|${chain.rpcUrl}`;
  const existing = clients.get(key);
  if (existing) return existing;
  const client = createPublicClient({
    chain: {
      id: chain.id,
      name: chain.name,
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: [chain.rpcUrl] } },
      // Mainnet (and a local mainnet fork) needs the ENS Universal Resolver for name lookups.
      contracts: chain.id === mainnet.id ? mainnet.contracts : undefined,
    },
    transport: fallback(
      [chain.rpcUrl, ...(chain.fallbackRpcUrls ?? [])].map((url) =>
        http(url, { retryCount: 2, timeout: 20_000, batch: NO_BATCH_HOSTS.some((h) => url.includes(h)) ? false : RPC_BATCH }),
      ),
    ),
  });
  clients.set(key, client);
  return client;
}

/** Request ids already found per (queue, controller), and the last block scanned for them. */
const logCache = new Map<string, { ids: Set<bigint>; scannedTo: bigint }>();

/** Request ids for `owner` at `q`. `error` is set when the scan could not finish; `ids` then holds what was found. */
async function discover(
  client: PublicClient,
  chain: ChainDef,
  q: QueueDef,
  owner: Address,
): Promise<{ ids: bigint[]; error?: unknown }> {
  switch (q.discovery.kind) {
    case "zero":
      return { ids: [0n] };
    case "lens":
      return {
        ids: [
          ...(await client.readContract({
            address: chain.lens!,
            abi: lensAbi,
            functionName: "requestIdsOf",
            args: [q.address, owner],
          })),
        ],
      };
    case "events": {
      // Scan only blocks not seen before (plus a small overlap) for this queue and wallet; refreshes then cost one
      // small log query. Progress is cached chunk by chunk, so a failed chunk is retried on the next refresh.
      const cacheKey = `${chain.key}|${q.address}|${owner}`;
      const start = q.discovery.fromBlock;
      const cached = logCache.get(cacheKey) ?? { ids: new Set<bigint>(), scannedTo: start - 1n };
      logCache.set(cacheKey, cached);
      const sorted = () => [...cached.ids].sort((a, b) => (a < b ? -1 : 1));
      try {
        const latest = await client.getBlockNumber();
        const resume = cached.scannedTo + 1n - RESCAN_BLOCKS;
        for (let from = resume > start ? resume : start; from <= latest; from += LOG_CHUNK) {
          const to = from + LOG_CHUNK - 1n > latest ? latest : from + LOG_CHUNK - 1n;
          const logs = await client.getContractEvents({
            address: q.address,
            abi: erc7540Abi,
            eventName: "RedeemRequest",
            args: { controller: owner },
            fromBlock: from,
            toBlock: to,
          });
          for (const l of logs) if (l.args.requestId !== undefined) cached.ids.add(l.args.requestId);
          if (to > cached.scannedTo) cached.scannedTo = to;
        }
      } catch (error) {
        return { ids: sorted(), error };
      }
      return { ids: sorted() };
    }
  }
}

/** Every open request `owner` has across the chain's tracked queues, with ERC-XXXX status. */
export async function lookup(chain: ChainDef, owner: Address): Promise<LookupResult> {
  if (!chain.lens) return { requests: [], failed: [] };
  const client = clientFor(chain);

  const perQueue = await Promise.all(
    chain.queues.map(async (q) => ({
      q,
      ...(await discover(client, chain, q, owner).catch((error: unknown) => ({ ids: [] as bigint[], error }))),
    })),
  );
  const failed = perQueue.filter((p) => p.error !== undefined).map((p) => p.q);
  const queries = perQueue.flatMap(({ q, ids }) => ids.map((requestId) => ({ q, requestId })));
  if (queries.length === 0) return { requests: [], failed };

  // Split into lens calls, each no bigger than the smallest `statusBatch` of the queues in it.
  const limit = (x: (typeof queries)[number]) => x.q.statusBatch ?? BATCH;
  const slices: (typeof queries)[] = [];
  let cur: typeof queries = [];
  for (const x of queries) {
    if (cur.length > 0 && cur.length + 1 > Math.min(limit(x), ...cur.map(limit))) {
      slices.push(cur);
      cur = [];
    }
    cur.push(x);
  }
  if (cur.length > 0) slices.push(cur);

  const results: TrackedRequest[] = [];
  for (const slice of slices) {
    const statuses = await client.readContract({
      address: chain.lens,
      abi: lensAbi,
      functionName: "redeemRequestStatusBatch",
      args: [slice.map(({ q, requestId }) => ({ vault: q.address, requestId, controller: owner }))],
    });
    statuses.forEach((s, j) => {
      results.push({
        queue: slice[j].q,
        requestId: slice[j].requestId,
        controller: owner,
        source: s.source as Source,
        ok: s.ok,
        state: s.state as RequestState,
        queuedAhead: s.queuedAhead,
        earliest: s.earliestClaimableAt,
        latest: s.latestClaimableAt,
      });
    });
  }

  const open = results.filter((r) => r.ok && r.state !== RequestState.None);
  await Promise.all(
    open.map(async (r) => {
      const read = amountReaders[r.queue.amounts ?? "erc7540"];
      const amounts = await read(client, r.queue.address, r.requestId, owner).catch(() => undefined);
      if (amounts) Object.assign(r, amounts);
    }),
  );

  const lidoPending = open.filter((r) => r.queue.estimate === "lido" && r.state !== RequestState.Claimable);
  if (lidoPending.length > 0 && chain.id === 1) {
    const est = await lidoEstimates(lidoPending.map((r) => r.requestId)).catch(() => new Map());
    for (const r of lidoPending) r.estimate = est.get(r.requestId);
  }
  return { requests: open, failed };
}

export async function overview(chain: ChainDef, q: QueueDef): Promise<QueueOverview> {
  const client = clientFor(chain);
  const c = { address: q.address, abi: fifoVaultAbi } as const;
  const [queued, processed, cycleLength, nextCycleAt, capacity, suspended, impaired] = await Promise.all([
    client.readContract({ ...c, functionName: "totalQueued" }),
    client.readContract({ ...c, functionName: "totalProcessed" }),
    client.readContract({ ...c, functionName: "cycleLength" }),
    client.readContract({ ...c, functionName: "nextCycleAt" }),
    client.readContract({ ...c, functionName: "capacityPerCycle" }),
    client.readContract({ ...c, functionName: "suspended" }),
    client.readContract({ ...c, functionName: "impaired" }),
  ]);
  return { outstanding: queued - processed, cycleLength, nextCycleAt, capacity, suspended, impaired };
}

export async function delayBounds(chain: ChainDef, q: QueueDef, amount: bigint): Promise<[bigint, bigint]> {
  const client = clientFor(chain);
  const [min, max] = await client.readContract({
    address: q.address,
    abi: fifoVaultAbi,
    functionName: "redeemDelayBounds",
    args: [amount],
  });
  return [min, max];
}

export async function chainNow(chain: ChainDef): Promise<bigint> {
  const block = await clientFor(chain).getBlock();
  return block.timestamp;
}
