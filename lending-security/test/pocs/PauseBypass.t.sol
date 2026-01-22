// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PoC pause-bypass

Verifica que funciones criticas (borrow/withdraw/liquidate) no pueden ejecutarse cuando el pool esta en pausa.
Tambien que funciones como depositETH, depositUSDC y repayUSDC siguen funcionando cuando el pool está pausado.
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract PauseBypassPoC is Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address liquidator = makeAddr("liquidator");

    function setUp() public {
        weth = new WETH9();
        usdc = new MockUSDC();
        oracle = new OracleMock(2000e8);

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
        pool.depositUSDC(500_000e6);
        vm.stopPrank();

        vm.deal(borrower, 1 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1 ether}();
        pool.borrowUSDC(1_000e6);
        vm.stopPrank();
    }

    // Validamos que, estando en pausa, ninguna accion critica se pueda ejecutar
    function testPauseBlocksCriticalFunctions() public {
        pool.pause();

        // borrower intenta borrowUSDC y withdrawETH y espera EnforcedPause() (Viene de contrato openzeppelin Pausable.sol)
        vm.startPrank(borrower);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        pool.borrowUSDC(1e6);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        pool.withdrawETH(0.1 ether);
        vm.stopPrank();

        // lender intenta withdrawUSDC
        vm.startPrank(lender);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        pool.withdrawUSDC(1e6);
        vm.stopPrank();

        // Baja el precio del oraculo para que el borrower quede liquidable. Liquidador intenta liquidar
        oracle.setPrice(1000e8);
        usdc.mint(liquidator, 1_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        pool.liquidate(borrower, 500e6);
        vm.stopPrank();
    }

    // Demuestra que depositETH, depositUSDC y repayUSDC siguen funcionando cuando el pool está pausado
    function testPauseAllowsDepositAndRepay() public {
        pool.pause();

        vm.deal(borrower, 1 ether);
        vm.prank(borrower);
        pool.depositETH{value: 0.1 ether}();

        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(1_000e6);
        vm.stopPrank();

        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repayUSDC(100e6);
        vm.stopPrank();
    }
}
