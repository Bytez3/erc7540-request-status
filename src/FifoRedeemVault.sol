// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IERC7540Operator, IERC7540Redeem} from "./interfaces/IERC7540.sol";
import {IERC7540RedeemStatus, RequestState} from "./interfaces/IERC7540RequestStatus.sol";

/// @title FifoRedeemVault
/// @author Steven Isaac (@SteOnChain), Bytez3 (https://www.bytez3.com)
/// @notice Reference implementation of ERC-XXXX on an ERC-7540 Vault with synchronous deposits and an
/// asynchronous, strictly first-in-first-out redemption queue processed by a manager in fixed cycles.
///
/// The schedule is enforced, not just reported: shares are only fulfilled inside a processing cycle,
/// cycles open at least `cycleLength` apart, and each cycle fulfills at most `capacityPerCycle` shares.
/// So, until the manager calls `setSchedule`, `earliestClaimableAt` is a guarantee, while
/// `latestClaimableAt` is the manager's commitment if it fulfills every cycle in full and on time.
///
/// Queue accounting uses two cumulative share counters, so every status view is O(1):
///   - each Request occupies the half-open interval [start, start + shares) of `totalQueued`
///   - `totalProcessed` is the prefix of that line that has been fulfilled
/// Per controller, a second interval [controllerStart, controllerStart + shares) over that controller's own
/// requested shares lets claims (which ERC-7540 aggregates per controller) be attributed oldest-first.
///
/// @dev Not audited. Intended to demonstrate the standard, not for production use.
// slither-disable-start timestamp (the processing schedule is defined in wall-clock time by design)
contract FifoRedeemVault is ERC4626, Ownable, IERC7540Redeem, IERC7540RedeemStatus, IERC165 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct Request {
        address controller;
        uint256 shares;
        uint256 start; // position in the global line (`totalQueued` before this Request)
        uint256 controllerStart; // position in the controller's own line (`requestedBy` before this Request)
    }

    /// @dev requestId == index + 1, so requestId 0 is never issued.
    Request[] internal _requests;
    uint256 internal _head; // index of the oldest Request that is not yet fully fulfilled

    uint256 public totalQueued;
    uint256 public totalProcessed;
    uint256 public reservedAssets; // assets owed to Claimable Requests, excluded from totalAssets()

    mapping(address controller => uint256) public requestedBy;
    mapping(address controller => uint256) public claimedBy;
    mapping(address controller => uint256) internal _claimableShares;
    mapping(address controller => uint256) internal _claimableAssets;
    mapping(address controller => mapping(address operator => bool)) public isOperator;

    // Schedule the estimates are derived from. Set by the manager.
    uint64 public cycleLength; // seconds between processing cycles
    uint64 public nextCycleAt; // timestamp of the next processing cycle
    uint256 public capacityPerCycle; // maximum shares fulfilled per cycle, 0 = uncapped (throughput unknown)
    bool public cycleOpen; // a cycle has been opened and `nextCycleAt` has not been reached yet
    uint256 public fulfilledInCycle; // shares fulfilled in the open cycle
    bool public suspended;
    bool public impaired;

    event ScheduleSet(uint64 cycleLength, uint64 nextCycleAt, uint256 capacityPerCycle);
    event RedeemFulfilled(uint256 shares, uint256 assets, uint256 totalProcessed);

    error NotAuthorized();
    error ZeroShares();
    error ExceedsClaimable();
    error IsSuspended();
    error AsyncFlow();
    error CycleNotOpen();
    error StrandedAssets();

    constructor(IERC20 asset_, string memory name_, string memory symbol_, address manager)
        ERC20(name_, symbol_)
        ERC4626(asset_)
        Ownable(manager)
    {}

    // ---------------------------------------------------------------------------------------------
    // ERC-7540 request flow
    // ---------------------------------------------------------------------------------------------

    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId) {
        if (shares == 0) revert ZeroShares();
        if (msg.sender != owner && !isOperator[owner][msg.sender]) _spendAllowance(owner, msg.sender, shares);
        _transfer(owner, address(this), shares);

        _requests.push(
            Request({
                controller: controller, shares: shares, start: totalQueued, controllerStart: requestedBy[controller]
            })
        );
        totalQueued += shares;
        requestedBy[controller] += shares;
        requestId = _requests.length;

        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
    }

    function pendingRedeemRequest(uint256 requestId, address controller) public view returns (uint256) {
        (bool ok, Request memory r) = _get(requestId, controller);
        if (!ok) return 0;
        return r.shares - _filled(r);
    }

    function claimableRedeemRequest(uint256 requestId, address controller) public view returns (uint256) {
        (bool ok, Request memory r) = _get(requestId, controller);
        if (!ok) return 0;
        uint256 claimed = _clamp(claimedBy[controller], r.controllerStart, r.shares);
        return _filled(r) - claimed;
    }

    /// @notice Claims `shares` of the controller's Claimable redemptions, oldest Request first.
    function redeem(uint256 shares, address receiver, address controller) public override returns (uint256 assets) {
        _checkController(controller);
        uint256 cs = _claimableShares[controller];
        if (shares > cs) revert ExceedsClaimable();
        if (shares == 0) return 0;
        // Claiming the last share takes the last asset, so no dust is ever left behind.
        assets = shares == cs ? _claimableAssets[controller] : shares.mulDiv(_claimableAssets[controller], cs);
        _claim(controller, receiver, shares, assets);
    }

    /// @notice Claims `assets` of the controller's Claimable redemptions, oldest Request first.
    function withdraw(uint256 assets, address receiver, address controller) public override returns (uint256 shares) {
        _checkController(controller);
        uint256 ca = _claimableAssets[controller];
        if (assets > ca) revert ExceedsClaimable();
        if (assets == 0) return 0;
        uint256 cs = _claimableShares[controller];
        shares = assets == ca ? cs : assets.mulDiv(cs, ca, Math.Rounding.Ceil);
        // Rounding up must not consume every share while assets remain, which would strand them.
        if (shares == cs && assets != ca) revert StrandedAssets();
        _claim(controller, receiver, shares, assets);
    }

    function maxRedeem(address controller) public view override returns (uint256) {
        return _claimableShares[controller];
    }

    function maxWithdraw(address controller) public view override returns (uint256) {
        return _claimableAssets[controller];
    }

    /// @dev ERC-7540: preview functions for async flows MUST revert.
    function previewRedeem(uint256) public pure override returns (uint256) {
        revert AsyncFlow();
    }

    function previewWithdraw(uint256) public pure override returns (uint256) {
        revert AsyncFlow();
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - reservedAssets;
    }

    /// @notice ERC-7575 share token (the Vault itself).
    function share() external view returns (address) {
        return address(this);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-XXXX request status
    // ---------------------------------------------------------------------------------------------

    function redeemRequestStatus(uint256 requestId, address controller)
        external
        view
        returns (RequestState state, uint256 queuedAhead, uint64 earliestClaimableAt, uint64 latestClaimableAt)
    {
        uint256 pending = pendingRedeemRequest(requestId, controller);
        uint256 claimable = claimableRedeemRequest(requestId, controller);

        if (pending == 0) {
            return (claimable == 0 ? RequestState.None : RequestState.Claimable, 0, 0, 0);
        }

        Request memory r = _requests[requestId - 1];
        queuedAhead = r.start > totalProcessed ? r.start - totalProcessed : 0;

        if (impaired) state = RequestState.Impaired;
        else if (suspended) state = RequestState.Suspended;
        else if (claimable > 0) state = RequestState.PartiallyClaimable;
        else state = RequestState.Pending;

        (earliestClaimableAt, latestClaimableAt) = _estimate(queuedAhead, pending);
    }

    function redeemDelayBounds(uint256 shares) external view returns (uint64 minDelay, uint64 maxDelay) {
        (uint64 earliest, uint64 latest) = _estimate(totalQueued - totalProcessed, shares == 0 ? 1 : shares);
        uint64 nowTs = uint64(block.timestamp);
        minDelay = earliest > nowTs ? earliest - nowTs : 0;
        // slither-disable-next-line incorrect-equality (type(uint64).max is the "unknown" sentinel)
        maxDelay = latest == type(uint64).max ? type(uint64).max : latest - nowTs;
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC7540Operator).interfaceId
            || interfaceId == type(IERC7540Redeem).interfaceId || interfaceId == type(IERC7540RedeemStatus).interfaceId
            || interfaceId == 0x2f0a18c5; // ERC-7575
    }

    // ---------------------------------------------------------------------------------------------
    // Manager
    // ---------------------------------------------------------------------------------------------

    /// @notice Fulfills up to `shares` from the head of the queue at the current exchange rate, touching at
    /// most `maxRequests` Requests so that a queue of many tiny Requests cannot exhaust the block gas limit.
    /// @dev Opens a new cycle if `nextCycleAt` has passed; otherwise continues the open cycle. A cycle can be
    /// worked through in several calls, but never beyond `capacityPerCycle` in total.
    function fulfillRedeem(uint256 shares, uint256 maxRequests) external onlyOwner returns (uint256 fulfilled) {
        if (suspended) revert IsSuspended();

        uint256 limit = totalQueued - totalProcessed;
        if (cycleLength > 0) {
            if (block.timestamp >= nextCycleAt) {
                cycleOpen = true;
                fulfilledInCycle = 0;
                nextCycleAt = uint64(block.timestamp) + cycleLength;
            } else if (!cycleOpen) {
                revert CycleNotOpen();
            }
            if (capacityPerCycle > 0) limit = Math.min(limit, _capacityLeft());
        }

        // One exchange rate for the whole batch (ERC-4626 virtual-offset formula), read once.
        uint256 rateAssets = totalAssets() + 1;
        uint256 rateShares = totalSupply() + 10 ** _decimalsOffset();

        uint256 remaining = Math.min(shares, limit);
        uint256 totalAssetsOut = 0;
        for (uint256 n; remaining > 0 && n < maxRequests; n++) {
            Request storage r = _requests[_head];
            uint256 left = r.start + r.shares - totalProcessed;
            uint256 take = Math.min(left, remaining);

            uint256 assets = take.mulDiv(rateAssets, rateShares);
            totalAssetsOut += assets;
            _claimableShares[r.controller] += take;
            _claimableAssets[r.controller] += assets;

            totalProcessed += take;
            fulfilled += take;
            remaining -= take;
            if (take == left) _head++;
        }

        if (fulfilled > 0) {
            _burn(address(this), fulfilled);
            reservedAssets += totalAssetsOut;
            fulfilledInCycle += fulfilled;
            emit RedeemFulfilled(fulfilled, totalAssetsOut, totalProcessed);
        }
    }

    function setSchedule(uint64 cycleLength_, uint64 nextCycleAt_, uint256 capacityPerCycle_) external onlyOwner {
        cycleLength = cycleLength_;
        nextCycleAt = nextCycleAt_;
        capacityPerCycle = capacityPerCycle_;
        cycleOpen = false; // a new schedule starts with a fresh cycle
        fulfilledInCycle = 0;
        emit ScheduleSet(cycleLength_, nextCycleAt_, capacityPerCycle_);
        _emitVaultWide();
    }

    function setSuspended(bool suspended_) external onlyOwner {
        suspended = suspended_;
        _emitVaultWide();
    }

    function setImpaired(bool impaired_) external onlyOwner {
        impaired = impaired_;
        _emitVaultWide();
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    /// @dev Bounds for the shares at queue offsets [ahead, ahead + pending), counted from the head of the queue.
    /// Unknown values degrade to the loosest true bound (0 / type(uint64).max).
    function _estimate(uint256 ahead, uint256 pending) internal view returns (uint64 earliest, uint64 latest) {
        if (suspended || cycleLength == 0) return (0, type(uint64).max);
        latest = capacityPerCycle == 0 ? type(uint64).max : _toU64(_fillTime(ahead + pending - 1));
        earliest = _toU64(_fillTime(ahead));
    }

    /// @dev Earliest time the share at queue offset `x` can be fulfilled under the enforced schedule, which is
    /// also when it will be fulfilled if every cycle runs on time at full capacity.
    function _fillTime(uint256 x) internal view returns (uint256) {
        bool canOpenNow = block.timestamp >= nextCycleAt;
        // Shares that could still be fulfilled right now, in the open cycle or one that may open this block.
        uint256 availableNow = 0;
        if (canOpenNow) availableNow = capacityPerCycle == 0 ? type(uint256).max : capacityPerCycle;
        else if (cycleOpen) availableNow = capacityPerCycle == 0 ? type(uint256).max : _capacityLeft();
        if (x < availableNow) return block.timestamp;

        uint256 nextOpen = canOpenNow ? block.timestamp + cycleLength : nextCycleAt;
        if (capacityPerCycle == 0) return nextOpen;
        // Rounding down to a whole cycle is intended.
        // slither-disable-start divide-before-multiply
        // forge-lint: disable-next-line(divide-before-multiply)
        return nextOpen + ((x - availableNow) / capacityPerCycle) * cycleLength;
        // slither-disable-end divide-before-multiply
    }

    function _capacityLeft() internal view returns (uint256) {
        return capacityPerCycle > fulfilledInCycle ? capacityPerCycle - fulfilledInCycle : 0;
    }

    function _claim(address controller, address receiver, uint256 shares, uint256 assets) internal {
        _claimableShares[controller] -= shares;
        _claimableAssets[controller] -= assets;
        claimedBy[controller] += shares;
        reservedAssets -= assets;
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function _checkController(address controller) internal view {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) revert NotAuthorized();
    }

    function _get(uint256 requestId, address controller) internal view returns (bool, Request memory r) {
        if (requestId == 0 || requestId > _requests.length) return (false, r);
        r = _requests[requestId - 1];
        return (r.controller == controller, r);
    }

    function _filled(Request memory r) internal view returns (uint256) {
        return _clamp(totalProcessed, r.start, r.shares);
    }

    /// @dev How much of the interval [start, start + len) lies below `x`.
    function _clamp(uint256 x, uint256 start, uint256 len) internal pure returns (uint256) {
        if (x <= start) return 0;
        return Math.min(x - start, len);
    }

    function _toU64(uint256 x) internal pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast) (guarded by the comparison)
        return x >= type(uint64).max ? type(uint64).max : uint64(x);
    }

    function _emitVaultWide() internal {
        RequestState s = impaired ? RequestState.Impaired : suspended ? RequestState.Suspended : RequestState.Pending;
        emit RedeemRequestStatusUpdate(address(0), 0, s, 0, type(uint64).max);
    }
}
// slither-disable-end timestamp
