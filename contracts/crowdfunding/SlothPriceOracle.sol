// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/ISlothPriceOracle.sol";
import "../libraries/ReentrancyGuard.sol";

/**
 * @title SlothPriceOracle
 * @notice A composite oracle that can route price queries to the correct underlying oracle for a given token.
 * @dev This allows the system to use Chainlink for some tokens and other oracles (e.g., Uniswap TWAP) for others.
 */
contract SlothPriceOracle is ISlothPriceOracle, ReentrancyGuard {
    address public admin;
    address public pendingAdmin;

    // Mapping from a token address to its designated price oracle
    mapping(address => IPriceOracle) public tokenOracles;

    // Events
    event TokenOracleSet(address indexed token, address indexed oracle);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferCompleted(address indexed oldAdmin, address indexed newAdmin);

    // Errors
    error OnlyAdmin();
    error OnlyPendingAdmin();
    error InvalidAddress();
    error OracleNotSetForToken();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /**
     * @notice Sets the oracle contract to be used for a specific token.
     * @param _token The address of the token.
     * @param _oracle The address of the IPriceOracle compliant contract for that token.
     */
    function setTokenOracle(address _token, address _oracle) external onlyAdmin {
        if (_token == address(0) || _oracle == address(0)) revert InvalidAddress();
        tokenOracles[_token] = IPriceOracle(_oracle);
        emit TokenOracleSet(_token, _oracle);
    }

    /**
     * @inheritdoc IPriceOracle
     */
    function getPrice(address _token) external view override returns (uint256) {
        IPriceOracle oracle = tokenOracles[_token];
        if (address(oracle) == address(0)) revert OracleNotSetForToken();

        return oracle.getPrice(_token);
    }

    /**
     * @inheritdoc IPriceOracle
     */
    function convertToUSD(address _token, uint256 _amount) external view override returns (uint256) {
        IPriceOracle oracle = tokenOracles[_token];
        if (address(oracle) == address(0)) revert OracleNotSetForToken();

        return oracle.convertToUSD(_token, _amount);
    }

    // ============ TWO-STEP ADMIN TRANSFER ============

    function initiateAdminTransfer(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert InvalidAddress();
        pendingAdmin = _newAdmin;
        emit AdminTransferInitiated(admin, _newAdmin);
    }

    function acceptAdminTransfer() external {
        if (msg.sender != pendingAdmin) revert OnlyPendingAdmin();

        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);

        emit AdminTransferCompleted(oldAdmin, admin);
    }
}
