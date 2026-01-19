// Tests de liquidación: cuando HF < 1, un liquidator puede repagar parte de la deuda
// (close factor 50%) y recibir colateral con bonus (5%). Se valida el ajuste de deuda,
// colateral y la transferencia de WETH al liquidator.

import { expect } from "chai";
import { ethers } from "hardhat";

describe("LendingPool - liquidation", function () {
  async function deployFixture() {
    const [deployer, borrower, liquidator] = await ethers.getSigners();

    const WETH = await ethers.getContractFactory("WETH9");
    const weth = await WETH.deploy();
    await weth.waitForDeployment();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    const OracleMock = await ethers.getContractFactory("OracleMock");
    const oracle = await OracleMock.deploy(2000n * 10n ** 8n); // ETH = $2000
    await oracle.waitForDeployment();

    const LendingPool = await ethers.getContractFactory("LendingPool");
    const pool = await LendingPool.deploy(
      await weth.getAddress(),
      await usdc.getAddress(),
      await oracle.getAddress(),
      7500,
      8000,
      0, // baseRateBps 0 para aislar liquidación
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

    return { pool, usdc, oracle, weth, borrower, liquidator };
  }

  it("allows liquidation when HF < 1 and seizes collateral with bonus", async () => {
    const { pool, usdc, oracle, weth, borrower, liquidator } =
      await deployFixture();

    // Borrower deposits 1 ETH and borrows 1500 USDC (max LTV at $2000)
    await pool.connect(borrower).depositETH({ value: ethers.parseEther("1") });
    await pool.connect(borrower).borrowUSDC(1500n * 10n ** 6n);

    // Price drops to $1500 -> HF < 1
    await oracle.setPrice(1500n * 10n ** 8n);

    // Liquidator mints USDC and approves
    await usdc.mint(liquidator.address, 1_000n * 10n ** 6n);
    await usdc
      .connect(liquidator)
      .approve(await pool.getAddress(), 1_000n * 10n ** 6n);

    const repayRequested = 800n * 10n ** 6n;
    const debt = 1500n * 10n ** 6n;
    const bps = 10_000n;
    const closeFactor = await pool.CLOSE_FACTOR_BPS();
    const liqBonus = await pool.LIQ_BONUS_BPS();

    const maxClose = (debt * closeFactor) / bps;
    const repayActual = repayRequested > maxClose ? maxClose : repayRequested;

    const price = 1500n * 10n ** 8n;
    const repayWad = repayActual * 10n ** 12n;
    const seizeUsdWad = (repayWad * (bps + liqBonus)) / bps;
    const seizeEth = (seizeUsdWad * 10n ** 8n) / price;

    await expect(pool.connect(liquidator).liquidate(borrower.address, repayRequested))
      .to.emit(pool, "Liquidate")
      .withArgs(liquidator.address, borrower.address, repayActual, seizeEth);

    const remainingDebt = await pool.getUserDebtUSDC(borrower.address);
    expect(remainingDebt).to.equal(debt - repayActual);

    const remainingColl = await pool.collateralWETH(borrower.address);
    expect(remainingColl).to.equal(ethers.parseEther("1") - seizeEth);

    const liqWeth = await weth.balanceOf(liquidator.address);
    expect(liqWeth).to.equal(seizeEth);
  });

  it("reverts when HF >= 1", async () => {
    const { pool, borrower, liquidator } = await deployFixture();

    await pool.connect(borrower).depositETH({ value: ethers.parseEther("1") });
    await pool.connect(borrower).borrowUSDC(1000n * 10n ** 6n);

    await expect(
      pool.connect(liquidator).liquidate(borrower.address, 100n * 10n ** 6n)
    ).to.be.revertedWithCustomError(pool, "NotLiquidatable");
  });

  it("allows multiple liquidations until HF is restored", async () => {
    const { pool, usdc, oracle, borrower, liquidator } = await deployFixture();

    await pool.connect(borrower).depositETH({ value: ethers.parseEther("1") });
    await pool.connect(borrower).borrowUSDC(1500n * 10n ** 6n);

    await oracle.setPrice(1700n * 10n ** 8n);

    await usdc.mint(liquidator.address, 2_000n * 10n ** 6n);
    await usdc
      .connect(liquidator)
      .approve(await pool.getAddress(), 2_000n * 10n ** 6n);

    await pool.connect(liquidator).liquidate(borrower.address, 800n * 10n ** 6n);

    const hfAfterFirst = await pool.getHealthFactor(borrower.address);
    expect(hfAfterFirst).to.be.lessThan(10n ** 18n);

    await pool.connect(liquidator).liquidate(borrower.address, 800n * 10n ** 6n);

    const hfAfterSecond = await pool.getHealthFactor(borrower.address);
    expect(hfAfterSecond).to.be.greaterThanOrEqual(10n ** 18n);

    await expect(
      pool.connect(liquidator).liquidate(borrower.address, 1n * 10n ** 6n)
    ).to.be.revertedWithCustomError(pool, "NotLiquidatable");
  });

  it("reverts on dust liquidation amounts", async () => {
    const { pool, usdc, oracle, borrower, liquidator } = await deployFixture();

    await pool.connect(borrower).depositETH({ value: ethers.parseEther("1") });
    await pool.connect(borrower).borrowUSDC(1500n * 10n ** 6n);

    await oracle.setPrice(1500n * 10n ** 8n);

    const min = await pool.MIN_LIQUIDATION_USDC();
    const dust = min - 1n;

    await usdc.mint(liquidator.address, min);
    await usdc
      .connect(liquidator)
      .approve(await pool.getAddress(), min);

    await expect(
      pool.connect(liquidator).liquidate(borrower.address, dust)
    ).to.be.revertedWithCustomError(pool, "DustAmount");
  });
});
