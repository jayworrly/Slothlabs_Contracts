// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPriceOracle.sol";

/**
 * @title MockPriceOracle
 * @notice Mock price oracle for testing
 */
contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public prices;  // 8 decimals
    mapping(address => bool) public priceSet;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
        priceSet[token] = true;
    }

    function getPrice(address token) external view override returns (uint256) {
        require(priceSet[token], "Price not set");
        return prices[token];
    }

    function convertToUSD(address token, uint256 amount) external view override returns (uint256) {
        require(priceSet[token], "Price not set");
        // Price has 8 decimals, amount has 18 decimals
        // Result should have 18 decimals
        return (amount * prices[token]) / 1e8;
    }
}
