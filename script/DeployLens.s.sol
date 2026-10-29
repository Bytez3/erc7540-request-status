// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {RequestStatusLens} from "../src/lens/RequestStatusLens.sol";
import {ERC7540Adapter} from "../src/lens/adapters/ERC7540Adapter.sol";
import {EthenaCooldownAdapter} from "../src/lens/adapters/EthenaCooldownAdapter.sol";
import {
    ILidoAccountingOracle,
    ILidoHashConsensus,
    LidoWithdrawalQueueAdapter
} from "../src/lens/adapters/LidoWithdrawalQueueAdapter.sol";

/// @notice Deploys the read-only RequestStatusLens with its generic ERC-7540 adapter and, on Ethereum mainnet,
/// the Lido and Ethena adapters (addresses verified in docs/research/queue-interfaces.md).
///
/// Usage (the deployer key stays in your own Foundry keystore):
///   forge script script/DeployLens.s.sol --rpc-url <rpc> --account <keystore-name> --broadcast --verify
///
/// Env:
///   LENS_OWNER  optional final owner (use a multisig on mainnet). Adapters are registered by the deployer first;
///               ownership is then offered to LENS_OWNER, who must call acceptOwnership() (two-step transfer).
contract DeployLens is Script {
    // Ethereum mainnet
    address constant LIDO_WQ = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    address constant LIDO_HASH_CONSENSUS = 0xD624B08C83bAECF0807Dd2c6880C3154a5F0B288;
    address constant LIDO_ACCOUNTING_ORACLE = 0x852deD011285fe67063a08005c71a85690503Cee;
    uint256 constant LIDO_REQUEST_TIMESTAMP_MARGIN = 7_680; // OracleReportSanityChecker, read live 2026-10-29
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    function run() external returns (RequestStatusLens lens) {
        address owner = vm.envOr("LENS_OWNER", msg.sender);

        vm.startBroadcast();
        ERC7540Adapter generic = new ERC7540Adapter();
        lens = new RequestStatusLens(msg.sender, generic);
        console.log("chainid                 ", block.chainid);
        console.log("ERC7540Adapter          ", address(generic));
        console.log("RequestStatusLens       ", address(lens));

        if (block.chainid == 1) {
            LidoWithdrawalQueueAdapter lido = new LidoWithdrawalQueueAdapter(
                ILidoHashConsensus(LIDO_HASH_CONSENSUS),
                ILidoAccountingOracle(LIDO_ACCOUNTING_ORACLE),
                LIDO_REQUEST_TIMESTAMP_MARGIN
            );
            EthenaCooldownAdapter ethena = new EthenaCooldownAdapter();
            lens.setAdapter(LIDO_WQ, lido);
            lens.setAdapter(SUSDE, ethena);
            console.log("LidoWithdrawalQueueAdapter", address(lido));
            console.log("EthenaCooldownAdapter     ", address(ethena));
        }

        if (owner != msg.sender) {
            lens.transferOwnership(owner);
            console.log("ownership offered to    ", owner, "(must call acceptOwnership)");
        }
        vm.stopBroadcast();
    }
}
