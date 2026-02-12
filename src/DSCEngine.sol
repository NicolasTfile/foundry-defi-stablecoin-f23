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

    //////////////////////
    // State Variables  //
    /////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIUIDATION_THRESHOLD = 50; // 200% overcollateralized (double the DSC)
    uint256 private constant LIUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////
    // Events           //
    /////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

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
    function depositCollateralAndMintDsc() external {}

    /**
     * @notice This function allows users to deposit collateral.
     * @notice follows CEI pattern (Checks, Effects, Interactions)
     * @param tokenCollateralAddress The address of the collateral token (e.g. WETH or WBTC).
     * @param amountCollateral The amount of collateral to deposit.
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
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

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    /**
     * @notice This function allows users to mint DSC.
     * @notice follows CEI pattern (Checks, Effects, Interactions)
     * @notice Users must have enough collateral deposited than the minimum threshold to mint the desired amount of DSC
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     */

    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;

        // If the user has minted more than the amount of DSC they are allowed to mint based on their collateral, revert
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}

    ////////////////////////////////////////
    // Private & Internal View Functions  //
    ////////////////////////////////////////
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
        // Total DSC minted by the user
        // Total value of collateral deposited by the user (in USD)
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIUIDATION_THRESHOLD) / LIUIDATION_PRECISION;
        // $1000 ETH * 50 = 50,000 / 100 = 500 / 100 > 1
        // $150 ETH * 50 = 7500 / 100 = 75 / 100 < 1

        // $1000 / 100 DSC
        // 1000 * 50 = 50000 / 100 = ((500 * 1e18) / 100) > 1
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * @notice This function checks health factor of the user (do they have enough collateral?)
     * @notice If they don't have enough collateral, revert
     * @param user The address of the user to check the health factor for
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1.
        // 2.
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////
    // Public & External View Functions  //
    ///////////////////////////////////////
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // Loop through the collateral deposited by the user, and get the value of each collateral in USD using the price feed, and sum them up to get the total collateral value in USD
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // The price feed returns the price (for eth and btc) with 8 decimals, so we need to adjust for that when calculating the USD value
        // We want to return the USD value with 18 decimals, so we need to multiply the price by 1e10 (ADDITIONAL_FEED_PRECISION) to adjust for the 8 decimals, and then multiply by the amount of collateral, and then divide by 1e18 (PRECISION) to adjust for the 18 decimals in the amount of collateral

        // casting to 'uint256' is safe because price is always positive (int256) and we are only dealing with positive values in this context
        // forge-lint: disable-next-line(unsafe-typecast)
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
