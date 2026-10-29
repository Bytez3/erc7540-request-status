import { describe, expect, it } from "vitest";
import {
  MAX_U256,
  MAX_U64,
  RequestState,
  describeAhead,
  describeWindow,
  formatAmount,
  relative,
} from "./format";

const fmt = (t: bigint) => `T${t}`;
const NOW = 1_000_000n;

describe("formatAmount", () => {
  it("formats whole and fractional values", () => {
    expect(formatAmount(0n, 18)).toBe("0");
    expect(formatAmount(1_234_500_000_000_000_000_000n, 18)).toBe("1,234.5");
    expect(formatAmount(1_000_000_000_000_000_000n, 18)).toBe("1");
    expect(formatAmount(1_234_567n, 6)).toBe("1.23");
  });
  it("rounds half up, carrying into the whole part", () => {
    expect(formatAmount(1_995_000n, 6)).toBe("2");
    expect(formatAmount(1_994_999n, 6)).toBe("1.99");
  });
  it("shows dust as <0.01", () => {
    expect(formatAmount(1n, 18)).toBe("<0.01");
  });
});

describe("relative", () => {
  it("covers minutes, hours, days and the past", () => {
    expect(relative(NOW + 30n, NOW)).toBe("now");
    expect(relative(NOW + 45n * 60n, NOW)).toBe("in 45 min");
    expect(relative(NOW + 2n * 3600n + 5n * 60n, NOW)).toBe("in 2 h 5 min");
    expect(relative(NOW + 3n * 86400n + 4n * 3600n, NOW)).toBe("in 3 d 4 h");
    expect(relative(NOW - 7200n, NOW)).toBe("2 h ago");
  });
});

describe("describeWindow", () => {
  it("treats the loosest bounds as unknown", () => {
    const w = describeWindow(RequestState.Pending, 0n, MAX_U64, NOW, fmt);
    expect(w.unknown).toBe(true);
    expect(w.headline).toBe("Timing not published");
  });
  it("shows an exact time when the bounds meet", () => {
    const w = describeWindow(RequestState.Pending, NOW + 3600n, NOW + 3600n, NOW, fmt);
    expect(w.headline).toBe(`Expected T${NOW + 3600n}`);
    expect(w.detail).toBe("in 1 h");
  });
  it("shows a window", () => {
    const w = describeWindow(RequestState.Pending, NOW + 3600n, NOW + 7200n, NOW, fmt);
    expect(w.headline).toBe(`Between T${NOW + 3600n} and T${NOW + 7200n}`);
    expect(w.detail).toBe("in 1 h to 2 h");
  });
  it("handles a missing upper bound", () => {
    const w = describeWindow(RequestState.Pending, NOW + 3600n, MAX_U64, NOW, fmt);
    expect(w.headline).toBe(`Not before T${NOW + 3600n}`);
    expect(w.unknown).toBe(false);
  });
  it("handles a missing or passed lower bound", () => {
    expect(describeWindow(RequestState.Pending, 0n, NOW + 60n * 60n, NOW, fmt).headline).toBe(`By T${NOW + 3600n}`);
    expect(describeWindow(RequestState.Pending, NOW, NOW, NOW, fmt).headline).toBe("Due now");
  });
  it("covers terminal and paused states", () => {
    expect(describeWindow(RequestState.Claimable, 0n, 0n, NOW, fmt).headline).toBe("Ready now");
    expect(describeWindow(RequestState.None, 0n, 0n, NOW, fmt).headline).toBe("Nothing pending");
    expect(describeWindow(RequestState.Suspended, 0n, MAX_U64, NOW, fmt).headline).toBe("On hold");
  });
});

describe("describeAhead", () => {
  it("handles unknown, front of line and amounts", () => {
    expect(describeAhead(MAX_U256, 18, "stETH")).toBe("Queue position not published");
    expect(describeAhead(0n, 18, "stETH")).toBe("You're at the front of the line");
    expect(describeAhead(12_400n * 10n ** 18n, 18, "stETH")).toBe("12,400 stETH ahead of you");
  });
});
