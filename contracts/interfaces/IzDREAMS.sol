// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IzDREAMS
 * @notice Interface for the zDREAMS staking receipt token
 *
 * zDREAMS is a non-transferable token that represents staked DREAMS.
 * It provides:
 * 1. Voting power in dispute resolution
 * 2. Ability to boost dream clouds (spend zDREAMS to enlarge clouds)
 */
interface IzDREAMS {
    // ============ EVENTS ============

    event StakingContractUpdated(address indexed oldContract, address indexed newContract);
    event CloudBoostContractUpdated(address indexed oldContract, address indexed newContract);
    event BurnedForBoost(address indexed user, uint256 amount, string dreamId);

    // ============ ERRORS ============

    error OnlyStakingContract();
    error OnlyCloudBoostContract();
    error OnlyAdmin();
    error NotPendingAdmin();
    error TransferDisabled();
    error InvalidAddress();
    error InsufficientBalance();

    // ============ STAKING FUNCTIONS ============

    /**
     * @notice Mint zDREAMS when user stakes DREAMS
     * @param _to Address receiving zDREAMS
     * @param _amount Amount to mint (1:1 with staked DREAMS)
     */
    function mint(address _to, uint256 _amount) external;

    /**
     * @notice Burn zDREAMS when user unstakes DREAMS
     * @param _from Address to burn from
     * @param _amount Amount to burn (1:1 with unstaked DREAMS)
     */
    function burn(address _from, uint256 _amount) external;

    // ============ CLOUD BOOST FUNCTIONS ============

    /**
     * @notice Burn zDREAMS to boost a dream cloud
     * @param _from Address spending zDREAMS
     * @param _amount Amount of zDREAMS to burn
     * @param _dreamId ID of the dream being boosted
     */
    function burnForBoost(address _from, uint256 _amount, string calldata _dreamId) external;

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get voting power for an address
     * @param _account Address to check
     * @return Voting power (= zDREAMS balance)
     */
    function getVotingPower(address _account) external view returns (uint256);

    /**
     * @notice Get total voting power across all stakers
     * @return Total zDREAMS supply
     */
    function getTotalVotingPower() external view returns (uint256);

    /**
     * @notice Get balance of zDREAMS for an account
     * @param _account Address to check
     * @return Balance of zDREAMS
     */
    function balanceOf(address _account) external view returns (uint256);

    /**
     * @notice Get total supply of zDREAMS
     * @return Total zDREAMS minted
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice Get total zDREAMS burned for cloud boosts
     * @return Total burned for boosts
     */
    function totalBurnedForBoosts() external view returns (uint256);

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Set the staking contract address
     * @param _stakingContract New staking contract
     */
    function setStakingContract(address _stakingContract) external;

    /**
     * @notice Set the cloud boost contract address
     * @param _cloudBoostContract New cloud boost contract
     */
    function setCloudBoostContract(address _cloudBoostContract) external;
}
