# Threat Model Lending Security Suite

## Alcance
Protocolo auditado: `protocol/Backend_Lending---Borrowing`

Componentes principales:
- `LendingPool` (core: deposits, borrows, repays, liquidations, shares)
- `Oracle` / `OracleMock` (precio ETH/USD)
- Tokens: `WETH9`, `MockUSDC`

Fuera de alcance (por ahora):
- Integraciones externas (DEX/TWAP reales)
- Bridges, multi-chain, governance on-chain
- UI, backend, off-chain services

## Actores
- **Lenders**: depositan USDC y esperan rendimiento.
- **Borrowers**: depositan ETH como colateral y piden USDC.
- **Liquidators**: repagan deuda y reciben colateral con bonus.
- **Owner/Admin**: puede pausar, cambiar oracle, risk params, rate model, reserve factor, rescue tokens.
- **Oracle/Feed**: fuente de precio ETH/USD (puede estar stale/invalid/comprometida).
- **Atacantes externos**: intentan manipular oracle, explotar rounding/dust, DoS o reentrancy.

## Superficies de ataque
- **Oracle**: manipulación de precio, stale/invalid/zero, DoS al revertir.
- **Liquidaciones**: rounding/dust, close factor, seize mínimo, underflow/overflow.
- **Accrue/Rate model**: interest shocks, rounding por minuto, backward time.
- **Pausas**: bloqueos de liquidaciones en crash, bypass de funciones críticas.
- **Shares/supply**: dust en shares, micro-deposits, inconsistencias de share price.
- **Access control**: admin abuse (setOracle/setRiskParams/setRateModel/setReserveFactor).
- **Rescue token**: extracción de tokens no core (centralization risk).
- **Reentrancy**: withdrawETH/liquidate con callbacks.
- **Liquidez**: bank-run y `InsufficientLiquidity`.

## Supuestos
- `WETH9` y `MockUSDC` cumplen ERC20 básico y no son maliciosos.
- El owner controla las funciones admin; el riesgo de governance es explícito.
- El oracle devuelve ETH/USD con 8 decimales y puede revertir.
- No hay MEV protection / TWAP real en este MVP.

## Límites del modelo
- No se evalúa seguridad económica en mainnet (flash loans reales, DEX oracles).
- No se cubren riesgos de infra off-chain (bots, indexers, infra nodes).
- No se analiza upgradeability.

## Matriz impacto / probabilidad (ejemplos)

| Riesgo | Impacto | Probabilidad | Notas |
|---|---|---|---|
| Manipulación de oracle (price inflate) | Alto | Medio | Puede permitir over-borrow y bad debt |
| Oracle stale/invalid DoS | Medio | Medio | Bloquea borrow/withdraw/liquidate |
| Bad debt tras crash | Alto | Medio | Insolvencia y pérdidas para lenders |
| Pause bloquea liquidaciones | Medio | Medio | Operacional, riesgo de acumulación de deuda |
| Dust/rounding en liquidaciones | Medio | Bajo | Liquidaciones fallidas por mínimos |
| Dust en shares / micro-deposits | Bajo | Medio | UX y fondos pequeños atrapados |
| Close factor griefing | Bajo | Medio | Más rondas, más gas |
| Admin abuse (oracle/risk/ratemodel) | Alto | Bajo-Medio | Centralization risk |
| Rescue token | Bajo | Medio | Centralization risk |
| Reentrancy | Alto | Bajo | Mitigado con ReentrancyGuard |

## Controles y pruebas existentes
- Invariantes + fuzz: `lending-security/test/LendingPool.invariants.t.sol`
- PoCs: `lending-security/test/pocs/` (ver `INDEX.md`)
- Unit tests core: `lending-security/test/LendingPool.t.sol`
- Sanity tests shares: `lending-security/test/LendingPool.sanity.t.sol`

## Estrategia de mitigación
- Oracle robusto (stale checks + múltiples fuentes si procede).
- Límites de liquidación (min close / min seize) y handling de dust.
- Protección de liquidaciones en pausa (procedimiento operativo claro).
- Governance/timelock/multisig para funciones admin críticas.
- Documentación de riesgos centralizados y operativos.
