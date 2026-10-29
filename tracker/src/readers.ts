import type { Address, PublicClient } from "viem";

import { erc7540Abi } from "./abi";

export interface Amounts {
  pending: bigint;
  claimable: bigint;
}

export type AmountReader = (client: PublicClient, queue: Address, requestId: bigint, owner: Address) => Promise<Amounts>;

const lidoStatusAbi = [
  {
    type: "function",
    name: "getWithdrawalStatus",
    stateMutability: "view",
    inputs: [{ name: "_requestIds", type: "uint256[]" }],
    outputs: [
      {
        name: "statuses",
        type: "tuple[]",
        components: [
          { name: "amountOfStETH", type: "uint256" },
          { name: "amountOfShares", type: "uint256" },
          { name: "owner", type: "address" },
          { name: "timestamp", type: "uint256" },
          { name: "isFinalized", type: "bool" },
          { name: "isClaimed", type: "bool" },
        ],
      },
    ],
  },
] as const;

const ethenaCooldownAbi = [
  {
    type: "function",
    name: "cooldowns",
    stateMutability: "view",
    inputs: [{ name: "", type: "address" }],
    outputs: [
      { name: "cooldownEnd", type: "uint104" },
      { name: "underlyingAmount", type: "uint152" },
    ],
  },
] as const;

/** Reads Pending / Claimable amounts for a request, per queue type. */
export const amountReaders: Record<string, AmountReader> = {
  async erc7540(client, queue, requestId, owner) {
    const [pending, claimable] = await Promise.all([
      client.readContract({ address: queue, abi: erc7540Abi, functionName: "pendingRedeemRequest", args: [requestId, owner] }),
      client.readContract({ address: queue, abi: erc7540Abi, functionName: "claimableRedeemRequest", args: [requestId, owner] }),
    ]);
    return { pending, claimable };
  },

  /** Lido unstETH: the request's stETH is pending until finalized, then claimable. */
  async lido(client, queue, requestId) {
    const [s] = await client.readContract({ address: queue, abi: lidoStatusAbi, functionName: "getWithdrawalStatus", args: [[requestId]] });
    return s.isFinalized ? { pending: 0n, claimable: s.amountOfStETH } : { pending: s.amountOfStETH, claimable: 0n };
  },

  /** Ethena sUSDe: the cooldown's USDe is pending until cooldownEnd, then claimable. */
  async ethena(client, queue, _requestId, owner) {
    const [[end, amount], block] = await Promise.all([
      client.readContract({ address: queue, abi: ethenaCooldownAbi, functionName: "cooldowns", args: [owner] }),
      client.getBlock(),
    ]);
    return block.timestamp >= BigInt(end) ? { pending: 0n, claimable: amount } : { pending: amount, claimable: 0n };
  },
};

/** Lido's own off-chain finalization estimate (wq-api.lido.fi), shown alongside the on-chain bounds. */
export async function lidoEstimates(ids: bigint[]): Promise<Map<bigint, { at: Date; reason: string }>> {
  const out = new Map<bigint, { at: Date; reason: string }>();
  if (ids.length === 0) return out;
  const qs = ids.map((id) => `ids=${id}`).join("&");
  const res = await fetch(`https://wq-api.lido.fi/v2/request-time?${qs}`, { headers: { "WQ-Request-Source": "unknown" } });
  if (!res.ok) return out;
  const body = (await res.json()) as {
    requestInfo: { requestId: string; finalizationAt?: string; type?: string };
    status: string;
  }[];
  for (const r of body) {
    if (r.status === "calculated" && r.requestInfo.finalizationAt) {
      out.set(BigInt(r.requestInfo.requestId), { at: new Date(r.requestInfo.finalizationAt), reason: r.requestInfo.type ?? "" });
    }
  }
  return out;
}
