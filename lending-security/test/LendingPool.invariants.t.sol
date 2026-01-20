// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract LendingPoolHandler is Test {
    LendingPool public pool;
    WETH9 public weth;
    MockUSDC public usdc;
    OracleMock public oracle;

    address[] public actors;

    constructor(
        LendingPool pool_,
        WETH9 weth_,
        MockUSDC usdc_,
        OracleMock oracle_,
        address[] memory actors_
    ) {
        pool = pool_;
        weth = weth_;
        usdc = usdc_;
        oracle = oracle_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _healthFactorWithCollateral(
        address actor,
        uint256 ethCollateral
    ) internal view returns (uint256) {
        uint256 debtUsdc = pool.getUserDebtUSDC(actor);
        if (debtUsdc == 0) return type(uint256).max;
        uint256 ethUsd = oracle.getEthUsdPrice();
        uint256 collateralUsdWad = (ethCollateral * ethUsd) / 1e8;
        uint256 adjCollateralWad = (collateralUsdWad *
            pool.LIQ_THRESHOLD_BPS()) / pool.BPS();
        uint256 debtUsdWad = debtUsdc * 1e12;
        return (adjCollateralWad * 1e18) / debtUsdWad;
    }

    function depositETH(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 value = bound(amount, 1, 10 ether);
        vm.deal(actor, value);
        vm.prank(actor);
        pool.depositETH{value: value}();
    }

    function withdrawETH(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 collateral = pool.collateralWETH(actor);
        if (collateral == 0) return;
        uint256 value = bound(amount, 1, collateral);
        if (pool.getUserDebtUSDC(actor) != 0) {
            uint256 newCol = collateral - value;
            if (_healthFactorWithCollateral(actor, newCol) < 1e18) return;
        }
        vm.prank(actor);
        pool.withdrawETH(value);
    }

    function depositUSDC(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 value = bound(amount, 1e6, 100_000e6);
        usdc.mint(actor, value);
        vm.startPrank(actor);
        usdc.approve(address(pool), value);
        pool.depositUSDC(value);
        vm.stopPrank();
    }

    function withdrawUSDC(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 maxWithdraw = pool.getUserSupplyUSDC(actor);
        if (maxWithdraw == 0) return;
        uint256 available = usdc.balanceOf(address(pool));
        if (available == 0) return;
        uint256 value = bound(amount, 1, maxWithdraw);
        if (value > available) value = available;
        if (value == 0) return;
        vm.prank(actor);
        pool.withdrawUSDC(value);
    }

    function borrowUSDC(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 maxBorrow = pool.getBorrowMax(actor);
        uint256 debt = pool.getUserDebtUSDC(actor);
        if (maxBorrow <= debt) return;
        uint256 available = usdc.balanceOf(address(pool));
        if (available == 0) return;
        uint256 room = maxBorrow - debt;
        uint256 value = bound(amount, 1, room);
        if (value > available) value = available;
        if (value == 0) return;
        vm.prank(actor);
        pool.borrowUSDC(value);
    }

    function repayUSDC(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 debt = pool.getUserDebtUSDC(actor);
        if (debt == 0) return;
        uint256 value = bound(amount, 1, debt);
        usdc.mint(actor, value);
        vm.startPrank(actor);
        usdc.approve(address(pool), value);
        pool.repayUSDC(value);
        vm.stopPrank();
    }

    function liquidate(
        uint256 liquidatorSeed,
        uint256 targetSeed,
        uint256 repayAmount
    ) external {
        address user = _actor(targetSeed);
        address liquidator = _actor(liquidatorSeed);
        if (user == liquidator && actors.length > 1) {
            liquidator = _actor(liquidatorSeed + 1);
        }

        uint256 debt = pool.getUserDebtUSDC(user);
        if (debt == 0) return;
        if (pool.getHealthFactor(user) >= 1e18) return;

        uint256 collateral = pool.collateralWETH(user);
        if (collateral == 0) return;

        uint256 maxClose = (debt * pool.CLOSE_FACTOR_BPS()) / pool.BPS();
        if (maxClose < pool.MIN_LIQUIDATION_USDC()) return;

        uint256 repay = bound(
            repayAmount,
            pool.MIN_LIQUIDATION_USDC(),
            maxClose
        );

        uint256 ethUsd = oracle.getEthUsdPrice();
        uint256 collateralUsdWad = (collateral * ethUsd) / 1e8;
        uint256 maxRepayUsdWad = (collateralUsdWad * pool.BPS()) /
            (pool.BPS() + pool.LIQ_BONUS_BPS());
        uint256 maxRepayUsdc = maxRepayUsdWad / 1e12;
        if (maxRepayUsdc < pool.MIN_LIQUIDATION_USDC()) return;
        if (repay > maxRepayUsdc) repay = maxRepayUsdc;
        if (repay < pool.MIN_LIQUIDATION_USDC()) return;

        uint256 seizeUsdWad = (repay * 1e12 * (pool.BPS() + pool.LIQ_BONUS_BPS())) /
            pool.BPS();
        uint256 seizeEth = (seizeUsdWad * 1e8 + ethUsd - 1) / ethUsd;
        if (seizeEth < pool.MIN_LIQUIDATION_WETH()) return;

        usdc.mint(liquidator, repay);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), repay);
        pool.liquidate(user, repay);
        vm.stopPrank();
    }

    function setPrice(uint256 newPrice) external {
        uint256 value = bound(newPrice, 500e8, 4000e8);
        oracle.setPrice(value);
    }

    function accrue() external {
        pool.accrue();
    }
}

contract LendingPoolInvariants is StdInvariant, Test {
    LendingPool pool;
    WETH9 weth;
    MockUSDC usdc;
    OracleMock oracle;
    LendingPoolHandler handler;

    address[] actors;

    function setUp() public {
        weth = new WETH9();
        usdc = new MockUSDC();
        oracle = new OracleMock(2000e8);

        pool = new LendingPool(
            address(weth),
            address(usdc),
            address(oracle),
            7500,
            8000,
            200,
            400,
            2000,
            8000,
            1000
        );

        actors = new address[](3);
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");

        address lender = actors[0];
        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositUSDC(500_000e6);
        vm.stopPrank();

        handler = new LendingPoolHandler(
            pool,
            weth,
            usdc,
            oracle,
            actors
        );

        targetContract(address(handler));
    }

    function invariant_noBorrowCapacityWhenUnderwater() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 debt = pool.getUserDebtUSDC(actor);
            if (debt == 0) continue;
            if (pool.getHealthFactor(actor) >= 1e18) continue;
            assertLe(pool.getBorrowMax(actor), debt);
        }
    }

    function invariant_withdrawWouldBreakHealthFactorWhenUnderwater()
        public
        view
    {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 debt = pool.getUserDebtUSDC(actor);
            if (debt == 0) continue;
            if (pool.getHealthFactor(actor) >= 1e18) continue;
            uint256 collateral = pool.collateralWETH(actor);
            if (collateral == 0) continue;
            uint256 newCol = collateral - 1;
            uint256 ethUsd = oracle.getEthUsdPrice();
            uint256 collateralUsdWad = (newCol * ethUsd) / 1e8;
            uint256 adjCollateralWad = (collateralUsdWad *
                pool.LIQ_THRESHOLD_BPS()) / pool.BPS();
            uint256 debtUsdWad = debt * 1e12;
            uint256 newHf = (adjCollateralWad * 1e18) / debtUsdWad;
            assertLt(newHf, 1e18);
        }
    }

    function invariant_totalCollateralMatchesUsers() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += pool.collateralWETH(actors[i]);
        }
        assertEq(pool.totalCollateralWETH(), sum);
    }

    function invariant_totalScaledDebtMatchesUsers() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += pool.scaledDebtUSDC(actors[i]);
        }
        assertEq(pool.totalScaledDebt(), sum);
    }

    function invariant_totalSupplySharesMatchesUsers() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += pool.supplyShares(actors[i]);
        }
        assertEq(pool.totalSupplyShares(), sum);
    }

    function invariant_assetsCoverReserves() public view {
        uint256 cashWad = usdc.balanceOf(address(pool)) * 1e12;
        uint256 debtWad = (pool.totalScaledDebt() * pool.borrowIndex()) /
            1e27;
        assertGe(cashWad + debtWad, pool.reserveWad());
    }
}
