// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {EnumerableSet} from "@openzepplin/contracts/utils/structs/EnumerableSet.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzepplin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {DSCEngine, AggregatorV3Interface} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {console} from "forge-std/console.sol";

contract Handler is Test {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Deployed contracts to interact with
    DSCEngine public engine;
    DecentralizedStableCoin public dsc;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;
    ERC20Mock public weth;
    ERC20Mock public wbtc;

    // Ghost Variables
    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(wbtc)));
    }

    // FUNCTOINS TO INTERACT WITH

    ///////////////
    // DSCEngine //
    ///////////////
    function mintAndDepositCollateral(uint256 _collateralSeed, uint256 _amountCollateral) public {
        // must be more than 0
        _amountCollateral = bound(_amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(_collateralSeed);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, _amountCollateral);
        collateral.approve(address(engine), _amountCollateral);
        engine.depositCollateral(address(collateral), _amountCollateral);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 _collateralSeed, uint256 _amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(_collateralSeed);
        uint256 maxCollateral = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));

        _amountCollateral = bound(_amountCollateral, 0, maxCollateral);
        //vm.prank(msg.sender);
        if (_amountCollateral == 0) {
            return;
        }
        vm.prank(msg.sender);
        engine.redeemCollateral(address(collateral), _amountCollateral);
    }

    function burnDsc(uint256 _amountDsc) public {
        // Must burn more than 0
        _amountDsc = bound(_amountDsc, 0, dsc.balanceOf(msg.sender));
        if (_amountDsc == 0) {
            return;
        }
        vm.startPrank(msg.sender);
        dsc.approve(address(engine), _amountDsc);
        engine.burnDSC(_amountDsc);
        vm.stopPrank();
    }

    // Only the DSCEngine can mint DSC!
    // function mintDsc(uint256 amountDsc) public {
    //     amountDsc = bound(amountDsc, 0, MAX_DEPOSIT_SIZE);
    //     vm.prank(dsc.owner());
    //     dsc.mint(msg.sender, amountDsc);
    // }

    function liquidate(uint256 _collateralSeed, address _userToBeLiquidated, uint256 _debtToCover) public {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        uint256 userHealthFactor = engine.getHealthFactor(_userToBeLiquidated);
        if (userHealthFactor >= minHealthFactor) {
            return;
        }
        _debtToCover = bound(_debtToCover, 1, uint256(type(uint96).max));
        ERC20Mock collateral = _getCollateralFromSeed(_collateralSeed);
        engine.liquidate(address(collateral), _userToBeLiquidated, _debtToCover);
    }

    /////////////////////////////
    // DecentralizedStableCoin //
    /////////////////////////////
    function transferDsc(uint256 _amountDsc, address _to) public {
        if (_to == address(0)) {
            _to = address(1);
        }
        _amountDsc = bound(_amountDsc, 0, dsc.balanceOf(msg.sender));
        vm.prank(msg.sender);
        dsc.transfer(_to, _amountDsc);
    }

    /////////////////////////////
    // Aggregator //
    /////////////////////////////
    function updateCollateralPrice(uint96 _newPrice, uint256 _collateralSeed) public {
        int256 intNewPrice = int256(uint256(_newPrice));
        ERC20Mock collateral = _getCollateralFromSeed(_collateralSeed);
        MockV3Aggregator priceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(collateral)));

        priceFeed.updateAnswer(intNewPrice);
    }

    /// Helper Functions
    function _getCollateralFromSeed(uint256 _collateralSeed) private view returns (ERC20Mock) {
        if (_collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
