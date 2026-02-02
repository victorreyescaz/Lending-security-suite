// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PoC centralization risk: rescueToken

El owner puede recuperar tokens no core enviados al pool.
Es un riesgo de gobernanza/operativo (admin drain de tokens no core).
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Creacion token RescueToken
contract RescueToken is ERC20 {
    constructor() ERC20("RescueToken", "RSC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RescueTokenCentralizationPoC is Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;
    RescueToken token;

    address user = makeAddr("user");

    function setUp() public {
        weth = new WETH9();
        usdc = new MockUSDC();
        oracle = new OracleMock(2000e8);

        pool = new LendingPool(address(weth), address(usdc), address(oracle), 7500, 8000, 200, 400, 2000, 8000, 1000);

        token = new RescueToken();
    }

    /*
    El owner puede recuperar cualquier ERC20 "no core" que esté en el pool.
    */
    function testOwnerCanRescueNonCoreToken() public {
        token.mint(user, 1_000e18);
        vm.startPrank(user);
        token.transfer(address(pool), 1_000e18);
        vm.stopPrank();

        uint256 ownerBefore = token.balanceOf(address(this));
        uint256 poolBefore = token.balanceOf(address(pool));
        assertEq(poolBefore, 1_000e18);

        // Owner extrae los tokens "RSC" del pool
        pool.rescueToken(address(token), address(this), 1_000e18);

        uint256 ownerAfter = token.balanceOf(address(this));
        uint256 poolAfter = token.balanceOf(address(pool));
        assertEq(poolAfter, 0);
        assertEq(ownerAfter, ownerBefore + 1_000e18);
    }
}
