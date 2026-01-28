/*
Listener + metricas para demostrar monitoring realista en local

- Conecta Anvil
  · Usa RPC_URL o http://127.0.0.1:8545
  · Lee direcciones desde addresses.json

- Crea contratos
  · LendingPool con ABI de eventos y funciones de metricas
  · Oracle para leer getEthUsdPrice()

- Escucha eventos
  · Imprime por consola Deposit, Withdraw, Borrow, Repay, SupplyUSDC, WithdrawUSDC, Liquidate y Accrue cuando ocurren

- Metricas periodicas cada 10s
  · utilizationBps, borrowBps, borrowIndex, ethUsdPrice

- Alertas
  · Si utilization > 90% imprime un warning
*/

import { readFileSync } from "node:fs";
import { JsonRpcProvider, Contract } from "ethers";

const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
const ADDR_PATH = process.env.ADDR_PATH || "./addresses.json";

const addresses = JSON.parse(readFileSync(ADDR_PATH, "utf-8"));

const provider = new JsonRpcProvider(RPC_URL);

const poolAbi = [
  "event Deposit(address indexed user, uint256 ethAmount)",
  "event Withdraw(address indexed user, uint256 ethAmount)",
  "event Borrow(address indexed user, uint256 usdcAmount)",
  "event Repay(address indexed user, uint256 usdcAmount)",
  "event SupplyUSDC(address indexed user, uint256 usdcAmount, uint256 shares)",
  "event WithdrawUSDC(address indexed user, uint256 usdcAmount, uint256 shares)",
  "event Liquidate(address indexed liquidator, address indexed user, uint256 repayAmount, uint256 seizedCollateral)",
  "event Accrue(uint256 timestamp,uint256 utilizationBps,uint256 rateBps,uint256 interestAccruedWad,uint256 reserveAccruedWad,uint256 prevIndex,uint256 newIndex)",
  "function getUtilizationBps() view returns (uint256)",
  "function borrowIndex() view returns (uint256)",
  "function getBorrowRateBps() view returns (uint256)"
];

const oracleAbi = ["function getEthUsdPrice() view returns (uint256)"];

const pool = new Contract(addresses.pool, poolAbi, provider);
const oracle = new Contract(addresses.oracle, oracleAbi, provider);

function logEvent(name, args) {
  const ts = new Date().toISOString();
  console.log(`[${ts}] ${name}`, args);
}

pool.on("Deposit", (user, ethAmount) =>
  logEvent("Deposit", { user, ethAmount: ethAmount.toString() })
);
pool.on("Withdraw", (user, ethAmount) =>
  logEvent("Withdraw", { user, ethAmount: ethAmount.toString() })
);
pool.on("Borrow", (user, usdcAmount) =>
  logEvent("Borrow", { user, usdcAmount: usdcAmount.toString() })
);
pool.on("Repay", (user, usdcAmount) =>
  logEvent("Repay", { user, usdcAmount: usdcAmount.toString() })
);
pool.on("SupplyUSDC", (user, usdcAmount, shares) =>
  logEvent("SupplyUSDC", {
    user,
    usdcAmount: usdcAmount.toString(),
    shares: shares.toString()
  })
);
pool.on("WithdrawUSDC", (user, usdcAmount, shares) =>
  logEvent("WithdrawUSDC", {
    user,
    usdcAmount: usdcAmount.toString(),
    shares: shares.toString()
  })
);
pool.on("Liquidate", (liquidator, user, repayAmount, seizedCollateral) =>
  logEvent("Liquidate", {
    liquidator,
    user,
    repayAmount: repayAmount.toString(),
    seizedCollateral: seizedCollateral.toString()
  })
);
pool.on("Accrue", (timestamp, utilizationBps, rateBps) =>
  logEvent("Accrue", {
    timestamp: Number(timestamp),
    utilizationBps: utilizationBps.toString(),
    rateBps: rateBps.toString()
  })
);

async function pollMetrics() {
  const util = await pool.getUtilizationBps();
  const rate = await pool.getBorrowRateBps();
  const index = await pool.borrowIndex();
  const price = await oracle.getEthUsdPrice();

  const utilNum = Number(util);
  if (utilNum > 9000) {
    console.warn("[ALERT] Utilization > 90%:", utilNum);
  }

  console.log(
    "[METRICS]",
    JSON.stringify({
      utilizationBps: util.toString(),
      borrowRateBps: rate.toString(),
      borrowIndex: index.toString(),
      ethUsdPrice: price.toString()
    })
  );
}

setInterval(pollMetrics, 10_000);
pollMetrics().catch((err) => {
  console.error("Initial metrics error:", err);
  process.exit(1);
});
