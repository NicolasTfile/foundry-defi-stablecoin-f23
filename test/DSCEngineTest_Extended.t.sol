// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 100 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_USER_BALANCE);
    }

    /////////////////
    // Modifiers   //
    ////////////////

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(5000 ether); // Mint $5000 DSC against $20,000 collateral (200% overcollateralized)
        vm.stopPrank();
        _;
    }

    ////////////////////////
    // Constructor Tests  //
    ////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testConstructorSetsTokenAddressesCorrectly() public {
        address[] memory tokens = new address[](2);
        tokens[0] = weth;
        tokens[1] = wbtc;

        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = ethUsdPriceFeed;
        priceFeeds[1] = btcUsdPriceFeed;

        DSCEngine newEngine = new DSCEngine(tokens, priceFeeds, address(dsc));

        // Verify tokens are recognized by trying to get USD value
        uint256 usdValue = newEngine.getUsdValue(weth, 1 ether);
        assertGt(usdValue, 0);
    }

    ///////////////////
    // Price Tests   //
    ///////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18; // 15 ETH * $2000/ETH
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetUsdValueWithDifferentAmounts() public view {
        uint256 ethAmount = 1e18;
        uint256 expectedUsd = 2000e18; // 1 ETH * $2000/ETH
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether; // $100 / $2000/ETH = 0.05 ETH
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    function testGetTokenAmountFromUsdWithLargeAmount() public view {
        uint256 usdAmount = 10000 ether; // $10,000
        uint256 expectedWeth = 5 ether; // $10,000 / $2000/ETH = 5 ETH
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        ranToken.mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testCanDepositCollateralWithoutMinting() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testDepositCollateralEmitsEvent() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, false, address(dsce));
        emit DSCEngine.CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);

        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testDepositMultipleCollateralTypes() public {
        vm.startPrank(USER);

        // Deposit WETH
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Deposit WBTC
        ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(wbtc, AMOUNT_COLLATERAL);

        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);

        // Should have value from both collateral types
        uint256 expectedValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL) + dsce.getUsdValue(wbtc, AMOUNT_COLLATERAL);
        assertEq(collateralValueInUsd, expectedValue);
    }

    function testRevertsDepositCollateralWithoutApproval() public {
        vm.startPrank(USER);
        // Don't approve - should revert
        vm.expectRevert();
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////
    // mintDsc Tests //
    ///////////////////

    function testRevertsIfMintAmountIsZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Try to mint more than allowed (health factor < 1)
        // Collateral: 10 ETH * $2000 = $20,000
        // Max DSC: $20,000 * 50% / 100% = $10,000
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        dsce.mintDsc(10001 ether); // Trying to mint $10,001 should fail
        vm.stopPrank();
    }

    function testCanMintDscWithSufficientCollateral() public depositedCollateral {
        vm.startPrank(USER);
        uint256 amountToMint = 5000 ether; // $5000
        dsce.mintDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    function testMintDscUpdatesAccountInformation() public depositedCollateral {
        uint256 amountToMint = 5000 ether;

        vm.startPrank(USER);
        dsce.mintDsc(amountToMint);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint);
    }

    function testCanMintDscMultipleTimes() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(1000 ether);
        dsce.mintDsc(1000 ether);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 2000 ether);
    }

    /////////////////////////////////////////////
    // depositCollateralAndMintDsc Tests      //
    /////////////////////////////////////////////

    function testCanDepositAndMintInOneTransaction() public {
        uint256 amountToMint = 5000 ether;

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint);
        assertGt(collateralValueInUsd, 0);
    }

    function testRevertsDepositAndMintIfBreaksHealthFactor() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 15000 ether); // Too much DSC
        vm.stopPrank();
    }

    ///////////////////
    // burnDsc Tests //
    ///////////////////

    function testRevertsIfBurnAmountIsZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), 1000 ether);
        dsce.burnDsc(1000 ether);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 4000 ether); // 5000 - 1000
    }

    function testBurnDscUpdatesAccountInformation() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), 1000 ether);
        dsce.burnDsc(1000 ether);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 4000 ether);
    }

    function testCanBurnAllDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), 5000 ether);
        dsce.burnDsc(5000 ether);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
    }

    function testRevertsIfBurnMoreThanBalance() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), 10000 ether);
        vm.expectRevert();
        dsce.burnDsc(6000 ether); // User only has 5000
        vm.stopPrank();
    }

    ////////////////////////////
    // redeemCollateral Tests //
    ////////////////////////////

    function testRevertsIfRedeemAmountIsZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        uint256 redeemAmount = 5 ether;

        vm.startPrank(USER);
        dsce.redeemCollateral(weth, redeemAmount);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);

        uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL - redeemAmount);
        assertEq(collateralValueInUsd, expectedCollateralValue);
    }

    function testRedeemCollateralEmitsEvent() public depositedCollateral {
        uint256 redeemAmount = 5 ether;

        vm.startPrank(USER);
        vm.expectEmit(true, true, true, true, address(dsce));
        emit DSCEngine.CollateralRedeemed(USER, USER, weth, redeemAmount);
        dsce.redeemCollateral(weth, redeemAmount);
        vm.stopPrank();
    }

    function testCanRedeemAllCollateralIfNoDscMinted() public depositedCollateral {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        assertEq(collateralValueInUsd, 0);
    }

    function testRevertsIfRedeemBreaksHealthFactor() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        // Try to redeem too much collateral
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        dsce.redeemCollateral(weth, 9 ether); // This would leave insufficient collateral
        vm.stopPrank();
    }

    function testCanRedeemPartialCollateral() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        // Can redeem some collateral while maintaining health factor
        dsce.redeemCollateral(weth, 2 ether);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 5000 ether);
        assertGt(collateralValueInUsd, 0);
    }

    function testRevertsIfRedeemMoreThanDeposited() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL + 1);
        vm.stopPrank();
    }

    ////////////////////////////////////
    // redeemCollateralForDsc Tests   //
    ////////////////////////////////////

    function testCanRedeemCollateralForDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), 1000 ether);
        dsce.redeemCollateralForDsc(weth, 2 ether, 1000 ether);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 4000 ether); // 5000 - 1000

        uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL - 2 ether);
        assertEq(collateralValueInUsd, expectedCollateralValue);
    }

    function testRedeemCollateralForDscImproveHealthFactor() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), 5000 ether);
        dsce.redeemCollateralForDsc(weth, 1 ether, 5000 ether);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
    }

    /////////////////////
    // liquidate Tests //
    /////////////////////

    function testRevertsLiquidateIfDebtToCoverIsZero() public depositedCollateralAndMintedDsc {
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.liquidate(weth, USER, 0);
    }

    function testRevertsLiquidateIfHealthFactorIsOk() public depositedCollateralAndMintedDsc {
        // Mint DSC to liquidator
        ERC20Mock(weth).mint(LIQUIDATOR, AMOUNT_COLLATERAL);
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 1000 ether);

        dsc.approve(address(dsce), 1000 ether);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, 1000 ether);
        vm.stopPrank();
    }

    ////////////////////////////////
    // getAccountInformation Tests //
    ////////////////////////////////

    function testGetAccountInformationReturnsCorrectValues() public depositedCollateralAndMintedDsc {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        assertEq(totalDscMinted, 5000 ether);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValueInUsd, expectedCollateralValue);
    }

    function testGetAccountInformationForUserWithNoActivity() public view {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        assertEq(totalDscMinted, 0);
        assertEq(collateralValueInUsd, 0);
    }

    ////////////////////////////////////
    // getAccountCollateralValue Tests //
    ////////////////////////////////////

    function testGetAccountCollateralValueWithNoDeposits() public view {
        uint256 collateralValue = dsce.getAccountCollateralValue(USER);
        assertEq(collateralValue, 0);
    }

    function testGetAccountCollateralValueWithSingleTokenDeposit() public depositedCollateral {
        uint256 collateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedValue);
    }

    function testGetAccountCollateralValueWithMultipleTokenDeposits() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(wbtc, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 collateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL) + dsce.getUsdValue(wbtc, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedValue);
    }

    ////////////////////////////
    // Integration Tests      //
    ////////////////////////////

    function testCompleteUserLifecycle() public {
        // 1. Deposit collateral
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // 2. Mint DSC
        dsce.mintDsc(5000 ether);
        assertEq(dsc.balanceOf(USER), 5000 ether);

        // 3. Burn some DSC
        dsc.approve(address(dsce), 2000 ether);
        dsce.burnDsc(2000 ether);
        assertEq(dsc.balanceOf(USER), 3000 ether);

        // 4. Redeem some collateral
        dsce.redeemCollateral(weth, 3 ether);

        // 5. Verify final state
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 3000 ether);
        assertEq(collateralValueInUsd, dsce.getUsdValue(weth, 7 ether));
        vm.stopPrank();
    }

    function testMultipleUsersCanInteractIndependently() public {
        address USER2 = makeAddr("user2");
        ERC20Mock(weth).mint(USER2, STARTING_USER_BALANCE);

        // USER deposits and mints
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 5000 ether);
        vm.stopPrank();

        // USER2 deposits and mints
        vm.startPrank(USER2);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 3000 ether);
        vm.stopPrank();

        // Verify independent balances
        assertEq(dsc.balanceOf(USER), 5000 ether);
        assertEq(dsc.balanceOf(USER2), 3000 ether);

        (uint256 user1Minted,) = dsce.getAccountInformation(USER);
        (uint256 user2Minted,) = dsce.getAccountInformation(USER2);
        assertEq(user1Minted, 5000 ether);
        assertEq(user2Minted, 3000 ether);
    }

    function testCanDepositBothCollateralTypesAndMint() public {
        vm.startPrank(USER);

        // Deposit WETH
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Deposit WBTC
        ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(wbtc, AMOUNT_COLLATERAL);

        // Mint DSC based on total collateral
        uint256 totalCollateralValue = dsce.getAccountCollateralValue(USER);
        uint256 maxDscToMint = (totalCollateralValue * 50) / 100; // 50% of collateral value

        dsce.mintDsc(maxDscToMint);
        vm.stopPrank();

        assertEq(dsc.balanceOf(USER), maxDscToMint);
    }

    function testHealthFactorMaintainedThroughoutOperations() public {
        vm.startPrank(USER);

        // Deposit and mint at 200% overcollateralization
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 5000 ether);

        // Operations that maintain health factor should succeed
        dsc.approve(address(dsce), 1000 ether);
        dsce.burnDsc(1000 ether); // Improves health factor

        dsce.redeemCollateral(weth, 1 ether); // Small redemption should be ok

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        // Verify health factor is still good
        uint256 collateralAdjusted = (collateralValueInUsd * 50) / 100;
        uint256 healthFactor = (collateralAdjusted * 1e18) / totalDscMinted;
        assertGe(healthFactor, 1e18);

        vm.stopPrank();
    }
}
