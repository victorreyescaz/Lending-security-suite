// Tests del modelo de tasa con "kink": valida baseRate/slope1/slope2 segun utilizacion.
// Setup clave: ETH/USD=2000e8, LTV=75%, LT=80%, baseRate 2%, slope1 6%, slope2 40%, optimalUtil 80% y liquidez 1000 USDC.
// Variables: borrows 500 y luego 400 USDC para pasar el kink y comprobar getBorrowRateBps().
import { expect } from "chai";
import { ethers } from "hardhat";

describe("LendingPool - rate model (kink)", function () {
  async function deployFixture() {
    const [deployer, borrower] = await ethers.getSigners();

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

    const liquidity = 1_000n * 10n ** 6n;
    await usdc.mint(deployer.address, liquidity);
    await usdc.connect(deployer).approve(await pool.getAddress(), liquidity);
    await pool.connect(deployer).depositUSDC(liquidity);

    return { pool, borrower };
  }

  it("applies base rate below kink and slope2 above kink", async function () {
    const { pool, borrower } = await deployFixture();

    await pool.connect(borrower).depositETH({ value: ethers.parseEther("1") });

    // 50% utilization: borrow 500 out of 1000
    await pool.connect(borrower).borrowUSDC(500n * 10n ** 6n);
    expect(await pool.getUtilizationBps()).to.equal(5000n);
    expect(await pool.getBorrowRateBps()).to.equal(575n); // 200 + 600*(0.625)

    // 90% utilization: borrow 400 more (total 900, cash 100)
    await pool.connect(borrower).borrowUSDC(400n * 10n ** 6n);
    expect(await pool.getUtilizationBps()).to.equal(9000n);
    expect(await pool.getBorrowRateBps()).to.equal(2800n); // 200+600+4000*(0.5)
  });

  it("rate increases as interest accrues and utilization rises", async function () {
    const { pool, borrower } = await deployFixture();

    await pool.connect(borrower).depositETH({ value: ethers.parseEther("1") });

    // 60% utilization: borrow 600 out of 1000
    await pool.connect(borrower).borrowUSDC(600n * 10n ** 6n);
    const utilBefore = await pool.getUtilizationBps();
    const rateBefore = await pool.getBorrowRateBps();

    await ethers.provider.send("evm_increaseTime", [365 * 24 * 60 * 60]);
    await ethers.provider.send("evm_mine", []);
    await pool.accrue();

    const utilAfter = await pool.getUtilizationBps();
    const rateAfter = await pool.getBorrowRateBps();

    expect(utilAfter).to.be.greaterThan(utilBefore);
    expect(rateAfter).to.be.greaterThan(rateBefore);
  });
});
