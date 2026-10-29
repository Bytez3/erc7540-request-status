// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

    uint64 constant CYCLE = 1 days;
    uint64 T0;

    function setUp() public {
        vm.warp(1_800_000_000);
        T0 = uint64(block.timestamp);
        asset = new MockAsset();
        vault = new FifoRedeemVault(IERC20(address(asset)), "Queue Vault", "qV", manager);

        _deposit(alice, 1_000e18);
        _deposit(bob, 1_000e18);
        _deposit(carol, 1_000e18);

        // Daily cycles starting tomorrow, 500 shares per cycle.
        vm.prank(manager);
        vault.setSchedule(CYCLE, T0 + CYCLE, 500e18);
    }

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

    function _status(uint256 id, address who)
        internal
        view
        returns (RequestState s, uint256 ahead, uint64 earliest, uint64 latest)
    {
        return vault.redeemRequestStatus(id, who);
    }

    // ---------------------------------------------------------------------------------------------
    // Interface detection
    // ---------------------------------------------------------------------------------------------

    function test_interfaceIds() public view {
        // Values published in ERC-7540 / ERC-7575.
        assertEq(type(IERC7540Operator).interfaceId, bytes4(0xe3bc4e65));
        assertEq(type(IERC7540Redeem).interfaceId, bytes4(0x620ee8e4));

        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540Redeem).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540RedeemStatus).interfaceId));
        assertTrue(vault.supportsInterface(0x2f0a18c5));
        assertFalse(vault.supportsInterface(type(IERC7540DepositStatus).interfaceId));
        assertFalse(vault.supportsInterface(0xffffffff));
    }

    function test_logInterfaceIds() public {
        // Printed with `forge test -vv` so the spec can quote them.
        emit log_named_bytes32("IERC7540RedeemStatus", bytes32(type(IERC7540RedeemStatus).interfaceId));
        emit log_named_bytes32("IERC7540DepositStatus", bytes32(type(IERC7540DepositStatus).interfaceId));
    }

    // ---------------------------------------------------------------------------------------------
    // Queue position and time bounds
    // ---------------------------------------------------------------------------------------------

    function test_unknownRequestIsNone() public view {
        (RequestState s, uint256 ahead, uint64 e, uint64 l) = _status(42, alice);
        assertEq(uint8(s), uint8(RequestState.None));
        assertEq(ahead, 0);
        assertEq(e, 0);
        assertEq(l, 0);
    }

    function test_wrongControllerIsNone() public {
        uint256 id = _request(alice, 100e18);
        (RequestState s,,,) = _status(id, bob);
        assertEq(uint8(s), uint8(RequestState.None));
    }

    function test_queuePositionAndBounds() public {
        uint256 a = _request(alice, 300e18); // occupies [0, 300)
        uint256 b = _request(bob, 400e18); //   occupies [300, 700) -> straddles cycles 0 and 1
        uint256 c = _request(carol, 600e18); // occupies [700, 1300) -> cycles 1 and 2

        (RequestState s, uint256 ahead, uint64 e, uint64 l) = _status(a, alice);
        assertEq(uint8(s), uint8(RequestState.Pending));
        assertEq(ahead, 0);
        assertEq(e, T0 + CYCLE);
        assertEq(l, T0 + CYCLE);

        (s, ahead, e, l) = _status(b, bob);
        assertEq(ahead, 300e18);
        assertEq(e, T0 + CYCLE);
        assertEq(l, T0 + 2 * CYCLE);

        (s, ahead, e, l) = _status(c, carol);
        assertEq(ahead, 700e18);
        assertEq(e, T0 + 2 * CYCLE);
        assertEq(l, T0 + 3 * CYCLE);
    }

    function test_partialFillThenClaim() public {
        uint256 a = _request(alice, 300e18);
        uint256 b = _request(bob, 400e18);

        vm.warp(T0 + CYCLE);
        vm.prank(manager);
        vault.fulfillRedeem(500e18);

        (RequestState s,,,) = _status(a, alice);
        assertEq(uint8(s), uint8(RequestState.Claimable));

        uint256 ahead;
        uint64 e;
        uint64 l;
        (s, ahead, e, l) = _status(b, bob);
        assertEq(uint8(s), uint8(RequestState.PartiallyClaimable));
        assertEq(ahead, 0);
        assertEq(vault.pendingRedeemRequest(b, bob), 200e18);
        assertEq(vault.claimableRedeemRequest(b, bob), 200e18);
        // Next cycle was rolled forward by the fulfillment.
        assertEq(e, T0 + 2 * CYCLE);
        assertEq(l, T0 + 2 * CYCLE);

        vm.prank(alice);
        uint256 assets = vault.redeem(300e18, alice, alice);
        assertEq(assets, 300e18);
        assertEq(asset.balanceOf(alice), 300e18);
        (s,,,) = _status(a, alice);
        assertEq(uint8(s), uint8(RequestState.None));
    }

    function test_claimsAttributedOldestFirst() public {
        uint256 a1 = _request(alice, 100e18);
        uint256 a2 = _request(alice, 100e18);

        vm.prank(manager);
        vault.fulfillRedeem(200e18);

        vm.prank(alice);
        vault.redeem(150e18, alice, alice);

        assertEq(vault.claimableRedeemRequest(a1, alice), 0);
        assertEq(vault.claimableRedeemRequest(a2, alice), 50e18);
        (RequestState s,,,) = _status(a1, alice);
        assertEq(uint8(s), uint8(RequestState.None));
        (s,,,) = _status(a2, alice);
        assertEq(uint8(s), uint8(RequestState.Claimable));
    }

    function test_overdueCycleNeverReportsPastBound() public {
        uint256 a = _request(alice, 300e18);
        vm.warp(T0 + 5 * CYCLE); // manager missed four cycles

        (,, uint64 e, uint64 l) = _status(a, alice);
        assertEq(e, block.timestamp);
        assertGe(l, block.timestamp);
    }

    function test_unknownCapacityGivesOpenUpperBound() public {
        vm.prank(manager);
        vault.setSchedule(CYCLE, T0 + CYCLE, 0);
        uint256 a = _request(alice, 300e18);

        (,, uint64 e, uint64 l) = _status(a, alice);
        assertEq(e, T0 + CYCLE);
        assertEq(l, type(uint64).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Suspension / impairment
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

        vm.prank(manager);
        vm.expectRevert(FifoRedeemVault.IsSuspended.selector);
        vault.fulfillRedeem(1);
    }

    function test_impairedTakesPrecedence() public {
        uint256 a = _request(alice, 300e18);
        vm.startPrank(manager);
        vault.setSuspended(true);
        vault.setImpaired(true);
        vm.stopPrank();
        (RequestState s,,,) = _status(a, alice);
        assertEq(uint8(s), uint8(RequestState.Impaired));
    }

    function test_claimableUnaffectedBySuspension() public {
        uint256 a = _request(alice, 300e18);
        vm.prank(manager);
        vault.fulfillRedeem(300e18);
        vm.prank(manager);
        vault.setSuspended(true);
        (RequestState s,,,) = _status(a, alice);
        assertEq(uint8(s), uint8(RequestState.Claimable));
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
    // Properties
    // ---------------------------------------------------------------------------------------------

    /// State, amounts and bounds stay mutually consistent under arbitrary requests and fills.
    function testFuzz_consistency(uint96[4] memory sizes, uint96 fill, uint32 dt) public {
        uint256[4] memory ids;
        address[4] memory who = [alice, bob, carol, alice];
        for (uint256 i; i < 4; i++) {
            uint256 sz = bound(sizes[i], 1, 200e18);
            ids[i] = _request(who[i], sz);
        }
        vm.warp(block.timestamp + bound(dt, 0, 10 days));
        vm.prank(manager);
        vault.fulfillRedeem(bound(fill, 0, 800e18));

        uint256 prevAhead;
        for (uint256 i; i < 4; i++) {
            (RequestState s, uint256 ahead, uint64 e, uint64 l) = _status(ids[i], who[i]);
            uint256 p = vault.pendingRedeemRequest(ids[i], who[i]);
            uint256 c = vault.claimableRedeemRequest(ids[i], who[i]);

            assertLe(e, l, "earliest <= latest");
            if (p == 0) {
                assertTrue(s == RequestState.Claimable || s == RequestState.None);
                assertEq(ahead, 0);
            } else {
                assertGe(l, block.timestamp, "pending bound not in the past");
                if (c > 0) assertEq(uint8(s), uint8(RequestState.PartiallyClaimable));
                else assertEq(uint8(s), uint8(RequestState.Pending));
                assertGe(ahead, prevAhead, "FIFO: position is monotonic");
                prevAhead = ahead;
            }
        }
    }
}
