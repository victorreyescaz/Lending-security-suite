// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PoC rounding/dust en shares

Retirar "todo" (getUserSupplyUSDC) puede dejar shares residuales por redondeo. Con el ratio assets/shares cambiado
(por interes y movimientos de deuda), esas shares pueden quedar inrescatables cuando getUserSupplyUSDC devuelve 0.
Tambien se muestra que un micro-deposit puede revertir si el precio por share se dispara.
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract ShareRoundingDustPoC is Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;

    address lender = makeAddr("lender");
    address lender2 = makeAddr("lender2");
    address borrower = makeAddr("borrower");
    address micro = makeAddr("micro");

    uint256 constant FAIR_PRICE = 2000e8;

    function setUp() public {
        weth = new WETH9();
        usdc = new MockUSDC();
        oracle = new OracleMock(FAIR_PRICE);

        pool = new LendingPool(address(weth), address(usdc), address(oracle), 7500, 8000, 200, 400, 2000, 8000, 1000);

        usdc.mint(lender, 1_000_000e6);
        usdc.mint(lender2, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(500_000e6);
        vm.stopPrank();

        vm.startPrank(lender2);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(500_000e6);
        vm.stopPrank();
    }

    /*
    Demuestra share dust por redondeos tras cambiar el ratio

    - Borrower deposita 1000ETH y pide 800k USDC
    - Pasa el tiempo y se acumulan accrue, lo que cambia ratio assets/shares
    - Borrower repaga toda la deuda
    - Lender retira todo getUserSupplyUSDC

    - Quedan supplyShares(lender) > 0 pero getUserSupplyUSDC(lender) == 0

    - Comprobacion de que el lender no puede hacer withdrawUSDC(1), revierte con InsufficientShares
    */
    function testWithdrawAllLeavesShareDust() public {
        vm.deal(borrower, 1000 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1000 ether}();
        pool.borrowUSDC(800_000e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        pool.accrue();

        uint256 debt = pool.getUserDebtUSDC(borrower);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repayUSDC(debt);
        vm.stopPrank();

        uint256 withdrawable = pool.getUserSupplyUSDC(lender);
        vm.startPrank(lender);
        pool.withdrawUSDC(withdrawable);
        vm.stopPrank();

        assertGt(pool.supplyShares(lender), 0);
        assertEq(pool.getUserSupplyUSDC(lender), 0);

        vm.startPrank(lender);
        vm.expectRevert(LendingPool.InsufficientShares.selector);
        pool.withdrawUSDC(1);
        vm.stopPrank();
    }

    /*
    Fuerza precio por share muy alto subiendo rate model y demuestra que un micro-deposit revierte InsufficientShares
    */
    function testMicroDepositRevertsWhenSharePriceHuge() public {
        vm.deal(borrower, 1000 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1000 ether}();
        pool.borrowUSDC(900_000e6);
        vm.stopPrank();

        // Fuerza modelo de interes extremo para inflar el precio por share rapidamente. baseRateBps, slope1Bps, slope2Bps, optimalUtilBps
        pool.setRateModel(0, 0, 20_000_000_000_000_000, 0);

        vm.warp(block.timestamp + 365 days);
        pool.accrue();

        usdc.mint(micro, 1);
        vm.startPrank(micro);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(LendingPool.InsufficientShares.selector);
        pool.depositUSDC(1);
        vm.stopPrank();
    }
}
