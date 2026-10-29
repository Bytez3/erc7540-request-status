// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {RequestState} from "../../src/interfaces/IERC7540RequestStatus.sol";
import {
    ILidoAccountingOracle,
    ILidoHashConsensus,
    ILidoWithdrawalQueue,
    LidoWithdrawalQueueAdapter
} from "../../src/lens/adapters/LidoWithdrawalQueueAdapter.sol";
import {EthenaCooldownAdapter} from "../../src/lens/adapters/EthenaCooldownAdapter.sol";

// -------------------------------------------------------------------------------------------------
// Mocks reproducing the exact interfaces of the live contracts
// -------------------------------------------------------------------------------------------------

contract MockLidoQueue {
    ILidoWithdrawalQueue.WithdrawalRequestStatus[] internal reqs; // index = id - 1
    uint256 public getLastFinalizedRequestId;
    bool public isPaused;
    uint256 public getResumeSinceTimestamp = type(uint256).max;
    bool public isBunkerModeActive;

    function add(address owner, uint256 steth, uint256 timestamp) external returns (uint256 id) {
        reqs.push(
            ILidoWithdrawalQueue.WithdrawalRequestStatus({
                amountOfStETH: steth,
                amountOfShares: steth,
                owner: owner,
                timestamp: timestamp,
                isFinalized: false,
                isClaimed: false
            })
        );
        id = reqs.length;
    }

    function finalizeUpTo(uint256 id) external {
        for (uint256 i = getLastFinalizedRequestId; i < id; i++) {
            reqs[i].isFinalized = true;
        }
        getLastFinalizedRequestId = id;
    }

    function claim(uint256 id) external {
        reqs[id - 1].isClaimed = true;
    }

    function setPaused(bool p, uint256 resumeSince) external {
        isPaused = p;
        getResumeSinceTimestamp = resumeSince;
    }

    function setBunker(bool b) external {
        isBunkerModeActive = b;
    }

    function getLastRequestId() external view returns (uint256) {
        return reqs.length;
    }

    function getWithdrawalStatus(uint256[] calldata ids)
        external
        view
        returns (ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory out)
    {
        out = new ILidoWithdrawalQueue.WithdrawalRequestStatus[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            out[i] = reqs[ids[i] - 1];
        }
    }

    function getWithdrawalRequests(address owner) external view returns (uint256[] memory ids) {
        uint256 n;
        for (uint256 i; i < reqs.length; i++) {
            if (reqs[i].owner == owner && !reqs[i].isClaimed) n++;
        }
        ids = new uint256[](n);
        n = 0;
        for (uint256 i; i < reqs.length; i++) {
            if (reqs[i].owner == owner && !reqs[i].isClaimed) ids[n++] = i + 1;
        }
    }
}

contract MockHashConsensus {
    uint256 public refSlot;

    function setRefSlot(uint256 s) external {
        refSlot = s;
    }

    function getChainConfig() external pure returns (uint256, uint256, uint256) {
        return (32, 12, 1_606_824_023); // mainnet values
    }

    function getFrameConfig() external pure returns (uint256, uint256, uint256) {
        return (201_600, 225, 100); // mainnet values: one frame = 1 day
    }

    function getCurrentFrame() external view returns (uint256, uint256) {
        return (refSlot, refSlot + 7200);
    }
}

contract MockAccountingOracle {
    uint256 public getLastProcessingRefSlot;

    function setLastProcessed(uint256 s) external {
        getLastProcessingRefSlot = s;
    }
}

contract MockSUSDe {
    struct Cooldown {
        uint104 cooldownEnd;
        uint152 underlyingAmount;
    }

    mapping(address => Cooldown) public cooldowns;
    uint24 public cooldownDuration = 1 days;

    function set(address who, uint104 end, uint152 amount) external {
        cooldowns[who] = Cooldown({cooldownEnd: end, underlyingAmount: amount});
    }

    function setDuration(uint24 d) external {
        cooldownDuration = d;
    }
}

// -------------------------------------------------------------------------------------------------
// Lido
// -------------------------------------------------------------------------------------------------

contract LidoAdapterTest is Test {
    uint256 constant GENESIS = 1_606_824_023;
    uint256 constant FRAME = 86_400;
    uint256 constant MARGIN = 7_680;
    uint256 constant REF_SLOT = 15_537_599; // live mainnet refSlot on 2026-10-29
    uint256 constant REF_TIME = GENESIS + REF_SLOT * 12; // 2026-10-29 12:00:11 UTC

    MockLidoQueue q;
    MockHashConsensus hc;
    MockAccountingOracle ao;
    LidoWithdrawalQueueAdapter adapter;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        q = new MockLidoQueue();
        hc = new MockHashConsensus();
        ao = new MockAccountingOracle();
        hc.setRefSlot(REF_SLOT);
        adapter =
            new LidoWithdrawalQueueAdapter(ILidoHashConsensus(address(hc)), ILidoAccountingOracle(address(ao)), MARGIN);
    }

    function _status(uint256 id, address who) internal view returns (RequestState s, uint256 a, uint64 e, uint64 l) {
        return adapter.redeemRequestStatus(address(q), id, who);
    }

    function test_unknownIdsAndWrongOwnerAreNone() public {
        uint256 id = q.add(alice, 1 ether, REF_TIME - 1 days);
        (RequestState s,,,) = _status(0, alice);
        assertEq(uint8(s), uint8(RequestState.None));
        (s,,,) = _status(id + 1, alice);
        assertEq(uint8(s), uint8(RequestState.None));
        (s,,,) = _status(id, bob);
        assertEq(uint8(s), uint8(RequestState.None));
    }

    function test_finalizedIsClaimableThenNoneOnceClaimed() public {
        uint256 id = q.add(alice, 1 ether, REF_TIME - 1 days);
        q.finalizeUpTo(id);
        (RequestState s, uint256 a, uint64 e, uint64 l) = _status(id, alice);
        assertEq(uint8(s), uint8(RequestState.Claimable));
        assertEq(a, 0);
        assertEq(e, 0);
        assertEq(l, 0);
        q.claim(id);
        (s,,,) = _status(id, alice);
        assertEq(uint8(s), uint8(RequestState.None));
    }

    function test_queuedAheadSumsUnfinalizedStETH() public {
        q.add(bob, 5 ether, REF_TIME - 3 days);
        q.finalizeUpTo(1);
        q.add(bob, 2 ether, REF_TIME - 2 days);
        q.add(bob, 3 ether, REF_TIME - 2 days);
        uint256 id = q.add(alice, 1 ether, REF_TIME - 1 days);
        (RequestState s, uint256 ahead,, uint64 l) = _status(id, alice);
        assertEq(uint8(s), uint8(RequestState.Pending));
        assertEq(ahead, 5 ether, "only unfinalized requests ahead count");
        assertEq(l, type(uint64).max, "no on-chain upper bound");
    }

    function test_earliestIsCurrentFrameWhenUnprocessedAndOldEnough() public {
        ao.setLastProcessed(REF_SLOT - 7200); // this frame's report still pending
        vm.warp(REF_TIME + 30 minutes);
        uint256 id = q.add(alice, 1 ether, REF_TIME - MARGIN);
        (,, uint64 e,) = _status(id, alice);
        assertEq(e, block.timestamp, "the pending report could finalize it any moment");
    }

    function test_earliestSkipsProcessedFrame() public {
        ao.setLastProcessed(REF_SLOT); // today's report already processed
        vm.warp(REF_TIME + 1 hours);
        uint256 id = q.add(alice, 1 ether, REF_TIME + 1 hours);
        (,, uint64 e,) = _status(id, alice);
        assertEq(e, REF_TIME + FRAME, "next day's reference slot");
    }

    function test_earliestRespectsTimestampMargin() public {
        ao.setLastProcessed(REF_SLOT);
        // Requested 1 hour before the next reference slot: younger than the 2h08m margin, so it misses that report.
        uint256 requestedAt = REF_TIME + FRAME - 1 hours;
        vm.warp(requestedAt);
        uint256 id = q.add(alice, 1 ether, requestedAt);
        (,, uint64 e,) = _status(id, alice);
        assertEq(e, REF_TIME + 2 * FRAME);
    }

    function test_earliestExactlyAtMarginBoundary() public {
        ao.setLastProcessed(REF_SLOT);
        uint256 requestedAt = REF_TIME + FRAME - MARGIN; // exactly old enough for the next report
        vm.warp(requestedAt);
        uint256 id = q.add(alice, 1 ether, requestedAt);
        (,, uint64 e,) = _status(id, alice);
        assertEq(e, REF_TIME + FRAME);
    }

    function test_pausedIndefinitelyIsSuspendedWithLoosestBounds() public {
        uint256 id = q.add(alice, 1 ether, REF_TIME - 1 days);
        q.setPaused(true, type(uint256).max);
        (RequestState s,, uint64 e, uint64 l) = _status(id, alice);
        assertEq(uint8(s), uint8(RequestState.Suspended));
        assertEq(e, 0);
        assertEq(l, type(uint64).max);
    }

    function test_pausedUntilScheduledResume() public {
        ao.setLastProcessed(REF_SLOT);
        vm.warp(REF_TIME + 1 hours);
        uint256 id = q.add(alice, 1 ether, REF_TIME - 1 days);
        q.setPaused(true, REF_TIME + 3 days);
        (RequestState s,, uint64 e,) = _status(id, alice);
        assertEq(uint8(s), uint8(RequestState.Suspended));
        assertEq(e, REF_TIME + 3 days, "not before the scheduled resumption");
    }

    function test_bunkerModeIsImpairedAndTakesPrecedence() public {
        uint256 id = q.add(alice, 1 ether, REF_TIME - 1 days);
        q.setPaused(true, type(uint256).max);
        q.setBunker(true);
        (RequestState s,,,) = _status(id, alice);
        assertEq(uint8(s), uint8(RequestState.Impaired));
    }

    function test_queuedAheadUnknownBeyondScanLimit() public {
        uint256 limit = adapter.MAX_SCAN();
        for (uint256 i; i <= limit; i++) {
            q.add(bob, 1, REF_TIME - 1 days);
        }
        uint256 id = q.add(alice, 1 ether, REF_TIME - 1 days);
        (, uint256 ahead,,) = _status(id, alice);
        assertEq(ahead, type(uint256).max);
    }

    function test_requestIdsOf() public {
        q.add(alice, 1, 0);
        q.add(bob, 1, 0);
        q.add(alice, 1, 0);
        uint256[] memory ids = adapter.requestIdsOf(address(q), alice);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 3);
    }

    /// Whatever the timing inputs, the bounds stay ordered and never point into the past.
    function testFuzz_boundsOrderedAndNotPast(uint32 sinceRef, uint32 age, bool processed) public {
        ao.setLastProcessed(processed ? REF_SLOT : REF_SLOT - 7200);
        uint256 nowTs = REF_TIME + bound(sinceRef, 0, FRAME - 1);
        vm.warp(nowTs);
        uint256 id = q.add(alice, 1 ether, nowTs - bound(age, 0, 30 days));
        (,, uint64 e, uint64 l) = _status(id, alice);
        assertGe(e, block.timestamp);
        assertLe(e, l);
        assertLe(e, block.timestamp + 2 * FRAME + MARGIN, "never more than two frames away");
    }
}

// -------------------------------------------------------------------------------------------------
// Ethena
// -------------------------------------------------------------------------------------------------

contract EthenaAdapterTest is Test {
    MockSUSDe s;
    EthenaCooldownAdapter adapter;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        s = new MockSUSDe();
        adapter = new EthenaCooldownAdapter();
    }

    function test_noCooldownIsNone() public view {
        (RequestState st,,,) = adapter.redeemRequestStatus(address(s), 0, alice);
        assertEq(uint8(st), uint8(RequestState.None));
    }

    function test_activeCooldownHasExactTime() public {
        uint104 end = uint104(block.timestamp + 1 days);
        s.set(alice, end, 100e18);
        (RequestState st, uint256 ahead, uint64 e, uint64 l) = adapter.redeemRequestStatus(address(s), 0, alice);
        assertEq(uint8(st), uint8(RequestState.Pending));
        assertEq(ahead, 0);
        assertEq(e, end);
        assertEq(l, end);
    }

    function test_endedCooldownIsClaimable() public {
        s.set(alice, uint104(block.timestamp), 100e18);
        (RequestState st,,,) = adapter.redeemRequestStatus(address(s), 0, alice);
        assertEq(uint8(st), uint8(RequestState.Claimable));
    }

    function test_zeroDurationMakesEverythingClaimable() public {
        s.set(alice, uint104(block.timestamp + 1 days), 100e18);
        s.setDuration(0);
        (RequestState st,,,) = adapter.redeemRequestStatus(address(s), 0, alice);
        assertEq(uint8(st), uint8(RequestState.Claimable));
    }

    function test_nonZeroRequestIdIsNone() public {
        s.set(alice, uint104(block.timestamp + 1 days), 100e18);
        (RequestState st,,,) = adapter.redeemRequestStatus(address(s), 1, alice);
        assertEq(uint8(st), uint8(RequestState.None));
        uint256[] memory ids = adapter.requestIdsOf(address(s), alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], 0);
    }
}
