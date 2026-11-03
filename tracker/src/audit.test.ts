// Security / correctness audit proofs for the tracker. Each `T-n` in a test name is a finding ID.
// No production source is modified: main.ts is driven through a minimal fake DOM with ./tracker mocked, and
// tracker.ts is exercised for real against an in-process JSON-RPC server on 127.0.0.1.
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
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

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
  lookup: undefined as unknown as (chain: unknown, owner: string) => Promise<unknown[]>,
  getEnsAddress: async (_: unknown) => null as string | null,
}));
vi.mock("./tracker", () => ({
  clientFor: () => ({ getEnsAddress: (a: unknown) => ctl.getEnsAddress(a) }),
  lookup: (c: unknown, o: string) => ctl.lookup(c, o),
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
// T-1  Dev-only chain / RPC overrides are live in the production build
// ================================================================================================
describe("T-1 dev overrides reachable from production URL", () => {
  it("T-1 ?chain=local activates the Local Anvil chain and auto-tracks ?address= against 127.0.0.1", async () => {
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

  it("T-1b crafted ?from= throws during module init and leaves the page blank", async () => {
    const lens = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
    const vault = "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9";
    await expect(loadMain(`?chain=fork&lens=${lens}&vault=${vault}&from=abc`)).rejects.toThrow(/BigInt/);
  });
});

// ================================================================================================
// T-2  Stale results from a previous lookup render under the new address
// ================================================================================================
describe("T-2 refresh race", () => {
  beforeEach(() => vi.unstubAllGlobals());

  it("T-2 an in-flight auto-refresh for wallet A renders A's requests under wallet B's header", async () => {
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
    expect(html).toContain("0x2222…2222"); // header says wallet B
    expect(html).toContain("Request #111"); // ...but the body is wallet A's request
    expect(html).not.toContain("Request #222");
  });

  it("T-2 the same happens via the demo button while a typed lookup is still loading", async () => {
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
    expect(ui.results.innerHTML).toContain("Request #111");
  });
});

// ================================================================================================
// T-3  One malformed record (bad Lido date, unknown enum) blanks the whole results list
// ================================================================================================
describe("T-3 render robustness", () => {
  beforeEach(() => vi.unstubAllGlobals());

  it("T-3 lidoEstimates turns a non-date finalizationAt into an Invalid Date (no validation)", async () => {
    vi.stubGlobal("fetch", async () => ({
      ok: true,
      json: async () => [{ status: "calculated", requestInfo: { requestId: "5", finalizationAt: "soon", type: "buffer" } }],
    }));
    const m = await lidoEstimates([5n]);
    expect(Number.isNaN(m.get(5n)!.at.getTime())).toBe(true);
    vi.unstubAllGlobals();
  });

  it("T-3 ...and that Invalid Date throws in card() so every request disappears behind a 'Couldn't reach' error", async () => {
    ctl.lookup = async () => [
      req({ requestId: 1n }),
      req({ requestId: 2n, estimate: { at: new Date("soon"), reason: "buffer" } }),
    ];
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).toContain("Couldn't reach Local Anvil");
    expect(ui.results.innerHTML).toContain("cannot be converted to a BigInt");
    expect(ui.results.innerHTML).not.toContain("Request #1");
  });

  it("T-3 an out-of-range Source/State from the lens (uint8) throws in esc(undefined)", async () => {
    ctl.lookup = async () => [req({ requestId: 1n }), req({ requestId: 2n, source: 9 as Source })];
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).toContain("Couldn't reach Local Anvil");
    expect(ui.results.innerHTML).not.toContain("Request #1");
  });

  it("T-3 an out-of-range State renders the literal text 'undefined' and class tone-undefined", async () => {
    ctl.lookup = async () => [req({ state: 9 as RequestState })];
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).toContain("tone-undefined");
    expect(ui.results.innerHTML).toMatch(/>undefined<\/span>/);
  });

  it("T-3c Lido `type` = 'constructor' is looked up on Object.prototype and rendered as native code text", async () => {
    ctl.lookup = async () => [req({ estimate: { at: new Date(1_800_086_400_000), reason: "constructor" } })];
    const ui = await loadMain("?chain=local");
    await submit(ui, A);
    expect(ui.results.innerHTML).toContain("function Object() { [native code] }");
  });
});

// ================================================================================================
// T-4  Timestamps beyond the JS Date range render as "Invalid Date"
// ================================================================================================
describe("T-4 large timestamps", () => {
  it("T-4 a latest bound just below the MAX_U64 sentinel renders 'By Invalid Date'", () => {
    const w = describeWindow(RequestState.Pending, 0n, MAX_U64 - 1n, 1_800_000_000n);
    expect(w.headline).toBe("By Invalid Date");
    expect(formatDate(8_640_000_000_001n)).toBe("Invalid Date"); // year 275760+
  });
  it("T-4 earliest > latest (inconsistent vault) is shown as a backwards window without complaint", () => {
    const fmt = (t: bigint) => `T${t}`;
    const w = describeWindow(RequestState.Pending, 2_000_000_000n, 1_900_000_000n, 1_800_000_000n, fmt);
    expect(w.headline).toBe("Between T2000000000 and T1900000000");
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

  it("T-5 an eth_getLogs failure is reported to the user as 'no open withdrawals' (lookup resolves [])", async () => {
    const { lookup } = await actualTracker();
    handler = rpc(
      () => 100n,
      () => {
        throw new Error("query returned more than 10000 results");
      },
    );
    await expect(lookup(testChain("t5"), OWNER)).resolves.toEqual([]);
  });

  it("T-6 a chunk failing after earlier chunks found the request drops that request from the result", async () => {
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
    expect(r).toEqual([]); // request 7 was found in chunk 1 but is not shown
  });

  it("T-7 a lagging/load-balanced RPC node makes a request invisible for the whole session", async () => {
    const { lookup } = await actualTracker();
    let head = 100n;
    let nodeHasBlock99 = false; // backend that served eth_getLogs was 2 blocks behind the one that served eth_blockNumber
    handler = rpc(
      () => head,
      (from, to) => (nodeHasBlock99 && from <= 99n && 99n <= to ? [redeemLog(42n, 99n)] : []),
    );
    const chain = testChain("t7");
    expect(await lookup(chain, OWNER)).toEqual([]);
    expect(getLogsCalls.at(-1)).toEqual({ fromBlock: 0n, toBlock: 100n });

    nodeHasBlock99 = true; // the log at block 99 is now available everywhere
    head = 101n;
    await new Promise((r) => setTimeout(r, 4_100)); // viem caches eth_blockNumber for pollingInterval (4 s)
    const second = await lookup(chain, OWNER);
    expect(getLogsCalls.at(-1)).toEqual({ fromBlock: 101n, toBlock: 101n }); // block 99 is never re-scanned
    expect(second).toEqual([]); // request 42 is missed until the page is reloaded

    const fresh = await lookup(testChain("t7-reload"), OWNER); // a reload (fresh cache) finds it
    expect(fresh.map((x) => x.requestId)).toEqual([42n]);
  }, 15_000);

  it("T-7 (negative result) fromBlock 0n is handled: the first scan starts at block 0", async () => {
    const { lookup } = await actualTracker();
    handler = rpc(() => 5n, () => [redeemLog(1n, 0n)]);
    const r = await lookup(testChain("t7-zero"), OWNER);
    expect(getLogsCalls[0]).toEqual({ fromBlock: 0n, toBlock: 5n });
    expect(r.map((x) => x.requestId)).toEqual([1n]);
  });
});

// ================================================================================================
// T-8  ENS lookups can never succeed: the client's chain object has no ensUniversalResolver
// ================================================================================================
describe("T-8 ENS", () => {
  it("T-8 getEnsAddress on the mainnet client throws before sending any request", async () => {
    const { clientFor } = await actualTracker();
    const { CHAINS } = await import("./deployments");
    const mainnet = CHAINS.find((c) => c.id === 1)!;
    const { normalize } = await import("viem/ens");
    await expect(clientFor(mainnet).getEnsAddress({ name: normalize("vitalik.eth") })).rejects.toThrow(
      /does not support contract "ensUniversalResolver"/,
    );
  });
});
