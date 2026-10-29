// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IERC7540Redeem} from "../../interfaces/IERC7540.sol";
import {RequestState} from "../../interfaces/IERC7540RequestStatus.sol";
import {IRequestStatusAdapter} from "../IRequestStatusAdapter.sol";

/// @title ERC7540Adapter
/// @author Steven Isaac (@SteOnChain), Bytez3 (https://www.bytez3.com)
/// @notice Generic fallback for any ERC-7540 Vault that does not implement ERC-XXXX.
/// @dev ERC-7540 exposes only Pending and Claimable amounts, so this adapter reports the state those imply and
/// the loosest true bounds for everything else: queue position unknown, earliest 0, latest type(uint64).max.
/// It cannot observe a suspended or impaired queue, so it never reports `Suspended` or `Impaired`.
contract ERC7540Adapter is IRequestStatusAdapter {
    function redeemRequestStatus(address vault, uint256 requestId, address controller)
        external
        view
        returns (RequestState state, uint256 queuedAhead, uint64 earliestClaimableAt, uint64 latestClaimableAt)
    {
        uint256 pending = IERC7540Redeem(vault).pendingRedeemRequest(requestId, controller);
        uint256 claimable = IERC7540Redeem(vault).claimableRedeemRequest(requestId, controller);

        if (pending == 0) {
            return (claimable == 0 ? RequestState.None : RequestState.Claimable, 0, 0, 0);
        }
        state = claimable > 0 ? RequestState.PartiallyClaimable : RequestState.Pending;
        return (state, type(uint256).max, 0, type(uint64).max);
    }

    /// @dev ERC-7540 has no enumeration. Vaults using `requestId == 0` aggregate per controller, so 0 is always
    /// a valid id to query; other ids must be discovered from `RedeemRequest` events.
    function requestIdsOf(address, address) external pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
    }
}
