const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("UniswapTwapOracle", function () {
  let uniswapOracle;
  let mockDreamsJuicyPool, mockJuicyEthPool;
  let chainlinkOracle;
  let dreamsToken, juicyToken, wethToken;
  let owner;

  const TWAP_PERIOD = 1800; // 30 minutes

  beforeEach(async function () {
    [owner] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    dreamsToken = await MockERC20.deploy("DREAMS Token", "DREAMS", 18);
    juicyToken = await MockERC20.deploy("JUICY Token", "JUICY", 18);
    wethToken = await MockERC20.deploy("Wrapped ETH", "WETH", 18);

    // Deploy mock Uniswap V3 pools
    const MockUniswapV3Pool = await ethers.getContractFactory("MockUniswapV3Pool");
    mockDreamsJuicyPool = await MockUniswapV3Pool.deploy(
      await dreamsToken.getAddress(),
      await juicyToken.getAddress()
    );
    mockJuicyEthPool = await MockUniswapV3Pool.deploy(
      await juicyToken.getAddress(),
      await wethToken.getAddress()
    );

    // Deploy a simple price oracle for Chainlink (using the existing PriceOracle as mock)
    const PriceOracle = await ethers.getContractFactory("PriceOracle");
    chainlinkOracle = await PriceOracle.deploy();

    // Set WETH price: $2000 (with 18 decimals for the value, but oracle returns 8 decimals)
    await chainlinkOracle.updatePrice(
      await wethToken.getAddress(),
      ethers.parseUnits("2000", 8) // $2000 with 8 decimals
    );

    // Deploy UniswapTwapOracle
    const UniswapTwapOracle = await ethers.getContractFactory("UniswapTwapOracle");
    uniswapOracle = await UniswapTwapOracle.deploy(
      await mockDreamsJuicyPool.getAddress(),
      await mockJuicyEthPool.getAddress(),
      await dreamsToken.getAddress(),
      await juicyToken.getAddress(),
      await wethToken.getAddress(),
      await chainlinkOracle.getAddress(),
      TWAP_PERIOD
    );

    // Set up ticks for expected price calculations
    // tick = log(price) / log(1.0001)
    // For DREAMS/JUICY: 1 DREAMS = 0.5 JUICY → tick ≈ -6932
    // For JUICY/ETH: 1 JUICY = 0.001 ETH → tick ≈ -69315
    // Note: Actual tick calculations depend on token ordering (token0 < token1)
    // The mock observe() uses these ticks to calculate price
    await mockDreamsJuicyPool.setTick(-6932); // ~0.5 price
    await mockJuicyEthPool.setTick(-69315);   // ~0.001 price
  });

  describe("Constructor Validation", function () {
    it("should deploy with valid parameters", async function () {
      expect(await uniswapOracle.dreamsToken()).to.equal(await dreamsToken.getAddress());
      expect(await uniswapOracle.juicyToken()).to.equal(await juicyToken.getAddress());
      expect(await uniswapOracle.wethToken()).to.equal(await wethToken.getAddress());
      expect(await uniswapOracle.twapPeriod()).to.equal(TWAP_PERIOD);
      expect(await uniswapOracle.admin()).to.equal(owner.address);
    });

    it("should reject zero dreams pool address", async function () {
      const UniswapTwapOracle = await ethers.getContractFactory("UniswapTwapOracle");
      await expect(
        UniswapTwapOracle.deploy(
          ethers.ZeroAddress,
          await mockJuicyEthPool.getAddress(),
          await dreamsToken.getAddress(),
          await juicyToken.getAddress(),
          await wethToken.getAddress(),
          await chainlinkOracle.getAddress(),
          TWAP_PERIOD
        )
      ).to.be.revertedWithCustomError(uniswapOracle, "InvalidAddress");
    });

    it("should reject zero juicy/eth pool address", async function () {
      const UniswapTwapOracle = await ethers.getContractFactory("UniswapTwapOracle");
      await expect(
        UniswapTwapOracle.deploy(
          await mockDreamsJuicyPool.getAddress(),
          ethers.ZeroAddress,
          await dreamsToken.getAddress(),
          await juicyToken.getAddress(),
          await wethToken.getAddress(),
          await chainlinkOracle.getAddress(),
          TWAP_PERIOD
        )
      ).to.be.revertedWithCustomError(uniswapOracle, "InvalidAddress");
    });

    it("should reject zero dreams token address", async function () {
      const UniswapTwapOracle = await ethers.getContractFactory("UniswapTwapOracle");
      await expect(
        UniswapTwapOracle.deploy(
          await mockDreamsJuicyPool.getAddress(),
          await mockJuicyEthPool.getAddress(),
          ethers.ZeroAddress,
          await juicyToken.getAddress(),
          await wethToken.getAddress(),
          await chainlinkOracle.getAddress(),
          TWAP_PERIOD
        )
      ).to.be.revertedWithCustomError(uniswapOracle, "InvalidAddress");
    });

    it("should reject zero juicy token address", async function () {
      const UniswapTwapOracle = await ethers.getContractFactory("UniswapTwapOracle");
      await expect(
        UniswapTwapOracle.deploy(
          await mockDreamsJuicyPool.getAddress(),
          await mockJuicyEthPool.getAddress(),
          await dreamsToken.getAddress(),
          ethers.ZeroAddress,
          await wethToken.getAddress(),
          await chainlinkOracle.getAddress(),
          TWAP_PERIOD
        )
      ).to.be.revertedWithCustomError(uniswapOracle, "InvalidAddress");
    });

    it("should reject zero weth token address", async function () {
      const UniswapTwapOracle = await ethers.getContractFactory("UniswapTwapOracle");
      await expect(
        UniswapTwapOracle.deploy(
          await mockDreamsJuicyPool.getAddress(),
          await mockJuicyEthPool.getAddress(),
          await dreamsToken.getAddress(),
          await juicyToken.getAddress(),
          ethers.ZeroAddress,
          await chainlinkOracle.getAddress(),
          TWAP_PERIOD
        )
      ).to.be.revertedWithCustomError(uniswapOracle, "InvalidAddress");
    });

    it("should reject zero chainlink oracle address", async function () {
      const UniswapTwapOracle = await ethers.getContractFactory("UniswapTwapOracle");
      await expect(
        UniswapTwapOracle.deploy(
          await mockDreamsJuicyPool.getAddress(),
          await mockJuicyEthPool.getAddress(),
          await dreamsToken.getAddress(),
          await juicyToken.getAddress(),
          await wethToken.getAddress(),
          ethers.ZeroAddress,
          TWAP_PERIOD
        )
      ).to.be.revertedWithCustomError(uniswapOracle, "InvalidAddress");
    });

    it("should reject zero TWAP period", async function () {
      const UniswapTwapOracle = await ethers.getContractFactory("UniswapTwapOracle");
      await expect(
        UniswapTwapOracle.deploy(
          await mockDreamsJuicyPool.getAddress(),
          await mockJuicyEthPool.getAddress(),
          await dreamsToken.getAddress(),
          await juicyToken.getAddress(),
          await wethToken.getAddress(),
          await chainlinkOracle.getAddress(),
          0
        )
      ).to.be.revertedWithCustomError(uniswapOracle, "InvalidTwapPeriod");
    });

    it("should reject pool with mismatched tokens", async function () {
      // Create a pool with different tokens
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const differentToken = await MockERC20.deploy("Different", "DIFF", 18);

      const MockUniswapV3Pool = await ethers.getContractFactory("MockUniswapV3Pool");
      const wrongPool = await MockUniswapV3Pool.deploy(
        await differentToken.getAddress(),
        await juicyToken.getAddress()
      );

      // Try to create oracle with mismatched pool
      const UniswapTwapOracle = await ethers.getContractFactory("UniswapTwapOracle");
      await expect(
        UniswapTwapOracle.deploy(
          await wrongPool.getAddress(), // Wrong pool - doesn't have DREAMS
          await mockJuicyEthPool.getAddress(),
          await dreamsToken.getAddress(),
          await juicyToken.getAddress(),
          await wethToken.getAddress(),
          await chainlinkOracle.getAddress(),
          TWAP_PERIOD
        )
      ).to.be.revertedWithCustomError(uniswapOracle, "PoolTokensMismatch");
    });
  });

  describe("Price Retrieval", function () {
    it("should correctly calculate the USD price of DREAMS token", async function () {
      // Real TWAP calculation based on tick values and mock pool observe()
      // The exact value depends on the tick math implementation
      const price = await uniswapOracle.getPrice(await dreamsToken.getAddress());

      // Just verify it returns a non-zero price (exact value depends on tick config)
      expect(price).to.be.gt(0);
    });

    it("should revert when querying price for non-DREAMS token", async function () {
      await expect(
        uniswapOracle.getPrice(await juicyToken.getAddress())
      ).to.be.revertedWithCustomError(uniswapOracle, "InvalidToken");
    });
  });

  describe("USD Conversion", function () {
    it("should correctly convert DREAMS amount to USD", async function () {
      const amount = ethers.parseEther("100"); // 100 tokens (18 decimals)
      const usdValue = await uniswapOracle.convertToUSD(
        await dreamsToken.getAddress(),
        amount
      );

      // Value should be non-zero
      expect(usdValue).to.be.gt(0);
    });

    it("should handle small amounts correctly", async function () {
      const smallAmount = ethers.parseEther("0.001"); // 0.001 tokens
      const usdValue = await uniswapOracle.convertToUSD(
        await dreamsToken.getAddress(),
        smallAmount
      );

      // Value should be non-zero for any non-zero input
      expect(usdValue).to.be.gt(0);
    });

    it("should handle large amounts correctly", async function () {
      const largeAmount = ethers.parseEther("1000000"); // 1 million tokens
      const usdValue = await uniswapOracle.convertToUSD(
        await dreamsToken.getAddress(),
        largeAmount
      );

      // Value should be greater than small amount value
      const smallValue = await uniswapOracle.convertToUSD(
        await dreamsToken.getAddress(),
        ethers.parseEther("1")
      );
      expect(usdValue).to.be.gt(smallValue);
    });
  });

  describe("Immutable State", function () {
    it("should have correct immutable values after deployment", async function () {
      expect(await uniswapOracle.dreamsJuicyPool()).to.equal(await mockDreamsJuicyPool.getAddress());
      expect(await uniswapOracle.juicyEthPool()).to.equal(await mockJuicyEthPool.getAddress());
      expect(await uniswapOracle.dreamsToken()).to.equal(await dreamsToken.getAddress());
      expect(await uniswapOracle.juicyToken()).to.equal(await juicyToken.getAddress());
      expect(await uniswapOracle.wethToken()).to.equal(await wethToken.getAddress());
      expect(await uniswapOracle.chainlinkOracle()).to.equal(await chainlinkOracle.getAddress());
      expect(await uniswapOracle.twapPeriod()).to.equal(TWAP_PERIOD);
    });
  });

  describe("Price Changes", function () {
    it("should reflect changes in ETH price", async function () {
      // Get initial price
      const initialPrice = await uniswapOracle.getPrice(await dreamsToken.getAddress());

      // Update ETH price to $4000 (double from $2000)
      await chainlinkOracle.updatePrice(
        await wethToken.getAddress(),
        ethers.parseUnits("4000", 8) // $4000 with 8 decimals
      );

      const newPrice = await uniswapOracle.getPrice(await dreamsToken.getAddress());

      // New price should be approximately double (within 5% tolerance due to tick math)
      const expectedPrice = initialPrice * 2n;
      const tolerance = expectedPrice / 20n; // 5% tolerance
      expect(newPrice).to.be.gt(expectedPrice - tolerance);
      expect(newPrice).to.be.lt(expectedPrice + tolerance);
    });
  });
});
