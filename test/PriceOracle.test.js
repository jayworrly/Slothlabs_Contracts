const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("PriceOracle", function () {
  let priceOracle;
  let owner, newAdmin, user;
  let mockToken;

  const ONE_HOUR = 3600;
  const ETH_PRICE = 200000000000n; // $2000 with 8 decimals

  beforeEach(async function () {
    [owner, newAdmin, user] = await ethers.getSigners();

    // Deploy mock token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockToken = await MockERC20.deploy("Mock Token", "MOCK", 18);

    // Deploy price oracle
    const PriceOracle = await ethers.getContractFactory("PriceOracle");
    priceOracle = await PriceOracle.deploy();
  });

  describe("Price Updates", function () {
    it("should allow admin to update price", async function () {
      await expect(
        priceOracle.updatePrice(await mockToken.getAddress(), ETH_PRICE)
      ).to.emit(priceOracle, "PriceUpdated");

      expect(await priceOracle.prices(await mockToken.getAddress())).to.equal(ETH_PRICE);
    });

    it("should reject price update from non-admin", async function () {
      await expect(
        priceOracle.connect(user).updatePrice(await mockToken.getAddress(), ETH_PRICE)
      ).to.be.revertedWithCustomError(priceOracle, "OnlyAdmin");
    });

    it("should reject zero price", async function () {
      await expect(
        priceOracle.updatePrice(await mockToken.getAddress(), 0)
      ).to.be.revertedWithCustomError(priceOracle, "InvalidPrice");
    });

    it("should reject zero address token", async function () {
      await expect(
        priceOracle.updatePrice(ethers.ZeroAddress, ETH_PRICE)
      ).to.be.revertedWithCustomError(priceOracle, "InvalidAddress");
    });

    it("should batch update prices", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const token2 = await MockERC20.deploy("Token 2", "TK2", 18);

      const tokens = [await mockToken.getAddress(), await token2.getAddress()];
      const prices = [ETH_PRICE, 100000000n]; // $2000, $1

      await priceOracle.updatePrices(tokens, prices);

      expect(await priceOracle.prices(tokens[0])).to.equal(prices[0]);
      expect(await priceOracle.prices(tokens[1])).to.equal(prices[1]);
    });
  });

  describe("Price Retrieval", function () {
    beforeEach(async function () {
      await priceOracle.updatePrice(await mockToken.getAddress(), ETH_PRICE);
    });

    it("should return correct price", async function () {
      expect(await priceOracle.getPrice(await mockToken.getAddress())).to.equal(ETH_PRICE);
    });

    it("should revert for unset price", async function () {
      await expect(
        priceOracle.getPrice(user.address)
      ).to.be.revertedWithCustomError(priceOracle, "PriceNotSet");
    });

    it("should revert for stale price", async function () {
      // Fast forward past MAX_PRICE_AGE (1 hour)
      await time.increase(ONE_HOUR + 1);

      await expect(
        priceOracle.getPrice(await mockToken.getAddress())
      ).to.be.revertedWithCustomError(priceOracle, "PriceTooOld");
    });

    it("should convert to USD correctly", async function () {
      const amount = ethers.parseEther("1"); // 1 token
      // Price is $2000 with 8 decimals
      // Expected: 1 * 2000 = $2000 with 18 decimals
      const expectedUSD = ethers.parseEther("2000");

      const result = await priceOracle.convertToUSD(await mockToken.getAddress(), amount);
      expect(result).to.equal(expectedUSD);
    });

    it("should report price freshness correctly", async function () {
      expect(await priceOracle.isPriceFresh(await mockToken.getAddress())).to.be.true;

      await time.increase(ONE_HOUR + 1);
      expect(await priceOracle.isPriceFresh(await mockToken.getAddress())).to.be.false;
    });
  });

  describe("Two-Step Admin Transfer", function () {
    it("should initiate admin transfer", async function () {
      await expect(
        priceOracle.initiateAdminTransfer(newAdmin.address)
      ).to.emit(priceOracle, "AdminTransferInitiated");

      expect(await priceOracle.pendingAdmin()).to.equal(newAdmin.address);
    });

    it("should reject initiation with zero address", async function () {
      await expect(
        priceOracle.initiateAdminTransfer(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(priceOracle, "InvalidAddress");
    });

    it("should complete admin transfer", async function () {
      await priceOracle.initiateAdminTransfer(newAdmin.address);

      await expect(
        priceOracle.connect(newAdmin).acceptAdminTransfer()
      ).to.emit(priceOracle, "AdminTransferCompleted");

      expect(await priceOracle.admin()).to.equal(newAdmin.address);
      expect(await priceOracle.pendingAdmin()).to.equal(ethers.ZeroAddress);
    });

    it("should reject acceptance from wrong address", async function () {
      await priceOracle.initiateAdminTransfer(newAdmin.address);

      await expect(
        priceOracle.connect(user).acceptAdminTransfer()
      ).to.be.revertedWithCustomError(priceOracle, "OnlyPendingAdmin");
    });

    it("should allow cancellation of pending transfer", async function () {
      await priceOracle.initiateAdminTransfer(newAdmin.address);

      await expect(
        priceOracle.cancelAdminTransfer()
      ).to.emit(priceOracle, "AdminTransferCancelled");

      expect(await priceOracle.pendingAdmin()).to.equal(ethers.ZeroAddress);
    });

    it("should reject cancellation when no pending admin", async function () {
      await expect(
        priceOracle.cancelAdminTransfer()
      ).to.be.revertedWithCustomError(priceOracle, "NoPendingAdmin");
    });

    it("should allow new admin to update prices", async function () {
      await priceOracle.initiateAdminTransfer(newAdmin.address);
      await priceOracle.connect(newAdmin).acceptAdminTransfer();

      await expect(
        priceOracle.connect(newAdmin).updatePrice(await mockToken.getAddress(), 300000000000n)
      ).to.emit(priceOracle, "PriceUpdated");
    });

    it("should reject old admin from updating prices after transfer", async function () {
      await priceOracle.initiateAdminTransfer(newAdmin.address);
      await priceOracle.connect(newAdmin).acceptAdminTransfer();

      await expect(
        priceOracle.connect(owner).updatePrice(await mockToken.getAddress(), 300000000000n)
      ).to.be.revertedWithCustomError(priceOracle, "OnlyAdmin");
    });
  });
});
