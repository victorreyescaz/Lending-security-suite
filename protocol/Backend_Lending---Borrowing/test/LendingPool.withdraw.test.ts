// Tests de withdrawETH: fixture con WETH9, MockUSDC, OracleMock (ETH/USD=2000e8) y pool LTV=75%, LIQ=80%, baseRate 8%, con liquidez aportada por lender.
// Caso sin deuda: retirar 0.4 de 1 ETH emite Withdraw y reduce collateralWETH y balance WETH del pool en igual monto.
// Caso HF: con 1500 USDC de deuda, retirar 0.1 ETH haría HF<1 y revierte con HealthFactorTooLow.
// Caso exceso: intentar retirar más WETH del que hay colateral revierte.


import { expect } from "chai";
import { ethers } from "hardhat";

describe("LendingPool - withdrawETH", function () {
  async function deployFixture() {
    const [deployer, user] = await ethers.getSigners();

    const WETH = await ethers.getContractFactory("WETH9");
    const weth = await WETH.deploy();
    await weth.waitForDeployment();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    const OracleMock = await ethers.getContractFactory("OracleMock");
    const oracle = await OracleMock.deploy(2000n * 10n ** 8n); // $2000
    await oracle.waitForDeployment();

    const LendingPool = await ethers.getContractFactory("LendingPool");
	    const pool = await LendingPool.deploy(
	      await weth.getAddress(),
	      await usdc.getAddress(),
	      await oracle.getAddress(),
	      7500,
	      8000, // LT 80%
	      800, // baseRateBps
	      0, // slope1Bps
	      0, // slope2Bps
	      8000, // optimalUtilBps
	      0 // reserveFactorBps
	    );
    await pool.waitForDeployment();

    // fund USDC liquidity via lender deposit
    const liquidity = 1_000_000n * 10n ** 6n;
    await usdc.mint(deployer.address, liquidity);
    await usdc.connect(deployer).approve(await pool.getAddress(), liquidity);
    await pool.connect(deployer).depositUSDC(liquidity);

    return { pool, weth, usdc, user };
  }

  it("allows withdraw when no debt", async () => {
    const { pool, weth, user } = await deployFixture();

    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });

    const withdrawAmount = ethers.parseEther("0.4");

    await expect(pool.connect(user).withdrawETH(withdrawAmount))
      .to.emit(pool, "Withdraw")
      .withArgs(user.address, withdrawAmount);

    expect(await pool.collateralWETH(user.address)).to.equal(
      ethers.parseEther("1") - withdrawAmount
    );

    // pool WETH balance reduced too
    expect(await weth.balanceOf(await pool.getAddress())).to.equal(
      ethers.parseEther("1") - withdrawAmount
    );
  });

  it("reverts if withdraw would make HF < 1", async () => {
    const { pool, user } = await deployFixture();

    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });

    // borrow 1500 USDC (max at LTV 75%), HF will be:
    // collateral $2000, LT 80% => adj = $1600; debt = $1500; HF=1.066...
    await pool.connect(user).borrowUSDC(1500n * 10n ** 6n);

    // If withdraw 0.1 ETH => collateral becomes 0.9 ETH => $1800; adj=$1440; HF=0.96 < 1 => revert
    const withdrawAmount = ethers.parseEther("0.1");

    await expect(pool.connect(user).withdrawETH(withdrawAmount))
      .to.be.revertedWithCustomError(pool, "HealthFactorTooLow");
  });

  it("reverts if withdrawing more than collateral", async () => {
    const { pool, user } = await deployFixture();

    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });

    await expect(pool.connect(user).withdrawETH(ethers.parseEther("2")))
      .to.be.reverted; // puedes refinar a custom error si quieres
  });
});
