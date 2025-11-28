// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title DreamsFaucet
 * @notice Testnet faucet for distributing test DREAMS tokens
 * @dev Rate-limited faucet to prevent abuse while allowing adequate testing
 *
 * WARNING: This contract is for TESTNET USE ONLY
 * Do not deploy on mainnet - it allows free token distribution
 */
contract DreamsFaucet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ STATE ============

    IERC20 public immutable dreamsToken;
    address public admin;

    // Rate limiting
    uint256 public claimAmount = 10_000 ether;      // 10,000 DREAMS per claim
    uint256 public claimCooldown = 24 hours;        // Once per day
    uint256 public maxClaimsPerAddress = 10;        // Max 10 claims total per address

    // Tracking
    mapping(address => uint256) public lastClaimTime;
    mapping(address => uint256) public totalClaims;
    uint256 public totalDistributed;

    // Circuit breaker
    bool public faucetEnabled = true;
    uint256 public maxDailyDistribution = 1_000_000 ether;  // 1M DREAMS per day max
    uint256 public dailyDistributed;
    uint256 public lastResetTime;

    // ============ ERRORS ============

    error FaucetDisabled();
    error CooldownNotPassed(uint256 timeRemaining);
    error MaxClaimsReached();
    error DailyLimitReached();
    error InsufficientFaucetBalance();
    error OnlyAdmin();
    error InvalidAmount();

    // ============ EVENTS ============

    event Claimed(address indexed user, uint256 amount, uint256 totalClaims);
    event FaucetToggled(bool enabled);
    event ClaimAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event CooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event FaucetFunded(address indexed funder, uint256 amount);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ============ CONSTRUCTOR ============

    constructor(address _dreamsToken) {
        dreamsToken = IERC20(_dreamsToken);
        admin = msg.sender;
        lastResetTime = block.timestamp;
    }

    // ============ MODIFIERS ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // ============ USER FUNCTIONS ============

    /**
     * @notice Claim test DREAMS tokens
     * @dev Rate-limited to prevent abuse
     */
    function claim() external nonReentrant {
        if (!faucetEnabled) revert FaucetDisabled();

        // Check cooldown
        uint256 timeSinceLastClaim = block.timestamp - lastClaimTime[msg.sender];
        if (lastClaimTime[msg.sender] != 0 && timeSinceLastClaim < claimCooldown) {
            revert CooldownNotPassed(claimCooldown - timeSinceLastClaim);
        }

        // Check max claims per address
        if (totalClaims[msg.sender] >= maxClaimsPerAddress) {
            revert MaxClaimsReached();
        }

        // Reset daily limit if new day
        if (block.timestamp >= lastResetTime + 24 hours) {
            dailyDistributed = 0;
            lastResetTime = block.timestamp;
        }

        // Check daily limit
        if (dailyDistributed + claimAmount > maxDailyDistribution) {
            revert DailyLimitReached();
        }

        // Check faucet balance
        uint256 faucetBalance = dreamsToken.balanceOf(address(this));
        if (faucetBalance < claimAmount) {
            revert InsufficientFaucetBalance();
        }

        // Update state
        lastClaimTime[msg.sender] = block.timestamp;
        totalClaims[msg.sender]++;
        totalDistributed += claimAmount;
        dailyDistributed += claimAmount;

        // Transfer tokens
        dreamsToken.safeTransfer(msg.sender, claimAmount);

        emit Claimed(msg.sender, claimAmount, totalClaims[msg.sender]);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Check if user can claim and when
     * @param _user Address to check
     * @return canClaim Whether user can claim now
     * @return timeUntilNextClaim Seconds until next claim (0 if can claim now)
     * @return claimsRemaining Number of claims remaining for user
     */
    function getClaimStatus(address _user) external view returns (
        bool canClaim,
        uint256 timeUntilNextClaim,
        uint256 claimsRemaining
    ) {
        if (!faucetEnabled) {
            return (false, 0, 0);
        }

        claimsRemaining = totalClaims[_user] >= maxClaimsPerAddress
            ? 0
            : maxClaimsPerAddress - totalClaims[_user];

        if (claimsRemaining == 0) {
            return (false, 0, 0);
        }

        if (lastClaimTime[_user] == 0) {
            // Never claimed before
            return (true, 0, claimsRemaining);
        }

        uint256 timeSinceLastClaim = block.timestamp - lastClaimTime[_user];
        if (timeSinceLastClaim >= claimCooldown) {
            return (true, 0, claimsRemaining);
        }

        timeUntilNextClaim = claimCooldown - timeSinceLastClaim;
        return (false, timeUntilNextClaim, claimsRemaining);
    }

    /**
     * @notice Get faucet statistics
     * @return balance Current faucet balance
     * @return distributed Total tokens distributed
     * @return dailyRemaining Tokens remaining in daily limit
     * @return enabled Whether faucet is enabled
     */
    function getFaucetStats() external view returns (
        uint256 balance,
        uint256 distributed,
        uint256 dailyRemaining,
        bool enabled
    ) {
        balance = dreamsToken.balanceOf(address(this));
        distributed = totalDistributed;

        // Calculate daily remaining
        uint256 currentDailyDistributed = dailyDistributed;
        if (block.timestamp >= lastResetTime + 24 hours) {
            currentDailyDistributed = 0;
        }
        dailyRemaining = maxDailyDistribution > currentDailyDistributed
            ? maxDailyDistribution - currentDailyDistributed
            : 0;

        enabled = faucetEnabled;
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Toggle faucet on/off
     */
    function toggleFaucet() external onlyAdmin {
        faucetEnabled = !faucetEnabled;
        emit FaucetToggled(faucetEnabled);
    }

    /**
     * @notice Update claim amount
     * @param _newAmount New amount per claim (in wei)
     */
    function setClaimAmount(uint256 _newAmount) external onlyAdmin {
        if (_newAmount == 0) revert InvalidAmount();
        uint256 oldAmount = claimAmount;
        claimAmount = _newAmount;
        emit ClaimAmountUpdated(oldAmount, _newAmount);
    }

    /**
     * @notice Update cooldown period
     * @param _newCooldown New cooldown in seconds
     */
    function setCooldown(uint256 _newCooldown) external onlyAdmin {
        uint256 oldCooldown = claimCooldown;
        claimCooldown = _newCooldown;
        emit CooldownUpdated(oldCooldown, _newCooldown);
    }

    /**
     * @notice Update max claims per address
     * @param _maxClaims New max claims
     */
    function setMaxClaims(uint256 _maxClaims) external onlyAdmin {
        maxClaimsPerAddress = _maxClaims;
    }

    /**
     * @notice Update daily distribution limit
     * @param _maxDaily New daily limit (in wei)
     */
    function setMaxDailyDistribution(uint256 _maxDaily) external onlyAdmin {
        maxDailyDistribution = _maxDaily;
    }

    /**
     * @notice Transfer admin role
     * @param _newAdmin New admin address
     */
    function transferAdmin(address _newAdmin) external onlyAdmin {
        address oldAdmin = admin;
        admin = _newAdmin;
        emit AdminTransferred(oldAdmin, _newAdmin);
    }

    /**
     * @notice Withdraw tokens from faucet (emergency)
     * @param _amount Amount to withdraw
     */
    function withdrawTokens(uint256 _amount) external onlyAdmin {
        dreamsToken.safeTransfer(admin, _amount);
    }

    /**
     * @notice Reset a user's claim count (for testing)
     * @param _user Address to reset
     */
    function resetUserClaims(address _user) external onlyAdmin {
        totalClaims[_user] = 0;
        lastClaimTime[_user] = 0;
    }
}
