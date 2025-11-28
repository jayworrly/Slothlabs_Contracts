// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockDexRouter
 * @notice Mock contract for testing DreamsTreasurySale
 * @dev Implements both Uniswap V3 and Trader Joe interfaces for testing
 */
contract MockDexRouter {
    address public weth;
    address public juicy;
    address public dreams;

    // Exchange rate: 1 ETH/AVAX = 1000 JUICY (for testing)
    uint256 public constant NATIVE_TO_JUICY_RATE = 1000;
    // Exchange rate: 1 JUICY = 7.5 DREAMS (for testing)
    uint256 public constant JUICY_TO_DREAMS_RATE = 75; // Divided by 10

    // Track last swap for event verification
    uint256 public lastJuicyOutput;
    uint256 public lastDreamsOutput;

    constructor(address _weth, address _juicy, address _dreams) {
        weth = _weth;
        juicy = _juicy;
        dreams = _dreams;
    }

    // ============ Uniswap V3 Interface ============

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /**
     * @notice Mock Uniswap V3 exactInputSingle
     * @dev Simulates WETH → JUICY swap OR JUICY → DREAMS swap
     */
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        // Handle WETH → JUICY swap
        if (params.tokenIn == weth && params.tokenOut == juicy) {
            // Transfer WETH from sender (the contract has already wrapped ETH)
            IERC20(weth).transferFrom(msg.sender, address(this), params.amountIn);

            // Calculate output: 1 ETH = 1000 JUICY
            amountOut = params.amountIn * NATIVE_TO_JUICY_RATE;
            lastJuicyOutput = amountOut;

            // Transfer JUICY to recipient
            IERC20(juicy).transfer(params.recipient, amountOut);
        }
        // Handle JUICY → DREAMS swap (for buyback loop)
        else if (params.tokenIn == juicy && params.tokenOut == dreams) {
            // Transfer JUICY from sender
            IERC20(juicy).transferFrom(msg.sender, address(this), params.amountIn);

            // Calculate output: 1 JUICY = 7.5 DREAMS
            amountOut = (params.amountIn * JUICY_TO_DREAMS_RATE) / 10;
            lastDreamsOutput = amountOut;

            // Transfer DREAMS to recipient
            IERC20(dreams).transfer(params.recipient, amountOut);
        }
        else {
            revert("Invalid swap path");
        }

        return amountOut;
    }

    // ============ Trader Joe Interface ============

    /**
     * @notice Mock Trader Joe swapExactAVAXForTokens
     * @dev Simulates AVAX → JUICY swap
     */
    function swapExactAVAXForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "Expired");
        require(path.length == 2, "Invalid path");
        require(path[0] == weth, "First token must be WAVAX");
        require(path[1] == juicy, "Second token must be JUICY");

        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = msg.value * NATIVE_TO_JUICY_RATE;

        require(amounts[1] >= amountOutMin, "Insufficient output");
        lastJuicyOutput = amounts[1];

        // Transfer JUICY to recipient
        IERC20(juicy).transfer(to, amounts[1]);

        return amounts;
    }

    /**
     * @notice Mock Trader Joe swapExactTokensForTokens
     * @dev Simulates JUICY → DREAMS swap OR DREAMS → JUICY swap
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "Expired");
        require(path.length == 2, "Invalid path");

        amounts = new uint256[](2);
        amounts[0] = amountIn;

        if (path[0] == juicy && path[1] == dreams) {
            // JUICY → DREAMS: 1 JUICY = 7.5 DREAMS
            amounts[1] = (amountIn * JUICY_TO_DREAMS_RATE) / 10;
            lastDreamsOutput = amounts[1];
        } else if (path[0] == dreams && path[1] == juicy) {
            // DREAMS → JUICY: 7.5 DREAMS = 1 JUICY (reverse)
            amounts[1] = (amountIn * 10) / JUICY_TO_DREAMS_RATE;
            lastJuicyOutput = amounts[1];
        } else {
            revert("Invalid path");
        }

        require(amounts[1] >= amountOutMin, "Insufficient output");

        // Transfer tokens
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path[1]).transfer(to, amounts[1]);

        return amounts;
    }

    /**
     * @notice Mock Trader Joe swapExactTokensForAVAX
     * @dev Simulates JUICY → AVAX swap (for buyback)
     */
    function swapExactTokensForAVAX(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "Expired");
        require(path.length == 2, "Invalid path");
        require(path[0] == juicy, "First token must be JUICY");
        require(path[1] == weth, "Second token must be WAVAX");

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        // JUICY → AVAX: 1000 JUICY = 1 AVAX (reverse of NATIVE_TO_JUICY_RATE)
        amounts[1] = amountIn / NATIVE_TO_JUICY_RATE;

        require(amounts[1] >= amountOutMin, "Insufficient output");

        // Transfer JUICY from sender
        IERC20(juicy).transferFrom(msg.sender, address(this), amountIn);

        // Send AVAX to recipient
        (bool success, ) = to.call{value: amounts[1]}("");
        require(success, "AVAX transfer failed");

        return amounts;
    }

    /**
     * @notice Mock Trader Joe getAmountsOut
     * @dev Returns expected output amounts for a swap path (supports both directions)
     */
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < path.length - 1; i++) {
            if (path[i] == weth && path[i + 1] == juicy) {
                // WETH/WAVAX → JUICY
                amounts[i + 1] = amounts[i] * NATIVE_TO_JUICY_RATE;
            } else if (path[i] == juicy && path[i + 1] == weth) {
                // JUICY → WETH/WAVAX (reverse)
                amounts[i + 1] = amounts[i] / NATIVE_TO_JUICY_RATE;
            } else if (path[i] == juicy && path[i + 1] == dreams) {
                // JUICY → DREAMS
                amounts[i + 1] = (amounts[i] * JUICY_TO_DREAMS_RATE) / 10;
            } else if (path[i] == dreams && path[i + 1] == juicy) {
                // DREAMS → JUICY (reverse)
                amounts[i + 1] = (amounts[i] * 10) / JUICY_TO_DREAMS_RATE;
            } else {
                revert("Unknown pair");
            }
        }

        return amounts;
    }

    // ============ Helper Functions ============

    /**
     * @notice Fund this contract with tokens for testing
     */
    receive() external payable {}

    /**
     * @notice Withdraw stuck tokens (for testing cleanup)
     */
    function withdraw(address token, uint256 amount) external {
        IERC20(token).transfer(msg.sender, amount);
    }
}
