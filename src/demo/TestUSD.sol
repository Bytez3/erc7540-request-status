// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestUSD
/// @author Steven Isaac (@SteOnChain), Bytez3 (https://www.bytez3.com)
/// @notice TESTNET ONLY. A worthless dollar-like token anyone can mint, used by the Bytez3 queue tracker demo.
/// @dev The constructor refuses to deploy on Ethereum mainnet and Base so it can never be mistaken for value.
contract TestUSD is ERC20 {
    uint256 public constant MINT_LIMIT = 100_000e18;

    error MainnetNotAllowed();
    error OverMintLimit();

    constructor() ERC20("Bytez3 Test USD", "b3tUSD") {
        if (block.chainid == 1 || block.chainid == 8453) revert MainnetNotAllowed();
    }

    /// @notice Faucet: mint up to `MINT_LIMIT` per call to any address.
    function mint(address to, uint256 amount) external {
        if (amount > MINT_LIMIT) revert OverMintLimit();
        _mint(to, amount);
    }
}
