// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJBPrices} from "@bananapus/core/src/interfaces/IJBPrices.sol";
import {IJBRulesets} from "@bananapus/core/src/interfaces/IJBRulesets.sol";
import {IJBDirectory} from "@bananapus/core/src/interfaces/IJBDirectory.sol";
import {IJBTokens} from "@bananapus/core/src/interfaces/IJBTokens.sol";
import {IJBPermissions} from "@bananapus/core/src/interfaces/IJBPermissions.sol";
import {JBConstants} from "@bananapus/core/src/libraries/JBConstants.sol";

import {JBSucker, JBAddToBalanceMode} from "./JBSucker.sol";
import {JBMessageRoot} from "./structs/JBMessageRoot.sol";
import {JBRemoteToken} from "./structs/JBRemoteToken.sol";
import {JBInboxTreeRoot} from "./structs/JBInboxTreeRoot.sol";
import {JBCCIPSuckerDeployer} from "./deployers/JBCCIPSuckerDeployer.sol";
import {MerkleLib} from "./utils/MerkleLib.sol";

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";

import {CCIPHelper} from "src/libraries/CCIPHelper.sol";

/// @notice A `JBSucker` implementation to suck tokens between chains with Chainlink CCIP
contract JBCCIPSucker is JBSucker {
    using MerkleLib for MerkleLib.Tree;
    using BitMaps for BitMaps.BitMap;

    event SuckingToRemote(address token, uint64 nonce);

    error NotEnoughBalance(uint256 balance, uint256 fees);

    error FailedToRefundFee();

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    constructor(IJBDirectory directory, IJBTokens tokens, IJBPermissions permissions, JBAddToBalanceMode atbMode)
        JBSucker(directory, tokens, permissions, atbMode)
    {}

    //*********************************************************************//
    // ------------------------ external views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the chain on which the peer is located.
    /// @return chainId of the peer.
    /// TODO: Check this, maybe remove from impl or return dummy info to keep interface the same.
    function peerChainID() external view virtual override returns (uint256 chainId) {}

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Use the `OPMESSENGER` to send the outbox tree for the `token` and the corresponding funds to the peer over the `OPBRIDGE`.
    /// @param transportPayment the amount of `msg.value` that is going to get paid for sending this message.
    /// @param token The token to bridge the outbox tree for.
    /// @param remoteToken Information about the remote token being bridged to.
    function _sendRoot(uint256 transportPayment, address token, JBRemoteToken memory remoteToken, uint64 remoteSelector)
        internal
        override
    {
        // TODO: Require transportPayment, CCIP expects to be paid
        if (transportPayment == 0) {
            revert UNEXPECTED_MSG_VALUE();
        }

        // Get the amount to send and then clear it from the outbox tree.
        uint256 amount = outbox[token][remoteSelector].balance;
        delete outbox[token][remoteSelector].balance;

        // Increment the outbox tree's nonce.
        uint64 nonce = ++outbox[token][remoteSelector].nonce;

        // Ensure the token is mapped to an address on the remote chain.
        // TODO: re-enable
        if (remoteToken.addr == address(0)) {
            revert TOKEN_NOT_MAPPED(token);
        }

        bytes32 _root = outbox[token][remoteSelector].tree.root();
        uint256 _index = outbox[token][remoteSelector].tree.count - 1;

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage({
            _receiver: address(this), // Global omni-chain address for BP-CCIP
            _root: JBMessageRoot({
                token: remoteToken.addr,
                amount: amount,
                remoteSelector: CCIPHelper.selectorOfChain(block.chainid),
                remoteRoot: JBInboxTreeRoot({nonce: nonce, root: _root})
            }),
            _token: token,
            _amount: amount,
            _feeTokenAddress: address(0) // Paid in native
        });

        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());

        // Get the fee required to send the CCIP message
        uint256 fees = router.getFee({destinationChainSelector: remoteSelector, message: evm2AnyMessage});

        if (fees > transportPayment) {
            revert NotEnoughBalance(transportPayment, fees);
        }

        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        IERC20(token).approve(address(router), amount);

        // TODO: Handle this messageId, maybe necessary
        // Send the message through the router and store the returned message ID
        /* messageId =  */
        router.ccipSend{value: fees}({destinationChainSelector: remoteSelector, message: evm2AnyMessage});

        // TODO: Refund remaining balance.
        (bool sent,) = msg.sender.call{value: msg.value - fees}("");
        if (!sent) revert FailedToRefundFee();

        // Emit an event for the relayers to watch for.
        emit RootToRemote(_root, token, _index, nonce);
    }

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for programmable tokens transfer.
    /// @param _receiver The address of the receiver.
    /// @param _root The root to be sent.
    /// @param _token The token to be transferred.
    /// @param _amount The amount of the token to be transferred.
    /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessage(
        address _receiver,
        JBMessageRoot memory _root,
        address _token,
        uint256 _amount,
        address _feeTokenAddress
    ) private pure returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: _token, amount: _amount});
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        return Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver), // ABI-encoded receiver address
            data: abi.encode(_root), // ABI-encoded string
            tokenAmounts: tokenAmounts, // The amount and type of token being transferred
            extraArgs: Client._argsToBytes(
                // Additional arguments, setting gas limit
                Client.EVMExtraArgsV1({gasLimit: 300_000})
            ),
            // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
            feeToken: _feeTokenAddress
        });
    }
}
