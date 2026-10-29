import { createPublicClient, http, type Address, type PublicClient } from "viem";

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

export interface QueueOverview {
  outstanding: bigint;
  cycleLength: bigint;
  nextCycleAt: bigint;
  capacity: bigint;
  suspended: boolean;
  impaired: boolean;
}

const LOG_CHUNK = 45_000n; // stays under common public-RPC eth_getLogs range limits
const BATCH = 40;

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
    },
    // Concurrent reads are sent as one JSON-RPC batch request instead of one HTTP request each.
    transport: http(chain.rpcUrl, { retryCount: 2, timeout: 20_000, batch: { batchSize: 50, wait: 16 } }),
  });
  clients.set(key, client);
  return client;
}

/** Request ids already found per (queue, controller), and the last block scanned for them. */
const logCache = new Map<string, { ids: Set<bigint>; scannedTo: bigint }>();

async function discover(client: PublicClient, chain: ChainDef, q: QueueDef, owner: Address): Promise<bigint[]> {
  switch (q.discovery.kind) {
    case "zero":
      return [0n];
    case "lens":
      return [
        ...(await client.readContract({
          address: chain.lens!,
          abi: lensAbi,
          functionName: "requestIdsOf",
          args: [q.address, owner],
        })),
      ];
    case "events": {
      // Scan only blocks not seen before for this queue and wallet; refreshes then cost one small log query.
      const cacheKey = `${chain.key}|${q.address}|${owner}`;
      const cached = logCache.get(cacheKey) ?? { ids: new Set<bigint>(), scannedTo: q.discovery.fromBlock - 1n };
      const latest = await client.getBlockNumber();
      const ids = cached.ids;
      for (let from = cached.scannedTo + 1n; from <= latest; from += LOG_CHUNK) {
        const to = from + LOG_CHUNK - 1n > latest ? latest : from + LOG_CHUNK - 1n;
        const logs = await client.getContractEvents({
          address: q.address,
          abi: erc7540Abi,
          eventName: "RedeemRequest",
          args: { controller: owner },
          fromBlock: from,
          toBlock: to,
        });
        for (const l of logs) if (l.args.requestId !== undefined) ids.add(l.args.requestId);
        cached.scannedTo = to;
      }
      logCache.set(cacheKey, cached);
      return [...ids].sort((a, b) => (a < b ? -1 : 1));
    }
  }
}

/** Every open request `owner` has across the chain's tracked queues, with ERC-XXXX status. */
export async function lookup(chain: ChainDef, owner: Address): Promise<TrackedRequest[]> {
  if (!chain.lens) return [];
  const client = clientFor(chain);

  const perQueue = await Promise.all(
    chain.queues.map(async (q) => ({ q, ids: await discover(client, chain, q, owner).catch(() => [] as bigint[]) })),
  );
  const queries = perQueue.flatMap(({ q, ids }) => ids.map((requestId) => ({ q, requestId })));
  if (queries.length === 0) return [];

  const results: TrackedRequest[] = [];
  for (let i = 0; i < queries.length; i += BATCH) {
    const slice = queries.slice(i, i + BATCH);
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
  return open;
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
