// Tests de getUserAccountData: valida el “snapshot” de cuenta del usuario (collUsd, debtUsd, borrowMax, hf) usando ETH/USD=2000e8 y liquidez de lender.
// Sin deuda: tras depositar 1 ETH, collateral = 2000e18, debt = 0, borrowMax = 1500e6 (LTV 75%) y hf = uint256 max.
// Con deuda: tras pedir 1000 USDC, debt = 1000e18, borrowMax no cambia (sigue 1500e6) y hf = (2000*0.8)/1000 = 1.6e18.


import { expect } from "chai";
import { ethers } from "hardhat";

describe("LendingPool - getUserAccountData", function () {
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

    return { pool, usdc, user };
  }

  it("returns correct values when no debt", async () => {
    const { pool, user } = await deployFixture();

    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });

    const [collUsd, debtUsd, borrowMax, hf] = await pool.getUserAccountData(user.address);

    // collateral = 1 ETH * $2000 => 2000e18
    expect(collUsd).to.equal(2000n * 10n ** 18n);
    expect(debtUsd).to.equal(0n);

    // borrowMax = 75% of $2000 => $1500 => 1500e6 USDC
    expect(borrowMax).to.equal(1500n * 10n ** 6n);

    // no debt => hf = max
    expect(hf).to.equal((2n ** 256n) - 1n);
  });

  it("returns correct values with debt", async () => {
    const { pool, user } = await deployFixture();

    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });
    await pool.connect(user).borrowUSDC(1000n * 10n ** 6n);

    const [collUsd, debtUsd, borrowMax, hf] = await pool.getUserAccountData(user.address);

    expect(collUsd).to.equal(2000n * 10n ** 18n);

    // debt $1000 => 1000e18
    expect(debtUsd).to.equal(1000n * 10n ** 18n);

    // borrowMax sigue siendo 1500 USDC mientras el colateral y precio no cambien
    expect(borrowMax).to.equal(1500n * 10n ** 6n);

    // HF = (2000*0.8)/1000 = 1.6 => 1.6e18
    expect(hf).to.equal(1600000000000000000n);
  });
});
