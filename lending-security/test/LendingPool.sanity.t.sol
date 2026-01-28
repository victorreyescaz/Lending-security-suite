// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
Sanity tests para supply/withdraw USDC:
- depositUSDC refleja getUserSupplyUSDC
- withdrawUSDC reduce supply
- retirar el resto deja supply visible en 0 y no permite mas retiros
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract LendingPoolSanityTest is Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;

    address lender = makeAddr("lender");

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
        vm.stopPrank();
    }

    // Deposit y withdraw deben reflejarse en getUserSupplyUSDC.
    function testSupplyAndWithdrawSanity() public {
        vm.startPrank(lender);
        pool.depositUSDC(100_000e6);
        vm.stopPrank();

        uint256 supplyBefore = pool.getUserSupplyUSDC(lender);
        assertEq(supplyBefore, 100_000e6);

        vm.startPrank(lender);
        pool.withdrawUSDC(40_000e6);
        vm.stopPrank();

        uint256 supplyAfter = pool.getUserSupplyUSDC(lender);
        assertEq(supplyAfter, 60_000e6);

        vm.startPrank(lender);
        pool.withdrawUSDC(supplyAfter);
        vm.stopPrank();

        assertEq(pool.getUserSupplyUSDC(lender), 0);

        vm.startPrank(lender);
        vm.expectRevert(LendingPool.InsufficientShares.selector);
        pool.withdrawUSDC(1);
        vm.stopPrank();
    }
}
