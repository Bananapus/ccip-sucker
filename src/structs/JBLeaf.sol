// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A leaf in the inbox or outbox tree of a `JBSucker`. Used to `claim` tokens from the inbox tree.
struct JBLeaf {
    uint256 index;
    address beneficiary;
    uint256 projectTokenAmount;
    uint256 terminalTokenAmount;
}
