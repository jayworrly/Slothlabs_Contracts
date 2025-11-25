const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("SlothPriceOracle", function () {
  let slothOracle, chainlinkOracle, uniswapOracle;
  let owner, admin;
  let tokenA, tokenB;

  beforeEach(async function () {
    [owner, admin] = await ethers.getSigners();

    // Deploy mock oracles. We can use the simple PriceOracle as a mock for both.
    const PriceOracle = await ethers.getContractFactory("PriceOracle");
    chainlinkOracle = await PriceOracle.deploy();
    uniswapOracle = await PriceOracle.deploy();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    tokenA = await MockERC20.deploy("Token A", "TKA", 18);
    tokenB = await MockERC20.deploy("Token B", "TKB", 18);
    
    // Deploy SlothPriceOracle
    const SlothPriceOracle = await ethers.getContractFactory("SlothPriceOracle");
    slothOracle = await SlothPriceOracle.deploy();

    // Set admin
    await slothOracle.connect(owner).initiateAdminTransfer(admin.address);
    await slothOracle.connect(admin).acceptAdminTransfer();

    // Set prices in mock oracles
    // Price is in USD with 8 decimals
    await chainlinkOracle.connect(owner).updatePrice(await tokenA.getAddress(), ethers.parseUnits("100", 8)); // Token A = $100
    await uniswapOracle.connect(owner).updatePrice(await tokenB.getAddress(), ethers.parseUnits("0.5", 8)); // Token B = $0.5
  });

  describe("Configuration", function () {
    it("should allow admin to set a token oracle", async function () {
      await expect(
        slothOracle.connect(admin).setTokenOracle(await tokenA.getAddress(), await chainlinkOracle.getAddress())
      ).to.emit(slothOracle, "TokenOracleSet")
        .withArgs(await tokenA.getAddress(), await chainlinkOracle.getAddress());

      expect(await slothOracle.tokenOracles(await tokenA.getAddress())).to.equal(await chainlinkOracle.getAddress());
    });

    it("should reject setting a token oracle from non-admin", async function () {
      await expect(
        slothOracle.connect(owner).setTokenOracle(await tokenA.getAddress(), await chainlinkOracle.getAddress())
      ).to.be.revertedWithCustomError(slothOracle, "OnlyAdmin");
    });
  });

  describe("Price Routing", function () {
    beforeEach(async function () {
      // Configure routes
      await slothOracle.connect(admin).setTokenOracle(await tokenA.getAddress(), await chainlinkOracle.getAddress());
      await slothOracle.connect(admin).setTokenOracle(await tokenB.getAddress(), await uniswapOracle.getAddress());
    });

    it("should route getPrice to the correct oracle", async function () {
      // Price from chainlinkOracle
      const priceA = await slothOracle.getPrice(await tokenA.getAddress());
      expect(priceA).to.equal(ethers.parseUnits("100", 8));

      // Price from uniswapOracle
      const priceB = await slothOracle.getPrice(await tokenB.getAddress());
      expect(priceB).to.equal(ethers.parseUnits("0.5", 8));
    });

    it("should route convertToUSD to the correct oracle", async function () {
        const amount = ethers.parseEther("10"); // 10 tokens with 18 decimals

        // Convert token A
        const usdValueA = await slothOracle.convertToUSD(await tokenA.getAddress(), amount);
        // 10 * 100 = 1000
        expect(usdValueA).to.equal(ethers.parseEther("1000"));

        // Convert token B
        const usdValueB = await slothOracle.convertToUSD(await tokenB.getAddress(), amount);
        // 10 * 0.5 = 5
        expect(usdValueB).to.equal(ethers.parseEther("5"));
    });

    it("should revert if no oracle is set for a token", async function () {
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        const tokenC = await MockERC20.deploy("Token C", "TKC", 18);

        await expect(
            slothOracle.getPrice(await tokenC.getAddress())
        ).to.be.revertedWithCustomError(slothOracle, "OracleNotSetForToken");
    });
  });
});
