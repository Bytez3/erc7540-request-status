# Ethereum Magicians post (draft, not yet posted)

**Category:** ERCs
**Tags:** erc, tokenized-vaults
**Title:** `[Draft ERC] Request Status for ERC-7540 Vaults`

---

Hi all,

I'm Steven from Bytez3. I'd like feedback on a small, read-only extension to [ERC-7540](https://eips.ethereum.org/EIPS/eip-7540) that answers the question every async-vault user asks: **"when do I get my money?"**

### Problem

ERC-7540 tells integrators *how much* of a Request is Pending or Claimable, but not:

- **when** the Pending part will become Claimable,
- **where** the Request sits in the queue,
- whether processing has **stopped** (gated, paused, frozen) or the Vault expects a **loss** (default, slashing).

Every RWA fund, credit vault, and LST/LRT withdrawal queue exposes this differently, or not at all. As a result, wallets show "pending" with no date. Lenders can't accept Pending Requests as collateral, even though ERC-8161 made them transferable, because nobody can bound how long they last. Users find out a queue is gated only when a claim doesn't arrive.

This was raised in the ERC-7540 thread back in 2023. @Amxx asked for "a standard discovery mechanism" for async delays. @joeysantoro said he'd be open to it if it were "either optional or includes a magic value for 'unknown delay'". The 7540 Rationale also notes that "not all Vaults will be able to return a reliable timestamp". This proposal tries to address both points.

The gap is still open. The current ERC-8416 draft (Epoch-Based Fixed-Rate Vault, [PR #2009](https://github.com/ethereum/ERCs/pull/2009)) extends 7540 and states in its Rationale that fulfillment timing is "left to the implementation".

### Proposal

Two ERC-165-detectable interfaces, one for redemptions and one for deposits, following the split used by ERC-7887 and ERC-8161:

```solidity
function redeemRequestStatus(uint256 requestId, address controller)
    external view
    returns (RequestState state, uint256 queuedAhead, uint64 earliestClaimableAt, uint64 latestClaimableAt);

function redeemDelayBounds(uint256 shares) external view returns (uint64 minDelay, uint64 maxDelay);

event RedeemRequestStatusUpdate(address indexed controller, uint256 indexed requestId,
    RequestState state, uint64 earliestClaimableAt, uint64 latestClaimableAt);

enum RequestState { None, Pending, PartiallyClaimable, Claimable, Suspended, Impaired }
```

The key design choice is that **everything is a bound, and "unknown" is the loosest true bound**: `0` for an earliest time, `type(uint64).max` for a latest time, and `type(uint256).max` for the amount queued ahead. A Vault that knows nothing returns `[0, max]` and is still compliant and truthful. A Vault with a fixed unbonding period returns a tight window. A consumer that ignores the convention still gets values that are safe to use.

Other points:

- `queuedAhead` is an *amount*, not an index, so it works for FIFO queues, for pro-rata batches (always `0`), and for Vaults with no queue model.
- The `state` values are tied to the 7540 `pending*`/`claimable*` views by hard consistency rules. `Impaired` takes precedence over `Suspended`.
- A pending Request's `latestClaimableAt` MUST NOT be in the past, so a Vault that misses its schedule has to revise its bound.
- The event is only a SHOULD, and only for transitions into or out of `Suspended`/`Impaired`. It can be emitted at batch or Vault scope, which respects 7540's reason for having no per-user Claimable event.
- It adds view functions and an event only, with no changes to request, fulfillment or claim behavior.

**Draft spec:** https://github.com/Bytez3/erc7540-request-status/blob/main/ERCS/erc-xxxx.md
**Reference implementation:** a FIFO redemption-queue vault where every status view is O(1) gas, using cumulative queue counters with no iteration. It *enforces* its schedule, so its `earliestClaimableAt` is a guarantee rather than an estimate. The repo has 95 tests: unit, fuzz, 8 stateful invariants (including "no share is ever paid before the earliest time the vault reported") and daily tests against live mainnet contracts. Slither reports no findings. https://github.com/Bytez3/erc7540-request-status

### Try it

- **Live demo:** https://bytez3.github.io/erc7540-request-status/ (click "Try a demo wallet"). The tracker reads everything from the chain, with no backend.
- **On Sepolia**, all verified on Sourcify:
  - reference vault `0x598BAB196c1C7B664BA96aF738C456EAB08cE639`, paying out hourly
  - `RequestStatusLens` `0x2cD12AA3b6dD4eD6A8D26FF84D20A8E6c1A9EaB7`, one read-only entry point that answers natively, through an adapter, or through a generic ERC-7540 fallback
- **Queues that predate the standard:** adapters for Lido's stETH withdrawal queue and Ethena's sUSDe cooldown show that the interface fits real queues as they exist today. For Lido, the adapter's on-chain earliest bound is derived from the oracle frame schedule. On a mainnet fork it landed just before Lido's own off-chain estimate, which is what a sound lower bound should do.

### Related work

- **Receipt NFTs for async 4626 vaults** ([thread](https://ethereum-magicians.org/t/erc-tokenizing-withdrawal-claims-for-async-4626-vaults/28529)): optional `claimableAfter(tokenId)`/`claimableBefore(tokenId)` give one exact timestamp per receipt NFT. This proposal keys on 7540's own `(requestId, controller)` and returns a sound earliest/latest *pair* plus state and queue position. The two compose: a receipt could expose these values for its underlying request.
- **ERC-8416** (PR #2009): vault-level epoch `exitWindow`, which is a schedule, not per-request status.
- **ERC-8318** (fund metadata, PR #1845) and **ERC-8391** (asset status, PR #1964): fund- and asset-level lifecycle state. This proposal is request-level.
- **ERC-8161** (transferable requests): complementary. Status is derived from the 7540 `pending*`/`claimable*` values for `(requestId, controller)`, so it follows a request to its new controller after a transfer.
- **ERC-7887** (cancelation): complementary, but the interaction is not specified yet (see open question 5).

### Open questions

1. **Bounds vs. confidence:** should there be an optional flag that says a bound is *enforced* on-chain rather than operator-reported? The reference vault enforces its earliest bound, and lenders would care about the difference.
2. **Should `Impaired` carry a magnitude**, such as an expected recovery ratio in basis points, or is a state flag enough for a first version?
3. **`requestId == 0` vaults:** is it acceptable to report the controller's aggregate Pending amount as a single position, or do people want per-deposit granularity?
4. **Naming:** `RequestStatus` vs. `RequestSchedule` vs. `QueueInfo`?
5. **Cancelation (ERC-7887):** while a cancel is pending, should the Request report its normal state, or should there be a distinct state? A new state would need its own interface ID, since the enum is fixed at six values.
6. **Would vault teams implement this?** I'd especially value input from Centrifuge, LST/LRT withdrawal queues, and tokenized-fund issuers. I'm looking for co-authors.

Thanks!

Steven, [Bytez3](https://www.bytez3.com)
