// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {RequestStatusLens} from "../src/lens/RequestStatusLens.sol";
import {ERC7540Adapter} from "../src/lens/adapters/ERC7540Adapter.sol";

/// @notice Deploys the read-only RequestStatusLens and its generic ERC-7540 adapter.
/// Chain-specific adapters (Lido, Ethena, ...) are deployed and registered by `RegisterAdapters`.
///
/// Usage (the deployer key stays in your own Foundry keystore):
///   forge script script/DeployLens.s.sol --rpc-url <rpc> --account <keystore-name> --broadcast --verify
///
/// Env:
///   LENS_OWNER  optional, defaults to the broadcasting account. Use a multisig for mainnet.
contract DeployLens is Script {
    function run() external returns (RequestStatusLens lens, ERC7540Adapter generic) {
        address owner = vm.envOr("LENS_OWNER", msg.sender);

        vm.startBroadcast();
        generic = new ERC7540Adapter();
        lens = new RequestStatusLens(owner, generic);
        vm.stopBroadcast();

        console.log("chainid           ", block.chainid);
        console.log("ERC7540Adapter    ", address(generic));
        console.log("RequestStatusLens ", address(lens));
        console.log("lens owner        ", owner);
    }
}
