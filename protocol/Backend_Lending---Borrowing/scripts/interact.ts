// CLI de interaccion con LendingPool: lee despliegue desde deployments/<network>.json o env LENDING_POOL + WETH/USDC/ORACLE.
// Comandos: status | deposit <eth> | supply <usdc> | borrow <usdc> | repay <usdc> | withdraw <eth> | withdraw-usdc <usdc> | liquidate <user> <usdc> | accrue.
// Variables clave: LIQUIDATION_USER (si no pasas address) y montos en ETH/USDC (6 dec).
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

type Deployment = {
  weth: string;
  usdc: string;
  oracle: string;
  lendingPool: string;
};

function loadDeployment(): Deployment {
  const fromEnv = process.env.LENDING_POOL;
  if (fromEnv) {
    const weth = process.env.WETH;
    const usdc = process.env.USDC;
    const oracle = process.env.ORACLE;
    if (!weth || !usdc || !oracle) {
      throw new Error(
        "If LENDING_POOL is set, you must also set WETH, USDC and ORACLE"
      );
    }
    return { lendingPool: fromEnv, weth, usdc, oracle };
  }

  const filePath = path.join(process.cwd(), "deployments", `${network.name}.json`);
  const raw = fs.readFileSync(filePath, "utf8");
  const parsed = JSON.parse(raw) as Deployment;
  if (!parsed.lendingPool || !parsed.usdc || !parsed.weth || !parsed.oracle) {
    throw new Error(`Invalid deployment file: ${filePath}`);
  }
  return parsed;
}

function parseAmountArg(raw: string | undefined, kind: "eth" | "usdc"): bigint {
  if (!raw) throw new Error(`Missing amount argument (${kind})`);
  if (kind === "eth") return ethers.parseEther(raw);
  return ethers.parseUnits(raw, 6);
}

async function printStatus(poolAddr: string, userAddr: string) {
  const pool = await ethers.getContractAt("LendingPool", poolAddr);

  const collateral = await pool.collateralWETH(userAddr);
  const debt = await pool.getUserDebtUSDC(userAddr);
  const borrowMax = await pool.getBorrowMax(userAddr);
  const utilBps = await pool.getUtilizationBps();
  const rateBps = await pool.getBorrowRateBps();
  const supply = await pool.getUserSupplyUSDC(userAddr);
  const supplyShares = await pool.supplyShares(userAddr);

  let hf: bigint | null = null;
  try {
    hf = await pool.getHealthFactor(userAddr);
  } catch {
    hf = null;
  }

  console.log(`User: ${userAddr}`);
  console.log(`Collateral WETH: ${ethers.formatEther(collateral)}`);
  console.log(`Debt USDC: ${ethers.formatUnits(debt, 6)}`);
  console.log(`Borrow max USDC: ${ethers.formatUnits(borrowMax, 6)}`);
  console.log(`Utilization bps: ${utilBps.toString()}`);
  console.log(`Borrow rate bps: ${rateBps.toString()}`);
  console.log(`Supply USDC: ${ethers.formatUnits(supply, 6)}`);
  console.log(`Supply shares: ${supplyShares.toString()}`);
  if (hf === null) console.log("Health factor: (unavailable)");
  else console.log(`Health factor (wad): ${hf.toString()}`);
}

async function main() {
  const [user] = await ethers.getSigners();
  const deployment = loadDeployment();

  const action = (process.argv[2] ?? "status").toLowerCase();
  const amountArg = process.argv[3];

  const pool = await ethers.getContractAt("LendingPool", deployment.lendingPool);
  const usdc = await ethers.getContractAt("MockUSDC", deployment.usdc);

  console.log(`Network: ${network.name}`);
  console.log(`LendingPool: ${deployment.lendingPool}`);

  if (action === "status") {
    await printStatus(deployment.lendingPool, user.address);
    return;
  }

  if (action === "deposit") {
    const amount = parseAmountArg(amountArg, "eth");
    const tx = await pool.connect(user).depositETH({ value: amount });
    await tx.wait();
    await printStatus(deployment.lendingPool, user.address);
    return;
  }

  if (action === "supply") {
    const amount = parseAmountArg(amountArg, "usdc");
    await (await usdc.connect(user).approve(await pool.getAddress(), amount)).wait();
    const tx = await pool.connect(user).depositUSDC(amount);
    await tx.wait();
    await printStatus(deployment.lendingPool, user.address);
    return;
  }

  if (action === "borrow") {
    const amount = parseAmountArg(amountArg, "usdc");
    const tx = await pool.connect(user).borrowUSDC(amount);
    await tx.wait();
    await printStatus(deployment.lendingPool, user.address);
    return;
  }

  if (action === "repay") {
    const amount = parseAmountArg(amountArg, "usdc");
    await (await usdc.connect(user).approve(await pool.getAddress(), amount)).wait();
    const tx = await pool.connect(user).repayUSDC(amount);
    await tx.wait();
    await printStatus(deployment.lendingPool, user.address);
    return;
  }

  if (action === "liquidate") {
    const targetArg = process.argv[3];
    const amountRaw = process.argv[4];
    const hasTarget = targetArg && ethers.isAddress(targetArg);
    const target = hasTarget
      ? targetArg
      : process.env.LIQUIDATION_USER;
    const amountArgResolved = hasTarget ? amountRaw : targetArg;

    if (!target) {
      throw new Error(
        "Missing borrower address for liquidation. Use: liquidate <user> <usdc> or set LIQUIDATION_USER."
      );
    }

    const amount = parseAmountArg(amountArgResolved, "usdc");
    await (await usdc.connect(user).approve(await pool.getAddress(), amount)).wait();
    const tx = await pool.connect(user).liquidate(target, amount);
    await tx.wait();
    await printStatus(deployment.lendingPool, target);
    await printStatus(deployment.lendingPool, user.address);
    return;
  }

  if (action === "withdraw") {
    const amount = parseAmountArg(amountArg, "eth");
    const tx = await pool.connect(user).withdrawETH(amount);
    await tx.wait();
    await printStatus(deployment.lendingPool, user.address);
    return;
  }

  if (action === "withdraw-usdc") {
    const amount = parseAmountArg(amountArg, "usdc");
    const tx = await pool.connect(user).withdrawUSDC(amount);
    await tx.wait();
    await printStatus(deployment.lendingPool, user.address);
    return;
  }

  if (action === "accrue") {
    const tx = await pool.connect(user).accrue();
    await tx.wait();
    await printStatus(deployment.lendingPool, user.address);
    return;
  }

  throw new Error(
    `Unknown action: ${action}. Use: status | deposit <eth> | supply <usdc> | borrow <usdc> | repay <usdc> | withdraw <eth> | withdraw-usdc <usdc> | accrue`
  );
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1; 
});
