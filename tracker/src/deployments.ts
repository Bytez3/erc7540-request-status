import type { Address } from "viem";

/** How the tracker finds a wallet's request ids at a queue. */
export type Discovery =
  | { kind: "events"; fromBlock: bigint } // scan ERC-7540 RedeemRequest logs for the controller
  | { kind: "lens" } // ask the lens / adapter to enumerate on-chain
  | { kind: "zero" }; // the queue aggregates per controller under requestId 0

export interface QueueDef {
  id: string;
  name: string;
  address: Address;
  /** What one unit of `queuedAhead` / Pending is denominated in, e.g. "b3tUSD shares" or "stETH". */
  unit: string;
  decimals: number;
  discovery: Discovery;
  /** Which reader fetches Pending / Claimable amounts (see readers.ts). Defaults to "erc7540". */
  amounts?: string;
  /** Set for vaults that implement ERC-XXXX natively and expose the reference-vault overview views. */
  overview?: boolean;
  blurb: string;
}

export interface ChainDef {
  id: number;
  key: string;
  name: string;
  rpcUrl: string;
  explorer: string;
  testnet: boolean;
  lens?: Address;
  queues: QueueDef[];
  /** Addresses the "Try the demo" button can load. */
  demoWallets?: Address[];
}

// Filled in from the Foundry deploy output. A chain without a `lens` is shown as "coming soon".
export const CHAINS: ChainDef[] = [
  {
    id: 11155111,
    key: "sepolia",
    name: "Sepolia testnet",
    rpcUrl: "https://ethereum-sepolia-rpc.publicnode.com",
    explorer: "https://sepolia.etherscan.io",
    testnet: true,
    queues: [],
  },
  {
    id: 1,
    key: "ethereum",
    name: "Ethereum",
    rpcUrl: "https://ethereum-rpc.publicnode.com",
    explorer: "https://etherscan.io",
    testnet: false,
    queues: [],
  },
];

/** Local Anvil chain for development: `?chain=local`. */
export const LOCAL_CHAIN: ChainDef = {
  id: 31337,
  key: "local",
  name: "Local Anvil",
  rpcUrl: "http://127.0.0.1:8546",
  explorer: "",
  testnet: true,
  lens: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
  queues: [
    {
      id: "demo",
      name: "Bytez3 Demo Queue Vault",
      address: "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
      unit: "b3tUSD shares",
      decimals: 18,
      discovery: { kind: "events", fromBlock: 0n },
      overview: true,
      blurb: "Reference vault that implements the standard natively and enforces its processing schedule.",
    },
  ],
  demoWallets: ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"],
};
