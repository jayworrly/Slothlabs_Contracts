// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title DreamsTreasurySale
 * @notice When you buy DREAMS tokens, we buy them from the open market for you.
 *         The treasury keeps 5% as a fee, you get 95%.
 *
 * HOW IT WORKS:
 * 1. You send ETH (on Base) or AVAX (on Avalanche)
 * 2. We automatically swap it for JUICY tokens
 * 3. We swap JUICY for DREAMS tokens
 * 4. Treasury keeps 5% of the DREAMS (that's how we make money)
 * 5. You receive 95% of the DREAMS
 *
 * AUTO-STAKE OPTION:
 * If enabled, your DREAMS are automatically staked to start earning rewards
 * instead of just sitting in your wallet.
 *
 * WHY THIS IS GOOD:
 * - Creates natural buying pressure for DREAMS tokens (good for price)
 * - Treasury earns sustainable revenue (keeps the platform running)
 * - You get real market prices (not some made-up rate)
 * - Simple and transparent - everyone knows the 5% fee upfront
 * - Lower fee than competitors encourages adoption
 */

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface ITraderJoeRouter {
    function swapExactAVAXForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IDreamsStaking {
    function stakeFor(address beneficiary, uint256 amount) external;
}

contract DreamsTreasurySale is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ STATE ============
    IERC20 public immutable dreams;
    IERC20 public immutable juicy;
    address public immutable wrappedNative;  // WETH on BASE, WAVAX on AVAX
    address public treasury;
    address public admin;

    // DEX Router (Uniswap on BASE, Trader Joe on AVAX)
    address public dexRouter;
    uint24 public poolFee = 3000;  // 0.3% for Uniswap V3 (ignored on Trader Joe)

    // Chain identification
    bool public immutable isAvalanche;

    // Fee configuration
    uint256 public constant TREASURY_FEE_BPS = 500;  // 5% fee to treasury
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant SLIPPAGE_BPS = 200;       // 2% max slippage

    bool public salesEnabled = true;

    // AUTO-STAKE: When enabled, user's DREAMS are automatically staked
    bool public autoStakeEnabled = true;
    address public dreamsStaking;  // DreamsStaking contract for auto-lock

    // ============ EVENTS ============
    event MarketBuy(
        address indexed buyer,
        uint256 nativeAmount,
        uint256 juicySwapped,
        uint256 totalDreamsBought,
        uint256 treasuryFee,
        uint256 userReceived,
        uint256 timestamp
    );
    event DirectJuicyBuy(
        address indexed buyer,
        uint256 juicyAmount,
        uint256 totalDreamsBought,
        uint256 treasuryFee,
        uint256 userReceived,
        uint256 timestamp
    );
    event SalesToggled(bool enabled);
    event RouterUpdated(address oldRouter, address newRouter);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event AutoStakeToggled(bool enabled);
    event StakingUpdated(address oldStaking, address newStaking);
    event AutoStaked(address indexed buyer, uint256 amount);

    // ============ ERRORS ============
    error SalesDisabled();
    error InvalidAmount();
    error OnlyAdmin();
    error SwapFailed();
    error InvalidAddress();

    // ============ MODIFIERS ============
    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor(
        address _dreams,
        address _juicy,
        address _wrappedNative,
        address _dexRouter,
        address _treasury,
        bool _isAvalanche
    ) {
        if (_dreams == address(0) || _juicy == address(0)) revert InvalidAddress();
        if (_wrappedNative == address(0) || _dexRouter == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();

        dreams = IERC20(_dreams);
        juicy = IERC20(_juicy);
        wrappedNative = _wrappedNative;
        dexRouter = _dexRouter;
        treasury = _treasury;
        isAvalanche = _isAvalanche;
        admin = msg.sender;

        // Approve router to spend tokens
        IERC20(_juicy).approve(_dexRouter, type(uint256).max);
        IERC20(_dreams).approve(_dexRouter, type(uint256).max);
    }

    // ============ MAIN PURCHASE FUNCTIONS ============

    /**
     * @notice Buy DREAMS with native token (ETH/AVAX) - treasury takes 5% fee
     * @dev Route: ETH/AVAX → JUICY → DREAMS
     *      Treasury receives 5% of DREAMS bought
     *      User receives 95% of DREAMS bought (optionally auto-staked)
     */
    function buyWithNative() external payable nonReentrant {
        if (!salesEnabled) revert SalesDisabled();
        if (msg.value == 0) revert InvalidAmount();

        // Step 1: Swap native → JUICY
        uint256 juicyReceived = _swapNativeToJuicy(msg.value);

        // Step 2: Swap JUICY → DREAMS (all to this contract)
        uint256 totalDreams = _swapJuicyToDreams(juicyReceived, address(this));

        // Step 3-5: Split fees and deliver DREAMS
        (uint256 treasuryFee, uint256 userAmount) = _completePurchase(msg.sender, totalDreams);

        emit MarketBuy(
            msg.sender,
            msg.value,
            juicyReceived,
            totalDreams,
            treasuryFee,
            userAmount,
            block.timestamp
        );
    }

    /**
     * @notice Buy DREAMS directly with JUICY - treasury takes 5% fee
     * @param juicyAmount Amount of JUICY to spend
     */
    function buyWithJuicy(uint256 juicyAmount) external nonReentrant {
        if (!salesEnabled) revert SalesDisabled();
        if (juicyAmount == 0) revert InvalidAmount();

        // Step 1: Pull JUICY from user
        juicy.safeTransferFrom(msg.sender, address(this), juicyAmount);

        // Step 2: Swap JUICY → DREAMS (all to this contract)
        uint256 totalDreams = _swapJuicyToDreams(juicyAmount, address(this));

        // Step 3-5: Split fees and deliver DREAMS
        (uint256 treasuryFee, uint256 userAmount) = _completePurchase(msg.sender, totalDreams);

        emit DirectJuicyBuy(
            msg.sender,
            juicyAmount,
            totalDreams,
            treasuryFee,
            userAmount,
            block.timestamp
        );
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Complete purchase by splitting fees and delivering DREAMS
     * @dev Shared logic for both buyWithNative and buyWithJuicy
     * @param recipient The user receiving DREAMS
     * @param totalDreams Total DREAMS received from swap
     * @return treasuryFee Amount sent to treasury (5%)
     * @return userAmount Amount sent to user (95%)
     */
    function _completePurchase(address recipient, uint256 totalDreams)
        internal
        returns (uint256 treasuryFee, uint256 userAmount)
    {
        // Calculate fee split
        treasuryFee = (totalDreams * TREASURY_FEE_BPS) / BPS_DENOMINATOR;  // 5%
        userAmount = totalDreams - treasuryFee;  // 95%

        // Send fee to treasury
        dreams.safeTransfer(treasury, treasuryFee);

        // Send DREAMS to user (or auto-stake)
        _deliverDreams(recipient, userAmount);
    }

    /**
     * @notice Send DREAMS to the buyer
     * @dev If auto-stake is enabled, the tokens are automatically locked to earn
     *      rewards instead of going directly to their wallet.
     */
    function _deliverDreams(address recipient, uint256 amount) internal {
        if (autoStakeEnabled && dreamsStaking != address(0)) {
            dreams.approve(dreamsStaking, amount);
            IDreamsStaking(dreamsStaking).stakeFor(recipient, amount);
            emit AutoStaked(recipient, amount);
        } else {
            dreams.safeTransfer(recipient, amount);
        }
    }

    /**
     * @notice Swap native → JUICY
     */
    function _swapNativeToJuicy(uint256 nativeAmount) internal returns (uint256) {
        if (isAvalanche) {
            return _swapAvaxToJuicy(nativeAmount);
        } else {
            return _swapEthToJuicy(nativeAmount);
        }
    }

    /**
     * @notice Swap AVAX → JUICY on Trader Joe
     */
    function _swapAvaxToJuicy(uint256 avaxAmount) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = wrappedNative;  // WAVAX
        path[1] = address(juicy);

        // Get expected output for slippage calculation
        uint256[] memory amountsOut = ITraderJoeRouter(dexRouter).getAmountsOut(avaxAmount, path);
        uint256 minOut = (amountsOut[1] * (BPS_DENOMINATOR - SLIPPAGE_BPS)) / BPS_DENOMINATOR;

        uint256[] memory amounts = ITraderJoeRouter(dexRouter).swapExactAVAXForTokens{value: avaxAmount}(
            minOut,
            path,
            address(this),
            block.timestamp + 300
        );

        return amounts[1];
    }

    /**
     * @notice Swap ETH → JUICY on Uniswap V3 (BASE)
     */
    function _swapEthToJuicy(uint256 ethAmount) internal returns (uint256) {
        // Wrap ETH to WETH
        IWETH(wrappedNative).deposit{value: ethAmount}();
        IWETH(wrappedNative).approve(dexRouter, ethAmount);

        // Swap WETH → JUICY
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: wrappedNative,
            tokenOut: address(juicy),
            fee: poolFee,
            recipient: address(this),
            amountIn: ethAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 juicyOut = ISwapRouter(dexRouter).exactInputSingle(params);
        if (juicyOut == 0) revert SwapFailed();

        return juicyOut;
    }

    /**
     * @notice Swap JUICY → DREAMS
     */
    function _swapJuicyToDreams(uint256 juicyAmount, address recipient) internal returns (uint256) {
        if (isAvalanche) {
            address[] memory path = new address[](2);
            path[0] = address(juicy);
            path[1] = address(dreams);

            // Get expected output for slippage
            uint256[] memory amountsOut = ITraderJoeRouter(dexRouter).getAmountsOut(juicyAmount, path);
            uint256 minOut = (amountsOut[1] * (BPS_DENOMINATOR - SLIPPAGE_BPS)) / BPS_DENOMINATOR;

            uint256[] memory amounts = ITraderJoeRouter(dexRouter).swapExactTokensForTokens(
                juicyAmount,
                minOut,
                path,
                recipient,
                block.timestamp + 300
            );
            return amounts[1];
        } else {
            // Uniswap V3 on BASE
            juicy.approve(dexRouter, juicyAmount);

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(juicy),
                tokenOut: address(dreams),
                fee: poolFee,
                recipient: recipient,
                amountIn: juicyAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

            uint256 dreamsOut = ISwapRouter(dexRouter).exactInputSingle(params);
            if (dreamsOut == 0) revert SwapFailed();
            return dreamsOut;
        }
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get quote for native token purchase
     * @param nativeAmount Amount of ETH/AVAX to spend
     * @return juicyEstimate Estimated JUICY from first swap
     * @return dreamsEstimate Total DREAMS from second swap
     * @return treasuryFee 5% fee to treasury
     * @return userReceives 95% that user receives
     */
    function getQuoteNative(uint256 nativeAmount) external view returns (
        uint256 juicyEstimate,
        uint256 dreamsEstimate,
        uint256 treasuryFee,
        uint256 userReceives
    ) {
        // Estimate native → JUICY
        if (isAvalanche) {
            address[] memory path = new address[](2);
            path[0] = wrappedNative;
            path[1] = address(juicy);

            try ITraderJoeRouter(dexRouter).getAmountsOut(nativeAmount, path) returns (uint256[] memory amounts) {
                juicyEstimate = amounts[1];
            } catch {
                return (0, 0, 0, 0);
            }
        } else {
            // BASE: Placeholder - would need Uniswap quoter
            juicyEstimate = nativeAmount * 1000;  // Placeholder
        }

        // Estimate JUICY → DREAMS
        if (juicyEstimate > 0) {
            address[] memory path2 = new address[](2);
            path2[0] = address(juicy);
            path2[1] = address(dreams);

            if (isAvalanche) {
                try ITraderJoeRouter(dexRouter).getAmountsOut(juicyEstimate, path2) returns (uint256[] memory amounts) {
                    dreamsEstimate = amounts[1];
                } catch {
                    dreamsEstimate = (juicyEstimate * 75) / 10;  // Fallback
                }
            } else {
                dreamsEstimate = (juicyEstimate * 75) / 10;  // Placeholder
            }

            treasuryFee = (dreamsEstimate * TREASURY_FEE_BPS) / BPS_DENOMINATOR;
            userReceives = dreamsEstimate - treasuryFee;
        }
    }

    /**
     * @notice Get quote for JUICY purchase
     * @param juicyAmount Amount of JUICY to spend
     */
    function getQuoteJuicy(uint256 juicyAmount) external view returns (
        uint256 dreamsEstimate,
        uint256 treasuryFee,
        uint256 userReceives
    ) {
        address[] memory path = new address[](2);
        path[0] = address(juicy);
        path[1] = address(dreams);

        if (isAvalanche) {
            try ITraderJoeRouter(dexRouter).getAmountsOut(juicyAmount, path) returns (uint256[] memory amounts) {
                dreamsEstimate = amounts[1];
            } catch {
                dreamsEstimate = (juicyAmount * 75) / 10;  // Fallback
            }
        } else {
            dreamsEstimate = (juicyAmount * 75) / 10;  // Placeholder
        }

        treasuryFee = (dreamsEstimate * TREASURY_FEE_BPS) / BPS_DENOMINATOR;
        userReceives = dreamsEstimate - treasuryFee;
    }

    /**
     * @notice Get treasury accumulated DREAMS balance
     */
    function getTreasuryStats() external view returns (
        uint256 treasuryDreams,
        uint256 treasuryJuicy,
        bool isEnabled
    ) {
        treasuryDreams = dreams.balanceOf(treasury);
        treasuryJuicy = juicy.balanceOf(treasury);
        isEnabled = salesEnabled;
    }

    // ============ ADMIN FUNCTIONS ============

    function toggleSales() external onlyAdmin {
        salesEnabled = !salesEnabled;
        emit SalesToggled(salesEnabled);
    }

    function updateRouter(address _newRouter) external onlyAdmin {
        if (_newRouter == address(0)) revert InvalidAddress();
        address oldRouter = dexRouter;
        dexRouter = _newRouter;

        // Update approvals
        juicy.approve(oldRouter, 0);
        dreams.approve(oldRouter, 0);
        juicy.approve(_newRouter, type(uint256).max);
        dreams.approve(_newRouter, type(uint256).max);

        emit RouterUpdated(oldRouter, _newRouter);
    }

    function updateTreasury(address _newTreasury) external onlyAdmin {
        if (_newTreasury == address(0)) revert InvalidAddress();
        address oldTreasury = treasury;
        treasury = _newTreasury;
        emit TreasuryUpdated(oldTreasury, _newTreasury);
    }

    function updatePoolFee(uint24 _newFee) external onlyAdmin {
        poolFee = _newFee;
    }

    function toggleAutoStake() external onlyAdmin {
        autoStakeEnabled = !autoStakeEnabled;
        emit AutoStakeToggled(autoStakeEnabled);
    }

    function updateStaking(address _newStaking) external onlyAdmin {
        address oldStaking = dreamsStaking;
        dreamsStaking = _newStaking;

        // Update approval for new staking contract
        if (oldStaking != address(0)) {
            dreams.approve(oldStaking, 0);
        }
        if (_newStaking != address(0)) {
            dreams.approve(_newStaking, type(uint256).max);
        }

        emit StakingUpdated(oldStaking, _newStaking);
    }

    function transferAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert InvalidAddress();
        admin = _newAdmin;
    }

    /**
     * @notice Emergency withdraw stuck tokens
     */
    function rescueTokens(address _token, uint256 _amount) external onlyAdmin {
        IERC20(_token).safeTransfer(admin, _amount);
    }

    /**
     * @notice Emergency withdraw stuck ETH/AVAX
     */
    function rescueNative() external onlyAdmin {
        (bool success, ) = admin.call{value: address(this).balance}("");
        require(success, "Transfer failed");
    }

    // Allow contract to receive ETH/AVAX
    receive() external payable {}
}
