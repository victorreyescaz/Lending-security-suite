// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PoC DoS (Denial of Service, Denegacion de servicio) por oraculo stale:

El wrapper Oracle revierte si el feed esta stale.
Si el precio no se actualiza, acciones criticas (borrow/withdraw/liquidate) quedan bloqueadas.
*/

import "forge-std/Test.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {Oracle, IAggregatorV3} from "protocol/Oracle.sol";
import {WETH9} from "protocol/WETH9.sol";

// Simula precios y timestamps. Se utiliza para que el oraculo devuelva error StalePrice
contract AggregatorV3Mock is IAggregatorV3 {
    uint8 public override decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = updatedAt_;
        roundId = 1;
    }

    function setAnswer(int256 answer_) external {
        answer = answer_;
        roundId += 1;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
        roundId += 1;
    }

    // Devuelve valores como lo haría un feed real
    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

    // Escenario donde el oraculo real (wrapper Oracle.sol) revierte por precio stale y eso bloquea funciones criticas de pool
    contract OracleStaleDoSPoC is Test {
        LendingPool pool;
        WETH9 weth;
        MockUSDC usdc;
        Oracle oracle;
        AggregatorV3Mock feed;

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        address liquidator = makeAddr("liquidator");

        uint256 constant FAIR_PRICE = 2000e8;

        function setUp() public {
            weth = new WETH9();
            usdc = new MockUSDC();
            feed = new AggregatorV3Mock(8, int256(FAIR_PRICE), block.timestamp);
            oracle = new Oracle(address(feed), 60);

            pool = new LendingPool(
                address(weth), address(usdc), address(oracle), 7500, 8000, 200, 400, 2000, 8000, 1000
            );

            usdc.mint(lender, 1_000_000e6);
            vm.startPrank(lender);
            usdc.approve(address(pool), type(uint256).max);
            pool.depositUSDC(500_000e6);
            vm.stopPrank();

            vm.deal(borrower, 10 ether);
            vm.startPrank(borrower);
            pool.depositETH{value: 10 ether}();
            pool.borrowUSDC(1_000e6);
            vm.stopPrank();
        }

        /*
        Hace el feel stale:
        - Avanza el tiempo y luego fija updateAt del feed a un timestamp antiguo, eso provoca que Oracle.getEthUsdPrice() revierta con StalePrice

        Comprueba que el borrower no puede operar:
        - Intenta borrowUSDC y withdrawEth => espera revert StalePrice

        Comprueba que la liquidacion tambien se bloquea:
        - liquidator con capital intenta liquidate con el minimo permitido => espera revert StalePrice
        */
        function testStaleOracleBlocksBorrowWithdrawAndLiquidate() public {
            vm.warp(block.timestamp + 3 days);
            feed.setUpdatedAt(block.timestamp - 2 days);

            vm.startPrank(borrower);
            vm.expectRevert(Oracle.StalePrice.selector);
            pool.borrowUSDC(1e6);
            vm.expectRevert(Oracle.StalePrice.selector);
            pool.withdrawETH(0.1 ether);
            vm.stopPrank();

            uint256 minUsdc = pool.MIN_LIQUIDATION_USDC();
            usdc.mint(liquidator, 1_000e6);
            vm.startPrank(liquidator);
            usdc.approve(address(pool), type(uint256).max);
            vm.expectRevert(Oracle.StalePrice.selector);
            pool.liquidate(borrower, minUsdc);
            vm.stopPrank();
        }
    }
