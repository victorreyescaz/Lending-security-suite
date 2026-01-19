// Tests de borrowUSDC: usa fixture con WETH9/MockUSDC/OracleMock (ETH/USD=2000e8) y pool LTV=75%, LIQ=80%, baseRate 8%.
// Caso exitoso: usuario deposita 1 ETH, puede pedir hasta 1500 USDC y se emite Borrow, balance actualizado.
// Caso negativo: pedir >LTV revierte con HealthFactorTooLow.

import { expect } from "chai";
import { ethers } from "hardhat";

async function deployFixture() {
  const [deployer, user] = await ethers.getSigners();

  const WETH = await ethers.getContractFactory("WETH9");
  const weth = await WETH.deploy();
  await weth.waitForDeployment();

  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const usdc = await MockUSDC.deploy();
  await usdc.waitForDeployment();

  const OracleMock = await ethers.getContractFactory("OracleMock");
  const oracle = await OracleMock.deploy(2000n * 10n ** 8n);
  await oracle.waitForDeployment();

  const LendingPool = await ethers.getContractFactory("LendingPool");
  const pool = await LendingPool.deploy(
    await weth.getAddress(),
    await usdc.getAddress(),
    await oracle.getAddress(),
    7500,
    8000,
    800, // baseRateBps
    0, // slope1Bps
    0, // slope2Bps
    8000, // optimalUtilBps
    0 // reserveFactorBps
  );
  await pool.waitForDeployment();

  const liquidity = 1_000_000n * 10n ** 6n;
  await usdc.mint(deployer.address, liquidity);
  await usdc.connect(deployer).approve(await pool.getAddress(), liquidity);
  await pool.connect(deployer).depositUSDC(liquidity);

  return { pool, weth, usdc, oracle, deployer, user };
}

describe("LendingPool - borrowUSDC", function () {
  it("borrows within LTV after depositing ETH", async function () {
    const { pool, usdc, user } = await deployFixture();

    // deposit 1 ETH -> collateral value = $2000
    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });

    // LTV 75% => max borrow = $1500 => 1500 USDC
    const borrowAmount = 1500n * 10n ** 6n;

    await expect(pool.connect(user).borrowUSDC(borrowAmount))
      .to.emit(pool, "Borrow")
      .withArgs(user.address, borrowAmount);

    expect(await usdc.balanceOf(user.address)).to.equal(borrowAmount);
  });

  it("reverts if borrowing above max (LTV)", async function () {
    const { pool, user } = await deployFixture();

    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });

    const tooMuch = 1500n * 10n ** 6n + 1n;

    await expect(pool.connect(user).borrowUSDC(tooMuch))
      .to.be.revertedWithCustomError(pool, "HealthFactorTooLow");
  });
});
