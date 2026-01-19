// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract LendingPoolTest is Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;

    address alice = makeAddr("alice");
    uint256 constant ETH_USD = 2000e8;

    function setUp() public {
        weth = new WETH9();
        usdc = new MockUSDC();
        oracle = new OracleMock(ETH_USD);

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

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(500_000e6);
    }

    function testSetup() public {
        assertEq(address(pool.WETH()), address(weth));
        assertEq(address(pool.USDC()), address(usdc));
        assertEq(pool.borrowIndex(), 1e27);
    }

    function testDepositAndBorrow() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        pool.depositETH{value: 1 ether}();
        uint256 maxBorrow = pool.getBorrowMax(alice);
        uint256 borrowAmount = maxBorrow / 2;
        pool.borrowUSDC(borrowAmount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), borrowAmount);
    }
}
