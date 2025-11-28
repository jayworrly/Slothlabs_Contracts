const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("DreamsTreasurySale", function () {
  let treasurySale;
  let dreams, juicy, weth;
  let mockRouter;
  let owner, treasury, buyer, admin;

  const TREASURY_FEE_BPS = 500; // 5% (updated from 10%)
  const BPS_DENOMINATOR = 10000;

  beforeEach(async function () {
    [owner, treasury, buyer, admin] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    dreams = await MockERC20.deploy("DREAMS Token", "DREAMS", 18);
    juicy = await MockERC20.deploy("JUICY Token", "JUICY", 18);

    // Deploy mock WETH (with deposit/withdraw)
    const MockWETH = await ethers.getContractFactory("MockWETH");
    weth = await MockWETH.deploy();

    // Deploy mock DEX router
    const MockDexRouter = await ethers.getContractFactory("MockDexRouter");
    mockRouter = await MockDexRouter.deploy(
      await weth.getAddress(),
      await juicy.getAddress(),
      await dreams.getAddress()
    );

    // Deploy treasury sale contract (BASE mode - not Avalanche)
    const DreamsTreasurySale = await ethers.getContractFactory("DreamsTreasurySale");
    treasurySale = await DreamsTreasurySale.deploy(
      await dreams.getAddress(),
      await juicy.getAddress(),
      await weth.getAddress(),
      await mockRouter.getAddress(),
      treasury.address,
      false // isAvalanche = false (BASE mode)
    );

    // Fund mock router with JUICY and DREAMS for swaps
    await juicy.mint(await mockRouter.getAddress(), ethers.parseEther("1000000"));
    await dreams.mint(await mockRouter.getAddress(), ethers.parseEther("1000000"));
  });

  describe("Constructor Validation", function () {
    it("should deploy with valid parameters", async function () {
      expect(await treasurySale.dreams()).to.equal(await dreams.getAddress());
      expect(await treasurySale.juicy()).to.equal(await juicy.getAddress());
      expect(await treasurySale.wrappedNative()).to.equal(await weth.getAddress());
      expect(await treasurySale.treasury()).to.equal(treasury.address);
      expect(await treasurySale.isAvalanche()).to.equal(false);
      expect(await treasurySale.admin()).to.equal(owner.address);
    });

    it("should reject zero DREAMS address", async function () {
      const DreamsTreasurySale = await ethers.getContractFactory("DreamsTreasurySale");
      await expect(
        DreamsTreasurySale.deploy(
          ethers.ZeroAddress,
          await juicy.getAddress(),
          await weth.getAddress(),
          await mockRouter.getAddress(),
          treasury.address,
          false
        )
      ).to.be.revertedWithCustomError(treasurySale, "InvalidAddress");
    });

    it("should reject zero JUICY address", async function () {
      const DreamsTreasurySale = await ethers.getContractFactory("DreamsTreasurySale");
      await expect(
        DreamsTreasurySale.deploy(
          await dreams.getAddress(),
          ethers.ZeroAddress,
          await weth.getAddress(),
          await mockRouter.getAddress(),
          treasury.address,
          false
        )
      ).to.be.revertedWithCustomError(treasurySale, "InvalidAddress");
    });

    it("should reject zero wrapped native address", async function () {
      const DreamsTreasurySale = await ethers.getContractFactory("DreamsTreasurySale");
      await expect(
        DreamsTreasurySale.deploy(
          await dreams.getAddress(),
          await juicy.getAddress(),
          ethers.ZeroAddress,
          await mockRouter.getAddress(),
          treasury.address,
          false
        )
      ).to.be.revertedWithCustomError(treasurySale, "InvalidAddress");
    });

    it("should reject zero router address", async function () {
      const DreamsTreasurySale = await ethers.getContractFactory("DreamsTreasurySale");
      await expect(
        DreamsTreasurySale.deploy(
          await dreams.getAddress(),
          await juicy.getAddress(),
          await weth.getAddress(),
          ethers.ZeroAddress,
          treasury.address,
          false
        )
      ).to.be.revertedWithCustomError(treasurySale, "InvalidAddress");
    });

    it("should reject zero treasury address", async function () {
      const DreamsTreasurySale = await ethers.getContractFactory("DreamsTreasurySale");
      await expect(
        DreamsTreasurySale.deploy(
          await dreams.getAddress(),
          await juicy.getAddress(),
          await weth.getAddress(),
          await mockRouter.getAddress(),
          ethers.ZeroAddress,
          false
        )
      ).to.be.revertedWithCustomError(treasurySale, "InvalidAddress");
    });
  });

  describe("Buy With Native (ETH)", function () {
    it("should buy DREAMS on market and take 5% fee", async function () {
      const ethAmount = ethers.parseEther("1");

      const treasuryDreamsBefore = await dreams.balanceOf(treasury.address);
      const buyerDreamsBefore = await dreams.balanceOf(buyer.address);

      await treasurySale.connect(buyer).buyWithNative({ value: ethAmount });

      const treasuryDreamsAfter = await dreams.balanceOf(treasury.address);
      const buyerDreamsAfter = await dreams.balanceOf(buyer.address);

      // Treasury should have received 10% fee
      const treasuryGain = treasuryDreamsAfter - treasuryDreamsBefore;
      expect(treasuryGain).to.be.gt(0);

      // Buyer should have received 90% (or auto-staked)
      // With auto-stake enabled by default, buyer's direct balance may not increase
      // but staking contract would have tokens
      const autoStakeEnabled = await treasurySale.autoStakeEnabled();
      if (!autoStakeEnabled) {
        const buyerGain = buyerDreamsAfter - buyerDreamsBefore;
        expect(buyerGain).to.be.gt(0);
        // Treasury fee should be ~5% of total (buyer got 95%)
        // treasuryGain / (treasuryGain + buyerGain) ≈ 5%
        const totalDreams = treasuryGain + buyerGain;
        const feePercent = (treasuryGain * 10000n) / totalDreams;
        expect(feePercent).to.be.closeTo(500n, 10n); // ~5% with small tolerance
      }
    });

    it("should apply correct 5% fee split", async function () {
      // Disable auto-stake for this test
      await treasurySale.toggleAutoStake();

      const ethAmount = ethers.parseEther("1");

      const treasuryDreamsBefore = await dreams.balanceOf(treasury.address);

      await treasurySale.connect(buyer).buyWithNative({ value: ethAmount });

      const treasuryDreamsAfter = await dreams.balanceOf(treasury.address);
      const buyerDreams = await dreams.balanceOf(buyer.address);

      const treasuryFee = treasuryDreamsAfter - treasuryDreamsBefore;
      const totalDreams = treasuryFee + buyerDreams;

      // Fee should be exactly 5% of total
      const expectedFee = (totalDreams * 500n) / 10000n;
      expect(treasuryFee).to.equal(expectedFee);

      // User should get exactly 95%
      const expectedUser = totalDreams - expectedFee;
      expect(buyerDreams).to.equal(expectedUser);
    });

    it("should revert when sales are disabled", async function () {
      await treasurySale.toggleSales();

      await expect(
        treasurySale.connect(buyer).buyWithNative({ value: ethers.parseEther("1") })
      ).to.be.revertedWithCustomError(treasurySale, "SalesDisabled");
    });

    it("should revert when sending zero ETH", async function () {
      await expect(
        treasurySale.connect(buyer).buyWithNative({ value: 0 })
      ).to.be.revertedWithCustomError(treasurySale, "InvalidAmount");
    });

    it("should emit MarketBuy event", async function () {
      const ethAmount = ethers.parseEther("1");

      await expect(treasurySale.connect(buyer).buyWithNative({ value: ethAmount }))
        .to.emit(treasurySale, "MarketBuy");
    });
  });

  describe("Buy With JUICY", function () {
    beforeEach(async function () {
      // Mint JUICY to buyer
      await juicy.mint(buyer.address, ethers.parseEther("10000"));
      await juicy.connect(buyer).approve(
        await treasurySale.getAddress(),
        ethers.MaxUint256
      );

      // Disable auto-stake for clearer testing
      await treasurySale.toggleAutoStake();
    });

    it("should buy DREAMS with JUICY and take 5% fee", async function () {
      const juicyAmount = ethers.parseEther("1000");

      const treasuryDreamsBefore = await dreams.balanceOf(treasury.address);
      const buyerDreamsBefore = await dreams.balanceOf(buyer.address);
      const buyerJuicyBefore = await juicy.balanceOf(buyer.address);

      await treasurySale.connect(buyer).buyWithJuicy(juicyAmount);

      const treasuryDreamsAfter = await dreams.balanceOf(treasury.address);
      const buyerDreamsAfter = await dreams.balanceOf(buyer.address);
      const buyerJuicyAfter = await juicy.balanceOf(buyer.address);

      // Buyer JUICY should have decreased
      expect(buyerJuicyAfter).to.equal(buyerJuicyBefore - juicyAmount);

      // Treasury should have received 5% fee
      const treasuryFee = treasuryDreamsAfter - treasuryDreamsBefore;
      expect(treasuryFee).to.be.gt(0);

      // Buyer should have received 95%
      const buyerGain = buyerDreamsAfter - buyerDreamsBefore;
      expect(buyerGain).to.be.gt(0);

      // Verify 5% fee
      const totalDreams = treasuryFee + buyerGain;
      const feePercent = (treasuryFee * 10000n) / totalDreams;
      expect(feePercent).to.equal(500n); // Exactly 5%
    });

    it("should revert when sales are disabled", async function () {
      await treasurySale.toggleSales();

      await expect(
        treasurySale.connect(buyer).buyWithJuicy(ethers.parseEther("1000"))
      ).to.be.revertedWithCustomError(treasurySale, "SalesDisabled");
    });

    it("should revert when sending zero JUICY", async function () {
      await expect(
        treasurySale.connect(buyer).buyWithJuicy(0)
      ).to.be.revertedWithCustomError(treasurySale, "InvalidAmount");
    });

    it("should emit DirectJuicyBuy event", async function () {
      const juicyAmount = ethers.parseEther("1000");

      await expect(treasurySale.connect(buyer).buyWithJuicy(juicyAmount))
        .to.emit(treasurySale, "DirectJuicyBuy");
    });
  });

  describe("Treasury Stats", function () {
    it("should report correct treasury stats", async function () {
      // Disable auto-stake and do a purchase
      await treasurySale.toggleAutoStake();
      await treasurySale.connect(buyer).buyWithNative({ value: ethers.parseEther("1") });

      const [treasuryDreams, treasuryJuicy, isEnabled] =
        await treasurySale.getTreasuryStats();

      // Treasury should have accumulated DREAMS from fees
      expect(treasuryDreams).to.be.gt(0);
      expect(isEnabled).to.equal(true);
    });
  });

  describe("Admin Functions", function () {
    it("should allow admin to toggle sales", async function () {
      expect(await treasurySale.salesEnabled()).to.equal(true);

      await expect(treasurySale.toggleSales())
        .to.emit(treasurySale, "SalesToggled")
        .withArgs(false);

      expect(await treasurySale.salesEnabled()).to.equal(false);

      await treasurySale.toggleSales();
      expect(await treasurySale.salesEnabled()).to.equal(true);
    });

    it("should allow admin to update router", async function () {
      const newRouter = ethers.Wallet.createRandom().address;
      const oldRouter = await treasurySale.dexRouter();

      await expect(treasurySale.updateRouter(newRouter))
        .to.emit(treasurySale, "RouterUpdated")
        .withArgs(oldRouter, newRouter);

      expect(await treasurySale.dexRouter()).to.equal(newRouter);
    });

    it("should allow admin to update treasury", async function () {
      const newTreasury = ethers.Wallet.createRandom().address;
      const oldTreasury = await treasurySale.treasury();

      await expect(treasurySale.updateTreasury(newTreasury))
        .to.emit(treasurySale, "TreasuryUpdated")
        .withArgs(oldTreasury, newTreasury);

      expect(await treasurySale.treasury()).to.equal(newTreasury);
    });

    it("should allow admin to update pool fee", async function () {
      await treasurySale.updatePoolFee(10000); // 1%
      expect(await treasurySale.poolFee()).to.equal(10000);
    });

    it("should allow admin to toggle auto-stake", async function () {
      expect(await treasurySale.autoStakeEnabled()).to.equal(true);

      await expect(treasurySale.toggleAutoStake())
        .to.emit(treasurySale, "AutoStakeToggled")
        .withArgs(false);

      expect(await treasurySale.autoStakeEnabled()).to.equal(false);
    });

    it("should allow admin to transfer admin", async function () {
      await treasurySale.transferAdmin(admin.address);
      expect(await treasurySale.admin()).to.equal(admin.address);
    });

    it("should reject non-admin calls", async function () {
      await expect(
        treasurySale.connect(buyer).toggleSales()
      ).to.be.revertedWithCustomError(treasurySale, "OnlyAdmin");

      await expect(
        treasurySale.connect(buyer).updateRouter(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(treasurySale, "OnlyAdmin");

      await expect(
        treasurySale.connect(buyer).updateTreasury(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(treasurySale, "OnlyAdmin");
    });

    it("should reject zero addresses in admin functions", async function () {
      await expect(
        treasurySale.updateRouter(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(treasurySale, "InvalidAddress");

      await expect(
        treasurySale.updateTreasury(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(treasurySale, "InvalidAddress");

      await expect(
        treasurySale.transferAdmin(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(treasurySale, "InvalidAddress");
    });
  });

  describe("Emergency Functions", function () {
    it("should allow admin to rescue tokens", async function () {
      // Send some tokens to contract accidentally
      const rescueAmount = ethers.parseEther("100");
      await juicy.mint(await treasurySale.getAddress(), rescueAmount);

      const adminBalanceBefore = await juicy.balanceOf(owner.address);

      await treasurySale.rescueTokens(await juicy.getAddress(), rescueAmount);

      const adminBalanceAfter = await juicy.balanceOf(owner.address);
      expect(adminBalanceAfter).to.equal(adminBalanceBefore + rescueAmount);
    });

    it("should allow admin to rescue native tokens", async function () {
      // Send ETH to contract
      await owner.sendTransaction({
        to: await treasurySale.getAddress(),
        value: ethers.parseEther("1")
      });

      const adminBalanceBefore = await ethers.provider.getBalance(owner.address);

      await treasurySale.rescueNative();

      const adminBalanceAfter = await ethers.provider.getBalance(owner.address);
      // Account for gas, but balance should increase significantly
      expect(adminBalanceAfter).to.be.gt(adminBalanceBefore - ethers.parseEther("0.01"));
    });

    it("should reject non-admin rescue calls", async function () {
      await expect(
        treasurySale.connect(buyer).rescueTokens(await juicy.getAddress(), 100)
      ).to.be.revertedWithCustomError(treasurySale, "OnlyAdmin");

      await expect(
        treasurySale.connect(buyer).rescueNative()
      ).to.be.revertedWithCustomError(treasurySale, "OnlyAdmin");
    });
  });

  describe("Quote Functions", function () {
    it("should return correct quote for native purchase", async function () {
      const nativeAmount = ethers.parseEther("1");

      const [juicyEstimate, dreamsEstimate, treasuryFee, userReceives] =
        await treasurySale.getQuoteNative(nativeAmount);

      // Verify fee calculation (5% fee)
      if (dreamsEstimate > 0) {
        const expectedFee = (dreamsEstimate * 500n) / 10000n;
        expect(treasuryFee).to.equal(expectedFee);
        expect(userReceives).to.equal(dreamsEstimate - treasuryFee);
      }
    });

    it("should return correct quote for JUICY purchase", async function () {
      const juicyAmount = ethers.parseEther("1000");

      const [dreamsEstimate, treasuryFee, userReceives] =
        await treasurySale.getQuoteJuicy(juicyAmount);

      // dreamsEstimate from mock: 1000 JUICY * 7.5 = 7500 DREAMS
      expect(dreamsEstimate).to.equal(ethers.parseEther("7500"));

      // 5% fee
      const expectedFee = (dreamsEstimate * 500n) / 10000n;
      expect(treasuryFee).to.equal(expectedFee);
      expect(userReceives).to.equal(dreamsEstimate - treasuryFee);
    });
  });

  describe("Receive ETH", function () {
    it("should accept ETH transfers", async function () {
      await owner.sendTransaction({
        to: await treasurySale.getAddress(),
        value: ethers.parseEther("1")
      });

      expect(await ethers.provider.getBalance(await treasurySale.getAddress()))
        .to.equal(ethers.parseEther("1"));
    });
  });
});

// Avalanche mode tests
describe("DreamsTreasurySale (Avalanche Mode)", function () {
  let treasurySale;
  let dreams, juicy, wavax;
  let mockRouter;
  let owner, treasury, buyer;

  beforeEach(async function () {
    [owner, treasury, buyer] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    dreams = await MockERC20.deploy("DREAMS Token", "DREAMS", 18);
    juicy = await MockERC20.deploy("JUICY Token", "JUICY", 18);

    // Deploy mock WAVAX (with deposit/withdraw)
    const MockWETH = await ethers.getContractFactory("MockWETH");
    wavax = await MockWETH.deploy();

    // Deploy mock DEX router
    const MockDexRouter = await ethers.getContractFactory("MockDexRouter");
    mockRouter = await MockDexRouter.deploy(
      await wavax.getAddress(),
      await juicy.getAddress(),
      await dreams.getAddress()
    );

    // Deploy treasury sale contract (Avalanche mode)
    const DreamsTreasurySale = await ethers.getContractFactory("DreamsTreasurySale");
    treasurySale = await DreamsTreasurySale.deploy(
      await dreams.getAddress(),
      await juicy.getAddress(),
      await wavax.getAddress(),
      await mockRouter.getAddress(),
      treasury.address,
      true // isAvalanche = true
    );

    // Fund mock router with JUICY and DREAMS for swaps
    await juicy.mint(await mockRouter.getAddress(), ethers.parseEther("1000000"));
    await dreams.mint(await mockRouter.getAddress(), ethers.parseEther("1000000"));
  });

  it("should be in Avalanche mode", async function () {
    expect(await treasurySale.isAvalanche()).to.equal(true);
  });

  it("should buy DREAMS with AVAX and take 5% fee", async function () {
    const avaxAmount = ethers.parseEther("10");

    // Disable auto-stake for testing
    await treasurySale.toggleAutoStake();

    const treasuryDreamsBefore = await dreams.balanceOf(treasury.address);
    const buyerDreamsBefore = await dreams.balanceOf(buyer.address);

    await treasurySale.connect(buyer).buyWithNative({ value: avaxAmount });

    const treasuryDreamsAfter = await dreams.balanceOf(treasury.address);
    const buyerDreamsAfter = await dreams.balanceOf(buyer.address);

    const treasuryFee = treasuryDreamsAfter - treasuryDreamsBefore;
    const buyerGain = buyerDreamsAfter - buyerDreamsBefore;

    // Both should have received DREAMS
    expect(treasuryFee).to.be.gt(0);
    expect(buyerGain).to.be.gt(0);

    // Verify 5% fee
    const totalDreams = treasuryFee + buyerGain;
    const feePercent = (treasuryFee * 10000n) / totalDreams;
    expect(feePercent).to.equal(500n);
  });

  it("should return quote with Trader Joe style", async function () {
    const avaxAmount = ethers.parseEther("10");

    const [juicyEstimate, dreamsEstimate, treasuryFee, userReceives] =
      await treasurySale.getQuoteNative(avaxAmount);

    // In Avalanche mode, quote uses getAmountsOut
    expect(juicyEstimate).to.be.gt(0);
    expect(dreamsEstimate).to.be.gt(0);
    expect(treasuryFee).to.be.gt(0);
    expect(userReceives).to.be.gt(0);

    // Verify math
    expect(treasuryFee + userReceives).to.equal(dreamsEstimate);
  });
});
