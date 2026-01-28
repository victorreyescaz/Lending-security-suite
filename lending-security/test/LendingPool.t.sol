// SPDX-License-Identifier: MIT

/*
Skeleton minimo para el protocolo.
Despliega WETH9, MockUSDC, OracleMock.
Crea LendingPool, deposita USDC de liquidez y valida flujos basicos para auditar el comportamiento del pool.
Incluye tests de control de acceso admin, rescueToken y reverts esperados en liquidacion.

Cubre:
- Wiring del pool y mocks
- Flujos básicos (deposit/borrow/repay/withdraw)
- Liquidación y reverts esperados
- Pausa y control de acceso admin
- Comportamiento de accrue y rate model (kink)
- Reglas de rescueToken
- Reverts por liquidez insuficiente y parametros invalidos
*/

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
    address bob = makeAddr("bob");
    address liquidator = makeAddr("liquidator");
    uint256 constant ETH_USD = 2000e8;

    // Despliega mocks y el pool, deja liquidez USDC lista para los tests.
    function setUp() public {
        weth = new WETH9();
        usdc = new MockUSDC();
        oracle = new OracleMock(ETH_USD);

        pool = new LendingPool(
            address(weth),
            address(usdc),
            address(oracle),
            7500, // LTV_BPS => 75% Loan-to-value
            8000, // LIQ_THRESHOLD_BPS => 80% umbral de liquidación
            200, // BASE_RATE_BPS => 2% tasa base anual
            400, // SLOPE1_BPS => 4% pendiente hasta el kink
            2000, // SLOPE2_BPS => 20% pendiente por encima del kink
            8000, // OPTIMAL_UTIL_BPS => 80% utilizacion optima kink
            1000 // RESERVE_FACTOR_BPS => 10% de intereses para reservas
        );

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(500_000e6);
    }

    // Verifica que el wiring (cableado) basico del pool coincide con los mocks desplegados.
    function testSetup() public view {
        assertEq(address(pool.WETH()), address(weth));
        assertEq(address(pool.USDC()), address(usdc));
        assertEq(pool.borrowIndex(), 1e27);
    }

    // ---------- Flujos básicos ----------

    // Flujo happy path: depositar ETH y pedir prestado USDC por debajo del maximo.
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

    // Repago parcial, reduce la deuda del usuario.
    function testRepayReducesDebt() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        pool.depositETH{value: 1 ether}();
        pool.borrowUSDC(1_000e6);
        uint256 debtBefore = pool.getUserDebtUSDC(alice);
        usdc.approve(address(pool), type(uint256).max);
        pool.repayUSDC(400e6);
        uint256 debtAfter = pool.getUserDebtUSDC(alice);
        vm.stopPrank();

        assertEq(debtAfter, debtBefore - 400e6);
    }

    // ---------- Reverts por límites de usuario ----------

    // Reversion esperada si el usuario intenta pedir mas del maximo permitido.
    function testBorrowAboveMaxReverts() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        pool.depositETH{value: 1 ether}();
        uint256 maxBorrow = pool.getBorrowMax(alice);
        vm.expectRevert(LendingPool.HealthFactorTooLow.selector);
        pool.borrowUSDC(maxBorrow + 1);
        vm.stopPrank();
    }

    // Retirar colateral cuando HF quedaria < 1, debe revertir.
    function testWithdrawBelowHealthFactorReverts() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        pool.depositETH{value: 1 ether}();
        uint256 maxBorrow = pool.getBorrowMax(alice);
        pool.borrowUSDC(maxBorrow);
        vm.expectRevert(LendingPool.HealthFactorTooLow.selector);
        pool.withdrawETH(0.1 ether);
        vm.stopPrank();
    }

    // WithdrawETH debe revertir si el usuario intenta retirar mas colateral del que tiene.
    function testWithdrawETHRevertsWhenAboveCollateral() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        pool.depositETH{value: 1 ether}();
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.withdrawETH(2 ether);
        vm.stopPrank();
    }

    // ---------- Reverts por liquidez ----------

    // Borrow debe revertir si no hay liquidez suficiente en el pool.
    function testBorrowRevertsWhenInsufficientLiquidity() public {
        vm.deal(alice, 1000 ether);
        vm.startPrank(alice);
        pool.depositETH{value: 1000 ether}();
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.borrowUSDC(1_000_000e6);
        vm.stopPrank();
    }

    // WithdrawUSDC debe revertir si el pool no tiene cash suficiente.
    function testWithdrawUSDCRevertsWhenInsufficientLiquidity() public {
        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(900_000e6);
        vm.stopPrank();

        vm.deal(bob, 1000 ether);
        vm.startPrank(bob);
        pool.depositETH{value: 1000 ether}();
        pool.borrowUSDC(1_200_000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.withdrawUSDC(900_000e6);
        vm.stopPrank();
    }

    // ---------- Reverts por repay/liquidate ----------

    // Repay debe revertir con amount=0 o si el usuario no tiene deuda.
    function testRepayRevertsOnZeroAmountOrNoDebt() public {
        vm.startPrank(alice);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.repayUSDC(0);
        vm.stopPrank();

        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.repayUSDC(1_000e6);
        vm.stopPrank();
    }

    // Liquidate debe revertir si el repayAmount es 0.
    function testLiquidateRevertsOnZeroAmount() public {
        usdc.mint(liquidator, 1_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.liquidate(alice, 0);
        vm.stopPrank();
    }

    // ---------- Liquidaciones ----------

    // Simula una caída del precio del ETH que deja a Alice bajo el umbral de liquidación.
    function testLiquidationSeizesCollateralWhenUnderwater() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        pool.depositETH{value: 1 ether}();
        pool.borrowUSDC(1_200e6);
        vm.stopPrank();

        oracle.setPrice(1000e8);

        usdc.mint(liquidator, 1_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        uint256 debtBefore = pool.getUserDebtUSDC(alice);
        uint256 collateralBefore = pool.collateralWETH(alice);
        pool.liquidate(alice, 600e6);
        vm.stopPrank();

        uint256 debtAfter = pool.getUserDebtUSDC(alice);
        uint256 collateralAfter = pool.collateralWETH(alice);
        assertLt(debtAfter, debtBefore);
        assertLt(collateralAfter, collateralBefore);
        assertGt(weth.balanceOf(liquidator), 0);
    }

    // Liquidar cuando no hay deuda o cuando la posicion es saludable debe revertir.
    function testLiquidationRevertsWhenNoDebtOrHealthy() public {
        usdc.mint(liquidator, 1_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);

        vm.expectRevert(LendingPool.NotLiquidatable.selector);
        pool.liquidate(alice, 1_000e6);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        pool.depositETH{value: 1 ether}();
        pool.borrowUSDC(500e6);
        vm.stopPrank();

        vm.startPrank(liquidator);
        vm.expectRevert(LendingPool.NotLiquidatable.selector);
        pool.liquidate(alice, 100e6);
        vm.stopPrank();
    }

    // ---------- Pausa ----------

    // Cuando el pool esta pausado, borrow y withdraw deben revertir.
    function testPauseBlocksBorrowAndWithdraw() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        pool.depositETH{value: 1 ether}();
        vm.stopPrank();

        pool.pause();

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        pool.borrowUSDC(100e6);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        pool.withdrawETH(0.1 ether);
        vm.stopPrank();
    }

    // ---------- Admin ----------

    // Solo el owner puede actualizar parametros administrativos.
    function testOnlyOwnerCanUpdateParams() public {
        vm.startPrank(bob);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob)
        );
        pool.setReserveFactor(500);
        vm.stopPrank();
    }

    // Solo el owner puede llamar setOracle, setRiskParams y setRateModel.
    function testOnlyOwnerCanCallAdminFunctions() public {
        vm.startPrank(bob);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob)
        );
        pool.setOracle(address(oracle));

        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob)
        );
        pool.setRiskParams(7000, 7500);

        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob)
        );
        pool.setRateModel(100, 200, 300, 7000);
        vm.stopPrank();
    }

    // setRiskParams debe revertir si los parametros son invalidos.
    function testSetRiskParamsRevertsOnInvalidValues() public {
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.setRiskParams(9000, 8000);

        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.setRiskParams(10_001, 10_000);
    }

    // ---------- Rescue ----------

    // rescueToken debe rechazar token cero y tokens core (USDC/WETH).
    function testRescueTokenRejectsCoreAndZero() public {
        vm.expectRevert(LendingPool.Unsupported.selector);
        pool.rescueToken(address(0), alice, 1);

        vm.expectRevert(LendingPool.Unsupported.selector);
        pool.rescueToken(address(usdc), alice, 1);

        vm.expectRevert(LendingPool.Unsupported.selector);
        pool.rescueToken(address(weth), alice, 1);
    }

    // ---------- Accrue / Rate model ----------

    // La funcion accrue debe aumentar el borrowIndex con el paso del tiempo.
    function testAccrueIncreasesBorrowIndexOverTime() public {
        uint256 beforeIndex = pool.borrowIndex();
        vm.warp(block.timestamp + 1 hours);
        pool.accrue();
        uint256 afterIndex = pool.borrowIndex();
        assertGt(afterIndex, beforeIndex);
    }

    // El borrow rate debe aumentar mas rapido cuando la utilizacion supera el kink (OPTIMAL_UTIL_BPS).
    function testBorrowRateIncreasesAboveKink() public {
        uint256 rateAtLowUtil = pool.getBorrowRateBps();

        vm.deal(alice, 1000 ether);
        vm.startPrank(alice);
        pool.depositETH{value: 1000 ether}();
        pool.borrowUSDC(450_000e6);
        vm.stopPrank();

        uint256 rateAtHighUtil = pool.getBorrowRateBps();

        assertGt(rateAtHighUtil, rateAtLowUtil);
        assertGt(pool.getUtilizationBps(), pool.OPTIMAL_UTIL_BPS());
    }

    /*
    _accrue debe tolerar time-travel hacia atras: no cambia el index y resetea lastAccrual.
    - Avanza 1h => borrowIndex sube
    - Vuelve 30s atras => borrowIndex no cambia y lastAccrual se actualiza al nuevo ts
    - Avanza 61s => vuelve a subir el borrowIndex
    */
    function testAccrueHandlesBackwardTime() public {
        uint256 indexBefore = pool.borrowIndex();

        vm.warp(block.timestamp + 1 hours);
        pool.accrue();

        uint256 indexAfterForward = pool.borrowIndex();
        uint256 lastAfterForward = pool.lastAccrual();
        assertGt(indexAfterForward, indexBefore);

        vm.warp(lastAfterForward - 30);
        pool.accrue();

        assertEq(pool.borrowIndex(), indexAfterForward);
        assertEq(pool.lastAccrual(), lastAfterForward - 30);

        vm.warp(pool.lastAccrual() + 61);
        pool.accrue();
        assertGt(pool.borrowIndex(), indexAfterForward);
    }
}
