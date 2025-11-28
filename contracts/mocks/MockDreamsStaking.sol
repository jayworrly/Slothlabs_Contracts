// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockDreamsStaking
 * @notice Mock staking contract for testing DreamsTreasuryBuyback
 * @dev Implements IDreamsStaking interface with simplified logic
 */
contract MockDreamsStaking {
    IERC20 public dreams;
    IERC20 public zDreams;

    // Stake info storage
    struct StakeInfo {
        uint256 amount;
        uint256 startTime;
        uint256 rewardsAccruedUSD;
        uint256 rewardsClaimed;
        uint256 lastRewardTime;
    }

    mapping(address => StakeInfo) public stakes;
    uint256 public totalStaked;

    // Configuration
    uint256 public cliffDuration = 7 days;
    uint256 public vestingDuration = 30 days;
    uint256 public earlyUnstakePenaltyBps = 1000; // 10% penalty

    // Authorized buyback contract
    address public buybackContract;

    constructor(address _dreams, address _zDreams) {
        dreams = IERC20(_dreams);
        zDreams = IERC20(_zDreams);
    }

    // ============ Mock Functions ============

    /**
     * @notice Set the authorized buyback contract
     */
    function setBuybackContract(address _buyback) external {
        buybackContract = _buyback;
    }

    /**
     * @notice Simulate a stake for testing
     */
    function mockStake(address user, uint256 amount) external {
        stakes[user] = StakeInfo({
            amount: amount,
            startTime: block.timestamp,
            rewardsAccruedUSD: 0,
            rewardsClaimed: 0,
            lastRewardTime: block.timestamp
        });
        totalStaked += amount;
    }

    /**
     * @notice Simulate stake with custom start time (for testing cliff)
     */
    function mockStakeWithTime(address user, uint256 amount, uint256 startTime) external {
        stakes[user] = StakeInfo({
            amount: amount,
            startTime: startTime,
            rewardsAccruedUSD: 0,
            rewardsClaimed: 0,
            lastRewardTime: startTime
        });
        totalStaked += amount;
    }

    /**
     * @notice Set cliff duration for testing
     */
    function setCliffDuration(uint256 _duration) external {
        cliffDuration = _duration;
    }

    /**
     * @notice Set early unstake penalty
     */
    function setEarlyUnstakePenalty(uint256 _bps) external {
        earlyUnstakePenaltyBps = _bps;
    }

    // ============ IDreamsStaking Interface ============

    /**
     * @notice Unstake DREAMS for buyback (burns zDREAMS, sends DREAMS to recipient)
     * @dev Only callable by authorized buyback contract
     * @param user The user whose stake to unstake from
     * @param amount Amount of DREAMS to unstake
     * @param recipient Where to send the DREAMS (buyback contract)
     * @return penalty Amount penalized (if early unstake)
     */
    function unstakeForBuyback(
        address user,
        uint256 amount,
        address recipient
    ) external returns (uint256 penalty) {
        require(msg.sender == buybackContract, "Only buyback contract");
        require(stakes[user].amount >= amount, "Insufficient staked");

        // Calculate penalty if before vesting end
        StakeInfo storage stake = stakes[user];
        uint256 vestingEnd = stake.startTime + vestingDuration;

        if (block.timestamp < vestingEnd) {
            // Pro-rata penalty based on time remaining
            uint256 timeRemaining = vestingEnd - block.timestamp;
            uint256 maxPenalty = (amount * earlyUnstakePenaltyBps) / 10000;
            penalty = (maxPenalty * timeRemaining) / vestingDuration;
        }

        // Update stake
        stake.amount -= amount;
        totalStaked -= amount;

        // Burn zDREAMS from user (mock: just check they have it)
        require(zDreams.balanceOf(user) >= amount, "Insufficient zDREAMS");
        // In a real contract, this would burn zDREAMS
        // For mock, we'll do a transferFrom to simulate burn
        zDreams.transferFrom(user, address(this), amount);

        // Send DREAMS to recipient (minus penalty)
        uint256 dreamsToSend = amount - penalty;
        dreams.transfer(recipient, dreamsToSend);

        return penalty;
    }

    /**
     * @notice Get stake info for a user
     */
    function getStakeInfo(address _account) external view returns (
        uint256 stakedAmount,
        uint256 vestedAmount,
        uint256 votingPower,
        uint256 pendingRewardsUSD,
        uint256 cliffEnds,
        uint256 vestingEnds,
        bool cliffReached
    ) {
        StakeInfo storage stake = stakes[_account];

        stakedAmount = stake.amount;
        cliffEnds = stake.startTime + cliffDuration;
        vestingEnds = stake.startTime + vestingDuration;
        cliffReached = block.timestamp >= cliffEnds;

        // Calculate vested amount
        if (block.timestamp >= vestingEnds) {
            vestedAmount = stakedAmount;
        } else if (block.timestamp > cliffEnds) {
            uint256 vestingTime = block.timestamp - stake.startTime;
            vestedAmount = (stakedAmount * vestingTime) / vestingDuration;
        } else {
            vestedAmount = 0;
        }

        votingPower = stakedAmount; // Simplified
        pendingRewardsUSD = stake.rewardsAccruedUSD - stake.rewardsClaimed;
    }

    /**
     * @notice Fund the contract with DREAMS for testing
     */
    function fundDreams(uint256 amount) external {
        dreams.transferFrom(msg.sender, address(this), amount);
    }
}
