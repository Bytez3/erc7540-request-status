// Regression tests for the tracker audit. Each `T-n` in a test name is a finding ID; every test asserts the fixed
// behaviour. main.ts is driven through a minimal fake DOM with ./tracker mocked, and tracker.ts is exercised for
// real against an in-process JSON-RPC server on 127.0.0.1.
// node:http is loaded dynamically below: the project has no @types/node and `npm run build` type-checks src/.

import {
  decodeFunctionData,
  encodeAbiParameters,
  encodeEventTopics,
  encodeFunctionResult,
  getAddress,
  type Address,
  type Hex,
} from "viem";
import { mainnet } from "viem/chains";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import { erc7540Abi, lensAbi } from "./abi";
import type { ChainDef, QueueDef } from "./deployments";
import { LOCAL_CHAIN } from "./deployments";
import { MAX_U64, RequestState, Source, describeWindow, formatDate } from "./format";
import { lidoEstimates } from "./readers";
import type { TrackedRequest } from "./tracker";

// ------------------------------------------------------------------------------------------------
// Mock of ./tracker used when main.ts is imported (tracker.ts itself is loaded with importActual below).
// ------------------------------------------------------------------------------------------------
const ctl = vi.hoisted(() => ({
  // Tests may return a bare request list (no failed queues) or a full LookupResult.
  lookup: undefined as unknown as (chain: unknown, owner: string) => Promise<unknown>,
  getEnsAddress: async (_: unknown) => null as string | null,
}));
vi.mock("./tracker", () => ({
  clientFor: () => ({ getEnsAddress: (a: unknown) => ctl.getEnsAddress(a) }),
  lookup: async (c: unknown, o: string) => {
    const r = await ctl.lookup(c, o);
    return Array.isArray(r) ? { requests: r, failed: [] } : r;
  },
  chainNow: async () => 1_800_000_000n,
  overview: async () => {
    throw new Error("no overview in tests");
  },
  delayBounds: async () => [0n, 0n],
}));

// ------------------------------------------------------------------------------------------------
// Minimal fake DOM: every querySelector returns a stable stub element; innerHTML is just a string.
// ------------------------------------------------------------------------------------------------
class FakeEl {
  innerHTML = "";
  textContent = "";
  value = "";
  disabled = false;
  dataset: Record<string, string> = {};
  handlers: Record<string, (e: unknown) => void> = {};
  private kids = new Map<string, FakeEl>();
  querySelector(sel: string): FakeEl {
    if (!this.kids.has(sel)) this.kids.set(sel, new FakeEl());
    return this.kids.get(sel)!;
  }
  addEventListener(type: string, fn: (e: unknown) => void) {
    this.handlers[type] = fn;
  }
}

interface Ui {
  results: FakeEl;
  form: FakeEl;
  input: FakeEl;
  hint: FakeEl;
  tick: () => void; // fires the auto-refresh interval callback
}

const flush = async () => {
  for (let i = 0; i < 20; i++) await new Promise((r) => setTimeout(r, 0));
};

async function loadMain(search: string): Promise<Ui> {
  vi.resetModules();
  const root = new FakeEl();
  let intervalCb: (() => void) | undefined;
  const href = `https://tracker.example/${search}`;
  vi.stubGlobal("document", { querySelector: () => root });
  vi.stubGlobal("location", { search, href });
  vi.stubGlobal("history", { replaceState: () => undefined });
  vi.stubGlobal("window", {
    setInterval: (cb: () => void) => {
      intervalCb = cb;
      return 1;
    },
  });
  vi.stubGlobal("clearInterval", () => undefined);
  await import("./main");
  await flush();
  const form = root.querySelector("form.lookup");
  return {
    results: root.querySelector("#results"),
    form,
    input: form.querySelector("input"),
    hint: root.querySelector("#hint"),
    tick: () => intervalCb?.(),
  };
}

const submit = async (ui: Ui, value: string) => {
  ui.input.value = value;
  ui.form.handlers.submit({ preventDefault() {} });
  await flush();
};

const deferred = <T>() => {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
};

const DEMO_Q = LOCAL_CHAIN.queues[0];
const A = getAddress("0x1111111111111111111111111111111111111111");
const B = getAddress("0x2222222222222222222222222222222222222222");

const req = (over: Partial<TrackedRequest> = {}): TrackedRequest => ({
  queue: DEMO_Q,
  requestId: 1n,
  controller: A,
  source: Source.Native,
  ok: true,
  state: RequestState.Pending,
  queuedAhead: 0n,
  earliest: 0n,
  latest: 1_800_003_600n,
  ...over,
});

// ================================================================================================
// T-1  Dev-only chain / RPC overrides were live in the production build (fixed: gated on import.meta.env.DEV)
// ================================================================================================
describe("T-1 dev overrides are dev-server only", () => {
  afterEach(() => vi.unstubAllEnvs());

  it("T-1 in a production build ?chain=local is ignored and nothing is sent to 127.0.0.1", async () => {
    vi.stubEnv("DEV", false);
    const seen: string[] = [];
    ctl.lookup = async (c) => {
      seen.push((c as ChainDef).rpcUrl);
      return [];
    };
    const ui = await loadMain(`?chain=local&address=${A}`);
    expect(seen.some((u) => u.includes("127.0.0.1") || u.includes("localhost"))).toBe(false);
    expect(ui.results.innerHTML).not.toContain("Local Anvil");
  });

  it("T-1 in a production build ?chain=fork&rpc= is ignored too", async () => {
    vi.stubEnv("DEV", false);
    const seen: string[] = [];
    ctl.lookup = async (c) => {
      seen.push((c as ChainDef).rpcUrl);
      return [];
    };
    await loadMain(`?chain=fork&lens=0x5FbDB2315678afecb367f032d93F642f64180aa3&rpc=http://localhost:22&address=${A}`);
    expect(seen).toEqual([]);
  });

  it("T-1 (dev server) ?chain=local still activates the Local Anvil chain for development", async () => {
    const seen: string[] = [];
    ctl.lookup = async (c) => {
      seen.push((c as ChainDef).rpcUrl);
      return [];
    };
    const ui = await loadMain(`?chain=local&address=${A}`);
    expect(seen).toEqual(["http://127.0.0.1:8546"]);
    expect(ui.results.innerHTML).toContain("Local Anvil");
  });

  // The regex is not exported; this is a verbatim copy of main.ts:51.
  const RPC_RE = /^http:\/\/(127\.0\.0\.1|localhost):\d+\/?$/;
  it("T-1 (negative result) the localhost regex rejects host-confusion bypasses", () => {
    for (const bad of [
      "http://127.0.0.1:1@evil.com",
      "http://127.0.0.1:1@evil.com/",
      "http://localhost:80.evil.com",
      "http://localhost.evil.com:80",
      "http://LOCALHOST:8545",
      "HTTP://localhost:8545",
      "http://localhost:8545/rpc",
      "http://localhost:8545/\n",
      "http://localhost:8545\nhttp://evil.com",
      "http://127.0.0.1:8545#@evil.com",
      "http://127.0.0.1:8545?x=@evil.com",
      "http://127。0。0。1:8545",
      "http://ｌocalhost:8545",
      "http://127.0.0.1:８５４５",
      "https://evil.com",
      "javascript:alert(1)//http://localhost:1",
    ]) {
      expect(RPC_RE.test(bad), bad).toBe(false);
    }
    // ...but every loopback port is accepted, including non-RPC local services.
    for (const ok of ["http://localhost:22", "http://127.0.0.1:631/", "http://localhost:0", "http://localhost:99999999"]) {
      expect(RPC_RE.test(ok), ok).toBe(true);
    }
    // And the URL parser agrees with the regex on host for the accepted shape.
    expect(new URL("http://localhost:8545/").hostname).toBe("localhost");
  });

  it("T-1b a malformed ?from= falls back to block 0 instead of crashing the page", async () => {
    const lens = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
    const vault = "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9";
    let fromBlock: bigint | undefined;
    ctl.lookup = async (c) => {
      const d = (c as ChainDef).queues[0].discovery;
      fromBlock = d.kind === "events" ? d.fromBlock : undefined;
      return [];
    };
    await loadMain(`?chain=fork&lens=${lens}&vault=${vault}&from=abc&address=${A}`);
    expect(fromBlock).toBe(0n);
  });
});

// ================================================================================================
// T-2  Stale results from a previous lookup rendered under the new address (fixed: lookup generations)
// ================================================================================================
describe("T-2 refresh race", () => {
  beforeEach(() => vi.unstubAllGlobals());

  it("T-2 an in-flight auto-refresh for wallet A is discarded once wallet B is looked up", async () => {
    const pendingA = deferred<TrackedRequest[]>();
    let callsA = 0;
    ctl.lookup = async (_c, o) => {
      if (o === A) return ++callsA === 1 ? [req({ requestId: 111n, controller: A })] : pendingA.promise;
      return [req({ requestId: 222n, controller: B })];
    };
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).toContain("Request #111");

    ui.tick(); // 30 s auto-refresh for A starts; the RPC is slow
    await flush();
    await submit(ui, B); // user looks up B meanwhile
    expect(ui.results.innerHTML).toContain("Request #222");

    pendingA.resolve([req({ requestId: 111n, controller: A })]); // A's slow refresh lands
    await flush();
    const html = ui.results.innerHTML;
    expect(html).toContain("0x2222…2222");
    expect(html).toContain("Request #222");
    expect(html).not.toContain("Request #111");
  });

  it("T-2 the demo button during a slow typed lookup wins, and the late answer is discarded", async () => {
    const pendingA = deferred<TrackedRequest[]>();
    ctl.lookup = async (_c, o) => (o === A ? pendingA.promise : [req({ requestId: 222n, controller: B })]);
    const ui = await loadMain("?chain=local");
    ui.input.value = A;
    ui.form.handlers.submit({ preventDefault() {} }); // A is loading, submit button disabled
    await flush();
    const demo = LOCAL_CHAIN.demoWallets![0];
    ui.hint.handlers.click({ target: { closest: () => ({ dataset: { demo } }) } }); // demo button is not disabled
    await flush();
    pendingA.resolve([req({ requestId: 111n })]);
    await flush();
    expect(ui.results.innerHTML).toContain("0xf39F…2266");
    expect(ui.results.innerHTML).toContain("Request #222");
    expect(ui.results.innerHTML).not.toContain("Request #111");
  });
});

// ================================================================================================
// T-3  One malformed record (bad Lido date, unknown enum) blanked the whole results list (fixed)
// ================================================================================================
describe("T-3 render robustness", () => {
  beforeEach(() => vi.unstubAllGlobals());

  it("T-3 lidoEstimates drops entries whose finalizationAt or requestId don't parse", async () => {
    vi.stubGlobal("fetch", async () => ({
      ok: true,
      json: async () => [
        { status: "calculated", requestInfo: { requestId: "5", finalizationAt: "soon", type: "buffer" } },
        { status: "calculated", requestInfo: { requestId: "x6", finalizationAt: "2027-01-01T00:00:00Z" } },
        { status: "calculated", requestInfo: { requestId: "7", finalizationAt: "2027-01-01T00:00:00Z", type: "buffer" } },
      ],
    }));
    const m = await lidoEstimates([5n, 7n]);
    expect([...m.keys()]).toEqual([7n]);
    vi.unstubAllGlobals();
  });

  it("T-3 an Invalid Date estimate is skipped and every request still renders", async () => {
    ctl.lookup = async () => [
      req({ requestId: 1n }),
      req({ requestId: 2n, estimate: { at: new Date("soon"), reason: "buffer" } }),
    ];
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).not.toContain("Couldn't reach");
    expect(ui.results.innerHTML).toContain("Request #1");
    expect(ui.results.innerHTML).toContain("Request #2");
  });

  it("T-3 an out-of-range Source from the lens (uint8) renders as 'Unknown source'", async () => {
    ctl.lookup = async () => [req({ requestId: 1n }), req({ requestId: 2n, source: 9 as Source })];
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).not.toContain("Couldn't reach");
    expect(ui.results.innerHTML).toContain("Request #1");
    expect(ui.results.innerHTML).toContain("Unknown source");
  });

  it("T-3 a card that still fails to render is replaced by a placeholder, not the whole list", async () => {
    const bad = req({ requestId: 2n });
    Object.defineProperty(bad, "latest", { get: () => { throw new Error("boom"); } });
    ctl.lookup = async () => [req({ requestId: 1n }), bad];
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).toContain("Request #1");
    expect(ui.results.innerHTML).toContain("can't display");
  });

  it("T-3 an out-of-range State renders as 'Unknown state' with a neutral badge", async () => {
    ctl.lookup = async () => [req({ state: 9 as RequestState })];
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).not.toContain("tone-undefined");
    expect(ui.results.innerHTML).toContain("tone-neutral");
    expect(ui.results.innerHTML).toContain("Unknown state");
  });

  it("T-3c Lido `type` = 'constructor' is not looked up on Object.prototype", async () => {
    ctl.lookup = async () => [req({ estimate: { at: new Date(1_800_086_400_000), reason: "constructor" } })];
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).not.toContain("native code");
    expect(ui.results.innerHTML).toContain("Request #1");
  });
});

// ================================================================================================
// T-4  Timestamps beyond the JS Date range rendered as "Invalid Date" (fixed)
// ================================================================================================
describe("T-4 large timestamps", () => {
  it("T-4 a latest bound just below the MAX_U64 sentinel is treated as no upper bound", () => {
    const w = describeWindow(RequestState.Pending, 0n, MAX_U64 - 1n, 1_800_000_000n);
    expect(w.headline).toBe("Timing not published");
    expect(formatDate(8_640_000_000_001n)).toBe("far in the future"); // year 275760+
    expect(formatDate(8_640_000_000_001n)).not.toContain("Invalid");
  });
  it("T-4 earliest > latest (inconsistent vault) is flagged instead of drawn as a backwards window", () => {
    const fmt = (t: bigint) => `T${t}`;
    const w = describeWindow(RequestState.Pending, 2_000_000_000n, 1_900_000_000n, 1_800_000_000n, fmt);
    expect(w.headline).toBe("Timing inconsistent");
    expect(w.unknown).toBe(true);
  });
});

// ================================================================================================
// XSS probes (negative results: these all PASS = no injection found)
// ================================================================================================
describe("XSS probes", () => {
  beforeEach(() => vi.unstubAllGlobals());
  const PAYLOAD = `"><img src=x onerror=alert(1)>`;

  it("XSS-1 a hostile ?address= value is rejected and never echoed", async () => {
    ctl.lookup = async () => [];
    const ui = await loadMain(`?chain=local&address=${encodeURIComponent(PAYLOAD)}`);
    expect(ui.results.innerHTML).not.toContain("<img");
    expect(ui.results.innerHTML).toContain("doesn&#39;t look like a wallet address");
  });

  it("XSS-2 a hostile ENS-looking name on a chainId-1 chain is escaped in the error", async () => {
    ctl.lookup = async () => [];
    ctl.getEnsAddress = async () => null;
    const ui = await loadMain(`?chain=fork&lens=0x5FbDB2315678afecb367f032d93F642f64180aa3`);
    await submit(ui, `${PAYLOAD}.eth`);
    expect(ui.results.innerHTML).not.toContain("<img");
    await submit(ui, `a<b>.eth`);
    expect(ui.results.innerHTML).not.toContain("<b>");
  });

  it("XSS-3 RPC error text is escaped", async () => {
    ctl.lookup = async () => {
      throw new Error(PAYLOAD);
    };
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).toContain("&lt;img");
    expect(ui.results.innerHTML).not.toContain("<img");
  });

  it("XSS-4 Lido API `type` is only used as a lookup key, never interpolated", async () => {
    ctl.lookup = async () => [req({ estimate: { at: new Date(1_800_086_400_000), reason: PAYLOAD } })];
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).not.toContain("<img");
  });

  it("XSS-5 progress width is a bounded number even for uint256-max amounts", async () => {
    const big = 2n ** 256n - 1n;
    ctl.lookup = async () => [req({ pending: big, claimable: big })];
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).toContain(`style="width:50%"`);
  });
});

// ================================================================================================
// T-5 / T-6 / T-7  tracker.ts against a real (in-process) JSON-RPC server
// ================================================================================================
type Handler = (method: string, params: unknown[]) => unknown;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type NodeAny = any;
let server: NodeAny;
let port = 0;
let handler: Handler = () => null;
const getLogsCalls: { fromBlock: bigint; toBlock: bigint }[] = [];

beforeAll(async () => {
  const nodeHttp = "node:http";
  const { createServer } = (await import(/* @vite-ignore */ nodeHttp)) as NodeAny;
  server = createServer((req: NodeAny, res: NodeAny) => {
    let body = "";
    req.on("data", (d: string) => (body += d));
    req.on("end", () => {
      const parsed = JSON.parse(body);
      const one = (m: { id: number; method: string; params: unknown[] }) => {
        try {
          return { jsonrpc: "2.0", id: m.id, result: handler(m.method, m.params) };
        } catch (e) {
          return { jsonrpc: "2.0", id: m.id, error: { code: -32602, message: (e as Error).message } };
        }
      };
      const out = Array.isArray(parsed) ? parsed.map(one) : one(parsed);
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify(out));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  port = (server.address() as { port: number }).port;
});
afterAll(() => server.close());

const LENS = getAddress("0x00000000000000000000000000000000000000a1");
const VAULT = getAddress("0x00000000000000000000000000000000000000b2");
const OWNER = getAddress("0x3333333333333333333333333333333333333333");
const hex = (n: bigint) => `0x${n.toString(16)}` as Hex;

function testChain(key: string): ChainDef {
  const q: QueueDef = {
    id: "demo",
    name: "Demo",
    address: VAULT,
    unit: "s",
    decimals: 18,
    discovery: { kind: "events", fromBlock: 0n },
    blurb: "",
  };
  return { id: 31337, key, name: key, rpcUrl: `http://127.0.0.1:${port}`, explorer: "", testnet: true, lens: LENS, queues: [q] };
}

function redeemLog(requestId: bigint, block: bigint) {
  const topics = encodeEventTopics({ abi: erc7540Abi, eventName: "RedeemRequest", args: { controller: OWNER, owner: OWNER, requestId } });
  return {
    address: VAULT,
    topics,
    data: encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [OWNER, 1n]),
    blockNumber: hex(block),
    blockHash: `0x${"11".repeat(32)}`,
    transactionHash: `0x${"22".repeat(32)}`,
    transactionIndex: "0x0",
    logIndex: "0x0",
    removed: false,
  };
}

/** Builds a JSON-RPC handler for a chain whose head is `head()` and whose node returns `logs(from,to)`. */
function rpc(head: () => bigint, logs: (from: bigint, to: bigint) => unknown[]): Handler {
  return (method, params) => {
    if (method === "eth_blockNumber") return hex(head());
    if (method === "eth_chainId") return "0x7a69";
    if (method === "eth_getLogs") {
      const f = params[0] as { fromBlock: Hex; toBlock: Hex };
      const range = { fromBlock: BigInt(f.fromBlock), toBlock: BigInt(f.toBlock) };
      getLogsCalls.push(range);
      return logs(range.fromBlock, range.toBlock);
    }
    if (method === "eth_call") {
      const { to, data } = params[0] as { to: Address; data: Hex };
      if (getAddress(to) === LENS) {
        const d = decodeFunctionData({ abi: lensAbi, data });
        if (d.functionName === "redeemRequestStatusBatch") {
          const qs = d.args[0] as readonly { requestId: bigint }[];
          return encodeFunctionResult({
            abi: lensAbi,
            functionName: "redeemRequestStatusBatch",
            result: qs.map(() => ({ source: 1, ok: true, state: 1, queuedAhead: 0n, earliestClaimableAt: 0n, latestClaimableAt: MAX_U64 })),
          });
        }
      }
      return encodeAbiParameters([{ type: "uint256" }], [1n]); // pending/claimable
    }
    throw new Error(`unhandled ${method}`);
  };
}

const actualTracker = () => vi.importActual<typeof import("./tracker")>("./tracker");

describe("T-5 / T-6 / T-7 log discovery", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    getLogsCalls.length = 0;
  });

  it("T-5 an eth_getLogs failure is reported as a failed queue, not as 'no open withdrawals'", async () => {
    const { lookup } = await actualTracker();
    handler = rpc(
      () => 100n,
      () => {
        throw new Error("query returned more than 10000 results");
      },
    );
    const r = await lookup(testChain("t5"), OWNER);
    expect(r.requests).toEqual([]);
    expect(r.failed.map((q) => q.id)).toEqual(["demo"]);
  });

  it("T-5 main.ts tells the user a queue couldn't be checked", async () => {
    ctl.lookup = async () => ({ requests: [], failed: [DEMO_Q] });
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).toContain("Couldn't check every queue");
    expect(ui.results.innerHTML).not.toContain("No open withdrawals found<");
  });

  it("T-6 a chunk failing after earlier chunks keeps the requests already found", async () => {
    const { lookup } = await actualTracker();
    handler = rpc(
      () => 50_000n,
      (from) => {
        if (from >= 45_000n) throw new Error("rate limited");
        return [redeemLog(7n, 10n)];
      },
    );
    const r = await lookup(testChain("t6"), OWNER);
    expect(getLogsCalls[0]).toEqual({ fromBlock: 0n, toBlock: 44_999n });
    expect(r.requests.map((x) => x.requestId)).toEqual([7n]);
    expect(r.failed.map((q) => q.id)).toEqual(["demo"]);
  });

  it("T-7 a log missed by a lagging/load-balanced RPC node is picked up on the next refresh", async () => {
    const { lookup } = await actualTracker();
    let head = 100n;
    let nodeHasBlock99 = false; // backend that served eth_getLogs was 2 blocks behind the one that served eth_blockNumber
    handler = rpc(
      () => head,
      (from, to) => (nodeHasBlock99 && from <= 99n && 99n <= to ? [redeemLog(42n, 99n)] : []),
    );
    const chain = testChain("t7");
    expect((await lookup(chain, OWNER)).requests).toEqual([]);
    expect(getLogsCalls.at(-1)).toEqual({ fromBlock: 0n, toBlock: 100n });

    nodeHasBlock99 = true; // the log at block 99 is now available everywhere
    head = 101n;
    await new Promise((r) => setTimeout(r, 4_100)); // viem caches eth_blockNumber for pollingInterval (4 s)
    const second = await lookup(chain, OWNER);
    expect(getLogsCalls.at(-1)).toEqual({ fromBlock: 37n, toBlock: 101n }); // the last 64 blocks are re-scanned
    expect(second.requests.map((x) => x.requestId)).toEqual([42n]);
  }, 15_000);

  it("T-7 (negative result) fromBlock 0n is handled: the first scan starts at block 0", async () => {
    const { lookup } = await actualTracker();
    handler = rpc(() => 5n, () => [redeemLog(1n, 0n)]);
    const r = await lookup(testChain("t7-zero"), OWNER);
    expect(getLogsCalls[0]).toEqual({ fromBlock: 0n, toBlock: 5n });
    expect(r.requests.map((x) => x.requestId)).toEqual([1n]);
  });
});

// ================================================================================================
// T-8  ENS lookups could never succeed: the client's chain object had no ensUniversalResolver (fixed)
// ================================================================================================
describe("T-8 ENS", () => {
  it("T-8 getEnsAddress on a chain-id-1 client queries the ENS Universal Resolver", async () => {
    const { clientFor } = await actualTracker();
    const { normalize } = await import("viem/ens");
    const calledTo: string[] = [];
    handler = (method, params) => {
      if (method === "eth_chainId") return "0x1";
      if (method === "eth_call") {
        calledTo.push(getAddress((params[0] as { to: Address }).to));
        throw new Error("execution reverted");
      }
      throw new Error(`unhandled ${method}`);
    };
    const chain = { ...testChain("t8"), id: 1 };
    await expect(clientFor(chain).getEnsAddress({ name: normalize("vitalik.eth") })).rejects.not.toThrow(
      /does not support contract "ensUniversalResolver"/,
    );
    expect(calledTo).toContain(getAddress(mainnet.contracts.ensUniversalResolver.address));
  });
});
