// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PoC interest-free window: 

_accrue ignora periodos < 60s, por lo que un borrow y repay en menos de un minuto no genera interes. Despues de 60s, el borrowIndex sube y la deuda crece.
Tambien se muestra el redondeo por minuto: el interes solo se aplica al completar bloques de 60s.
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract InterestFreeWindowPoC is Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");

    uint256 constant FAIR_PRICE = 2000e8;
    uint256 constant BORROW_AMOUNT = 500_000e6;

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

        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(700_000e6);
        vm.stopPrank();
    }

    // Borrower deposita 1000ETH y pide prestado BORROW_AMOUNT
    function _openBorrow() internal {
        vm.deal(borrower, 1000 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1000 ether}();
        pool.borrowUSDC(BORROW_AMOUNT);
        vm.stopPrank();
    }

    // borrowIndex no cambia y la deuda del borrower permanece igual al monto prestado ya que no han pasado 60s
    function testBorrowUnder60sAccruesNoInterest() public {
        _openBorrow();
        uint256 indexBefore = pool.borrowIndex();

        vm.warp(block.timestamp + 59);
        pool.accrue();

        assertEq(pool.borrowIndex(), indexBefore);
        assertEq(pool.getUserDebtUSDC(borrower), BORROW_AMOUNT);
    }

    // borrow + repay en menos de 60s no genera interes adicional
    function testBorrowRepayUnder60sPaysNoInterest() public {
        _openBorrow();
        uint256 indexBefore = pool.borrowIndex();

        vm.warp(block.timestamp + 59);
        pool.accrue();

        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repayUSDC(BORROW_AMOUNT);
        vm.stopPrank();

        assertEq(pool.borrowIndex(), indexBefore);
        assertEq(pool.getUserDebtUSDC(borrower), 0);
    }

    // borrowIndex sube y la deuda del borrower es mayor que el principal ya que han pasado mas de 60s
    function testBorrowOver60sAccruesInterest() public {
        _openBorrow();
        uint256 indexBefore = pool.borrowIndex();

        vm.warp(block.timestamp + 61);
        pool.accrue();

        assertGt(pool.borrowIndex(), indexBefore);
        assertGt(pool.getUserDebtUSDC(borrower), BORROW_AMOUNT);
    }

    /*
    Granularidad por minuto:
    - dos ventanas de 59s no generan interés hasta completar 60s
    - 59s + 59s acumula lo mismo que un único warp de 118s (1 minuto)
    */
    function testMinuteRoundingIsPerFullMinute() public {
        uint256 snap = vm.snapshotState();

        _openBorrow();
        uint256 indexBefore = pool.borrowIndex();

        vm.warp(block.timestamp + 59);
        pool.accrue();
        assertEq(pool.borrowIndex(), indexBefore);

        vm.startPrank(borrower);
        pool.borrowUSDC(100e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 59);
        pool.accrue();
        uint256 indexSplit = pool.borrowIndex();

        vm.revertToState(snap);

        _openBorrow();
        uint256 indexBeforeSingle = pool.borrowIndex();
        vm.warp(block.timestamp + 118);
        pool.accrue();
        uint256 indexSingle = pool.borrowIndex();

        assertEq(indexSplit, indexSingle);
        assertGt(indexSingle, indexBeforeSingle);
    }
}
