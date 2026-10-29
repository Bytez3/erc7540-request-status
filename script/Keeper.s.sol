// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {FifoRedeemVault} from "../src/FifoRedeemVault.sol";
import {TestUSD} from "../src/demo/TestUSD.sol";

/// @notice TESTNET ONLY. Runs one processing step for the demo vault so the tracker shows a moving queue:
/// fulfills the next cycle if one is open, and tops the queue back up when it runs low.
///
/// Usage:
///   DEMO_VAULT=<address> forge script script/Keeper.s.sol --rpc-url <testnet-rpc> --account <keystore> --broadcast
contract Keeper is Script {
    error MainnetNotAllowed();

    function run() external {
        if (block.chainid == 1 || block.chainid == 8453) revert MainnetNotAllowed();
        FifoRedeemVault vault = FifoRedeemVault(vm.envAddress("DEMO_VAULT"));

        // Only send a fulfillment when it can actually pay something out: a new cycle can open, or the open cycle
        // still has capacity left.
        uint256 cap = vault.capacityPerCycle();
        bool cycleReady = block.timestamp >= vault.nextCycleAt()
            || (vault.cycleOpen() && (cap == 0 || vault.fulfilledInCycle() < cap));
        uint256 outstanding = vault.totalQueued() - vault.totalProcessed();

        vm.startBroadcast();
        // The wallet actually broadcasting; inside a script `msg.sender` is not this address.
        (, address keeper,) = vm.readCallers();
        if (cycleReady && outstanding > 0) {
            uint256 done = vault.fulfillRedeem(type(uint256).max, 50);
            console.log("fulfilled shares", done);
        }
        // Keep the demo alive: when the line gets short, claim the manager's own payouts, top up with test
        // dollars, and join the back of the queue again.
        if (outstanding < vault.capacityPerCycle()) {
            uint256 claimable = vault.maxRedeem(keeper);
            if (claimable > 0) vault.redeem(claimable, keeper, keeper);

            TestUSD usd = TestUSD(vault.asset());
            usd.mint(keeper, 1_000e18);
            uint256 assets = usd.balanceOf(keeper);
            usd.approve(address(vault), assets);
            uint256 shares = vault.deposit(assets, keeper);
            vault.requestRedeem(shares, keeper, keeper);
            console.log("re-queued shares", shares);
        }
        vm.stopBroadcast();
    }
}
