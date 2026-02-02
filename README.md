# Lending Security Suite

Auditoría completa de mi **Lending & Borrowing MVP** con foco en seguridad práctica: invariants, fuzzing, PoCs, tests unitarios, reportes y monitoring on-chain (Anvil + Node.js).  
Objetivo: demostrar capacidad real de auditoría y operación de protocolos DeFi.

## Highlights
- Invariants + fuzzing para health factor y consistencia supply/debt
- PoCs de riesgos reales: oráculos, liquidaciones, dust/rounding, bad debt, governance, reentrancy
- Tests unitarios de reverts críticos y sanity checks
- Threat model y Audit Report versionado
- CI con Foundry + Slither
- Monitoring on-chain local con Anvil

## Quickstart
**Tests básicos:**
```bash
cd lending-security
forge test
```

**PoCs:**
```bash
forge test --match-path test/pocs/*.t.sol
```

**Invariants:**
```bash
forge test --match-path test/LendingPool.invariants.t.sol
```

**Monitoring (demo visual):**
Ver detalles en: [README monitoring](monitoring/README.md)
```bash
anvil
```
```bash
cd lending-security
export PRIVATE_KEY=<ANVIL_PK_1>
forge script script/DeployMonitoring.s.sol:DeployMonitoringScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key $PRIVATE_KEY \
  --broadcast
```
```bash
cd monitoring
npm install
node monitor.js
```
```bash
export PRIVATE_KEY=<OTRA_ANVIL_PK>
node generate-events.js
```

## Estructura del repo
```
/lending-security-suite
  /protocol
    /Backend_Lending---Borrowing   # protocolo base (MVP)
    /vulnerable                    # versión intencionalmente vulnerable
    /patched                       # versión corregida
    CHANGELOG.md                   # security changelog
  /lending-security
    /test                          # unit tests + invariants + PoCs
    /script                        # scripts (deploy monitoring)
  /security
    /threat-model                  # THREAT_MODEL.md
  /monitoring                      # monitor on-chain (Anvil + Node.js)
  /reports                         # informes de auditoría
  CI.md                            # explicación del pipeline CI
```

## Cobertura de auditoría
- Oracle manipulation / stale / invalid / zero / DoS
- Liquidations (rounding/dust, close-factor griefing)
- Bad debt & insolvency
- Pause semantics y operational risks
- Governance risks (oracle swap, rate model shock, reserve factor abuse, rescueToken)
- Reentrancy attempt (bloqueado)
- Rounding/dust en deuda y shares
- Time granularity en accrue

## Documentación clave
- Threat Model: `security/threat-model/THREAT_MODEL.md`
- Audit Report: `reports/2026-01-28-report.md`
- PoCs Index: `lending-security/test/pocs/INDEX.md`
- CI: `CI.md`
- Monitoring: `monitoring/README.md`

## CI (Continuous Integration)
Workflow automático con `forge test`, `forge fmt --check`, `forge coverage` y Slither.  
Más detalles en `CI.md`.

## Notas sobre vulnerable/patched
Las carpetas `protocol/vulnerable` y `protocol/patched` permiten demostrar la trazabilidad:
**vulnerable → PoC → patch → changelog**.

## Learnings
Profundicé en riesgos reales de lending (oracle, liquidaciones, rounding/dust) y en cómo convertir hallazgos en PoCs reproducibles.  
También reforcé la disciplina de auditoría con threat model, reportes y CI para mantener el protocolo seguro en el tiempo.

## Roadmap breve
- Publicar README extendido con capturas del monitoring
- Métricas adicionales en monitoring
