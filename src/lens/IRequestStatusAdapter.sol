// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {RequestState} from "../interfaces/IERC7540RequestStatus.sol";

/// @title IRequestStatusAdapter
/// @author Steven Isaac (@SteOnChain), Bytez3 (https://www.bytez3.com)
/// @notice Reports ERC-XXXX redeem Request status on behalf of a queue that does not implement it itself.
/// @dev Outputs follow the ERC-XXXX semantics: every value is a bound, and unknown values are the loosest
/// true bound (0 for earliest, type(uint64).max for latest, type(uint256).max for queuedAhead).
interface IRequestStatusAdapter {
    /// @notice Same outputs as `IERC7540RedeemStatus.redeemRequestStatus`, for the queue at `vault`.
    function redeemRequestStatus(address vault, uint256 requestId, address controller)
        external
        view
        returns (RequestState state, uint256 queuedAhead, uint64 earliestClaimableAt, uint64 latestClaimableAt);

    /// @notice Request ids that `controller` has open at `vault`, where the adapter can enumerate them on-chain.
    /// @dev An empty array means "cannot enumerate"; callers then discover ids off-chain, e.g. from events.
    function requestIdsOf(address vault, address controller) external view returns (uint256[] memory);
}
