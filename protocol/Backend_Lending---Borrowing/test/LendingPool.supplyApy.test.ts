// Tests de supply USDC: depositos de lenders, retiro y reparto de interes desde borrowers.
// Setup clave: WETH9/MockUSDC/OracleMock con ETH/USD=2000e8 y pool LTV=75%, LT=80%, baseRate 10%.
// Variables: depositos en USDC (6 dec) y avance de 365 dias para generar interes.

import { expect } from "chai";
import { ethers } from "hardhat";

describe("LendingPool - USDC lenders", function () {
  async function deployFixture() {
    const [deployer, lender, borrower] = await ethers.getSigners();

    // Deploy WETH9
    const WETH = await ethers.getContractFactory("WETH9");
    const weth = await WETH.deploy();
    await weth.waitForDeployment();

    // Deploy Mock USDC (6 decimals)
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    // Deploy Oracle mock: ETH/USD = 2000e8
    const OracleMock = await ethers.getContractFactory("OracleMock");
    const oracle = await OracleMock.deploy(2000n * 10n ** 8n);
    await oracle.waitForDeployment();

    // Deploy pool: baseRate 10%, reserveFactor 0%
    const LendingPool = await ethers.getContractFactory("LendingPool");
    const pool = await LendingPool.deploy(
      await weth.getAddress(),
      await usdc.getAddress(),
      await oracle.getAddress(),
      7500, // LTV 75%
      8000, // LT 80%
      1000, // baseRateBps 10%
      0,    // slope1Bps
      0,    // slope2Bps
      8000, // optimalUtilBps
      0     // Reserve factor 0%
    );
    await pool.waitForDeployment();

    return { pool, usdc, oracle, weth, deployer, lender, borrower };
  }

  it("allows deposit and withdraw for lenders", async () => {
    const { pool, usdc, lender } = await deployFixture();

    const deposit = 5_000n * 10n ** 6n;
    await usdc.mint(lender.address, deposit);
    await usdc.connect(lender).approve(await pool.getAddress(), deposit);

    await pool.connect(lender).depositUSDC(deposit);
    expect(await pool.getUserSupplyUSDC(lender.address)).to.equal(deposit);

    const withdraw = 2_000n * 10n ** 6n;
    const before = await usdc.balanceOf(lender.address);
    await pool.connect(lender).withdrawUSDC(withdraw);
    const afterBal = await usdc.balanceOf(lender.address);

    expect(afterBal - before).to.equal(withdraw);
    expect(await pool.getUserSupplyUSDC(lender.address)).to.equal(
      deposit - withdraw
    );
  });

  it("lenders earn interest from borrowers", async () => {
    const { pool, usdc, lender, borrower } = await deployFixture();

    const deposit = 10_000n * 10n ** 6n;
    await usdc.mint(lender.address, deposit);
    await usdc.connect(lender).approve(await pool.getAddress(), deposit);
    await pool.connect(lender).depositUSDC(deposit);

    await pool.connect(borrower).depositETH({ value: ethers.parseEther("1") });

    const borrow = 1_000n * 10n ** 6n;
    await pool.connect(borrower).borrowUSDC(borrow);

    // Advance time by 365 days and accrue
    await ethers.provider.send("evm_increaseTime", [365 * 24 * 60 * 60]);
    await ethers.provider.send("evm_mine", []);
    await pool.accrue();

    const debt = await pool.getUserDebtUSDC(borrower.address);
    expect(debt).to.equal(1100n * 10n ** 6n);

    await usdc.mint(borrower.address, 200n * 10n ** 6n);
    await usdc.connect(borrower).approve(await pool.getAddress(), debt);
    await pool.connect(borrower).repayUSDC(debt);

    const supply = await pool.getUserSupplyUSDC(lender.address);
    expect(supply).to.equal(10_100n * 10n ** 6n);

    const before = await usdc.balanceOf(lender.address);
    await pool.connect(lender).withdrawUSDC(supply);
    const afterBal = await usdc.balanceOf(lender.address);

    expect(afterBal - before).to.equal(supply);
  });
});
