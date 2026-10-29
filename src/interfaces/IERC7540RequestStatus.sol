// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title ERC-XXXX: Request Status for ERC-7540 Vaults
/// @author Steven Isaac (@SteOnChain), Bytez3 (https://www.bytez3.com)
/// @notice Read-only status, queue position and settlement-time bounds for ERC-7540 Requests.
///
/// Every value is a *bound*, and "unknown" is always expressed as the loosest true bound:
///   - unknown `earliestClaimableAt`  -> 0
///   - unknown `latestClaimableAt`    -> type(uint64).max
///   - unknown `queuedAhead`          -> type(uint256).max
///   - unknown `minDelay`             -> 0
///   - unknown `maxDelay`             -> type(uint64).max
/// A Vault that knows nothing can therefore always comply without returning a false value.

/// @dev Shared state enum. Values are stable and MUST NOT be reordered.
enum RequestState {
    None, //                0: no Pending or Claimable amount for (requestId, controller)
    Pending, //             1: Pending > 0, Claimable == 0, processing is proceeding normally
    PartiallyClaimable, //  2: Pending > 0, Claimable > 0
    Claimable, //           3: Pending == 0, Claimable > 0
    Suspended, //           4: Pending > 0, the Vault has halted processing (gate, pause, freeze)
    Impaired //             5: Pending > 0, the Vault does not expect to fulfill in full or at fair value
}

interface IERC7540RedeemStatus {
    /// @notice Emitted when the status of one or more redeem Requests changes in a way not
    /// observable from ERC-7540 events (suspension, impairment, or a revised schedule).
    /// @dev `controller == address(0)` means the update applies to every controller with `requestId`.
    /// `controller == address(0) && requestId == 0` means every redeem Request in the Vault; consumers SHOULD
    /// re-query `redeemRequestStatus` for the Requests they track, and the bounds in the event are (0, max).
    event RedeemRequestStatusUpdate(
        address indexed controller,
        uint256 indexed requestId,
        RequestState state,
        uint64 earliestClaimableAt,
        uint64 latestClaimableAt
    );

    /// @notice Status of the redeem Request discriminated by (`requestId`, `controller`).
    /// @return state                Current state, consistent with `pendingRedeemRequest` / `claimableRedeemRequest`.
    /// @return queuedAhead          Shares the Vault will fulfill before any part of this Request. 0 when next in line
    ///                              or when fulfilled pro-rata with everything else Pending.
    /// @return earliestClaimableAt  Timestamp before which no additional part of this Request will become Claimable.
    /// @return latestClaimableAt    Timestamp by which the Vault expects all of this Request to be Claimable.
    function redeemRequestStatus(uint256 requestId, address controller)
        external
        view
        returns (RequestState state, uint256 queuedAhead, uint64 earliestClaimableAt, uint64 latestClaimableAt);

    /// @notice Delay bounds, in seconds, for a redeem Request of `shares` submitted in the current block.
    function redeemDelayBounds(uint256 shares) external view returns (uint64 minDelay, uint64 maxDelay);
}

interface IERC7540DepositStatus {
    /// @dev Same semantics as `RedeemRequestStatusUpdate`, for deposit Requests.
    event DepositRequestStatusUpdate(
        address indexed controller,
        uint256 indexed requestId,
        RequestState state,
        uint64 earliestClaimableAt,
        uint64 latestClaimableAt
    );

    /// @dev `queuedAhead` is denominated in assets for deposit Requests.
    function depositRequestStatus(uint256 requestId, address controller)
        external
        view
        returns (RequestState state, uint256 queuedAhead, uint64 earliestClaimableAt, uint64 latestClaimableAt);

    /// @notice Delay bounds, in seconds, for a deposit Request of `assets` submitted in the current block.
    function depositDelayBounds(uint256 assets) external view returns (uint64 minDelay, uint64 maxDelay);
}
