import type { Address, PublicClient } from "viem";

import { erc7540Abi } from "./abi";

export interface Amounts {
  pending: bigint;
  claimable: bigint;
}

export type AmountReader = (client: PublicClient, queue: Address, requestId: bigint, owner: Address) => Promise<Amounts>;

/** Reads Pending / Claimable amounts for a request. Queue-specific readers are added alongside their adapters. */
export const amountReaders: Record<string, AmountReader> = {
  async erc7540(client, queue, requestId, owner) {
    const [pending, claimable] = await Promise.all([
      client.readContract({ address: queue, abi: erc7540Abi, functionName: "pendingRedeemRequest", args: [requestId, owner] }),
      client.readContract({ address: queue, abi: erc7540Abi, functionName: "claimableRedeemRequest", args: [requestId, owner] }),
    ]);
    return { pending, claimable };
  },
};
