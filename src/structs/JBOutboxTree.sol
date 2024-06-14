// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MerkleLib} from "../utils/MerkleLib.sol";

/// @notice A merkle tree used to track the outbox for a given token in a `JBSucker`.
/// @dev The outbox is used to send from the local chain to the remote chain.
struct JBOutboxTree {
    uint64 nonce;
    uint256 balance;
    MerkleLib.Tree tree;
}
