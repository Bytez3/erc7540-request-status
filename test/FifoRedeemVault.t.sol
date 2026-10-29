// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {FifoRedeemVault} from "../src/FifoRedeemVault.sol";
import {IERC7540Operator, IERC7540Redeem} from "../src/interfaces/IERC7540.sol";
import {IERC7540RedeemStatus, IERC7540DepositStatus, RequestState} from "../src/interfaces/IERC7540RequestStatus.sol";

contract MockAsset is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FifoRedeemVaultTest is Test {
    MockAsset asset;
    FifoRedeemVault vault;

    address manager = makeAddr("manager");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeper = makeAddr("keeper");

    uint64 constant CYCLE = 1 days;
    uint256 constant CAP = 500e18;
    uint256 constant ALL = type(uint256).max;
    uint64 t0;

    function setUp() public {
        vm.warp(1_800_000_000);
        t0 = uint64(block.timestamp);
        asset = new MockAsset();
        vault = new FifoRedeemVault(IERC20(address(asset)), "Queue Vault", "qV", manager);

        _deposit(alice, 1_000e18);
        _deposit(bob, 1_000e18);
        _deposit(carol, 1_000e18);

        // Daily cycles, the first opening tomorrow, at most 500 shares per cycle.
        vm.prank(manager);
        vault.setSchedule(CYCLE, t0 + CYCLE, CAP);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _deposit(address who, uint256 amount) internal {
        asset.mint(who, amount);
        vm.startPrank(who);
        asset.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _request(address who, uint256 shares) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.requestRedeem(shares, who, who);
    }

    function _fulfill(uint256 shares) internal returns (uint256) {
        vm.prank(manager);
        return vault.fulfillRedeem(shares, ALL);
    }

    function _status(uint256 id, address who)
        internal
        view
        returns (RequestState s, uint256 ahead, uint64 earliest, uint64 latest)
    {
        return vault.redeemRequestStatus(id, who);
    }

    function _state(uint256 id, address who) internal view returns (RequestState s) {
        (s,,,) = vault.redeemRequestStatus(id, who);
    }

    // ---------------------------------------------------------------------------------------------
    // Interface detection
    // ---------------------------------------------------------------------------------------------

    function test_interfaceIds() public view {
        // Values published in ERC-7540.
        assertEq(type(IERC7540Operator).interfaceId, bytes4(0xe3bc4e65));
        assertEq(type(IERC7540Redeem).interfaceId, bytes4(0x620ee8e4));
        // Values this standard publishes.
        assertEq(type(IERC7540RedeemStatus).interfaceId, bytes4(0x2522a9c4));
        assertEq(type(IERC7540DepositStatus).interfaceId, bytes4(0x27f6ce85));

        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540Operator).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540Redeem).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540RedeemStatus).interfaceId));
        assertTrue(vault.supportsInterface(0x2f0a18c5)); // ERC-7575
        assertFalse(vault.supportsInterface(type(IERC7540DepositStatus).interfaceId));
        assertFalse(vault.supportsInterface(0xffffffff));
    }

    function test_share() public view {
        assertEq(vault.share(), address(vault));
    }

    // ---------------------------------------------------------------------------------------------
    // Request status: state, queue position, bounds
    // ---------------------------------------------------------------------------------------------

    function test_unknownRequestIsNone() public view {
        (RequestState s, uint256 ahead, uint64 e, uint64 l) = _status(42, alice);
        assertEq(uint8(s), uint8(RequestState.None));
        assertEq(ahead, 0);
        assertEq(e, 0);
        assertEq(l, 0);
        assertEq(uint8(_state(0, alice)), uint8(RequestState.None));
    }

    function test_wrongControllerIsNone() public {
        uint256 id = _request(alice, 100e18);
        assertEq(uint8(_state(id, bob)), uint8(RequestState.None));
        assertEq(vault.pendingRedeemRequest(id, bob), 0);
        assertEq(vault.claimableRedeemRequest(id, bob), 0);
    }

    function test_queuePositionAndBounds() public {
        uint256 a = _request(alice, 300e18); // occupies [0, 300)    -> cycle 0
        uint256 b = _request(bob, 400e18); //   occupies [300, 700)  -> cycles 0 and 1
        uint256 c = _request(carol, 600e18); // occupies [700, 1300) -> cycles 1 and 2

        (RequestState s, uint256 ahead, uint64 e, uint64 l) = _status(a, alice);
        assertEq(uint8(s), uint8(RequestState.Pending));
        assertEq(ahead, 0);
        assertEq(e, t0 + CYCLE);
        assertEq(l, t0 + CYCLE);

        (s, ahead, e, l) = _status(b, bob);
        assertEq(ahead, 300e18);
        assertEq(e, t0 + CYCLE);
        assertEq(l, t0 + 2 * CYCLE);

        (s, ahead, e, l) = _status(c, carol);
        assertEq(ahead, 700e18);
        assertEq(e, t0 + 2 * CYCLE);
        assertEq(l, t0 + 3 * CYCLE);
    }

    function test_partialFillThenClaim() public {
        uint256 a = _request(alice, 300e18);
        uint256 b = _request(bob, 400e18);

        vm.warp(t0 + CYCLE);
        assertEq(_fulfill(ALL), CAP); // capped at 500

        assertEq(uint8(_state(a, alice)), uint8(RequestState.Claimable));

        (RequestState s, uint256 ahead, uint64 e, uint64 l) = _status(b, bob);
        assertEq(uint8(s), uint8(RequestState.PartiallyClaimable));
        assertEq(ahead, 0);
        assertEq(vault.pendingRedeemRequest(b, bob), 200e18);
        assertEq(vault.claimableRedeemRequest(b, bob), 200e18);
        // This cycle's capacity is used up, so the rest waits for the next cycle.
        assertEq(e, t0 + 2 * CYCLE);
        assertEq(l, t0 + 2 * CYCLE);

        vm.prank(alice);
        assertEq(vault.redeem(300e18, alice, alice), 300e18);
        assertEq(asset.balanceOf(alice), 300e18);
        assertEq(uint8(_state(a, alice)), uint8(RequestState.None));
    }

    function test_openCycleWithCapacityLeftReportsNow() public {
        _request(alice, 100e18);
        uint256 b = _request(bob, 300e18); // [100, 400)
        uint256 c = _request(carol, 300e18); // [400, 700)

        vm.warp(t0 + CYCLE);
        _fulfill(100e18); // cycle open, 400 capacity left

        (, uint256 ahead, uint64 e, uint64 l) = _status(b, bob);
        assertEq(ahead, 0);
        assertEq(e, block.timestamp, "fits in what is left of this cycle");
        assertEq(l, block.timestamp);

        (, ahead, e, l) = _status(c, carol);
        assertEq(ahead, 300e18);
        assertEq(e, block.timestamp, "first 100 still fit this cycle");
        assertEq(l, t0 + 2 * CYCLE, "remaining 200 wait for the next one");
    }

    function test_claimsAttributedOldestFirst() public {
        uint256 a1 = _request(alice, 100e18);
        uint256 a2 = _request(alice, 100e18);

        vm.warp(t0 + CYCLE);
        _fulfill(200e18);

        vm.prank(alice);
        vault.redeem(150e18, alice, alice);

        assertEq(vault.claimableRedeemRequest(a1, alice), 0);
        assertEq(vault.claimableRedeemRequest(a2, alice), 50e18);
        assertEq(uint8(_state(a1, alice)), uint8(RequestState.None));
        assertEq(uint8(_state(a2, alice)), uint8(RequestState.Claimable));
    }

    function test_overdueCycleNeverReportsPastBound() public {
        uint256 a = _request(alice, 300e18);
        uint256 c = _request(carol, 600e18); // [300, 900)
        vm.warp(t0 + 5 * CYCLE); // manager missed four cycles

        (,, uint64 e, uint64 l) = _status(a, alice);
        assertEq(e, block.timestamp);
        assertEq(l, block.timestamp);

        (,, e, l) = _status(c, carol);
        assertEq(e, block.timestamp);
        assertEq(l, block.timestamp + CYCLE);
    }

    function test_uncappedThroughputGivesOpenUpperBound() public {
        vm.prank(manager);
        vault.setSchedule(CYCLE, t0 + CYCLE, 0);
        uint256 a = _request(alice, 300e18);

        (,, uint64 e, uint64 l) = _status(a, alice);
        assertEq(e, t0 + CYCLE);
        assertEq(l, type(uint64).max);
    }

    function test_noScheduleGivesLoosestBounds() public {
        vm.prank(manager);
        vault.setSchedule(0, 0, 0);
        uint256 a = _request(alice, 300e18);

        (RequestState s, uint256 ahead, uint64 e, uint64 l) = _status(a, alice);
        assertEq(uint8(s), uint8(RequestState.Pending));
        assertEq(ahead, 0);
        assertEq(e, 0);
        assertEq(l, type(uint64).max);

        // With no schedule the manager may fulfill at any time.
        assertEq(_fulfill(ALL), 300e18);
    }

    // ---------------------------------------------------------------------------------------------
    // Suspension and impairment
    // ---------------------------------------------------------------------------------------------

    function test_suspendedReportsLoosestBoundsAndEmits() public {
        uint256 a = _request(alice, 300e18);

        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC7540RedeemStatus.RedeemRequestStatusUpdate(address(0), 0, RequestState.Suspended, 0, type(uint64).max);
        vm.prank(manager);
        vault.setSuspended(true);

        (RequestState s, uint256 ahead, uint64 e, uint64 l) = _status(a, alice);
        assertEq(uint8(s), uint8(RequestState.Suspended));
        assertEq(ahead, 0);
        assertEq(e, 0);
        assertEq(l, type(uint64).max);

        (uint64 minD, uint64 maxD) = vault.redeemDelayBounds(1e18);
        assertEq(minD, 0);
        assertEq(maxD, type(uint64).max);

        vm.warp(t0 + CYCLE);
        vm.prank(manager);
        vm.expectRevert(FifoRedeemVault.IsSuspended.selector);
        vault.fulfillRedeem(1, ALL);
    }

    function test_resumeEmitsAndRestoresBounds() public {
        uint256 a = _request(alice, 300e18);
        vm.startPrank(manager);
        vault.setSuspended(true);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC7540RedeemStatus.RedeemRequestStatusUpdate(address(0), 0, RequestState.Pending, 0, type(uint64).max);
        vault.setSuspended(false);
        vm.stopPrank();

        (RequestState s,, uint64 e, uint64 l) = _status(a, alice);
        assertEq(uint8(s), uint8(RequestState.Pending));
        assertEq(e, t0 + CYCLE);
        assertEq(l, t0 + CYCLE);
    }

    function test_impairedTakesPrecedence() public {
        uint256 a = _request(alice, 300e18);
        vm.startPrank(manager);
        vault.setSuspended(true);
        vault.setImpaired(true);
        vm.stopPrank();
        assertEq(uint8(_state(a, alice)), uint8(RequestState.Impaired));
    }

    function test_impairedAppliesToPartiallyClaimable() public {
        _request(alice, 300e18);
        uint256 b = _request(bob, 400e18);
        vm.warp(t0 + CYCLE);
        _fulfill(ALL); // bob half filled
        vm.prank(manager);
        vault.setImpaired(true);
        assertEq(uint8(_state(b, bob)), uint8(RequestState.Impaired));
    }

    function test_claimableUnaffectedBySuspensionOrImpairment() public {
        uint256 a = _request(alice, 300e18);
        vm.warp(t0 + CYCLE);
        _fulfill(300e18);
        vm.startPrank(manager);
        vault.setSuspended(true);
        vault.setImpaired(true);
        vm.stopPrank();
        assertEq(uint8(_state(a, alice)), uint8(RequestState.Claimable));

        // Claims still work while processing is suspended.
        vm.prank(alice);
        assertEq(vault.redeem(300e18, alice, alice), 300e18);
    }

    // ---------------------------------------------------------------------------------------------
    // Delay bounds for a hypothetical new Request
    // ---------------------------------------------------------------------------------------------

    function test_delayBounds() public {
        _request(alice, 700e18); // 700 already queued

        // A new 100-share Request occupies [700, 800): entirely in cycle 1.
        (uint64 minD, uint64 maxD) = vault.redeemDelayBounds(100e18);
        assertEq(minD, 2 * CYCLE);
        assertEq(maxD, 2 * CYCLE);

        // A new 400-share Request occupies [700, 1100): cycles 1 and 2.
        (minD, maxD) = vault.redeemDelayBounds(400e18);
        assertEq(minD, 2 * CYCLE);
        assertEq(maxD, 3 * CYCLE);

        // Zero is reported as the smallest possible Request.
        (minD, maxD) = vault.redeemDelayBounds(0);
        assertEq(minD, 2 * CYCLE);
        assertEq(maxD, 2 * CYCLE);
    }

    function test_delayBoundsMatchStatusAfterRequest() public {
        _request(alice, 650e18);
        (uint64 minD, uint64 maxD) = vault.redeemDelayBounds(250e18);
        uint256 id = _request(bob, 250e18);
        (,, uint64 e, uint64 l) = _status(id, bob);
        assertEq(e, block.timestamp + minD);
        assertEq(l, block.timestamp + maxD);
    }

    // ---------------------------------------------------------------------------------------------
    // Enforced schedule
    // ---------------------------------------------------------------------------------------------

    function test_cannotFulfillBeforeCycleOpens() public {
        _request(alice, 100e18);
        vm.prank(manager);
        vm.expectRevert(FifoRedeemVault.CycleNotOpen.selector);
        vault.fulfillRedeem(100e18, ALL);
    }

    function test_cycleCapacityIsEnforcedAcrossCalls() public {
        _request(alice, 900e18);
        vm.warp(t0 + CYCLE);
        assertEq(_fulfill(300e18), 300e18);
        assertEq(_fulfill(300e18), 200e18, "only 200 left this cycle");
        assertEq(_fulfill(ALL), 0, "cycle exhausted");

        vm.warp(t0 + 2 * CYCLE - 1);
        assertEq(_fulfill(ALL), 0, "next cycle not open yet");

        vm.warp(t0 + 2 * CYCLE);
        assertEq(_fulfill(ALL), 400e18, "new cycle, rest of the queue");
    }

    function test_nextCycleIsAtLeastCycleLengthAfterLateOpen() public {
        _request(alice, 900e18);
        vm.warp(t0 + CYCLE + 7 hours); // manager is 7 hours late
        _fulfill(ALL);
        assertEq(vault.nextCycleAt(), t0 + 2 * CYCLE + 7 hours);
    }

    function test_maxRequestsBoundsWork() public {
        uint256[10] memory ids;
        for (uint256 i; i < 10; i++) {
            ids[i] = _request(alice, 1e18);
        }
        vm.warp(t0 + CYCLE);
        vm.startPrank(manager);
        assertEq(vault.fulfillRedeem(ALL, 3), 3e18);
        assertEq(vault.fulfillRedeem(ALL, 3), 3e18, "same cycle continues");
        assertEq(vault.fulfillRedeem(ALL, 100), 4e18);
        vm.stopPrank();
        assertEq(uint8(_state(ids[9], alice)), uint8(RequestState.Claimable));
    }

    function test_spamQueueCannotBlockProcessing() public {
        address spammer = makeAddr("spammer");
        _deposit(spammer, 1e18);
        for (uint256 i; i < 300; i++) {
            _request(spammer, 1);
        }
        uint256 a = _request(alice, 100e18);

        vm.warp(t0 + CYCLE);
        vm.startPrank(manager);
        uint256 g = gasleft();
        vault.fulfillRedeem(ALL, 100);
        assertLt(g - gasleft(), 5_000_000, "a bounded batch stays well under the block gas limit");
        vault.fulfillRedeem(ALL, 100);
        vault.fulfillRedeem(ALL, 101);
        vm.stopPrank();
        assertEq(uint8(_state(a, alice)), uint8(RequestState.Claimable));
    }

    function test_onlyManager() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.fulfillRedeem(1, ALL);
        vm.expectRevert();
        vault.setSchedule(1, 1, 1);
        vm.expectRevert();
        vault.setSuspended(true);
        vm.expectRevert();
        vault.setImpaired(true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-7540 request and claim behaviour
    // ---------------------------------------------------------------------------------------------

    function test_requestEscrowsSharesAndEmits() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC7540Redeem.RedeemRequest(alice, alice, 1, alice, 100e18);
        uint256 id = _request(alice, 100e18);
        assertEq(id, 1);
        assertEq(vault.balanceOf(alice), 900e18);
        assertEq(vault.balanceOf(address(vault)), 100e18);
        assertEq(vault.pendingRedeemRequest(id, alice), 100e18);
    }

    function test_requestZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(FifoRedeemVault.ZeroShares.selector);
        vault.requestRedeem(0, alice, alice);
    }

    function test_requestForAnotherController() public {
        vm.prank(alice);
        uint256 id = vault.requestRedeem(100e18, bob, alice);
        assertEq(vault.pendingRedeemRequest(id, bob), 100e18);
        assertEq(vault.pendingRedeemRequest(id, alice), 0);
        vm.warp(t0 + CYCLE);
        _fulfill(ALL);
        vm.prank(bob);
        vault.redeem(100e18, bob, bob);
        assertEq(asset.balanceOf(bob), 100e18);
    }

    function test_requestByOperator() public {
        vm.prank(alice);
        vault.setOperator(keeper, true);
        vm.prank(keeper);
        vault.requestRedeem(100e18, alice, alice);
        assertEq(vault.balanceOf(alice), 900e18);
    }

    function test_requestByAllowance() public {
        vm.prank(alice);
        vault.approve(keeper, 60e18);
        vm.prank(keeper);
        vault.requestRedeem(60e18, keeper, alice);
        assertEq(vault.allowance(alice, keeper), 0);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, keeper, 0, 1));
        vault.requestRedeem(1, keeper, alice);
    }

    function test_operatorSetEmitsAndCanClaim() public {
        uint256 id = _request(alice, 100e18);
        vm.warp(t0 + CYCLE);
        _fulfill(ALL);

        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC7540Operator.OperatorSet(alice, keeper, true);
        vm.prank(alice);
        assertTrue(vault.setOperator(keeper, true));
        assertTrue(vault.isOperator(alice, keeper));

        vm.prank(keeper);
        vault.redeem(100e18, keeper, alice);
        assertEq(asset.balanceOf(keeper), 100e18);
        assertEq(uint8(_state(id, alice)), uint8(RequestState.None));
    }

    function test_claimByStrangerReverts() public {
        _request(alice, 100e18);
        vm.warp(t0 + CYCLE);
        _fulfill(ALL);
        vm.startPrank(bob);
        vm.expectRevert(FifoRedeemVault.NotAuthorized.selector);
        vault.redeem(1, bob, alice);
        vm.expectRevert(FifoRedeemVault.NotAuthorized.selector);
        vault.withdraw(1, bob, alice);
        vm.stopPrank();
    }

    function test_claimMoreThanClaimableReverts() public {
        _request(alice, 100e18);
        vm.warp(t0 + CYCLE);
        _fulfill(ALL);
        vm.startPrank(alice);
        vm.expectRevert(FifoRedeemVault.ExceedsClaimable.selector);
        vault.redeem(100e18 + 1, alice, alice);
        vm.expectRevert(FifoRedeemVault.ExceedsClaimable.selector);
        vault.withdraw(100e18 + 1, alice, alice);
        vm.stopPrank();
    }

    function test_zeroClaimsReturnZero() public {
        vm.startPrank(alice);
        assertEq(vault.redeem(0, alice, alice), 0);
        assertEq(vault.withdraw(0, alice, alice), 0);
        vm.stopPrank();
    }

    function test_withdrawExactAssets() public {
        _request(alice, 100e18);
        vm.warp(t0 + CYCLE);
        _fulfill(ALL);
        assertEq(vault.maxWithdraw(alice), 100e18);
        vm.startPrank(alice);
        assertEq(vault.withdraw(40e18, alice, alice), 40e18);
        assertEq(vault.withdraw(60e18, alice, alice), 60e18);
        vm.stopPrank();
        assertEq(asset.balanceOf(alice), 100e18);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.reservedAssets(), 0);
    }

    function test_withdrawCannotStrandDust() public {
        // Make one share worth ~10 assets, then claim a single share's worth in two steps.
        asset.mint(address(vault), 27_000e18);
        uint256 id = _request(alice, 1);
        vm.warp(t0 + CYCLE);
        _fulfill(ALL);
        uint256 ca = vault.maxWithdraw(alice);
        assertGt(ca, 1);

        vm.startPrank(alice);
        vm.expectRevert(FifoRedeemVault.StrandedAssets.selector);
        vault.withdraw(ca - 1, alice, alice);
        assertEq(vault.withdraw(ca, alice, alice), 1);
        vm.stopPrank();
        assertEq(uint8(_state(id, alice)), uint8(RequestState.None));
    }

    function test_redeemLastShareTakesRemainingAssets() public {
        asset.mint(address(vault), 1e18 + 7); // awkward exchange rate
        _request(alice, 3);
        vm.warp(t0 + CYCLE);
        _fulfill(ALL);
        uint256 total = vault.maxWithdraw(alice);
        vm.startPrank(alice);
        uint256 got = vault.redeem(1, alice, alice) + vault.redeem(1, alice, alice) + vault.redeem(1, alice, alice);
        vm.stopPrank();
        assertEq(got, total, "no dust left behind");
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_previewsRevert() public {
        vm.expectRevert(FifoRedeemVault.AsyncFlow.selector);
        vault.previewRedeem(1);
        vm.expectRevert(FifoRedeemVault.AsyncFlow.selector);
        vault.previewWithdraw(1);
    }

    function test_yieldBetweenCyclesGoesToLaterRequests() public {
        _request(alice, 500e18);
        _request(bob, 500e18);

        vm.warp(t0 + CYCLE);
        _fulfill(ALL); // alice at 1.0
        uint256 aliceAssets = vault.maxWithdraw(alice);

        asset.mint(address(vault), 250e18); // yield accrues while bob waits

        vm.warp(t0 + 2 * CYCLE);
        _fulfill(ALL);
        uint256 bobAssets = vault.maxWithdraw(bob);

        assertEq(vault.maxWithdraw(alice), aliceAssets, "fulfilled assets are reserved, not exposed to later yield");
        assertApproxEqAbs(aliceAssets, 500e18, 1);
        assertGt(bobAssets, aliceAssets, "bob is paid at the later, higher rate");
    }

    function test_reservedAssetsExcludedFromTotalAssets() public {
        _request(alice, 500e18);
        vm.warp(t0 + CYCLE);
        _fulfill(ALL);
        assertEq(vault.reservedAssets(), 500e18);
        assertEq(vault.totalAssets(), 2_500e18);
        assertEq(vault.totalSupply(), 2_500e18);

        // A new depositor still enters at the fair rate.
        _deposit(keeper, 100e18);
        assertEq(vault.balanceOf(keeper), 100e18);
    }

    function test_scheduleSetEmits() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit FifoRedeemVault.ScheduleSet(2 days, t0 + 3 days, 42e18);
        vm.prank(manager);
        vault.setSchedule(2 days, t0 + 3 days, 42e18);
    }

    function test_fulfillEmitsBatchTotals() public {
        _request(alice, 100e18);
        _request(bob, 150e18);
        vm.warp(t0 + CYCLE);
        vm.expectEmit(false, false, false, true, address(vault));
        emit FifoRedeemVault.RedeemFulfilled(250e18, 250e18, 250e18);
        _fulfill(ALL);
    }

    function test_emptyFulfillEmitsNothing() public {
        vm.warp(t0 + CYCLE);
        vm.recordLogs();
        assertEq(_fulfill(ALL), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_batchUsesOneExchangeRate() public {
        asset.mint(address(vault), 1_234_567); // awkward rate
        _request(alice, 7e18);
        _request(bob, 7e18);
        _request(carol, 7e18);
        vm.warp(t0 + CYCLE);
        _fulfill(ALL);
        uint256 a = vault.maxWithdraw(alice);
        assertEq(vault.maxWithdraw(bob), a, "equal shares in one batch get equal assets");
        assertEq(vault.maxWithdraw(carol), a);
        assertLe(3 * a, asset.balanceOf(address(vault)));
    }

    // ---------------------------------------------------------------------------------------------
    // Constant-gas status views
    // ---------------------------------------------------------------------------------------------

    function test_statusGasIndependentOfQueueLength() public {
        _request(alice, 1e18);
        uint256 second = _request(bob, 1e18); // 1 share ahead
        for (uint256 i; i < 200; i++) {
            _request(bob, 1e18);
        }
        uint256 last = _request(carol, 1e18); // 201 shares ahead, same code path as `second`

        // Warm both storage paths first so the comparison is not skewed by cold-slot surcharges.
        vault.redeemRequestStatus(second, bob);
        vault.redeemRequestStatus(last, carol);

        uint256 g0 = gasleft();
        vault.redeemRequestStatus(second, bob);
        uint256 gSecond = g0 - gasleft();
        g0 = gasleft();
        vault.redeemRequestStatus(last, carol);
        uint256 gLast = g0 - gasleft();

        // Allow a few gas for the different calldata (request id, controller address bytes).
        assertApproxEqAbs(gSecond, gLast, 16, "status cost does not grow with the queue");
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: consistency rules from the specification
    // ---------------------------------------------------------------------------------------------

    function testFuzz_consistency(uint96[4] memory sizes, uint96 fill, uint32 dt) public {
        uint256[4] memory ids;
        address[4] memory who = [alice, bob, carol, alice];
        for (uint256 i; i < 4; i++) {
            ids[i] = _request(who[i], bound(sizes[i], 1, 200e18));
        }
        vm.warp(t0 + CYCLE + bound(dt, 0, 10 days));
        _fulfill(bound(fill, 0, 800e18));

        uint256 prevAhead;
        for (uint256 i; i < 4; i++) {
            (RequestState s, uint256 ahead, uint64 e, uint64 l) = _status(ids[i], who[i]);
            uint256 p = vault.pendingRedeemRequest(ids[i], who[i]);
            uint256 c = vault.claimableRedeemRequest(ids[i], who[i]);

            assertLe(e, l, "earliest <= latest");
            if (p == 0) {
                assertEq(uint8(s), uint8(c > 0 ? RequestState.Claimable : RequestState.None));
                assertEq(ahead, 0);
                assertEq(e, 0);
                assertEq(l, 0);
            } else {
                assertGe(l, block.timestamp, "pending bound not in the past");
                assertEq(uint8(s), uint8(c > 0 ? RequestState.PartiallyClaimable : RequestState.Pending));
                assertGe(ahead, prevAhead, "FIFO: position is monotonic");
                prevAhead = ahead;
            }
        }
    }
}
