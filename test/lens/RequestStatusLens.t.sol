// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {FifoRedeemVault} from "../../src/FifoRedeemVault.sol";
import {RequestState} from "../../src/interfaces/IERC7540RequestStatus.sol";
import {RequestStatusLens} from "../../src/lens/RequestStatusLens.sol";
import {IRequestStatusAdapter} from "../../src/lens/IRequestStatusAdapter.sol";
import {ERC7540Adapter} from "../../src/lens/adapters/ERC7540Adapter.sol";
import {MockAsset} from "../FifoRedeemVault.t.sol";

/// @dev An ERC-7540 vault that does NOT implement ERC-XXXX: only the 7540 views and ERC-165.
contract Mock7540Vault {
    mapping(uint256 => mapping(address => uint256)) public pendingRedeemRequest;
    mapping(uint256 => mapping(address => uint256)) public claimableRedeemRequest;

    function set(uint256 id, address c, uint256 pending, uint256 claimable) external {
        pendingRedeemRequest[id][c] = pending;
        claimableRedeemRequest[id][c] = claimable;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x620ee8e4;
    }
}

/// @dev A queue with no standard interface at all, served by a registered adapter.
contract MockCustomQueue {}

contract MockAdapter is IRequestStatusAdapter {
    bool public broken;

    function setBroken(bool b) external {
        broken = b;
    }

    function redeemRequestStatus(address, uint256 requestId, address)
        external
        view
        returns (RequestState, uint256, uint64, uint64)
    {
        require(!broken, "adapter broken");
        return (RequestState.Pending, requestId * 10, 100, 200);
    }

    function requestIdsOf(address, address) external pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = 7;
        ids[1] = 9;
    }
}

contract RequestStatusLensTest is Test {
    RequestStatusLens lens;
    ERC7540Adapter generic;
    FifoRedeemVault nativeVault;
    Mock7540Vault plain7540;
    MockCustomQueue custom;
    MockAdapter adapter;
    MockAsset asset;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        generic = new ERC7540Adapter();
        lens = new RequestStatusLens(owner, generic);

        asset = new MockAsset();
        nativeVault = new FifoRedeemVault(IERC20(address(asset)), "Q", "Q", owner);
        vm.prank(owner);
        nativeVault.setSchedule(1 days, uint64(block.timestamp + 1 days), 500e18);
        asset.mint(alice, 100e18);
        vm.startPrank(alice);
        asset.approve(address(nativeVault), 100e18);
        nativeVault.deposit(100e18, alice);
        nativeVault.requestRedeem(40e18, alice, alice);
        vm.stopPrank();

        plain7540 = new Mock7540Vault();
        custom = new MockCustomQueue();
        adapter = new MockAdapter();
        vm.prank(owner);
        lens.setAdapter(address(custom), adapter);
    }

    function test_sourceResolution() public {
        (RequestStatusLens.Source s, address t) = lens.sourceOf(address(nativeVault));
        assertEq(uint8(s), uint8(RequestStatusLens.Source.Native));
        assertEq(t, address(nativeVault));

        (s, t) = lens.sourceOf(address(custom));
        assertEq(uint8(s), uint8(RequestStatusLens.Source.Adapter));
        assertEq(t, address(adapter));

        (s, t) = lens.sourceOf(address(plain7540));
        assertEq(uint8(s), uint8(RequestStatusLens.Source.Generic));
        assertEq(t, address(generic));

        (s, t) = lens.sourceOf(alice); // an EOA
        assertEq(uint8(s), uint8(RequestStatusLens.Source.Unsupported));
        (s,) = lens.sourceOf(address(asset)); // a contract without ERC-165
        assertEq(uint8(s), uint8(RequestStatusLens.Source.Unsupported));
    }

    function test_nativeVaultIsPreferredOverAdapter() public {
        vm.prank(owner);
        lens.setAdapter(address(nativeVault), adapter);
        (RequestStatusLens.Source s,) = lens.sourceOf(address(nativeVault));
        assertEq(uint8(s), uint8(RequestStatusLens.Source.Native));
    }

    function test_nativeStatusMatchesVault() public view {
        RequestStatusLens.Status memory s = lens.redeemRequestStatus(address(nativeVault), 1, alice);
        (RequestState st, uint256 ahead, uint64 e, uint64 l) = nativeVault.redeemRequestStatus(1, alice);
        assertTrue(s.ok);
        assertEq(uint8(s.state), uint8(st));
        assertEq(s.queuedAhead, ahead);
        assertEq(s.earliestClaimableAt, e);
        assertEq(s.latestClaimableAt, l);
        assertEq(uint8(s.state), uint8(RequestState.Pending));
    }

    function test_adapterStatus() public view {
        RequestStatusLens.Status memory s = lens.redeemRequestStatus(address(custom), 3, alice);
        assertTrue(s.ok);
        assertEq(uint8(s.source), uint8(RequestStatusLens.Source.Adapter));
        assertEq(s.queuedAhead, 30);
        assertEq(s.earliestClaimableAt, 100);
        assertEq(s.latestClaimableAt, 200);
    }

    function test_genericStatesAndLoosestBounds() public {
        plain7540.set(0, alice, 5, 0);
        RequestStatusLens.Status memory s = lens.redeemRequestStatus(address(plain7540), 0, alice);
        assertEq(uint8(s.state), uint8(RequestState.Pending));
        assertEq(s.queuedAhead, type(uint256).max, "queue position unknown");
        assertEq(s.earliestClaimableAt, 0);
        assertEq(s.latestClaimableAt, type(uint64).max);

        plain7540.set(0, alice, 5, 3);
        assertEq(
            uint8(lens.redeemRequestStatus(address(plain7540), 0, alice).state), uint8(RequestState.PartiallyClaimable)
        );

        plain7540.set(0, alice, 0, 3);
        s = lens.redeemRequestStatus(address(plain7540), 0, alice);
        assertEq(uint8(s.state), uint8(RequestState.Claimable));
        assertEq(s.queuedAhead, 0);
        assertEq(s.latestClaimableAt, 0);

        plain7540.set(0, alice, 0, 0);
        assertEq(uint8(lens.redeemRequestStatus(address(plain7540), 0, alice).state), uint8(RequestState.None));
    }

    function test_unsupportedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RequestStatusLens.Unsupported.selector, alice));
        lens.redeemRequestStatus(alice, 0, alice);
    }

    function test_batchIsolatesFailures() public {
        adapter.setBroken(true);
        RequestStatusLens.Query[] memory q = new RequestStatusLens.Query[](4);
        q[0] = RequestStatusLens.Query(address(nativeVault), 1, alice);
        q[1] = RequestStatusLens.Query(address(custom), 1, alice); // adapter reverts
        q[2] = RequestStatusLens.Query(alice, 0, alice); // unsupported
        q[3] = RequestStatusLens.Query(address(plain7540), 0, alice);

        RequestStatusLens.Status[] memory out = lens.redeemRequestStatusBatch(q);
        assertTrue(out[0].ok);
        assertEq(uint8(out[0].state), uint8(RequestState.Pending));
        assertFalse(out[1].ok);
        assertEq(uint8(out[1].source), uint8(RequestStatusLens.Source.Adapter));
        assertFalse(out[2].ok);
        assertEq(uint8(out[2].source), uint8(RequestStatusLens.Source.Unsupported));
        assertTrue(out[3].ok);
        assertEq(uint8(out[3].state), uint8(RequestState.None));
    }

    function test_requestIdsOf() public view {
        uint256[] memory ids = lens.requestIdsOf(address(custom), alice);
        assertEq(ids.length, 2);
        assertEq(ids[1], 9);
        ids = lens.requestIdsOf(address(plain7540), alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], 0);
        assertEq(lens.requestIdsOf(address(nativeVault), alice).length, 0);
        assertEq(lens.requestIdsOf(alice, alice).length, 0);
    }

    function test_setAdapterOnlyOwnerAndEmits() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        lens.setAdapter(address(plain7540), adapter);

        vm.expectEmit(true, true, false, false, address(lens));
        emit RequestStatusLens.AdapterSet(address(plain7540), address(adapter));
        vm.prank(owner);
        lens.setAdapter(address(plain7540), adapter);
        (RequestStatusLens.Source s,) = lens.sourceOf(address(plain7540));
        assertEq(uint8(s), uint8(RequestStatusLens.Source.Adapter));

        vm.prank(owner);
        lens.setAdapter(address(plain7540), IRequestStatusAdapter(address(0)));
        (s,) = lens.sourceOf(address(plain7540));
        assertEq(uint8(s), uint8(RequestStatusLens.Source.Generic), "removing the adapter falls back to generic");
    }

    function test_ownershipIsTwoStep() public {
        address next = makeAddr("next");
        vm.prank(owner);
        lens.transferOwnership(next);
        assertEq(lens.owner(), owner, "not transferred until accepted");
        vm.prank(next);
        lens.acceptOwnership();
        assertEq(lens.owner(), next);
    }

    function test_interfaceIdConstantsMatch() public view {
        assertEq(lens.REDEEM_STATUS_INTERFACE_ID(), bytes4(0x2522a9c4));
        assertEq(lens.ERC7540_REDEEM_INTERFACE_ID(), bytes4(0x620ee8e4));
    }
}
