# Monitoring (Anvil + Node.js)

Este módulo demuestra un “monitoring on-chain” básico usando Anvil y un script en Node.js.

## 1) Arrancar Anvil
**En terminal nº1:**
```bash
anvil
```

## 2) Desplegar contratos (Foundry)
**En terminal nº2:**
Desde `lending-security/`:
```bash
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/DeployMonitoring.s.sol:DeployMonitoringScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key $PRIVATE_KEY \
  --broadcast
```

Esto crea `monitoring/addresses.json` con las direcciones desplegadas.  
**Nota:** este paso es necesario si reinicias Anvil o no existe `addresses.json`.  
Si `addresses.json` ya existe y Anvil sigue corriendo con ese mismo estado, puedes omitir el deploy.

## 3) Instalar dependencias y ejecutar el monitor
**En terminal nº3:**
```bash
cd monitoring
npm install
node monitor.js
```

## 4) Generar eventos de ejemplo
**En terminal nº4:**
```bash
cd monitoring
export PRIVATE_KEY=<OTRA_PRIVATE_KEY_DE_ANVIL>
node generate-events.js
```
Usa **una private key distinta** a la del deploy para evitar conflictos de nonce.

## Configuración opcional (.env)
Puedes crear un `.env` basado en `.env.example` para definir `RPC_URL` y `ADDR_PATH`.

## Qué hace el monitor
- Escucha eventos del `LendingPool` (Deposit, Borrow, Liquidate, etc.).
- Imprime métricas periódicas: utilization, borrow rate, borrow index y ETH/USD.
- Lanza una alerta básica si la utilización supera 90%.

## Output esperado en monitor
- Logs de eventos como `Deposit`, `SupplyUSDC`, `Borrow`, `Repay`, `Accrue`.
- Mensajes `[METRICS]` cada ~10s con utilization y borrow rate.
- Si la utilización > 90% aparece `[ALERT]`.

## Variables opcionales
- `RPC_URL` (default: http://127.0.0.1:8545)
- `ADDR_PATH` (default: ./addresses.json)
- `PRIVATE_KEY` (solo para `generate-events.js`)
