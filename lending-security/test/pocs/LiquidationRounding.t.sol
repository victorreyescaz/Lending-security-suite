// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PoC de rounding/dust en liquidaciones

Escenarios donde una cuenta es liquidable pero la liquidacion revierte por minimos (deuda muy pequeña, colateral insuficiente o precio que hace que el seize (cantidad de colateral que se confisca al user liquidado y se entrega al liquidator a cambio de repagar la deuda) quede por debajo del minimo.
Tambien muestra el close factor como riesgo operativo: una liquidacion grande se parte en rondas, aumentando costes.
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract LiquidationRoundingPoC is Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address liquidator = makeAddr("liquidator");

    uint256 constant FAIR_PRICE = 2000e8;

    function setUp() public {
        weth = new WETH9();
        usdc = new MockUSDC();
        oracle = new OracleMock(FAIR_PRICE);

        pool = new LendingPool(
            address(weth),
            address(usdc),
            address(oracle),
            7500,
            8000,
            200,
            400,
            2000,
            8000,
            1000
        );

        usdc.mint(lender, 2_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(1_500_000e6);
        vm.stopPrank();
    }

    function _prepareLiquidator(uint256 amount) internal {
        usdc.mint(liquidator, amount);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _finalizeLiquidator() internal {
        vm.stopPrank();
    }

    /*
    - Borrower toma una deuda diminuta muy cercana al minimo
    - Se baja el precio para que quede liquidable y se intenta liquidar esperando revert DustAmount
    */
    function testLiquidationRevertsWhenDebtBelowMinCloseFactor() public {
        uint256 minUsdc = pool.MIN_LIQUIDATION_USDC();

        vm.deal(borrower, 1 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1 ether}();
        pool.borrowUSDC(minUsdc + 500);
        vm.stopPrank();

        oracle.setPrice(1e5); // $0.001 to force HF < 1 with tiny debt

        _prepareLiquidator(minUsdc);
        vm.expectRevert(LendingPool.DustAmount.selector);
        pool.liquidate(borrower, minUsdc);
        _finalizeLiquidator();
    }

    /*
    - Borrower deposita muy poco colateral
    - Se baja el precio a 1USD para que el colateral valga casi nada y se intenta liquidar por minUsdc esperando revert DustAmount, el colateral es tan bajo que maxRepayUsdc queda por debajo del minimo de liquidacion.
    - El sistema puede quedar con posiciones liquidables pero no liquidables por dust.
    */
    function testLiquidationRevertsWhenCollateralValueTooLow() public {
        uint256 minUsdc = pool.MIN_LIQUIDATION_USDC();

        vm.deal(borrower, 0.001 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 0.001 ether}();
        pool.borrowUSDC(1_000_000); // 1 USDC
        vm.stopPrank();

        oracle.setPrice(1e8); // $1 to make collateral value < min liquidation

        _prepareLiquidator(minUsdc);
        vm.expectRevert(LendingPool.DustAmount.selector);
        pool.liquidate(borrower, minUsdc);
        _finalizeLiquidator();
    }

    /*
    - Borrower pide 1M USDC con 1 ETH de colateral cuando el cambio es alto 2M USD/ETH
    - El precio baja a 1.1M USD/ETH, HF<1, liquidable
    - Liquidator intenta liquidar por el minimo esperando revert DustAmount ya que con un precio tan alto, el colateral que seize por esa cantidad minima de repay es menos de 1gwei (MIN_LIQUIDATION_USDC)
    */
    function testLiquidationRevertsWhenSeizeBelowMinDueToPrice() public {
        uint256 minUsdc = pool.MIN_LIQUIDATION_USDC();

        vm.deal(borrower, 1 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1 ether}();
        oracle.setPrice(2_000_000e8);
        pool.borrowUSDC(1_000_000e6);
        vm.stopPrank();

        oracle.setPrice(1_100_000e8); // HF < 1, but seize for min repay < 1 gwei

        _prepareLiquidator(minUsdc);
        vm.expectRevert(LendingPool.DustAmount.selector);
        pool.liquidate(borrower, minUsdc);
        _finalizeLiquidator();
    }

    /*
    Close factor griefing:
    - Borrower queda underwater
    - El liquidator intenta liquidar todo, pero se limita por CLOSE_FACTOR_BPS
    - Se requieren multiples rondas para limpiar la deuda
    */
    function testCloseFactorRequiresMultipleLiquidations() public {
        vm.deal(borrower, 1 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1 ether}();
        uint256 maxBorrow = pool.getBorrowMax(borrower);
        pool.borrowUSDC(maxBorrow);
        vm.stopPrank();

        oracle.setPrice(1000e8);
        assertLt(pool.getHealthFactor(borrower), 1e18);

        _prepareLiquidator(2_000_000e6);

        uint256 debtBefore = pool.getUserDebtUSDC(borrower);
        uint256 collateralBefore = pool.collateralWETH(borrower);
        pool.liquidate(borrower, debtBefore);

        uint256 debtAfter = pool.getUserDebtUSDC(borrower);
        uint256 collateralAfter = pool.collateralWETH(borrower);
        assertGt(debtBefore, debtAfter);
        assertGt(collateralBefore, collateralAfter);
        assertGt(debtAfter, 0);
        assertLt(pool.getHealthFactor(borrower), 1e18);

        // Segunda ronda necesaria para seguir reduciendo deuda
        pool.liquidate(borrower, debtAfter);
        uint256 debtAfter2 = pool.getUserDebtUSDC(borrower);
        assertGt(debtAfter, debtAfter2);

        _finalizeLiquidator();
    }
}
