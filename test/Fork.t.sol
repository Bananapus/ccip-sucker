// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import /* {*} from */ "@bananapus/core/test/helpers/TestBaseWorkflow.sol";
import {MockPriceFeed} from "@bananapus/core/test/mock/MockPriceFeed.sol";
import {IBPSucker} from "../src/interfaces/IBPSucker.sol";
import {IBPSuckerDeployer} from "../src/interfaces/IBPSuckerDeployer.sol";
import {IJBDirectory} from "@bananapus/core/src/interfaces/IJBDirectory.sol";
import {IJBController} from "@bananapus/core/src/interfaces/IJBController.sol";
import {IJBTokens} from "@bananapus/core/src/interfaces/IJBTokens.sol";
import {IJBTerminal} from "@bananapus/core/src/interfaces/IJBTerminal.sol";
import {IJBRedeemTerminal} from "@bananapus/core/src/interfaces/IJBRedeemTerminal.sol";
import {JBConstants} from "@bananapus/core/src/libraries/JBConstants.sol";
import {JBPermissioned} from "@bananapus/core/src/abstract/JBPermissioned.sol";
import {JBPermissionsData} from "@bananapus/core/src/structs/JBPermissionsData.sol";
import {IJBPermissions} from "@bananapus/core/src/interfaces/IJBPermissions.sol";
import {JBPermissionIds} from "@bananapus/permission-ids/src/JBPermissionIds.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BPTokenMapping} from "../src/structs/BPTokenMapping.sol";
import {BPRemoteToken} from "../src/structs/BPRemoteToken.sol";
import {BPOutboxTree} from "../src/structs/BPOutboxTree.sol";
import {BPInboxTreeRoot} from "../src/structs/BPInboxTreeRoot.sol";
import {BPMessageRoot} from "../src/structs/BPMessageRoot.sol";
import {BPClaim} from "../src/structs/BPClaim.sol";
import {BPAddToBalanceMode} from "../src/enums/BPAddToBalanceMode.sol";
import {MerkleLib} from "../src/utils/MerkleLib.sol";

import "forge-std/Test.sol";
import {BPCCIPSucker} from "../src/BPCCIPSucker.sol";
import {BurnMintERC677Helper} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";

import {BPClaim} from "../src/structs/BPClaim.sol";
import {BPLeaf} from "../src/structs/BPClaim.sol";
import {MerkleLib} from "../src/utils/MerkleLib.sol";

contract CCIPSuckerFork is TestBaseWorkflow {
    uint8 private constant _WEIGHT_DECIMALS = 18; // FIXED
    uint8 private constant _NATIVE_DECIMALS = 18; // FIXED
    uint256 private constant _TEST_PRICE_PER_NATIVE = 100 * 10 ** 18; // 2000 test token == 1 native token
    uint256 private _weight = 1000 * 10 ** _WEIGHT_DECIMALS;

    JBRulesetMetadata private _metadata;

    CCIPLocalSimulatorFork public ccipLocalSimulatorFork;
    BPCCIPSucker public suckerGlobal;
    BurnMintERC677Helper public ccipBnM;
    BurnMintERC677Helper public ccipBnMArbSepolia;
    address sender = makeAddr("rootSender");
    /* bytes32 SALT = "SUCKER"; */

    uint256 sepoliaFork;
    uint256 arbSepoliaFork;

    uint64 arbSepoliaChainSelector = 3478487238524512106;
    uint64 ethSepoliaChainSelector = 16015286601757825753;

    IJBToken projectOneToken;

    function setUp() public override {
        // address(0) == peer is the same as address(this) - this being the sucker itself
        address peer = address(0);
        BPAddToBalanceMode atbMode = BPAddToBalanceMode.ON_CLAIM;

        string memory ETHEREUM_SEPOLIA_RPC_URL = vm.envString("RPC_ETHEREUM_SEPOLIA");
        string memory ARBITRUM_SEPOLIA_RPC_URL = vm.envString("RPC_ARBITRUM_SEPOLIA");
        sepoliaFork = vm.createSelectFork(ETHEREUM_SEPOLIA_RPC_URL);

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));
        Register.NetworkDetails memory sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        ccipBnM = BurnMintERC677Helper(sepoliaNetworkDetails.ccipBnMAddress);
        vm.label(address(ccipBnM), "bnmEthSep");
        vm.makePersistent(address(ccipBnM));

        _metadata = JBRulesetMetadata({
            reservedRate: JBConstants.MAX_RESERVED_RATE / 2, //50%
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE, //50%
            baseCurrency: uint32(uint160(address(JBConstants.NATIVE_TOKEN))),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowControllerMigration: false,
            allowSetController: false,
            holdFees: false,
            useTotalSurplusForRedemptions: true,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(0),
            metadata: 0
        });

        // We run setup on our first fork (sepolia) so we have a JBV4 setup
        super.setUp();

        // We deploy our first sucker
        suckerGlobal = new BPCCIPSucker{salt: "SUCKER"}(jbDirectory(), jbTokens(), jbPermissions(), peer, atbMode);

        // setup permissions
        vm.startPrank(multisig());

        // Allows the sucker to mint
        uint256[] memory ids = new uint256[](1);
        ids[0] = 9;

        // permissions to set
        JBPermissionsData memory perms =
            JBPermissionsData({operator: address(suckerGlobal), projectId: 1, permissionIds: ids});

        // Allows our sucker to mint
        jbPermissions().setPermissionsFor(multisig(), perms);

        // Setup: terminal / project
        // Package up the limits for the given terminal.
        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        {
            // Specify a payout limit.
            JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](1);
            _payoutLimits[0] = JBCurrencyAmount({
                amount: 10 * 10 ** _NATIVE_DECIMALS,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });

            // Specify a surplus allowance.
            JBCurrencyAmount[] memory _surplusAllowances = new JBCurrencyAmount[](1);
            _surplusAllowances[0] = JBCurrencyAmount({
                amount: 5 * 10 ** _NATIVE_DECIMALS,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });

            _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
                terminal: address(jbMultiTerminal()),
                token: JBConstants.NATIVE_TOKEN,
                payoutLimits: _payoutLimits,
                surplusAllowances: _surplusAllowances
            });
        }

        {
            // Package up the ruleset configuration.
            JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
            _rulesetConfigurations[0].mustStartAtOrAfter = 0;
            _rulesetConfigurations[0].duration = 0;
            _rulesetConfigurations[0].weight = _weight;
            _rulesetConfigurations[0].decayRate = 0;
            _rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
            _rulesetConfigurations[0].metadata = _metadata;
            _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
            _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

            JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
            address[] memory _tokensToAccept = new address[](2);
            _tokensToAccept[0] = JBConstants.NATIVE_TOKEN;
            _tokensToAccept[1] = address(ccipBnM);
            _terminalConfigurations[0] =
                JBTerminalConfig({terminal: jbMultiTerminal(), tokensToAccept: _tokensToAccept});

            // Create a first project to collect fees.
            jbController().launchProjectFor({
                owner: multisig(), // Random.
                projectUri: "whatever",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations, // Set terminals to receive fees.
                memo: ""
            });

            // Setup an erc20 for the project
            projectOneToken = jbController().deployERC20For(1, "SuckerToken", "SOOK", bytes32(0));

            // Add a price-feed to reconcile pays and redeems with our test token
            MockPriceFeed _priceFeedNativeTest = new MockPriceFeed(_TEST_PRICE_PER_NATIVE, 18);
            vm.label(address(_priceFeedNativeTest), "Mock Price Feed Native-ccipBnM");

            IJBPrices(jbPrices()).addPriceFeedFor({
                projectId: 1,
                pricingCurrency: uint32(uint160(address(ccipBnM))),
                unitCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                priceFeed: IJBPriceFeed(_priceFeedNativeTest)
            });
        }

        // Setup: allow chains for our first sucker
        uint64[] memory allowedChains = new uint64[](2);
        allowedChains[0] = arbSepoliaChainSelector;
        allowedChains[1] = ethSepoliaChainSelector;

        // Sucker one now allows our forked chains
        suckerGlobal.setAllowedChains(allowedChains);

        vm.stopPrank();

        arbSepoliaFork = vm.createSelectFork(ARBITRUM_SEPOLIA_RPC_URL);

        // Get the corresponding remote token and label it
        Register.NetworkDetails memory arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(421614);
        ccipBnMArbSepolia = BurnMintERC677Helper(arbSepoliaNetworkDetails.ccipBnMAddress);
        vm.label(address(ccipBnMArbSepolia), "bnmArbSep");

        // Setup JBV4 on our second fork (arb-sep)
        super.setUp();

        // Since our sucker deploy address would differ (just in this particular context)
        // We instead use this cheatcode to deploy what is essentially "Sucker Two" to the same address,
        // But on our other fork
        deployCodeTo(
            "BPCCIPSucker.sol",
            abi.encode(jbDirectory(), jbTokens(), jbPermissions(), peer, atbMode),
            address(suckerGlobal)
        );

        // set permissions
        vm.startPrank(multisig());

        {
            // Package up the ruleset configuration.
            JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
            _rulesetConfigurations[0].mustStartAtOrAfter = 0;
            _rulesetConfigurations[0].duration = 0;
            _rulesetConfigurations[0].weight = _weight;
            _rulesetConfigurations[0].decayRate = 0;
            _rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
            _rulesetConfigurations[0].metadata = _metadata;
            _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
            _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

            JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
            address[] memory _tokensToAccept = new address[](2);
            _tokensToAccept[0] = JBConstants.NATIVE_TOKEN;
            _tokensToAccept[1] = address(ccipBnMArbSepolia);
            _terminalConfigurations[0] =
                JBTerminalConfig({terminal: jbMultiTerminal(), tokensToAccept: _tokensToAccept});

            // Create a first project to collect fees.
            jbController().launchProjectFor({
                owner: multisig(), // Random.
                projectUri: "whatever",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations, // Set terminals to receive fees.
                memo: ""
            });
        }

        jbPermissions().setPermissionsFor(multisig(), perms);

        suckerGlobal.setAllowedChains(allowedChains);

        vm.stopPrank();

        // Switch back to sepolia (our L1 in this context) to begin testing
        vm.selectFork(sepoliaFork);
    }

    function test_forkTokenTransfer() external {
        // User that is transferring tokens
        address user = makeAddr("him");

        // The amount we pay to the project
        uint256 amountToSend = 100;

        // amount received after redemption
        uint256 maxRedeemed = amountToSend / 2; // 50% Max redemption rate

        // Give ourselves test tokens
        ccipBnM.drip(address(user));

        // Map the token
        BPTokenMapping memory map = BPTokenMapping({
            localToken: address(ccipBnM),
            minGas: 200_000,
            remoteToken: address(ccipBnMArbSepolia),
            remoteSelector: arbSepoliaChainSelector,
            minBridgeAmount: 1
        });

        vm.prank(multisig());
        suckerGlobal.mapToken(map);

        // Let the terminal spend our test tokens so we can pay and receive project tokens
        vm.startPrank(user);
        ccipBnM.approve(address(jbMultiTerminal()), amountToSend);

        // We receive 500 project tokens as a result
        uint256 projectTokenAmount = jbMultiTerminal().pay(1, address(ccipBnM), amountToSend, user, 0, "", "");

        // Approve the sucker to use those project tokens received by the user (we are still pranked as user)
        IERC20(address(projectOneToken)).approve(address(suckerGlobal), projectTokenAmount);

        // Call prepare which uses our project tokens to retrieve (redeem) for our backing tokens (test token)
        suckerGlobal.prepare(projectTokenAmount, user, maxRedeemed, address(ccipBnM), arbSepoliaChainSelector);
        vm.stopPrank();

        // Give the root sender some eth to pay the fees
        // TODO: return excess amounts in BPCCIPSucker
        vm.deal(sender, 1 ether);

        // Initiates the bridging
        vm.prank(sender);
        suckerGlobal.toRemote{value: 1 ether}(address(ccipBnM), arbSepoliaChainSelector);

        // Fees are paid but balance isn't zero (excess msg.value is returned)
        assert(sender.balance < 1 ether);
        assert(sender.balance > 0);

        // Use CCIP local to initiate the transfer on the L2
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);

        // Check that the tokens were transferred
        assertEq(ccipBnMArbSepolia.balanceOf(address(suckerGlobal)), maxRedeemed);

        // This is the most simple verification that messages are being sent and received though
        // Meaning CCIP transferred the data to our sucker on L2's inbox
        BPInboxTreeRoot memory updatedInbox = suckerGlobal.getInbox(address(ccipBnMArbSepolia), ethSepoliaChainSelector);
        assertNotEq(updatedInbox.root, bytes32(0));

        // TODO: claim and clean this up

        // Setup claim data
        BPLeaf memory _leaf = BPLeaf({
            index: 1,
            beneficiary: user,
            projectTokenAmount: projectTokenAmount,
            terminalTokenAmount: maxRedeemed
        });

        bytes32[32] memory _proof;

        BPClaim memory _claimData = BPClaim({
            token: address(ccipBnMArbSepolia),
            remoteSelector: ethSepoliaChainSelector,
            leaf: _leaf,
            proof: _proof
        });

        suckerGlobal.testClaim(_claimData);
    }
}
