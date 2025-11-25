// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPriceOracle
 * @dev Interface for getting token prices in USD
 * Used to convert ETH/AVAX to USD equivalent
 */
interface IPriceOracle {
    /**
     * @dev Returns the price of a token in USD (with 8 decimals)
     * @param token Address of the token
     * @return price Price in USD (e.g., 2000.00000000 for $2000)
     */
    function getPrice(address token) external view returns (uint256 price);

    /**
     * @dev Converts token amount to USD value
     * @param token Address of the token
     * @param amount Amount of tokens
     * @return usdValue USD value (with 18 decimals)
     */
    function convertToUSD(address token, uint256 amount) external view returns (uint256 usdValue);
}
