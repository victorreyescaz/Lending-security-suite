// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PoC governance reserve factor abuse:

El owner puede subir el reserveFactor a 100% y capturar todos los intereses como reservas, reduciendo el upside de los lenders.
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract GovernanceReserveFactorPoC is Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");

    function setUp() public {
        weth = new WETH9();
        usdc = new MockUSDC();
        oracle = new OracleMock(2000e8);

        pool = new LendingPool(address(weth), address(usdc), address(oracle), 7500, 8000, 200, 400, 2000, 8000, 1000);

        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(800_000e6);
        vm.stopPrank();
    }

    /*
    Lender no captura los intereses si el owner pone reserveFactor=100%.

    - Lender deposita.
    - Borrower genera intereses.
    - Owner sube reserveFactor a 100%.
    - Tras accrue, el valor de getUserSupplyUSDC(lender) no sube (todo se va a reserveWad), mostrando pérdida de   upside.
    */
    function testOwnerSetsReserveFactorToMaxCapturesInterest() public {
        vm.deal(borrower, 1000 ether);
        vm.startPrank(borrower);
        pool.depositETH{value: 1000 ether}();
        pool.borrowUSDC(600_000e6);
        vm.stopPrank();

        uint256 sharesBefore = pool.supplyShares(lender);
        uint256 valueBefore = pool.getUserSupplyUSDC(lender);

        // Owner redirige todos los intereses a reservas.
        pool.setReserveFactor(10_000);

        vm.warp(block.timestamp + 365 days);
        pool.accrue();

        uint256 valueAfter = pool.getUserSupplyUSDC(lender);
        assertEq(pool.supplyShares(lender), sharesBefore);
        assertEq(valueAfter, valueBefore);
    }
}
