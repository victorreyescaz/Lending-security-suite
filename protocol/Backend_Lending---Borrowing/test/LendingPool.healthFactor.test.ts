// Tests de getHealthFactor: fixture con WETH9, MockUSDC, OracleMock (ETH/USD=2000e8) y pool LTV=75%, LIQ=80%, baseRate 8%, con liquidez aportada por lender.
// Caso sin deuda: tras depositar 1 ETH, HF es max uint256 (infinito práctico).
// Caso simple: con 1 ETH de colateral ($2000) y 1000 USDC de deuda, HF esperado = (2000 * 0.8) / 1000 = 1.6e18 (wad).


import { expect } from "chai";
import { ethers } from "hardhat";

describe("LendingPool - health factor", function () {
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

    const liquidity = 1_000_000n * 10n ** 6n;
    await usdc.mint(deployer.address, liquidity);
    await usdc.connect(deployer).approve(await pool.getAddress(), liquidity);
    await pool.connect(deployer).depositUSDC(liquidity);
    return { pool, usdc, user };
  }

  it("HF is max when no debt", async () => {
    const { pool, user } = await deployFixture();

    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });

    const hf = await pool.getHealthFactor(user.address);
    expect(hf).to.equal((2n ** 256n) - 1n);
  });

  it("HF matches LT / debt ratio (simple case)", async () => {
    const { pool, user } = await deployFixture();

    // 1 ETH => $2000 collateral
    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });

    // borrow 1000 USDC => debt $1000
    const borrowAmount = 1000n * 10n ** 6n;
    await pool.connect(user).borrowUSDC(borrowAmount);

    // HF = (2000 * 0.8) / 1000 = 1.6
    // We represent HF in wad => 1.6e18
    const hf = await pool.getHealthFactor(user.address);
    expect(hf).to.equal(1600000000000000000n);
  });
});
