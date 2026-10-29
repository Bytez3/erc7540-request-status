import type { Address } from "viem";

import generated from "./deployments.generated.json";

/** Written by `node tracker/scripts/sync-deployments.mjs` from Foundry broadcast output after each deploy. */
interface Generated {
  lens?: Address;
  demoVault?: Address;
  demoVaultBlock?: number;
  demoManager?: Address;
}
const gen = generated as Record<string, Generated>;

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
  /** Off-chain estimate source shown alongside the on-chain bounds (clearly labelled as the protocol's own). */
  estimate?: "lido";
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

/** Queues tracked on Ethereum mainnet. Addresses verified in docs/research/queue-interfaces.md. */
export const MAINNET_QUEUES: QueueDef[] = [
  {
    id: "lido",
    name: "Lido stETH withdrawals",
    address: "0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1",
    unit: "stETH",
    decimals: 18,
    discovery: { kind: "lens" },
    amounts: "lido",
    estimate: "lido",
    blurb: "Unstaking stETH back to ETH. Paid out at Lido's daily oracle report once enough ETH is available.",
  },
  {
    id: "ethena",
    name: "Ethena sUSDe cooldown",
    address: "0x9D39A5DE30e57443BfF2A8307A4256c8797A3497",
    unit: "USDe",
    decimals: 18,
    discovery: { kind: "zero" },
    amounts: "ethena",
    blurb: "Unstaking sUSDe. A fixed cooldown per wallet, so the payout time is exact.",
  },
  {
    id: "centrifuge-jtrsy",
    name: "Centrifuge · Janus Henderson Treasury (JTRSY)",
    address: "0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A",
    unit: "JTRSY",
    decimals: 6,
    discovery: { kind: "zero" },
    blurb: "Tokenised US Treasury fund (ERC-7540). Redemptions settle when the fund processes them.",
  },
  {
    id: "centrifuge-jaaa",
    name: "Centrifuge · Janus Henderson AAA CLO (JAAA)",
    address: "0x4880799eE5200fC58DA299e965df644fBf46780B",
    unit: "JAAA",
    decimals: 6,
    discovery: { kind: "zero" },
    blurb: "Tokenised AAA CLO fund (ERC-7540). Redemptions settle when the fund processes them.",
  },
  {
    id: "centrifuge-acrdx",
    name: "Centrifuge · Anemoy Apollo credit (ACRDX)",
    address: "0x74A739EA1Dc67c5a0179ebad665D1D3c4b80B712",
    unit: "ACRDX",
    decimals: 18,
    discovery: { kind: "zero" },
    blurb: "Tokenised private-credit fund (ERC-7540). Redemptions settle when the fund processes them.",
  },
];

// Filled in from the Foundry deploy output. A chain without a `lens` is shown as "coming soon".
export const CHAINS: ChainDef[] = [
  {
    id: 11155111,
    key: "sepolia",
    name: "Sepolia testnet",
    rpcUrl: "https://ethereum-sepolia-rpc.publicnode.com",
    explorer: "https://sepolia.etherscan.io",
    testnet: true,
    lens: gen.sepolia?.lens,
    queues: gen.sepolia?.demoVault
      ? [
          {
            id: "demo",
            name: "Bytez3 Demo Queue Vault",
            address: gen.sepolia.demoVault,
            unit: "b3tUSD shares",
            decimals: 18,
            discovery: { kind: "events", fromBlock: BigInt(gen.sepolia.demoVaultBlock ?? 0) },
            overview: true,
            blurb: "A live demo of the standard: this vault reports its own queue and enforces an hourly payout schedule. Test funds only.",
          },
        ]
      : [],
    demoWallets: gen.sepolia?.demoManager ? [gen.sepolia.demoManager] : undefined,
  },
  {
    id: 1,
    key: "ethereum",
    name: "Ethereum",
    rpcUrl: "https://ethereum-rpc.publicnode.com",
    explorer: "https://etherscan.io",
    testnet: false,
    lens: gen.ethereum?.lens,
    queues: MAINNET_QUEUES,
  },
];

/** Local Anvil fork of mainnet for end-to-end testing against real queues: `?chain=fork`. */
export const FORK_CHAIN: ChainDef = {
  id: 1,
  key: "fork",
  name: "Mainnet fork (local)",
  rpcUrl: "http://127.0.0.1:8547",
  explorer: "https://etherscan.io",
  testnet: true,
  lens: undefined, // set by `?lens=0x…` when testing
  queues: MAINNET_QUEUES,
};

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
