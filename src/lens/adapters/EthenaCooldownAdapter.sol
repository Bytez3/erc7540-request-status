// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {RequestState} from "../../interfaces/IERC7540RequestStatus.sol";
import {IRequestStatusAdapter} from "../IRequestStatusAdapter.sol";

/// @dev Verified against Ethena's StakedUSDeV2 (sUSDe) source.
interface IStakedUSDeCooldown {
    function cooldowns(address owner) external view returns (uint104 cooldownEnd, uint152 underlyingAmount);
    function cooldownDuration() external view returns (uint24);
}

/// @title EthenaCooldownAdapter
/// @author Steven Isaac (@SteOnChain), Bytez3 (https://www.bytez3.com)
/// @notice ERC-XXXX status for Ethena's sUSDe unstaking cooldown. Each address has one aggregated cooldown, so
/// requests use `requestId == 0` (as ERC-7540 does for per-controller aggregation). Amounts are in USDe.
///
/// There is no queue: each cooldown ends at a fixed time, so `queuedAhead` is 0 and the earliest and latest
/// claimable times are both `cooldownEnd`. If Ethena sets the cooldown duration to 0, every cooldown becomes
/// claimable immediately, which this adapter reflects.
// slither-disable-start timestamp (reporting payout times is the purpose of this adapter)
contract EthenaCooldownAdapter is IRequestStatusAdapter {
    function redeemRequestStatus(address vault, uint256 requestId, address controller)
        external
        view
        returns (RequestState state, uint256 queuedAhead, uint64 earliestClaimableAt, uint64 latestClaimableAt)
    {
        if (requestId != 0) return (RequestState.None, 0, 0, 0);
        IStakedUSDeCooldown staked = IStakedUSDeCooldown(vault);
        (uint104 end, uint152 amount) = staked.cooldowns(controller);

        if (amount == 0) return (RequestState.None, 0, 0, 0);
        if (staked.cooldownDuration() == 0 || block.timestamp >= end) return (RequestState.Claimable, 0, 0, 0);

        // forge-lint: disable-next-line(unsafe-typecast) (cooldownEnd is now + at most 90 days)
        uint64 t = uint64(end);
        return (RequestState.Pending, 0, t, t);
    }

    function requestIdsOf(address, address) external pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
    }
}
// slither-disable-end timestamp
