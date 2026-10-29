// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {RequestState} from "../../interfaces/IERC7540RequestStatus.sol";
import {IRequestStatusAdapter} from "../IRequestStatusAdapter.sol";

/// @dev Verified against lidofinance/core WithdrawalQueueBase / WithdrawalQueue / WithdrawalQueueERC721.
interface ILidoWithdrawalQueue {
    struct WithdrawalRequestStatus {
        // forge-lint: disable-next-line(mixed-case-variable) (Lido's own field name)
        uint256 amountOfStETH;
        uint256 amountOfShares;
        address owner;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }

    function getLastRequestId() external view returns (uint256);
    function getLastFinalizedRequestId() external view returns (uint256);
    function getWithdrawalStatus(uint256[] calldata requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses);
    function getWithdrawalRequests(address owner) external view returns (uint256[] memory requestsIds);
    function isPaused() external view returns (bool);
    function getResumeSinceTimestamp() external view returns (uint256);
    function isBunkerModeActive() external view returns (bool);
}

/// @dev Verified against lidofinance/core HashConsensus.
interface ILidoHashConsensus {
    function getChainConfig() external view returns (uint256 slotsPerEpoch, uint256 secondsPerSlot, uint256 genesisTime);
    function getFrameConfig()
        external
        view
        returns (uint256 initialEpoch, uint256 epochsPerFrame, uint256 fastLaneLengthSlots);
    function getCurrentFrame() external view returns (uint256 refSlot, uint256 reportProcessingDeadlineSlot);
}

/// @dev Verified against lidofinance/core BaseOracle (AccountingOracle).
interface ILidoAccountingOracle {
    function getLastProcessingRefSlot() external view returns (uint256);
}

/// @title LidoWithdrawalQueueAdapter
/// @author Steven Isaac (@SteOnChain), Bytez3 (https://www.bytez3.com)
/// @notice ERC-XXXX status for Lido's stETH withdrawal queue (unstETH NFTs). `requestId` is the NFT id and
/// `controller` its owner. Amounts are in stETH.
///
/// Bounds:
///   - earliest: Lido finalizes requests only in the daily AccountingOracle report, and only requests at least
///     `requestTimestampMargin` seconds older than the report's reference slot. So a request cannot be finalized
///     before the reference slot of the first unprocessed frame that satisfies that margin. This is a true lower bound.
///   - latest: finalization also depends on ETH availability (buffer, rewards, validator exits). Nothing on-chain
///     bounds it, so latest is reported as unknown (type(uint64).max).
///
/// State: a paused queue is `Suspended` (Lido's `finalize` requires the queue to be resumed); bunker mode is
/// `Impaired`, because requests may then be finalized at a discounted rate.
///
/// @dev `requestTimestampMargin` mirrors OracleReportSanityChecker's limit at deploy time. If Lido lowers it, the
/// earliest bound could become later than reality: redeploy the adapter with the new value in that case.
// slither-disable-start timestamp (reporting payout times is the purpose of this adapter)
contract LidoWithdrawalQueueAdapter is IRequestStatusAdapter {
    // forge-lint: disable-start(screaming-snake-case-immutable) (keeps the public getters readable)
    ILidoHashConsensus public immutable hashConsensus;
    ILidoAccountingOracle public immutable accountingOracle;
    uint256 public immutable requestTimestampMargin;
    // forge-lint: disable-end(screaming-snake-case-immutable)

    /// @notice Beyond this many unfinalized requests ahead, `queuedAhead` is reported as unknown to bound gas.
    uint256 public constant MAX_SCAN = 1_000;

    constructor(ILidoHashConsensus hashConsensus_, ILidoAccountingOracle accountingOracle_, uint256 margin) {
        hashConsensus = hashConsensus_;
        accountingOracle = accountingOracle_;
        requestTimestampMargin = margin;
    }

    function redeemRequestStatus(address vault, uint256 requestId, address controller)
        external
        view
        returns (RequestState state, uint256 queuedAhead, uint64 earliestClaimableAt, uint64 latestClaimableAt)
    {
        ILidoWithdrawalQueue queue = ILidoWithdrawalQueue(vault);
        if (requestId == 0 || requestId > queue.getLastRequestId()) return (RequestState.None, 0, 0, 0);

        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory st = queue.getWithdrawalStatus(ids)[0];

        if (st.owner != controller || st.isClaimed) return (RequestState.None, 0, 0, 0);
        if (st.isFinalized) return (RequestState.Claimable, 0, 0, 0);

        queuedAhead = _stethAhead(queue, requestId);
        latestClaimableAt = type(uint64).max;

        if (queue.isBunkerModeActive()) {
            state = RequestState.Impaired;
            earliestClaimableAt = _earliestFinalization(st.timestamp);
        } else if (queue.isPaused()) {
            state = RequestState.Suspended;
            uint256 resume = queue.getResumeSinceTimestamp();
            // A scheduled resumption is a true lower bound; an indefinite pause gives none.
            earliestClaimableAt =
                resume >= type(uint64).max ? 0 : _max(_u64(resume), _earliestFinalization(st.timestamp));
        } else {
            state = RequestState.Pending;
            earliestClaimableAt = _earliestFinalization(st.timestamp);
        }
    }

    function requestIdsOf(address vault, address controller) external view returns (uint256[] memory) {
        return ILidoWithdrawalQueue(vault).getWithdrawalRequests(controller);
    }

    /// @dev Sum of stETH in unfinalized requests strictly ahead of `requestId`.
    function _stethAhead(ILidoWithdrawalQueue queue, uint256 requestId) internal view returns (uint256 sum) {
        uint256 firstUnfinalized = queue.getLastFinalizedRequestId() + 1;
        uint256 n = requestId - firstUnfinalized;
        if (n == 0) return 0;
        if (n > MAX_SCAN) return type(uint256).max;

        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = firstUnfinalized + i;
        }
        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory sts = queue.getWithdrawalStatus(ids);
        for (uint256 i; i < n; i++) {
            sum += sts[i].amountOfStETH;
        }
    }

    /// @dev Reference-slot time of the first unprocessed oracle frame in which a request made at `requestedAt`
    /// is old enough to be finalized, never earlier than now.
    function _earliestFinalization(uint256 requestedAt) internal view returns (uint64) {
        (uint256 slotsPerEpoch, uint256 secondsPerSlot, uint256 genesisTime) = hashConsensus.getChainConfig();
        // Only some fields of Lido's oracle config are needed.
        // slither-disable-next-line unused-return
        (, uint256 epochsPerFrame,) = hashConsensus.getFrameConfig();
        // slither-disable-next-line unused-return
        (uint256 refSlot,) = hashConsensus.getCurrentFrame();

        uint256 frameSeconds = epochsPerFrame * slotsPerEpoch * secondsPerSlot;
        uint256 refTime = genesisTime + refSlot * secondsPerSlot;
        // This frame's report has already been processed, so the next chance is the next frame.
        if (accountingOracle.getLastProcessingRefSlot() >= refSlot) refTime += frameSeconds;

        uint256 eligibleFrom = requestedAt + requestTimestampMargin;
        if (refTime < eligibleFrom) {
            // Round up to a whole number of frames, which is intended.
            // slither-disable-start divide-before-multiply
            // forge-lint: disable-next-line(divide-before-multiply)
            refTime += ((eligibleFrom - refTime + frameSeconds - 1) / frameSeconds) * frameSeconds;
            // slither-disable-end divide-before-multiply
        }
        return _max(_u64(refTime), uint64(block.timestamp));
    }

    function _max(uint64 a, uint64 b) internal pure returns (uint64) {
        return a > b ? a : b;
    }

    function _u64(uint256 x) internal pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast) (guarded by the comparison)
        return x >= type(uint64).max ? type(uint64).max : uint64(x);
    }
}
// slither-disable-end timestamp
