// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title zDREAMS
 * @notice Non-transferable staking receipt token for DREAMS stakers.
 *
 * WHAT IS zDREAMS?
 * When you stake DREAMS tokens, you receive an equal amount of zDREAMS.
 * Think of it as a receipt that proves your stake and gives you powers:
 *
 * 1. VOTING POWER: Your zDREAMS balance = your voting power in dispute resolution.
 *    The MilestoneCrowdfunding contract uses hybrid quadratic + time-weighted voting,
 *    but your base voting power comes from zDREAMS balance.
 *
 * 2. CLOUD BOOST: Spend zDREAMS to enlarge dream clouds in the UI. This is a visual
 *    reward for stakers - bigger clouds get more attention. The zDREAMS spent on boosts
 *    is burned, reducing supply and increasing scarcity.
 *
 * NON-TRANSFERABLE:
 * - zDREAMS cannot be transferred between wallets
 * - Can only be minted by the DreamsStaking contract when you stake
 * - Can only be burned when you unstake or spend on cloud boosts
 * - This prevents vote-buying and ensures voting power stays with stakers
 *
 * MINTING/BURNING:
 * - Stake 100 DREAMS -> Receive 100 zDREAMS
 * - Unstake 50 DREAMS -> Burn 50 zDREAMS
 * - Boost a cloud with 10 zDREAMS -> Burn 10 zDREAMS (cloud gets bigger!)
 */
contract zDREAMS is ERC20 {
    // ============ STATE ============

    /// @notice The staking contract that can mint/burn zDREAMS
    address public stakingContract;

    /// @notice The cloud boost contract that can burn zDREAMS for boosts
    address public cloudBoostContract;

    /// @notice Admin for updating contract addresses
    address public admin;
    address public pendingAdmin;

    /// @notice Total zDREAMS burned for cloud boosts (tracking metric)
    uint256 public totalBurnedForBoosts;

    // ============ EVENTS ============

    event StakingContractUpdated(address indexed oldContract, address indexed newContract);
    event CloudBoostContractUpdated(address indexed oldContract, address indexed newContract);
    event BurnedForBoost(address indexed user, uint256 amount, string dreamId);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferCompleted(address indexed oldAdmin, address indexed newAdmin);

    // ============ ERRORS ============

    error OnlyStakingContract();
    error OnlyCloudBoostContract();
    error OnlyAdmin();
    error NotPendingAdmin();
    error TransferDisabled();
    error InvalidAddress();
    error InsufficientBalance();

    // ============ MODIFIERS ============

    modifier onlyStakingContract() {
        if (msg.sender != stakingContract) revert OnlyStakingContract();
        _;
    }

    modifier onlyCloudBoostContract() {
        if (msg.sender != cloudBoostContract) revert OnlyCloudBoostContract();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor() ERC20("Staked DREAMS", "zDREAMS") {
        admin = msg.sender;
    }

    // ============ STAKING FUNCTIONS ============

    /**
     * @notice Mint zDREAMS when user stakes DREAMS
     * @dev Only callable by the staking contract
     * @param _to Address receiving zDREAMS
     * @param _amount Amount to mint (1:1 with staked DREAMS)
     */
    function mint(address _to, uint256 _amount) external onlyStakingContract {
        _mint(_to, _amount);
    }

    /**
     * @notice Burn zDREAMS when user unstakes DREAMS
     * @dev Only callable by the staking contract
     * @param _from Address to burn from
     * @param _amount Amount to burn (1:1 with unstaked DREAMS)
     */
    function burn(address _from, uint256 _amount) external onlyStakingContract {
        _burn(_from, _amount);
    }

    // ============ CLOUD BOOST FUNCTIONS ============

    /**
     * @notice Burn zDREAMS to boost a dream cloud
     * @dev Only callable by the cloud boost contract
     * @param _from Address spending zDREAMS
     * @param _amount Amount of zDREAMS to burn
     * @param _dreamId ID of the dream being boosted
     */
    function burnForBoost(
        address _from,
        uint256 _amount,
        string calldata _dreamId
    ) external onlyCloudBoostContract {
        if (balanceOf(_from) < _amount) revert InsufficientBalance();

        _burn(_from, _amount);
        totalBurnedForBoosts += _amount;

        emit BurnedForBoost(_from, _amount, _dreamId);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get voting power for an address
     * @dev This is a simple 1:1 mapping, but MilestoneCrowdfunding applies
     *      additional quadratic and time-weighted calculations
     * @param _account Address to check
     * @return Voting power (= zDREAMS balance)
     */
    function getVotingPower(address _account) external view returns (uint256) {
        return balanceOf(_account);
    }

    /**
     * @notice Get total voting power across all stakers
     * @return Total zDREAMS supply
     */
    function getTotalVotingPower() external view returns (uint256) {
        return totalSupply();
    }

    // ============ TRANSFER OVERRIDES (DISABLED) ============

    /**
     * @notice Transfers are disabled - zDREAMS is non-transferable
     * @dev This prevents vote-buying and ensures voting power stays with stakers
     */
    function transfer(address, uint256) public pure override returns (bool) {
        revert TransferDisabled();
    }

    /**
     * @notice TransferFrom is disabled - zDREAMS is non-transferable
     */
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert TransferDisabled();
    }

    /**
     * @notice Approve is disabled since transfers are disabled
     */
    function approve(address, uint256) public pure override returns (bool) {
        revert TransferDisabled();
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Set the staking contract address
     * @param _stakingContract New staking contract
     */
    function setStakingContract(address _stakingContract) external onlyAdmin {
        if (_stakingContract == address(0)) revert InvalidAddress();
        address oldContract = stakingContract;
        stakingContract = _stakingContract;
        emit StakingContractUpdated(oldContract, _stakingContract);
    }

    /**
     * @notice Set the cloud boost contract address
     * @param _cloudBoostContract New cloud boost contract
     */
    function setCloudBoostContract(address _cloudBoostContract) external onlyAdmin {
        if (_cloudBoostContract == address(0)) revert InvalidAddress();
        address oldContract = cloudBoostContract;
        cloudBoostContract = _cloudBoostContract;
        emit CloudBoostContractUpdated(oldContract, _cloudBoostContract);
    }

    /**
     * @notice Initiate admin transfer (2-step for safety)
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
