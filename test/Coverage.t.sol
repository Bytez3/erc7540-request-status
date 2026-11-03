// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FifoRedeemVault} from "../src/FifoRedeemVault.sol";
import {TestUSD} from "../src/demo/TestUSD.sol";
import {RequestState} from "../src/interfaces/IERC7540RequestStatus.sol";

/// Closes the remaining coverage gaps reported by `forge coverage`.
contract CoverageGapsTest is Test {
    function test_uncappedOverdueCycleReportsNowAndOpenUpperBound() public {
        vm.warp(1_800_000_000);
        TestUSD usd = new TestUSD();
        address manager = makeAddr("manager");
        address alice = makeAddr("alice");
        FifoRedeemVault vault = new FifoRedeemVault(IERC20(address(usd)), "Q", "Q", manager);
        vm.prank(manager);
        vault.setSchedule(1 hours, uint64(block.timestamp + 1 hours), 0); // uncapped

        usd.mint(alice, 100e18);
        vm.startPrank(alice);
        usd.approve(address(vault), 100e18);
        vault.deposit(100e18, alice);
        uint256 id = vault.requestRedeem(50e18, alice, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 3 hours); // the cycle is overdue and could open right now
        (RequestState s,, uint64 e, uint64 l) = vault.redeemRequestStatus(id, alice);
        assertEq(uint8(s), uint8(RequestState.Pending));
        assertEq(e, block.timestamp);
        assertEq(l, type(uint64).max);
    }
}

contract TestUSDTest is Test {
    function test_metadataAndFaucet() public {
        TestUSD usd = new TestUSD();
        assertEq(usd.name(), "Bytez3 Test USD");
        assertEq(usd.symbol(), "b3tUSD");
        usd.mint(address(this), usd.MINT_LIMIT());
        assertEq(usd.balanceOf(address(this)), 100_000e18);
    }

    function test_mintLimit() public {
        TestUSD usd = new TestUSD();
        uint256 limit = usd.MINT_LIMIT();
        vm.expectRevert(TestUSD.OverMintLimit.selector);
        usd.mint(address(this), limit + 1);
    }

    function test_refusesEthereumMainnet() public {
        vm.chainId(1);
        vm.expectRevert(TestUSD.MainnetNotAllowed.selector);
        new TestUSD();
    }

    function test_refusesBase() public {
        vm.chainId(8453);
        vm.expectRevert(TestUSD.MainnetNotAllowed.selector);
        new TestUSD();
    }
}
