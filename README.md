# ERC-XXXX: Request Status for ERC-7540 Vaults

Proposed by **[Bytez3](https://www.bytez3.com)** (Steven Isaac, [@SteOnChain](https://github.com/SteOnChain)).

A draft ERC plus a reference implementation. It lets any ERC-7540 async vault report a Request's **state**, **queue position**, and **bounds on when it becomes claimable**.

| Path | What |
|---|---|
| `ERCS/erc-xxxx.md` | The spec, in ethereum/ERCs format. Passes the repo's `eipw` linter. |
| `src/interfaces/IERC7540RequestStatus.sol` | The proposed interfaces (redeem + deposit). |
| `src/interfaces/IERC7540.sol` | The minimal ERC-7540 interfaces it builds on. |
| `src/FifoRedeemVault.sol` | Reference implementation: a FIFO redemption queue with O(1) status views. Not audited. |
| `test/FifoRedeemVault.t.sol` | 15 Foundry tests, including a consistency fuzz test. |
| `MAGICIANS_POST.md` | Draft discussion post for ethereum-magicians.org. |

Interface IDs: `IERC7540RedeemStatus` = `0x2522a9c4`, `IERC7540DepositStatus` = `0x27f6ce85`.

## Build and test

```bash
git clone --recursive https://github.com/Bytez3/erc7540-request-status.git
cd erc7540-request-status
forge test -vv
```

This needs `evm_version = "osaka"`, because OpenZeppelin v5.7 uses the `CLZ` opcode.

## Path to an ERC number

1. Post `MAGICIANS_POST.md` in the ERCs category on ethereum-magicians.org, and put the thread URL in the spec's `discussions-to:` field.
2. Fork `ethereum/ERCs` and add `ERCS/erc-<n>.md` plus `assets/erc-<n>/` (the contracts and tests). Open the PR as "Add ERC: Request Status for ERC-7540 Vaults". The editors confirm the number.
3. Iterate with editor and community review, then move through Review, Last Call and Final. This standard depends only on Final ERCs (165, 7540), so nothing upstream blocks it from reaching Final.
