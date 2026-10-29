// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @dev Minimal ERC-7540 interfaces (https://eips.ethereum.org/EIPS/eip-7540).
/// OpenZeppelin Contracts does not ship ERC-7540, so the subset needed here is declared locally.

interface IERC7540Operator {
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    function setOperator(address operator, bool approved) external returns (bool);
    function isOperator(address controller, address operator) external view returns (bool);
}

interface IERC7540Redeem is IERC7540Operator {
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
}
