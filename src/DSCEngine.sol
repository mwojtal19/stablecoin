// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzepplin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzepplin/contracts/token/ERC20/IERC20.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title DSCEngine
 * @author Michał Wojtalczyk
 * @notice This contract is the core of the DSC System. It handles all the logic
 * for minting and redeeming DSC, as well as depostiing & withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDao DSS (DAI) system.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * The system is designed to be as minimal as possible and have the tokens
 * maintain a 1 token == 1$ peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar pegged
 * - Algoritmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees,
 * and was only backed by WETH and WBTC.
 */
contract DSCEngine is ReentrancyGuard {
    //errors
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    using OracleLib for AggregatorV3Interface;

    //state variables
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    // events
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    // modifiers
    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    // functions
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

    // external functions

    /**
     *
     * @param _tokenCollateralAddress The address of the token to deposit as collateral
     * @param _amountCollateral The amount of collateral to deposit
     * @param _amountDscToMint The amount of decentralized stablecoin to mint
     * @notice This function will deposit collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDSC(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint
    ) external {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDSC(_amountDscToMint);
    }

    /**
     * @notice follows CEI
     * @param _tokenCollateralAddress The address of the token to deposit as collateral
     * @param _amountCollateral The maount of collateral to deposit
     */
    function depositCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _amountCollateral;
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param _tokenCollateralAddress The token collateral address
     * @param _amountCollateral The amount of collatreal to redeem
     * @param _amountDscToBurn The amount of DSC to burn
     * @notice This function burns DSC and reddems underlying collateral in one transaction
     */
    function redeemCollateralForDSC(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToBurn
    ) external {
        burnDSC(_amountDscToBurn);
        redeemCollateral(_tokenCollateralAddress, _amountCollateral);
    }

    function redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, _tokenCollateralAddress, _amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param _amountDscToMint The amount of DSC to mint
     * @notice They must have more collateral value than the minimum treshold
     */
    function mintDSC(uint256 _amountDscToMint) public moreThanZero(_amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += _amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 _amount) public moreThanZero(_amount) {
        _burnDsc(_amount, msg.sender, msg.sender);
    }

    /**
     *
     * @param _collateral The ERC20 collateral address to liquidate
     * @param _user Address of user who has broken the health factor. Their _healthFactor should
     * be below MIN_HEALTH_FACTOR
     * @param _debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice You can partially liquidate a user.
     * @notice You will get liquidation bonus for taking the users funds.
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized
     * in order for this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then
     * we wouldn't be able to incentive the liquidators.
     */
    function liquidate(address _collateral, address _user, uint256 _debtToCover)
        external
        moreThanZero(_debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(_user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(_collateral, _debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToReedem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(_user, msg.sender, _collateral, totalCollateralToReedem);
        _burnDsc(_debtToCover, _user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(_user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }
    //private & internal view functions

    /**
     *
     * @param _amountDscToBurn The amount of DSC to burn
     * @param _onBehalfOf Who's tokens we are burning
     * @param _dscFrom Who's is burning tokens
     * @dev Low-level internal function, do not call unless the function calling it
     * is checking for health factors being broken
     */
    function _burnDsc(uint256 _amountDscToBurn, address _onBehalfOf, address _dscFrom) private {
        s_DSCMinted[_onBehalfOf] -= _amountDscToBurn;
        bool success = i_dsc.transferFrom(_dscFrom, address(this), _amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(_amountDscToBurn);
    }

    function _redeemCollateral(address _from, address _to, address _tokenCollateralAddress, uint256 _amountCollateral)
        private
    {
        s_collateralDeposited[_from][_tokenCollateralAddress] -= _amountCollateral;
        emit CollateralRedeemed(_from, _to, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transfer(_to, _amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address _user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[_user];
        collateralValueInUsd = getAccountCollateralValue(_user);
    }

    /**
     * @notice How close to liquidation user is, if a user goes below 1
     * then they can get liquidated
     * @param _user The address of user
     */
    function _healthFactor(address _user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(_user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        // if not dscMinted take max of uint256 == max health factor
        if (totalDscMinted == 0) return type(uint256).max;
        // below health factor
        // $150 ETH / 100 DSC
        // 150 * 50 = 7500 / 100 = (75 / 100) < 1

        // above health factor
        // $1000 ETH / 100 DSC
        // 1000 * 50 = 50000 / 100 = (500 / 100) > 1
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _getUsdValue(address _token, uint256 _amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) / PRECISION;
    }

    //public & external view functions
    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function calculateHealthFactor(uint256 _totalDscMinted, uint256 _collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(_totalDscMinted, _collateralValueInUsd);
    }

    function getTokenAmountFromUsd(address _token, uint256 _usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (_usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address _user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getDsc() public view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokens() public view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address _tokenAddress) public view returns (address) {
        return s_priceFeeds[_tokenAddress];
    }

    function getCollateralBalanceOfUser(address _user, address _token) external view returns (uint256) {
        return s_collateralDeposited[_user][_token];
    }

    function getAccountInformation(address _user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(_user);
    }

    function getDscMinted(address _user) public view returns (uint256) {
        return s_DSCMinted[_user];
    }

    function getAdditionalFeedPrecision() public pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() public pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getHealthFactor(address _user) external view returns (uint256) {
        return _healthFactor(_user);
    }
}
