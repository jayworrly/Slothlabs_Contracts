// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDreamsStaking
 * @notice Interface for DreamsStaking contract - used for hybrid voting power calculation
 */
interface IDreamsStaking {
    /**
     * @notice Get staking info for an account
     * @param _account Address to check
     * @return stakedAmount Amount of DREAMS staked
     * @return vestedAmount Amount that can be withdrawn without penalty
     * @return votingPower Current voting power (= staked amount)
     * @return pendingRewardsUSD Pending rewards in USD
     * @return cliffEnds When cliff period ends
     * @return vestingEnds When full vesting ends
     * @return cliffReached Whether cliff period has passed
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
        );

    /**
     * @notice Get voting power for an address
     * @param _account Address to check
     * @return Voting power (= staked balance)
     */
    function getVotingPower(address _account) external view returns (uint256);

    /**
     * @notice Get total voting power across all stakers
     */
    function getTotalVotingPower() external view returns (uint256);

    /**
     * @notice Get the stake data for an account (used for time-weighted voting)
     * @param _account Address to check
     * @return amount Staked token amount
     * @return startTime When the user started staking (0 if never staked)
     * @return rewardsAccruedUSD Total rewards accrued in USD
     * @return rewardsClaimed Total rewards claimed
     * @return lastRewardTime Last time rewards were calculated
     */
    function stakes(address _account) external view returns (
        uint256 amount,
        uint256 startTime,
        uint256 rewardsAccruedUSD,
        uint256 rewardsClaimed,
        uint256 lastRewardTime
    );
}
