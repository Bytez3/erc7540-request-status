// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FifoRedeemVault} from "../../src/FifoRedeemVault.sol";
import {RequestState} from "../../src/interfaces/IERC7540RequestStatus.sol";
import {MockAsset} from "../FifoRedeemVault.t.sol";

/// @dev Drives the vault through random sequences of user and manager actions, recording ghost state.
contract Handler is Test {
    FifoRedeemVault public vault;
    MockAsset public asset;
    address public manager;
    address[3] public actors;

    uint256[] public ids;
    mapping(uint256 id => address) public controllerOf;

    /// Latest `earliestClaimableAt` ever reported for a Request. The schedule is never changed by the handler,
    /// so every reported earliest bound must hold: no part of the Request may be fulfilled before it.
    mapping(uint256 id => uint64) public promisedEarliest;
    bool public earliestViolated;

    uint256 public currentTime;
    mapping(bytes32 => uint256) public calls;

    constructor(FifoRedeemVault vault_, MockAsset asset_, address manager_) {
        vault = vault_;
        asset = asset_;
        manager = manager_;
        actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        currentTime = block.timestamp;
    }

    modifier step(bytes32 name) {
        vm.warp(currentTime); // keep time consistent across calls
        calls[name]++;
        _;
        _observe();
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function actorList() external view returns (address[3] memory) {
        return actors;
    }

    // ---------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------

    function deposit(uint256 seed, uint256 amount) external step("deposit") {
        address a = actors[seed % 3];
        amount = bound(amount, 1, 1e24);
        asset.mint(a, amount);
        vm.startPrank(a);
        asset.approve(address(vault), amount);
        vault.deposit(amount, a);
        vm.stopPrank();
    }

    function requestRedeem(uint256 seed, uint256 shares) external step("requestRedeem") {
        address a = actors[seed % 3];
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(a);
        uint256 id = vault.requestRedeem(shares, a, a);
        ids.push(id);
        controllerOf[id] = a;
    }

    function fulfill(uint256 shares, uint256 maxRequests) external step("fulfill") {
        if (vault.suspended()) return;
        if (block.timestamp < vault.nextCycleAt() && !vault.cycleOpen()) return;

        uint256[] memory before = new uint256[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            before[i] = vault.pendingRedeemRequest(ids[i], controllerOf[ids[i]]);
        }

        vm.prank(manager);
        vault.fulfillRedeem(bound(shares, 0, 2e24), bound(maxRequests, 1, 20));

        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            if (vault.pendingRedeemRequest(id, controllerOf[id]) < before[i] && block.timestamp < promisedEarliest[id])
            {
                earliestViolated = true;
            }
        }
    }

    function warp(uint256 dt) external step("warp") {
        currentTime += bound(dt, 0, 2 days);
        vm.warp(currentTime);
    }

    function claimRedeem(uint256 seed, uint256 shares) external step("claimRedeem") {
        address a = actors[seed % 3];
        uint256 max = vault.maxRedeem(a);
        if (max == 0) return;
        vm.prank(a);
        vault.redeem(bound(shares, 1, max), a, a);
    }

    function claimWithdraw(uint256 seed, uint256 assets) external step("claimWithdraw") {
        address a = actors[seed % 3];
        uint256 max = vault.maxWithdraw(a);
        if (max == 0) return;
        vm.prank(a);
        try vault.withdraw(bound(assets, 1, max), a, a) {}
        catch (bytes memory err) {
            // The only acceptable failure is the dust guard.
            assertEq(err.length, 4);
            // forge-lint: disable-next-line(unsafe-typecast) (length checked above)
            assertEq(bytes4(err), FifoRedeemVault.StrandedAssets.selector);
        }
    }

    function donate(uint256 amount) external step("donate") {
        asset.mint(address(vault), bound(amount, 0, 1e22));
    }

    function toggleSuspended() external step("toggleSuspended") {
        bool next = !vault.suspended(); // read before pranking: vm.prank applies to the next external call
        vm.prank(manager);
        vault.setSuspended(next);
    }

    // ---------------------------------------------------------------------------------------------
    // Ghost bookkeeping
    // ---------------------------------------------------------------------------------------------

    function _observe() internal {
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            if (vault.pendingRedeemRequest(id, controllerOf[id]) == 0) continue;
            (,, uint64 e,) = vault.redeemRequestStatus(id, controllerOf[id]);
            if (e > promisedEarliest[id]) promisedEarliest[id] = e;
        }
    }
}

contract FifoRedeemVaultInvariantTest is Test {
    FifoRedeemVault vault;
    MockAsset asset;
    Handler handler;
    address manager = makeAddr("manager");

    function setUp() public {
        vm.warp(1_800_000_000);
        asset = new MockAsset();
        vault = new FifoRedeemVault(IERC20(address(asset)), "Queue Vault", "qV", manager);
        vm.prank(manager);
        vault.setSchedule(1 days, uint64(block.timestamp + 1 days), 500e18);

        handler = new Handler(vault, asset, manager);
        targetContract(address(handler));
    }

    function _sync() internal {
        vm.warp(handler.currentTime());
    }

    /// The vault always holds at least what it owes to Claimable Requests.
    function invariant_solvent() public {
        _sync();
        assertLe(vault.reservedAssets(), asset.balanceOf(address(vault)));
    }

    /// Reserved assets are exactly the sum of what controllers can withdraw, and no dust is stranded.
    function invariant_reservedMatchesClaimable() public {
        _sync();
        address[3] memory actors = handler.actorList();
        uint256 sum;
        for (uint256 i; i < 3; i++) {
            uint256 s = vault.maxRedeem(actors[i]);
            uint256 a = vault.maxWithdraw(actors[i]);
            assertEq(s == 0, a == 0, "claimable shares and assets are zero together");
            sum += a;
        }
        assertEq(sum, vault.reservedAssets());
    }

    /// Escrowed shares, queue counters and per-Request Pending amounts agree.
    function invariant_queueAccounting() public {
        _sync();
        uint256 outstanding = vault.totalQueued() - vault.totalProcessed();
        assertEq(vault.balanceOf(address(vault)), outstanding);

        uint256 pendingSum;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; i++) {
            uint256 id = handler.ids(i);
            pendingSum += vault.pendingRedeemRequest(id, handler.controllerOf(id));
        }
        assertEq(pendingSum, outstanding);
    }

    /// Per-Request Claimable amounts add up to each controller's aggregate `maxRedeem`.
    function invariant_perRequestClaimableSumsToController() public {
        _sync();
        address[3] memory actors = handler.actorList();
        uint256 n = handler.idCount();
        for (uint256 k; k < 3; k++) {
            uint256 sum;
            for (uint256 i; i < n; i++) {
                uint256 id = handler.ids(i);
                if (handler.controllerOf(id) == actors[k]) sum += vault.claimableRedeemRequest(id, actors[k]);
            }
            assertEq(sum, vault.maxRedeem(actors[k]));
        }
    }

    /// Every consistency rule in the specification holds for every Request.
    function invariant_statusConsistency() public {
        _sync();
        uint256 n = handler.idCount();
        uint256 prevAhead;
        for (uint256 i; i < n; i++) {
            uint256 id = handler.ids(i);
            address c = handler.controllerOf(id);
            (RequestState s, uint256 ahead, uint64 e, uint64 l) = vault.redeemRequestStatus(id, c);
            uint256 pending = vault.pendingRedeemRequest(id, c);
            uint256 claimable = vault.claimableRedeemRequest(id, c);

            assertLe(e, l, "earliest <= latest");
            if (pending == 0) {
                assertEq(uint8(s), uint8(claimable > 0 ? RequestState.Claimable : RequestState.None));
                assertEq(ahead, 0);
                assertEq(e, 0);
                assertEq(l, 0);
            } else {
                assertGe(l, block.timestamp, "pending bound not in the past");
                RequestState expected = vault.impaired()
                    ? RequestState.Impaired
                    : vault.suspended()
                        ? RequestState.Suspended
                        : claimable > 0 ? RequestState.PartiallyClaimable : RequestState.Pending;
                assertEq(uint8(s), uint8(expected));
                if (vault.suspended()) {
                    assertEq(e, 0);
                    assertEq(l, type(uint64).max);
                }
                assertGe(ahead, prevAhead, "FIFO: queue position is monotonic in request order");
                prevAhead = ahead;
            }
        }
    }

    /// No share was ever fulfilled before the earliest time the vault had reported for it.
    function invariant_earliestBoundHonoured() public view {
        assertFalse(handler.earliestViolated());
    }

    /// A cycle never fulfills more than its declared capacity.
    function invariant_cycleCapacity() public view {
        assertLe(vault.fulfilledInCycle(), vault.capacityPerCycle());
    }

    function invariant_delayBoundsOrdered() public {
        _sync();
        (uint64 minD, uint64 maxD) = vault.redeemDelayBounds(1e18);
        assertLe(minD, maxD);
    }
}
