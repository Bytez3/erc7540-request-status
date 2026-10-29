// Pure formatting helpers. No network access, so they are unit-tested in format.test.ts.

export const MAX_U64 = 2n ** 64n - 1n;
export const MAX_U256 = 2n ** 256n - 1n;

export enum RequestState {
  None = 0,
  Pending = 1,
  PartiallyClaimable = 2,
  Claimable = 3,
  Suspended = 4,
  Impaired = 5,
}

export enum Source {
  Unsupported = 0,
  Native = 1,
  Adapter = 2,
  Generic = 3,
}

export const STATE_LABEL: Record<RequestState, string> = {
  [RequestState.None]: "No open request",
  [RequestState.Pending]: "In the queue",
  [RequestState.PartiallyClaimable]: "Partly ready",
  [RequestState.Claimable]: "Ready to claim",
  [RequestState.Suspended]: "Queue paused",
  [RequestState.Impaired]: "At risk",
};

export type Tone = "neutral" | "info" | "good" | "warn" | "bad";

export const STATE_TONE: Record<RequestState, Tone> = {
  [RequestState.None]: "neutral",
  [RequestState.Pending]: "info",
  [RequestState.PartiallyClaimable]: "good",
  [RequestState.Claimable]: "good",
  [RequestState.Suspended]: "warn",
  [RequestState.Impaired]: "bad",
};

export const SOURCE_LABEL: Record<Source, string> = {
  [Source.Unsupported]: "Not supported",
  [Source.Native]: "Reported by the vault",
  [Source.Adapter]: "Bytez3 adapter",
  [Source.Generic]: "Generic ERC-7540",
};

export const SOURCE_HINT: Record<Source, string> = {
  [Source.Unsupported]: "This contract does not expose a withdrawal queue the tracker understands.",
  [Source.Native]: "The vault implements the standard itself, so these figures come straight from it.",
  [Source.Adapter]: "This queue predates the standard. A Bytez3 adapter reads its native contract and translates.",
  [Source.Generic]: "The vault speaks ERC-7540 but does not publish timing, so only amounts are known.",
};

/** "1,234.56" with at most `maxFrac` decimals; tiny non-zero values show as "<0.01". */
export function formatAmount(value: bigint, decimals: number, maxFrac = 2): string {
  if (value === 0n) return "0";
  const base = 10n ** BigInt(decimals);
  const whole = value / base;
  const frac = value % base;
  const scale = 10n ** BigInt(maxFrac);
  let fracScaled = (frac * scale) / base;
  let wholeOut = whole;
  // Round half up on the first dropped digit.
  const remainder = (frac * scale) % base;
  if (remainder * 2n >= base) {
    fracScaled += 1n;
    if (fracScaled === scale) {
      fracScaled = 0n;
      wholeOut += 1n;
    }
  }
  if (wholeOut === 0n && fracScaled === 0n) return `<${(1 / 10 ** maxFrac).toFixed(maxFrac)}`;
  const wholeStr = wholeOut.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  if (fracScaled === 0n || maxFrac === 0) return wholeStr;
  const fracStr = fracScaled.toString().padStart(maxFrac, "0").replace(/0+$/, "");
  return `${wholeStr}.${fracStr}`;
}

/** Human duration from `now` to `t` (both unix seconds): "in 3 d 4 h", "in 45 min", "now", "2 h ago". */
export function relative(t: bigint, now: bigint): string {
  const diff = Number(t - now);
  const past = diff < 0;
  const s = Math.abs(diff);
  if (s < 60) return "now";
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const text = d > 0 ? `${d} d${h ? ` ${h} h` : ""}` : h > 0 ? `${h} h${m ? ` ${m} min` : ""}` : `${m} min`;
  return past ? `${text} ago` : `in ${text}`;
}

export function formatDate(t: bigint, locale?: string, timeZone?: string): string {
  return new Date(Number(t) * 1000).toLocaleString(locale, {
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    timeZone,
  });
}

export interface Window {
  /** Main line, e.g. "Expected Thu 30 Oct, 14:00". */
  headline: string;
  /** Relative line, e.g. "in 2 h" or "between 1 h and 3 h from now". */
  detail: string;
  /** True when the vault published no timing at all. */
  unknown: boolean;
}

/** Turns ERC-XXXX bounds into words. Unknown values arrive as the loosest true bound: 0 and MAX_U64. */
export function describeWindow(
  state: RequestState,
  earliest: bigint,
  latest: bigint,
  now: bigint,
  fmt: (t: bigint) => string = (t) => formatDate(t),
): Window {
  if (state === RequestState.None) return { headline: "Nothing pending", detail: "", unknown: false };
  if (state === RequestState.Claimable) return { headline: "Ready now", detail: "Claim whenever you like", unknown: false };
  if (state === RequestState.Suspended && earliest === 0n && latest === MAX_U64) {
    return { headline: "On hold", detail: "The vault has paused processing; no date until it resumes", unknown: true };
  }

  const noEarliest = earliest === 0n || earliest <= now;
  const noLatest = latest === MAX_U64;

  if (noEarliest && noLatest) {
    return { headline: "Timing not published", detail: "This vault does not say when requests are processed", unknown: true };
  }
  if (noLatest) {
    return { headline: `Not before ${fmt(earliest)}`, detail: `${relative(earliest, now)} at the earliest, no upper bound published`, unknown: false };
  }
  if (noEarliest) {
    if (latest <= now) return { headline: "Due now", detail: "Could be processed at any moment", unknown: false };
    return { headline: `By ${fmt(latest)}`, detail: `could be any moment, ${relative(latest, now)} at the latest`, unknown: false };
  }
  if (earliest === latest) {
    return { headline: `Expected ${fmt(latest)}`, detail: relative(latest, now), unknown: false };
  }
  return {
    headline: `Between ${fmt(earliest)} and ${fmt(latest)}`,
    detail: `${relative(earliest, now)} to ${relative(latest, now).replace(/^in /, "")}`,
    unknown: false,
  };
}

export function describeAhead(queuedAhead: bigint, decimals: number, unit: string): string {
  if (queuedAhead === MAX_U256) return "Queue position not published";
  if (queuedAhead === 0n) return "You're at the front of the line";
  return `${formatAmount(queuedAhead, decimals, 0)} ${unit} ahead of you`;
}

export function shortAddress(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}
