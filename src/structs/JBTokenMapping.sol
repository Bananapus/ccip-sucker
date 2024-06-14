// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct JBTokenMapping {
    address localToken;
    uint32 minGas;
    address remoteToken;
    uint64 remoteSelector;
    uint256 minBridgeAmount;
}
