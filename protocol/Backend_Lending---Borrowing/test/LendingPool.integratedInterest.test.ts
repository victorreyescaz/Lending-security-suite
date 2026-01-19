// Test integrado de interés y salud: recorre el ciclo completo deposit → borrow → pasa el tiempo → accrue → restricciones por HF → repay → volver a operar.
// Setup: ETH/USD=2000e8, LTV=75%, LT=80%, baseRate 10% para que en 365 días la deuda suba exacto 1.1x (1500 → 1650 USDC).
// Verifica: tras accrue la deuda aumenta, HF cae por debajo de 1 y withdraw/borrow revierten; al repagar 200 USDC HF vuelve >1 y permite un withdraw pequeño.


import { expect } from "chai";
import { ethers } from "hardhat";

describe("LendingPool - integrated (interest + borrow + withdraw + repay)", function () {
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

    // baseRate 10% => 1000 bps (para que en 365d sea exacto 1.1x)
    const LendingPool = await ethers.getContractFactory("LendingPool");
	    const pool = await LendingPool.deploy(
	      await weth.getAddress(),
	      await usdc.getAddress(),
	      await oracle.getAddress(),
	      7500, // LTV 75%
	      8000, // LT 80%
	      1000, // baseRateBps 10%
	      0, // slope1Bps
	      0, // slope2Bps
	      8000, // optimalUtilBps
	      0 // reserveFactorBps
	    );
    await pool.waitForDeployment();

    // Liquidez del pool via lender deposit
    const liquidity = 1_000_000n * 10n ** 6n;
    await usdc.mint(deployer.address, liquidity);
    await usdc.connect(deployer).approve(await pool.getAddress(), liquidity);
    await pool.connect(deployer).depositUSDC(liquidity);

    return { pool, usdc, user };
  }

  it("after time passes: debt increases, HF drops, withdraw/borrow can revert; repay restores actions", async () => {
    const { pool, usdc, user } = await deployFixture();

    // 1) Deposit 1 ETH => $2000 collateral
    await pool.connect(user).depositETH({ value: ethers.parseEther("1") });

    // 2) Borrow 1500 USDC (max LTV = 75% de 2000 => 1500)
    const borrow1500 = 1500n * 10n ** 6n;
    await pool.connect(user).borrowUSDC(borrow1500);

    // debt inicial
    expect(await pool.getUserDebtUSDC(user.address)).to.equal(borrow1500);

    // HF inicial: (2000*0.8)/1500 = 1.066666... => > 1
    const hfBefore = await pool.getHealthFactor(user.address);
    expect(hfBefore).to.be.greaterThan(10n ** 18n);

    // 3) Avanza 365 días y fuerza accrue
    await ethers.provider.send("evm_increaseTime", [365 * 24 * 60 * 60]);
    await ethers.provider.send("evm_mine", []);
    await pool.accrue();

    // 4) La deuda sube 10% exacto: 1500 -> 1650 USDC
    const debtAfter = await pool.getUserDebtUSDC(user.address);
    const expected1650 = 1650n * 10n ** 6n;
    expect(debtAfter).to.equal(expected1650);

    // HF cae: adj collateral = 2000*0.8=1600; 1600/1650 < 1
    const hfAfter = await pool.getHealthFactor(user.address);
    expect(hfAfter).to.be.lessThan(10n ** 18n);

    // 5) Withdraw ahora debería revertir (cualquier withdraw baja aún más el colateral)
    await expect(pool.connect(user).withdrawETH(ethers.parseEther("0.01")))
      .to.be.revertedWithCustomError(pool, "HealthFactorTooLow");

    // 6) Borrow adicional también debería revertir (ya estás por debajo de 1)
    await expect(pool.connect(user).borrowUSDC(1n * 10n ** 6n))
      .to.be.revertedWithCustomError(pool, "HealthFactorTooLow");

    // 7) Repay 200 USDC => deuda 1650 -> 1450
    const repay200 = 200n * 10n ** 6n;

    // el user tiene 1500 USDC del borrow, así que puede aprobar y pagar
    await usdc.connect(user).approve(await pool.getAddress(), repay200);
    await pool.connect(user).repayUSDC(repay200);

    const expected1450 = 1450n * 10n ** 6n;
    expect(await pool.getUserDebtUSDC(user.address)).to.equal(expected1450);

    // HF vuelve a > 1: 1600/1450 = 1.103...
    const hfAfterRepay = await pool.getHealthFactor(user.address);
    expect(hfAfterRepay).to.be.greaterThan(10n ** 18n);

    // 8) Withdraw pequeño ahora sí debería ser posible.
    // Si retiras 0.05 ETH: colateral 0.95 => $1900; adj=1520; 1520/1450 > 1
    const withdraw005 = ethers.parseEther("0.05");
    await expect(pool.connect(user).withdrawETH(withdraw005))
      .to.emit(pool, "Withdraw")
      .withArgs(user.address, withdraw005);
  });
});
