// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IzDREAMS.sol";

/**
 * @title CloudBoost
 * @notice Spend zDREAMS to boost dream cloud sizes in the UI
 *
 * HOW CLOUD BOOSTING WORKS:
 * 1. Users stake DREAMS tokens and receive zDREAMS (staking receipt token)
 * 2. zDREAMS can be spent to "boost" dream clouds, making them larger in the UI
 * 3. Larger clouds = more visibility = more engagement
 * 4. zDREAMS spent on boosts is burned permanently (deflationary)
 *
 * BOOST TIERS:
 * - Spark (1 zDREAMS): +5% cloud size
 * - Glow (5 zDREAMS): +15% cloud size
 * - Blaze (20 zDREAMS): +40% cloud size
 * - Supernova (100 zDREAMS): +100% cloud size (2x!)
 *
 * BOOST MECHANICS:
 * - Boosts stack additively up to a maximum multiplier
 * - Boosts decay over time (7-day half-life)
 * - Off-chain system reads boost data and applies to cloud rendering
 */
contract CloudBoost is ReentrancyGuard {
    // ============ STATE ============

    IzDREAMS public zDreamsToken;
    address public admin;
    address public pendingAdmin;

    /// @notice Maximum boost multiplier (500% = 5x original size)
    uint256 public constant MAX_BOOST_MULTIPLIER = 500;

    /// @notice Boost decay half-life in seconds (7 days)
    uint256 public constant BOOST_HALF_LIFE = 7 days;

    /// @notice Boost tier definitions
    struct BoostTier {
        uint256 cost;       // zDREAMS required
        uint256 sizeBoost;  // Size boost percentage (e.g., 15 = +15%)
    }

    /// @notice Available boost tiers
    BoostTier[] public boostTiers;

    /// @notice Boost data for each dream
    struct DreamBoost {
        uint256 totalBoostPoints;  // Raw boost points accumulated
        uint256 lastBoostTime;     // Last time boost was applied
        uint256 totalSpent;        // Total zDREAMS spent on this dream
    }

    /// @notice Dream ID -> Boost data
    mapping(string => DreamBoost) public dreamBoosts;

    /// @notice User stats for boosts given
    struct UserBoostStats {
        uint256 totalBoostsGiven;   // Number of boosts
        uint256 totalZDreamsSpent;  // Total zDREAMS spent on boosts
    }

    mapping(address => UserBoostStats) public userStats;

    /// @notice Total zDREAMS burned across all boosts
    uint256 public totalBurned;

    // ============ EVENTS ============

    event DreamBoosted(
        address indexed booster,
        string indexed dreamId,
        uint256 tierIndex,
        uint256 zDreamsSpent,
        uint256 newBoostPoints
    );
    event BoostTierAdded(uint256 indexed tierIndex, uint256 cost, uint256 sizeBoost);
    event BoostTierUpdated(uint256 indexed tierIndex, uint256 cost, uint256 sizeBoost);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferCompleted(address indexed oldAdmin, address indexed newAdmin);

    // ============ ERRORS ============

    error OnlyAdmin();
    error NotPendingAdmin();
    error InvalidAddress();
    error InvalidTier();
    error InvalidAmount();
    error InsufficientZDreams();

    // ============ MODIFIERS ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor(address _zDreamsToken) {
        if (_zDreamsToken == address(0)) revert InvalidAddress();

        zDreamsToken = IzDREAMS(_zDreamsToken);
        admin = msg.sender;

        // Initialize default boost tiers
        boostTiers.push(BoostTier({ cost: 1 ether, sizeBoost: 5 }));    // Spark: 1 zDREAMS = +5%
        boostTiers.push(BoostTier({ cost: 5 ether, sizeBoost: 15 }));   // Glow: 5 zDREAMS = +15%
        boostTiers.push(BoostTier({ cost: 20 ether, sizeBoost: 40 }));  // Blaze: 20 zDREAMS = +40%
        boostTiers.push(BoostTier({ cost: 100 ether, sizeBoost: 100 })); // Supernova: 100 zDREAMS = +100%
    }

    // ============ BOOST FUNCTIONS ============

    /**
     * @notice Boost a dream cloud by spending zDREAMS
     * @param _dreamId The dream to boost
     * @param _tierIndex Which boost tier to use (0-3)
     */
    function boostDream(string calldata _dreamId, uint256 _tierIndex) external nonReentrant {
        if (_tierIndex >= boostTiers.length) revert InvalidTier();
        if (bytes(_dreamId).length == 0) revert InvalidAmount();

        BoostTier storage tier = boostTiers[_tierIndex];

        // Check user has enough zDREAMS
        if (zDreamsToken.balanceOf(msg.sender) < tier.cost) revert InsufficientZDreams();

        // Burn zDREAMS for the boost
        zDreamsToken.burnForBoost(msg.sender, tier.cost, _dreamId);

        // Update dream boost data
        DreamBoost storage boost = dreamBoosts[_dreamId];

        // Apply decay to existing boost before adding new points
        uint256 currentEffectiveBoost = getEffectiveBoost(_dreamId);

        // Add new boost points
        boost.totalBoostPoints = currentEffectiveBoost + tier.sizeBoost;
        boost.lastBoostTime = block.timestamp;
        boost.totalSpent += tier.cost;

        // Cap at max multiplier
        if (boost.totalBoostPoints > MAX_BOOST_MULTIPLIER) {
            boost.totalBoostPoints = MAX_BOOST_MULTIPLIER;
        }

        // Update user stats
        userStats[msg.sender].totalBoostsGiven += 1;
        userStats[msg.sender].totalZDreamsSpent += tier.cost;

        // Update global stats
        totalBurned += tier.cost;

        emit DreamBoosted(msg.sender, _dreamId, _tierIndex, tier.cost, boost.totalBoostPoints);
    }

    /**
     * @notice Boost with multiple tiers at once
     * @param _dreamId The dream to boost
     * @param _tierIndices Array of tier indices
     * @param _counts Array of counts for each tier
     */
    function boostDreamMultiple(
        string calldata _dreamId,
        uint256[] calldata _tierIndices,
        uint256[] calldata _counts
    ) external nonReentrant {
        if (bytes(_dreamId).length == 0) revert InvalidAmount();
        if (_tierIndices.length != _counts.length) revert InvalidAmount();

        uint256 totalCost = 0;
        uint256 totalSizeBoost = 0;

        // Calculate totals
        for (uint256 i = 0; i < _tierIndices.length; i++) {
            if (_tierIndices[i] >= boostTiers.length) revert InvalidTier();
            if (_counts[i] == 0) continue;

            BoostTier storage tier = boostTiers[_tierIndices[i]];
            totalCost += tier.cost * _counts[i];
            totalSizeBoost += tier.sizeBoost * _counts[i];
        }

        if (totalCost == 0) revert InvalidAmount();

        // Check user has enough zDREAMS
        if (zDreamsToken.balanceOf(msg.sender) < totalCost) revert InsufficientZDreams();

        // Burn zDREAMS
        zDreamsToken.burnForBoost(msg.sender, totalCost, _dreamId);

        // Update dream boost data
        DreamBoost storage boost = dreamBoosts[_dreamId];
        uint256 currentEffectiveBoost = getEffectiveBoost(_dreamId);

        boost.totalBoostPoints = currentEffectiveBoost + totalSizeBoost;
        boost.lastBoostTime = block.timestamp;
        boost.totalSpent += totalCost;

        // Cap at max multiplier
        if (boost.totalBoostPoints > MAX_BOOST_MULTIPLIER) {
            boost.totalBoostPoints = MAX_BOOST_MULTIPLIER;
        }

        // Update stats
        userStats[msg.sender].totalBoostsGiven += 1;
        userStats[msg.sender].totalZDreamsSpent += totalCost;
        totalBurned += totalCost;

        emit DreamBoosted(msg.sender, _dreamId, type(uint256).max, totalCost, boost.totalBoostPoints);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get the effective boost percentage for a dream (after decay)
     * @param _dreamId The dream to check
     * @return Effective boost percentage (e.g., 50 = +50% size)
     */
    function getEffectiveBoost(string calldata _dreamId) public view returns (uint256) {
        DreamBoost storage boost = dreamBoosts[_dreamId];

        if (boost.totalBoostPoints == 0 || boost.lastBoostTime == 0) {
            return 0;
        }

        uint256 elapsed = block.timestamp - boost.lastBoostTime;

        // Apply exponential decay with half-life
        // After 7 days: 50% remains
        // After 14 days: 25% remains
        // After 21 days: 12.5% remains
        if (elapsed >= BOOST_HALF_LIFE * 5) {
            // After 5 half-lives, boost is essentially zero
            return 0;
        }

        // Calculate decay using integer math approximation
        // decay_factor = 0.5 ^ (elapsed / half_life)
        uint256 halfLives = elapsed / BOOST_HALF_LIFE;
        uint256 remainder = elapsed % BOOST_HALF_LIFE;

        uint256 effectiveBoost = boost.totalBoostPoints;

        // Apply full half-lives
        for (uint256 i = 0; i < halfLives && effectiveBoost > 0; i++) {
            effectiveBoost = effectiveBoost / 2;
        }

        // Apply partial decay for remainder (linear approximation)
        if (remainder > 0 && effectiveBoost > 0) {
            uint256 partialDecay = (effectiveBoost * remainder) / (BOOST_HALF_LIFE * 2);
            effectiveBoost = effectiveBoost > partialDecay ? effectiveBoost - partialDecay : 0;
        }

        return effectiveBoost;
    }

    /**
     * @notice Get the cloud size multiplier for a dream
     * @param _dreamId The dream to check
     * @return Size multiplier in basis points (10000 = 1x, 15000 = 1.5x)
     */
    function getCloudSizeMultiplier(string calldata _dreamId) external view returns (uint256) {
        uint256 boostPercent = getEffectiveBoost(_dreamId);
        // Convert percentage to multiplier in basis points
        // 0% boost = 10000 (1x)
        // 50% boost = 15000 (1.5x)
        // 100% boost = 20000 (2x)
        return 10000 + (boostPercent * 100);
    }

    /**
     * @notice Get boost info for a dream
     * @param _dreamId The dream to check
     * @return effectiveBoost Current boost percentage after decay
     * @return totalSpent Total zDREAMS spent on this dream
     * @return lastBoostTime When the dream was last boosted
     */
    function getDreamBoostInfo(string calldata _dreamId) external view returns (
        uint256 effectiveBoost,
        uint256 totalSpent,
        uint256 lastBoostTime
    ) {
        DreamBoost storage boost = dreamBoosts[_dreamId];
        return (
            getEffectiveBoost(_dreamId),
            boost.totalSpent,
            boost.lastBoostTime
        );
    }

    /**
     * @notice Get number of boost tiers
     */
    function getBoostTierCount() external view returns (uint256) {
        return boostTiers.length;
    }

    /**
     * @notice Get all boost tiers
     */
    function getAllBoostTiers() external view returns (BoostTier[] memory) {
        return boostTiers;
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Add a new boost tier
     * @param _cost zDREAMS required
     * @param _sizeBoost Size boost percentage
     */
    function addBoostTier(uint256 _cost, uint256 _sizeBoost) external onlyAdmin {
        if (_cost == 0 || _sizeBoost == 0) revert InvalidAmount();

        boostTiers.push(BoostTier({ cost: _cost, sizeBoost: _sizeBoost }));
        emit BoostTierAdded(boostTiers.length - 1, _cost, _sizeBoost);
    }

    /**
     * @notice Update an existing boost tier
     * @param _tierIndex Tier to update
     * @param _cost New cost
     * @param _sizeBoost New size boost
     */
    function updateBoostTier(uint256 _tierIndex, uint256 _cost, uint256 _sizeBoost) external onlyAdmin {
        if (_tierIndex >= boostTiers.length) revert InvalidTier();
        if (_cost == 0 || _sizeBoost == 0) revert InvalidAmount();

        boostTiers[_tierIndex] = BoostTier({ cost: _cost, sizeBoost: _sizeBoost });
        emit BoostTierUpdated(_tierIndex, _cost, _sizeBoost);
    }

    /**
     * @notice Update zDREAMS token address
     */
    function setZDreamsToken(address _zDreamsToken) external onlyAdmin {
        if (_zDreamsToken == address(0)) revert InvalidAddress();
        zDreamsToken = IzDREAMS(_zDreamsToken);
    }

    /**
     * @notice Initiate admin transfer
     */
    function initiateAdminTransfer(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert InvalidAddress();
        pendingAdmin = _newAdmin;
        emit AdminTransferInitiated(admin, _newAdmin);
    }

    /**
     * @notice Accept admin transfer
     */
    function acceptAdminTransfer() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferCompleted(oldAdmin, admin);
    }
}
