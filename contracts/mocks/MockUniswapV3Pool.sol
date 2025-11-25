// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockUniswapV3Pool
 * @notice Mock contract for testing UniswapTwapOracle
 * @dev Implements minimal IUniswapV3Pool interface needed for testing
 */
contract MockUniswapV3Pool {
    address public token0;
    address public token1;

    // Current tick (determines price ratio)
    int24 public currentTick;

    // For slot0 mock
    uint16 public observationIndex = 0;
    uint16 public observationCardinality = 100;

    // For observations mock
    mapping(uint256 => Observation) public observations;

    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        uint160 secondsPerLiquidityCumulativeX128;
        bool initialized;
    }

    constructor(address _token0, address _token1) {
        // Ensure token0 < token1 (standard Uniswap ordering)
        if (_token0 < _token1) {
            token0 = _token0;
            token1 = _token1;
        } else {
            token0 = _token1;
            token1 = _token0;
        }

        // Default tick representing 1:1 price (tick 0)
        currentTick = 0;

        // Initialize first observation
        observations[0] = Observation({
            blockTimestamp: uint32(block.timestamp),
            tickCumulative: 0,
            secondsPerLiquidityCumulativeX128: 0,
            initialized: true
        });
    }

    /**
     * @notice Set the current tick (price)
     * @dev tick = log_1.0001(price)
     *      tick 0 = price 1.0
     *      tick -6931 ≈ price 0.5 (1 DREAMS = 0.5 JUICY)
     *      tick -69315 ≈ price 0.001 (1 JUICY = 0.001 ETH)
     */
    function setTick(int24 _tick) external {
        currentTick = _tick;
    }

    /**
     * @notice Mock slot0 function
     */
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIdx,
            uint16 observationCardinality_,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (0, currentTick, observationIndex, observationCardinality, observationCardinality, 0, true);
    }

    /**
     * @notice Mock observe function - returns tick cumulatives for TWAP calculation
     * @dev Simulates constant tick over the observation period
     */
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);

        uint32 currentTime = uint32(block.timestamp);

        for (uint256 i = 0; i < secondsAgos.length; i++) {
            // Calculate tick cumulative at the given time
            // Assuming constant tick over time: tickCumulative = tick * time
            uint32 targetTime = currentTime - secondsAgos[i];
            // Tick cumulative at target time
            tickCumulatives[i] = int56(currentTick) * int56(int32(targetTime));
            secondsPerLiquidityCumulativeX128s[i] = uint160(targetTime) << 32;
        }

        return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
    }

    /**
     * @notice Mock liquidity function
     */
    function liquidity() external pure returns (uint128) {
        return 1e18;
    }
}
