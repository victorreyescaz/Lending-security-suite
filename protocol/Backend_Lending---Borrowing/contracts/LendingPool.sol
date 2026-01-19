// SPDX-License-Identifier: MIT

// LendingPool: vault principal que acepta ETH y lo envuelve en WETH, presta USDC contra ese colateral y lleva intereses.
// Factores clave: WETH (colateral), USDC (activo prestado), ORACLE (ETH/USD con 8 decimales).
// Riesgo/config: LTV_BPS define cuánto USDC se puede pedir sobre el valor del WETH; LIQ_THRESHOLD_BPS marca el umbral de liquidación; la tasa de borrow es dinámica (kink).
// Índices de interés: borrowIndex (ray, 1e27) y lastAccrual (timestamp) se usan para acumular deuda compuesta.
// Estado por usuario: collateralWETH (WETH depositado, 18 dec) y scaledDebtUSDC (deuda indexada, 6 dec tras desescalar).

pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IWETH is IERC20 {
    function deposit() external payable;

    function withdraw(uint256) external;
}

// Return price with 8 decimals (Chainlink style)
interface IOracle {
    function getEthUsdPrice() external view returns (uint256);
}

contract LendingPool is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    uint256 public constant YEAR = 365 days;

    // ---------- Errors ----------
    error ZeroAmount();
    error HealthFactorTooLow();
    error TransferFailed();
    error InsufficientLiquidity();
    error InsufficientCollateral();
    error InsufficientShares();
    error NotLiquidatable();
    error NoDebt();
    error DustAmount();
    error Unsupported();
    // ---------- Events ----------
    event Deposit(address indexed user, uint256 ethAmount);
    event Withdraw(address indexed user, uint256 ethAmount);
    event Borrow(address indexed user, uint256 usdcAmount);
    event Repay(address indexed user, uint256 usdcAmount);
    event SupplyUSDC(address indexed user, uint256 usdcAmount, uint256 shares);
    event WithdrawUSDC(
        address indexed user,
        uint256 usdcAmount,
        uint256 shares
    );
    event Accrue(
        uint256 timestamp,
        uint256 utilizationBps,
        uint256 rateBps,
        uint256 interestAccruedWad,
        uint256 reserveAccruedWad,
        uint256 prevIndex,
        uint256 newIndex
    );
    event Liquidate(
        address indexed liquidator,
        address indexed user,
        uint256 repayAmount,
        uint256 seizedCollateral
    );
    event RiskParamsUpdated(uint256 ltvBps, uint256 liqThresholdBps);
    event RateModelUpdated(
        uint256 baseRateBps,
        uint256 slope1Bps,
        uint256 slope2Bps,
        uint256 optimalUtilBps
    );
    event ReserveFactorUpdated(uint256 reserveFactorBps);
    event OracleUpdated(address indexed oracle);

    // ---------- Core addresses ----------
    IWETH public immutable WETH;
    IERC20 public immutable USDC;
    IOracle public ORACLE;
    uint256 public RESERVE_FACTOR_BPS;

    // ---------- Risk params ----------
    uint256 public constant BPS = 10_000;
    uint256 public LTV_BPS; // e.g. 7500
    uint256 public LIQ_THRESHOLD_BPS; // e.g. 8000
    uint256 public BASE_RATE_BPS; // e.g. 200 (2%)
    uint256 public SLOPE1_BPS; // e.g. 400 (4%) hasta el kink
    uint256 public SLOPE2_BPS; // e.g. 2000 (20%) por encima del kink
    uint256 public OPTIMAL_UTIL_BPS; // e.g. 8000 (80%)
    uint256 public constant LIQ_BONUS_BPS = 500; // 5% bonus to liquidator
    uint256 public constant CLOSE_FACTOR_BPS = 5000; // 50% of debt per liquidation
    uint256 public constant MIN_LIQUIDATION_USDC = 1_000; // 0.001 USDC
    uint256 public constant MIN_LIQUIDATION_WETH = 1_000_000_000; // 1 gwei

    // ---------- Interest indexing ----------
    uint256 public borrowIndex; // ray(1e27)
    uint256 public lastAccrual; // timestamp

    // ---------- User state ----------
    mapping(address => uint256) public collateralWETH; // in wei (1e18)
    mapping(address => uint256) public scaledDebtUSDC;

    // ---------- Global state ----------
    uint256 public totalCollateralWETH;
    uint256 public totalScaledDebt;

    // ---------- Lender supply (USDC) ----------
    uint256 public totalSupplyShares; // WAD shares
    mapping(address => uint256) public supplyShares;
    uint256 public reserveWad;

    struct AccrueCache {
        uint256 last;
        uint256 prevIndex;
        uint256 prevTotalDebtWad;
        uint256 utilBps;
        uint256 rateBps;
        uint256 interestAccruedWad;
        uint256 reserveAccruedWad;
        uint256 newIndex;
        uint256 newLast;
    }

    // ---------- Helpers de "ray math" ----------
    uint256 public constant RAY = 1e27;
    uint256 public constant WAD = 1e18;

    function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / RAY;
    }

    function _rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * RAY) / b;
    }

    function _usdcToWad(uint256 usdcAmount) internal pure returns (uint256) {
        // 6 -> 18
        return usdcAmount * 1e12;
    }

    function _wadToUsdc(uint256 wadAmount) internal pure returns (uint256) {
        // 18 -> 6 (floor)
        return wadAmount / 1e12;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // Helper withdrawETH

    function _healthFactorWithCollateral(
        address user,
        uint256 ethCollateral
    ) internal view returns (uint256) {
        uint256 debtUsdc = _wadToUsdc(
            _rayMul(scaledDebtUSDC[user], borrowIndex)
        );
        if (debtUsdc == 0) return type(uint256).max;

        uint256 ethUsd = ORACLE.getEthUsdPrice(); // 1e8
        uint256 collateralUsdWad = (ethCollateral * ethUsd) / 1e8; // 1e18
        uint256 adjCollateralWad = (collateralUsdWad * LIQ_THRESHOLD_BPS) / BPS;
        uint256 debtUsdWad = _usdcToWad(debtUsdc);

        return (adjCollateralWad * WAD) / debtUsdWad;
    }

    // Helpers accountData

    function _collateralUsdWad(address user) internal view returns (uint256) {
        uint256 ethCollateral = collateralWETH[user];
        if (ethCollateral == 0) return 0;

        uint256 ethUsd = ORACLE.getEthUsdPrice(); // 1e8
        return (ethCollateral * ethUsd) / 1e8;
    }

    function _debtUsdWad(address user) internal view returns (uint256) {
        uint256 scaledDebt = scaledDebtUSDC[user];
        if (scaledDebt == 0) return 0;
        uint256 debtWad = _rayMul(scaledDebt, borrowIndex);
        return (debtWad / 1e12) * 1e12;
    }

    constructor(
        address weth_,
        address usdc_,
        address oracle_,
        uint256 ltvBps_,
        uint256 liqThresholdBps_,
        uint256 baseRateBps_,
        uint256 slope1Bps_,
        uint256 slope2Bps_,
        uint256 optimalUtilBps_,
        uint256 reserveFactorBps_
    ) Ownable(msg.sender) {
        if (reserveFactorBps_ > BPS) revert InsufficientCollateral();
        WETH = IWETH(weth_);
        USDC = IERC20(usdc_);
        ORACLE = IOracle(oracle_);
        RESERVE_FACTOR_BPS = reserveFactorBps_;

        _setRiskParams(ltvBps_, liqThresholdBps_);
        _setRateModel(baseRateBps_, slope1Bps_, slope2Bps_, optimalUtilBps_);

        borrowIndex = RAY;
        lastAccrual = block.timestamp;
    }

    // ---------- View helpers ----------
    function getHealthFactor(address user) public view returns (uint256) {
        uint256 debtUsdc = _wadToUsdc(
            _rayMul(scaledDebtUSDC[user], borrowIndex)
        );
        if (debtUsdc == 0) return type(uint256).max;

        uint256 ethCollateral = collateralWETH[user];
        uint256 ethUsd = ORACLE.getEthUsdPrice(); // 1e8

        uint256 collateralUsdWad = (ethCollateral * ethUsd) / 1e8; // 1e18
        uint256 adjCollateralWad = (collateralUsdWad * LIQ_THRESHOLD_BPS) / BPS;
        uint256 debtUsdWad = _usdcToWad(debtUsdc);

        return (adjCollateralWad * WAD) / debtUsdWad;
    }

    function getBorrowMax(address user) public view returns (uint256) {
        uint256 ethCollateral = collateralWETH[user]; // 1e18
        if (ethCollateral == 0) return 0;

        uint256 ethUsd = ORACLE.getEthUsdPrice(); // 1e8
        uint256 collateralValueUsdWad = (ethCollateral * ethUsd) / 1e8; // scale to 1e18
        uint256 maxBorrowUsdWad = (collateralValueUsdWad * LTV_BPS) / BPS;
        return _wadToUsdc(maxBorrowUsdWad); // 1e6
    }

    function getUserDebtUSDC(address user) external view returns (uint256) {
        uint256 debtWad = _rayMul(scaledDebtUSDC[user], borrowIndex);
        return _wadToUsdc(debtWad);
    }

    function getUtilizationBps() public view returns (uint256) {
        uint256 debtWad = _rayMul(totalScaledDebt, borrowIndex);
        if (debtWad == 0) return 0;

        uint256 cashWad = _usdcToWad(USDC.balanceOf(address(this)));
        uint256 total = debtWad + cashWad;
        if (total == 0) return 0;

        return Math.mulDiv(debtWad, BPS, total);
    }

    function _borrowRateBps(uint256 utilBps) internal view returns (uint256) {
        if (utilBps == 0) return BASE_RATE_BPS;

        if (OPTIMAL_UTIL_BPS == 0) {
            return BASE_RATE_BPS + Math.mulDiv(SLOPE2_BPS, utilBps, BPS);
        }

        if (utilBps <= OPTIMAL_UTIL_BPS) {
            return
                BASE_RATE_BPS +
                Math.mulDiv(SLOPE1_BPS, utilBps, OPTIMAL_UTIL_BPS);
        }

        uint256 excess = utilBps - OPTIMAL_UTIL_BPS;
        uint256 denom = BPS - OPTIMAL_UTIL_BPS;
        if (denom == 0) return BASE_RATE_BPS + SLOPE1_BPS;

        return
            BASE_RATE_BPS + SLOPE1_BPS + Math.mulDiv(SLOPE2_BPS, excess, denom);
    }

    // ---------- Admin controls ----------
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setOracle(address oracle_) external onlyOwner {
        if (oracle_ == address(0)) revert Unsupported();
        ORACLE = IOracle(oracle_);
        emit OracleUpdated(oracle_);
    }

    function setRiskParams(
        uint256 ltvBps_,
        uint256 liqThresholdBps_
    ) external onlyOwner {
        _setRiskParams(ltvBps_, liqThresholdBps_);
        emit RiskParamsUpdated(ltvBps_, liqThresholdBps_);
    }

    function setRateModel(
        uint256 baseRateBps_,
        uint256 slope1Bps_,
        uint256 slope2Bps_,
        uint256 optimalUtilBps_
    ) external onlyOwner {
        _accrue();
        _setRateModel(baseRateBps_, slope1Bps_, slope2Bps_, optimalUtilBps_);
        emit RateModelUpdated(
            baseRateBps_,
            slope1Bps_,
            slope2Bps_,
            optimalUtilBps_
        );
    }

    function setReserveFactor(uint256 reserveFactorBps_) external onlyOwner {
        if (reserveFactorBps_ > BPS) revert InsufficientCollateral();
        _accrue();
        RESERVE_FACTOR_BPS = reserveFactorBps_;
        emit ReserveFactorUpdated(reserveFactorBps_);
    }

    function rescueToken(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (
            token == address(0) ||
            to == address(0) ||
            token == address(USDC) ||
            token == address(WETH)
        ) revert Unsupported();
        IERC20(token).safeTransfer(to, amount);
    }

    function _setRiskParams(
        uint256 ltvBps_,
        uint256 liqThresholdBps_
    ) internal {
        if (
            ltvBps_ > BPS ||
            liqThresholdBps_ > BPS ||
            liqThresholdBps_ < ltvBps_
        ) revert InsufficientCollateral();
        LTV_BPS = ltvBps_;
        LIQ_THRESHOLD_BPS = liqThresholdBps_;
    }

    function _setRateModel(
        uint256 baseRateBps_,
        uint256 slope1Bps_,
        uint256 slope2Bps_,
        uint256 optimalUtilBps_
    ) internal {
        if (optimalUtilBps_ > BPS) revert InsufficientCollateral();
        BASE_RATE_BPS = baseRateBps_;
        SLOPE1_BPS = slope1Bps_;
        SLOPE2_BPS = slope2Bps_;
        OPTIMAL_UTIL_BPS = optimalUtilBps_;
    }

    function getUserAccountData(
        address user
    )
        external
        view
        returns (
            uint256 collateralUsdWad,
            uint256 debtUsdWad,
            uint256 borrowMaxUsdc,
            uint256 healthFactorWad
        )
    {
        uint256 ethCollateral = collateralWETH[user];
        if (ethCollateral != 0) {
            uint256 ethUsd = ORACLE.getEthUsdPrice(); // 1e8
            collateralUsdWad = (ethCollateral * ethUsd) / 1e8; // 1e18
            borrowMaxUsdc = _wadToUsdc((collateralUsdWad * LTV_BPS) / BPS);
        }

        uint256 scaledDebt = scaledDebtUSDC[user];
        if (scaledDebt == 0) {
            healthFactorWad = type(uint256).max;
        } else {
            uint256 debtUsdc = _wadToUsdc(_rayMul(scaledDebt, borrowIndex)); //1e6
            debtUsdWad = _usdcToWad(debtUsdc); // 1e18

            if (debtUsdWad == 0) {
                healthFactorWad = type(uint256).max;
            } else {
                uint256 adjCollateralWad = (collateralUsdWad *
                    LIQ_THRESHOLD_BPS) / BPS;
                healthFactorWad = (adjCollateralWad * WAD) / debtUsdWad;
            }
        }
    }

    function getBorrowRateBps() public view returns (uint256) {
        return _borrowRateBps(getUtilizationBps());
    }

    // ---------- Core actions ----------
    function depositETH() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        _accrue();
        // Wrap ETH -> WETH
        WETH.deposit{value: msg.value}();
        // Update collateral
        collateralWETH[msg.sender] += msg.value;
        totalCollateralWETH += msg.value;

        emit Deposit(msg.sender, msg.value);
    }

    function withdrawETH(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        _accrue();

        uint256 col = collateralWETH[msg.sender];
        if (amount > col) revert InsufficientCollateral();

        // 1) HF check usando colateral “post-withdraw”
        uint256 newCol = col - amount;

        if (_healthFactorWithCollateral(msg.sender, newCol) < WAD)
            revert HealthFactorTooLow();

        // 2) Effects: actualiza storage ANTES de interacciones (CEI)
        collateralWETH[msg.sender] = newCol;
        totalCollateralWETH -= amount;

        // 3) Interactions: unwrap y enviar ETH
        WETH.withdraw(amount);
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Withdraw(msg.sender, amount);
    }

    function depositUSDC(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _accrue();

        uint256 totalAssets = _totalAssetsWad();
        uint256 totalShares = totalSupplyShares;
        uint256 amountWad = _usdcToWad(amount);

        uint256 shares = totalShares == 0 || totalAssets == 0
            ? amountWad
            : (amountWad * totalShares) / totalAssets;
        if (shares == 0) revert InsufficientShares();

        supplyShares[msg.sender] += shares;
        totalSupplyShares = totalShares + shares;

        bool ok = USDC.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        emit SupplyUSDC(msg.sender, amount, shares);
    }

    function withdrawUSDC(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        _accrue();

        uint256 totalAssets = _totalAssetsWad();
        uint256 totalShares = totalSupplyShares;
        if (totalShares == 0 || totalAssets == 0) revert InsufficientShares();

        uint256 amountWad = _usdcToWad(amount);
        uint256 shares = _ceilDiv(amountWad * totalShares, totalAssets);

        uint256 userShares = supplyShares[msg.sender];
        if (shares > userShares) revert InsufficientShares();
        if (USDC.balanceOf(address(this)) < amount)
            revert InsufficientLiquidity();

        supplyShares[msg.sender] = userShares - shares;
        totalSupplyShares = totalShares - shares;

        bool ok = USDC.transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();

        emit WithdrawUSDC(msg.sender, amount, shares);
    }

    function borrowUSDC(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _accrue();

        // 1) check liquidity
        if (USDC.balanceOf(address(this)) < amount)
            revert InsufficientLiquidity();

        // 2) check max borrow
        uint256 maxBorrow = getBorrowMax(msg.sender);

        uint256 debtActualUSDC = _wadToUsdc(
            _rayMul(scaledDebtUSDC[msg.sender], borrowIndex)
        );
        if (debtActualUSDC + amount > maxBorrow) revert HealthFactorTooLow();

        // 3) update scaled debt
        uint256 amountWad = _usdcToWad(amount);
        uint256 scaledDelta = _rayDiv(amountWad, borrowIndex);
        scaledDebtUSDC[msg.sender] += scaledDelta;
        totalScaledDebt += scaledDelta;

        // transfer USDC to user
        USDC.safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, amount);
    }

    function repayUSDC(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _accrue();

        // debt in USDC (1e6) to cap repayment
        uint256 debtUsdc = _wadToUsdc(
            _rayMul(scaledDebtUSDC[msg.sender], borrowIndex)
        );
        if (debtUsdc == 0) revert ZeroAmount();

        uint256 pay = amount > debtUsdc ? debtUsdc : amount;

        // 1) pull USDC
        USDC.safeTransferFrom(msg.sender, address(this), pay);

        // 2) reduce scaled debt
        uint256 payWad = _usdcToWad(pay);
        uint256 scaledDelta = _rayDiv(payWad, borrowIndex);

        uint256 currentScaled = scaledDebtUSDC[msg.sender];
        uint256 actualScaledDelta = scaledDelta >= currentScaled
            ? currentScaled
            : scaledDelta;

        totalScaledDebt = actualScaledDelta >= totalScaledDebt
            ? 0
            : totalScaledDebt - actualScaledDelta;

        scaledDebtUSDC[msg.sender] = scaledDelta >= currentScaled
            ? 0
            : currentScaled - scaledDelta;

        emit Repay(msg.sender, pay);
    }

    function liquidate(
        address user,
        uint256 repayAmount
    ) external nonReentrant whenNotPaused {
        if (repayAmount == 0) revert ZeroAmount();

        _accrue();

        if (getHealthFactor(user) >= WAD) revert NotLiquidatable();

        (uint256 repayUsdc, uint256 seizeEth) = _calcLiquidation(
            user,
            repayAmount
        );

        _reduceUserDebt(user, repayUsdc);
        _seizeCollateral(user, seizeEth);

        USDC.safeTransferFrom(msg.sender, address(this), repayUsdc);
        IERC20(address(WETH)).safeTransfer(msg.sender, seizeEth);

        emit Liquidate(msg.sender, user, repayUsdc, seizeEth);
    }

    function _calcLiquidation(
        address user,
        uint256 repayAmount
    ) internal view returns (uint256 repayUsdc, uint256 seizeEth) {
        uint256 debtUsdc = _wadToUsdc(
            _rayMul(scaledDebtUSDC[user], borrowIndex)
        );
        if (debtUsdc == 0) revert NoDebt();

        uint256 maxClose = (debtUsdc * CLOSE_FACTOR_BPS) / BPS;
        if (maxClose == 0) revert NoDebt();

        repayUsdc = repayAmount > maxClose ? maxClose : repayAmount;
        if (repayUsdc < MIN_LIQUIDATION_USDC) revert DustAmount();

        uint256 ethUsd = ORACLE.getEthUsdPrice(); // 1e8
        uint256 collateralEth = collateralWETH[user];
        if (collateralEth == 0) revert InsufficientCollateral();

        uint256 collateralUsdWad = (collateralEth * ethUsd) / 1e8;
        uint256 maxRepayUsdWad = (collateralUsdWad * BPS) /
            (BPS + LIQ_BONUS_BPS);
        uint256 maxRepayUsdc = _wadToUsdc(maxRepayUsdWad);
        if (maxRepayUsdc == 0) revert InsufficientCollateral();

        if (repayUsdc > maxRepayUsdc) repayUsdc = maxRepayUsdc;
        if (repayUsdc < MIN_LIQUIDATION_USDC) revert DustAmount();

        uint256 seizeUsdWad = (_usdcToWad(repayUsdc) * (BPS + LIQ_BONUS_BPS)) /
            BPS;
        seizeEth = _ceilDiv(seizeUsdWad * 1e8, ethUsd);

        if (seizeEth < MIN_LIQUIDATION_WETH) revert DustAmount();
        if (seizeEth > collateralEth) seizeEth = collateralEth;
    }

    function _reduceUserDebt(address user, uint256 repayUsdc) internal {
        uint256 repayWad = _usdcToWad(repayUsdc);
        uint256 scaledDelta = _rayDiv(repayWad, borrowIndex);
        uint256 currentScaled = scaledDebtUSDC[user];
        uint256 actualScaledDelta = scaledDelta >= currentScaled
            ? currentScaled
            : scaledDelta;

        totalScaledDebt = actualScaledDelta >= totalScaledDebt
            ? 0
            : totalScaledDebt - actualScaledDelta;

        scaledDebtUSDC[user] = scaledDelta >= currentScaled
            ? 0
            : currentScaled - scaledDelta;
    }

    function _seizeCollateral(address user, uint256 seizeEth) internal {
        collateralWETH[user] -= seizeEth;
        totalCollateralWETH -= seizeEth;
    }

    function accrue() external {
        _accrue();
    }

    // ---------- Internal ----------
    function _accrue() internal {
        uint256 ts = block.timestamp;
        AccrueCache memory cache;
        cache.last = lastAccrual;
        // Hardhat snapshots / manual timestamp setting can move time backwards.
        // Avoid underflow and resync accrual timestamp to keep the pool usable.
        if (ts <= cache.last) {
            lastAccrual = ts;
            return;
        }

        uint256 dtExact = ts - cache.last;
        if (dtExact < 60) return;
        // Accrue at minute granularity to avoid "1 second per block" drift in tests.
        uint256 dt = (dtExact / 60) * 60;
        if (dt == 0) return;

        cache.prevIndex = borrowIndex;
        cache.prevTotalDebtWad = _rayMul(totalScaledDebt, cache.prevIndex);
        cache.utilBps = getUtilizationBps();
        cache.rateBps = _borrowRateBps(cache.utilBps);

        uint256 factorRay = RAY + (((cache.rateBps * RAY) / BPS) * dt) / YEAR;
        cache.newIndex = _rayMul(cache.prevIndex, factorRay);
        borrowIndex = cache.newIndex;

        uint256 newTotalDebtWad = _rayMul(totalScaledDebt, cache.newIndex);
        if (newTotalDebtWad > cache.prevTotalDebtWad) {
            unchecked {
                cache.interestAccruedWad =
                    newTotalDebtWad -
                    cache.prevTotalDebtWad;
            }
        }
        if (cache.interestAccruedWad != 0 && RESERVE_FACTOR_BPS != 0) {
            cache.reserveAccruedWad =
                (cache.interestAccruedWad * RESERVE_FACTOR_BPS) /
                BPS;
            reserveWad += cache.reserveAccruedWad;
        }

        cache.newLast = cache.last + dt;
        lastAccrual = cache.newLast;
        emit Accrue(
            cache.newLast,
            cache.utilBps,
            cache.rateBps,
            cache.interestAccruedWad,
            cache.reserveAccruedWad,
            cache.prevIndex,
            cache.newIndex
        );
    }

    function getUserSupplyUSDC(address user) external view returns (uint256) {
        uint256 shares = supplyShares[user];
        if (shares == 0) return 0;
        uint256 totalShares = totalSupplyShares;
        if (totalShares == 0) return 0;
        uint256 assetsWad = _totalAssetsWad();
        uint256 amountWad = (shares * assetsWad) / totalShares;
        return _wadToUsdc(amountWad);
    }

    function _totalAssetsWad() internal view returns (uint256) {
        uint256 cashWad = _usdcToWad(USDC.balanceOf(address(this)));
        uint256 debtWad = _rayMul(totalScaledDebt, borrowIndex);
        return cashWad + debtWad - reserveWad;
    }

    receive() external payable {}
}
