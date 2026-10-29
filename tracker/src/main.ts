import "./style.css";

import { getAddress, isAddress, parseUnits, type Address } from "viem";
import { normalize } from "viem/ens";

import { CHAINS, FORK_CHAIN, LOCAL_CHAIN, type ChainDef } from "./deployments";
import {
  MAX_U64,
  RequestState,
  SOURCE_HINT,
  SOURCE_LABEL,
  STATE_LABEL,
  STATE_TONE,
  describeAhead,
  describeWindow,
  formatAmount,
  formatDate,
  relative,
  shortAddress,
} from "./format";
import { chainNow, clientFor, delayBounds, lookup, overview, type TrackedRequest } from "./tracker";

const REFRESH_MS = 30_000;

/** Lido wq-api `type` values, in plain words. */
const ESTIMATE_REASON: Record<string, string> = {
  buffer: "covered by Lido's ETH buffer",
  bunker: "Lido is in bunker mode",
  vaultsBalance: "covered by Lido's vault balances",
  rewardsOnly: "waiting for staking rewards",
  validatorBalances: "waiting for validator balances",
  requestTimestampMargin: "waiting for the request to age",
  exitValidators: "waiting for validators to exit",
};
const GITHUB = "https://github.com/Bytez3/erc7540-request-status";

const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

// ------------------------------------------------------------------------------------------------
// State
// ------------------------------------------------------------------------------------------------

const params = new URLSearchParams(location.search);
const devChain = (() => {
  if (params.get("chain") === "local") return LOCAL_CHAIN;
  const lens = params.get("lens");
  if (params.get("chain") === "fork" && lens && isAddress(lens)) return { ...FORK_CHAIN, lens: getAddress(lens) };
  return undefined;
})();
const allChains = devChain ? [devChain, ...CHAINS] : CHAINS;
let chain: ChainDef =
  allChains.find((c) => c.key === params.get("chain")) ?? allChains.find((c) => c.lens) ?? allChains[0];
let owner: Address | undefined;
let timer: number | undefined;

// ------------------------------------------------------------------------------------------------
// Shell
// ------------------------------------------------------------------------------------------------

const app = document.querySelector<HTMLDivElement>("#app")!;
app.innerHTML = `
  <header>
    <div class="wrap bar">
      <a class="brand" href="https://www.bytez3.com" aria-label="Bytez3">
        <span class="brand-mark">B3</span> Bytez3 <small>Queue Tracker</small>
      </a>
      <nav class="chains" aria-label="Network"></nav>
    </div>
  </header>

  <main class="wrap">
    <section class="hero">
      <span class="eyebrow">Withdrawal queues, explained</span>
      <h1>When do I get <span class="gradient">my money?</span></h1>
      <p class="lede">Paste a wallet to see every withdrawal it has waiting: where it is in the queue, and the
        earliest and latest it can be paid out.</p>
      <form class="lookup" autocomplete="off">
        <input name="who" placeholder="Wallet address (0x…) or ENS name" aria-label="Wallet address or ENS name" spellcheck="false" />
        <button class="btn" type="submit">Track</button>
      </form>
      <p class="hint" id="hint"></p>
    </section>

    <div class="results" id="results" aria-live="polite"></div>

    <section class="block" id="queues">
      <h2>Queues we track</h2>
      <p class="section-lede">Every queue below is read live from the blockchain. Nothing is stored and no wallet connection is needed.</p>
      <div class="queue-grid" id="queue-grid"></div>
    </section>

    <section class="block">
      <h2>How it works</h2>
      <p class="section-lede">Built on an open Ethereum standard proposed by Bytez3.</p>
      <div class="steps">
        <div class="card step"><div class="step-n">1</div><h3>One standard question</h3>
          <p>The draft standard adds one read-only question to any withdrawal vault: what state is this request in,
          how much is ahead of it, and what are the earliest and latest times it can be paid?</p></div>
        <div class="card step"><div class="step-n">2</div><h3>Honest when unsure</h3>
          <p>Every answer is a range. A vault that doesn't know says "anywhere from now to never", so it can never
          report something false. We show exactly what each vault publishes, nothing more.</p></div>
        <div class="card step"><div class="step-n">3</div><h3>Works with today's queues</h3>
          <p>Queues that predate the standard are covered by small Bytez3 adapter contracts, so the tracker works
          now, before vaults adopt it themselves.</p></div>
      </div>
    </section>
  </main>

  <footer>
    <div class="wrap foot">
      <span>Built by <a href="https://www.bytez3.com">Bytez3</a> · Falmouth, Cornwall</span>
      <span><a href="${GITHUB}">Open source on GitHub</a> · Draft standard: Request Status for ERC-7540 Vaults</span>
    </div>
  </footer>
`;

const nav = app.querySelector<HTMLElement>(".chains")!;
const form = app.querySelector<HTMLFormElement>("form.lookup")!;
const input = form.querySelector<HTMLInputElement>("input")!;
const button = form.querySelector<HTMLButtonElement>("button")!;
const hint = app.querySelector<HTMLElement>("#hint")!;
const results = app.querySelector<HTMLElement>("#results")!;
const queueGrid = app.querySelector<HTMLElement>("#queue-grid")!;

// ------------------------------------------------------------------------------------------------
// Rendering
// ------------------------------------------------------------------------------------------------

function renderChains() {
  nav.innerHTML = allChains
    .map(
      (c) =>
        `<button type="button" data-chain="${c.key}" aria-pressed="${c.key === chain.key}">${esc(
          c.testnet ? c.name.replace(" testnet", "") : c.name,
        )}${c.lens ? "" : " · soon"}</button>`,
    )
    .join("");
}

function renderHint() {
  if (!chain.lens) {
    hint.innerHTML = `${esc(chain.name)} launches soon. Try the testnet demo in the meantime.`;
    return;
  }
  const demo = chain.demoWallets?.[0];
  hint.innerHTML = `${chain.testnet ? `<b>${esc(chain.name)}</b>: test funds only. ` : ""}${
    demo ? `<button type="button" class="btn btn-ghost" data-demo="${demo}">Try a demo wallet →</button>` : ""
  }`;
}

function card(r: TrackedRequest, now: bigint): string {
  const q = r.queue;
  const w = describeWindow(r.state, r.earliest, r.latest, now, (t) => formatDate(t));
  const total = (r.pending ?? 0n) + (r.claimable ?? 0n);
  const pct = total > 0n ? Number(((r.claimable ?? 0n) * 10_000n) / total) / 100 : r.state === RequestState.Claimable ? 100 : 0;
  const amounts =
    r.pending !== undefined
      ? `<div class="progress" role="progressbar" aria-valuenow="${pct}" aria-valuemin="0" aria-valuemax="100" aria-label="Share ready to claim"><span style="width:${pct}%"></span></div>
         <div class="card-sub">${formatAmount(r.claimable ?? 0n, q.decimals)} ready · ${formatAmount(r.pending, q.decimals)} still waiting · ${esc(q.unit)}</div>`
      : "";
  const showAhead = r.state === RequestState.Pending || r.state === RequestState.PartiallyClaimable ||
    r.state === RequestState.Suspended || r.state === RequestState.Impaired;
  const explorer = chain.explorer ? `<a href="${chain.explorer}/address/${q.address}" target="_blank" rel="noopener">${shortAddress(q.address)}</a>` : `<span class="mono">${shortAddress(q.address)}</span>`;

  return `
    <article class="card">
      <div class="card-head">
        <div>
          <div class="card-title">${esc(q.name)}</div>
          <div class="card-sub">${q.discovery.kind === "zero" ? "Your position" : `Request #${r.requestId.toString()}`} · ${explorer}</div>
        </div>
        <span class="badge tone-${STATE_TONE[r.state]}">${STATE_LABEL[r.state]}</span>
      </div>
      <div class="when${w.unknown ? " unknown" : ""}">
        <div class="when-headline">${esc(w.headline)}</div>
        <div class="when-detail">${esc(w.detail)}</div>
      </div>
      ${amounts}
      <dl class="facts">
        ${showAhead ? `<div class="fact"><dt>Queue position</dt><dd>${esc(describeAhead(r.queuedAhead, q.decimals, q.unit))}</dd></div>` : ""}
        ${r.earliest > 0n && r.earliest !== r.latest && r.state !== RequestState.Claimable ? `<div class="fact"><dt>Earliest</dt><dd>${esc(formatDate(r.earliest))}</dd></div>` : ""}
        ${r.estimate ? `<div class="fact"><dt>${esc(q.name.split(" ")[0])}'s own estimate</dt><dd>${esc(r.estimate.at.toLocaleString(undefined, { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }))} <span class="card-sub">(${esc(relative(BigInt(Math.floor(r.estimate.at.getTime() / 1000)), now))}${ESTIMATE_REASON[r.estimate.reason] ? `, ${ESTIMATE_REASON[r.estimate.reason]}` : ""})</span></dd></div>` : ""}
        ${r.latest > 0n && r.latest !== MAX_U64 && r.earliest !== r.latest && r.state !== RequestState.Claimable ? `<div class="fact"><dt>Latest</dt><dd>${esc(formatDate(r.latest))}</dd></div>` : ""}
      </dl>
      <div class="source"><b>${SOURCE_LABEL[r.source]}.</b> ${esc(SOURCE_HINT[r.source])}</div>
    </article>`;
}

function renderResults(list: TrackedRequest[], now: bigint) {
  if (!owner) {
    results.innerHTML = "";
    return;
  }
  const head = `<div class="updated">${shortAddress(owner)} on ${esc(chain.name)} · updated ${new Date().toLocaleTimeString()}</div>`;
  if (list.length === 0) {
    results.innerHTML = `${head}<div class="notice"><strong>No open withdrawals found</strong>This wallet has nothing waiting in the queues we track on ${esc(chain.name)}.</div>`;
    return;
  }
  const order = (r: TrackedRequest) => (r.state === RequestState.Claimable ? 0 : r.state === RequestState.PartiallyClaimable ? 1 : 2);
  results.innerHTML = head + [...list].sort((a, b) => order(a) - order(b)).map((r) => card(r, now)).join("");
}

async function renderQueues() {
  if (!chain.lens || chain.queues.length === 0) {
    queueGrid.innerHTML = `<div class="notice"><strong>Coming soon on ${esc(chain.name)}</strong>Contracts for this network have not been deployed yet.</div>`;
    return;
  }
  queueGrid.innerHTML = chain.queues.map((q) => `<article class="card" data-queue="${q.id}">
      <div class="card-head"><div><div class="card-title">${esc(q.name)}</div><div class="card-sub">${esc(q.blurb)}</div></div></div>
      <div class="queue-live"></div></article>`).join("");

  await Promise.all(chain.queues.filter((q) => q.overview).map(async (q) => {
    const el = queueGrid.querySelector<HTMLElement>(`[data-queue="${q.id}"] .queue-live`)!;
    try {
      const [o, now] = await Promise.all([overview(chain, q), chainNow(chain)]);
      const state = o.impaired ? `<span class="badge tone-bad">At risk</span>` : o.suspended ? `<span class="badge tone-warn">Paused</span>` : `<span class="badge tone-good">Processing</span>`;
      el.innerHTML = `
        <div class="stats">
          <div class="stat"><div class="k">Status</div><div class="v">${state}</div></div>
          <div class="stat"><div class="k">Waiting in line</div><div class="v">${formatAmount(o.outstanding, q.decimals, 0)}</div></div>
          <div class="stat"><div class="k">Paid per cycle</div><div class="v">${o.capacity === 0n ? "Uncapped" : formatAmount(o.capacity, q.decimals, 0)}</div></div>
          <div class="stat"><div class="k">Next cycle</div><div class="v">${o.cycleLength === 0n ? "Any time" : esc(relative(o.nextCycleAt > now ? o.nextCycleAt : now, now))}</div></div>
        </div>
        <div class="calc">If I ask to withdraw <input type="number" min="0" step="any" value="1000" aria-label="Amount to withdraw" /> ${esc(q.unit)} now: <output>…</output></div>`;
      const amount = el.querySelector<HTMLInputElement>(".calc input")!;
      const out = el.querySelector<HTMLOutputElement>(".calc output")!;
      const update = async () => {
        let shares: bigint;
        try {
          shares = parseUnits(amount.value || "0", q.decimals);
        } catch {
          out.textContent = "enter a number";
          return;
        }
        const [min, max] = await delayBounds(chain, q, shares);
        const t = await chainNow(chain);
        out.textContent = describeWindow(RequestState.Pending, min === 0n ? 0n : t + min, max === MAX_U64 ? MAX_U64 : t + max, t).headline;
      };
      amount.addEventListener("input", () => void update().catch(() => (out.textContent = "unavailable")));
      await update();
    } catch {
      el.innerHTML = `<div class="card-sub">Live figures are unavailable right now.</div>`;
    }
  }));
}

// ------------------------------------------------------------------------------------------------
// Actions
// ------------------------------------------------------------------------------------------------

async function resolveOwner(raw: string): Promise<Address> {
  const v = raw.trim();
  if (isAddress(v, { strict: false })) return getAddress(v);
  if (v.includes(".") && chain.id === 1) {
    const a = await clientFor(chain).getEnsAddress({ name: normalize(v) });
    if (a) return a;
    throw new Error(`No address found for ${v}`);
  }
  throw new Error("That doesn't look like a wallet address");
}

async function refresh() {
  if (!owner || !chain.lens) return;
  try {
    const [list, now] = await Promise.all([lookup(chain, owner), chainNow(chain)]);
    renderResults(list, now);
  } catch (e) {
    results.innerHTML = `<div class="notice"><strong>Couldn't reach ${esc(chain.name)}</strong>${esc((e as Error).message.split("\n")[0])}</div>`;
  }
}

async function track(raw: string) {
  if (!chain.lens) return;
  button.disabled = true;
  results.innerHTML = `<div class="skeleton"></div>`;
  try {
    owner = await resolveOwner(raw);
    input.value = raw.trim();
    const url = new URL(location.href);
    url.searchParams.set("chain", chain.key);
    url.searchParams.set("address", owner);
    history.replaceState(null, "", url);
    await refresh();
    clearInterval(timer);
    timer = window.setInterval(() => void refresh(), REFRESH_MS);
  } catch (e) {
    owner = undefined;
    results.innerHTML = `<div class="notice"><strong>${esc((e as Error).message)}</strong>Paste a 0x… address${chain.id === 1 ? " or an ENS name" : ""}.</div>`;
  } finally {
    button.disabled = false;
  }
}

function switchChain(key: string) {
  const next = allChains.find((c) => c.key === key);
  if (!next || next.key === chain.key) return;
  chain = next;
  owner = undefined;
  clearInterval(timer);
  results.innerHTML = "";
  const url = new URL(location.href);
  url.searchParams.set("chain", chain.key);
  url.searchParams.delete("address");
  history.replaceState(null, "", url);
  renderChains();
  renderHint();
  void renderQueues();
}

form.addEventListener("submit", (e) => {
  e.preventDefault();
  void track(input.value);
});
nav.addEventListener("click", (e) => {
  const b = (e.target as HTMLElement).closest<HTMLButtonElement>("button[data-chain]");
  if (b) switchChain(b.dataset.chain!);
});
hint.addEventListener("click", (e) => {
  const b = (e.target as HTMLElement).closest<HTMLButtonElement>("button[data-demo]");
  if (b) {
    input.value = b.dataset.demo!;
    void track(b.dataset.demo!);
  }
});

renderChains();
renderHint();
void renderQueues();
const initial = params.get("address");
if (initial && chain.lens) void track(initial);
