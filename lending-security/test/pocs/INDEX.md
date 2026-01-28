# PoC Index

- **BadDebtInsolvency.t.sol** – bad debt tras crash y bank-run
- **DebtRoundingDust.t.sol** – dust de deuda y repay con residuo
- **GovernanceOracleSwap.t.sol** – riesgo de gobernanza (oracle swap, risk params, rate model shock)
- **GovernanceReserveFactor.t.sol** – reserve factor abuse (intereses a reservas)
- **InterestFreeWindow.t.sol** – ventana <60s y redondeo por minuto
- **LiquidationRounding.t.sol** – rounding/dust en liquidaciones y close factor griefing
- **OracleInvalidPriceDoS.t.sol** – DoS por precio inválido del oracle
- **OracleManipulation.t.sol** – manipulación de precio para over-borrow
- **OracleStaleDoS.t.sol** – DoS por oracle stale (wrapper real)
- **OracleZeroOrStale.t.sol** – precio cero/stale enmascara o bloquea
- **PauseBypass.t.sol** – pausa bloquea críticas; depósitos/repays siguen; liquidaciones bloqueadas
- **ReentrancyAttempt.t.sol** – intento de reentrancy bloqueado
- **RescueTokenCentralization.t.sol** – rescueToken como riesgo de centralización
- **ShareRoundingDust.t.sol** – dust en shares y micro-deposit revert
