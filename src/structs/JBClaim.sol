// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBLeaf} from "./JBLeaf.sol";

struct JBClaim {
    address token;
    uint64 remoteSelector;
    JBLeaf leaf;
    // Must be `JBSucker.TREE_DEPTH` long.
    bytes32[32] proof;
}
