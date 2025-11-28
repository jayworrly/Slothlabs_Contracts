// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/IzDREAMS.sol";

/**
 * @title DreamsStaking
 * @notice Lock up your DREAMS tokens to earn rewards and get voting power.
 *
 * HOW STAKING WORKS:
 * 1. You deposit DREAMS tokens into this contract
 * 2. Your tokens earn rewards over time
 * 3. You get voting power in the crowdfunding system
 * 4. After the vesting period, you can withdraw everything
 *
 * VESTING SCHEDULE (prevents quick dump-and-run):
 * - Cliff Period (30 days): During this time, you can't withdraw anything.
 *   Think of it as a commitment period.
 * - Vesting Period (180 days): After the cliff, your tokens unlock gradually.
 *   Each day, a little more becomes available.
 * - Early Withdrawal: If you withdraw before fully vested, you pay a 20% penalty
 *   on the unvested portion.
 *
 * REWARD SYSTEM (protects you from price swings):
 * - Rewards accrue in US dollar value, not token count
 * - When you claim, dollars convert to tokens at the current price
 * - Example: You earn $100 in rewards. If token price is $2, you get 50 tokens.
 *   If token price drops to $1, you get 100 tokens. Either way, you get $100 worth.
 *
 * COMPOUNDING (for long-term holders):
 * - You can add your rewards back into your stake
 * - Warning: This resets your vesting timer! But you get more voting power.
 */
contract DreamsStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ STATE ============

    IERC20 public immutable dreamsToken;
    IzDREAMS public zDreamsToken;
    IPriceOracle public priceOracle;

    address public admin;
    address public pendingAdmin;

    // Vesting configuration
    uint256 public cliffPeriod = 30 days;      // Minimum stake time before rewards
    uint256 public vestingPeriod = 180 days;   // Full vesting duration after cliff
    uint256 public earlyUnstakePenaltyBps = 2000; // 20% penalty for early unstake

    // Staking state
    uint256 public totalStaked;
    uint256 public totalVotingPower;

    struct StakeInfo {
        uint256 amount;              // DREAMS staked
        uint256 startTime;           // When stake began
        uint256 rewardsAccruedUSD;   // Rewards in USD (18 decimals)
        uint256 rewardsClaimed;      // Rewards already claimed (in reward tokens)
        uint256 lastRewardTime;      // Last time rewards were calculated
    }

    mapping(address => StakeInfo) public stakes;

    // Reward configuration
    address public rewardToken;           // Token paid as rewards (e.g., JUICY)
    uint256 public rewardRateUSDPerSecond; // USD rewards per second per staked token (scaled by 1e18)

    // Treasury for penalties
    address public treasury;

    // Treasury integration (closed-loop economy)
    address public treasurySaleContract;   // DreamsTreasurySale contract
    address public buybackContract;         // DreamsTreasuryBuyback contract
    uint256 public treasuryBonusBps = 1000; // 10% bonus zDREAMS for treasury purchases
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ EVENTS ============

    event Staked(address indexed user, uint256 amount, uint256 vestingEnd);
    event StakedFor(address indexed beneficiary, address indexed depositor, uint256 amount, uint256 vestingEnd);
    event Unstaked(address indexed user, uint256 amount, uint256 penalty);
    event RewardsClaimed(address indexed user, uint256 usdValue, uint256 tokenAmount);
    event RewardsCompounded(address indexed user, uint256 usdValue, uint256 tokenAmount, uint256 newVestingEnd);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event VestingConfigUpdated(uint256 cliff, uint256 vesting, uint256 penaltyBps);
    event RewardsDeposited(address indexed depositor, uint256 amount);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferCompleted(address indexed oldAdmin, address indexed newAdmin);
    event zDreamsTokenUpdated(address indexed oldToken, address indexed newToken);
    event TreasurySaleContractUpdated(address indexed oldContract, address indexed newContract);
    event BuybackContractUpdated(address indexed oldContract, address indexed newContract);
    event TreasuryBonusUpdated(uint256 oldBonus, uint256 newBonus);
    event UnstakedForBuyback(address indexed user, uint256 amount, uint256 toRecipient, uint256 penalty, address recipient);

    // ============ ERRORS ============

    error InvalidAmount();
    error InvalidAddress();
    error InsufficientBalance();
    error CannotCompoundNonDreams();
    error OnlyAdmin();
    error NotPendingAdmin();
    error CliffNotReached();
    error NoRewardsToClaim();
    error InvalidConfiguration();
    error OnlyBuybackContract();
    error BonusTooHigh();

    // ============ MODIFIERS ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyBuybackContract() {
        if (msg.sender != buybackContract) revert OnlyBuybackContract();
        _;
    }

    modifier updateRewards(address _account) {
        if (_account != address(0) && stakes[_account].amount > 0) {
            stakes[_account].rewardsAccruedUSD += _calculatePendingRewardsUSD(_account);
            stakes[_account].lastRewardTime = block.timestamp;
        }
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor(
        address _dreamsToken,
        address _rewardToken,
        address _priceOracle,
        address _treasury
    ) {
        if (_dreamsToken == address(0) || _rewardToken == address(0)) revert InvalidAddress();
        if (_priceOracle == address(0) || _treasury == address(0)) revert InvalidAddress();

        dreamsToken = IERC20(_dreamsToken);
        rewardToken = _rewardToken;
        priceOracle = IPriceOracle(_priceOracle);
        treasury = _treasury;
        admin = msg.sender;
    }

    // ============ STAKING FUNCTIONS ============

    /**
     * @notice Process stake for a beneficiary
     * @dev Internal helper to avoid duplicate code between stake() and stakeFor()
     * @param _beneficiary Address that will own the staked tokens
     * @param _amount Amount of DREAMS to stake
     * @param _fromTreasury Whether this stake originates from treasury sale (gets bonus zDREAMS)
     * @return vestingEndTime The calculated vesting end time
     */
    function _processStake(address _beneficiary, uint256 _amount, bool _fromTreasury) internal returns (uint256 vestingEndTime) {
        StakeInfo storage userStake = stakes[_beneficiary];

        // If first time staking or adding to existing stake
        if (userStake.amount == 0) {
            userStake.startTime = block.timestamp;
            userStake.lastRewardTime = block.timestamp;
        }

        userStake.amount += _amount;
        totalStaked += _amount;
        totalVotingPower += _amount;

        // Mint zDREAMS for voting power and cloud boosts
        // Treasury purchases get bonus zDREAMS (10% extra voting power incentive)
        if (address(zDreamsToken) != address(0)) {
            uint256 zDreamsToMint = _amount;
            if (_fromTreasury && treasuryBonusBps > 0) {
                // Example: 1000 DREAMS staked via treasury → 1100 zDREAMS (10% bonus)
                zDreamsToMint = (_amount * (BPS_DENOMINATOR + treasuryBonusBps)) / BPS_DENOMINATOR;
            }
            zDreamsToken.mint(_beneficiary, zDreamsToMint);
        }

        return userStake.startTime + cliffPeriod + vestingPeriod;
    }

    /**
     * @notice Stake DREAMS tokens with vesting
     * @param _amount Amount of DREAMS to stake
     */
    function stake(uint256 _amount) external nonReentrant updateRewards(msg.sender) {
        if (_amount == 0) revert InvalidAmount();

        // Regular stake - no treasury bonus
        uint256 vestingEndTime = _processStake(msg.sender, _amount, false);

        dreamsToken.safeTransferFrom(msg.sender, address(this), _amount);

        emit Staked(msg.sender, _amount, vestingEndTime);
    }

    /**
     * @notice Stake DREAMS tokens on behalf of another user (for auto-lock treasury purchases)
     * @dev Tokens are pulled from msg.sender but staked for _beneficiary
     *      Used by DreamsTreasurySale to auto-stake purchased tokens
     *      If called by treasurySaleContract, user gets 10% bonus zDREAMS for voting power
     * @param _beneficiary Address that will own the staked tokens
     * @param _amount Amount of DREAMS to stake
     */
    function stakeFor(address _beneficiary, uint256 _amount) external nonReentrant updateRewards(_beneficiary) {
        if (_amount == 0) revert InvalidAmount();
        if (_beneficiary == address(0)) revert InvalidAddress();

        // Check if this is from treasury sale contract (gets bonus zDREAMS)
        bool fromTreasury = (msg.sender == treasurySaleContract);
        uint256 vestingEndTime = _processStake(_beneficiary, _amount, fromTreasury);

        // Pull tokens from caller (e.g., treasury sale contract)
        dreamsToken.safeTransferFrom(msg.sender, address(this), _amount);

        emit StakedFor(_beneficiary, msg.sender, _amount, vestingEndTime);
    }

    /**
     * @notice Unstake DREAMS tokens
     * @dev If before vesting complete, penalty applies to unvested portion
     * @param _amount Amount of DREAMS to unstake
     */
    function unstake(uint256 _amount) external nonReentrant updateRewards(msg.sender) {
        if (_amount == 0) revert InvalidAmount();

        StakeInfo storage userStake = stakes[msg.sender];
        if (userStake.amount < _amount) revert InsufficientBalance();

        uint256 vestedAmount = getVestedAmount(msg.sender);
        uint256 penalty = 0;

        // If you withdraw early, you pay a penalty on tokens that haven't fully vested yet
        // Example: if only 50% is vested and you withdraw 100 tokens, 50 of them have a penalty
        if (_amount > vestedAmount) {
            uint256 unvestedWithdraw = _amount - vestedAmount;
            penalty = (unvestedWithdraw * earlyUnstakePenaltyBps) / 10000;
        }

        uint256 toUser = _amount - penalty;

        userStake.amount -= _amount;
        totalStaked -= _amount;
        totalVotingPower -= _amount;

        // Burn zDREAMS 1:1 with unstaked amount
        if (address(zDreamsToken) != address(0)) {
            zDreamsToken.burn(msg.sender, _amount);
        }

        // Transfer to user
        dreamsToken.safeTransfer(msg.sender, toUser);

        // Send penalty to treasury
        if (penalty > 0) {
            dreamsToken.safeTransfer(treasury, penalty);
        }

        // Reset if fully unstaked
        if (userStake.amount == 0) {
            userStake.startTime = 0;
        }

        emit Unstaked(msg.sender, toUser, penalty);
    }

    /**
     * @notice Claim accrued rewards
     * @dev Rewards in USD converted to reward tokens at current price
     */
    function claimRewards() external nonReentrant updateRewards(msg.sender) {
        StakeInfo storage userStake = stakes[msg.sender];

        // Check cliff period
        if (block.timestamp < userStake.startTime + cliffPeriod) {
            revert CliffNotReached();
        }

        uint256 rewardsUSD = userStake.rewardsAccruedUSD;
        if (rewardsUSD == 0) revert NoRewardsToClaim();

        // Convert USD to reward tokens at current price
        uint256 rewardTokenPrice = priceOracle.getPrice(rewardToken); // 8 decimals
        uint256 tokenAmount = (rewardsUSD * 1e8) / rewardTokenPrice;  // Convert to token amount

        // Reset accrued rewards
        userStake.rewardsAccruedUSD = 0;
        userStake.rewardsClaimed += tokenAmount;

        // Transfer reward tokens
        IERC20(rewardToken).safeTransfer(msg.sender, tokenAmount);

        emit RewardsClaimed(msg.sender, rewardsUSD, tokenAmount);
    }

    /**
     * @notice Add your rewards back into your stake to earn even more
     * @dev WARNING: Compounding resets your vesting timer! Your existing stake's
     *      vesting progress is NOT lost, but the newly added rewards start a fresh
     *      vesting period. Only works when reward token is DREAMS (can't stake JUICY here).
     */
    function compoundRewards() external nonReentrant updateRewards(msg.sender) {
        // Compounding only makes sense if rewards are in DREAMS (same token we stake)
        if (rewardToken != address(dreamsToken)) revert CannotCompoundNonDreams();

        StakeInfo storage userStake = stakes[msg.sender];

        // Must have passed the cliff period first
        if (block.timestamp < userStake.startTime + cliffPeriod) {
            revert CliffNotReached();
        }

        uint256 rewardsUSD = userStake.rewardsAccruedUSD;
        if (rewardsUSD == 0) revert NoRewardsToClaim();

        // Convert your USD rewards to DREAMS tokens at current market price
        uint256 dreamsPrice = priceOracle.getPrice(address(dreamsToken));
        uint256 tokenAmount = (rewardsUSD * 1e8) / dreamsPrice;

        // Clear the rewards (you're converting them to stake)
        userStake.rewardsAccruedUSD = 0;

        // Add rewards to your stake - but this RESETS the vesting timer!
        // This is a tradeoff: more staked = more voting power and more rewards,
        // but you have to wait again before you can withdraw penalty-free
        userStake.amount += tokenAmount;
        userStake.startTime = block.timestamp;  // Reset vesting clock
        userStake.lastRewardTime = block.timestamp;

        totalStaked += tokenAmount;
        totalVotingPower += tokenAmount;

        // Mint additional zDREAMS for the compounded amount
        if (address(zDreamsToken) != address(0)) {
            zDreamsToken.mint(msg.sender, tokenAmount);
        }

        emit RewardsCompounded(msg.sender, rewardsUSD, tokenAmount, block.timestamp + cliffPeriod + vestingPeriod);
    }

    /**
     * @notice Unstake DREAMS for buyback contract (closed-loop economy)
     * @dev Only callable by the buyback contract. Burns zDREAMS (including any bonus),
     *      sends DREAMS to recipient (usually treasury), applies vesting penalty.
     * @param _user User whose position is being unstaked
     * @param _amount Amount of DREAMS to unstake
     * @param _recipient Where to send the DREAMS (usually treasury)
     * @return penalty Amount of DREAMS taken as early withdrawal penalty
     */
    function unstakeForBuyback(
        address _user,
        uint256 _amount,
        address _recipient
    ) external nonReentrant onlyBuybackContract updateRewards(_user) returns (uint256 penalty) {
        if (_amount == 0) revert InvalidAmount();
        if (_recipient == address(0)) revert InvalidAddress();

        StakeInfo storage userStake = stakes[_user];
        if (userStake.amount < _amount) revert InsufficientBalance();

        // Calculate penalty on unvested portion (same logic as regular unstake)
        uint256 vestedAmount = getVestedAmount(_user);
        if (_amount > vestedAmount) {
            uint256 unvestedWithdraw = _amount - vestedAmount;
            penalty = (unvestedWithdraw * earlyUnstakePenaltyBps) / 10000;
        }

        uint256 toRecipient = _amount - penalty;

        // Update staking state
        userStake.amount -= _amount;
        totalStaked -= _amount;
        totalVotingPower -= _amount;

        // Burn ALL zDREAMS for this user's unstaked amount
        // This includes any treasury bonus - when you exit, you lose the bonus voting power
        if (address(zDreamsToken) != address(0)) {
            uint256 zBalance = zDreamsToken.balanceOf(_user);
            // Burn proportional amount of zDREAMS
            // If user had bonus, they lose the bonus proportionally
            uint256 zToBurn = _amount;
            if (userStake.amount + _amount > 0) {
                // Calculate ratio of zDREAMS to burn based on original stake proportion
                zToBurn = (zBalance * _amount) / (userStake.amount + _amount);
            }
            // Ensure we don't try to burn more than they have
            if (zToBurn > zBalance) zToBurn = zBalance;
            zDreamsToken.burn(_user, zToBurn);
        }

        // Send DREAMS to recipient (buyback contract will forward to treasury)
        dreamsToken.safeTransfer(_recipient, toRecipient);

        // Send penalty to treasury
        if (penalty > 0) {
            dreamsToken.safeTransfer(treasury, penalty);
        }

        // Reset if fully unstaked
        if (userStake.amount == 0) {
            userStake.startTime = 0;
        }

        emit UnstakedForBuyback(_user, _amount, toRecipient, penalty, _recipient);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get voting power for an address
     * @param _account Address to check
     * @return Voting power (= staked balance)
     */
    function getVotingPower(address _account) external view returns (uint256) {
        return stakes[_account].amount;
    }

    /**
     * @notice Get total voting power
     */
    function getTotalVotingPower() external view returns (uint256) {
        return totalVotingPower;
    }

    /**
     * @notice Calculate how much of your stake is fully unlocked
     * @dev Vesting works in three phases:
     *      1. Cliff period (first 30 days): Nothing is vested, withdrawing costs 20% penalty
     *      2. Vesting period (next 180 days): Tokens unlock gradually each day
     *      3. After vesting: Everything is fully unlocked, no penalty to withdraw
     * @param _account Address to check
     * @return Amount of DREAMS that can be withdrawn without penalty
     */
    function getVestedAmount(address _account) public view returns (uint256) {
        StakeInfo storage userStake = stakes[_account];

        if (userStake.amount == 0) return 0;

        uint256 elapsed = block.timestamp - userStake.startTime;

        // During the cliff period: nothing is vested yet
        if (elapsed < cliffPeriod) {
            return 0;
        }

        // After full vesting period: everything is unlocked
        if (elapsed >= cliffPeriod + vestingPeriod) {
            return userStake.amount;
        }

        // During vesting: linear unlock (e.g., after 90 days of 180-day vesting = 50% vested)
        uint256 vestingElapsed = elapsed - cliffPeriod;
        return (userStake.amount * vestingElapsed) / vestingPeriod;
    }

    /**
     * @notice Get pending rewards in USD for an account
     * @param _account Address to check
     * @return Pending rewards in USD (18 decimals)
     */
    function getPendingRewardsUSD(address _account) external view returns (uint256) {
        StakeInfo storage userStake = stakes[_account];
        return userStake.rewardsAccruedUSD + _calculatePendingRewardsUSD(_account);
    }

    /**
     * @notice Get pending rewards converted to token amount
     * @param _account Address to check
     * @return Estimated reward tokens at current price
     */
    function getPendingRewardsTokens(address _account) external view returns (uint256) {
        StakeInfo storage userStake = stakes[_account];
        uint256 totalUSD = userStake.rewardsAccruedUSD + _calculatePendingRewardsUSD(_account);

        if (totalUSD == 0) return 0;

        uint256 rewardTokenPrice = priceOracle.getPrice(rewardToken);
        return (totalUSD * 1e8) / rewardTokenPrice;
    }

    /**
     * @notice Get complete stake info for an account
     */
    function getStakeInfo(address _account)
        external
        view
        returns (
            uint256 stakedAmount,
            uint256 vestedAmount,
            uint256 votingPower,
            uint256 pendingRewardsUSD,
            uint256 cliffEnds,
            uint256 vestingEnds,
            bool cliffReached
        )
    {
        StakeInfo storage userStake = stakes[_account];

        stakedAmount = userStake.amount;
        vestedAmount = getVestedAmount(_account);
        votingPower = userStake.amount;
        pendingRewardsUSD = userStake.rewardsAccruedUSD + _calculatePendingRewardsUSD(_account);
        cliffEnds = userStake.startTime + cliffPeriod;
        vestingEnds = userStake.startTime + cliffPeriod + vestingPeriod;
        cliffReached = block.timestamp >= cliffEnds;
    }

    /**
     * @notice Calculate pending rewards since last update
     */
    function _calculatePendingRewardsUSD(address _account) internal view returns (uint256) {
        StakeInfo storage userStake = stakes[_account];

        if (userStake.amount == 0 || rewardRateUSDPerSecond == 0) {
            return 0;
        }

        uint256 elapsed = block.timestamp - userStake.lastRewardTime;
        // Rewards = staked amount * rate * time / 1e18 (for precision)
        return (userStake.amount * rewardRateUSDPerSecond * elapsed) / 1e18;
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Set reward rate (USD per second per staked token)
     * @param _ratePerSecond New rate (scaled by 1e18)
     */
    function setRewardRate(uint256 _ratePerSecond) external onlyAdmin {
        uint256 oldRate = rewardRateUSDPerSecond;
        rewardRateUSDPerSecond = _ratePerSecond;
        emit RewardRateUpdated(oldRate, _ratePerSecond);
    }

    /**
     * @notice Update vesting configuration
     * @param _cliffPeriod New cliff period in seconds
     * @param _vestingPeriod New vesting period in seconds
     * @param _penaltyBps New penalty in basis points
     */
    function setVestingConfig(
        uint256 _cliffPeriod,
        uint256 _vestingPeriod,
        uint256 _penaltyBps
    ) external onlyAdmin {
        if (_penaltyBps > 5000) revert InvalidConfiguration(); // Max 50% penalty

        cliffPeriod = _cliffPeriod;
        vestingPeriod = _vestingPeriod;
        earlyUnstakePenaltyBps = _penaltyBps;

        emit VestingConfigUpdated(_cliffPeriod, _vestingPeriod, _penaltyBps);
    }

    /**
     * @notice Update price oracle
     * @param _oracle New oracle address
     */
    function setPriceOracle(address _oracle) external onlyAdmin {
        if (_oracle == address(0)) revert InvalidAddress();
        priceOracle = IPriceOracle(_oracle);
    }

    /**
     * @notice Update treasury address
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyAdmin {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
    }

    /**
     * @notice Set zDREAMS token contract
     * @param _zDreamsToken New zDREAMS token address
     */
    function setZDreamsToken(address _zDreamsToken) external onlyAdmin {
        if (_zDreamsToken == address(0)) revert InvalidAddress();
        address oldToken = address(zDreamsToken);
        zDreamsToken = IzDREAMS(_zDreamsToken);
        emit zDreamsTokenUpdated(oldToken, _zDreamsToken);
    }

    /**
     * @notice Set treasury sale contract (for bonus zDREAMS)
     * @param _treasurySaleContract Address of DreamsTreasurySale contract
     */
    function setTreasurySaleContract(address _treasurySaleContract) external onlyAdmin {
        address oldContract = treasurySaleContract;
        treasurySaleContract = _treasurySaleContract;
        emit TreasurySaleContractUpdated(oldContract, _treasurySaleContract);
    }

    /**
     * @notice Set buyback contract (for closed-loop exits)
     * @param _buybackContract Address of DreamsTreasuryBuyback contract
     */
    function setBuybackContract(address _buybackContract) external onlyAdmin {
        address oldContract = buybackContract;
        buybackContract = _buybackContract;
        emit BuybackContractUpdated(oldContract, _buybackContract);
    }

    /**
     * @notice Set treasury bonus for purchases via treasury sale
     * @param _bonusBps Bonus in basis points (e.g., 1000 = 10% bonus zDREAMS)
     */
    function setTreasuryBonus(uint256 _bonusBps) external onlyAdmin {
        if (_bonusBps > 5000) revert BonusTooHigh(); // Max 50% bonus
        uint256 oldBonus = treasuryBonusBps;
        treasuryBonusBps = _bonusBps;
        emit TreasuryBonusUpdated(oldBonus, _bonusBps);
    }

    /**
     * @notice Deposit reward tokens to contract
     * @param _amount Amount to deposit
     */
    function depositRewards(uint256 _amount) external {
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), _amount);
        emit RewardsDeposited(msg.sender, _amount);
    }

    /**
     * @notice Emergency withdraw stuck tokens
     * @param _token Token address
     * @param _amount Amount to withdraw
     */
    function rescueTokens(address _token, uint256 _amount) external onlyAdmin {
        if (_token == address(dreamsToken)) {
            uint256 excess = IERC20(_token).balanceOf(address(this)) - totalStaked;
            require(_amount <= excess, "Cannot withdraw staked tokens");
        }
        IERC20(_token).safeTransfer(admin, _amount);
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
