// Test de “oracle shock”: simula una caída brusca del precio ETH/USD y verifica cómo impacta en la Health Factor y en las acciones permitidas.
// Setup determinista: baseRate=0 para aislar el efecto del precio (sin intereses), LTV=75%, LT=80%, oráculo mockeado.
// Flujo: deposit 1 ETH @ $2000 + borrow 1500 USDC ⇒ HF>1; baja precio a $1500 ⇒ HF<1 y withdraw/borrow deben revertir.
// Recuperación: repay 300 USDC para volver a HF>=1, luego ligera subida de precio ($1510) para permitir un withdraw pequeño.


import { expect } from "chai";
import { ethers } from "hardhat";

describe("LendingPool - oracle shock (price drop)", function () {
  async function deployFixture() {
    const [deployer, user] = await ethers.getSigners();

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
	      7500, // LTV 75%
	      8000, // LT 80%
	      0, // baseRateBps 0 para aislar efecto precio
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

    return { pool, usdc, oracle, user };
  }

  it("price drop reduces HF and blocks withdraw/borrow; repay restores", async () => {
    const { pool, usdc, oracle, user } = await deployFixture();

    // 1) Deposit 1 ETH @ $2000 => collateral $2000
    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });

    // 2) Borrow max LTV: 1500 USDC
    const borrow1500 = 1500n * 10n ** 6n;
    await pool.connect(user).borrowUSDC(borrow1500);

    // HF inicial > 1: adj=2000*0.8=1600; 1600/1500=1.066...
    const hfBefore = await pool.getHealthFactor(user.address);
    expect(hfBefore).to.be.greaterThan(10n ** 18n);

    // 3) Price drops to $1500
    // New adj collateral = 1500*0.8=1200; debt=1500 => HF=0.8 < 1
    await oracle.setPrice(1500n * 10n ** 8n);

    const hfAfter = await pool.getHealthFactor(user.address);
    expect(hfAfter).to.be.lessThan(10n ** 18n);

    // 4) withdraw should revert
    await expect(pool.connect(user).withdrawETH(ethers.parseEther("0.01")))
      .to.be.revertedWithCustomError(pool, "HealthFactorTooLow");

    // 5) borrow more should revert
    await expect(pool.connect(user).borrowUSDC(1n * 10n ** 6n))
      .to.be.revertedWithCustomError(pool, "HealthFactorTooLow");

    // 6) repay some to restore HF
    // Need debt <= adjCollateral = 1200 => repay 300 USDC (1500 -> 1200)
    const repay300 = 300n * 10n ** 6n;
    await usdc.connect(user).approve(await pool.getAddress(), repay300);
    await pool.connect(user).repayUSDC(repay300);

    // HF should be >= 1 now (actually ==1)
    const hfAfterRepay = await pool.getHealthFactor(user.address);
    expect(hfAfterRepay).to.be.greaterThanOrEqual(10n ** 18n);

    // 7) withdraw tiny amount would now likely fail if HF is exactly 1 (because it would go below 1).
    // So instead: just check we can borrow 0 (no), or better: raise price slightly and withdraw.
    await oracle.setPrice(1510n * 10n ** 8n); // small recovery

    await expect(pool.connect(user).withdrawETH(ethers.parseEther("0.001")))
      .to.emit(pool, "Withdraw");
  });
});
