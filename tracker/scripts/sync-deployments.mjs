// Reads Foundry broadcast output and writes tracker/src/deployments.generated.json, so deployed addresses are
// never copied by hand. Run from the repo root after a deploy:  node tracker/scripts/sync-deployments.mjs
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "../..");
const out = resolve(root, "tracker/src/deployments.generated.json");
const CHAINS = {
  1: { key: "ethereum", rpc: "https://ethereum-rpc.publicnode.com" },
  11155111: { key: "sepolia", rpc: "https://ethereum-sepolia-rpc.publicnode.com" },
};

// Guards against local fork rehearsals (which reuse the real chain id): only addresses that hold contract code on
// the real network are written.
const hasCode = async (rpc, address) => {
  const res = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [address, "latest"] }),
  });
  const { result } = await res.json();
  return typeof result === "string" && result.length > 2;
};

const read = (script, chainId) => {
  const p = resolve(root, `broadcast/${script}/${chainId}/run-latest.json`);
  return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : undefined;
};
const created = (run, name) => {
  const tx = run?.transactions.find((t) => t.transactionType === "CREATE" && t.contractName === name);
  if (!tx) return undefined;
  const receipt = run.receipts.find((r) => r.transactionHash === tx.hash);
  return { address: tx.contractAddress, block: receipt ? Number(BigInt(receipt.blockNumber)) : 0 };
};

const result = {};
for (const [chainId, { key, rpc }] of Object.entries(CHAINS)) {
  const lensRun = read("DeployLens.s.sol", chainId);
  const demoRun = read("DeployDemo.s.sol", chainId);
  const lens = created(lensRun, "RequestStatusLens");
  const vault = created(demoRun, "FifoRedeemVault");
  if (!lens && !vault) continue;
  for (const [label, c] of [["lens", lens], ["demo vault", vault]]) {
    if (c && !(await hasCode(rpc, c.address))) {
      console.error(`refusing ${key}: ${label} ${c.address} has no code on ${rpc} (a local fork deploy?)`);
      process.exit(1);
    }
  }
  result[key] = {
    lens: lens?.address,
    demoVault: vault?.address,
    demoVaultBlock: vault?.block,
    demoManager: demoRun?.transactions[0]?.transaction?.from,
  };
}
writeFileSync(out, JSON.stringify(result, null, 2) + "\n");
console.log(`wrote ${out}\n${JSON.stringify(result, null, 2)}`);
