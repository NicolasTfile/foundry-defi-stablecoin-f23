// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volatility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Olaniyi Agunloye
 *
 * The system is designed to be as minimal as possible, and have the tokens mintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral: The collateral is external to the system, and can be any asset that has a price feed. In this case, we will use ETH and BTC as collateral.
 * - Dollar Pegged: The stablecoin is pegged to the US Dollar, meaning that 1 DSC should always be worth 1 USD.
 * - Algorithmically Stable: The system will have mechanisms to maintain the peg, such as minting and burning of tokens, and liquidation of collateral.
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should alway be "overcollateralized." At no point should the value of all collateral be <= the dollar-backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system.
 *
 */

contract DSCEngine is ReentrancyGuard {
    //////////////////////
    // Errors           //
    /////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    //////////////////////
    // State Variables  //
    /////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized (double the DSC)
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////
    // Events           //
    /////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    //////////////////////
    // Modifiers        //
    /////////////////////
    modifier moreThanZero(uint256 amount) {
        _moreThanZero(amount);
        _;
    }

    modifier isAllowedToken(address token) {
        _isAllowedToken(token);
        _;
    }

    //////////////////////
    // Functions        //
    /////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    // External Functions  //
    ////////////////////////
    /**
     * @notice This function allows users to deposit collateral and mint DSC in a single transaction.
     * @param tokenCollateralAddress The address of the collateral token (e.g. WETH or WBTC).
     * @param amountCollateral The amount of collateral to deposit.
     * @param amountDscToMint The amount of decentralized stablecoin (DSC) to mint.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice This function allows users to deposit collateral.
     * @notice follows CEI pattern (Checks, Effects, Interactions)
     * @param tokenCollateralAddress The address of the collateral token (e.g. WETH or WBTC).
     * @param amountCollateral The amount of collateral to deposit.
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice This function allows users burn DSC and redeem underlying collateral in a single transaction.
     * @param tokenCollateralAddress The address of the collateral token (e.g. WETH or WBTC).
     * @param amountCollateral The amount of collateral to redeem.
     * @param amountDscToBurn The amount of decentralized stablecoin (DSC) to burn.
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral will check the health factor after redeeming collateral, so we don't need to check it here
    }

    /**
     * @notice This function allows users to redeem collateral.
     * @notice follows CEI pattern (Checks, Effects, Interactions)
     * @notice In order to redeem collateral:
     * @notice 1. Health factor must be over 1 after collateral is pulled
     * @param tokenCollateralAddress The address of the collateral token (e.g. WETH or WBTC).
     * @param amountCollateral The amount of collateral to redeem.
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice This function allows users to mint DSC.
     * @notice follows CEI pattern (Checks, Effects, Interactions)
     * @notice Users must have enough collateral deposited than the minimum threshold to mint the desired amount of DSC
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     */

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;

        // If the user has minted more than the amount of DSC they are allowed to mint based on their collateral, revert
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) revert DSCEngine__MintFailed(); // Trying out this one-liner instead of an if statement with a revert in the body, just to see if it works and is more efficient.
    }

    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this will ever hit because burning DSC should only increase the health factor
    }

    /**
     * @notice This function allows users to liquidate undercollateralized positions.
     * @notice If a user's _healthFactor falls below MIN_HEALTH_FACTOR, their position can be partially liquidated by other users.
     * @notice The liquidator can choose to cover a portion of the user's debt (debtToCover), and in return, they will receive a portion of the user's collateral that is equivalent in value to the debt they covered, plus a liquidation bonus.
     * @notice The liquidation bonus is an additional percentage of the collateral that the liquidator receives as an incentive for performing the liquidation. For example, if the liquidation bonus is 10%, and the liquidator covers $100 worth of debt, they would receive $110 worth of collateral.
     * @notice This function assumes the protocol will be roughly 200% overcollateralized, so the liquidator can receive up to $200 worth of collateral for every $100 of debt they cover, depending on the current health factor of the position being liquidated.
     * @notice Follows the CEI pattern (Checks, Effects, Interactions)
     * @param collateral The erc20 collateral address that the liquidator wants to receive.
     * @param user The address of the user whose position is being liquidated.
     * @param debtToCover The amount of the user's debt that the liquidator wants to cover (in DSC), which will improve the user's health factor
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Need to check health factor of the user to make sure they are undercollateralized and can be liquidated
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // We want to burn their DSC "debt" and take their collateral, so we need to calculate how much collateral the liquidator should receive for covering the specified amount of debt, based on the current price of the collateral and the liquidation bonus.
        // Bad User: $140 ETH, $100 DSC
        // debtToCover = $100
        // $100 of DSC = ?? ETH?
        // = 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // liquidation bonus = 10%
        // We are giving the liquidator $110 of WETH for 100 DSC covered
        // 0.05 ETH * 0.1 = 0.005 ETH (bonus), Getting 0.055 ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        // We want to make sure that the liquidation actually improved the user's health factor, otherwise, something went wrong and we should revert the transaction
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender); // We also want to make sure that the liquidator's health factor is not broken after the liquidation
    }

    function getHealthFactor() external view {}

    ///////////////////////////////////////////////
    // Private & Internal View & Pure Functions  //
    ///////////////////////////////////////////////

    /**
     * @dev Low-level internal function, do not call unless the function calling it is
     * checking for health factors being broken
     * @param amountDscToBurn The amount of DSC that the user wants to burn.
     * @param onBehalfOf The address of the user whose debt is being reduced (the one who originally minted the DSC).
     * @param dscFrom The address from which the DSC will be transferred (the user who is burning the DSC).
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // The conditional below is hpothetically redundant because the transferFrom function in the DecentralizedStableCoin contract should revert if the transfer fails,
        // but we include it here for completeness and to handle any unexpected cases where the transfer might fail without reverting.
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        // _calculateHealthFactorAfter()
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _moreThanZero(uint256 amount) internal pure {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
    }

    function _isAllowedToken(address token) internal view {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @notice This function returns the health factor of a user, which is the ratio of the value of their collateral to the value of their debt (minted DSC).
     * @notice If the health factor is below 1, the user's position can be liquidated.
     * @param user The address of the user to check the health factor for.
     * @return The health factor of the user.
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        // If no DSC has been minted, return maximum health factor (infinite health)
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // 1000 * 50 = 50000 / 100 = ((500 * 1e18) / 100) > 1
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * @notice This function checks health factor of the user (do they have enough collateral?)
     * @notice If they don't have enough collateral, revert
     * @param user The address of the user to check the health factor for
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end making 18 zeroes
        // casting to 'uint256' is safe because price is always positive (int256) and we are only dealing with positive values in this context
        // forge-lint: disable-next-line(unsafe-typecast)
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    ///////////////////////////////////////
    // Public & External View Functions  //
    ///////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // Use price feed to get the current price of the token in USD then divide the USD by the price of the token
        // If $2000 / 1 ETH. $1000 DSC = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18 * 1e18) / ($2000e8 * 1e10)
        // casting to 'uint256' is safe because price is always positive (int256) and we are only dealing with positive values in this context
        // forge-lint: disable-next-line(unsafe-typecast)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // Loop through the collateral deposited by the user, and get the value of each collateral in USD using the price feed, and sum them up to get the total collateral value in USD
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amountInWei) external view returns (uint256) {
        return _getUsdValue(token, amountInWei);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
