// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PoC bad debt/insolvency

Una caida brusca de precio deja deuda residual despues de liquidaciones y reduce la capacidad de retiro de lenders.
Ademas, muestra riesgo de liquidez (bank-run) si un borrower drena el cash del pool.

- Borrower toma el maximo
- Caida brusca de precio deja posicion underwater
- Liquidaciones sucesivas agotan el colateral
- Queda deuda residual
- El efectivo del pool es menor que lo que el lender debería poder retirar
- Bank-run: borrower toma toda la liquidez y el lender no puede retirar su supply completo
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract BadDebtInsolvencyPoC is Test {
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

        usdc.mint(lender, 2_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(1_500_000e6);
        vm.stopPrank();
    }

    /*
    Calcula si una liquidacion es posible y cuanto deberia repagarse sin revertir. Asi evitamos reverts al intentar liquidar en el PoC.
    - Si todo cuadra, devuelve ok=true y un repay seguro
    - Si no cuadra devuelve ok=false
    */
    function _liquidationQuote(address user) internal view returns (bool ok, uint256 repay) {
        uint256 debt = pool.getUserDebtUSDC(user);
        if (debt == 0) return (false, 0);
        if (pool.getHealthFactor(user) >= 1e18) return (false, 0);

        uint256 maxClose = (debt * pool.CLOSE_FACTOR_BPS()) / pool.BPS();
        if (maxClose < pool.MIN_LIQUIDATION_USDC()) return (false, 0);

        uint256 collateral = pool.collateralWETH(user);
        if (collateral == 0) return (false, 0);

        uint256 ethUsd = oracle.getEthUsdPrice();
        if (ethUsd == 0) return (false, 0);

        uint256 collateralUsdWad = (collateral * ethUsd) / 1e8;
        uint256 maxRepayUsdWad = (collateralUsdWad * pool.BPS()) / (pool.BPS() + pool.LIQ_BONUS_BPS());
        uint256 maxRepayUsdc = maxRepayUsdWad / 1e12;
        if (maxRepayUsdc == 0) return (false, 0);

        repay = maxClose < maxRepayUsdc ? maxClose : maxRepayUsdc;
        if (repay < pool.MIN_LIQUIDATION_USDC()) return (false, 0);

        uint256 seizeUsdWad = (repay * 1e12 * (pool.BPS() + pool.LIQ_BONUS_BPS())) / pool.BPS();
        uint256 seizeEth = (seizeUsdWad * 1e8 + ethUsd - 1) / ethUsd;
        if (seizeEth < pool.MIN_LIQUIDATION_WETH()) return (false, 0);

        return (true, repay);
    }

    /*
    Escenario completo de insolvencia
    - Borrower deposita 1ETH y pide maximo USDC
    - Precio cae a 200USDC, posicion underwater
    - Liquidator repaga en bucle hasta 10 veces para liquidar todo lo posible sin revert

    Comprueba que:
    - Existe deuda residual debt > 0
    - Ya no se puede liquidar mas _liquidationQuote devuelve ok=false

    Mide el impacto en lenders: poolCash < lenderSupply, el pool no puede cubrir el retiro total del lender
    */
    function testBadDebtAfterPriceCrash() public {
        vm.deal(borrower, 1 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1 ether}();
        uint256 maxBorrow = pool.getBorrowMax(borrower);
        pool.borrowUSDC(maxBorrow);
        vm.stopPrank();

        oracle.setPrice(200e8);

        usdc.mint(liquidator, 2_000_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);

        for (uint256 i = 0; i < 10; i++) {
            (bool ok, uint256 repay) = _liquidationQuote(borrower);
            if (!ok) break;
            pool.liquidate(borrower, repay);
        }
        vm.stopPrank();

        assertGt(pool.getUserDebtUSDC(borrower), 0);
        (bool stillLiquidatable,) = _liquidationQuote(borrower);
        assertTrue(!stillLiquidatable);

        uint256 lenderSupply = pool.getUserSupplyUSDC(lender);
        uint256 poolCash = usdc.balanceOf(address(pool));
        assertLt(poolCash, lenderSupply);
    }

    /*
    Riesgo de liquidez (bank-run):
    - Borrower toma toda la liquidez del pool
    - Lender intenta retirar su supply completo
    - Revert por InsufficientLiquidity
    */
    function testLenderWithdrawRevertsWhenPoolHasNoLiquidity() public {
        vm.deal(borrower, 1000 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1000 ether}();
        pool.borrowUSDC(1_500_000e6);
        vm.stopPrank();

        uint256 withdrawable = pool.getUserSupplyUSDC(lender);
        vm.startPrank(lender);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.withdrawUSDC(withdrawable);
        vm.stopPrank();
    }
}
