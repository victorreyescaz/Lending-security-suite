// Tests de depositETH: fixture despliega WETH9 y LendingPool con USDC/Oracle en ZeroAddress y params LTV=75%, LIQ=80%, APR=8%.
// Caso existoso: depositar 1 ETH emite Deposit, acredita collateralWETH al usuario, el pool guarda WETH y no retiene ETH nativo.
// Caso negativo: depositar 0 revierte con el error custom ZeroAmount.


import { expect } from "chai";
import { ethers } from "hardhat";

describe("LendingPool - depositETH", function () {
  async function deployFixture() {
    const [deployer, user] = await ethers.getSigners();

    // Deploy WETH
    const WETH = await ethers.getContractFactory("WETH9");
    const weth = await WETH.deploy();
    await weth.waitForDeployment();

    // Deploy LendingPool
	    const LendingPool = await ethers.getContractFactory("LendingPool");
	    const pool = (await LendingPool.deploy(
	      await weth.getAddress(),
	      ethers.ZeroAddress, // USDC not needed yet
	      ethers.ZeroAddress, // Oracle not needed yet
	      7500,
	      8000,
	      800, // baseRateBps
	      0, // slope1Bps
	      0, // slope2Bps
	      8000, // optimalUtilBps
	      0 // reserveFactorBps
	    )) as any;
    await pool.waitForDeployment();

    return { pool, weth, deployer, user };
  }

  it("wraps ETH into WETH and credits collateral", async function () {
    const { pool, weth, user } = await deployFixture();

    const amount = ethers.parseEther("1");

    await expect(
      pool.connect(user).depositETH({ value: amount })
    ).to.emit(pool, "Deposit").withArgs(user.address, amount);

    // User collateral updated
    expect(await pool.collateralWETH(user.address)).to.equal(amount);

    // Pool holds WETH
    expect(
      await weth.balanceOf(await pool.getAddress())
    ).to.equal(amount);

    // Pool holds no ETH
    expect(
      await ethers.provider.getBalance(await pool.getAddress())
    ).to.equal(0n);
  });

  it("reverts on zero amount", async function () {
    const { pool, user } = await deployFixture();

    await expect(
      pool.connect(user).depositETH({ value: 0 })
    ).to.be.revertedWithCustomError(pool, "ZeroAmount");
  });
});
