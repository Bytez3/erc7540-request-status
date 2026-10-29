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
/// Queue accounting uses two cumulative share counters, so every status view is O(1):
///   - each Request occupies the half-open interval [start, start + shares) of `totalQueued`
///   - `totalProcessed` is the prefix of that line that has been fulfilled
/// Per controller, a second interval [controllerStart, controllerStart + shares) over that controller's own
/// requested shares lets claims (which ERC-7540 aggregates per controller) be attributed oldest-first.
///
/// @dev Not audited. Intended to demonstrate the standard, not for production use.
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
    uint256 public capacityPerCycle; // shares the manager expects to fulfill per cycle, 0 = unknown
    bool public suspended;
    bool public impaired;

    error NotAuthorized();
    error ZeroShares();
    error ExceedsClaimable();
    error IsSuspended();
    error AsyncFlow();

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

        _requests.push(Request(controller, shares, totalQueued, requestedBy[controller]));
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
        assets = shares.mulDiv(_claimableAssets[controller], cs, Math.Rounding.Floor);
        _claim(controller, receiver, shares, assets);
    }

    /// @notice Claims `assets` of the controller's Claimable redemptions, oldest Request first.
    function withdraw(uint256 assets, address receiver, address controller) public override returns (uint256 shares) {
        _checkController(controller);
        uint256 ca = _claimableAssets[controller];
        if (assets > ca) revert ExceedsClaimable();
        shares = assets.mulDiv(_claimableShares[controller], ca, Math.Rounding.Ceil);
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

    /// @notice Fulfills up to `shares` from the head of the queue at the current exchange rate.
    function fulfillRedeem(uint256 shares) external onlyOwner returns (uint256 fulfilled) {
        if (suspended) revert IsSuspended();
        uint256 remaining = Math.min(shares, totalQueued - totalProcessed);

        while (remaining > 0) {
            Request storage r = _requests[_head];
            uint256 left = r.start + r.shares - totalProcessed;
            uint256 take = Math.min(left, remaining);

            uint256 assets = _convertToAssets(take, Math.Rounding.Floor);
            _burn(address(this), take);
            reservedAssets += assets;
            _claimableShares[r.controller] += take;
            _claimableAssets[r.controller] += assets;

            totalProcessed += take;
            fulfilled += take;
            remaining -= take;
            if (take == left) _head++;
        }

        if (nextCycleAt <= block.timestamp && cycleLength > 0) {
            nextCycleAt = uint64(block.timestamp) + cycleLength;
        }
    }

    function setSchedule(uint64 cycleLength_, uint64 nextCycleAt_, uint256 capacityPerCycle_) external onlyOwner {
        cycleLength = cycleLength_;
        nextCycleAt = nextCycleAt_;
        capacityPerCycle = capacityPerCycle_;
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

    /// @dev Cycle-based bounds. Unknown values degrade to the loosest true bound (0 / type(uint64).max).
    function _estimate(uint256 ahead, uint256 pending) internal view returns (uint64 earliest, uint64 latest) {
        if (suspended || cycleLength == 0) return (0, type(uint64).max);

        // An overdue cycle can run at any moment, so the next cycle is never earlier than now.
        uint256 next = Math.max(nextCycleAt, block.timestamp);
        if (capacityPerCycle == 0) return (_toU64(next), type(uint64).max);

        uint256 firstCycle = ahead / capacityPerCycle;
        uint256 lastCycle = (ahead + pending - 1) / capacityPerCycle;
        earliest = _toU64(next + firstCycle * cycleLength);
        latest = _toU64(next + lastCycle * cycleLength);
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
        return x >= type(uint64).max ? type(uint64).max : uint64(x);
    }

    function _emitVaultWide() internal {
        RequestState s = impaired ? RequestState.Impaired : suspended ? RequestState.Suspended : RequestState.Pending;
        emit RedeemRequestStatusUpdate(address(0), 0, s, 0, type(uint64).max);
    }
}
