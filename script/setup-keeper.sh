#!/usr/bin/env bash
# One-time setup for the hourly GitHub Actions keeper (.github/workflows/keeper.yml) on the Sepolia demo vault.
#
#   1. Creates a fresh keeper wallet. Its private key is piped straight into the repo's encrypted GitHub secret
#      KEEPER_PRIVATE_KEY and is never printed or written to disk.
#   2. Sends it 0.05 Sepolia ETH from the deployer wallet for gas.
#   3. Hands ownership of the demo vault (and only the demo vault) to the keeper. The lens stays with the deployer.
#
# Run from the repo root:  bash script/setup-keeper.sh
# Needs: cast, jq, gh (logged in with access to the repo), the bytez3-deployer keystore and its password file.
set -euo pipefail

REPO=Bytez3/erc7540-request-status
RPC=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
ACCOUNT=bytez3-deployer
PW=${PW:-$HOME/.foundry/keystores/bytez3-deployer.password}
VAULT=$(jq -r '.sepolia.demoVault' tracker/src/deployments.generated.json)

[ "$(cast chain-id --rpc-url "$RPC")" = 11155111 ] || { echo "RPC is not Sepolia" >&2; exit 1; }
DEPLOYER=$(cast wallet address --account "$ACCOUNT" --password-file "$PW")
OWNER=$(cast call "$VAULT" "owner()(address)" --rpc-url "$RPC")
[ "${OWNER,,}" = "${DEPLOYER,,}" ] || { echo "vault $VAULT is owned by $OWNER, not the deployer" >&2; exit 1; }

# 1. New keeper key -> GitHub secret. `gh` is run from $HOME because the snap build cannot read /run/media paths.
WALLET=$(cast wallet new --json)
KEEPER=$(jq -r '.[0].address' <<<"$WALLET")
jq -r '.[0].private_key' <<<"$WALLET" | (cd "$HOME" && gh secret set KEEPER_PRIVATE_KEY -R "$REPO")
unset WALLET
(cd "$HOME" && gh variable set DEMO_VAULT -R "$REPO" --body "$VAULT")
echo "keeper wallet: $KEEPER (key stored as GitHub secret KEEPER_PRIVATE_KEY)"
# Show the keeper's live requests behind the tracker's "Try a demo wallet" button.
KEEPER=$(cast to-check-sum-address "$KEEPER")
tmp=$(mktemp) && jq --arg k "$KEEPER" '.sepolia.demoKeeper = $k' tracker/src/deployments.generated.json >"$tmp" \
  && mv "$tmp" tracker/src/deployments.generated.json

# 2. Gas money.
cast send "$KEEPER" --value 0.05ether --account "$ACCOUNT" --password-file "$PW" --rpc-url "$RPC" >/dev/null
echo "funded keeper with 0.05 Sepolia ETH"

# 3. Demo vault ownership (one-step Ownable on the demo vault).
cast send "$VAULT" "transferOwnership(address)" "$KEEPER" --account "$ACCOUNT" --password-file "$PW" --rpc-url "$RPC" >/dev/null
echo "demo vault owner is now: $(cast call "$VAULT" "owner()(address)" --rpc-url "$RPC")"
echo "done. Commit tracker/src/deployments.generated.json, then trigger a first run with:"
echo "  (cd ~ && gh workflow run keeper -R $REPO)"
