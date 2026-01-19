// Tests de repayUSDC: fixture despliega WETH9, MockUSDC, OracleMock (ETH/USD=2000e8) y pool con LTV=75%, LIQ=80%, baseRate 8%, con liquidez aportada por lender.
// Caso parcial: usuario deposita 1 ETH, pide 1000 USDC, aprueba 400 y al repagar emite Repay, su saldo queda en 600 y la deuda baja en 400 (usa getUserDebtUSDC).
// Caso total: tras pedir 500 USDC, repaga todo y la deuda queda en 0 sin irse a negativo.


import { expect } from "chai";
import { ethers } from "hardhat";

describe("LendingPool - repayUSDC", function () {
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

    // Fund pool liquidity via lender deposit
    const liquidity = 1_000_000n * 10n ** 6n;
    await usdc.mint(deployer.address, liquidity);
    await usdc.connect(deployer).approve(await pool.getAddress(), liquidity);
    await pool.connect(deployer).depositUSDC(liquidity);

    return { pool, usdc, user };
  }

  it("repays partially and reduces debt", async function () {
    const { pool, usdc, user } = await deployFixture();

    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });

    const borrowAmount = 1000n * 10n ** 6n;
    await pool.connect(user).borrowUSDC(borrowAmount);

    const repayAmount = 400n * 10n ** 6n;

    // approve repay
    await usdc.connect(user).approve(await pool.getAddress(), repayAmount);

    await expect(pool.connect(user).repayUSDC(repayAmount))
      .to.emit(pool, "Repay")
      .withArgs(user.address, repayAmount);

    // User should keep (borrow - repay)
    expect(await usdc.balanceOf(user.address)).to.equal(borrowAmount - repayAmount);

    // Debt should be borrow - repay (since accrue is empty for now)
    const debtAfter = await pool.getUserDebtUSDC(user.address); // we'll add this view helper
    expect(debtAfter).to.equal(borrowAmount - repayAmount);
  });

  it("repays full debt and sets it to zero (no negative)", async function () {
    const { pool, usdc, user } = await deployFixture();

    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });

    const borrowAmount = 500n * 10n ** 6n;
    await pool.connect(user).borrowUSDC(borrowAmount);

    await usdc.connect(user).approve(await pool.getAddress(), borrowAmount);

    await pool.connect(user).repayUSDC(borrowAmount);

    expect(await pool.getUserDebtUSDC(user.address)).to.equal(0n);
  });
});
