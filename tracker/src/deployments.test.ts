import { getAddress } from "viem";
import { describe, expect, it } from "vitest";

import { CHAINS, FORK_CHAIN, LOCAL_CHAIN } from "./deployments";

describe("deployments config", () => {
  const chains = [...CHAINS, FORK_CHAIN, LOCAL_CHAIN];

  it("uses only valid, checksummed addresses", () => {
    for (const c of chains) {
      for (const a of [c.lens, ...c.queues.map((q) => q.address), ...(c.demoWallets ?? [])]) {
        if (a) expect(getAddress(a)).toBe(a);
      }
    }
  });

  it("has unique queue ids per chain", () => {
    for (const c of chains) {
      const ids = c.queues.map((q) => q.id);
      expect(new Set(ids).size).toBe(ids.length);
    }
  });
});
