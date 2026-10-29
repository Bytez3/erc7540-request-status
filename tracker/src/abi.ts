// Minimal ABIs for the contracts the tracker reads. Every call is read-only.

export const lensAbi = [
  {
    type: "function",
    name: "redeemRequestStatusBatch",
    stateMutability: "view",
    inputs: [
      {
        name: "queries",
        type: "tuple[]",
        components: [
          { name: "vault", type: "address" },
          { name: "requestId", type: "uint256" },
          { name: "controller", type: "address" },
        ],
      },
    ],
    outputs: [
      {
        name: "out",
        type: "tuple[]",
        components: [
          { name: "source", type: "uint8" },
          { name: "ok", type: "bool" },
          { name: "state", type: "uint8" },
          { name: "queuedAhead", type: "uint256" },
          { name: "earliestClaimableAt", type: "uint64" },
          { name: "latestClaimableAt", type: "uint64" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "requestIdsOf",
    stateMutability: "view",
    inputs: [
      { name: "vault", type: "address" },
      { name: "controller", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256[]" }],
  },
] as const;

export const erc7540Abi = [
  {
    type: "function",
    name: "pendingRedeemRequest",
    stateMutability: "view",
    inputs: [
      { name: "requestId", type: "uint256" },
      { name: "controller", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "claimableRedeemRequest",
    stateMutability: "view",
    inputs: [
      { name: "requestId", type: "uint256" },
      { name: "controller", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "event",
    name: "RedeemRequest",
    inputs: [
      { name: "controller", type: "address", indexed: true },
      { name: "owner", type: "address", indexed: true },
      { name: "requestId", type: "uint256", indexed: true },
      { name: "sender", type: "address", indexed: false },
      { name: "shares", type: "uint256", indexed: false },
    ],
  },
] as const;

export const redeemStatusAbi = [
  {
    type: "function",
    name: "redeemDelayBounds",
    stateMutability: "view",
    inputs: [{ name: "shares", type: "uint256" }],
    outputs: [
      { name: "minDelay", type: "uint64" },
      { name: "maxDelay", type: "uint64" },
    ],
  },
] as const;

/// Extra views exposed by the Bytez3 reference vault, used for the queue overview panel.
export const fifoVaultAbi = [
  ...redeemStatusAbi,
  { type: "function", name: "totalQueued", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalProcessed", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "cycleLength", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { type: "function", name: "nextCycleAt", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { type: "function", name: "capacityPerCycle", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "suspended", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { type: "function", name: "impaired", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
] as const;
