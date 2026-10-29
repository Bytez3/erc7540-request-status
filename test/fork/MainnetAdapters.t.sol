// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {RequestState} from "../../src/interfaces/IERC7540RequestStatus.sol";
import {RequestStatusLens} from "../../src/lens/RequestStatusLens.sol";
import {ERC7540Adapter} from "../../src/lens/adapters/ERC7540Adapter.sol";
import {
    ILidoAccountingOracle,
    ILidoHashConsensus,
    ILidoWithdrawalQueue,
    LidoWithdrawalQueueAdapter
} from "../../src/lens/adapters/LidoWithdrawalQueueAdapter.sol";
import {EthenaCooldownAdapter, IStakedUSDeCooldown} from "../../src/lens/adapters/EthenaCooldownAdapter.sol";

interface IStakedUSDeActions {
    function cooldownShares(uint256 shares) external returns (uint256 assets);
    function unstake(address receiver) external;
}

/// Runs the real adapters against live Ethereum mainnet contracts on a fork.
/// Skipped unless MAINNET_RPC_URL is set, e.g. MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test
contract MainnetAdaptersForkTest is Test {
    // Addresses verified in docs/research/queue-interfaces.md
    address constant LIDO_WQ = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    address constant LIDO_HASH_CONSENSUS = 0xD624B08C83bAECF0807Dd2c6880C3154a5F0B288;
    address constant LIDO_ACCOUNTING_ORACLE = 0x852deD011285fe67063a08005c71a85690503Cee;
    uint256 constant LIDO_MARGIN = 7_680;
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant CENTRIFUGE_JTRSY = 0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A;

    RequestStatusLens lens;
    ILidoWithdrawalQueue wq = ILidoWithdrawalQueue(LIDO_WQ);

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        lens = new RequestStatusLens(address(this), new ERC7540Adapter());
        lens.setAdapter(
            LIDO_WQ,
            new LidoWithdrawalQueueAdapter(
                ILidoHashConsensus(LIDO_HASH_CONSENSUS), ILidoAccountingOracle(LIDO_ACCOUNTING_ORACLE), LIDO_MARGIN
            )
        );
        lens.setAdapter(SUSDE, new EthenaCooldownAdapter());
    }

    function _one(uint256 id) internal view returns (ILidoWithdrawalQueue.WithdrawalRequestStatus memory) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        return wq.getWithdrawalStatus(ids)[0];
    }

    // ---------------------------------------------------------------------------------------------
    // Lido
    // ---------------------------------------------------------------------------------------------

    function test_lido_newestRequestMatchesQueue() public view {
        uint256 last = wq.getLastRequestId();
        uint256 lastFinalized = wq.getLastFinalizedRequestId();
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory st = _one(last);
        RequestStatusLens.Status memory s = lens.redeemRequestStatus(LIDO_WQ, last, st.owner);

        assertTrue(s.ok);
        assertEq(uint8(s.source), uint8(RequestStatusLens.Source.Adapter));

        if (st.isClaimed) {
            assertEq(uint8(s.state), uint8(RequestState.None));
        } else if (st.isFinalized) {
            assertEq(uint8(s.state), uint8(RequestState.Claimable));
        } else {
            // Independently recompute stETH ahead.
            uint256 expected;
            for (uint256 id = lastFinalized + 1; id < last; id++) {
                expected += _one(id).amountOfStETH;
            }
            assertEq(s.queuedAhead, expected, "queuedAhead matches the live queue");
            assertEq(s.latestClaimableAt, type(uint64).max, "Lido has no on-chain upper bound");
            assertGe(s.earliestClaimableAt, block.timestamp);
            if (s.state == RequestState.Pending) {
                assertGe(s.earliestClaimableAt, st.timestamp + LIDO_MARGIN, "respects the sanity-check margin");
                assertLe(s.earliestClaimableAt, block.timestamp + 2 days + LIDO_MARGIN);
            }
        }
    }

    function test_lido_finalizedUnclaimedIsClaimable() public view {
        uint256 lastFinalized = wq.getLastFinalizedRequestId();
        for (uint256 id = lastFinalized; id > 0 && id + 200 > lastFinalized; id--) {
            ILidoWithdrawalQueue.WithdrawalRequestStatus memory st = _one(id);
            RequestStatusLens.Status memory s = lens.redeemRequestStatus(LIDO_WQ, id, st.owner);
            assertEq(uint8(s.state), uint8(st.isClaimed ? RequestState.None : RequestState.Claimable));
            if (!st.isClaimed) return; // found and checked one
        }
    }

    function test_lido_wrongOwnerAndInvalidIdsAreNone() public view {
        uint256 last = wq.getLastRequestId();
        assertEq(uint8(lens.redeemRequestStatus(LIDO_WQ, last, address(0xdead)).state), uint8(RequestState.None));
        assertEq(uint8(lens.redeemRequestStatus(LIDO_WQ, 0, address(0xdead)).state), uint8(RequestState.None));
        assertEq(uint8(lens.redeemRequestStatus(LIDO_WQ, last + 1, address(0xdead)).state), uint8(RequestState.None));
    }

    function test_lido_requestIdsOfOwner() public view {
        uint256 last = wq.getLastRequestId();
        ILidoWithdrawalQueue.WithdrawalRequestStatus memory st = _one(last);
        vm.assume(!st.isClaimed);
        uint256[] memory ids = lens.requestIdsOf(LIDO_WQ, st.owner);
        bool found;
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == last) found = true;
        }
        assertTrue(found);
    }

    // ---------------------------------------------------------------------------------------------
    // Ethena: a real cooldown, start to finish
    // ---------------------------------------------------------------------------------------------

    function test_ethena_realCooldownLifecycle() public {
        uint24 duration = IStakedUSDeCooldown(SUSDE).cooldownDuration();
        vm.assume(duration > 0); // with no cooldown, sUSDe redeems are synchronous

        address user = makeAddr("sUSDe-holder");
        deal(SUSDE, user, 1_000e18);

        assertEq(uint8(lens.redeemRequestStatus(SUSDE, 0, user).state), uint8(RequestState.None));

        vm.prank(user);
        uint256 assets = IStakedUSDeActions(SUSDE).cooldownShares(100e18);
        assertGt(assets, 0);

        RequestStatusLens.Status memory s = lens.redeemRequestStatus(SUSDE, 0, user);
        assertEq(uint8(s.state), uint8(RequestState.Pending));
        assertEq(s.queuedAhead, 0);
        assertEq(s.earliestClaimableAt, block.timestamp + duration);
        assertEq(s.latestClaimableAt, block.timestamp + duration);

        // One second early: still pending, and unstaking really is impossible.
        vm.warp(block.timestamp + duration - 1);
        assertEq(uint8(lens.redeemRequestStatus(SUSDE, 0, user).state), uint8(RequestState.Pending));
        vm.prank(user);
        vm.expectRevert();
        IStakedUSDeActions(SUSDE).unstake(user);

        // At the reported time: claimable, and unstaking really works.
        vm.warp(block.timestamp + 1);
        assertEq(uint8(lens.redeemRequestStatus(SUSDE, 0, user).state), uint8(RequestState.Claimable));
        vm.prank(user);
        IStakedUSDeActions(SUSDE).unstake(user);
        assertEq(uint8(lens.redeemRequestStatus(SUSDE, 0, user).state), uint8(RequestState.None));
    }

    // ---------------------------------------------------------------------------------------------
    // Centrifuge V3: a live ERC-7540 vault served by the generic fallback
    // ---------------------------------------------------------------------------------------------

    function test_centrifuge_genericFallback() public view {
        (RequestStatusLens.Source src,) = lens.sourceOf(CENTRIFUGE_JTRSY);
        assertEq(uint8(src), uint8(RequestStatusLens.Source.Generic));
        RequestStatusLens.Status memory s = lens.redeemRequestStatus(CENTRIFUGE_JTRSY, 0, address(0xdead));
        assertTrue(s.ok);
        assertEq(uint8(s.state), uint8(RequestState.None));
    }
}
