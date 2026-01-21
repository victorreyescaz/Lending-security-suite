// SPDX-License-Identifier: MIT

/*
Invariant tests para LendingPool: fuzz con un handler que simula depositos, borrows, repagos,
retiros, cambios de precio y liquidaciones
Valida que se mantengan invariantes globales de colateral/deuda/shares y reglas de seguridad cuando el HF < 1
*/
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

/*
Actor de fuzz.
Simula actors, ejecuta acciones, evita reverts obvios y crea estados complejos que luego son validados por las invariants del contrato LendingPoolInvariants
*/

contract LendingPoolHandler is Test {
    LendingPool public pool;
    WETH9 public weth;
    MockUSDC public usdc;
    OracleMock public oracle;

    address[] public actors;

    constructor(
        LendingPool pool_,
        WETH9 weth_,
        MockUSDC usdc_,
        OracleMock oracle_,
        address[] memory actors_
    ) {
        pool = pool_;
        weth = weth_;
        usdc = usdc_;
        oracle = oracle_;
        actors = actors_;
    }

    // Dado un numero (seed) elige que user válido va a ejecutar la accion
    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /*
    Se utiliza para evitar retiros que dejarían HF < 1. Calcula el HF de un user teniendo un colateral
    - Si no hay deuda devuelve HF infinito (max)
    - Convierte el colateral a USD utilizando el oraculo
    - Aplica el LIQ_THRESHOLD_BPS
    - Divide por la deuda en USD, USDC 18 decimales
    */
    function _healthFactorWithCollateral(
        address actor,
        uint256 ethCollateral
    ) internal view returns (uint256) {
        uint256 debtUsdc = pool.getUserDebtUSDC(actor);
        if (debtUsdc == 0) return type(uint256).max;
        uint256 ethUsd = oracle.getEthUsdPrice();
        uint256 collateralUsdWad = (ethCollateral * ethUsd) / 1e8;
        uint256 adjCollateralWad = (collateralUsdWad *
            pool.LIQ_THRESHOLD_BPS()) / pool.BPS();
        uint256 debtUsdWad = debtUsdc * 1e12;
        return (adjCollateralWad * 1e18) / debtUsdWad;
    }

    /* 
    Simula depósitos de colateral en fuzz
    Dado un actor, le da un value entre 1 y 10 ETH y ejecuta depositETH como ese actor
    */
    function depositETH(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 value = bound(amount, 1, 10 ether);
        vm.deal(actor, value);
        vm.prank(actor);
        pool.depositETH{value: value}();
    }

    /*
    Simula retiros de colateral sin romper la regla HF
    Dado un actor, comprueba si tiene colateral, si lo tiene calcula cuanto retirar y si ese actor tiene deuda calcula HF post-withdraw y no retira si HF quedaria por debajo de 1
    Si todo pasa llama a withdrawETH como ese actor
     */
    function withdrawETH(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 collateral = pool.collateralWETH(actor);
        if (collateral == 0) return;
        uint256 value = bound(amount, 1, collateral);
        if (pool.getUserDebtUSDC(actor) != 0) {
            uint256 newCol = collateral - value;
            if (_healthFactorWithCollateral(actor, newCol) < 1e18) return;
        }
        vm.prank(actor);
        pool.withdrawETH(value);
    }

    /*
    Simula provisión de liquidez en fuzz
    Dado un actor, limita entre 1 y 100.000 USDC, mina USDC, aprueba pool y deposita como ese actor 
    */
    function depositUSDC(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 value = bound(amount, 1e6, 100_000e6);
        usdc.mint(actor, value);
        vm.startPrank(actor);
        usdc.approve(address(pool), value);
        pool.depositUSDC(value);
        vm.stopPrank();
    }

    /*
    Simula retiros de liquidez sin exceder lo disponible
    Dado un actor, hace el calculo de cuanto puede retirar segun getUserSupplyUSDC, limita amount a la liquidez disponible del pool, ejecuta withdrawUSDC como ese actor
    */
    function withdrawUSDC(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 maxWithdraw = pool.getUserSupplyUSDC(actor);
        if (maxWithdraw == 0) return;
        uint256 available = usdc.balanceOf(address(pool));
        if (available == 0) return;
        uint256 value = bound(amount, 1, maxWithdraw);
        if (value > available) value = available;
        if (value == 0) return;
        vm.prank(actor);
        pool.withdrawUSDC(value);
    }

    /*
    Simula prestamos de USDC dentro de los limites del protocolo
    Dado un actor, calcula su maxBorrow y su deuda actual, si no tiene margen sale, sino limita el amount a ese margen y a la liquidez de la pool, ejecuta borrowUSDC como ese actor
    */
    function borrowUSDC(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 maxBorrow = pool.getBorrowMax(actor);
        uint256 debt = pool.getUserDebtUSDC(actor);
        if (maxBorrow <= debt) return;
        uint256 available = usdc.balanceOf(address(pool));
        if (available == 0) return;
        uint256 room = maxBorrow - debt;
        uint256 value = bound(amount, 1, room);
        if (value > available) value = available;
        if (value == 0) return;
        vm.prank(actor);
        pool.borrowUSDC(value);
    }

    /*
    Simula repagos parciales de deuda.
    Dado un actor, si no tiene deuda sale, acota amount hasta la deuda, mina USDC para pagar, aprueba y llama a repayUSDC como ese actor
    */
    function repayUSDC(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 debt = pool.getUserDebtUSDC(actor);
        if (debt == 0) return;
        uint256 value = bound(amount, 1, debt);
        usdc.mint(actor, value);
        vm.startPrank(actor);
        usdc.approve(address(pool), value);
        pool.repayUSDC(value);
        vm.stopPrank();
    }

    /*
    Simula liquidaciones reales durante el fuzz
    - Elige un user bajo-colaterizado (HF<1) 
    - Verifica que el user tiene deuda, colateral y HF<1
    - Calcula un repay valido respetando close factor y minimos
    - Minta USDC al liquidator, aprueba y llama a pool.liquidate
    */
    function liquidate(
        uint256 liquidatorSeed,
        uint256 targetSeed,
        uint256 repayAmount
    ) external {
        address user = _actor(targetSeed);
        address liquidator = _actor(liquidatorSeed);
        if (user == liquidator && actors.length > 1) {
            liquidator = _actor(liquidatorSeed + 1);
        }

        uint256 debt = pool.getUserDebtUSDC(user);
        if (debt == 0) return;
        if (pool.getHealthFactor(user) >= 1e18) return;

        uint256 collateral = pool.collateralWETH(user);
        if (collateral == 0) return;

        uint256 maxClose = (debt * pool.CLOSE_FACTOR_BPS()) / pool.BPS();
        if (maxClose < pool.MIN_LIQUIDATION_USDC()) return;

        uint256 repay = bound(
            repayAmount,
            pool.MIN_LIQUIDATION_USDC(),
            maxClose
        );

        uint256 ethUsd = oracle.getEthUsdPrice();
        uint256 collateralUsdWad = (collateral * ethUsd) / 1e8;
        uint256 maxRepayUsdWad = (collateralUsdWad * pool.BPS()) /
            (pool.BPS() + pool.LIQ_BONUS_BPS());
        uint256 maxRepayUsdc = maxRepayUsdWad / 1e12;
        if (maxRepayUsdc < pool.MIN_LIQUIDATION_USDC()) return;
        if (repay > maxRepayUsdc) repay = maxRepayUsdc;
        if (repay < pool.MIN_LIQUIDATION_USDC()) return;

        uint256 seizeUsdWad = (repay *
            1e12 *
            (pool.BPS() + pool.LIQ_BONUS_BPS())) / pool.BPS();
        uint256 seizeEth = (seizeUsdWad * 1e8 + ethUsd - 1) / ethUsd;
        if (seizeEth < pool.MIN_LIQUIDATION_WETH()) return;

        usdc.mint(liquidator, repay);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), repay);
        pool.liquidate(user, repay);
        vm.stopPrank();
    }

    /*
    Simula volatilidad del colateral y fuerza cambios en el HF durante el fuzz
    - Toma newPrice aleatorio entre 500 y 4000 con 8 decimales
    - Actualiza OracleMock con ese precio
    */
    function setPrice(uint256 newPrice) external {
        uint256 value = bound(newPrice, 500e8, 4000e8);
        oracle.setPrice(value);
    }

    // Sirve para que, en fuzz, el tiempo/interest afecte a la deuda y al HF.
    // Llama a pool.accrue para acumular intereses y subir el borrowIndex
    function accrue() external {
        pool.accrue();
    }
}

/*
- Entorno de fuzz ( mocks, pool, actors y handler)
- Declara invariantes que deben cumplirse SIEMPRE (functions invariant) 

Foundry ejecuta esas invariantes despues de secuencias aleatorias del handler para validar la seguridad del protocolo
*/
contract LendingPoolInvariants is StdInvariant, Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;
    LendingPoolHandler handler;

    address[] actors;

    // Preparacion del entorno para los invariants
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

        // Actors
        actors = new address[](3);
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");

        // Mintea USDC a alice y deposita 500k USDC al pool para dar liquidez inicial
        address lender = actors[0];
        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(500_000e6);
        vm.stopPrank();

        handler = new LendingPoolHandler(pool, weth, usdc, oracle, actors);

        // Viene de StdVariant. Conexion entre el motor del fuzz con nuestro handler
        // Le decimos a Foundry que utilice el contrato del handler como fuente de acciones, elegirá aleatoriamente funciones de ese contrato y las ejecutara miles de veces
        targetContract(address(handler));
    }

    // Recorre actors, si un actor tiene deuda y HF < 1 entonces no puede pedir mas ya que getBorrowMax <= deuda
    function invariant_noBorrowCapacityWhenUnderwater() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 debt = pool.getUserDebtUSDC(actor);
            if (debt == 0) continue;
            if (pool.getHealthFactor(actor) >= 1e18) continue;
            assertLe(pool.getBorrowMax(actor), debt);
        }
    }

    /*
    - Si un actor ya esta underwater, cualquier retiro no deberia devolver la posicion a saludable ni permitir que retire algo sin romper la regla
    - Para cada actor en underwater recalcula HF si retirara 1wei de colateral. Comprueba que HF seguiria por debajo de 1
    */
    function invariant_withdrawWouldBreakHealthFactorWhenUnderwater()
        public
        view
    {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 debt = pool.getUserDebtUSDC(actor);
            if (debt == 0) continue;
            if (pool.getHealthFactor(actor) >= 1e18) continue;
            uint256 collateral = pool.collateralWETH(actor);
            if (collateral == 0) continue;
            uint256 newCol = collateral - 1;
            uint256 ethUsd = oracle.getEthUsdPrice();
            uint256 collateralUsdWad = (newCol * ethUsd) / 1e8;
            uint256 adjCollateralWad = (collateralUsdWad *
                pool.LIQ_THRESHOLD_BPS()) / pool.BPS();
            uint256 debtUsdWad = debt * 1e12;
            uint256 newHf = (adjCollateralWad * 1e18) / debtUsdWad;
            assertLt(newHf, 1e18);
        }
    }

    // Comparacion de la suma de los colaterales de cada actor con su totalCollateralWETH, deben ser iguales
    function invariant_totalCollateralMatchesUsers() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += pool.collateralWETH(actors[i]);
        }
        assertEq(pool.totalCollateralWETH(), sum);
    }

    // Comparacion de la deuda escalada de cada actor, debe coindicir con totalScaleDebt
    function invariant_totalScaledDebtMatchesUsers() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += pool.scaledDebtUSDC(actors[i]);
        }
        assertEq(pool.totalScaledDebt(), sum);
    }

    // Comparacion de la suma de los shares de cada actor, deben ser iguales a totalSupplyShares. Aplicable solo a users lenders que aportan USDC para suministrar liquidez
    function invariant_totalSupplySharesMatchesUsers() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += pool.supplyShares(actors[i]);
        }
        assertEq(pool.totalSupplyShares(), sum);
    }

    /*
    - Calcula activos totales: USDC del contrato + deuda total
    - Comprueba que esos activos cubren las reservas reservedWad

    Las reservas no pueden ser mayores que los activos disponibles
    */
    function invariant_assetsCoverReserves() public view {
        uint256 cashWad = usdc.balanceOf(address(pool)) * 1e12;
        uint256 debtWad = (pool.totalScaledDebt() * pool.borrowIndex()) / 1e27;
        assertGe(cashWad + debtWad, pool.reserveWad());
    }
}
