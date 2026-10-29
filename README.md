# ERC-XXXX: Request Status for ERC-7540 Vaults

[![test](https://github.com/Bytez3/erc7540-request-status/actions/workflows/test.yml/badge.svg)](https://github.com/Bytez3/erc7540-request-status/actions/workflows/test.yml)

Proposed by **[Bytez3](https://www.bytez3.com)** (Steven Isaac, [@SteOnChain](https://github.com/SteOnChain)).

A draft ERC plus a reference implementation. It lets any ERC-7540 async vault report a Request's **state**, **queue position**, and **bounds on when it becomes claimable**.

| Path | What |
|---|---|
| `ERCS/erc-xxxx.md` | The spec, in ethereum/ERCs format. Passes the repo's `eipw` linter. |
| `src/interfaces/IERC7540RequestStatus.sol` | The proposed interfaces (redeem + deposit). |
| `src/interfaces/IERC7540.sol` | The minimal ERC-7540 interfaces it builds on. |
| `src/FifoRedeemVault.sol` | Reference implementation: a FIFO redemption queue with O(1) status views and an enforced processing schedule. Not audited. |
| `test/FifoRedeemVault.t.sol` | 45 unit and fuzz tests. |
| `test/invariant/` | 8 stateful invariants, including "no share is paid before its reported earliest time". |
| `src/lens/RequestStatusLens.sol` | Read-only entry point: answers status for any queue, natively, through an adapter, or through the generic ERC-7540 fallback. |
| `src/lens/adapters/` | Adapters for Lido stETH withdrawals, the Ethena sUSDe cooldown, and any ERC-7540 vault. Tested against live mainnet on a fork. |
| `tracker/` | **Bytez3 Queue Tracker**: a static web app that answers "when do I get my money?" for a wallet. |
| `script/` | `DeployLens`, `DeployDemo` (testnet demo vault), `Keeper` (advances the demo queue). |
| `docs/DEPLOY.md` | Step-by-step deploy runbook. |
| `docs/research/queue-interfaces.md` | Verified interfaces and addresses of the live queues the adapters read. |
| `MAGICIANS_POST.md` | Draft discussion post for ethereum-magicians.org. |

Interface IDs: `IERC7540RedeemStatus` = `0x2522a9c4`, `IERC7540DepositStatus` = `0x27f6ce85`.

## Build and test

```bash
git clone --recursive https://github.com/Bytez3/erc7540-request-status.git
cd erc7540-request-status
forge test -vv
```

This needs `evm_version = "osaka"`, because OpenZeppelin v5.7 uses the `CLZ` opcode.

Static analysis (Slither reports 0 findings; the three intentional patterns are annotated in the source):

```bash
slither src/FifoRedeemVault.sol --filter-paths "lib/|test/" --exclude-informational
```

CI runs formatting, linting, build, the full test suite, Slither and the tracker's tests and build on every push. A separate daily workflow runs the adapters against live mainnet:

```bash
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-path "test/fork/*"
```

## Queue Tracker

```bash
cd tracker && npm ci && npm run dev
```

The tracker reads everything live from the chain through `RequestStatusLens`. It needs no wallet connection,
server or database. See `docs/DEPLOY.md` for deployment.

## Path to an ERC number

1. Post `MAGICIANS_POST.md` in the ERCs category on ethereum-magicians.org, and put the thread URL in the spec's `discussions-to:` field.
2. Fork `ethereum/ERCs` and add `ERCS/erc-<n>.md` plus `assets/erc-<n>/` (the contracts and tests). Open the PR as "Add ERC: Request Status for ERC-7540 Vaults". The editors confirm the number.
3. Iterate with editor and community review, then move through Review, Last Call and Final. This standard depends only on Final ERCs (165, 7540), so nothing upstream blocks it from reaching Final.
