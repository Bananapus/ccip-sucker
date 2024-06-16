// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBInboxTreeRoot} from "./JBInboxTreeRoot.sol";

/// @notice Information about the remote (inbox) tree's root, passed in a message from the remote chain.
/// @custom:member The address of the terminal token that the tree tracks.
/// @custom:member The amount of tokens being sent.
/// @custom:member The origin chain selector.
/// @custom:member The root of the merkle tree.
struct JBMessageRoot {
    address token;
    uint256 amount;
    uint64 remoteSelector;
    JBInboxTreeRoot remoteRoot;
}
