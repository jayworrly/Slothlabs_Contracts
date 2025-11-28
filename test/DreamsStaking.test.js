const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("DreamsStaking", function () {
  let staking;
  let dreamsToken, rewardToken;
  let mockOracle;
  let owner, treasury, user1, user2;

  const CLIFF_PERIOD = 30 * 24 * 60 * 60; // 30 days
  const VESTING_PERIOD = 180 * 24 * 60 * 60; // 180 days
  const EARLY_UNSTAKE_PENALTY_BPS = 2000; // 20%

  beforeEach(async function () {
    [owner, treasury, user1, user2] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    dreamsToken = await MockERC20.deploy("DREAMS Token", "DREAMS", 18);
    rewardToken = await MockERC20.deploy("JUICY Token", "JUICY", 18);

    // Deploy mock price oracle
    const MockPriceOracle = await ethers.getContractFactory("MockPriceOracle");
    mockOracle = await MockPriceOracle.deploy();

    // Set prices (8 decimals)
    await mockOracle.setPrice(await dreamsToken.getAddress(), 100000000); // $1
    await mockOracle.setPrice(await rewardToken.getAddress(), 50000000);  // $0.50

    // Deploy staking contract
    const DreamsStaking = await ethers.getContractFactory("DreamsStaking");
    staking = await DreamsStaking.deploy(
      await dreamsToken.getAddress(),
      await rewardToken.getAddress(),
      await mockOracle.getAddress(),
      treasury.address
    );

    // Mint tokens to users
    await dreamsToken.mint(user1.address, ethers.parseEther("10000"));
    await dreamsToken.mint(user2.address, ethers.parseEther("10000"));

    // Approve staking contract
    await dreamsToken.connect(user1).approve(await staking.getAddress(), ethers.MaxUint256);
    await dreamsToken.connect(user2).approve(await staking.getAddress(), ethers.MaxUint256);

    // Fund staking contract with rewards
    await rewardToken.mint(await staking.getAddress(), ethers.parseEther("1000000"));

    // Set reward rate: 0.01 USD per second per staked token (scaled by 1e18)
    // This means 1000 staked DREAMS earns ~$864 USD per day
    await staking.setRewardRate(ethers.parseEther("0.00001")); // More reasonable rate
  });

  describe("Constructor Validation", function () {
    it("should deploy with valid parameters", async function () {
      expect(await staking.dreamsToken()).to.equal(await dreamsToken.getAddress());
      expect(await staking.rewardToken()).to.equal(await rewardToken.getAddress());
      expect(await staking.treasury()).to.equal(treasury.address);
      expect(await staking.admin()).to.equal(owner.address);
    });

    it("should reject zero DREAMS token address", async function () {
      const DreamsStaking = await ethers.getContractFactory("DreamsStaking");
      await expect(
        DreamsStaking.deploy(
          ethers.ZeroAddress,
          await rewardToken.getAddress(),
          await mockOracle.getAddress(),
          treasury.address
        )
      ).to.be.revertedWithCustomError(staking, "InvalidAddress");
    });

    it("should reject zero reward token address", async function () {
      const DreamsStaking = await ethers.getContractFactory("DreamsStaking");
      await expect(
        DreamsStaking.deploy(
          await dreamsToken.getAddress(),
          ethers.ZeroAddress,
          await mockOracle.getAddress(),
          treasury.address
        )
      ).to.be.revertedWithCustomError(staking, "InvalidAddress");
    });

    it("should reject zero oracle address", async function () {
      const DreamsStaking = await ethers.getContractFactory("DreamsStaking");
      await expect(
        DreamsStaking.deploy(
          await dreamsToken.getAddress(),
          await rewardToken.getAddress(),
          ethers.ZeroAddress,
          treasury.address
        )
      ).to.be.revertedWithCustomError(staking, "InvalidAddress");
    });

    it("should reject zero treasury address", async function () {
      const DreamsStaking = await ethers.getContractFactory("DreamsStaking");
      await expect(
        DreamsStaking.deploy(
          await dreamsToken.getAddress(),
          await rewardToken.getAddress(),
          await mockOracle.getAddress(),
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(staking, "InvalidAddress");
    });
  });

  describe("Staking", function () {
    it("should allow staking DREAMS tokens", async function () {
      const stakeAmount = ethers.parseEther("1000");

      await expect(staking.connect(user1).stake(stakeAmount))
        .to.emit(staking, "Staked");

      const stakeInfo = await staking.stakes(user1.address);
      expect(stakeInfo.amount).to.equal(stakeAmount);
      expect(await staking.totalStaked()).to.equal(stakeAmount);
    });

    it("should transfer tokens from user to contract", async function () {
      const stakeAmount = ethers.parseEther("1000");
      const userBalanceBefore = await dreamsToken.balanceOf(user1.address);

      await staking.connect(user1).stake(stakeAmount);

      const userBalanceAfter = await dreamsToken.balanceOf(user1.address);
      expect(userBalanceAfter).to.equal(userBalanceBefore - stakeAmount);
      expect(await dreamsToken.balanceOf(await staking.getAddress())).to.equal(stakeAmount);
    });

    it("should track voting power", async function () {
      const stakeAmount = ethers.parseEther("1000");

      await staking.connect(user1).stake(stakeAmount);

      expect(await staking.getVotingPower(user1.address)).to.equal(stakeAmount);
      expect(await staking.getTotalVotingPower()).to.equal(stakeAmount);
    });

    it("should allow adding to existing stake", async function () {
      const firstStake = ethers.parseEther("500");
      const secondStake = ethers.parseEther("500");

      await staking.connect(user1).stake(firstStake);
      await staking.connect(user1).stake(secondStake);

      const stakeInfo = await staking.stakes(user1.address);
      expect(stakeInfo.amount).to.equal(firstStake + secondStake);
    });

    it("should revert when staking zero amount", async function () {
      await expect(
        staking.connect(user1).stake(0)
      ).to.be.revertedWithCustomError(staking, "InvalidAmount");
    });

    it("should update totalVotingPower on stake", async function () {
      await staking.connect(user1).stake(ethers.parseEther("1000"));
      await staking.connect(user2).stake(ethers.parseEther("2000"));

      expect(await staking.getTotalVotingPower()).to.equal(ethers.parseEther("3000"));
    });
  });

  describe("Vesting", function () {
    const stakeAmount = ethers.parseEther("1000");

    beforeEach(async function () {
      await staking.connect(user1).stake(stakeAmount);
    });

    it("should return 0 vested before cliff period", async function () {
      expect(await staking.getVestedAmount(user1.address)).to.equal(0);

      // Advance 15 days (half cliff)
      await time.increase(15 * 24 * 60 * 60);
      expect(await staking.getVestedAmount(user1.address)).to.equal(0);
    });

    it("should vest linearly after cliff period", async function () {
      // Skip cliff period
      await time.increase(CLIFF_PERIOD);

      // At cliff end, 0% vested (vesting period just starting)
      expect(await staking.getVestedAmount(user1.address)).to.equal(0);

      // 50% through vesting period
      await time.increase(VESTING_PERIOD / 2);
      const vestedHalf = await staking.getVestedAmount(user1.address);
      // Should be approximately 50% (allow 1% tolerance for block timing)
      expect(vestedHalf).to.be.closeTo(stakeAmount / 2n, stakeAmount / 100n);

      // 100% through vesting period
      await time.increase(VESTING_PERIOD / 2);
      const vestedFull = await staking.getVestedAmount(user1.address);
      expect(vestedFull).to.equal(stakeAmount);
    });

    it("should return full amount after complete vesting", async function () {
      // Skip cliff + vesting period
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD);

      expect(await staking.getVestedAmount(user1.address)).to.equal(stakeAmount);

      // Even more time later
      await time.increase(365 * 24 * 60 * 60);
      expect(await staking.getVestedAmount(user1.address)).to.equal(stakeAmount);
    });
  });

  describe("Unstaking", function () {
    const stakeAmount = ethers.parseEther("1000");

    beforeEach(async function () {
      await staking.connect(user1).stake(stakeAmount);
    });

    it("should apply penalty for early unstake", async function () {
      const userBalanceBefore = await dreamsToken.balanceOf(user1.address);
      const treasuryBalanceBefore = await dreamsToken.balanceOf(treasury.address);

      await staking.connect(user1).unstake(stakeAmount);

      const userBalanceAfter = await dreamsToken.balanceOf(user1.address);
      const treasuryBalanceAfter = await dreamsToken.balanceOf(treasury.address);

      // 20% penalty on unvested (full amount is unvested before cliff)
      const expectedPenalty = (stakeAmount * 2000n) / 10000n; // 200 DREAMS
      const expectedReturn = stakeAmount - expectedPenalty; // 800 DREAMS

      expect(userBalanceAfter - userBalanceBefore).to.equal(expectedReturn);
      expect(treasuryBalanceAfter - treasuryBalanceBefore).to.equal(expectedPenalty);
    });

    it("should not apply penalty after full vesting", async function () {
      // Skip cliff + vesting
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD);

      const userBalanceBefore = await dreamsToken.balanceOf(user1.address);

      await staking.connect(user1).unstake(stakeAmount);

      const userBalanceAfter = await dreamsToken.balanceOf(user1.address);

      // No penalty - full amount returned
      expect(userBalanceAfter - userBalanceBefore).to.equal(stakeAmount);
    });

    it("should apply partial penalty during vesting", async function () {
      // Skip cliff + half vesting (50% vested)
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD / 2);

      const vestedAmount = await staking.getVestedAmount(user1.address);
      const unvestedAmount = stakeAmount - vestedAmount;

      const userBalanceBefore = await dreamsToken.balanceOf(user1.address);

      await staking.connect(user1).unstake(stakeAmount);

      const userBalanceAfter = await dreamsToken.balanceOf(user1.address);

      // Penalty only applies to unvested portion
      const expectedPenalty = (unvestedAmount * 2000n) / 10000n;
      const expectedReturn = stakeAmount - expectedPenalty;

      // Allow small tolerance for block timing
      expect(userBalanceAfter - userBalanceBefore).to.be.closeTo(expectedReturn, ethers.parseEther("1"));
    });

    it("should emit Unstaked event with penalty", async function () {
      const expectedPenalty = (stakeAmount * 2000n) / 10000n;
      const expectedReturn = stakeAmount - expectedPenalty;

      await expect(staking.connect(user1).unstake(stakeAmount))
        .to.emit(staking, "Unstaked")
        .withArgs(user1.address, expectedReturn, expectedPenalty);
    });

    it("should revert unstaking zero amount", async function () {
      await expect(
        staking.connect(user1).unstake(0)
      ).to.be.revertedWithCustomError(staking, "InvalidAmount");
    });

    it("should revert unstaking more than staked", async function () {
      await expect(
        staking.connect(user1).unstake(stakeAmount + 1n)
      ).to.be.revertedWithCustomError(staking, "InsufficientBalance");
    });

    it("should reset stake info when fully unstaked", async function () {
      await staking.connect(user1).unstake(stakeAmount);

      const stakeInfo = await staking.stakes(user1.address);
      expect(stakeInfo.amount).to.equal(0);
      expect(stakeInfo.startTime).to.equal(0);
    });

    it("should update voting power on unstake", async function () {
      expect(await staking.getVotingPower(user1.address)).to.equal(stakeAmount);

      await staking.connect(user1).unstake(stakeAmount);

      expect(await staking.getVotingPower(user1.address)).to.equal(0);
      expect(await staking.getTotalVotingPower()).to.equal(0);
    });
  });

  describe("Rewards (USD-denominated)", function () {
    const stakeAmount = ethers.parseEther("1000");

    beforeEach(async function () {
      await staking.connect(user1).stake(stakeAmount);
    });

    it("should accrue rewards over time", async function () {
      // Skip 1 day
      await time.increase(24 * 60 * 60);

      const pendingUSD = await staking.getPendingRewardsUSD(user1.address);
      expect(pendingUSD).to.be.gt(0);
    });

    it("should not allow claiming before cliff", async function () {
      // Skip 15 days (before cliff)
      await time.increase(15 * 24 * 60 * 60);

      await expect(
        staking.connect(user1).claimRewards()
      ).to.be.revertedWithCustomError(staking, "CliffNotReached");
    });

    it("should allow claiming after cliff", async function () {
      // Skip cliff period
      await time.increase(CLIFF_PERIOD);

      const pendingUSD = await staking.getPendingRewardsUSD(user1.address);
      expect(pendingUSD).to.be.gt(0);

      const rewardBalanceBefore = await rewardToken.balanceOf(user1.address);

      await staking.connect(user1).claimRewards();

      const rewardBalanceAfter = await rewardToken.balanceOf(user1.address);
      expect(rewardBalanceAfter).to.be.gt(rewardBalanceBefore);
    });

    it("should convert USD to tokens at current price", async function () {
      // Skip cliff period
      await time.increase(CLIFF_PERIOD);

      const pendingUSD = await staking.getPendingRewardsUSD(user1.address);
      // Reward token price is $0.50 (50000000 with 8 decimals)
      // So USD rewards / 0.50 = token amount
      const expectedTokens = (pendingUSD * BigInt(1e8)) / BigInt(50000000);

      const pendingTokens = await staking.getPendingRewardsTokens(user1.address);

      // Allow 1% tolerance for timing
      expect(pendingTokens).to.be.closeTo(expectedTokens, expectedTokens / 100n);
    });

    it("should reset accrued rewards after claim", async function () {
      // Skip cliff period
      await time.increase(CLIFF_PERIOD);

      await staking.connect(user1).claimRewards();

      const pendingUSD = await staking.getPendingRewardsUSD(user1.address);
      // Should be very small (just accrued in the same block)
      expect(pendingUSD).to.be.lt(ethers.parseEther("0.01"));
    });

    it("should emit RewardsClaimed event", async function () {
      // Skip cliff period
      await time.increase(CLIFF_PERIOD);

      await expect(staking.connect(user1).claimRewards())
        .to.emit(staking, "RewardsClaimed");
    });

    it("should revert claiming with no rewards", async function () {
      // Skip cliff but set reward rate to 0
      await staking.setRewardRate(0);
      await time.increase(CLIFF_PERIOD);

      await expect(
        staking.connect(user1).claimRewards()
      ).to.be.revertedWithCustomError(staking, "NoRewardsToClaim");
    });
  });

  describe("Compound Rewards", function () {
    let stakingWithDreamsReward;

    beforeEach(async function () {
      // Deploy new staking where reward token = DREAMS (for compounding)
      const DreamsStaking = await ethers.getContractFactory("DreamsStaking");
      stakingWithDreamsReward = await DreamsStaking.deploy(
        await dreamsToken.getAddress(),
        await dreamsToken.getAddress(), // reward = dreams
        await mockOracle.getAddress(),
        treasury.address
      );

      // Approve and stake
      await dreamsToken.connect(user1).approve(await stakingWithDreamsReward.getAddress(), ethers.MaxUint256);
      await stakingWithDreamsReward.connect(user1).stake(ethers.parseEther("1000"));

      // Fund contract with DREAMS for rewards
      await dreamsToken.mint(await stakingWithDreamsReward.getAddress(), ethers.parseEther("100000"));

      // Set reward rate
      await stakingWithDreamsReward.setRewardRate(ethers.parseEther("0.00001"));
    });

    it("should compound rewards and extend lock period", async function () {
      // Skip cliff period
      await time.increase(CLIFF_PERIOD);

      const stakeInfoBefore = await stakingWithDreamsReward.stakes(user1.address);
      const stakedBefore = stakeInfoBefore.amount;

      await stakingWithDreamsReward.connect(user1).compoundRewards();

      const stakeInfoAfter = await stakingWithDreamsReward.stakes(user1.address);

      // Staked amount should increase
      expect(stakeInfoAfter.amount).to.be.gt(stakedBefore);

      // Start time should be reset (lock extended)
      expect(stakeInfoAfter.startTime).to.be.gt(stakeInfoBefore.startTime);
    });

    it("should emit RewardsCompounded event", async function () {
      // Skip cliff period
      await time.increase(CLIFF_PERIOD);

      await expect(stakingWithDreamsReward.connect(user1).compoundRewards())
        .to.emit(stakingWithDreamsReward, "RewardsCompounded");
    });

    it("should not allow compound before cliff", async function () {
      await expect(
        stakingWithDreamsReward.connect(user1).compoundRewards()
      ).to.be.revertedWithCustomError(stakingWithDreamsReward, "CliffNotReached");
    });

    it("should not allow compound when reward token != DREAMS", async function () {
      // Skip cliff period on original staking (where reward is JUICY, not DREAMS)
      await time.increase(CLIFF_PERIOD);

      await expect(
        staking.connect(user1).compoundRewards()
      ).to.be.revertedWithCustomError(staking, "CannotCompoundNonDreams");
    });

    it("should update voting power after compound", async function () {
      // Skip cliff period
      await time.increase(CLIFF_PERIOD);

      const votingPowerBefore = await stakingWithDreamsReward.getVotingPower(user1.address);

      await stakingWithDreamsReward.connect(user1).compoundRewards();

      const votingPowerAfter = await stakingWithDreamsReward.getVotingPower(user1.address);
      expect(votingPowerAfter).to.be.gt(votingPowerBefore);
    });
  });

  describe("View Functions", function () {
    const stakeAmount = ethers.parseEther("1000");

    beforeEach(async function () {
      await staking.connect(user1).stake(stakeAmount);
    });

    it("should return correct stake info", async function () {
      const info = await staking.getStakeInfo(user1.address);

      expect(info.stakedAmount).to.equal(stakeAmount);
      expect(info.votingPower).to.equal(stakeAmount);
      expect(info.cliffReached).to.equal(false);
    });

    it("should show cliff reached after cliff period", async function () {
      await time.increase(CLIFF_PERIOD);

      const info = await staking.getStakeInfo(user1.address);
      expect(info.cliffReached).to.equal(true);
    });

    it("should return zero for non-staker", async function () {
      expect(await staking.getVotingPower(user2.address)).to.equal(0);
      expect(await staking.getVestedAmount(user2.address)).to.equal(0);
    });
  });

  describe("Admin Functions", function () {
    it("should allow admin to set reward rate", async function () {
      const newRate = ethers.parseEther("0.001");

      await expect(staking.setRewardRate(newRate))
        .to.emit(staking, "RewardRateUpdated");

      expect(await staking.rewardRateUSDPerSecond()).to.equal(newRate);
    });

    it("should allow admin to set vesting config", async function () {
      const newCliff = 7 * 24 * 60 * 60; // 7 days
      const newVesting = 90 * 24 * 60 * 60; // 90 days
      const newPenalty = 1000; // 10%

      await expect(staking.setVestingConfig(newCliff, newVesting, newPenalty))
        .to.emit(staking, "VestingConfigUpdated");

      expect(await staking.cliffPeriod()).to.equal(newCliff);
      expect(await staking.vestingPeriod()).to.equal(newVesting);
      expect(await staking.earlyUnstakePenaltyBps()).to.equal(newPenalty);
    });

    it("should reject penalty over 50%", async function () {
      await expect(
        staking.setVestingConfig(CLIFF_PERIOD, VESTING_PERIOD, 5001)
      ).to.be.revertedWithCustomError(staking, "InvalidConfiguration");
    });

    it("should allow admin to set price oracle", async function () {
      const newOracle = ethers.Wallet.createRandom().address;
      await staking.setPriceOracle(newOracle);
      expect(await staking.priceOracle()).to.equal(newOracle);
    });

    it("should allow admin to set treasury", async function () {
      const newTreasury = ethers.Wallet.createRandom().address;
      await staking.setTreasury(newTreasury);
      expect(await staking.treasury()).to.equal(newTreasury);
    });

    it("should allow anyone to deposit rewards", async function () {
      const depositAmount = ethers.parseEther("1000");
      await rewardToken.mint(user1.address, depositAmount);
      await rewardToken.connect(user1).approve(await staking.getAddress(), depositAmount);

      await expect(staking.connect(user1).depositRewards(depositAmount))
        .to.emit(staking, "RewardsDeposited");
    });

    it("should reject non-admin calls", async function () {
      await expect(
        staking.connect(user1).setRewardRate(0)
      ).to.be.revertedWithCustomError(staking, "OnlyAdmin");

      await expect(
        staking.connect(user1).setVestingConfig(0, 0, 0)
      ).to.be.revertedWithCustomError(staking, "OnlyAdmin");

      await expect(
        staking.connect(user1).setPriceOracle(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(staking, "OnlyAdmin");

      await expect(
        staking.connect(user1).setTreasury(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(staking, "OnlyAdmin");
    });
  });

  describe("Admin Transfer (Two-Step)", function () {
    it("should allow admin to initiate transfer", async function () {
      await expect(staking.initiateAdminTransfer(user1.address))
        .to.emit(staking, "AdminTransferInitiated")
        .withArgs(owner.address, user1.address);

      expect(await staking.pendingAdmin()).to.equal(user1.address);
    });

    it("should allow pending admin to accept transfer", async function () {
      await staking.initiateAdminTransfer(user1.address);

      await expect(staking.connect(user1).acceptAdminTransfer())
        .to.emit(staking, "AdminTransferCompleted")
        .withArgs(owner.address, user1.address);

      expect(await staking.admin()).to.equal(user1.address);
      expect(await staking.pendingAdmin()).to.equal(ethers.ZeroAddress);
    });

    it("should reject non-pending admin accepting transfer", async function () {
      await staking.initiateAdminTransfer(user1.address);

      await expect(
        staking.connect(user2).acceptAdminTransfer()
      ).to.be.revertedWithCustomError(staking, "NotPendingAdmin");
    });

    it("should reject initiating transfer to zero address", async function () {
      await expect(
        staking.initiateAdminTransfer(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(staking, "InvalidAddress");
    });
  });

  describe("Rescue Tokens", function () {
    it("should allow rescuing excess tokens", async function () {
      // Stake some DREAMS
      await staking.connect(user1).stake(ethers.parseEther("1000"));

      // Accidentally send extra DREAMS to contract
      await dreamsToken.mint(await staking.getAddress(), ethers.parseEther("500"));

      // Can rescue the excess 500 but not the staked 1000
      await staking.rescueTokens(await dreamsToken.getAddress(), ethers.parseEther("500"));

      // Try to rescue more than excess
      await expect(
        staking.rescueTokens(await dreamsToken.getAddress(), ethers.parseEther("1"))
      ).to.be.revertedWith("Cannot withdraw staked tokens");
    });

    it("should allow rescuing reward tokens", async function () {
      const rescueAmount = ethers.parseEther("100");
      const adminBalanceBefore = await rewardToken.balanceOf(owner.address);

      await staking.rescueTokens(await rewardToken.getAddress(), rescueAmount);

      const adminBalanceAfter = await rewardToken.balanceOf(owner.address);
      expect(adminBalanceAfter - adminBalanceBefore).to.equal(rescueAmount);
    });
  });

  describe("StakeFor (Auto-Lock Feature)", function () {
    let treasurySale; // Simulated treasury sale contract

    beforeEach(async function () {
      // Use owner as simulated treasury sale contract
      treasurySale = owner;
      // Mint DREAMS to treasury sale
      await dreamsToken.mint(treasurySale.address, ethers.parseEther("100000"));
      // Approve staking contract
      await dreamsToken.connect(treasurySale).approve(await staking.getAddress(), ethers.MaxUint256);
    });

    it("should allow staking on behalf of another user", async function () {
      const stakeAmount = ethers.parseEther("1000");

      await expect(staking.connect(treasurySale).stakeFor(user1.address, stakeAmount))
        .to.emit(staking, "StakedFor")
        .withArgs(user1.address, treasurySale.address, stakeAmount, await time.latest() + CLIFF_PERIOD + VESTING_PERIOD + 1);

      // Check beneficiary has staked tokens
      const stakeInfo = await staking.stakes(user1.address);
      expect(stakeInfo.amount).to.equal(stakeAmount);

      // Check voting power assigned to beneficiary
      expect(await staking.getVotingPower(user1.address)).to.equal(stakeAmount);
    });

    it("should pull tokens from caller, not beneficiary", async function () {
      const stakeAmount = ethers.parseEther("1000");

      const callerBalanceBefore = await dreamsToken.balanceOf(treasurySale.address);
      const beneficiaryBalanceBefore = await dreamsToken.balanceOf(user1.address);

      await staking.connect(treasurySale).stakeFor(user1.address, stakeAmount);

      const callerBalanceAfter = await dreamsToken.balanceOf(treasurySale.address);
      const beneficiaryBalanceAfter = await dreamsToken.balanceOf(user1.address);

      // Caller's balance should decrease
      expect(callerBalanceBefore - callerBalanceAfter).to.equal(stakeAmount);

      // Beneficiary's balance should not change
      expect(beneficiaryBalanceAfter).to.equal(beneficiaryBalanceBefore);
    });

    it("should allow beneficiary to unstake their tokens", async function () {
      const stakeAmount = ethers.parseEther("1000");

      await staking.connect(treasurySale).stakeFor(user1.address, stakeAmount);

      // Skip cliff + vesting for no penalty
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD);

      const userBalanceBefore = await dreamsToken.balanceOf(user1.address);

      await staking.connect(user1).unstake(stakeAmount);

      const userBalanceAfter = await dreamsToken.balanceOf(user1.address);
      expect(userBalanceAfter - userBalanceBefore).to.equal(stakeAmount);
    });

    it("should add to existing stake if beneficiary already staking", async function () {
      const firstStake = ethers.parseEther("500");
      const secondStake = ethers.parseEther("500");

      // User stakes first
      await staking.connect(user1).stake(firstStake);

      // Treasury stakes on their behalf
      await staking.connect(treasurySale).stakeFor(user1.address, secondStake);

      const stakeInfo = await staking.stakes(user1.address);
      expect(stakeInfo.amount).to.equal(firstStake + secondStake);
    });

    it("should accrue rewards for beneficiary", async function () {
      const stakeAmount = ethers.parseEther("1000");

      await staking.connect(treasurySale).stakeFor(user1.address, stakeAmount);

      // Skip time
      await time.increase(24 * 60 * 60); // 1 day

      const pendingUSD = await staking.getPendingRewardsUSD(user1.address);
      expect(pendingUSD).to.be.gt(0);
    });

    it("should revert stakeFor with zero amount", async function () {
      await expect(
        staking.connect(treasurySale).stakeFor(user1.address, 0)
      ).to.be.revertedWithCustomError(staking, "InvalidAmount");
    });

    it("should revert stakeFor with zero address beneficiary", async function () {
      await expect(
        staking.connect(treasurySale).stakeFor(ethers.ZeroAddress, ethers.parseEther("1000"))
      ).to.be.revertedWithCustomError(staking, "InvalidAddress");
    });

    it("should update totalStaked and totalVotingPower", async function () {
      const stakeAmount = ethers.parseEther("1000");

      const totalStakedBefore = await staking.totalStaked();
      const totalVotingPowerBefore = await staking.getTotalVotingPower();

      await staking.connect(treasurySale).stakeFor(user1.address, stakeAmount);

      expect(await staking.totalStaked()).to.equal(totalStakedBefore + stakeAmount);
      expect(await staking.getTotalVotingPower()).to.equal(totalVotingPowerBefore + stakeAmount);
    });
  });

  describe("UnstakeForBuyback (Proportional Burn)", function () {
    let buybackContract;
    let zDreamsToken;

    beforeEach(async function () {
      // Get a signer to act as buyback contract
      const signers = await ethers.getSigners();
      buybackContract = signers[4];

      // Deploy mock zDREAMS
      const MockZDreams = await ethers.getContractFactory("MockZDreams");
      zDreamsToken = await MockZDreams.deploy();

      // Set buyback contract
      await staking.setBuybackContract(buybackContract.address);

      // Set zDREAMS token
      await staking.setZDreamsToken(await zDreamsToken.getAddress());
    });

    it("should only allow buyback contract to call", async function () {
      const stakeAmount = ethers.parseEther("1000");
      await staking.connect(user1).stake(stakeAmount);

      // Advance past cliff
      await time.increase(CLIFF_PERIOD + 1);

      await expect(
        staking.connect(user1).unstakeForBuyback(user1.address, stakeAmount, user1.address)
      ).to.be.revertedWithCustomError(staking, "OnlyBuybackContract");
    });

    it("should reject zero amount", async function () {
      const stakeAmount = ethers.parseEther("1000");
      await staking.connect(user1).stake(stakeAmount);

      await expect(
        staking.connect(buybackContract).unstakeForBuyback(user1.address, 0, user1.address)
      ).to.be.revertedWithCustomError(staking, "InvalidAmount");
    });

    it("should reject zero recipient address", async function () {
      const stakeAmount = ethers.parseEther("1000");
      await staking.connect(user1).stake(stakeAmount);

      await expect(
        staking.connect(buybackContract).unstakeForBuyback(user1.address, stakeAmount, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(staking, "InvalidAddress");
    });

    it("should reject if user has insufficient staked balance", async function () {
      const stakeAmount = ethers.parseEther("1000");
      await staking.connect(user1).stake(stakeAmount);

      await expect(
        staking.connect(buybackContract).unstakeForBuyback(user1.address, stakeAmount + 1n, user1.address)
      ).to.be.revertedWithCustomError(staking, "InsufficientBalance");
    });

    it("should transfer DREAMS to recipient (buyback contract)", async function () {
      const stakeAmount = ethers.parseEther("1000");
      await staking.connect(user1).stake(stakeAmount);

      // Advance past full vesting (no penalty)
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD + 1);

      const recipientBalanceBefore = await dreamsToken.balanceOf(buybackContract.address);

      await staking.connect(buybackContract).unstakeForBuyback(
        user1.address,
        stakeAmount,
        buybackContract.address
      );

      const recipientBalanceAfter = await dreamsToken.balanceOf(buybackContract.address);
      expect(recipientBalanceAfter - recipientBalanceBefore).to.equal(stakeAmount);
    });

    it("should apply penalty on unvested portion", async function () {
      const stakeAmount = ethers.parseEther("1000");
      await staking.connect(user1).stake(stakeAmount);

      // Advance to just past cliff (no vesting yet)
      await time.increase(CLIFF_PERIOD + 1);

      const treasuryBalanceBefore = await dreamsToken.balanceOf(treasury.address);
      const recipientBalanceBefore = await dreamsToken.balanceOf(buybackContract.address);

      // At cliff+1 second, almost nothing is vested, so penalty on almost full amount
      const tx = await staking.connect(buybackContract).unstakeForBuyback(
        user1.address,
        stakeAmount,
        buybackContract.address
      );

      const treasuryBalanceAfter = await dreamsToken.balanceOf(treasury.address);
      const recipientBalanceAfter = await dreamsToken.balanceOf(buybackContract.address);

      // Penalty should be 20% of unvested portion
      const penaltyReceived = treasuryBalanceAfter - treasuryBalanceBefore;
      const dreamsReceived = recipientBalanceAfter - recipientBalanceBefore;

      expect(penaltyReceived).to.be.gt(0);
      expect(dreamsReceived + penaltyReceived).to.equal(stakeAmount);
    });

    it("should apply no penalty on fully vested stake", async function () {
      const stakeAmount = ethers.parseEther("1000");
      await staking.connect(user1).stake(stakeAmount);

      // Advance past full vesting
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD + 1);

      const treasuryBalanceBefore = await dreamsToken.balanceOf(treasury.address);

      await staking.connect(buybackContract).unstakeForBuyback(
        user1.address,
        stakeAmount,
        buybackContract.address
      );

      const treasuryBalanceAfter = await dreamsToken.balanceOf(treasury.address);

      // No penalty for fully vested stake
      expect(treasuryBalanceAfter - treasuryBalanceBefore).to.equal(0);
    });

    it("should burn proportional zDREAMS when user has no bonus", async function () {
      const stakeAmount = ethers.parseEther("1000");

      // Don't pre-mint zDREAMS - stake() will mint 1:1 for regular staking
      await zDreamsToken.connect(user1).approve(await staking.getAddress(), ethers.MaxUint256);

      await staking.connect(user1).stake(stakeAmount);

      // Advance past full vesting
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD + 1);

      const zBalanceBefore = await zDreamsToken.balanceOf(user1.address);
      // stake() mints 1000 zDREAMS (1:1 ratio for regular stake)
      expect(zBalanceBefore).to.equal(stakeAmount);

      // Unstake half
      const unstakeAmount = stakeAmount / 2n;
      await staking.connect(buybackContract).unstakeForBuyback(
        user1.address,
        unstakeAmount,
        buybackContract.address
      );

      const zBalanceAfter = await zDreamsToken.balanceOf(user1.address);

      // Should burn proportional amount (50% of zDREAMS since unstaking 50% of stake)
      // Note: the calculation is zBalance * _amount / (userStake.amount + _amount)
      // After unstake, userStake.amount is 500, and _amount was 500
      // So: 1000 * 500 / (500 + 500) = 1000 * 500 / 1000 = 500
      expect(zBalanceBefore - zBalanceAfter).to.equal(unstakeAmount);
    });

    it("should burn proportional zDREAMS when user has treasury bonus", async function () {
      const stakeAmount = ethers.parseEther("1000");
      const treasuryBonusBps = 1000n; // 10% bonus = 1000 basis points
      const totalZDreams = stakeAmount + (stakeAmount * treasuryBonusBps) / 10000n; // 1100 zDREAMS

      // Get treasury sale signer
      const signers = await ethers.getSigners();
      const treasurySale = signers[5];

      // Set treasury sale contract
      await staking.setTreasurySaleContract(treasurySale.address);

      // Approve staking contract and mint DREAMS to treasury sale
      await dreamsToken.mint(treasurySale.address, stakeAmount);
      await dreamsToken.connect(treasurySale).approve(await staking.getAddress(), ethers.MaxUint256);
      await zDreamsToken.connect(user1).approve(await staking.getAddress(), ethers.MaxUint256);

      // Stake via treasury (gets 10% bonus zDREAMS)
      await staking.connect(treasurySale).stakeFor(user1.address, stakeAmount);

      // Advance past full vesting
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD + 1);

      const zBalanceBefore = await zDreamsToken.balanceOf(user1.address);
      // stakeFor from treasury mints 1100 zDREAMS (1000 + 10% bonus)
      expect(zBalanceBefore).to.equal(totalZDreams);

      // Unstake half the DREAMS (500)
      const unstakeAmount = stakeAmount / 2n;
      await staking.connect(buybackContract).unstakeForBuyback(
        user1.address,
        unstakeAmount,
        buybackContract.address
      );

      const zBalanceAfter = await zDreamsToken.balanceOf(user1.address);

      // Proportional burn: zBalance * _amount / (userStake.amount + _amount)
      // After unstake, userStake.amount = 500
      // zToBurn = 1100 * 500 / (500 + 500) = 1100 * 500 / 1000 = 550
      // This means user loses bonus proportionally
      const expectedBurn = (totalZDreams * unstakeAmount) / stakeAmount;
      expect(zBalanceBefore - zBalanceAfter).to.equal(expectedBurn);
    });

    it("should handle multiple partial unstakes correctly", async function () {
      const stakeAmount = ethers.parseEther("1000");

      // Don't pre-mint - stake() will mint zDREAMS 1:1
      await zDreamsToken.connect(user1).approve(await staking.getAddress(), ethers.MaxUint256);

      await staking.connect(user1).stake(stakeAmount);

      // Advance past full vesting
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD + 1);

      // First partial unstake (25%)
      const firstUnstake = ethers.parseEther("250");
      await staking.connect(buybackContract).unstakeForBuyback(
        user1.address,
        firstUnstake,
        buybackContract.address
      );

      let stakeInfo = await staking.stakes(user1.address);
      expect(stakeInfo.amount).to.equal(ethers.parseEther("750"));

      // Second partial unstake (25% of original = 250)
      const secondUnstake = ethers.parseEther("250");
      await staking.connect(buybackContract).unstakeForBuyback(
        user1.address,
        secondUnstake,
        buybackContract.address
      );

      stakeInfo = await staking.stakes(user1.address);
      expect(stakeInfo.amount).to.equal(ethers.parseEther("500"));

      // Third partial unstake (remaining 500)
      const thirdUnstake = ethers.parseEther("500");
      await staking.connect(buybackContract).unstakeForBuyback(
        user1.address,
        thirdUnstake,
        buybackContract.address
      );

      stakeInfo = await staking.stakes(user1.address);
      expect(stakeInfo.amount).to.equal(0);

      // Verify start time is reset when fully unstaked
      expect(stakeInfo.startTime).to.equal(0);
    });

    it("should update totalStaked and totalVotingPower", async function () {
      const stakeAmount = ethers.parseEther("1000");
      await staking.connect(user1).stake(stakeAmount);

      // Advance past full vesting
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD + 1);

      const totalStakedBefore = await staking.totalStaked();
      const totalVotingPowerBefore = await staking.getTotalVotingPower();

      const unstakeAmount = ethers.parseEther("300");
      await staking.connect(buybackContract).unstakeForBuyback(
        user1.address,
        unstakeAmount,
        buybackContract.address
      );

      expect(await staking.totalStaked()).to.equal(totalStakedBefore - unstakeAmount);
      expect(await staking.getTotalVotingPower()).to.equal(totalVotingPowerBefore - unstakeAmount);
    });

    it("should emit UnstakedForBuyback event", async function () {
      const stakeAmount = ethers.parseEther("1000");
      await staking.connect(user1).stake(stakeAmount);

      // Advance past full vesting (no penalty)
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD + 1);

      await expect(
        staking.connect(buybackContract).unstakeForBuyback(
          user1.address,
          stakeAmount,
          buybackContract.address
        )
      ).to.emit(staking, "UnstakedForBuyback")
        .withArgs(user1.address, stakeAmount, stakeAmount, 0, buybackContract.address);
    });

    it("should handle edge case: unstake exactly vested amount (no penalty)", async function () {
      const stakeAmount = ethers.parseEther("1000");
      await staking.connect(user1).stake(stakeAmount);

      // Advance to 50% vested (halfway through vesting period)
      await time.increase(CLIFF_PERIOD + (VESTING_PERIOD / 2));

      const vestedAmount = await staking.getVestedAmount(user1.address);
      const treasuryBalanceBefore = await dreamsToken.balanceOf(treasury.address);

      // Unstake exactly the vested amount
      await staking.connect(buybackContract).unstakeForBuyback(
        user1.address,
        vestedAmount,
        buybackContract.address
      );

      const treasuryBalanceAfter = await dreamsToken.balanceOf(treasury.address);

      // No penalty since we only unstaked vested amount
      expect(treasuryBalanceAfter - treasuryBalanceBefore).to.equal(0);
    });

    it("should handle edge case: zDREAMS balance is less than expected burn", async function () {
      const stakeAmount = ethers.parseEther("1000");

      // Approve zDREAMS for staking contract (for burn)
      await zDreamsToken.connect(user1).approve(await staking.getAddress(), ethers.MaxUint256);

      // Stake normally - this mints 1000 zDREAMS
      await staking.connect(user1).stake(stakeAmount);

      // Simulate user burning some zDREAMS elsewhere (e.g., for cloud boosts)
      // This creates the edge case: user has 500 zDREAMS but stake expects ~1000 proportional
      const burnAmount = ethers.parseEther("500");
      await zDreamsToken.burn(user1.address, burnAmount);

      // Advance past full vesting
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD + 1);

      const zBalanceBefore = await zDreamsToken.balanceOf(user1.address);
      expect(zBalanceBefore).to.equal(ethers.parseEther("500")); // 1000 - 500 burned

      // Unstake full amount - contract should cap burn at available balance
      await staking.connect(buybackContract).unstakeForBuyback(
        user1.address,
        stakeAmount,
        buybackContract.address
      );

      const zBalanceAfter = await zDreamsToken.balanceOf(user1.address);

      // Should burn at most the available balance
      expect(zBalanceAfter).to.equal(0);
      expect(zBalanceBefore - zBalanceAfter).to.equal(ethers.parseEther("500"));
    });

    it("should handle edge case: user has zero zDREAMS", async function () {
      const stakeAmount = ethers.parseEther("1000");
      await staking.connect(user1).stake(stakeAmount);

      // No zDREAMS minted for user

      // Advance past full vesting
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD + 1);

      // Should succeed without reverting (burns 0)
      await expect(
        staking.connect(buybackContract).unstakeForBuyback(
          user1.address,
          stakeAmount,
          buybackContract.address
        )
      ).to.not.be.reverted;

      const stakeInfo = await staking.stakes(user1.address);
      expect(stakeInfo.amount).to.equal(0);
    });

    it("should work correctly when zDreamsToken is not set", async function () {
      // Deploy fresh staking contract without zDREAMS
      const DreamsStaking = await ethers.getContractFactory("DreamsStaking");
      const freshStaking = await DreamsStaking.deploy(
        await dreamsToken.getAddress(),
        await rewardToken.getAddress(),
        await mockOracle.getAddress(),
        treasury.address
      );

      await freshStaking.setBuybackContract(buybackContract.address);

      // Approve and stake
      await dreamsToken.connect(user1).approve(await freshStaking.getAddress(), ethers.MaxUint256);
      const stakeAmount = ethers.parseEther("1000");
      await freshStaking.connect(user1).stake(stakeAmount);

      // Advance past full vesting
      await time.increase(CLIFF_PERIOD + VESTING_PERIOD + 1);

      // Should work without zDREAMS burning
      await expect(
        freshStaking.connect(buybackContract).unstakeForBuyback(
          user1.address,
          stakeAmount,
          buybackContract.address
        )
      ).to.not.be.reverted;
    });

    it("should apply partial penalty for partially vested stake", async function () {
      const stakeAmount = ethers.parseEther("1000");
      await staking.connect(user1).stake(stakeAmount);

      // Advance to 50% vested
      await time.increase(CLIFF_PERIOD + (VESTING_PERIOD / 2));

      const vestedAmount = await staking.getVestedAmount(user1.address);
      const unvestedAmount = stakeAmount - vestedAmount;
      const expectedPenalty = (unvestedAmount * BigInt(EARLY_UNSTAKE_PENALTY_BPS)) / 10000n;

      const treasuryBalanceBefore = await dreamsToken.balanceOf(treasury.address);

      await staking.connect(buybackContract).unstakeForBuyback(
        user1.address,
        stakeAmount,
        buybackContract.address
      );

      const treasuryBalanceAfter = await dreamsToken.balanceOf(treasury.address);
      const actualPenalty = treasuryBalanceAfter - treasuryBalanceBefore;

      // Allow some tolerance due to block time
      expect(actualPenalty).to.be.closeTo(expectedPenalty, ethers.parseEther("1"));
    });
  });
});
