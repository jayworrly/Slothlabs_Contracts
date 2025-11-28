// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/IzDREAMS.sol";

/**
 * @title MockZDreams
 * @notice Mock zDREAMS token for testing DreamsTreasuryBuyback
 * @dev Implements IzDREAMS interface with ERC20 for testing
 *      In production zDREAMS is non-transferable, but for testing we allow transfers
 */
contract MockZDreams is ERC20, IzDREAMS {
    address public stakingContract;
    address public cloudBoostContract;
    address public admin;
    uint256 public totalBurnedForBoosts;

    // Allow anyone to mint for testing
    bool public publicMintEnabled = true;

    constructor() ERC20("Mock zDREAMS", "zDRM") {
        admin = msg.sender;
    }

    // ============ Testing Functions ============

    /**
     * @notice Public mint for testing purposes
     */
    function publicMint(address to, uint256 amount) external {
        require(publicMintEnabled, "Public mint disabled");
        _mint(to, amount);
    }

    /**
     * @notice Enable/disable public minting
     */
    function setPublicMint(bool enabled) external {
        require(msg.sender == admin, "Only admin");
        publicMintEnabled = enabled;
    }

    // ============ IzDREAMS Interface ============

    function mint(address _to, uint256 _amount) external override {
        // In production only staking contract can mint
        // For testing, allow any caller
        _mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) external override {
        // In production only staking contract can burn
        // For testing, allow any caller (or check caller is staking contract)
        _burn(_from, _amount);
    }

    function burnForBoost(
        address _from,
        uint256 _amount,
        string calldata _dreamId
    ) external override {
        require(balanceOf(_from) >= _amount, "Insufficient balance");
        _burn(_from, _amount);
        totalBurnedForBoosts += _amount;
        emit BurnedForBoost(_from, _amount, _dreamId);
    }

    function getVotingPower(address _account) external view override returns (uint256) {
        return balanceOf(_account);
    }

    function getTotalVotingPower() external view override returns (uint256) {
        return totalSupply();
    }

    function setStakingContract(address _stakingContract) external override {
        require(msg.sender == admin, "Only admin");
        address oldContract = stakingContract;
        stakingContract = _stakingContract;
        emit StakingContractUpdated(oldContract, _stakingContract);
    }

    function setCloudBoostContract(address _cloudBoostContract) external override {
        require(msg.sender == admin, "Only admin");
        address oldContract = cloudBoostContract;
        cloudBoostContract = _cloudBoostContract;
        emit CloudBoostContractUpdated(oldContract, _cloudBoostContract);
    }

    // Override balanceOf to satisfy the interface
    function balanceOf(address _account) public view override(ERC20, IzDREAMS) returns (uint256) {
        return super.balanceOf(_account);
    }

    // Override totalSupply to satisfy the interface
    function totalSupply() public view override(ERC20, IzDREAMS) returns (uint256) {
        return super.totalSupply();
    }
}
