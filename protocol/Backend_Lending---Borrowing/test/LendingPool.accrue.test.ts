// Tests de _accrue/interés: fixture con WETH9, MockUSDC, OracleMock (ETH/USD=2000e8) y pool LTV=75%, LIQ=80%, baseRate 10%, con liquidez aportada por lender.
// Flujo: usuario deposita 1 ETH, pide 1000 USDC, avanza 365d (evm_increaseTime + mine), luego llama accrue() para disparar _accrue.
// Expectativa: la deuda reportada por getUserDebtUSDC aumenta respecto al principal (interés simple/compuesto según implementación).


import { expect } from "chai";
import { ethers } from "hardhat";

describe("LendingPool - accrue interest", function () {
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
	      1000, // baseRateBps 10%
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
    return { pool, usdc, user };
  }

  it("debt increases after time passes", async () => {
    const { pool, user } = await deployFixture();

    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });

    const borrowAmount = 1000n * 10n ** 6n;
    await pool.connect(user).borrowUSDC(borrowAmount);

    const before = await pool.getUserDebtUSDC(user.address);
    expect(before).to.equal(borrowAmount);

    // + 365 days
    await ethers.provider.send("evm_increaseTime", [365 * 24 * 60 * 60]);
    await ethers.provider.send("evm_mine", []);

    // Trigger accrue via a no-op-like call (repay 1 or call a public accrue)
    // Si no tienes accrue() público, con getUserDebtUSDC NO cambia (view).
    // Recomendación MVP: añade function accrue() external { _accrue(); }
    await pool.accrue();

    const afterDebt = await pool.getUserDebtUSDC(user.address);
    expect(afterDebt).to.be.greaterThan(before);
  });
});
