// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {CurvyPuppetLending, IERC20} from "../../src/curvy-puppet/CurvyPuppetLending.sol";
import {CurvyPuppetOracle} from "../../src/curvy-puppet/CurvyPuppetOracle.sol";
import {IStableSwap} from "../../src/curvy-puppet/IStableSwap.sol";

contract CurvyPuppetChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address treasury = makeAddr("treasury");

    // Users' accounts
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    address constant ETH = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // Relevant Ethereum mainnet addresses
    IPermit2 constant permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IStableSwap constant curvePool = IStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IERC20 constant stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    WETH constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    uint256 constant TREASURY_WETH_BALANCE = 200e18;
    uint256 constant TREASURY_LP_BALANCE = 65e17;
    uint256 constant LENDER_INITIAL_LP_BALANCE = 1000e18;
    uint256 constant USER_INITIAL_COLLATERAL_BALANCE = 2500e18;
    uint256 constant USER_BORROW_AMOUNT = 1e18;
    uint256 constant ETHER_PRICE = 4000e18;
    uint256 constant DVT_PRICE = 10e18;

    DamnValuableToken dvt;
    CurvyPuppetLending lending;
    CurvyPuppetOracle oracle;

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
        // Fork from mainnet state at specific block
        vm.createSelectFork((vm.envString("MAINNET_FORKING_URL")), 20190356);

        startHoax(deployer);

        // Deploy DVT token (collateral asset in the lending contract)
        dvt = new DamnValuableToken();

        // Deploy price oracle and set prices for ETH and DVT
        oracle = new CurvyPuppetOracle();
        oracle.setPrice({asset: ETH, value: ETHER_PRICE, expiration: block.timestamp + 1 days});
        oracle.setPrice({asset: address(dvt), value: DVT_PRICE, expiration: block.timestamp + 1 days});

        // Deploy the lending contract. It will offer LP tokens, accepting DVT as collateral.
        lending = new CurvyPuppetLending({
            _collateralAsset: address(dvt),
            _curvePool: curvePool,
            _permit2: permit2,
            _oracle: oracle
        });

        // Fund treasury account with WETH and approve player's expenses
        deal(address(weth), treasury, TREASURY_WETH_BALANCE);

        // Fund lending pool and treasury with initial LP tokens
        vm.startPrank(0x4F48031B0EF8acCea3052Af00A3279fbA31b50D8); // impersonating mainnet LP token holder to simplify setup (:
        IERC20(curvePool.lp_token()).transfer(address(lending), LENDER_INITIAL_LP_BALANCE);
        IERC20(curvePool.lp_token()).transfer(treasury, TREASURY_LP_BALANCE);

        // Treasury approves assets to player
        vm.startPrank(treasury);
        weth.approve(player, TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).approve(player, TREASURY_LP_BALANCE);

        // Users open 3 positions in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            // Fund user with some collateral
            vm.startPrank(deployer);
            dvt.transfer(users[i], USER_INITIAL_COLLATERAL_BALANCE);
            // User deposits + borrows from lending contract
            _openPositionFor(users[i]);
        }
    }

    /**
     * Utility function used during setup of challenge to open users' positions in the lending contract
     */
    function _openPositionFor(address who) private {
        vm.startPrank(who);
        // Approve and deposit collateral
        address collateralAsset = lending.collateralAsset();
        // Allow permit2 handle token transfers
        IERC20(collateralAsset).approve(address(permit2), type(uint256).max);
        // Allow lending contract to pull collateral
        permit2.approve({
            token: lending.collateralAsset(),
            spender: address(lending),
            amount: uint160(USER_INITIAL_COLLATERAL_BALANCE),
            expiration: uint48(block.timestamp)
        });
        // Deposit collateral + borrow
        lending.deposit(USER_INITIAL_COLLATERAL_BALANCE);
        lending.borrow(USER_BORROW_AMOUNT);
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Player balances
        assertEq(dvt.balanceOf(player), 0);
        assertEq(stETH.balanceOf(player), 0);
        assertEq(weth.balanceOf(player), 0);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0);

        // Treasury balances
        assertEq(dvt.balanceOf(treasury), 0);
        assertEq(stETH.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(treasury), TREASURY_WETH_BALANCE);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(treasury), TREASURY_LP_BALANCE);

        // Curve pool trades the expected assets
        assertEq(curvePool.coins(0), ETH);
        assertEq(curvePool.coins(1), address(stETH));

        // Correct collateral and borrow assets in lending contract
        assertEq(lending.collateralAsset(), address(dvt));
        assertEq(lending.borrowAsset(), curvePool.lp_token());

        // Users opened position in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            uint256 collateralAmount = lending.getCollateralAmount(users[i]);
            uint256 borrowAmount = lending.getBorrowAmount(users[i]);
            assertEq(collateralAmount, USER_INITIAL_COLLATERAL_BALANCE);
            assertEq(borrowAmount, USER_BORROW_AMOUNT);

            // User is sufficiently collateralized
            assertGt(lending.getCollateralValue(collateralAmount) / lending.getBorrowValue(borrowAmount), 3);
        }
    }


    // // Flash loan callback function
    // function executeOperation(
    //                           address asset,
    //                           uint256 amount,
    //                           uint256 premium,
    //                           address initiator,
    //                           bytes calldata params
    // ) external returns (bool){
    //     require(msg.sender == 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2, "Only Aave pool can call this function");
    //     address aaveAddress = msg.sender;
    //     // require(initiator == player, "Only this contract can call this function");
    //     require(asset == address(weth), "Only WETH can be borrowed");

    //     // console.log("LP token price before flashloan: ", curvePool.get_virtual_price());
    //     // uint256 lpTokenAmount = curvePool.add_liquidity{value: amount}([amount, 0], block.timestamp + 1 days);

    //     // console.log("LP token price after flashloan: ", curvePool.get_virtual_price());





    //     weth.approve(aaveAddress, amount + premium);

    //     weth.approve(player, type(uint256).max);

    //     return true;
    // }

    function executeOperation(
                              address[] calldata assets,
                              uint256[] calldata amounts,
                              uint256[] calldata premiums,
                              address initiator,
                              bytes calldata params
    ) external returns (bool){
        require(msg.sender == 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2, "Only Aave pool can call this function");
        uint256 amount = amounts[0];
        uint256 premium = premiums[0];

        console.log("LP token price before flashloan: ", curvePool.get_virtual_price());
        weth.withdraw(amount);
        weth.approve(address(curvePool), amount);
        IERC20(stETH).approve(address(curvePool), type(uint256).max);
        uint256 received = curvePool.exchange{value: amount  / 2}(0, 1, amount / 2 , 0);
        uint256 lpTokenAmount = curvePool.add_liquidity{value: amount/2}([amount / 2 , received], block.timestamp + 1 days);

        console.log("LP token price after flashloan: ", curvePool.get_virtual_price());




        weth.approve(msg.sender, amount + premium);
        weth.approve(player, type(uint256).max);

        return true;
  }

    receive() external payable {}

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_curvyPuppet() public checkSolvedByPlayer {
        permit2.approve({
            token: address(lending.collateralAsset()),
            spender: address(lending),
            amount: type(uint160).max,
            expiration: uint48(block.timestamp + 1 days)
        });
        lending.deposit(0);
        // lending.withdraw(1);
        // lending.borrow(1);
        // lending.redeem(1);
        // lending.liquidate(address(this));

        // // IERC20(curvePool.lp_token()).transferFrom(treasury, player, TREASURY_LP_BALANCE);
        // weth.transferFrom(treasury, address(this), TREASURY_WETH_BALANCE);

        // address aavePool = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

        // // FlashLoan API:https://aave.com/docs/developers/smart-contracts/pool#flashloan
        // // function flashLoan(
        // //     address receiverAddress,
        // //     address[] calldata assets,
        // //     uint256[] calldata amounts,
        // //     uint256[] calldata interestRateModes,
        // //     address onBehalfOf,
        // //     bytes calldata params,
        // //     uint16 referralCode
        // // ) public virtual override

        // address[] memory assets = new address[](1);
        // assets[0] = address(weth);

        // uint256[] memory amounts = new uint256[](1);
        // amounts[0] = 80000 ether;

        // uint256[] memory interestRateModes = new uint256[](1); // leave it to default 0


        // (bool success,) = aavePool.call(abi.encodeWithSignature("flashLoan(address,address[],uint256[],uint256[],address,bytes,uint16)",
        //                                                         address(this), // receiverAddress
        //                                                         assets,
        //                                                         amounts,
        //                                                         interestRateModes,
        //                                                         address(this), // onBehalfOf
        //                                                         "", // params
        //                                                         0 // referralCode
        //                                                        ));

        // require(success, "Flash loan failed");

        // console.log("Curve LP total supply: ", IERC20(curvePool.lp_token()).totalSupply());
        // console.log("Curve stETH balance: ",stETH.balanceOf(address(curvePool)));

        // for (uint256 i = 1; i < 11; i++) {
        //     console.log("Borrow value of ", i, lending.getBorrowValue(i));
        //     console.log("Collateral value of ", i, lending.getCollateralValue(i));
        // }

        // uint256 borrowedValue = lending.getBorrowValue(lending.getBorrowAmount(alice));
        // uint256 collateralValue = lending.getCollateralValue(lending.getCollateralAmount(alice));

        // console.log("borrowedAmount", lending.getBorrowAmount(alice));
        // console.log("borrowedValue", borrowedValue);

        // console.log("collateralAmount", lending.getCollateralAmount(alice));
        // console.log("collateralValue", collateralValue);

        // IERC20(curvePool.lp_token()).transferFrom(treasury, player, TREASURY_LP_BALANCE);
        // weth.transferFrom(treasury, player, TREASURY_WETH_BALANCE);
        // weth.withdraw(100 ether);
        // weth.approve(address(curvePool), type(uint256).max);
        // stETH.approve(address(curvePool), type(uint256).max);

        // // uint256 borrowedValue = lending.getBorrowValue(lending.getBorrowAmount(alice));
        // // uint256 collateralValue = lending.getCollateralValue(lending.getCollateralAmount(alice));

        // uint256 lpPrice = curvePool.get_virtual_price();
        // console.log("lpPrice", curvePool.get_virtual_price());

        // uint256 received = curvePool.exchange{value: 100 ether}(0, 1, 100 ether, 99 ether); // stEth
        // stETH.transfer(address(curvePool), received);

        // console.log("lpPrice", curvePool.get_virtual_price());

        // curvePool.remove_liquidity_one_coin(
        //     TREASURY_LP_BALANCE,
        //     0, // Remove WETH
        //     0 // Min amount of WETH
        // );

        // console.log("lpPrice", curvePool.get_virtual_price());

        // uint256 lpTokenAmount = curvePool.add_liquidity([0, uint256(99 ether)], block.timestamp + 1 days);

        // // assertEq(lpPrice,curvePool.get_virtual_price(), "LP token price changed before adding liquidity");

        // uint256 newBorrowedValue = lending.getBorrowValue(lending.getBorrowAmount(alice));
        // uint256 newCollateralValue = lending.getCollateralValue(lending.getCollateralAmount(alice));

        // assertEq(newCollateralValue, collateralValue, "Collateral value changed after adding liquidity");
        // assertEq(newBorrowedValue, borrowedValue, "Borrowed value changed after adding liquidity");


        // --------------------------------------------------------------------------------
        // IERC20(curvePool.lp_token()).transferFrom(treasury, player, TREASURY_LP_BALANCE);

        // // weth.approve(address(curvePool), TREASURY_WETH_BALANCE);





        // uint256 lpPrice = curvePool.get_virtual_price();

        // curvePool.remove_liquidity_one_coin(
        //     TREASURY_LP_BALANCE,
        //     0, // Remove WETH
        //     0 // Min amount of WETH
        // );

        // assertTrue(curvePool.get_virtual_price() > lpPrice, "LP token price did not increase");
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All users' positions are closed
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(lending.getCollateralAmount(users[i]), 0, "User position still has collateral assets");
            assertEq(lending.getBorrowAmount(users[i]), 0, "User position still has borrowed assets");
        }

        // Treasury still has funds left
        assertGt(weth.balanceOf(treasury), 0, "Treasury doesn't have any WETH");
        assertGt(IERC20(curvePool.lp_token()).balanceOf(treasury), 0, "Treasury doesn't have any LP tokens left");
        assertEq(dvt.balanceOf(treasury), USER_INITIAL_COLLATERAL_BALANCE * 3, "Treasury doesn't have the users' DVT");

        // Player has nothing
        assertEq(dvt.balanceOf(player), 0, "Player still has DVT");
        assertEq(stETH.balanceOf(player), 0, "Player still has stETH");
        assertEq(weth.balanceOf(player), 0, "Player still has WETH");
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0, "Player still has LP tokens");
    }
}
