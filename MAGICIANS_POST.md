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
**Reference implementation:** a FIFO redemption-queue vault where every status view is O(1) gas, using cumulative queue counters with no iteration. It *enforces* its schedule, so its `earliestClaimableAt` is a guarantee rather than an estimate. It has 45 unit/fuzz tests and 8 stateful invariants, including "no share is ever paid before the earliest time the vault reported", and Slither reports no findings. https://github.com/Bytez3/erc7540-request-status

### Open questions

1. **Bounds vs. confidence:** should there be an optional flag that says a bound is *enforced* on-chain rather than operator-reported? The reference vault enforces its earliest bound, and lenders would care about the difference.
2. **Should `Impaired` carry a magnitude**, such as an expected recovery ratio in basis points, or is a state flag enough for a first version?
3. **`requestId == 0` vaults:** is it acceptable to report the controller's aggregate Pending amount as a single position, or do people want per-deposit granularity?
4. **Naming:** `RequestStatus` vs. `RequestSchedule` vs. `QueueInfo`?
5. **Would vault teams implement this?** I'd especially value input from Centrifuge, LST/LRT withdrawal queues, and tokenized-fund issuers. I'm looking for co-authors.

Thanks!

Steven, [Bytez3](https://www.bytez3.com)
