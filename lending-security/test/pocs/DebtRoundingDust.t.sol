// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PoC rounding/dust de deuda

Pagar "todo" (getUserDebtUSDC) puede dejar scaledDebt residual por redondeo. Con uso alto del pool
el borrowIndex sube y esa deuda fantasma puede reaparecer aunque el usuario crea haber cerrado.

Ademas, repayUSDC revierte con ZeroAmount si la deuda visible es 0, dejando al usuario sin forma
de cerrar el residuo.
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract DebtRoundingDustPoC is Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address whale = makeAddr("whale");

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

        usdc.mint(lender, 7_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(6_000_000e6);
        vm.stopPrank();
    }

    /*
    "Pagar todo" peude dejar un residuo interno aunque la deuda visible sea 0
    - Borrower deposita 1ETH y pide 1USDC
    - Avanza el tiempo y se llama a accrue para que suba el borrowIndex
    - Borrower paga exactamente getUserDebtUSDC(borrower)
    - getUserDebtUSDC queda a 0 PERO scaleDebtUSDC > 0 por redondeos en el calculo del repago
    */
    function testRepayAllLeavesScaledDust() public {
        vm.deal(borrower, 1 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1 ether}();
        pool.borrowUSDC(1e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 120);
        pool.accrue();

        uint256 debtUsdc = pool.getUserDebtUSDC(borrower);
        assertEq(debtUsdc, 1e6);
        usdc.mint(borrower, debtUsdc);
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repayUSDC(debtUsdc);
        vm.stopPrank();

        assertEq(pool.getUserDebtUSDC(borrower), 0);
        assertGt(pool.scaledDebtUSDC(borrower), 0);
    }

    /*
    Si la deuda visible es 0 pero queda scaledDebt, repayUSDC revierte con ZeroAmount,
    dejando al usuario sin forma de cerrar el residuo.
    */
    function testRepayZeroDebtRevertsWithDust() public {
        vm.deal(borrower, 1 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1 ether}();
        pool.borrowUSDC(1e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 120);
        pool.accrue();

        uint256 debtUsdc = pool.getUserDebtUSDC(borrower);
        usdc.mint(borrower, debtUsdc);
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repayUSDC(debtUsdc);
        vm.stopPrank();

        assertEq(pool.getUserDebtUSDC(borrower), 0);
        assertGt(pool.scaledDebtUSDC(borrower), 0);

        vm.startPrank(borrower);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.repayUSDC(1);
        vm.stopPrank();
    }

    /*
    Al quedar residuo tras pagar la deuda, cuando accrue sube la deuda se hace visible
    Demuestra que con el tiempo el impacto del residuo puede ser muy notable dado la alta utilizacion del pool, de ahi crear una whale, para subir la utilizacion y acelerar el crecimiento de borrowIndex, asi la deuda "fantasma" aparece más rapido
    */
    function testDustReappearsAfterAccrue() public {
        vm.deal(whale, 4000 ether);
        vm.startPrank(whale);
        pool.depositETH{value: 4000 ether}();
        pool.borrowUSDC(5_000_000e6);
        vm.stopPrank();

        vm.deal(borrower, 400 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 400 ether}();
        pool.borrowUSDC(500_000e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 120);
        pool.accrue();

        uint256 debtUsdc = pool.getUserDebtUSDC(borrower);
        assertGt(debtUsdc, 0);
        usdc.mint(borrower, debtUsdc);
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repayUSDC(debtUsdc);
        vm.stopPrank();

        for (uint256 i = 0; i < 15; i++) {
            vm.warp(block.timestamp + 365 days);
            pool.accrue();
        }

        assertGt(pool.getUserDebtUSDC(borrower), 0);
    }
}
