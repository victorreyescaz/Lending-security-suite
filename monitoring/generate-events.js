/*
Simula la conexion de una wallet al pool desplegado y ejecuta acciones para emitir eventos.
Su objetivo es generar actividad on-chain para que el monitor muestre eventos y metricas.

- Usa una cuenta de Anvil y se conecta al pool
- Minta USDC para esa cuenta y aprueba el pool
- Ejecuta acciones como depositUSDC, depositETH, borrowUASC, repayUASC y accrue para emitir eventos y poder verlos en el monitor
*/

import { readFileSync } from "node:fs";
import {
  JsonRpcProvider,
  Wallet,
  Contract,
  parseEther,
  NonceManager
} from "ethers";

const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
const ADDR_PATH = process.env.ADDR_PATH || "./addresses.json";
const PRIVATE_KEY = process.env.PRIVATE_KEY;
if (!PRIVATE_KEY) {
  throw new Error(
    "PRIVATE_KEY no definido. Usa: PRIVATE_KEY=... node generate-events.js"
  );
}

const addresses = JSON.parse(readFileSync(ADDR_PATH, "utf-8"));
const provider = new JsonRpcProvider(RPC_URL);
const baseSigner = new Wallet(PRIVATE_KEY, provider);
const signer = new NonceManager(baseSigner);

const poolAbi = [
  "function depositETH() payable",
  "function borrowUSDC(uint256)",
  "function repayUSDC(uint256)",
  "function depositUSDC(uint256)",
  "function withdrawUSDC(uint256)",
  "function accrue()",
  "function getBorrowMax(address) view returns (uint256)"
];
const usdcAbi = [
  "function mint(address,uint256)",
  "function approve(address,uint256)",
  "function balanceOf(address) view returns (uint256)"
];

const pool = new Contract(addresses.pool, poolAbi, signer);
const usdc = new Contract(addresses.usdc, usdcAbi, signer);

async function main() {
  const addr = await signer.getAddress();
  const nonce = await provider.getTransactionCount(addr, "pending");
  console.log("Generating events with:", addr, "nonce:", nonce);

  // mint USDC for deposits/repay
  await (await usdc.mint(addr, 500_000e6)).wait();
  await (await usdc.approve(addresses.pool, BigInt(2) ** BigInt(256) - 1n)).wait();

  // deposit USDC (SupplyUSDC)
  await (await pool.depositUSDC(100_000e6)).wait();

  // deposit ETH (Deposit)
  await (await pool.depositETH({ value: parseEther("1") })).wait();

  // borrow (Borrow)
  const maxBorrow = await pool.getBorrowMax(addr);
  await (await pool.borrowUSDC(maxBorrow / 2n)).wait();

  // repay (Repay)
  await (await pool.repayUSDC(10_000e6)).wait();

  // accrue (Accrue)
  await (await pool.accrue()).wait();

  console.log("Events generated.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
