// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PoC reentrancy attempt:

Intenta reentrar en withdrawETH durante el callback del receive. Deberia fallar por ReentrancyGuard y no permitir doble retiro.
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract ReentrantReceiver {
    LendingPool public pool;
    bool public reenterSuccess;
    bool internal attacking;

    constructor(LendingPool pool_) {
        pool = pool_;
    }

    function attack() external {
        uint256 amount = address(this).balance;
        require(amount > 0, "no balance");
        pool.depositETH{value: amount}();
        attacking = true;
        pool.withdrawETH(amount);
        attacking = false;
    }

    receive() external payable {
        if (attacking) {
            (bool ok,) = address(pool).call(abi.encodeWithSignature("withdrawETH(uint256)", 1));
            reenterSuccess = ok;
        }
    }
}

contract ReentrancyAttemptPoC is Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;
    ReentrantReceiver attacker;

    function setUp() public {
        weth = new WETH9();
        usdc = new MockUSDC();
        oracle = new OracleMock(2000e8);

        pool = new LendingPool(address(weth), address(usdc), address(oracle), 7500, 8000, 200, 400, 2000, 8000, 1000);

        attacker = new ReentrantReceiver(pool);
    }

    function testReentrancyAttemptIsBlocked() public {
        vm.deal(address(attacker), 1 ether);

        attacker.attack();

        assertTrue(!attacker.reenterSuccess());
        assertEq(pool.collateralWETH(address(attacker)), 0);
        assertEq(address(attacker).balance, 1 ether);
    }
}
