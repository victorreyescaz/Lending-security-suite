// Tests admin: solo owner puede pausar y cambiar parametros; pause bloquea borrow/withdraw/liquidate pero permite deposit/repay.
// Setup clave: ETH/USD=2000e8, LTV=75%, LT=80%, baseRate 2%, slope1 6%, slope2 40% y liquidez inicial 1,000,000 USDC.
// Variables: se cambia el oraculo a un nuevo OracleMock para validar setOracle().
import { expect } from "chai";
import { ethers } from "hardhat";

describe("LendingPool - admin (pause + setters)", function () {
  async function deployFixture() {
    const [deployer, user, liquidator] = await ethers.getSigners();

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
      200, // baseRateBps
      600, // slope1Bps
      4000, // slope2Bps
      8000, // optimalUtilBps
      0 // reserveFactorBps
    );
    await pool.waitForDeployment();

    const liquidity = 1_000_000n * 10n ** 6n;
    await usdc.mint(deployer.address, liquidity);
    await usdc.connect(deployer).approve(await pool.getAddress(), liquidity);
    await pool.connect(deployer).depositUSDC(liquidity);

    return { pool, usdc, oracle, deployer, user, liquidator };
  }

  it("only owner can pause and update params", async function () {
    const { pool, oracle, user } = await deployFixture();

    await expect(pool.connect(user).pause())
      .to.be.revertedWithCustomError(pool, "OwnableUnauthorizedAccount")
      .withArgs(user.address);

    await expect(pool.connect(user).setRiskParams(7000, 8000))
      .to.be.revertedWithCustomError(pool, "OwnableUnauthorizedAccount")
      .withArgs(user.address);

    await pool.pause();
    expect(await pool.paused()).to.equal(true);
    await pool.unpause();
    expect(await pool.paused()).to.equal(false);

    await pool.setRiskParams(7000, 8200);
    expect(await pool.LTV_BPS()).to.equal(7000n);
    expect(await pool.LIQ_THRESHOLD_BPS()).to.equal(8200n);

    await pool.setRateModel(100, 500, 3000, 8500);
    expect(await pool.BASE_RATE_BPS()).to.equal(100n);
    expect(await pool.SLOPE1_BPS()).to.equal(500n);
    expect(await pool.SLOPE2_BPS()).to.equal(3000n);
    expect(await pool.OPTIMAL_UTIL_BPS()).to.equal(8500n);

    await pool.setReserveFactor(250);
    expect(await pool.RESERVE_FACTOR_BPS()).to.equal(250n);

    const OracleMock = await ethers.getContractFactory("OracleMock");
    const oracle2 = await OracleMock.deploy(2100n * 10n ** 8n);
    await oracle2.waitForDeployment();
    await pool.setOracle(await oracle2.getAddress());
    expect(await pool.ORACLE()).to.equal(await oracle2.getAddress());
  });

  it("pause blocks borrow/withdraw/liquidate but allows deposit/repay", async function () {
    const { pool, usdc, oracle, deployer, user, liquidator } =
      await deployFixture();

    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });
    await pool.connect(user).borrowUSDC(1000n * 10n ** 6n);

    await pool.connect(deployer).pause();

    await expect(pool.connect(user).borrowUSDC(1n * 10n ** 6n))
      .to.be.revertedWithCustomError(pool, "EnforcedPause");

    await expect(pool.connect(user).withdrawETH(ethers.parseEther("0.1")))
      .to.be.revertedWithCustomError(pool, "EnforcedPause");

    await pool.connect(user).depositETH({ value: ethers.parseEther("0.1") });

    await usdc.mint(user.address, 200n * 10n ** 6n);
    await usdc.connect(user).approve(await pool.getAddress(), 200n * 10n ** 6n);
    await pool.connect(user).depositUSDC(200n * 10n ** 6n);

    await usdc.connect(user).approve(await pool.getAddress(), 100n * 10n ** 6n);
    await expect(pool.connect(user).repayUSDC(100n * 10n ** 6n))
      .to.emit(pool, "Repay")
      .withArgs(user.address, 100n * 10n ** 6n);

    await expect(pool.connect(user).withdrawUSDC(1n * 10n ** 6n))
      .to.be.revertedWithCustomError(pool, "EnforcedPause");

    await oracle.setPrice(1500n * 10n ** 8n);
    await usdc.mint(liquidator.address, 500n * 10n ** 6n);
    await usdc
      .connect(liquidator)
      .approve(await pool.getAddress(), 500n * 10n ** 6n);

    await expect(
      pool.connect(liquidator).liquidate(user.address, 100n * 10n ** 6n)
    ).to.be.revertedWithCustomError(pool, "EnforcedPause");
  });
});
