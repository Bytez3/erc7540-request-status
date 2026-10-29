# Deploy runbook

Every command below is run by you, from the repo root, with your own wallet. The deployer key lives only in
Foundry's encrypted keystore on your machine. Never paste a private key into a chat, a file or a website.

## 1. Create the deployer wallet (once)

```bash
cast wallet new ~/.foundry/keystores bytez3-deployer
```

This asks you for a password, saves an encrypted keystore, and prints the new address. Back up two things
somewhere safe: the file `~/.foundry/keystores/bytez3-deployer` and its password. Check the address any time with:

```bash
cast wallet address --account bytez3-deployer
```

## 2. Fund it with Sepolia test ETH

About 0.05 Sepolia ETH covers the lens, the demo vault and a few weeks of keeper runs. Free faucets:

- Google Cloud Web3 faucet: https://cloud.google.com/application/web3/faucet/ethereum/sepolia
- PoW faucet (no account needed): https://sepolia-faucet.pk910.de

Check the balance:

```bash
cast balance $(cast wallet address --account bytez3-deployer) --rpc-url https://ethereum-sepolia-rpc.publicnode.com --ether
```

## 3. Deploy to Sepolia

If the keystore was created with a password file next to it (`~/.foundry/keystores/bytez3-deployer.password`),
add `--password-file` so nothing has to be typed. Otherwise drop that flag and Foundry will prompt.

```bash
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com
export PW=~/.foundry/keystores/bytez3-deployer.password
forge script script/DeployLens.s.sol --rpc-url $SEPOLIA_RPC --account bytez3-deployer --password-file $PW --broadcast --verify --verifier sourcify
forge script script/DeployDemo.s.sol --rpc-url $SEPOLIA_RPC --account bytez3-deployer --password-file $PW --broadcast --verify --verifier sourcify
```

Both scripts check after deploying that your wallet owns what they deployed, and abort otherwise. A rehearsal of
these exact commands on a Sepolia fork (2026-10-29) cost about 0.0004 ETH in total.

`--verifier sourcify` publishes the verified source code without needing an API key. To verify on Etherscan
instead, create a free key at etherscan.io and use `--verify --etherscan-api-key <key>`.

## 4. Point the tracker at the new contracts

```bash
node tracker/scripts/sync-deployments.mjs
```

This reads Foundry's deploy output and writes `tracker/src/deployments.generated.json`. Before writing anything, it
checks that each address really holds contract code on the live network, so a local fork rehearsal can never leak
into the config. Commit the generated file.

## 5. Keep the demo queue moving (testnet)

The demo vault pays out once an hour, but only when someone calls the manager function. Run the keeper whenever
you want the queue to advance:

```bash
DEMO_VAULT=<FifoRedeemVault address> forge script script/Keeper.s.sol --rpc-url $SEPOLIA_RPC --account bytez3-deployer --broadcast
```

The keeper refuses to run on Ethereum mainnet or Base.

## 6. Mainnet

Ethereum mainnet needs only the lens and adapters. They are read-only and hold no funds, and the demo vault is
never deployed there. Rehearse on a local fork first:

```bash
anvil --fork-url https://ethereum-rpc.publicnode.com --port 8547
forge script script/DeployLens.s.sol --rpc-url http://127.0.0.1:8547 --account bytez3-deployer --broadcast
rm -rf broadcast/DeployLens.s.sol/1   # discard the rehearsal output
```

Then deploy for real. Set `LENS_OWNER` to a Safe multisig you control. The deployer registers the Lido and
Ethena adapters, then offers ownership to the Safe, which must call `acceptOwnership()`.

```bash
LENS_OWNER=<your Safe address> forge script script/DeployLens.s.sol --rpc-url https://ethereum-rpc.publicnode.com --account bytez3-deployer --broadcast --verify --verifier sourcify
node tracker/scripts/sync-deployments.mjs
```

Measured cost on a mainnet fork (2026-10-29): about 4.9M gas, or roughly 0.001 ETH at 0.2 gwei.

## 7. Host the tracker

```bash
cd tracker && npm ci && npm run build
```

`tracker/dist/` is a fully static site, so it can go on any static host (Cloudflare Pages, Netlify, an S3
bucket, or a route on bytez3.com). It needs no server, database or secrets.

## Local development

```bash
anvil --port 8546                    # local chain for the demo
# deploy DeployLens + DeployDemo to http://127.0.0.1:8546 with an Anvil test key, then:
cd tracker && npm run dev            # open http://localhost:5174/?chain=local
```

To browse real mainnet queues against a fork, deploy the lens to the fork as in step 6 and open
`http://localhost:5174/?chain=fork&lens=<fork lens address>`.
