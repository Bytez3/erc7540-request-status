// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IERC7540RedeemStatus, RequestState} from "../interfaces/IERC7540RequestStatus.sol";
import {IRequestStatusAdapter} from "./IRequestStatusAdapter.sol";

/// @title RequestStatusLens
/// @author Steven Isaac (@SteOnChain), Bytez3 (https://www.bytez3.com)
/// @notice One read-only entry point for ERC-XXXX request status across any withdrawal queue.
///
/// Resolution order for a vault:
///   1. `Native`  - the vault implements ERC-XXXX itself, so it is asked directly (most authoritative).
///   2. `Adapter` - an adapter registered for this vault (e.g. Lido, Ethena), which translates its native queue.
///   3. `Generic` - the vault implements ERC-7540, so the generic adapter reports what 7540 exposes.
/// Anything else is `Unsupported`.
///
/// @dev Holds no funds and has no effect on any vault. The owner can only map vaults to adapters.
contract RequestStatusLens is Ownable2Step {
    enum Source {
        Unsupported,
        Native,
        Adapter,
        Generic
    }

    struct Status {
        Source source;
        bool ok; // false if the underlying call reverted (batch queries only)
        RequestState state;
        uint256 queuedAhead;
        uint64 earliestClaimableAt;
        uint64 latestClaimableAt;
    }

    struct Query {
        address vault;
        uint256 requestId;
        address controller;
    }

    bytes4 public constant REDEEM_STATUS_INTERFACE_ID = 0x2522a9c4; // ERC-XXXX IERC7540RedeemStatus
    bytes4 public constant ERC7540_REDEEM_INTERFACE_ID = 0x620ee8e4; // ERC-7540 IERC7540Redeem

    // forge-lint: disable-next-line(screaming-snake-case-immutable) (keeps the public getter readable)
    IRequestStatusAdapter public immutable genericAdapter;
    mapping(address vault => IRequestStatusAdapter) public adapterOf;

    event AdapterSet(address indexed vault, address indexed adapter);

    error Unsupported(address vault);

    constructor(address owner_, IRequestStatusAdapter genericAdapter_) Ownable(owner_) {
        genericAdapter = genericAdapter_;
    }

    /// @notice Registers (or, with `address(0)`, removes) the adapter used for `vault`.
    function setAdapter(address vault, IRequestStatusAdapter adapter) external onlyOwner {
        adapterOf[vault] = adapter;
        emit AdapterSet(vault, address(adapter));
    }

    /// @notice How the lens would answer for `vault`, and which contract it would ask.
    function sourceOf(address vault) public view returns (Source source, address target) {
        if (ERC165Checker.supportsInterface(vault, REDEEM_STATUS_INTERFACE_ID)) return (Source.Native, vault);
        IRequestStatusAdapter adapter = adapterOf[vault];
        if (address(adapter) != address(0)) return (Source.Adapter, address(adapter));
        if (ERC165Checker.supportsInterface(vault, ERC7540_REDEEM_INTERFACE_ID)) {
            return (Source.Generic, address(genericAdapter));
        }
        return (Source.Unsupported, address(0));
    }

    /// @notice ERC-XXXX status of the redeem Request (`requestId`, `controller`) at `vault`. Reverts if unsupported.
    function redeemRequestStatus(address vault, uint256 requestId, address controller)
        public
        view
        returns (Status memory s)
    {
        (Source source, address target) = sourceOf(vault);
        s.source = source;
        if (source == Source.Native) {
            (s.state, s.queuedAhead, s.earliestClaimableAt, s.latestClaimableAt) =
                IERC7540RedeemStatus(vault).redeemRequestStatus(requestId, controller);
        } else if (source == Source.Adapter || source == Source.Generic) {
            (s.state, s.queuedAhead, s.earliestClaimableAt, s.latestClaimableAt) =
                IRequestStatusAdapter(target).redeemRequestStatus(vault, requestId, controller);
        } else {
            revert Unsupported(vault);
        }
        s.ok = true;
    }

    /// @notice Many queries in one call. A query that fails returns `ok == false` instead of reverting the batch.
    /// @dev Each query is an external self-call so a reverting vault or adapter can be caught with try/catch.
    // slither-disable-start calls-loop,var-read-using-this
    function redeemRequestStatusBatch(Query[] calldata queries) external view returns (Status[] memory out) {
        out = new Status[](queries.length);
        for (uint256 i; i < queries.length; i++) {
            Query calldata q = queries[i];
            try this.redeemRequestStatus(q.vault, q.requestId, q.controller) returns (Status memory s) {
                out[i] = s;
            } catch {
                (out[i].source,) = sourceOf(q.vault);
            }
        }
    }

    // slither-disable-end calls-loop,var-read-using-this

    /// @notice Open request ids for `controller` at `vault`, where they can be enumerated on-chain.
    /// @dev Empty for native vaults and for adapters that cannot enumerate; discover those off-chain from events.
    function requestIdsOf(address vault, address controller) external view returns (uint256[] memory) {
        (Source source, address target) = sourceOf(vault);
        if (source == Source.Adapter || source == Source.Generic) {
            return IRequestStatusAdapter(target).requestIdsOf(vault, controller);
        }
        return new uint256[](0);
    }
}
