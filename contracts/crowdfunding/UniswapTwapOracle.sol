// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPriceOracle.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "./PriceOracle.sol"; // For AggregatorV3Interface
import "./OracleLibrary.sol"; // For TWAP calculations

/**
 * @title UniswapTwapOracle
 * @notice Gets the current price of DREAMS tokens in US dollars.
 *
 * HOW IT WORKS:
 * Instead of trusting a single price source, this contract looks at what price people
 * are actually trading at on decentralized exchanges over the past 30 minutes.
 * This "average over time" approach (called TWAP) makes it very hard to manipulate the price.
 *
 * THE PRICE CALCULATION PATH:
 * 1. Check DREAMS-to-JUICY trading price on Uniswap
 * 2. Check JUICY-to-ETH trading price on Uniswap
 * 3. Get ETH-to-USD price from Chainlink (professional price feeds)
 * 4. Multiply them together to get DREAMS price in USD
 *
 * EXAMPLE: If 1 DREAMS = 0.5 JUICY, 1 JUICY = 0.001 ETH, and 1 ETH = $2000
 *          Then 1 DREAMS = 0.5 × 0.001 × $2000 = $1.00
 */
contract UniswapTwapOracle is IPriceOracle {
    address public admin;

    IUniswapV3Pool public immutable dreamsJuicyPool;
    IUniswapV3Pool public immutable juicyEthPool;
    address public immutable dreamsToken;
    address public immutable juicyToken;
    address public immutable wethToken;
    IPriceOracle public immutable chainlinkOracle;
    uint32 public immutable twapPeriod;

    // Errors
    error OnlyAdmin();
    error InvalidAddress();
    error InvalidTwapPeriod();
    error PoolTokensMismatch();
    error InvalidTwapResult();
    error InvalidToken();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor(
        address _dreamsJuicyPool,
        address _juicyEthPool,
        address _dreamsToken,
        address _juicyToken,
        address _wethToken,
        address _chainlinkOracle,
        uint32 _twapPeriod
    ) {
        if (_dreamsJuicyPool == address(0) || _juicyEthPool == address(0) || _dreamsToken == address(0) || _juicyToken == address(0) || _wethToken == address(0) || _chainlinkOracle == address(0)) {
            revert InvalidAddress();
        }
        if (_twapPeriod == 0) revert InvalidTwapPeriod();

        dreamsJuicyPool = IUniswapV3Pool(_dreamsJuicyPool);
        juicyEthPool = IUniswapV3Pool(_juicyEthPool);
        dreamsToken = _dreamsToken;
        juicyToken = _juicyToken;
        wethToken = _wethToken;
        chainlinkOracle = IPriceOracle(_chainlinkOracle);
        twapPeriod = _twapPeriod;
        admin = msg.sender;

        // Verify pool tokens
        if (!((dreamsJuicyPool.token0() == _dreamsToken && dreamsJuicyPool.token1() == _juicyToken) || (dreamsJuicyPool.token0() == _juicyToken && dreamsJuicyPool.token1() == _dreamsToken))) {
            revert PoolTokensMismatch();
        }
        if (!((juicyEthPool.token0() == _juicyToken && juicyEthPool.token1() == _wethToken) || (juicyEthPool.token0() == _wethToken && juicyEthPool.token1() == _juicyToken))) {
            revert PoolTokensMismatch();
        }
    }

    /**
     * @notice Gets the average trading price over the last 30 minutes
     * @dev Uses Uniswap's built-in price history to calculate a manipulation-resistant average.
     *      This is like checking the average sale price of a house over the last month
     *      instead of just the last sale - much harder to fake!
     * @param _pool The trading pool to check
     * @param _tokenIn The token we want to know the price of
     * @param _tokenOut The token we're comparing against
     * @return The average price (how much _tokenOut you get for 1 _tokenIn)
     */
    function getTwapPrice(IUniswapV3Pool _pool, address _tokenIn, address _tokenOut) internal view returns (uint256) {
        // Look at the average trading activity over the TWAP period
        (int24 arithmeticMeanTick, ) = OracleLibrary.consult(address(_pool), twapPeriod);

        // Convert the tick value to an actual price
        // (Uniswap uses "ticks" internally - this converts to a normal number)
        uint256 quoteAmount = OracleLibrary.getQuoteAtTick(
            arithmeticMeanTick,
            uint128(1e18), // Check price for 1 whole token
            _tokenIn,
            _tokenOut
        );

        return quoteAmount;
    }

    function getPrice(address _token) external view override returns (uint256) {
        return _getPrice(_token);
    }

    function _getPrice(address _token) internal view returns (uint256) {
        // This oracle only provides prices for DREAMS tokens
        if (_token != dreamsToken) revert InvalidToken();

        // Step 1: How many JUICY tokens can you get for 1 DREAMS?
        uint256 dreamsPerJuicy = getTwapPrice(dreamsJuicyPool, dreamsToken, juicyToken);

        // Step 2: How much ETH can you get for 1 JUICY?
        uint256 juicyPerEth = getTwapPrice(juicyEthPool, juicyToken, wethToken);

        // Step 3: How many USD is 1 ETH worth? (from professional Chainlink price feed)
        uint256 ethInUsd = chainlinkOracle.getPrice(wethToken);

        // Step 4: Chain them together to get DREAMS price in USD
        // Example: 0.5 JUICY × 0.001 ETH × $2000 = $1.00
        uint256 dreamsInUsd = (((dreamsPerJuicy * juicyPerEth) / 1e18) * ethInUsd) / 1e18;
        return dreamsInUsd;
    }

    function convertToUSD(address _token, uint256 _amount) external view override returns (uint256) {
        uint256 price = _getPrice(_token); // 8 decimals
        return (_amount * price) / 1e8;
    }

    /**
     * @notice Checks if we have enough trading history to calculate a reliable price
     * @dev The pool needs at least 30 minutes of price data to compute a TWAP.
     *      If a pool is brand new, this will return false until enough trades happen.
     * @param _pool The trading pool to check
     * @return True if the pool has enough history, false if it's too new
     */
    function hasSufficientHistory(address _pool) external view returns (bool) {
        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(_pool);
        return oldestObservation >= twapPeriod;
    }

    /**
     * @notice How old is the oldest price record we can see?
     * @dev Useful for debugging - if this returns less than 1800 (30 min),
     *      the TWAP calculation may not be accurate yet.
     * @param _pool The trading pool to check
     * @return secondsAgo How many seconds of price history is available
     */
    function getOldestObservation(address _pool) external view returns (uint32) {
        return OracleLibrary.getOldestObservationSecondsAgo(_pool);
    }
}
