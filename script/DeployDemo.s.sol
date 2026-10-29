// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FifoRedeemVault} from "../src/FifoRedeemVault.sol";
import {TestUSD} from "../src/demo/TestUSD.sol";

/// @notice TESTNET ONLY. Deploys a live demo of the standard for the Bytez3 queue tracker: a worthless test dollar,
/// a FifoRedeemVault with hourly cycles, and a seeded queue of redemption requests across several controllers.
///
/// Usage:
///   forge script script/DeployDemo.s.sol --rpc-url <testnet-rpc> --account <keystore-name> --broadcast --verify
///
/// Env (all optional):
///   DEMO_CYCLE     seconds per processing cycle   (default 3600)
///   DEMO_CAPACITY  shares fulfilled per cycle     (default 2,500e18)
contract DeployDemo is Script {
    error MainnetNotAllowed();

    function run() external returns (TestUSD usd, FifoRedeemVault vault) {
        if (block.chainid == 1 || block.chainid == 8453) revert MainnetNotAllowed();

        uint64 cycle = uint64(vm.envOr("DEMO_CYCLE", uint256(3600)));
        uint256 capacity = vm.envOr("DEMO_CAPACITY", uint256(2_500e18));
        address deployer = msg.sender;

        // Demo controllers so the queue shows several independent positions. Nobody holds these keys; they exist
        // only so the tracker has realistic data. The deployer, as owner of the shares, creates every request.
        address[4] memory controllers = [
            deployer,
            address(uint160(uint256(keccak256("bytez3.demo.controller.1")))),
            address(uint160(uint256(keccak256("bytez3.demo.controller.2")))),
            address(uint160(uint256(keccak256("bytez3.demo.controller.3"))))
        ];
        uint256[6] memory sizes = [uint256(1_200e18), 800e18, 1_500e18, 2_000e18, 600e18, 1_900e18];

        vm.startBroadcast();
        usd = new TestUSD();
        vault = new FifoRedeemVault(IERC20(address(usd)), "Bytez3 Demo Queue Vault", "b3DQV", deployer);
        vault.setSchedule(cycle, uint64(block.timestamp) + cycle, capacity);

        usd.mint(deployer, 10_000e18);
        usd.approve(address(vault), 10_000e18);
        vault.deposit(10_000e18, deployer);
        for (uint256 i; i < sizes.length; i++) {
            vault.requestRedeem(sizes[i], controllers[i % 4], deployer);
        }
        vm.stopBroadcast();

        console.log("chainid            ", block.chainid);
        console.log("TestUSD            ", address(usd));
        console.log("FifoRedeemVault    ", address(vault));
        console.log("manager            ", deployer);
        console.log("cycle (s)          ", cycle);
        console.log("requests seeded    ", sizes.length);
    }
}
