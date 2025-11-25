const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("ChainlinkPriceOracle", function () {
  let chainlinkOracle, mockPriceFeed, mockSequencerFeed;
  let owner, admin;
  let tokenA;

  beforeEach(async function () {
    [owner, admin] = await ethers.getSigners();

    // Deploy mock aggregator for the price feed
    const MockAggregatorV3 = await ethers.getContractFactory("MockAggregatorV3");
    mockPriceFeed = await MockAggregatorV3.deploy();
    
    // Deploy mock aggregator for the L2 sequencer feed
    mockSequencerFeed = await MockAggregatorV3.deploy();

    // Deploy mock token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    tokenA = await MockERC20.deploy("Token A", "TKA", 18);
    
    // Deploy ChainlinkPriceOracle
    const ChainlinkPriceOracle = await ethers.getContractFactory("ChainlinkPriceOracle");
    chainlinkOracle = await ChainlinkPriceOracle.deploy();

    // Set admin
    await chainlinkOracle.connect(owner).initiateAdminTransfer(admin.address);
    await chainlinkOracle.connect(admin).acceptAdminTransfer();

    // Configure the oracle
    await chainlinkOracle.connect(admin).setPriceFeed(await tokenA.getAddress(), await mockPriceFeed.getAddress(), 3600); // 1 hour heartbeat
    await chainlinkOracle.connect(admin).setSequencerUptimeFeed(await mockSequencerFeed.getAddress());
  });

  describe("Price Retrieval", function () {
    it("should return the correct price", async function () {
      const now = await time.latest();
      const oneHourAgo = now - 3600;
      await mockPriceFeed.set(1, ethers.parseUnits("2000", 8), now, now, 1); // Fresh price
      await mockSequencerFeed.set(1, 0, oneHourAgo, oneHourAgo, 1); // Sequencer is UP and grace period is over

      const price = await chainlinkOracle.getPrice(await tokenA.getAddress());
      expect(price).to.equal(ethers.parseUnits("2000", 8));
    });

    it("should revert if sequencer is down", async function () {
        const now = await time.latest();
        const oneHourAgo = now - 3600;
        await mockPriceFeed.set(1, ethers.parseUnits("2000", 8), now, now, 1);
        await mockSequencerFeed.set(1, 1, oneHourAgo, oneHourAgo, 1); // Sequencer is DOWN

        await expect(
            chainlinkOracle.getPrice(await tokenA.getAddress())
        ).to.be.revertedWithCustomError(chainlinkOracle, "SequencerDown");
    });

    it("should revert if price is stale", async function () {
        const now = await time.latest();
        const twoHoursAgo = now - 7200;
        const oneHourAgo = now - 3600;
        await mockPriceFeed.set(1, ethers.parseUnits("2000", 8), twoHoursAgo, twoHoursAgo, 1); // Stale price
        await mockSequencerFeed.set(1, 0, oneHourAgo, oneHourAgo, 1); // Sequencer is UP

        await expect(
            chainlinkOracle.getPrice(await tokenA.getAddress())
        ).to.be.revertedWithCustomError(chainlinkOracle, "StalePrice");
    });

    it("should revert if round is incomplete", async function () {
        const now = await time.latest();
        const oneHourAgo = now - 3600;
        await mockPriceFeed.set(2, ethers.parseUnits("2000", 8), now, now, 1); // answeredInRound < roundId
        await mockSequencerFeed.set(1, 0, oneHourAgo, oneHourAgo, 1); // Sequencer is UP

        await expect(
            chainlinkOracle.getPrice(await tokenA.getAddress())
        ).to.be.revertedWithCustomError(chainlinkOracle, "StaleRound");
    });

    it("should revert if price is not set for a token", async function () {
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        const tokenB = await MockERC20.deploy("Token B", "TKB", 18);
        const now = await time.latest();
        const oneHourAgo = now - 3600;
        await mockSequencerFeed.set(1, 0, oneHourAgo, oneHourAgo, 1); // Sequencer is UP

        await expect(
            chainlinkOracle.getPrice(await tokenB.getAddress())
        ).to.be.revertedWithCustomError(chainlinkOracle, "PriceFeedNotSet");
    });
  });
});
