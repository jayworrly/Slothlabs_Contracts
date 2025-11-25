// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPriceOracle.sol";

interface ISlothPriceOracle is IPriceOracle {
    function setTokenOracle(address token, address oracle) external;
}
