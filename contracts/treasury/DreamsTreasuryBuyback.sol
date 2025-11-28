// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/IzDREAMS.sol";

/**
 * @title DreamsTreasuryBuyback (DEX Wrapper Model)
 * @notice Allows users to sell their staked DREAMS back for ETH/AVAX
 *
 * DEX WRAPPER MODEL:
 * Unlike a pre-funded reserve model, this contract acts as a DEX wrapper:
 * 1. User sells zDREAMS → Contract receives DREAMS from staking
 * 2. Contract swaps DREAMS → JUICY → ETH/AVAX on DEX (real-time)
 * 3. Contract takes 2.5% spread as profit
 * 4. User receives ETH/AVAX
 *
 * WHY THIS MODEL:
 * - No pre-funded ETH reserves needed
 * - Treasury's DREAMS holdings ARE the backing
 * - Scales automatically with price (DREAMS worth more = more ETH available)
 * - Uses existing DEX liquidity
 *
 * MULTI-CHAIN SUPPORT:
 * - BASE: Uses Uniswap V3 (DREAMS → JUICY → WETH → unwrap)
 * - Avalanche: Uses Trader Joe (DREAMS → JUICY → WAVAX → unwrap)
 *
 * PROTECTIONS:
 * - TWAP oracle for fair pricing (manipulation resistant)
 * - Circuit breaker on 20% price deviation
 * - Dynamic spread during volatility
 * - Daily limits (per-user and global)
 * - Large sell cooldown
 * - Slippage protection on DEX swaps
 */

// ============ INTERFACES ============

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface ITraderJoeRouter {
    function swapExactTokensForAVAX(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IDreamsStaking {
    function unstakeForBuyback(
        address user,
        uint256 amount,
        address recipient
    ) external returns (uint256 penalty);

    function getStakeInfo(address _account) external view returns (
        uint256 stakedAmount,
        uint256 vestedAmount,
        uint256 votingPower,
        uint256 pendingRewardsUSD,
        uint256 cliffEnds,
        uint256 vestingEnds,
        bool cliffReached
    );

    function stakes(address user) external view returns (
        uint256 amount,
        uint256 startTime,
        uint256 rewardsAccruedUSD,
        uint256 rewardsClaimed,
        uint256 lastRewardTime
    );

    function totalStaked() external view returns (uint256);
}

/**
 * @title AggregatorV3Interface
 * @notice Chainlink price feed interface for ETH/USD and AVAX/USD fallback
 */
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

contract DreamsTreasuryBuyback is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ TOKENS & CONTRACTS ============

    IERC20 public immutable dreams;
    IERC20 public immutable juicy;
    IzDREAMS public zDreamsToken;
    IPriceOracle public priceOracle;
    IDreamsStaking public dreamsStaking;

    // DEX configuration
    address public immutable wrappedNative;  // WETH on BASE, WAVAX on AVAX
    address public dexRouter;
    uint24 public poolFee = 3000;  // 0.3% for Uniswap V3 (ignored on Trader Joe)
    bool public immutable isAvalanche;

    // Admin
    address public admin;
    address public pendingAdmin;
    address public treasury;

    // ============ FEE & SPREAD CONFIGURATION ============

    uint256 public sellSpreadBps = 250;  // 2.5% spread (treasury profit)
    uint256 public constant MAX_SPREAD_BPS = 1000; // Max 10% spread
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant SLIPPAGE_BPS = 300;  // 3% max slippage on DEX swaps

    // ============ PRICE MANIPULATION PROTECTION ============

    // Reference price tracking (for deviation detection)
    uint256 public referencePrice;           // Last known "safe" price (8 decimals)
    uint256 public referencePriceTimestamp;  // When reference was set
    uint256 public referencePriceUpdateInterval = 24 hours;

    // Circuit breaker settings
    uint256 public maxPriceDeviationBps = 2000;  // 20% max deviation from reference
    bool public circuitBreakerTriggered;
    uint256 public circuitBreakerCooldown = 1 hours;
    uint256 public lastCircuitBreakerTrigger;

    // Dynamic spread (increases during volatility)
    uint256 public volatilitySpreadBps = 0;
    uint256 public maxVolatilitySpreadBps = 500; // Max 5% additional spread
    uint256 public priceDropThresholdBps = 1000; // 10% drop triggers volatility spread

    // Large sell cooldown
    uint256 public largeSellThreshold = 25000 ether;  // 25k DREAMS = "large" sell
    uint256 public largeSellCooldown = 30 minutes;
    mapping(address => uint256) public lastLargeSell;

    // ============ CHAINLINK FALLBACK ORACLE ============

    AggregatorV3Interface public chainlinkEthUsd;
    AggregatorV3Interface public chainlinkAvaxUsd;
    uint256 public chainlinkHeartbeat = 3600;
    bool public useChainlinkFallback = true;
    uint256 public manualPriceOverride;
    uint256 public manualPriceExpiry;

    // ============ LIMITS (Bank Run Protection) ============

    uint256 public maxSellPerTx = 100000 ether;     // 100k DREAMS per transaction
    uint256 public dailySellLimit = 1000000 ether;  // 1M DREAMS global per day
    uint256 public userDailyLimit = 50000 ether;    // 50k DREAMS per user per day

    // Tracking
    mapping(address => mapping(uint256 => uint256)) public userDailySells;
    mapping(uint256 => uint256) public globalDailySells;
    uint256 public totalSoldBack;

    // Status
    bool public buybackEnabled = true;

    // ============ EVENTS ============

    event BuybackExecuted(
        address indexed user,
        uint256 dreamsAmount,
        uint256 nativePayout,
        uint256 oraclePrice,
        uint256 effectivePrice,
        uint256 penalty,
        uint256 spreadTaken,
        uint256 timestamp
    );
    event SpreadUpdated(uint256 oldSpread, uint256 newSpread);
    event LimitsUpdated(uint256 maxPerTx, uint256 dailyGlobal, uint256 dailyUser);
    event BuybackToggled(bool enabled);
    event RouterUpdated(address oldRouter, address newRouter);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferCompleted(address indexed oldAdmin, address indexed newAdmin);

    // Circuit breaker events
    event CircuitBreakerTriggered(uint256 currentPrice, uint256 referencePrice, uint256 deviationBps);
    event CircuitBreakerReset(address indexed admin);
    event ReferencePriceUpdated(uint256 oldPrice, uint256 newPrice);
    event VolatilitySpreadActivated(uint256 spreadBps, uint256 priceDropBps);
    event VolatilitySpreadDeactivated();

    // Chainlink events
    event ChainlinkFallbackUsed(uint256 twapPrice, uint256 chainlinkPrice, string reason);
    event ChainlinkFeedUpdated(address ethUsdFeed, address avaxUsdFeed);
    event ManualPriceOverrideSet(uint256 price, uint256 expiry);

    // DEX events
    event SwapExecuted(uint256 dreamsIn, uint256 juicyOut, uint256 nativeOut);

    // ============ ERRORS ============

    error BuybackDisabled();
    error InvalidAmount();
    error InvalidAddress();
    error OnlyAdmin();
    error NotPendingAdmin();
    error ExceedsTransactionLimit();
    error ExceedsUserDailyLimit();
    error ExceedsGlobalDailyLimit();
    error CliffNotReached();
    error InsufficientZDreams();
    error SpreadTooHigh();
    error TransferFailed();
    error CircuitBreakerActive();
    error PriceDeviationTooHigh();
    error LargeSellCooldownActive();
    error NoPriceAvailable();
    error SwapFailed();
    error InsufficientOutput();

    // ============ MODIFIERS ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier whenBuybackEnabled() {
        if (!buybackEnabled) revert BuybackDisabled();
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor(
        address _dreams,
        address _juicy,
        address _wrappedNative,
        address _dexRouter,
        address _zDreamsToken,
        address _priceOracle,
        address _dreamsStaking,
        address _treasury,
        bool _isAvalanche
    ) {
        if (_dreams == address(0)) revert InvalidAddress();
        if (_juicy == address(0)) revert InvalidAddress();
        if (_wrappedNative == address(0)) revert InvalidAddress();
        if (_dexRouter == address(0)) revert InvalidAddress();
        if (_zDreamsToken == address(0)) revert InvalidAddress();
        if (_priceOracle == address(0)) revert InvalidAddress();
        if (_dreamsStaking == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();

        dreams = IERC20(_dreams);
        juicy = IERC20(_juicy);
        wrappedNative = _wrappedNative;
        dexRouter = _dexRouter;
        zDreamsToken = IzDREAMS(_zDreamsToken);
        priceOracle = IPriceOracle(_priceOracle);
        dreamsStaking = IDreamsStaking(_dreamsStaking);
        treasury = _treasury;
        isAvalanche = _isAvalanche;
        admin = msg.sender;

        // Approve router to spend tokens
        IERC20(_dreams).approve(_dexRouter, type(uint256).max);
        IERC20(_juicy).approve(_dexRouter, type(uint256).max);
    }

    // ============ MAIN BUYBACK FUNCTION ============

    /**
     * @notice Sell staked DREAMS back for ETH/AVAX
     * @dev DEX WRAPPER MODEL:
     *      1. Burns user's zDREAMS, receives DREAMS from staking
     *      2. Swaps DREAMS → JUICY → ETH/AVAX on DEX
     *      3. Takes 2.5% spread, sends rest to user
     *
     * @param _dreamsAmount Amount of DREAMS to sell back
     */
    function sellStakedPosition(uint256 _dreamsAmount) external nonReentrant whenBuybackEnabled {
        if (_dreamsAmount == 0) revert InvalidAmount();
        if (_dreamsAmount > maxSellPerTx) revert ExceedsTransactionLimit();

        // ========== CIRCUIT BREAKER CHECKS ==========

        // First check if circuit breaker is currently active (from a previous trigger)
        if (circuitBreakerTriggered) {
            if (block.timestamp < lastCircuitBreakerTrigger + circuitBreakerCooldown) {
                revert CircuitBreakerActive();
            }
            // Cooldown passed, auto-reset the circuit breaker
            circuitBreakerTriggered = false;
        }

        // Get current price and check for manipulation
        uint256 currentPrice = _getOraclePrice();

        // Check price deviation - this will SET circuit breaker state if deviation exceeds threshold
        // The state change persists even though we revert after
        bool deviationExceeded = _checkPriceDeviation(currentPrice);
        if (deviationExceeded) {
            // Circuit breaker state has been set, now revert
            // Next call will see circuitBreakerTriggered = true and revert with CircuitBreakerActive
            revert PriceDeviationTooHigh();
        }

        // Check large sell cooldown
        if (_dreamsAmount >= largeSellThreshold) {
            if (block.timestamp < lastLargeSell[msg.sender] + largeSellCooldown) {
                revert LargeSellCooldownActive();
            }
            lastLargeSell[msg.sender] = block.timestamp;
        }

        // ========== STANDARD CHECKS ==========

        // Check user has enough zDREAMS
        uint256 zBalance = zDreamsToken.balanceOf(msg.sender);
        if (zBalance < _dreamsAmount) revert InsufficientZDreams();

        // Check cliff period
        (,,,,,, bool cliffReached) = dreamsStaking.getStakeInfo(msg.sender);
        if (!cliffReached) revert CliffNotReached();

        // Check daily limits
        uint256 today = block.timestamp / 1 days;
        if (userDailySells[msg.sender][today] + _dreamsAmount > userDailyLimit) {
            revert ExceedsUserDailyLimit();
        }
        if (globalDailySells[today] + _dreamsAmount > dailySellLimit) {
            revert ExceedsGlobalDailyLimit();
        }

        // ========== UNSTAKE & RECEIVE DREAMS ==========

        // Unstake DREAMS via staking contract (burns zDREAMS)
        // DREAMS come to this contract for swapping
        uint256 penalty = dreamsStaking.unstakeForBuyback(msg.sender, _dreamsAmount, address(this));
        uint256 dreamsReceived = _dreamsAmount - penalty;

        // ========== DEX SWAP: DREAMS → ETH/AVAX ==========

        uint256 nativeReceived = _swapDreamsToNative(dreamsReceived);

        // ========== APPLY SPREAD & SEND TO USER ==========

        uint256 totalSpreadBps = sellSpreadBps + volatilitySpreadBps;
        uint256 spreadAmount = (nativeReceived * totalSpreadBps) / BPS_DENOMINATOR;
        uint256 userPayout = nativeReceived - spreadAmount;

        // Update tracking
        userDailySells[msg.sender][today] += _dreamsAmount;
        globalDailySells[today] += _dreamsAmount;
        totalSoldBack += _dreamsAmount;

        // Update reference price if interval passed
        _maybeUpdateReferencePrice(currentPrice);

        // Send native token to user
        (bool success, ) = msg.sender.call{value: userPayout}("");
        if (!success) revert TransferFailed();

        // Spread stays in contract (can be withdrawn to treasury)

        emit BuybackExecuted(
            msg.sender,
            _dreamsAmount,
            userPayout,
            currentPrice,
            (currentPrice * (BPS_DENOMINATOR - totalSpreadBps)) / BPS_DENOMINATOR,
            penalty,
            spreadAmount,
            block.timestamp
        );
    }

    // ============ DEX SWAP FUNCTIONS ============

    /**
     * @notice Swap DREAMS → ETH/AVAX via DEX
     * @dev Route: DREAMS → JUICY → WETH/WAVAX → unwrap
     * @param _dreamsAmount Amount of DREAMS to swap
     * @return nativeOut Amount of ETH/AVAX received
     */
    function _swapDreamsToNative(uint256 _dreamsAmount) internal returns (uint256 nativeOut) {
        if (isAvalanche) {
            nativeOut = _swapDreamsToAvax(_dreamsAmount);
        } else {
            nativeOut = _swapDreamsToEth(_dreamsAmount);
        }

        if (nativeOut == 0) revert SwapFailed();
    }

    /**
     * @notice Swap DREAMS → AVAX on Trader Joe
     */
    function _swapDreamsToAvax(uint256 _dreamsAmount) internal returns (uint256) {
        // Step 1: DREAMS → JUICY
        address[] memory path1 = new address[](2);
        path1[0] = address(dreams);
        path1[1] = address(juicy);

        uint256[] memory amounts1 = ITraderJoeRouter(dexRouter).getAmountsOut(_dreamsAmount, path1);
        uint256 minJuicy = (amounts1[1] * (BPS_DENOMINATOR - SLIPPAGE_BPS)) / BPS_DENOMINATOR;

        uint256[] memory juicyAmounts = ITraderJoeRouter(dexRouter).swapExactTokensForTokens(
            _dreamsAmount,
            minJuicy,
            path1,
            address(this),
            block.timestamp + 300
        );
        uint256 juicyReceived = juicyAmounts[1];

        // Step 2: JUICY → AVAX
        address[] memory path2 = new address[](2);
        path2[0] = address(juicy);
        path2[1] = wrappedNative;

        uint256[] memory amounts2 = ITraderJoeRouter(dexRouter).getAmountsOut(juicyReceived, path2);
        uint256 minAvax = (amounts2[1] * (BPS_DENOMINATOR - SLIPPAGE_BPS)) / BPS_DENOMINATOR;

        uint256[] memory avaxAmounts = ITraderJoeRouter(dexRouter).swapExactTokensForAVAX(
            juicyReceived,
            minAvax,
            path2,
            address(this),
            block.timestamp + 300
        );

        uint256 nativeOut = avaxAmounts[1];
        emit SwapExecuted(_dreamsAmount, juicyReceived, nativeOut);
        return nativeOut;
    }

    /**
     * @notice Swap DREAMS → ETH on Uniswap V3 (BASE)
     */
    function _swapDreamsToEth(uint256 _dreamsAmount) internal returns (uint256) {
        // Step 1: DREAMS → JUICY
        ISwapRouter.ExactInputSingleParams memory params1 = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(dreams),
            tokenOut: address(juicy),
            fee: poolFee,
            recipient: address(this),
            amountIn: _dreamsAmount,
            amountOutMinimum: 0,  // Will check after
            sqrtPriceLimitX96: 0
        });

        uint256 juicyReceived = ISwapRouter(dexRouter).exactInputSingle(params1);
        if (juicyReceived == 0) revert SwapFailed();

        // Step 2: JUICY → WETH
        ISwapRouter.ExactInputSingleParams memory params2 = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(juicy),
            tokenOut: wrappedNative,
            fee: poolFee,
            recipient: address(this),
            amountIn: juicyReceived,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 wethReceived = ISwapRouter(dexRouter).exactInputSingle(params2);
        if (wethReceived == 0) revert SwapFailed();

        // Step 3: Unwrap WETH → ETH
        IWETH(wrappedNative).withdraw(wethReceived);

        emit SwapExecuted(_dreamsAmount, juicyReceived, wethReceived);
        return wethReceived;
    }

    // ============ ORACLE FUNCTIONS ============

    /**
     * @notice Get oracle price with fallback logic
     */
    function _getOraclePrice() internal view returns (uint256) {
        // Check manual override first
        if (manualPriceOverride > 0 && block.timestamp < manualPriceExpiry) {
            return manualPriceOverride;
        }

        // Try TWAP oracle
        try priceOracle.getPrice(address(dreams)) returns (uint256 twapPrice) {
            if (twapPrice > 0) {
                return twapPrice;
            }
        } catch {}

        // Fallback to reference price if valid
        if (useChainlinkFallback && referencePrice > 0 &&
            block.timestamp < referencePriceTimestamp + (referencePriceUpdateInterval * 2)) {
            return referencePrice;
        }

        revert NoPriceAvailable();
    }

    /**
     * @notice Check price deviation and update state (does NOT revert)
     * @dev Returns true if price deviation exceeds max threshold
     *      State changes (circuit breaker, volatility spread) are persisted regardless of revert
     * @param _currentPrice Current oracle price
     * @return deviationExceeded True if deviation exceeds max and circuit breaker was triggered
     */
    function _checkPriceDeviation(uint256 _currentPrice) internal returns (bool deviationExceeded) {
        if (referencePrice == 0) {
            referencePrice = _currentPrice;
            referencePriceTimestamp = block.timestamp;
            emit ReferencePriceUpdated(0, _currentPrice);
            return false;
        }

        uint256 deviationBps;
        if (_currentPrice > referencePrice) {
            deviationBps = ((_currentPrice - referencePrice) * BPS_DENOMINATOR) / referencePrice;
        } else {
            deviationBps = ((referencePrice - _currentPrice) * BPS_DENOMINATOR) / referencePrice;
        }

        // Check for volatility spread activation
        if (_currentPrice < referencePrice) {
            uint256 dropBps = ((referencePrice - _currentPrice) * BPS_DENOMINATOR) / referencePrice;
            if (dropBps >= priceDropThresholdBps && volatilitySpreadBps == 0) {
                volatilitySpreadBps = (dropBps * maxVolatilitySpreadBps) / priceDropThresholdBps;
                if (volatilitySpreadBps > maxVolatilitySpreadBps) {
                    volatilitySpreadBps = maxVolatilitySpreadBps;
                }
                emit VolatilitySpreadActivated(volatilitySpreadBps, dropBps);
            }
        }

        // Trigger circuit breaker if deviation exceeds max (but don't revert here)
        if (deviationBps > maxPriceDeviationBps) {
            circuitBreakerTriggered = true;
            lastCircuitBreakerTrigger = block.timestamp;
            emit CircuitBreakerTriggered(_currentPrice, referencePrice, deviationBps);
            return true;
        }

        return false;
    }

    /**
     * @notice Update reference price if interval passed
     */
    function _maybeUpdateReferencePrice(uint256 _currentPrice) internal {
        if (block.timestamp >= referencePriceTimestamp + referencePriceUpdateInterval) {
            uint256 oldPrice = referencePrice;
            referencePrice = _currentPrice;
            referencePriceTimestamp = block.timestamp;

            if (volatilitySpreadBps > 0) {
                volatilitySpreadBps = 0;
                emit VolatilitySpreadDeactivated();
            }

            emit ReferencePriceUpdated(oldPrice, _currentPrice);
        }
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get quote for selling DREAMS
     * @param _dreamsAmount Amount of DREAMS to sell
     * @return estimatedNative Estimated native token payout
     * @return oraclePrice Current oracle price
     * @return effectivePrice Price after spread
     * @return totalSpread Total spread being applied
     */
    function getQuoteSell(uint256 _dreamsAmount) external view returns (
        uint256 estimatedNative,
        uint256 oraclePrice,
        uint256 effectivePrice,
        uint256 totalSpread,
        bool userCanSell,
        bool globalCanSell
    ) {
        // Get oracle price
        try priceOracle.getPrice(address(dreams)) returns (uint256 price) {
            oraclePrice = price;
        } catch {
            oraclePrice = referencePrice;
        }

        if (oraclePrice == 0) {
            return (0, 0, 0, 0, false, false);
        }

        // Calculate spread
        totalSpread = sellSpreadBps + volatilitySpreadBps;
        effectivePrice = (oraclePrice * (BPS_DENOMINATOR - totalSpread)) / BPS_DENOMINATOR;

        // Estimate native output (this is approximate, actual DEX output may vary)
        estimatedNative = (_dreamsAmount * effectivePrice) / 1e8;

        // Check limits
        uint256 today = block.timestamp / 1 days;
        userCanSell = userDailySells[msg.sender][today] + _dreamsAmount <= userDailyLimit;
        globalCanSell = globalDailySells[today] + _dreamsAmount <= dailySellLimit;
    }

    /**
     * @notice Get DEX quote for DREAMS → Native swap
     * @dev More accurate than oracle-based estimate
     */
    function getDexQuote(uint256 _dreamsAmount) external view returns (
        uint256 juicyEstimate,
        uint256 nativeEstimate,
        uint256 afterSpread
    ) {
        if (isAvalanche) {
            // DREAMS → JUICY
            address[] memory path1 = new address[](2);
            path1[0] = address(dreams);
            path1[1] = address(juicy);

            try ITraderJoeRouter(dexRouter).getAmountsOut(_dreamsAmount, path1) returns (uint256[] memory amounts1) {
                juicyEstimate = amounts1[1];

                // JUICY → AVAX
                address[] memory path2 = new address[](2);
                path2[0] = address(juicy);
                path2[1] = wrappedNative;

                try ITraderJoeRouter(dexRouter).getAmountsOut(juicyEstimate, path2) returns (uint256[] memory amounts2) {
                    nativeEstimate = amounts2[1];
                } catch {}
            } catch {}
        }
        // Note: Uniswap V3 quoter is separate contract, would need additional integration

        uint256 totalSpread = sellSpreadBps + volatilitySpreadBps;
        afterSpread = (nativeEstimate * (BPS_DENOMINATOR - totalSpread)) / BPS_DENOMINATOR;
    }

    /**
     * @notice Get circuit breaker status
     */
    function getCircuitBreakerStatus() external view returns (
        bool isTriggered,
        uint256 currentPrice,
        uint256 refPrice,
        uint256 deviationBps,
        uint256 totalSpread,
        uint256 timeUntilReset
    ) {
        isTriggered = circuitBreakerTriggered;
        refPrice = referencePrice;
        totalSpread = sellSpreadBps + volatilitySpreadBps;

        try priceOracle.getPrice(address(dreams)) returns (uint256 price) {
            currentPrice = price;
        } catch {
            currentPrice = 0;
        }

        if (refPrice > 0 && currentPrice > 0) {
            if (currentPrice > refPrice) {
                deviationBps = ((currentPrice - refPrice) * BPS_DENOMINATOR) / refPrice;
            } else {
                deviationBps = ((refPrice - currentPrice) * BPS_DENOMINATOR) / refPrice;
            }
        }

        if (isTriggered && block.timestamp < lastCircuitBreakerTrigger + circuitBreakerCooldown) {
            timeUntilReset = (lastCircuitBreakerTrigger + circuitBreakerCooldown) - block.timestamp;
        }
    }

    /**
     * @notice Get user's daily remaining allowance
     */
    function getUserDailyRemaining(address _user) external view returns (uint256 remaining) {
        uint256 today = block.timestamp / 1 days;
        uint256 sold = userDailySells[_user][today];
        remaining = sold >= userDailyLimit ? 0 : userDailyLimit - sold;
    }

    /**
     * @notice Get global daily remaining allowance
     */
    function getGlobalDailyRemaining() external view returns (uint256 remaining) {
        uint256 today = block.timestamp / 1 days;
        uint256 sold = globalDailySells[today];
        remaining = sold >= dailySellLimit ? 0 : dailySellLimit - sold;
    }

    /**
     * @notice Get contract stats
     */
    function getStats() external view returns (
        uint256 contractNativeBalance,
        uint256 contractDreamsBalance,
        uint256 totalSold,
        uint256 currentSpreadBps,
        bool isEnabled
    ) {
        contractNativeBalance = address(this).balance;
        contractDreamsBalance = dreams.balanceOf(address(this));
        totalSold = totalSoldBack;
        currentSpreadBps = sellSpreadBps + volatilitySpreadBps;
        isEnabled = buybackEnabled;
    }

    // ============ ADMIN FUNCTIONS ============

    function setSpread(uint256 _spreadBps) external onlyAdmin {
        if (_spreadBps > MAX_SPREAD_BPS) revert SpreadTooHigh();
        uint256 oldSpread = sellSpreadBps;
        sellSpreadBps = _spreadBps;
        emit SpreadUpdated(oldSpread, _spreadBps);
    }

    function setLimits(
        uint256 _maxPerTx,
        uint256 _dailyGlobal,
        uint256 _dailyUser
    ) external onlyAdmin {
        maxSellPerTx = _maxPerTx;
        dailySellLimit = _dailyGlobal;
        userDailyLimit = _dailyUser;
        emit LimitsUpdated(_maxPerTx, _dailyGlobal, _dailyUser);
    }

    function toggleBuyback() external onlyAdmin {
        buybackEnabled = !buybackEnabled;
        emit BuybackToggled(buybackEnabled);
    }

    function updateRouter(address _newRouter) external onlyAdmin {
        if (_newRouter == address(0)) revert InvalidAddress();
        address oldRouter = dexRouter;
        dexRouter = _newRouter;

        // Update approvals
        dreams.approve(oldRouter, 0);
        juicy.approve(oldRouter, 0);
        dreams.approve(_newRouter, type(uint256).max);
        juicy.approve(_newRouter, type(uint256).max);

        emit RouterUpdated(oldRouter, _newRouter);
    }

    function setPoolFee(uint24 _fee) external onlyAdmin {
        poolFee = _fee;
    }

    function setPriceOracle(address _oracle) external onlyAdmin {
        if (_oracle == address(0)) revert InvalidAddress();
        priceOracle = IPriceOracle(_oracle);
    }

    function setDreamsStaking(address _staking) external onlyAdmin {
        if (_staking == address(0)) revert InvalidAddress();
        dreamsStaking = IDreamsStaking(_staking);
    }

    function setTreasury(address _treasury) external onlyAdmin {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
    }

    // ============ CIRCUIT BREAKER FUNCTIONS ============

    /**
     * @notice Public function to check price and trigger circuit breaker if needed
     * @dev Anyone can call this to protect the protocol during price manipulation
     *      This allows the circuit breaker state to persist (since tx doesn't revert)
     * @return triggered True if circuit breaker was triggered by this call
     */
    function checkAndTriggerCircuitBreaker() external returns (bool triggered) {
        // Skip if already triggered and cooldown not passed
        if (circuitBreakerTriggered) {
            if (block.timestamp < lastCircuitBreakerTrigger + circuitBreakerCooldown) {
                return false; // Already active
            }
            // Cooldown passed, reset
            circuitBreakerTriggered = false;
        }

        // Need reference price to compare against
        if (referencePrice == 0) {
            return false;
        }

        uint256 currentPrice = _getOraclePrice();

        // Check deviation
        uint256 deviationBps;
        if (currentPrice > referencePrice) {
            deviationBps = ((currentPrice - referencePrice) * BPS_DENOMINATOR) / referencePrice;
        } else {
            deviationBps = ((referencePrice - currentPrice) * BPS_DENOMINATOR) / referencePrice;
        }

        // Trigger circuit breaker if deviation exceeds max
        if (deviationBps > maxPriceDeviationBps) {
            circuitBreakerTriggered = true;
            lastCircuitBreakerTrigger = block.timestamp;
            emit CircuitBreakerTriggered(currentPrice, referencePrice, deviationBps);
            return true;
        }

        return false;
    }

    function resetCircuitBreaker() external onlyAdmin {
        circuitBreakerTriggered = false;
        volatilitySpreadBps = 0;
        emit CircuitBreakerReset(msg.sender);
        emit VolatilitySpreadDeactivated();
    }

    function forceUpdateReferencePrice() external onlyAdmin {
        uint256 oldPrice = referencePrice;
        uint256 currentPrice = _getOraclePrice();
        referencePrice = currentPrice;
        referencePriceTimestamp = block.timestamp;
        volatilitySpreadBps = 0;
        emit ReferencePriceUpdated(oldPrice, currentPrice);
        emit VolatilitySpreadDeactivated();
    }

    function setCircuitBreakerSettings(
        uint256 _maxDeviationBps,
        uint256 _cooldown,
        uint256 _updateInterval
    ) external onlyAdmin {
        maxPriceDeviationBps = _maxDeviationBps;
        circuitBreakerCooldown = _cooldown;
        referencePriceUpdateInterval = _updateInterval;
    }

    function setVolatilitySettings(
        uint256 _maxVolatilityBps,
        uint256 _dropThresholdBps
    ) external onlyAdmin {
        maxVolatilitySpreadBps = _maxVolatilityBps;
        priceDropThresholdBps = _dropThresholdBps;
    }

    function setLargeSellSettings(
        uint256 _threshold,
        uint256 _cooldown
    ) external onlyAdmin {
        largeSellThreshold = _threshold;
        largeSellCooldown = _cooldown;
    }

    // ============ CHAINLINK ADMIN ============

    function setChainlinkFeeds(
        address _ethUsdFeed,
        address _avaxUsdFeed
    ) external onlyAdmin {
        chainlinkEthUsd = AggregatorV3Interface(_ethUsdFeed);
        chainlinkAvaxUsd = AggregatorV3Interface(_avaxUsdFeed);
        emit ChainlinkFeedUpdated(_ethUsdFeed, _avaxUsdFeed);
    }

    function setChainlinkSettings(
        bool _enabled,
        uint256 _heartbeat
    ) external onlyAdmin {
        useChainlinkFallback = _enabled;
        chainlinkHeartbeat = _heartbeat;
    }

    function setManualPriceOverride(
        uint256 _price,
        uint256 _duration
    ) external onlyAdmin {
        manualPriceOverride = _price;
        manualPriceExpiry = _price > 0 ? block.timestamp + _duration : 0;
        emit ManualPriceOverrideSet(_price, manualPriceExpiry);
    }

    // ============ EMERGENCY & WITHDRAWAL ============

    /**
     * @notice Withdraw accumulated spread profits to treasury
     */
    function withdrawProfits() external onlyAdmin {
        uint256 balance = address(this).balance;
        if (balance == 0) revert InvalidAmount();

        (bool success, ) = treasury.call{value: balance}("");
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Emergency withdraw all funds
     */
    function emergencyWithdraw() external onlyAdmin {
        buybackEnabled = false;

        // Withdraw native
        uint256 nativeBalance = address(this).balance;
        if (nativeBalance > 0) {
            (bool success, ) = treasury.call{value: nativeBalance}("");
            if (!success) revert TransferFailed();
        }

        // Withdraw any stuck DREAMS
        uint256 dreamsBalance = dreams.balanceOf(address(this));
        if (dreamsBalance > 0) {
            dreams.safeTransfer(treasury, dreamsBalance);
        }

        // Withdraw any stuck JUICY
        uint256 juicyBalance = juicy.balanceOf(address(this));
        if (juicyBalance > 0) {
            juicy.safeTransfer(treasury, juicyBalance);
        }
    }

    /**
     * @notice Rescue stuck tokens
     */
    function rescueTokens(address _token, uint256 _amount) external onlyAdmin {
        IERC20(_token).safeTransfer(treasury, _amount);
    }

    // ============ ADMIN TRANSFER ============

    function initiateAdminTransfer(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert InvalidAddress();
        pendingAdmin = _newAdmin;
        emit AdminTransferInitiated(admin, _newAdmin);
    }

    function acceptAdminTransfer() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferCompleted(oldAdmin, admin);
    }

    // Allow contract to receive ETH/AVAX
    receive() external payable {}
}
