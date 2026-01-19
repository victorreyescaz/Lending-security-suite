# Lending & Borrowing MVP (ETH/WETH + USDC)

Backend MVP de lending/borrowing con colateral ETH (WETH), deuda USDC, interés variable tipo kink y liquidaciones básicas. Pensado para integrarse desde un frontend sin modificar el contrato.

## Quickstart

```bash
npm install
npm test
npm run deploy:local
npm run interact:local -- status
```

## Contratos

- `contracts/LendingPool.sol`: core del protocolo.
- `contracts/Oracle.sol`: wrapper de Chainlink con `stale` check.
- `contracts/MockUSDC.sol`: token de test (6 decimales).
- `contracts/WETH9.sol`: wrapper WETH estándar.

## Arquitectura

### Flujo de datos

1. Lenders depositan USDC → reciben shares sobre el total del pool.
2. Usuario deposita ETH → se envuelve a WETH y se registra como colateral.
3. Usuario pide borrow USDC hasta un % del valor del colateral (LTV).
4. Se calcula Health Factor: si baja de 1, estaría en riesgo (en MVP puedes solo bloquear withdraw/borrow si HF < 1).
5. Intereses:
   Borrow APR: tasa variable según utilización (kink), la deuda crece con el tiempo.
   Supply APY: el interés pagado aumenta el valor de las shares.
6. Lenders pueden retirar USDC si hay liquidez disponible en el pool.

## Integración frontend (resumen)

- `depositETH` usa `msg.value`.
- `depositUSDC` y `repayUSDC` requieren `approve` previo.
- `borrowUSDC`/`withdrawETH`/`withdrawUSDC` bloquean si `HF < 1`.
- Utiliza eventos para sincronizar UI (ver sección Eventos).

## Interfaz pública (LendingPool)

Core:

- `depositETH()`, `withdrawETH(amount)`
- `depositUSDC(amount)`, `withdrawUSDC(amount)`
- `borrowUSDC(amount)`, `repayUSDC(amount)`
- `liquidate(user, repayAmount)`
- `accrue()`

Views útiles:

- `getHealthFactor(user)`
- `getBorrowMax(user)`
- `getUserDebtUSDC(user)`
- `getUserSupplyUSDC(user)`
- `getUtilizationBps()`
- `getBorrowRateBps()`

Admin:

- `pause()`, `unpause()`
- `setRiskParams(ltvBps, liqThresholdBps)`
- `setRateModel(base, slope1, slope2, optimal)`
- `setReserveFactor(bps)`
- `setOracle(address)`
- `rescueToken(token, to, amount)`

## Eventos

- `Deposit`, `Withdraw`
- `Borrow`, `Repay`
- `SupplyUSDC`, `WithdrawUSDC`
- `Liquidate`
- `Accrue`
- `RiskParamsUpdated`, `RateModelUpdated`, `ReserveFactorUpdated`, `OracleUpdated`

## Unidades y decimales

- ETH/WETH: 18 decimales.
- USDC: 6 decimales.
- Oráculo ETH/USD: 8 decimales.
- Health Factor: wad (1e18).
- `borrowIndex`: ray (1e27).
- Parámetros en bps: 10_000 = 100%.

## Admin & safety (MVP)

- Owner puede pausar parcialmente: se bloquea `borrow`, `withdraw` y `liquidate`, pero se permite `deposit` y `repay`.
- Parámetros configurables por owner: LTV/LT, curva de interés (base/slope/kink), reserve factor y oráculo.
- Rescue de tokens no core (excluye USDC/WETH).

## Parámetros por defecto (deploy)

Definidos en `scripts/deploy.ts` y configurables por `.env`:

- `LTV_BPS=7500`, `LIQ_THRESHOLD_BPS=8000`
- `BASE_RATE_BPS=200`, `SLOPE1_BPS=600`, `SLOPE2_BPS=4000`, `OPTIMAL_UTIL_BPS=8000`
- `RESERVE_FACTOR_BPS=0`

## Fórmulas (MVP)

- Utilización (bps): `U = debt / (debt + cash)`.
- Borrow rate (bps) si `U <= optimal`: `rate = base + slope1 * U / optimal`.
- Borrow rate (bps) si `U > optimal`: `rate = base + slope1 + slope2 * (U - optimal) / (1 - optimal)`.
- Borrow index (ray): `index = index * (1 + rate_per_year * dt / YEAR)`.
- Deuda USDC: `debt = scaledDebt * borrowIndex` (ray → 6 dec).
- Health factor (wad): `(collateralUsd * LT) / debtUsd`.
- Shares mint: `shares = amount * totalShares / totalAssets`.
- Shares withdraw: `shares = ceil(amount * totalShares / totalAssets)`.
- Total assets (wad): `cash + debt - reserve`.

## Invariantes / checks

- Si `HF < 1`, no se permite `borrow` ni `withdraw`.
- `totalAssets >= 0` y `reserve <= cash + debt`.
- `U` está en `[0, 10_000]`.
- Si `totalShares == 0`, la tasa de cambio shares/USDC es 1:1.
- Si no hay deuda, `HF = max`.

## Limitaciones (MVP)

- Single-asset: solo ETH/WETH como colateral y USDC como deuda.
- Admin centralizado (sin timelock/multisig).
- Sin upgradeability.
- No existen límites mçaximos de depósito o de deuda por usuario ni por activo.
