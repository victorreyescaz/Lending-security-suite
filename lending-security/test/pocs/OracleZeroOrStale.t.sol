// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PoC oraculo cero/estancado

Muestra que si el feed/orcaulo devuelve 0, las liquidaciones no se pueden ejecutar, y si el feed queda estancado en un precio alto, el pool puede considerar saludable una posicion que estaria underwater con el precio real.
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract OracleZeroOrStalePoC is Test {
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

        pool = new LendingPool(address(weth), address(usdc), address(oracle), 7500, 8000, 200, 400, 2000, 8000, 1000);

        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(500_000e6);
        vm.stopPrank();
    }

    /*
    - Replica el calculo de HF del protocolo pero con un precio externo ethUsd que decidimos
    - Compara el HF real con el HF que el pool cree(si el oraculo esta estancado)
    */
    function _healthFactorAtPrice(address user, uint256 ethUsd) internal view returns (uint256) {
        uint256 debtUsdc = pool.getUserDebtUSDC(user);
        if (debtUsdc == 0) return type(uint256).max;
        uint256 collateral = pool.collateralWETH(user);
        uint256 collateralUsdWad = (collateral * ethUsd) / 1e8;
        uint256 adjCollateralWad = (collateralUsdWad * pool.LIQ_THRESHOLD_BPS()) / pool.BPS();
        uint256 debtUsdWad = debtUsdc * 1e12;
        return (adjCollateralWad * 1e18) / debtUsdWad;
    }

    /*
    Demuestra que con un oraculo a 0 se bloquean liquidaciones
    - Borrower deposita 1 ETH y pide 1000 USDC
    - Se fuerza oraculo a 0 y se verifica que HF cae < 1
    - Liquidator intenta liquidar por el minimo esperando revert InsufficientCollateral ya que con precio 0 no se puede calcular liquidacion ya que el protocolo lo trata como colateral 0
    */
    function testOracleZeroBlocksLiquidation() public {
        vm.deal(borrower, 1 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1 ether}();
        pool.borrowUSDC(1_000e6);
        vm.stopPrank();

        oracle.setPrice(0);
        assertLt(pool.getHealthFactor(borrower), 1e18);

        uint256 minUsdc = pool.MIN_LIQUIDATION_USDC();
        usdc.mint(liquidator, 1_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.liquidate(borrower, minUsdc);
        vm.stopPrank();
    }

    /*
    Demuestra que un orcaculo escantado en precio alto puede ocultar posiciones riesgosas
    - Borrower deposita 1ETH y pide 1400 USDC
    - Con precio oraculo 2000 HF>1
    - Calcula shadowHF con oraculo 1000
    - Comprueba que shadowHF < 1, en el "mundo real" la posicion estaria underwater
    */
    function testStaleOracleMasksUnderwaterPosition() public {
        vm.deal(borrower, 1 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1 ether}();
        pool.borrowUSDC(1_400e6);
        vm.stopPrank();

        uint256 poolHf = pool.getHealthFactor(borrower);
        assertGe(poolHf, 1e18);

        uint256 shadowHf = _healthFactorAtPrice(borrower, 1000e8);
        assertLt(shadowHf, 1e18);
    }
}
