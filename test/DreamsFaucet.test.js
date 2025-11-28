const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("DreamsFaucet", function () {
  let faucet;
  let dreamsToken;
  let owner, user1, user2;

  const CLAIM_AMOUNT = ethers.parseEther("10000"); // 10k DREAMS
  const COOLDOWN = 24 * 60 * 60; // 24 hours
  const MAX_CLAIMS = 10;
  const FAUCET_FUNDING = ethers.parseEther("1000000"); // 1M DREAMS

  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();

    // Deploy mock DREAMS token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    dreamsToken = await MockERC20.deploy("DREAMS Token", "DREAMS", 18);

    // Deploy faucet
    const DreamsFaucet = await ethers.getContractFactory("DreamsFaucet");
    faucet = await DreamsFaucet.deploy(await dreamsToken.getAddress());

    // Fund the faucet
    await dreamsToken.mint(await faucet.getAddress(), FAUCET_FUNDING);
  });

  describe("Constructor", function () {
    it("should deploy with correct parameters", async function () {
      expect(await faucet.dreamsToken()).to.equal(await dreamsToken.getAddress());
      expect(await faucet.admin()).to.equal(owner.address);
      expect(await faucet.claimAmount()).to.equal(CLAIM_AMOUNT);
      expect(await faucet.claimCooldown()).to.equal(COOLDOWN);
      expect(await faucet.faucetEnabled()).to.equal(true);
    });
  });

  describe("Claim", function () {
    it("should allow first claim", async function () {
      const balanceBefore = await dreamsToken.balanceOf(user1.address);

      await faucet.connect(user1).claim();

      const balanceAfter = await dreamsToken.balanceOf(user1.address);
      expect(balanceAfter - balanceBefore).to.equal(CLAIM_AMOUNT);
    });

    it("should emit Claimed event", async function () {
      await expect(faucet.connect(user1).claim())
        .to.emit(faucet, "Claimed")
        .withArgs(user1.address, CLAIM_AMOUNT, 1);
    });

    it("should update claim tracking", async function () {
      await faucet.connect(user1).claim();

      expect(await faucet.totalClaims(user1.address)).to.equal(1);
      expect(await faucet.totalDistributed()).to.equal(CLAIM_AMOUNT);
    });

    it("should reject claim before cooldown", async function () {
      await faucet.connect(user1).claim();

      await expect(faucet.connect(user1).claim())
        .to.be.revertedWithCustomError(faucet, "CooldownNotPassed");
    });

    it("should allow claim after cooldown", async function () {
      await faucet.connect(user1).claim();

      // Fast forward 24 hours
      await time.increase(COOLDOWN + 1);

      await expect(faucet.connect(user1).claim()).to.not.be.reverted;

      expect(await faucet.totalClaims(user1.address)).to.equal(2);
    });

    it("should reject after max claims reached", async function () {
      // Make all 10 claims
      for (let i = 0; i < MAX_CLAIMS; i++) {
        await faucet.connect(user1).claim();
        if (i < MAX_CLAIMS - 1) {
          await time.increase(COOLDOWN + 1);
        }
      }

      await time.increase(COOLDOWN + 1);

      await expect(faucet.connect(user1).claim())
        .to.be.revertedWithCustomError(faucet, "MaxClaimsReached");
    });

    it("should reject when faucet disabled", async function () {
      await faucet.toggleFaucet();

      await expect(faucet.connect(user1).claim())
        .to.be.revertedWithCustomError(faucet, "FaucetDisabled");
    });

    it("should reject when faucet has insufficient balance", async function () {
      // Deploy new faucet without funding
      const DreamsFaucet = await ethers.getContractFactory("DreamsFaucet");
      const emptyFaucet = await DreamsFaucet.deploy(await dreamsToken.getAddress());

      await expect(emptyFaucet.connect(user1).claim())
        .to.be.revertedWithCustomError(emptyFaucet, "InsufficientFaucetBalance");
    });

    it("should enforce daily distribution limit", async function () {
      // Set very low daily limit
      await faucet.setMaxDailyDistribution(ethers.parseEther("15000")); // 15k limit
      await faucet.setCooldown(1); // 1 second cooldown for testing

      // First claim works (10k)
      await faucet.connect(user1).claim();
      await time.increase(2);

      // Second claim would exceed limit (10k + 10k > 15k)
      await expect(faucet.connect(user1).claim())
        .to.be.revertedWithCustomError(faucet, "DailyLimitReached");
    });

    it("should reset daily limit after 24 hours", async function () {
      // Set low daily limit
      await faucet.setMaxDailyDistribution(ethers.parseEther("15000"));
      await faucet.setCooldown(1);

      // First claim
      await faucet.connect(user1).claim();
      await time.increase(2);

      // Second claim fails (exceeds daily)
      await expect(faucet.connect(user1).claim())
        .to.be.revertedWithCustomError(faucet, "DailyLimitReached");

      // Wait 24 hours
      await time.increase(COOLDOWN);

      // Now it works
      await expect(faucet.connect(user1).claim()).to.not.be.reverted;
    });
  });

  describe("View Functions", function () {
    it("should return correct claim status for new user", async function () {
      const [canClaim, timeUntilNext, claimsRemaining] = await faucet.getClaimStatus(user1.address);

      expect(canClaim).to.equal(true);
      expect(timeUntilNext).to.equal(0);
      expect(claimsRemaining).to.equal(MAX_CLAIMS);
    });

    it("should return correct claim status after claim", async function () {
      await faucet.connect(user1).claim();

      const [canClaim, timeUntilNext, claimsRemaining] = await faucet.getClaimStatus(user1.address);

      expect(canClaim).to.equal(false);
      expect(timeUntilNext).to.be.gt(0);
      expect(claimsRemaining).to.equal(MAX_CLAIMS - 1);
    });

    it("should return correct faucet stats", async function () {
      await faucet.connect(user1).claim();

      const [balance, distributed, dailyRemaining, enabled] = await faucet.getFaucetStats();

      expect(balance).to.equal(FAUCET_FUNDING - CLAIM_AMOUNT);
      expect(distributed).to.equal(CLAIM_AMOUNT);
      expect(dailyRemaining).to.be.gt(0);
      expect(enabled).to.equal(true);
    });
  });

  describe("Admin Functions", function () {
    it("should toggle faucet", async function () {
      await faucet.toggleFaucet();
      expect(await faucet.faucetEnabled()).to.equal(false);

      await faucet.toggleFaucet();
      expect(await faucet.faucetEnabled()).to.equal(true);
    });

    it("should update claim amount", async function () {
      const newAmount = ethers.parseEther("5000");

      await expect(faucet.setClaimAmount(newAmount))
        .to.emit(faucet, "ClaimAmountUpdated")
        .withArgs(CLAIM_AMOUNT, newAmount);

      expect(await faucet.claimAmount()).to.equal(newAmount);
    });

    it("should reject zero claim amount", async function () {
      await expect(faucet.setClaimAmount(0))
        .to.be.revertedWithCustomError(faucet, "InvalidAmount");
    });

    it("should update cooldown", async function () {
      const newCooldown = 12 * 60 * 60; // 12 hours

      await expect(faucet.setCooldown(newCooldown))
        .to.emit(faucet, "CooldownUpdated")
        .withArgs(COOLDOWN, newCooldown);

      expect(await faucet.claimCooldown()).to.equal(newCooldown);
    });

    it("should update max claims", async function () {
      await faucet.setMaxClaims(20);
      expect(await faucet.maxClaimsPerAddress()).to.equal(20);
    });

    it("should transfer admin", async function () {
      await expect(faucet.transferAdmin(user1.address))
        .to.emit(faucet, "AdminTransferred")
        .withArgs(owner.address, user1.address);

      expect(await faucet.admin()).to.equal(user1.address);
    });

    it("should withdraw tokens", async function () {
      const withdrawAmount = ethers.parseEther("100000");
      const balanceBefore = await dreamsToken.balanceOf(owner.address);

      await faucet.withdrawTokens(withdrawAmount);

      const balanceAfter = await dreamsToken.balanceOf(owner.address);
      expect(balanceAfter - balanceBefore).to.equal(withdrawAmount);
    });

    it("should reset user claims", async function () {
      // User claims multiple times
      await faucet.connect(user1).claim();
      await time.increase(COOLDOWN + 1);
      await faucet.connect(user1).claim();

      expect(await faucet.totalClaims(user1.address)).to.equal(2);

      // Admin resets
      await faucet.resetUserClaims(user1.address);

      expect(await faucet.totalClaims(user1.address)).to.equal(0);
      expect(await faucet.lastClaimTime(user1.address)).to.equal(0);

      // User can claim again immediately
      await expect(faucet.connect(user1).claim()).to.not.be.reverted;
    });

    it("should reject non-admin calls", async function () {
      await expect(faucet.connect(user1).toggleFaucet())
        .to.be.revertedWithCustomError(faucet, "OnlyAdmin");

      await expect(faucet.connect(user1).setClaimAmount(1000))
        .to.be.revertedWithCustomError(faucet, "OnlyAdmin");

      await expect(faucet.connect(user1).setCooldown(1000))
        .to.be.revertedWithCustomError(faucet, "OnlyAdmin");

      await expect(faucet.connect(user1).transferAdmin(user2.address))
        .to.be.revertedWithCustomError(faucet, "OnlyAdmin");
    });
  });

  describe("Multiple Users", function () {
    it("should track claims independently per user", async function () {
      await faucet.connect(user1).claim();
      await faucet.connect(user2).claim();

      expect(await faucet.totalClaims(user1.address)).to.equal(1);
      expect(await faucet.totalClaims(user2.address)).to.equal(1);
      expect(await faucet.totalDistributed()).to.equal(CLAIM_AMOUNT * 2n);
    });

    it("should enforce cooldown independently per user", async function () {
      await faucet.connect(user1).claim();

      // user2 can still claim even though user1 is in cooldown
      await expect(faucet.connect(user2).claim()).to.not.be.reverted;

      // user1 still in cooldown
      await expect(faucet.connect(user1).claim())
        .to.be.revertedWithCustomError(faucet, "CooldownNotPassed");
    });
  });
});
