---
eip: xxxx
title: Request Status for ERC-7540 Vaults
description: Extension of ERC-7540 exposing Request state, queue position and bounds on when a Request becomes Claimable
author: Steven Isaac (@SteOnChain), Bytez3 (@Bytez3)
discussions-to: https://ethereum-magicians.org/t/TBD
status: Draft
type: Standards Track
category: ERC
created: 2026-10-29
requires: 165, 7540
---

## Abstract

This standard extends [ERC-7540](./eip-7540.md) with read-only methods that report, for any asynchronous deposit or redemption Request, its lifecycle state, how much is queued ahead of it, and a lower and upper bound on when it becomes Claimable. It also adds a per-Vault method that bounds the delay of a Request submitted now, and an optional event for status changes that ERC-7540 events cannot express, such as a suspended or impaired queue. Every value is defined as a bound, and an unknown value is expressed as the loosest true bound. A Vault can therefore always comply without returning a false value.

## Motivation

ERC-7540 standardizes the *request now, claim later* flow used by real-world asset funds, private credit, liquid staking and restaking withdrawals, and cross-chain vaults. It tells integrators how much of a Request is Pending and how much is Claimable. It does not tell them **when** the Pending part will become Claimable, **where** the Request sits in a queue, or whether processing has **stopped**.

Each Vault answers those questions with its own method names, its own off-chain API, or not at all. As a result:

- Wallets and portfolio dashboards show a Pending Request with no date.
- Lending markets cannot accept Pending Requests as collateral, because they cannot bound their duration. This is despite [ERC-8161](./eip-8161.md) making Pending Requests transferable.
- Buyers of transferred Requests cannot price what they are buying.
- Aggregators cannot route deposits by how quickly a Vault pays out.
- Users discover a gated or frozen queue only when an expected claim fails to arrive.

The need was raised during the ERC-7540 discussion, which asked for "a standard discovery mechanism" for the duration of async operations. The authors' reply was that they would be open to it if it were "either optional or includes a magic value for 'unknown delay'". ERC-7540's Rationale likewise left out a claim timestamp because "not all Vaults will be able to return a reliable timestamp". This standard takes up both points. It is a separate, optional extension, and it defines unknown values so that any Vault can return them truthfully.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

The definitions of Request, Pending, Claimable, Claimed, `controller` and `requestId` from ERC-7540 apply.

A Vault MAY implement the redeem status interface, the deposit status interface, or both. A Vault implementing either MUST implement the corresponding asynchronous flow of ERC-7540.

### Bounds and unknown values

All time and quantity outputs are **bounds**, not point estimates. When the Vault cannot compute a bound, it MUST return the loosest value that is still true:

| Output                | Meaning                                                                     | Unknown value       |
|-----------------------|-----------------------------------------------------------------------------|---------------------|
| `queuedAhead`         | Amount the Vault will fulfill before any part of this Request              | `type(uint256).max` |
| `earliestClaimableAt` | Unix timestamp before which no additional part of this Request will become Claimable | `0`       |
| `latestClaimableAt`   | Unix timestamp by which the Vault expects the whole Request to be Claimable | `type(uint64).max`  |
| `minDelay`            | Seconds from now before a new Request could become even partially Claimable | `0`                 |
| `maxDelay`            | Seconds from now by which a new Request is expected to be fully Claimable  | `type(uint64).max`  |

`queuedAhead` is denominated in `shares` for redeem Requests and in `assets` for deposit Requests. It MUST be `0` when the Request is next to be fulfilled, or when the Vault fulfills it pro-rata with all other Pending Requests.

### Request state

```solidity
enum RequestState {
    None,               // 0
    Pending,            // 1
    PartiallyClaimable, // 2
    Claimable,          // 3
    Suspended,          // 4
    Impaired            // 5
}
```

Let `pending` and `claimable` be the values the Vault's ERC-7540 `pending*Request` and `claimable*Request` methods return for the same `(requestId, controller)` in the same block. The returned state MUST satisfy:

- `None` if and only if `pending == 0` and `claimable == 0`.
- `Claimable` if and only if `pending == 0` and `claimable > 0`.
- If `pending > 0`, exactly one of the following, in this order of precedence:
  1. `Impaired`: the Vault does not expect to fulfill the Pending amount in full, or expects to fulfill it at a materially worse exchange rate than the one it currently reports (for example after a default or a slashing event).
  2. `Suspended`: the Vault has halted processing of Requests (for example a redemption gate, a pause, or a legal freeze).
  3. `PartiallyClaimable`: `claimable > 0`.
  4. `Pending`: otherwise.

Values of `RequestState` are encoded as `uint8` in the ABI. Vaults MUST NOT return a value greater than `5`, because the Solidity ABI decoder reverts on out-of-range enum values. Any future states will be defined by a separate extension with its own interface identifier.

### Consistency requirements

For every output of `redeemRequestStatus` and `depositRequestStatus`:

- `earliestClaimableAt` MUST be less than or equal to `latestClaimableAt`.
- If the state is `None` or `Claimable`, then `queuedAhead`, `earliestClaimableAt` and `latestClaimableAt` MUST all be `0`.
- If `pending > 0`, then `latestClaimableAt` MUST be greater than or equal to `block.timestamp`. A bound that is already in the past is false, so a Vault that has missed its own schedule MUST return a later bound or `type(uint64).max`.
- If the state is `Suspended`, then `earliestClaimableAt` SHOULD be `0` and `latestClaimableAt` SHOULD be `type(uint64).max`, unless the Vault has a scheduled time at which processing resumes.

For `redeemDelayBounds` and `depositDelayBounds`, `minDelay` MUST be less than or equal to `maxDelay`.

### Methods

#### redeemRequestStatus

Returns the status of the redeem Request discriminated by `requestId` and `controller`. When `requestId == 0`, the Vault reports on the aggregated Pending and Claimable redeem state of `controller`, as defined by ERC-7540.

MUST NOT revert unless the Vault does not support asynchronous redemption.

```yaml
- name: redeemRequestStatus
  type: function
  stateMutability: view

  inputs:
    - name: requestId
      type: uint256
    - name: controller
      type: address

  outputs:
    - name: state
      type: uint8
    - name: queuedAhead
      type: uint256
    - name: earliestClaimableAt
      type: uint64
    - name: latestClaimableAt
      type: uint64
```

#### redeemDelayBounds

Returns bounds on the delay, in seconds, for a redeem Request of `shares` submitted in the current block, given the current queue. This lets integrators compare Vaults before making a Request.

If `requestRedeem(shares, ...)` is called later in the same block and changes nothing else, the `earliestClaimableAt` and `latestClaimableAt` of the new Request SHOULD equal `block.timestamp + minDelay` and `block.timestamp + maxDelay`, with `type(uint64).max` left unchanged.

MUST NOT revert. When `shares == 0`, the Vault SHOULD report bounds for the smallest possible Request.

```yaml
- name: redeemDelayBounds
  type: function
  stateMutability: view

  inputs:
    - name: shares
      type: uint256

  outputs:
    - name: minDelay
      type: uint64
    - name: maxDelay
      type: uint64
```

#### depositRequestStatus

Same as `redeemRequestStatus`, for deposit Requests. `queuedAhead` is denominated in `assets`.

```yaml
- name: depositRequestStatus
  type: function
  stateMutability: view

  inputs:
    - name: requestId
      type: uint256
    - name: controller
      type: address

  outputs:
    - name: state
      type: uint8
    - name: queuedAhead
      type: uint256
    - name: earliestClaimableAt
      type: uint64
    - name: latestClaimableAt
      type: uint64
```

#### depositDelayBounds

Same as `redeemDelayBounds`, for a deposit Request of `assets`.

```yaml
- name: depositDelayBounds
  type: function
  stateMutability: view

  inputs:
    - name: assets
      type: uint256

  outputs:
    - name: minDelay
      type: uint64
    - name: maxDelay
      type: uint64
```

### Events

#### RedeemRequestStatusUpdate

Signals a change in redeem Request status that ERC-7540 events do not show, namely entering or leaving `Suspended` or `Impaired`, or a revised schedule.

The scope of the event is set by its first two parameters:

- `controller != address(0)`: the Request `(requestId, controller)`.
- `controller == address(0)` and `requestId != 0`: every Request with `requestId`, for all controllers.
- `controller == address(0)` and `requestId == 0`: every redeem Request in the Vault. In this case the event's bounds MUST be `0` and `type(uint64).max`, and consumers SHOULD call `redeemRequestStatus` again for the Requests they track.

A Vault SHOULD emit this event, at the narrowest scope that is practical, whenever the state of any Pending Request becomes or stops being `Suspended` or `Impaired`. Emitting it in other cases is OPTIONAL. Consumers MUST treat the view methods, not events, as authoritative.

```yaml
- name: RedeemRequestStatusUpdate
  type: event

  inputs:
    - name: controller
      indexed: true
      type: address
    - name: requestId
      indexed: true
      type: uint256
    - name: state
      indexed: false
      type: uint8
    - name: earliestClaimableAt
      indexed: false
      type: uint64
    - name: latestClaimableAt
      indexed: false
      type: uint64
```

#### DepositRequestStatusUpdate

Same as `RedeemRequestStatusUpdate`, for deposit Requests.

```yaml
- name: DepositRequestStatusUpdate
  type: event

  inputs:
    - name: controller
      indexed: true
      type: address
    - name: requestId
      indexed: true
      type: uint256
    - name: state
      indexed: false
      type: uint8
    - name: earliestClaimableAt
      indexed: false
      type: uint64
    - name: latestClaimableAt
      indexed: false
      type: uint64
```

### Solidity interfaces

```solidity
interface IERC7540RedeemStatus {
    event RedeemRequestStatusUpdate(
        address indexed controller,
        uint256 indexed requestId,
        RequestState state,
        uint64 earliestClaimableAt,
        uint64 latestClaimableAt
    );

    function redeemRequestStatus(uint256 requestId, address controller)
        external view
        returns (RequestState state, uint256 queuedAhead, uint64 earliestClaimableAt, uint64 latestClaimableAt);

    function redeemDelayBounds(uint256 shares) external view returns (uint64 minDelay, uint64 maxDelay);
}

interface IERC7540DepositStatus {
    event DepositRequestStatusUpdate(
        address indexed controller,
        uint256 indexed requestId,
        RequestState state,
        uint64 earliestClaimableAt,
        uint64 latestClaimableAt
    );

    function depositRequestStatus(uint256 requestId, address controller)
        external view
        returns (RequestState state, uint256 queuedAhead, uint64 earliestClaimableAt, uint64 latestClaimableAt);

    function depositDelayBounds(uint256 assets) external view returns (uint64 minDelay, uint64 maxDelay);
}
```

### [ERC-165](./eip-165.md) support

Vaults implementing `IERC7540RedeemStatus` MUST return `true` when `0x2522a9c4` is passed as the `interfaceID` argument of `supportsInterface`.

Vaults implementing `IERC7540DepositStatus` MUST return `true` when `0x27f6ce85` is passed as the `interfaceID` argument of `supportsInterface`.

## Rationale

### Bounds instead of a single estimate

A single "expected time" invites over-reading: wallets display it as a promise, and Vaults with uncertain fulfillment either refuse to return one or return a guess. A pair of bounds can be true even when the Vault knows little. A Vault that knows nothing returns `[0, type(uint64).max]`, which is true and lets consumers tell "unknown" apart from "soon". A Vault with a fixed unbonding period returns a tight pair. This is the answer to ERC-7540's objection that "not all Vaults will be able to return a reliable timestamp": they are not asked to.

### Unknown as the loosest true bound, not a separate flag

The ERC-7540 discussion suggested a magic value for "unknown". Choosing the loosest bound as that magic value means no consumer can misuse it. Code that ignores the convention and treats the value as a real bound still behaves safely, because `0` is a valid lower bound and `type(uint64).max` is a valid upper bound. A separate `known` flag would let careless consumers read a garbage value.

### Queue position as an amount ahead, not an index

Requests have different sizes, so an index ("you are 14th") says little about waiting time. An amount ahead, combined with a Vault's known throughput, gives integrators what they need, and it is well defined for FIFO queues (amount ahead in the line), pro-rata batches (`0`), and Vaults with no queue model (`type(uint256).max`).

### Suspended and Impaired states

These are the two conditions users most need to see before they happen to them, and ERC-7540 has no way to express them. They are kept separate because they mean different things. `Suspended` means "later, at the same value". `Impaired` means "possibly less". Impaired takes precedence because a loss matters more to the holder than a delay.

### A status event at batch or Vault scope

ERC-7540 does not include a Claimable event, because emitting per-user events for batched fulfillment is impractical. This standard keeps that constraint. Its event is a SHOULD, is required only for the rare transitions into and out of `Suspended` and `Impaired`, and can be emitted once for a whole `requestId` or a whole Vault.

### Timestamps rather than block numbers

The delays that matter here (settlement cycles, unbonding periods, notice periods) are defined in wall-clock time, are often driven by off-chain processes, and have to compare across chains with different block times. `uint64` seconds covers any realistic horizon.

### Separate deposit and redeem interfaces

ERC-7540 lets Vaults be asynchronous in only one direction, and [ERC-7887](./eip-7887.md) and [ERC-8161](./eip-8161.md) split their interfaces the same way. Following that pattern lets integrators detect support per direction.

### No guarantees and no enforcement

This standard is a reporting interface. It does not change Request, fulfillment or claim behavior, and it gives no on-chain recourse if a bound is missed. Enforceable commitments, such as a Vault that bonds collateral against its `latestClaimableAt`, can be built on top of it.

## Backwards Compatibility

The interface is fully backwards compatible with ERC-7540. It adds only `view` methods and events, and does not change existing behavior. Integrators detect support through ERC-165. Vaults that do not implement it behave exactly as before.

## Test Cases

The reference implementation includes a Foundry test suite covering:

- `None` for unknown `requestId` and for a mismatched `controller`.
- Queue position and bounds for Requests that straddle processing cycles.
- `PartiallyClaimable` after a partial fulfillment, and claims attributed oldest-first within a `controller`.
- Bounds that never fall into the past when the Vault misses a cycle.
- An open upper bound when throughput is unknown.
- `Suspended` returning the loosest bounds, plus emission of the Vault-wide event.
- Precedence of `Impaired` over `Suspended`, and `Claimable` taking precedence over both once `pending == 0`.
- `redeemDelayBounds` agreeing with `redeemRequestStatus` for a Request made in the same block.
- A fuzz test of the consistency requirements over arbitrary Request sizes, fulfillment amounts and elapsed time.

## Reference Implementation

See [`FifoRedeemVault.sol`](../assets/erc-xxxx/src/FifoRedeemVault.sol). It is an ERC-7540 Vault with synchronous deposits and a strictly FIFO redemption queue, which a manager processes in fixed cycles with a declared per-cycle capacity.

The queue is represented by two cumulative counters. Each Request occupies the half-open interval `[start, start + shares)` of all shares ever queued, and `totalProcessed` is the fulfilled prefix of that line. A Request's Pending amount, its `queuedAhead`, and the cycles in which its first and last shares will be fulfilled then follow arithmetically, so every status method runs in constant gas regardless of queue length:

```solidity
queuedAhead          = max(start - totalProcessed, 0);
earliestClaimableAt  = nextCycle + (queuedAhead / capacity) * cycleLength;
latestClaimableAt    = nextCycle + ((queuedAhead + pending - 1) / capacity) * cycleLength;
```

where `nextCycle = max(nextCycleAt, block.timestamp)`. When capacity is unknown, `latestClaimableAt` is `type(uint64).max`. When the Vault is suspended, the bounds are `[0, type(uint64).max]`.

## Security Considerations

### Bounds are self-reported

The Vault reports every value in this standard about itself, and a malicious or careless Vault can report tighter bounds than it will meet. Consumers that rely on the bounds for value, such as lenders accepting Pending Requests as collateral or buyers of transferred Requests, MUST assess the Vault's trustworthiness just as they would its exchange rate. They SHOULD prefer Vaults whose bounds are derived on-chain from enforced parameters, such as a fixed unbonding period, over bounds set by an operator.

### Missed bounds

A missed `latestClaimableAt` is not a violation that can be detected on-chain, because the requirement that the bound not lie in the past forces the Vault to revise it. Consumers that care about missed deadlines SHOULD record the bounds they observed and compare them later.

### State can change between read and use

Like ERC-7540's Pending and Claimable views, these values describe the current block only. A Request can become `Suspended` or `Impaired` immediately after a read. Contracts SHOULD NOT gate irreversible actions on a single read without accounting for this.

### Front-running on announced impairment

Moving to `Impaired` signals a loss before it is realized. Holders who can still exit synchronously, or who can transfer Pending Requests (ERC-8161), may front-run the event. Vaults SHOULD apply the impairment to exchange rates and transferability in the same transaction in which they report it.

### Gas

The status methods are `view` and are expected to be called off-chain, but they may also be called on-chain by lending or routing contracts. Implementations SHOULD keep them constant-gas. The reference implementation shows that a FIFO queue does not need iteration to answer them.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
