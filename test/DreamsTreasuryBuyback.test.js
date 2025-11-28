const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("DreamsTreasuryBuyback", function () {
  let buyback;
  let dreams, juicy, weth, zDreams;
  let mockRouter, mockOracle, mockStaking;
  let owner, treasury, seller, admin, user2;

  // Constants matching contract
  const SPREAD_BPS = 250; // 2.5%
  const BPS_DENOMINATOR = 10000;
  const MAX_SELL_PER_TX = ethers.parseEther("100000"); // 100k DREAMS
  const DAILY_SELL_LIMIT = ethers.parseEther("1000000"); // 1M DREAMS global
  const USER_DAILY_LIMIT = ethers.parseEther("50000"); // 50k per user
  const LARGE_SELL_THRESHOLD = ethers.parseEther("25000"); // 25k triggers cooldown
  const LARGE_SELL_COOLDOWN = 30 * 60; // 30 minutes

  // Exchange rates from MockDexRouter
  const NATIVE_TO_JUICY_RATE = 1000n; // 1 ETH = 1000 JUICY
  const JUICY_TO_DREAMS_RATE = 75n; // 1 JUICY = 7.5 DREAMS

  // Oracle price (8 decimals)
  const DREAMS_PRICE = 10000000n; // $0.10 per DREAMS

  beforeEach(async function () {
    [owner, treasury, seller, admin, user2] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    dreams = await MockERC20.deploy("DREAMS Token", "DREAMS", 18);
    juicy = await MockERC20.deploy("JUICY Token", "JUICY", 18);

    // Deploy mock WETH
    const MockWETH = await ethers.getContractFactory("MockWETH");
    weth = await MockWETH.deploy();

    // Deploy mock zDREAMS
    const MockZDreams = await ethers.getContractFactory("MockZDreams");
    zDreams = await MockZDreams.deploy();

    // Deploy mock DEX router
    const MockDexRouter = await ethers.getContractFactory("MockDexRouter");
    mockRouter = await MockDexRouter.deploy(
      await weth.getAddress(),
      await juicy.getAddress(),
      await dreams.getAddress()
    );

    // Deploy mock price oracle
    const MockPriceOracle = await ethers.getContractFactory("MockPriceOracle");
    mockOracle = await MockPriceOracle.deploy();
    await mockOracle.setPrice(await dreams.getAddress(), DREAMS_PRICE);

    // Deploy mock staking
    const MockDreamsStaking = await ethers.getContractFactory("MockDreamsStaking");
    mockStaking = await MockDreamsStaking.deploy(
      await dreams.getAddress(),
      await zDreams.getAddress()
    );

    // Deploy buyback contract (Avalanche mode for Trader Joe testing)
    const DreamsTreasuryBuyback = await ethers.getContractFactory("DreamsTreasuryBuyback");
    buyback = await DreamsTreasuryBuyback.deploy(
      await dreams.getAddress(),
      await juicy.getAddress(),
      await weth.getAddress(),
      await mockRouter.getAddress(),
      await zDreams.getAddress(),
      await mockOracle.getAddress(),
      await mockStaking.getAddress(),
      treasury.address,
      true // isAvalanche = true
    );

    // Configure mock staking to use buyback contract
    await mockStaking.setBuybackContract(await buyback.getAddress());

    // Fund mock router with tokens for swaps
    await juicy.mint(await mockRouter.getAddress(), ethers.parseEther("10000000"));
    await dreams.mint(await mockRouter.getAddress(), ethers.parseEther("10000000"));

    // Fund mock router with ETH for swaps
    await owner.sendTransaction({
      to: await mockRouter.getAddress(),
      value: ethers.parseEther("100")
    });

    // Fund mock staking with DREAMS to send to buyback
    await dreams.mint(await mockStaking.getAddress(), ethers.parseEther("10000000"));

    // Setup seller: give zDREAMS, create stake
    const sellAmount = ethers.parseEther("10000");
    await zDreams.publicMint(seller.address, sellAmount);

    // Create a stake that's past the cliff (7 days ago)
    const pastCliff = (await time.latest()) - (8 * 24 * 60 * 60); // 8 days ago
    await mockStaking.mockStakeWithTime(seller.address, sellAmount, pastCliff);

    // Approve zDREAMS spending by staking contract
    await zDreams.connect(seller).approve(await mockStaking.getAddress(), ethers.MaxUint256);
  });

  describe("Constructor Validation", function () {
    it("should deploy with valid parameters", async function () {
      expect(await buyback.dreams()).to.equal(await dreams.getAddress());
      expect(await buyback.juicy()).to.equal(await juicy.getAddress());
      expect(await buyback.wrappedNative()).to.equal(await weth.getAddress());
      expect(await buyback.treasury()).to.equal(treasury.address);
      expect(await buyback.isAvalanche()).to.equal(true);
      expect(await buyback.admin()).to.equal(owner.address);
      expect(await buyback.buybackEnabled()).to.equal(true);
    });

    it("should reject zero DREAMS address", async function () {
      const DreamsTreasuryBuyback = await ethers.getContractFactory("DreamsTreasuryBuyback");
      await expect(
        DreamsTreasuryBuyback.deploy(
          ethers.ZeroAddress,
          await juicy.getAddress(),
          await weth.getAddress(),
          await mockRouter.getAddress(),
          await zDreams.getAddress(),
          await mockOracle.getAddress(),
          await mockStaking.getAddress(),
          treasury.address,
          true
        )
      ).to.be.revertedWithCustomError(buyback, "InvalidAddress");
    });

    it("should reject zero price oracle address", async function () {
      const DreamsTreasuryBuyback = await ethers.getContractFactory("DreamsTreasuryBuyback");
      await expect(
        DreamsTreasuryBuyback.deploy(
          await dreams.getAddress(),
          await juicy.getAddress(),
          await weth.getAddress(),
          await mockRouter.getAddress(),
          await zDreams.getAddress(),
          ethers.ZeroAddress,
          await mockStaking.getAddress(),
          treasury.address,
          true
        )
      ).to.be.revertedWithCustomError(buyback, "InvalidAddress");
    });

    it("should reject zero treasury address", async function () {
      const DreamsTreasuryBuyback = await ethers.getContractFactory("DreamsTreasuryBuyback");
      await expect(
        DreamsTreasuryBuyback.deploy(
          await dreams.getAddress(),
          await juicy.getAddress(),
          await weth.getAddress(),
          await mockRouter.getAddress(),
          await zDreams.getAddress(),
          await mockOracle.getAddress(),
          await mockStaking.getAddress(),
          ethers.ZeroAddress,
          true
        )
      ).to.be.revertedWithCustomError(buyback, "InvalidAddress");
    });
  });

  describe("sellStakedPosition - Happy Path", function () {
    it("should execute buyback and send ETH to user", async function () {
      const sellAmount = ethers.parseEther("1000");
      const sellerBalanceBefore = await ethers.provider.getBalance(seller.address);

      const tx = await buyback.connect(seller).sellStakedPosition(sellAmount);
      const receipt = await tx.wait();
      const gasUsed = receipt.gasUsed * receipt.gasPrice;

      const sellerBalanceAfter = await ethers.provider.getBalance(seller.address);

      // Seller should have received ETH (minus gas)
      expect(sellerBalanceAfter + gasUsed).to.be.gt(sellerBalanceBefore);
    });

    it("should burn zDREAMS from seller", async function () {
      const sellAmount = ethers.parseEther("1000");
      const zBalanceBefore = await zDreams.balanceOf(seller.address);

      await buyback.connect(seller).sellStakedPosition(sellAmount);

      const zBalanceAfter = await zDreams.balanceOf(seller.address);
      expect(zBalanceAfter).to.equal(zBalanceBefore - sellAmount);
    });

    it("should update tracking variables", async function () {
      const sellAmount = ethers.parseEther("1000");

      await buyback.connect(seller).sellStakedPosition(sellAmount);

      expect(await buyback.totalSoldBack()).to.equal(sellAmount);
    });

    it("should emit BuybackExecuted event", async function () {
      const sellAmount = ethers.parseEther("1000");

      await expect(buyback.connect(seller).sellStakedPosition(sellAmount))
        .to.emit(buyback, "BuybackExecuted")
        .withArgs(
          seller.address,
          sellAmount,
          (value) => value > 0, // nativePayout > 0
          DREAMS_PRICE,
          (value) => value > 0, // effectivePrice
          (value) => true, // penalty (could be 0)
          (value) => value > 0, // spreadTaken
          (value) => true // timestamp
        );
    });

    it("should emit SwapExecuted event", async function () {
      const sellAmount = ethers.parseEther("1000");

      await expect(buyback.connect(seller).sellStakedPosition(sellAmount))
        .to.emit(buyback, "SwapExecuted");
    });
  });

  describe("Daily Limits", function () {
    it("should track user daily sells", async function () {
      const sellAmount = ethers.parseEther("1000");

      await buyback.connect(seller).sellStakedPosition(sellAmount);

      const remaining = await buyback.getUserDailyRemaining(seller.address);
      expect(remaining).to.equal(USER_DAILY_LIMIT - sellAmount);
    });

    it("should track global daily sells", async function () {
      const sellAmount = ethers.parseEther("1000");

      await buyback.connect(seller).sellStakedPosition(sellAmount);

      const remaining = await buyback.getGlobalDailyRemaining();
      expect(remaining).to.equal(DAILY_SELL_LIMIT - sellAmount);
    });

    it("should reject if user daily limit exceeded", async function () {
      // Setup: give seller more zDREAMS
      await zDreams.publicMint(seller.address, USER_DAILY_LIMIT);
      const pastCliff = (await time.latest()) - (8 * 24 * 60 * 60);
      await mockStaking.mockStakeWithTime(seller.address, USER_DAILY_LIMIT + ethers.parseEther("10000"), pastCliff);
      await zDreams.connect(seller).approve(await mockStaking.getAddress(), ethers.MaxUint256);

      // First sell uses most of the limit
      await buyback.connect(seller).sellStakedPosition(USER_DAILY_LIMIT);

      // Second sell should fail
      await expect(
        buyback.connect(seller).sellStakedPosition(ethers.parseEther("1"))
      ).to.be.revertedWithCustomError(buyback, "ExceedsUserDailyLimit");
    });

    it("should reset limits after a day", async function () {
      // Sell up to limit
      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("10000"));

      // Advance time by 1 day
      await time.increase(24 * 60 * 60 + 1);

      // Mint more zDREAMS for seller and create new stake
      await zDreams.publicMint(seller.address, ethers.parseEther("1000"));
      const pastCliff = (await time.latest()) - (8 * 24 * 60 * 60);
      await mockStaking.mockStakeWithTime(seller.address, ethers.parseEther("1000"), pastCliff);

      // Should be able to sell again
      await expect(
        buyback.connect(seller).sellStakedPosition(ethers.parseEther("1000"))
      ).to.not.be.reverted;
    });
  });

  describe("Transaction Limits", function () {
    it("should reject zero amount", async function () {
      await expect(
        buyback.connect(seller).sellStakedPosition(0)
      ).to.be.revertedWithCustomError(buyback, "InvalidAmount");
    });

    it("should reject amount exceeding per-tx limit", async function () {
      await expect(
        buyback.connect(seller).sellStakedPosition(MAX_SELL_PER_TX + 1n)
      ).to.be.revertedWithCustomError(buyback, "ExceedsTransactionLimit");
    });
  });

  describe("Large Sell Cooldown", function () {
    beforeEach(async function () {
      // Give seller enough for large sells
      await zDreams.publicMint(seller.address, ethers.parseEther("100000"));
      const pastCliff = (await time.latest()) - (8 * 24 * 60 * 60);
      await mockStaking.mockStakeWithTime(seller.address, ethers.parseEther("100000"), pastCliff);
    });

    it("should track large sells", async function () {
      await buyback.connect(seller).sellStakedPosition(LARGE_SELL_THRESHOLD);

      const lastLargeSell = await buyback.lastLargeSell(seller.address);
      const currentTime = await time.latest();
      expect(lastLargeSell).to.be.closeTo(currentTime, 2);
    });

    it("should enforce cooldown for large sells", async function () {
      await buyback.connect(seller).sellStakedPosition(LARGE_SELL_THRESHOLD);

      // Try another large sell immediately
      await expect(
        buyback.connect(seller).sellStakedPosition(LARGE_SELL_THRESHOLD)
      ).to.be.revertedWithCustomError(buyback, "LargeSellCooldownActive");
    });

    it("should allow large sell after cooldown", async function () {
      await buyback.connect(seller).sellStakedPosition(LARGE_SELL_THRESHOLD);

      // Advance time past cooldown
      await time.increase(LARGE_SELL_COOLDOWN + 1);

      // Should work now
      await expect(
        buyback.connect(seller).sellStakedPosition(LARGE_SELL_THRESHOLD)
      ).to.not.be.reverted;
    });

    it("should allow small sells during cooldown", async function () {
      await buyback.connect(seller).sellStakedPosition(LARGE_SELL_THRESHOLD);

      // Small sell should work
      await expect(
        buyback.connect(seller).sellStakedPosition(ethers.parseEther("1000"))
      ).to.not.be.reverted;
    });
  });

  describe("Circuit Breaker", function () {
    it("should set reference price on first sell", async function () {
      expect(await buyback.referencePrice()).to.equal(0);

      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"));

      expect(await buyback.referencePrice()).to.equal(DREAMS_PRICE);
    });

    it("should trigger on large price deviation", async function () {
      // First sell to set reference price
      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"));

      // Change price significantly (>20%)
      const newPrice = (DREAMS_PRICE * 75n) / 100n; // 25% drop
      await mockOracle.setPrice(await dreams.getAddress(), newPrice);

      // Sell should revert with PriceDeviationTooHigh
      await expect(
        buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(buyback, "PriceDeviationTooHigh");
    });

    it("should persist circuit breaker state when triggered externally", async function () {
      // First sell to set reference price
      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"));

      // Drop price by 30% (above 20% max deviation threshold)
      const newPrice = (DREAMS_PRICE * 70n) / 100n;
      await mockOracle.setPrice(await dreams.getAddress(), newPrice);

      // Use the public checkAndTriggerCircuitBreaker function (doesn't revert)
      const triggered = await buyback.checkAndTriggerCircuitBreaker.staticCall();
      expect(triggered).to.equal(true);

      // Actually trigger it (state change)
      await buyback.checkAndTriggerCircuitBreaker();

      // Verify circuit breaker is now set
      expect(await buyback.circuitBreakerTriggered()).to.equal(true);

      // Even with price restored, circuit breaker should block sells
      await mockOracle.setPrice(await dreams.getAddress(), DREAMS_PRICE);

      await expect(
        buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(buyback, "CircuitBreakerActive");
    });

    it("should keep rejecting sells on price deviation until price normalizes", async function () {
      // First sell to set reference price
      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"));

      // Drop price by 30% (above 20% max deviation threshold)
      const newPrice = (DREAMS_PRICE * 70n) / 100n;
      await mockOracle.setPrice(await dreams.getAddress(), newPrice);

      // Sell should fail with PriceDeviationTooHigh
      await expect(
        buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(buyback, "PriceDeviationTooHigh");

      // With price restored (within deviation range), sells should work
      await mockOracle.setPrice(await dreams.getAddress(), DREAMS_PRICE);

      await expect(
        buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"))
      ).to.not.be.reverted;
    });

    it("should auto-reset after cooldown", async function () {
      // First sell to set reference price
      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"));

      // Trigger circuit breaker via external function
      const newPrice = (DREAMS_PRICE * 70n) / 100n;
      await mockOracle.setPrice(await dreams.getAddress(), newPrice);
      await buyback.checkAndTriggerCircuitBreaker();

      // Verify circuit breaker is active
      expect(await buyback.circuitBreakerTriggered()).to.equal(true);

      // Sells should be blocked
      await expect(
        buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(buyback, "CircuitBreakerActive");

      // Advance past cooldown (1 hour)
      await time.increase(3600 + 1);

      // Reset price and update reference manually
      await mockOracle.setPrice(await dreams.getAddress(), DREAMS_PRICE);
      await buyback.forceUpdateReferencePrice();

      // Should work now (circuit breaker auto-resets when cooldown passes)
      await expect(
        buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"))
      ).to.not.be.reverted;
    });

    it("should activate volatility spread on price drop", async function () {
      // First sell to set reference
      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"));

      // 12% price drop (above 10% threshold, below 20% circuit breaker)
      const newPrice = (DREAMS_PRICE * 88n) / 100n;
      await mockOracle.setPrice(await dreams.getAddress(), newPrice);

      // Sell should work but with higher spread
      const tx = await buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"));

      // Check volatility spread was activated
      expect(await buyback.volatilitySpreadBps()).to.be.gt(0);
    });
  });

  describe("Cliff Period Enforcement", function () {
    it("should reject if cliff not reached", async function () {
      // Create new seller with recent stake (cliff not reached)
      await zDreams.publicMint(user2.address, ethers.parseEther("1000"));
      await mockStaking.mockStake(user2.address, ethers.parseEther("1000")); // Just staked now
      await zDreams.connect(user2).approve(await mockStaking.getAddress(), ethers.MaxUint256);

      await expect(
        buyback.connect(user2).sellStakedPosition(ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(buyback, "CliffNotReached");
    });
  });

  describe("Insufficient Balance", function () {
    it("should reject if insufficient zDREAMS", async function () {
      const balance = await zDreams.balanceOf(seller.address);

      await expect(
        buyback.connect(seller).sellStakedPosition(balance + 1n)
      ).to.be.revertedWithCustomError(buyback, "InsufficientZDreams");
    });
  });

  describe("Buyback Toggle", function () {
    it("should reject sells when disabled", async function () {
      await buyback.toggleBuyback();

      await expect(
        buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(buyback, "BuybackDisabled");
    });

    it("should allow sells when re-enabled", async function () {
      await buyback.toggleBuyback(); // Disable
      await buyback.toggleBuyback(); // Re-enable

      await expect(
        buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"))
      ).to.not.be.reverted;
    });
  });

  describe("Spread Calculation", function () {
    it("should apply base spread correctly", async function () {
      const sellAmount = ethers.parseEther("1000");

      // Get quote before sell
      const quote = await buyback.getQuoteSell(sellAmount);
      expect(quote.totalSpread).to.equal(SPREAD_BPS);
    });

    it("should accumulate spread in contract", async function () {
      const sellAmount = ethers.parseEther("1000");
      const contractBalanceBefore = await ethers.provider.getBalance(await buyback.getAddress());

      await buyback.connect(seller).sellStakedPosition(sellAmount);

      const contractBalanceAfter = await ethers.provider.getBalance(await buyback.getAddress());
      expect(contractBalanceAfter).to.be.gt(contractBalanceBefore);
    });
  });

  describe("Admin Functions", function () {
    it("should update spread", async function () {
      const newSpread = 500; // 5%
      await buyback.setSpread(newSpread);
      expect(await buyback.sellSpreadBps()).to.equal(newSpread);
    });

    it("should reject spread above max", async function () {
      await expect(
        buyback.setSpread(1001) // > 10%
      ).to.be.revertedWithCustomError(buyback, "SpreadTooHigh");
    });

    it("should update limits", async function () {
      const newMaxPerTx = ethers.parseEther("50000");
      const newDailyGlobal = ethers.parseEther("500000");
      const newDailyUser = ethers.parseEther("25000");

      await buyback.setLimits(newMaxPerTx, newDailyGlobal, newDailyUser);

      expect(await buyback.maxSellPerTx()).to.equal(newMaxPerTx);
      expect(await buyback.dailySellLimit()).to.equal(newDailyGlobal);
      expect(await buyback.userDailyLimit()).to.equal(newDailyUser);
    });

    it("should update router", async function () {
      const newRouter = user2.address;
      await buyback.updateRouter(newRouter);
      expect(await buyback.dexRouter()).to.equal(newRouter);
    });

    it("should reject zero router", async function () {
      await expect(
        buyback.updateRouter(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(buyback, "InvalidAddress");
    });

    it("should update pool fee", async function () {
      await buyback.setPoolFee(500);
      expect(await buyback.poolFee()).to.equal(500);
    });

    it("should update price oracle", async function () {
      await buyback.setPriceOracle(user2.address);
      expect(await buyback.priceOracle()).to.equal(user2.address);
    });

    it("should update treasury", async function () {
      await buyback.setTreasury(user2.address);
      expect(await buyback.treasury()).to.equal(user2.address);
    });

    it("should reset circuit breaker and volatility spread", async function () {
      // First sell to set reference price
      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"));

      // Trigger circuit breaker via external function
      const dropPrice = (DREAMS_PRICE * 70n) / 100n; // 30% drop
      await mockOracle.setPrice(await dreams.getAddress(), dropPrice);
      await buyback.checkAndTriggerCircuitBreaker();

      // Verify circuit breaker is active
      expect(await buyback.circuitBreakerTriggered()).to.equal(true);

      // Also test volatility spread: reset price to moderate drop
      await mockOracle.setPrice(await dreams.getAddress(), (DREAMS_PRICE * 88n) / 100n);
      await buyback.resetCircuitBreaker(); // Reset first to clear
      await buyback.forceUpdateReferencePrice(); // Update reference to current price

      // Now do a sell with the moderate drop to activate volatility spread
      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"));

      // Drop again to trigger volatility spread
      const volatilityPrice = (DREAMS_PRICE * 76n) / 100n; // ~14% from new reference
      await mockOracle.setPrice(await dreams.getAddress(), volatilityPrice);
      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"));

      // Verify volatility spread was activated
      expect(await buyback.volatilitySpreadBps()).to.be.gt(0);

      // Admin resets - this clears both
      await buyback.resetCircuitBreaker();

      // Both should be cleared
      expect(await buyback.circuitBreakerTriggered()).to.equal(false);
      expect(await buyback.volatilitySpreadBps()).to.equal(0);
    });

    it("should force update reference price", async function () {
      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("100"));
      const oldRef = await buyback.referencePrice();

      const newPrice = (DREAMS_PRICE * 95n) / 100n;
      await mockOracle.setPrice(await dreams.getAddress(), newPrice);

      await buyback.forceUpdateReferencePrice();

      expect(await buyback.referencePrice()).to.equal(newPrice);
      expect(await buyback.referencePrice()).to.not.equal(oldRef);
    });

    it("should set manual price override", async function () {
      const overridePrice = 20000000n; // $0.20
      const duration = 3600; // 1 hour

      await buyback.setManualPriceOverride(overridePrice, duration);

      expect(await buyback.manualPriceOverride()).to.equal(overridePrice);
    });

    it("should only allow admin", async function () {
      await expect(
        buyback.connect(seller).setSpread(500)
      ).to.be.revertedWithCustomError(buyback, "OnlyAdmin");

      await expect(
        buyback.connect(seller).toggleBuyback()
      ).to.be.revertedWithCustomError(buyback, "OnlyAdmin");
    });
  });

  describe("Admin Transfer", function () {
    it("should initiate admin transfer", async function () {
      await buyback.initiateAdminTransfer(user2.address);
      expect(await buyback.pendingAdmin()).to.equal(user2.address);
    });

    it("should complete admin transfer", async function () {
      await buyback.initiateAdminTransfer(user2.address);
      await buyback.connect(user2).acceptAdminTransfer();
      expect(await buyback.admin()).to.equal(user2.address);
      expect(await buyback.pendingAdmin()).to.equal(ethers.ZeroAddress);
    });

    it("should reject non-pending admin acceptance", async function () {
      await buyback.initiateAdminTransfer(user2.address);
      await expect(
        buyback.connect(seller).acceptAdminTransfer()
      ).to.be.revertedWithCustomError(buyback, "NotPendingAdmin");
    });
  });

  describe("Emergency Functions", function () {
    it("should withdraw profits to treasury", async function () {
      // Do a sell to generate spread profits
      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("1000"));

      const contractBalance = await ethers.provider.getBalance(await buyback.getAddress());
      expect(contractBalance).to.be.gt(0);

      const treasuryBalanceBefore = await ethers.provider.getBalance(treasury.address);

      await buyback.withdrawProfits();

      const treasuryBalanceAfter = await ethers.provider.getBalance(treasury.address);
      expect(treasuryBalanceAfter).to.be.gt(treasuryBalanceBefore);
    });

    it("should emergency withdraw all funds", async function () {
      // Do a sell
      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("1000"));

      await buyback.emergencyWithdraw();

      expect(await buyback.buybackEnabled()).to.equal(false);
      expect(await ethers.provider.getBalance(await buyback.getAddress())).to.equal(0);
    });

    it("should rescue stuck tokens", async function () {
      // Send some JUICY to buyback contract
      await juicy.mint(await buyback.getAddress(), ethers.parseEther("100"));

      const treasuryBalanceBefore = await juicy.balanceOf(treasury.address);

      await buyback.rescueTokens(await juicy.getAddress(), ethers.parseEther("100"));

      const treasuryBalanceAfter = await juicy.balanceOf(treasury.address);
      expect(treasuryBalanceAfter - treasuryBalanceBefore).to.equal(ethers.parseEther("100"));
    });
  });

  describe("View Functions", function () {
    it("should return quote sell info", async function () {
      const sellAmount = ethers.parseEther("1000");
      const quote = await buyback.getQuoteSell(sellAmount);

      expect(quote.oraclePrice).to.equal(DREAMS_PRICE);
      expect(quote.totalSpread).to.equal(SPREAD_BPS);
      expect(quote.userCanSell).to.equal(true);
      expect(quote.globalCanSell).to.equal(true);
    });

    it("should return circuit breaker status", async function () {
      const status = await buyback.getCircuitBreakerStatus();

      expect(status.isTriggered).to.equal(false);
      expect(status.totalSpread).to.equal(SPREAD_BPS);
    });

    it("should return contract stats", async function () {
      await buyback.connect(seller).sellStakedPosition(ethers.parseEther("1000"));

      const stats = await buyback.getStats();

      expect(stats.totalSold).to.equal(ethers.parseEther("1000"));
      expect(stats.isEnabled).to.equal(true);
      expect(stats.contractNativeBalance).to.be.gt(0);
    });

    it("should return DEX quote", async function () {
      const sellAmount = ethers.parseEther("1000");
      const quote = await buyback.getDexQuote(sellAmount);

      expect(quote.juicyEstimate).to.be.gt(0);
      expect(quote.nativeEstimate).to.be.gt(0);
      expect(quote.afterSpread).to.be.gt(0);
      expect(quote.afterSpread).to.be.lt(quote.nativeEstimate);
    });
  });

  describe("DEX Integration (Avalanche Mode)", function () {
    it("should execute DREAMS → JUICY → AVAX swap", async function () {
      const sellAmount = ethers.parseEther("1000");

      // Track DREAMS on router (should increase from swap)
      const routerDreamsBefore = await dreams.balanceOf(await mockRouter.getAddress());

      await buyback.connect(seller).sellStakedPosition(sellAmount);

      // Check swap happened
      const lastJuicyOutput = await mockRouter.lastJuicyOutput();
      expect(lastJuicyOutput).to.be.gt(0);
    });
  });
});
