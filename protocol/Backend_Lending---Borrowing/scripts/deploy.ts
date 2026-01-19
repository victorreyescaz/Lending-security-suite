// Despliega WETH9, MockUSDC y LendingPool; en sepolia usa Oracle con feed ETH/USD y en local usa OracleMock a 2000e8.
// Variables clave: LTV_BPS, LIQ_THRESHOLD_BPS, BASE_RATE_BPS, SLOPE1_BPS, SLOPE2_BPS, OPTIMAL_UTIL_BPS, RESERVE_FACTOR_BPS y POOL_LIQUIDITY_USDC.
// En sepolia requiere ETH_USD_FEED (opcional), ORACLE_STALE_AFTER, SEPOLIA_RPC_URL y DEPLOYER_PRIVATE_KEY.

import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

type Deployment = {
  network: string;
  chainId: number;
  deployer: string;
  weth: string;
  usdc: string;
  oracle: string;
  lendingPool: string;
};

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var ${name}`);
  return value;
}

function parseBps(name: string, defaultValue: number): number {
  const raw = process.env[name];
  if (!raw) return defaultValue;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 10_000) {
    throw new Error(`${name} must be an integer between 0 and 10000`);
  }
  return parsed;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);

  const LTV_BPS = parseBps("LTV_BPS", 7500);
  const LIQ_THRESHOLD_BPS = parseBps("LIQ_THRESHOLD_BPS", 8000);
  const BASE_RATE_BPS = parseBps("BASE_RATE_BPS", 200);
  const SLOPE1_BPS = parseBps("SLOPE1_BPS", 600);
  const SLOPE2_BPS = parseBps("SLOPE2_BPS", 4000);
  const OPTIMAL_UTIL_BPS = parseBps("OPTIMAL_UTIL_BPS", 8000);
  const RESERVE_FACTOR_BPS = parseBps("RESERVE_FACTOR_BPS", 0);

  const initialPoolLiquidityUsdc =
    process.env.POOL_LIQUIDITY_USDC ?? "1000000"; // 1,000,000

  console.log(`Network: ${network.name} (chainId=${chainId})`);
  console.log(`Deployer: ${deployer.address}`);

  const WETH = await ethers.getContractFactory("WETH9");
  const weth = await WETH.deploy();
  await weth.waitForDeployment();

  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const usdc = await MockUSDC.deploy();
  await usdc.waitForDeployment();

  let oracleAddress: string;
  if (network.name === "sepolia") {
    const feed =
      process.env.ETH_USD_FEED ??
      "0x694AA1769357215DE4FAC081bf1f309aDC325306"; // Sepolia ETH/USD
    const staleAfter = Number(process.env.ORACLE_STALE_AFTER ?? "3600"); // 1h
    if (!process.env.SEPOLIA_RPC_URL) requireEnv("SEPOLIA_RPC_URL");
    if (!process.env.DEPLOYER_PRIVATE_KEY) requireEnv("DEPLOYER_PRIVATE_KEY");

    const Oracle = await ethers.getContractFactory("Oracle");
    const oracle = await Oracle.deploy(feed, staleAfter);
    await oracle.waitForDeployment();
    oracleAddress = await oracle.getAddress();
  } else {
    const OracleMock = await ethers.getContractFactory("OracleMock");
    const oracle = await OracleMock.deploy(2000n * 10n ** 8n);
    await oracle.waitForDeployment();
    oracleAddress = await oracle.getAddress();
  }

  const LendingPool = await ethers.getContractFactory("LendingPool");
  const pool = await LendingPool.deploy(
    await weth.getAddress(),
    await usdc.getAddress(),
    oracleAddress,
    LTV_BPS,
    LIQ_THRESHOLD_BPS,
    BASE_RATE_BPS,
    SLOPE1_BPS,
    SLOPE2_BPS,
    OPTIMAL_UTIL_BPS,
    RESERVE_FACTOR_BPS
  );
  await pool.waitForDeployment();

  const liquidity = ethers.parseUnits(initialPoolLiquidityUsdc, 6);
  if (liquidity > 0n) {
    await usdc.mint(deployer.address, liquidity);
    await usdc.approve(await pool.getAddress(), liquidity);
    await pool.depositUSDC(liquidity);
  }

  const deployment: Deployment = {
    network: network.name,
    chainId,
    deployer: deployer.address,
    weth: await weth.getAddress(),
    usdc: await usdc.getAddress(),
    oracle: oracleAddress,
    lendingPool: await pool.getAddress(),
  };

  console.log("Deployed:");
  console.log(deployment);

  const outDir = path.join(process.cwd(), "deployments");
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, `${network.name}.json`);
  fs.writeFileSync(outPath, JSON.stringify(deployment, null, 2));
  console.log(`Saved to ${outPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
