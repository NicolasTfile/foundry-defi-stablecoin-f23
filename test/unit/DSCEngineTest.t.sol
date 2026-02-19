// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public user = makeAddr("user0");

    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    uint256 amountToMint = 100 ether;

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
    }

    /////////////////
    // Modifiers   //
    ////////////////

    function _depositedCollateral() internal {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function _depositedCollateralAndMintedDsc() internal {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function _liquidated() internal {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // uint256 userHealthFactor = dsce.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.liquidate(weth, user, amountToMint); // We are covering their whole debt
        vm.stopPrank();
    }

    modifier liquidated() {
        _liquidated();
        _;
    }

    modifier depositedCollateral() {
        _depositedCollateral();
        _;
    }

    modifier depositedCollateralAndMintedDsc() {
        _depositedCollateralAndMintedDsc();
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

    // function testRevertsIfTransferFromFails() public {
    //     address owner = msg.sender;
    //     vm.prank(owner);
    //     MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom();
    //     tokenAddresses = [address(mockCollateralToken)];
    //     feedAddresses = [ethUsdPriceFeed];
    //     // DSCEngine receives the third parameter as dscAddress, not the tokenAddress used as collateral.
    //     vm.prank(owner);
    //     DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    //     mockCollateralToken.mint(user, amountCollateral);
    //     vm.startPrank(user);
    //     ERC20Mock(address(mockCollateralToken)).approve(address(mockDsce), amountCollateral);
    //     // Act / Assert
    //     vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
    //     mockDsce.depositCollateral(address(mockCollateralToken), amountCollateral);
    //     vm.stopPrank();
    // }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock();

        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(randToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testDepositCollateralEmitsEvent() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, false, address(dsce));
        emit DSCEngine.CollateralDeposited(user, weth, AMOUNT_COLLATERAL); // where event?

        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testDepositMultipleCollateralTypes() public {
        vm.startPrank(user);

        // Deposit WETH
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Deposit WBTC
        ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(wbtc, AMOUNT_COLLATERAL);

        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
        assertEq(totalDscMinted, 0);

        // Should have value from both collateral types
        uint256 expectedValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL) + dsce.getUsdValue(wbtc, AMOUNT_COLLATERAL);
        assertEq(collateralValueInUsd, expectedValue);
    }

    function testRevertsDepositCollateralWithoutApproval() public {
        vm.startPrank(user);
        // Don't approve - should revert
        vm.expectRevert();
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////
    // mintDsc Tests //
    ///////////////////

    // // This test needs it's own custom setup
    // function testRevertsIfMintFails() public {
    //     // Arrange - Setup
    //     MockFailedMintDSC mockDsc = new MockFailedMintDSC();
    //     tokenAddresses = [weth];
    //     feedAddresses = [ethUsdPriceFeed];
    //     address owner = msg.sender;
    //     vm.prank(owner);
    //     DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
    //     mockDsc.transferOwnership(address(mockDsce));
    //     // Arrange - User
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(mockDsce), amountCollateral);

    //     vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
    //     mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
    //     vm.stopPrank();
    // }

    function testRevertsIfMintAmountIsZero() public depositedCollateral {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000 ?
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000 ?
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        // casting to 'uint256' is safe because price is always positive (int256) and we are only dealing with positive values in this context
        // forge-lint: disable-next-line(unsafe-typecast)
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDscWithSufficientCollateral() public depositedCollateral {
        vm.startPrank(user);
        dsce.mintDsc(amountToMint); // $5000
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    function testMintDscUpdatesAccountInformation() public depositedCollateral {
        vm.startPrank(user);
        dsce.mintDsc(amountToMint);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(user);
        assertEq(totalDscMinted, amountToMint);
    }

    function testCanMintDscMultipleTimes() public depositedCollateral {
        vm.startPrank(user);
        dsce.mintDsc(1000 ether);
        dsce.mintDsc(1000 ether);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 2000 ether);
    }

    function testCannotMintWithoutDepositingCollateral() public {
        vm.startPrank(user);

        // Do NOT deposit collateral; do NOT approve anything.
        // Try to mint — should revert because health factor will be broken.
        // With 0 collateral, the health factor will be 0
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(amountToMint, 0);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);

        vm.stopPrank();
    }

    /////////////////////////////////////////////
    // depositCollateralAndMintDsc Tests      //
    /////////////////////////////////////////////

    function testCanDepositAndMintInOneTransaction() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
        assertEq(totalDscMinted, amountToMint);
        assertGt(collateralValueInUsd, 0);
    }

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        // casting to 'uint256' is safe because price is always positive (int256) and we are only dealing with positive values in this context
        // forge-lint: disable-next-line(unsafe-typecast)
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    ///////////////////
    // burnDsc Tests //
    ///////////////////

    function testRevertsIfBurnAmountIsZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dsce), amountToMint);
        dsce.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testBurnDscUpdatesAccountInformation() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dsce), amountToMint);
        dsce.burnDsc(amountToMint);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(user);
        assertEq(totalDscMinted, 0);
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    ////////////////////////////
    // redeemCollateral Tests //
    ////////////////////////////

    // // this test needs it's own setup
    // function testRevertsIfTransferFails() public {
    //     // Arrange - Setup
    //     address owner = msg.sender;
    //     vm.prank(owner);
    //     MockFailedTransfer mockDsc = new MockFailedTransfer();
    //     tokenAddresses = [address(mockDsc)];
    //     feedAddresses = [ethUsdPriceFeed];
    //     vm.prank(owner);
    //     DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
    //     mockDsc.mint(user, amountCollateral);

    //     vm.prank(owner);
    //     mockDsc.transferOwnership(address(mockDsce));
    //     // Arrange - User
    //     vm.startPrank(user);
    //     ERC20Mock(address(mockDsc)).approve(address(mockDsce), amountCollateral);
    //     // Act / Assert
    //     mockDsce.depositCollateral(address(mockDsc), amountCollateral);
    //     vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
    //     mockDsce.redeemCollateral(address(mockDsc), amountCollateral);
    //     vm.stopPrank();
    // }

    function testRevertsIfRedeemAmountIsZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        uint256 userBalanceBeforeRedeem = dsce.getCollateralBalanceOfUser(user, weth);
        assertEq(userBalanceBeforeRedeem, AMOUNT_COLLATERAL);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalanceAfterRedeem = dsce.getCollateralBalanceOfUser(user, weth);
        assertEq(userBalanceAfterRedeem, 0);
        vm.stopPrank();
    }

    function testRedeemCollateralEmitsEvent() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(dsce));
        emit DSCEngine.CollateralRedeemed(user, user, weth, AMOUNT_COLLATERAL); // Instead of CollateralRedeemed(user, user, weth, amountCollateral);
        vm.startPrank(user);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanRedeemAllCollateralIfNoDscMinted() public depositedCollateral {
        vm.startPrank(user);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
        assertEq(totalDscMinted, 0);
        assertEq(collateralValueInUsd, 0);
    }

    function testRevertsIfRedeemBreaksHealthFactor() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        // Try to redeem too much collateral
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(amountToMint, 0);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL); // This would leave insufficient collateral
        vm.stopPrank();
    }

    function testCanRedeemPartialCollateral() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        // Can redeem some collateral while maintaining health factor
        dsce.redeemCollateral(weth, 2 ether);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
        assertEq(totalDscMinted, amountToMint);
        assertGt(collateralValueInUsd, 0);
    }

    function testRevertsIfRedeemMoreThanDeposited() public depositedCollateral {
        vm.startPrank(user);
        vm.expectRevert();
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL + 1);
        vm.stopPrank();
    }

    ////////////////////////////////////
    // redeemCollateralForDsc Tests   //
    ////////////////////////////////////

    function testCanRedeemCollateralForDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dsce), amountToMint);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(user);
        assertEq(totalDscMinted, 0);

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dsce), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    /////////////////////
    // liquidate Tests //
    /////////////////////

    // // This test needs it's own setup
    // function testMustImproveHealthFactorOnLiquidation() public {
    //     // Arrange - Setup
    //     MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
    //     tokenAddresses = [weth];
    //     feedAddresses = [ethUsdPriceFeed];
    //     address owner = msg.sender;
    //     vm.prank(owner);
    //     DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
    //     mockDsc.transferOwnership(address(mockDsce));
    //     // Arrange - User
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(mockDsce), amountCollateral);
    //     mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
    //     vm.stopPrank();

    //     // Arrange - Liquidator
    //     collateralToCover = 1 ether;
    //     ERC20Mock(weth).mint(liquidator, collateralToCover);

    //     vm.startPrank(liquidator);
    //     ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
    //     uint256 debtToCover = 10 ether;
    //     mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
    //     mockDsc.approve(address(mockDsce), debtToCover);
    //     // Act
    //     int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
    //     // Act/Assert
    //     vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
    //     mockDsce.liquidate(weth, user, debtToCover);
    //     vm.stopPrank();
    // }

    function testRevertsLiquidateIfDebtToCoverIsZero() public depositedCollateralAndMintedDsc {
        vm.prank(liquidator);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.liquidate(weth, user, 0);
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        // Mint DSC to liquidator
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    // function testLiquidationPayoutIsCorrect() public liquidated {
    //     uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
    //     uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint)
    //         + (dsce.getTokenAmountFromUsd(weth, amountToMint)
    //             * dsce.getLiquidationBonus()
    //             / dsce.getLiquidationPrecision());
    //     uint256 hardCodedExpected = 6111111111111111110;
    //     assertEq(liquidatorWethBalance, hardCodedExpected);
    //     assertEq(liquidatorWethBalance, expectedWeth);
    // }

    // function testUserStillHasSomeEthAfterLiquidation() public liquidated {
    //     // Get how much WETH the user lost
    //     uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, amountToMint)
    //         + (dsce.getTokenAmountFromUsd(weth, amountToMint)
    //             * dsce.getLiquidationBonus()
    //             / dsce.getLiquidationPrecision());

    //     uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);
    //     uint256 expectedUserCollateralValueInUsd = dsce.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);

    //     (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(user);
    //     uint256 hardCodedExpectedValue = 70000000000000000020;
    //     assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
    //     assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    // }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dsce.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dsce.getAccountInformation(user);
        assertEq(userDscMinted, 0);
    }

    ////////////////////////////////
    // getAccountInformation Tests //
    ////////////////////////////////

    function testGetAccountInformationReturnsCorrectValues() public depositedCollateralAndMintedDsc {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);

        assertEq(totalDscMinted, amountToMint);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValueInUsd, expectedCollateralValue);
    }

    function testGetAccountInformationForUserWithNoActivity() public view {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);

        assertEq(totalDscMinted, 0);
        assertEq(collateralValueInUsd, 0);
    }

    /////////////////////////////////////
    // getAccountCollateralValue Tests //
    /////////////////////////////////////

    function testGetAccountCollateralValueWithNoDeposits() public view {
        uint256 collateralValue = dsce.getAccountCollateralValue(user);
        assertEq(collateralValue, 0);
    }

    function testGetAccountCollateralValueWithSingleTokenDeposit() public depositedCollateral {
        uint256 collateralValue = dsce.getAccountCollateralValue(user);
        uint256 expectedValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedValue);
    }

    function testGetAccountCollateralValueWithMultipleTokenDeposits() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(wbtc, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 collateralValue = dsce.getAccountCollateralValue(user);
        uint256 expectedValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL) + dsce.getUsdValue(wbtc, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedValue);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dsce.getHealthFactor(user);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Remember, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dsce.getHealthFactor(user);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    // ///////////////////////////////////
    // // View & Pure Function Tests //
    // //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetHealthFactor() public view {
        uint256 healthFactor = dsce.getHealthFactor(user);
        assertGe(healthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = dsce.getAccountInformation(user);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = dsce.getCollateralBalanceOfUser(user, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = dsce.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public view {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dsce.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    ////////////////////////////
    // Integration Tests      //
    ////////////////////////////

    // function testCompleteUserLifecycle() public {
    //     // 1. Deposit collateral
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

    //     // 2. Mint DSC
    //     dsce.mintDsc(5000 ether);
    //     assertEq(dsc.balanceOf(user), 5000 ether);

    //     // 3. Burn some DSC
    //     dsc.approve(address(dsce), 2000 ether);
    //     dsce.burnDsc(2000 ether);
    //     assertEq(dsc.balanceOf(user), 3000 ether);

    //     // 4. Redeem some collateral
    //     dsce.redeemCollateral(weth, 3 ether);

    //     // 5. Verify final state
    //     (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
    //     assertEq(totalDscMinted, 3000 ether);
    //     assertEq(collateralValueInUsd, dsce.getUsdValue(weth, 7 ether));
    //     vm.stopPrank();
    // }

    // function testMultipleUsersCanInteractIndependently() public {
    //     address user2 = makeAddr("user2");
    //     ERC20Mock(weth).mint(user2, STARTING_USER_BALANCE);

    //     // user deposits and mints
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 5000 ether);
    //     vm.stopPrank();

    //     // user2 deposits and mints
    //     vm.startPrank(user2);
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 3000 ether);
    //     vm.stopPrank();

    //     // Verify independent balances
    //     assertEq(dsc.balanceOf(user), 5000 ether);
    //     assertEq(dsc.balanceOf(user2), 3000 ether);

    //     (uint256 user1Minted,) = dsce.getAccountInformation(user);
    //     (uint256 user2Minted,) = dsce.getAccountInformation(user2);
    //     assertEq(user1Minted, 5000 ether);
    //     assertEq(user2Minted, 3000 ether);
    // }

    // function testCanDepositBothCollateralTypesAndMint() public {
    //     vm.startPrank(user);

    //     // Deposit WETH
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

    //     // Deposit WBTC
    //     ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositCollateral(wbtc, AMOUNT_COLLATERAL);

    //     // Mint DSC based on total collateral
    //     uint256 totalCollateralValue = dsce.getAccountCollateralValue(user);
    //     uint256 maxDscToMint = (totalCollateralValue * 50) / 100; // 50% of collateral value

    //     dsce.mintDsc(maxDscToMint);
    //     vm.stopPrank();

    //     assertEq(dsc.balanceOf(user), maxDscToMint);
    // }

    // function testHealthFactorMaintainedThroughoutOperations() public {
    //     vm.startPrank(user);

    //     // Deposit and mint at 200% overcollateralization
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 5000 ether);

    //     // Operations that maintain health factor should succeed
    //     dsc.approve(address(dsce), 1000 ether);
    //     dsce.burnDsc(1000 ether); // Improves health factor

    //     dsce.redeemCollateral(weth, 1 ether); // Small redemption should be ok

    //     (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);

    //     // Verify health factor is still good
    //     uint256 collateralAdjusted = (collateralValueInUsd * 50) / 100;
    //     uint256 healthFactor = (collateralAdjusted * 1e18) / totalDscMinted;
    //     assertGe(healthFactor, 1e18);

    //     vm.stopPrank();
    // }
}
