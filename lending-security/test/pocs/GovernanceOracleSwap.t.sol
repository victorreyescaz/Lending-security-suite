// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PoC riesgo de gobernanza: 

El owner puede cambiar el oraculo a uno malicioso y permitir over-borrow con precio inflado. No es bug tecnico, es riesgo de control/gobernanza
El owner tambien puede cambiar parametros de riesgo y volver liquidables posiciones existentes sin mover el precio.
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract GovernanceOracleSwapPoC is Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;
    OracleMock evilOracle;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");

    uint256 constant FAIR_PRICE = 2000e8;
    uint256 constant EVIL_PRICE = 50000e8;

    function setUp() public {
        weth = new WETH9();
        usdc = new MockUSDC();
        oracle = new OracleMock(FAIR_PRICE);
        evilOracle = new OracleMock(EVIL_PRICE);

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
    }

    // El owner cambia el oraculo por uno inflado para aumentar el maxBorrow.
    // Se compara maxBorrow antes/despues, se borra al maximo y luego se restaura el oraculo real para comprobar que el HF queda < 1e18.

    function testOwnerSwapsOracleToInflateBorrowing() public {
        vm.deal(borrower, 1 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1 ether}();
        uint256 maxBorrowFair = pool.getBorrowMax(borrower);
        vm.stopPrank();

        pool.setOracle(address(evilOracle));

        vm.startPrank(borrower);
        uint256 maxBorrowEvil = pool.getBorrowMax(borrower);
        pool.borrowUSDC(maxBorrowEvil);
        vm.stopPrank();

        assertGt(maxBorrowEvil, maxBorrowFair);

        pool.setOracle(address(oracle));
        assertLt(pool.getHealthFactor(borrower), 1e18);
    }

    // El owner baja los parametros de riesgo y convierte una posicion sana en liquidable sin que el precio cambie.
    function testOwnerLowersRiskParamsForcesLiquidation() public {
        vm.deal(borrower, 1 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1 ether}();
        uint256 maxBorrow = pool.getBorrowMax(borrower);
        pool.borrowUSDC(maxBorrow);
        vm.stopPrank();

        uint256 hfBefore = pool.getHealthFactor(borrower);
        assertGt(hfBefore, 1e18);

        pool.setRiskParams(7000, 7000);

        uint256 hfAfter = pool.getHealthFactor(borrower);
        assertLt(hfAfter, 1e18);
    }
}
