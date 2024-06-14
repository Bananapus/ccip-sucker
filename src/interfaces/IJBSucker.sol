// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBTokenMapping} from "../structs/JBTokenMapping.sol";

interface IJBSucker {
    function PEER() external view returns (address);

    function peerChainID() external view returns (uint256 chainId);

    function isMapped(address token) external view returns (bool);

    function prepare(
        uint256 projectTokenAmount,
        address beneficiary,
        uint256 minTokensReclaimed,
        address token,
        uint64 chainSelector
    ) external;

    function mapToken(JBTokenMapping calldata map) external;

    function mapTokens(JBTokenMapping[] calldata maps) external;

    event NewInboxTreeRoot(address indexed token, uint64 nonce, bytes32 root);

    event RootToRemote(bytes32 indexed root, address indexed terminalToken, uint256 index, uint64 nonce);

    event Claimed(
        address beneficiary,
        address token,
        uint256 projectTokenAmount,
        uint256 terminalTokenAmount,
        uint256 index,
        bool autoAddedToBalance
    );

    event InsertToOutboxTree(
        address indexed beneficiary,
        address indexed terminalToken,
        bytes32 hashed,
        uint256 index,
        bytes32 root,
        uint256 projectTokenAmount,
        uint256 terminalTokenAmount
    );
}
