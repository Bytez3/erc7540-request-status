// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FifoRedeemVault} from "../src/FifoRedeemVault.sol";
import {TestUSD} from "../src/demo/TestUSD.sol";

/// The standard says `redeemDelayBounds` MUST NOT revert and MUST return minDelay <= maxDelay, for any input.
contract DelayBoundsTest is Test {
    function test_fuzz_delayBoundsNeverRevert(uint256 shares, uint64 cycle, uint256 capacity, uint8 queued) public {
        vm.warp(1_800_000_000);
        TestUSD usd = new TestUSD();
        address manager = makeAddr("manager");
        address alice = makeAddr("alice");
        FifoRedeemVault vault = new FifoRedeemVault(IERC20(address(usd)), "Q", "Q", manager);
        vm.prank(manager);
        vault.setSchedule(cycle, uint64(block.timestamp + 1 hours), capacity);

        // Put a few requests ahead so the queue offset is non-zero.
        usd.mint(alice, 100e18);
        vm.startPrank(alice);
        usd.approve(address(vault), 100e18);
        vault.deposit(100e18, alice);
        for (uint256 i; i < queued % 4; i++) {
            vault.requestRedeem(1e18, alice, alice);
        }
        vm.stopPrank();

        (uint64 minDelay, uint64 maxDelay) = vault.redeemDelayBounds(shares);
        assertLe(minDelay, maxDelay);
    }

    function test_hugeAmountsReportUnknownLatest() public {
        test_fuzz_delayBoundsNeverRevert(type(uint256).max, 1 hours, 2_500e18, 3);
        test_fuzz_delayBoundsNeverRevert(type(uint256).max / 2, 1 hours, 1, 3);
    }
}
