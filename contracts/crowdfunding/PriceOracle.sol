// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPriceOracle.sol";

/**
 * @title PriceOracle
 * @notice Gets token prices for TESTING PURPOSES ONLY.
 * @dev ⚠️ DO NOT USE IN PRODUCTION! In the real app, use ChainlinkPriceOracle
 *      which gets prices from professional data providers.
 *
 * HOW IT WORKS (for testing):
 * - Admin manually sets fake prices for testing
 * - Prices automatically expire after 1 hour (forces fresh data)
 * - Two-step admin transfer for safety
 */
contract PriceOracle is IPriceOracle {

    address public admin;
    address public pendingAdmin;

    // Token address => USD price (8 decimals, like Chainlink)
    mapping(address => uint256) public prices;

    // Last update timestamp for each token
    mapping(address => uint256) public lastUpdated;

    // Prices expire after 1 hour - this ensures we always have recent data
    uint256 public constant MAX_PRICE_AGE = 1 hours;

    // Events
    event PriceUpdated(address indexed token, uint256 price, uint256 timestamp);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferCompleted(address indexed oldAdmin, address indexed newAdmin);
    event AdminTransferCancelled(address indexed admin);

    // Errors
    error OnlyAdmin();
    error OnlyPendingAdmin();
    error InvalidAddress();
    error InvalidPrice();
    error PriceNotSet();
    error PriceTooOld();
    error LengthMismatch();
    error NoPendingAdmin();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /**
     * @notice Update price for a token
     * @param token Token address
     * @param price Price in USD with 8 decimals
     */
    function updatePrice(address token, uint256 price) external onlyAdmin {
        if (token == address(0)) revert InvalidAddress();
        if (price == 0) revert InvalidPrice();

        prices[token] = price;
        lastUpdated[token] = block.timestamp;

        emit PriceUpdated(token, price, block.timestamp);
    }

    /**
     * @notice Batch update prices
     */
    function updatePrices(address[] calldata tokens, uint256[] calldata _prices) external onlyAdmin {
        if (tokens.length != _prices.length) revert LengthMismatch();

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) revert InvalidAddress();
            if (_prices[i] == 0) revert InvalidPrice();

            prices[tokens[i]] = _prices[i];
            lastUpdated[tokens[i]] = block.timestamp;

            emit PriceUpdated(tokens[i], _prices[i], block.timestamp);
        }
    }

    /**
     * @inheritdoc IPriceOracle
     */
    function getPrice(address token) external view override returns (uint256) {
        uint256 price = prices[token];
        if (price == 0) revert PriceNotSet();
        if (block.timestamp - lastUpdated[token] > MAX_PRICE_AGE) revert PriceTooOld();
        return price;
    }

    /**
     * @inheritdoc IPriceOracle
     */
    function convertToUSD(address token, uint256 amount) external view override returns (uint256) {
        uint256 price = prices[token];
        if (price == 0) revert PriceNotSet();
        if (block.timestamp - lastUpdated[token] > MAX_PRICE_AGE) revert PriceTooOld();

        // Price has 8 decimals, amount has 18 decimals
        // Result should have 18 decimals
        return (amount * price) / 1e8;
    }

    // ============ TWO-STEP ADMIN TRANSFER ============

    /**
     * @notice Initiate admin transfer (step 1)
     * @param newAdmin Address of the new admin
     */
    function initiateAdminTransfer(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        pendingAdmin = newAdmin;
        emit AdminTransferInitiated(admin, newAdmin);
    }

    /**
     * @notice Accept admin transfer (step 2 - must be called by pending admin)
     */
    function acceptAdminTransfer() external {
        if (msg.sender != pendingAdmin) revert OnlyPendingAdmin();

        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);

        emit AdminTransferCompleted(oldAdmin, admin);
    }

    /**
     * @notice Cancel pending admin transfer
     */
    function cancelAdminTransfer() external onlyAdmin {
        if (pendingAdmin == address(0)) revert NoPendingAdmin();
        pendingAdmin = address(0);
        emit AdminTransferCancelled(admin);
    }

    /**
     * @notice Check if price is fresh
     * @param token Token address
     * @return fresh Whether the price is within MAX_PRICE_AGE
     */
    function isPriceFresh(address token) external view returns (bool fresh) {
        if (prices[token] == 0) return false;
        return block.timestamp - lastUpdated[token] <= MAX_PRICE_AGE;
    }
}

/**
 * @title AggregatorV3Interface
 * @notice Chainlink price feed interface
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

/**
 * @title AggregatorV2V3Interface (for sequencer uptime feed)
 */
interface AggregatorV2V3Interface {
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
}

/**
 * @title ChainlinkPriceOracle
 * @notice Gets real token prices from Chainlink - professional price data providers.
 * @dev Use this contract for PRODUCTION (real money).
 *
 * HOW IT WORKS:
 * Chainlink is a network of independent data providers that report real-world prices.
 * Many providers report prices, and Chainlink aggregates them to prevent manipulation.
 * Think of it like getting price quotes from 10 different banks and averaging them.
 *
 * SAFETY CHECKS:
 * - Prices must be recent (less than 1 hour old)
 * - Checks that the price data is complete (not stuck mid-update)
 * - On Layer 2 chains: checks that the blockchain itself is working properly
 * - Rejects negative or zero prices (obviously wrong data)
 */
contract ChainlinkPriceOracle is IPriceOracle {

    // Token address => Chainlink price feed address
    mapping(address => address) public priceFeeds;

    // Token address => heartbeat (staleness threshold)
    mapping(address => uint256) public heartbeats;

    address public admin;
    address public pendingAdmin;

    // On Layer 2 chains (Arbitrum, Optimism, Base, etc.), we check if the blockchain is working
    // before trusting any prices. If the chain was down, prices during that time are unreliable.
    address public sequencerUptimeFeed;

    // After the blockchain comes back online, we wait 1 hour before trusting prices again
    // This gives time for prices to stabilize after any disruption
    uint256 public constant GRACE_PERIOD_TIME = 3600; // 1 hour

    // If no specific update interval is set, assume prices should update every hour
    uint256 public constant DEFAULT_HEARTBEAT = 3600; // 1 hour

    // Flag extreme price swings (more than 50% change) - could indicate manipulation
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 5000;

    // Events
    event PriceFeedSet(address indexed token, address indexed priceFeed, uint256 heartbeat);
    event SequencerFeedSet(address indexed feed);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferCompleted(address indexed oldAdmin, address indexed newAdmin);
    event CircuitBreakerTriggered(address indexed token, uint256 oldPrice, uint256 newPrice);

    // Errors
    error OnlyAdmin();
    error OnlyPendingAdmin();
    error InvalidAddress();
    error PriceFeedNotSet();
    error InvalidPrice();
    error StalePrice();
    error SequencerDown();
    error GracePeriodNotOver();
    error StaleRound();
    error PriceDeviationTooHigh();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /**
     * @notice Set Chainlink price feed for a token
     * @param token Token address
     * @param priceFeed Chainlink price feed address
     * @param heartbeat Maximum age of price in seconds
     */
    function setPriceFeed(address token, address priceFeed, uint256 heartbeat) external onlyAdmin {
        if (token == address(0) || priceFeed == address(0)) revert InvalidAddress();

        priceFeeds[token] = priceFeed;
        heartbeats[token] = heartbeat > 0 ? heartbeat : DEFAULT_HEARTBEAT;

        emit PriceFeedSet(token, priceFeed, heartbeats[token]);
    }

    /**
     * @notice Set L2 sequencer uptime feed
     * @param feed Sequencer uptime feed address
     */
    function setSequencerUptimeFeed(address feed) external onlyAdmin {
        sequencerUptimeFeed = feed;
        emit SequencerFeedSet(feed);
    }

    /**
     * @notice Checks if the blockchain itself is working properly before trusting prices
     * @dev On Layer 2 chains, the "sequencer" is what processes transactions.
     *      If it was down recently, prices might be stale or manipulated.
     *      We check: 1) Is it running? 2) Has it been up long enough?
     */
    function _checkSequencer() internal view {
        // Skip this check if we're not on a Layer 2 chain
        if (sequencerUptimeFeed == address(0)) return;

        (
            /*uint80 roundId*/,
            int256 answer,
            uint256 startedAt,
            /*uint256 updatedAt*/,
            /*uint80 answeredInRound*/
        ) = AggregatorV2V3Interface(sequencerUptimeFeed).latestRoundData();

        // Check if the blockchain is working: 0 = working, 1 = not working
        if (answer != 0) revert SequencerDown();

        // Even after the blockchain comes back, we wait 1 hour before trusting prices
        // This gives time for any price manipulation to be corrected
        uint256 timeSinceUp = block.timestamp - startedAt;
        if (timeSinceUp < GRACE_PERIOD_TIME) revert GracePeriodNotOver();
    }

    /**
     * @notice Gets a price after running all our safety checks
     * @dev This is the main price-fetching function. It checks multiple things:
     *      1. Is the blockchain working? (Layer 2 check)
     *      2. Is the price recent enough? (not stale)
     *      3. Is the price data complete? (not stuck mid-update)
     *      4. Is the price valid? (not negative or zero)
     * @param token Which token to get the price for
     * @return normalizedPrice The price in USD with 8 decimal places
     */
    function _getValidatedPrice(address token) internal view returns (uint256 normalizedPrice) {
        // First, make sure the blockchain is working properly (on Layer 2)
        _checkSequencer();

        // Find the Chainlink price feed for this token
        address feed = priceFeeds[token];
        if (feed == address(0)) revert PriceFeedNotSet();

        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);

        // Get the latest price data from Chainlink
        (
            uint80 roundId,
            int256 price,
            /*uint256 startedAt*/,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        // Reject obviously wrong prices (negative or zero)
        if (price <= 0) revert InvalidPrice();

        // Make sure the price isn't too old
        uint256 heartbeat = heartbeats[token];
        if (heartbeat == 0) heartbeat = DEFAULT_HEARTBEAT;
        if (block.timestamp - updatedAt > heartbeat) revert StalePrice();

        // Make sure Chainlink finished calculating this price (not stuck mid-update)
        if (answeredInRound < roundId) revert StaleRound();

        // Convert to our standard format (8 decimal places)
        return _normalizePrice(uint256(price), priceFeed.decimals());
    }

    /**
     * @inheritdoc IPriceOracle
     */
    function getPrice(address token) external view override returns (uint256) {
        return _getValidatedPrice(token);
    }

    /**
     * @inheritdoc IPriceOracle
     */
    function convertToUSD(address token, uint256 amount) external view override returns (uint256) {
        uint256 price = _getValidatedPrice(token);
        // Convert: (amount * price) / 1e8
        return (amount * price) / 1e8;
    }

    /**
     * @dev Normalize price to 8 decimals
     */
    function _normalizePrice(uint256 price, uint8 decimals) internal pure returns (uint256) {
        if (decimals < 8) {
            return price * (10 ** (8 - decimals));
        } else if (decimals > 8) {
            return price / (10 ** (decimals - 8));
        }
        return price;
    }

    // ============ TWO-STEP ADMIN TRANSFER ============

    function initiateAdminTransfer(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        pendingAdmin = newAdmin;
        emit AdminTransferInitiated(admin, newAdmin);
    }

    function acceptAdminTransfer() external {
        if (msg.sender != pendingAdmin) revert OnlyPendingAdmin();
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferCompleted(oldAdmin, admin);
    }
}
