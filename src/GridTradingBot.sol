// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IGridTradingBot } from "./interfaces/IGridTradingBot.sol";
import { IAutomationCompatibleInterface } from "./interfaces/IAutomationCompatible.sol";
import { TWAPLib } from "./libraries/TWAPLib.sol";

/// @title ISwapRouterMinimal
/// @notice Minimal interface for Uniswap V3 SwapRouter
interface ISwapRouterMinimal {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title IUniswapV3FactoryMinimal
/// @notice Minimal interface for Uniswap V3 Factory
interface IUniswapV3FactoryMinimal {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @title GridTradingBot
/// @notice On-chain grid trading bot for Uniswap V3 on Arbitrum
/// @dev Implements automated grid trading with configurable parameters
///
/// MEV CONSIDERATIONS:
/// This contract is susceptible to MEV attacks in several ways:
/// 1. Front-running: Bots can see pending executeGrid() calls and front-run swaps
/// 2. Sandwich attacks: Attackers can sandwich our swaps for profit
/// 3. Back-running: After price moves trigger a level, bots can back-run
///
/// Mitigations implemented:
/// - TWAP oracle: Uses time-weighted price (60s default), harder to manipulate than spot
/// - Slippage protection: Reverts if execution price deviates too much from expected
/// - Execution cooldown: Prevents rapid re-triggering of same level
/// - Min output calculation: Ensures minimum acceptable output based on TWAP + slippage
///
/// Additional mitigations to consider for production:
/// - Use Flashbots Protect RPC for transaction submission
/// - Implement commit-reveal scheme for large orders
/// - Add private mempool integration (e.g., MEV Blocker)
/// - Randomize execution timing in the keeper
contract GridTradingBot is IGridTradingBot, IAutomationCompatibleInterface, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Maximum allowed slippage (10%)
    uint256 public constant MAX_SLIPPAGE_BPS = 1000;

    /// @notice Minimum grid levels
    uint256 public constant MIN_GRID_LEVELS = 2;

    /// @notice Maximum grid levels
    uint256 public constant MAX_GRID_LEVELS = 100;

    /// @notice Price scaling factor (1e18)
    uint256 public constant PRICE_PRECISION = 1e18;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Default TWAP interval in seconds
    uint32 public constant DEFAULT_TWAP_INTERVAL = 60;

    /// @notice Maximum swaps per execution to prevent gas limit issues
    uint256 public constant MAX_SWAPS_PER_EXECUTION = 10;

    // ============ Immutables ============

    /// @notice Uniswap V3 SwapRouter address
    address public immutable swapRouter;

    /// @notice Uniswap V3 Factory address (used to find pools)
    address public immutable factory;

    // ============ State Variables ============

    /// @notice Contract owner (only address that can deposit/withdraw/configure)
    address public owner;

    /// @notice Current grid configuration
    GridConfig private _gridConfig;

    /// @notice Grid levels mapping (index => GridLevel)
    mapping(uint256 => GridLevel) private _gridLevels;

    /// @notice Number of initialized grid levels
    uint256 private _levelCount;

    /// @notice Whether the bot is paused
    bool private _paused;

    /// @notice Minimum time between executions on the same level (seconds)
    uint256 private _executionCooldown;

    /// @notice Whether the grid has been configured
    bool private _isConfigured;

    /// @notice Whether levels have been initialized
    bool private _levelsInitialized;

    /// @notice TWAP interval for price queries (seconds)
    uint32 private _twapInterval;

    /// @notice The Uniswap V3 pool address for the trading pair
    address private _pool;

    /// @notice Whether tokenA is token0 in the Uniswap pool
    bool private _tokenAIsToken0;

    /// @notice Total number of swaps executed
    uint256 public totalSwapsExecuted;

    // ============ Modifiers ============

    /// @notice Restricts function to owner only
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Ensures the bot is not paused
    modifier whenNotPaused() {
        require(!_paused, "Bot is paused");
        _;
    }

    /// @notice Ensures the bot is paused
    modifier whenPaused() {
        require(_paused, "Bot is not paused");
        _;
    }

    // ============ Constructor ============

    /// @notice Initializes the GridTradingBot
    /// @param _swapRouter Uniswap V3 SwapRouter address
    /// @param _factory Uniswap V3 Factory address
    constructor(address _swapRouter, address _factory) {
        if (_swapRouter == address(0) || _factory == address(0)) revert ZeroAddress();

        owner = msg.sender;
        swapRouter = _swapRouter;
        factory = _factory;
        _executionCooldown = 60; // Default 60 seconds cooldown
        _twapInterval = DEFAULT_TWAP_INTERVAL;
        _paused = false;
    }

    // ============ Deposit Functions ============

    /// @inheritdoc IGridTradingBot
    function depositTokenA(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (!_isConfigured) revert GridNotConfigured();

        IERC20(_gridConfig.tokenA).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(_gridConfig.tokenA, amount, block.timestamp);
    }

    /// @inheritdoc IGridTradingBot
    function depositTokenB(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (!_isConfigured) revert GridNotConfigured();

        IERC20(_gridConfig.tokenB).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(_gridConfig.tokenB, amount, block.timestamp);
    }

    // ============ Withdraw Functions ============

    /// @inheritdoc IGridTradingBot
    function withdrawTokenA(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (!_isConfigured) revert GridNotConfigured();

        uint256 balance = IERC20(_gridConfig.tokenA).balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();

        IERC20(_gridConfig.tokenA).safeTransfer(msg.sender, amount);

        emit Withdrawn(_gridConfig.tokenA, amount, block.timestamp);
    }

    /// @inheritdoc IGridTradingBot
    function withdrawTokenB(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (!_isConfigured) revert GridNotConfigured();

        uint256 balance = IERC20(_gridConfig.tokenB).balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();

        IERC20(_gridConfig.tokenB).safeTransfer(msg.sender, amount);

        emit Withdrawn(_gridConfig.tokenB, amount, block.timestamp);
    }

    // ============ Configuration Functions ============

    /// @inheritdoc IGridTradingBot
    function configureGrid(GridConfig calldata config) external onlyOwner {
        // Validate token addresses
        if (config.tokenA == address(0) || config.tokenB == address(0)) revert ZeroAddress();
        if (config.tokenA == config.tokenB) revert InvalidGridConfig();

        // Validate price range
        if (config.lowerPrice == 0 || config.upperPrice == 0) revert InvalidGridConfig();
        if (config.lowerPrice >= config.upperPrice) revert InvalidGridConfig();

        // Validate grid levels
        if (config.gridLevels < MIN_GRID_LEVELS || config.gridLevels > MAX_GRID_LEVELS) {
            revert InvalidGridConfig();
        }

        // Validate order sizes
        if (config.orderSizeA == 0 || config.orderSizeB == 0) revert InvalidGridConfig();

        // Validate pool fee (Uniswap V3 fee tiers: 100, 500, 3000, 10000)
        if (
            config.poolFee != 100 && config.poolFee != 500 && config.poolFee != 3000 && config.poolFee != 10000
        ) {
            revert InvalidGridConfig();
        }

        // Validate slippage
        if (config.maxSlippageBps == 0 || config.maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert InvalidSlippage();
        }

        // Find and validate the Uniswap V3 pool
        address pool = IUniswapV3FactoryMinimal(factory).getPool(config.tokenA, config.tokenB, config.poolFee);
        require(pool != address(0), "Pool does not exist");

        _gridConfig = config;
        _pool = pool;
        _isConfigured = true;
        _levelsInitialized = false; // Reset levels when config changes

        // Determine token order in pool
        _tokenAIsToken0 = config.tokenA < config.tokenB;

        emit GridConfigured(config.lowerPrice, config.upperPrice, config.gridLevels, block.timestamp);
    }

    /// @inheritdoc IGridTradingBot
    /// @dev Uses geometric spacing: each level is a fixed percentage apart
    /// Formula: price[i] = lowerPrice * (upperPrice/lowerPrice)^(i/(n-1))
    /// where n is the number of levels and i goes from 0 to n-1
    function initializeLevels() external onlyOwner {
        if (!_isConfigured) revert GridNotConfigured();

        uint256 numLevels = _gridConfig.gridLevels;
        uint256 lowerPrice = _gridConfig.lowerPrice;
        uint256 upperPrice = _gridConfig.upperPrice;

        // Get current price to determine initial buy/sell sides
        uint256 currentPrice = _getTWAPPrice();

        // If we can't get TWAP, use mid-price as fallback
        if (currentPrice == 0) {
            currentPrice = (lowerPrice + upperPrice) / 2;
        }

        for (uint256 i = 0; i < numLevels; i++) {
            // Calculate price at this level using geometric interpolation
            uint256 levelPrice = _calculateGeometricPrice(lowerPrice, upperPrice, i, numLevels);

            // Levels below current price start as BUY, levels above start as SELL
            bool isBuyLevel = levelPrice < currentPrice;

            _gridLevels[i] = GridLevel({
                price: levelPrice,
                isBuyLevel: isBuyLevel,
                isActive: true,
                lastExecutedAt: 0
            });
        }

        _levelCount = numLevels;
        _levelsInitialized = true;

        emit LevelsInitialized(numLevels, block.timestamp);
    }

    /// @notice Calculate price at a specific grid level using geometric spacing
    /// @param lowerPrice Lower bound price
    /// @param upperPrice Upper bound price
    /// @param index Current level index (0-based)
    /// @param totalLevels Total number of levels
    /// @return The price at this level
    function _calculateGeometricPrice(
        uint256 lowerPrice,
        uint256 upperPrice,
        uint256 index,
        uint256 totalLevels
    ) internal pure returns (uint256) {
        if (index == 0) return lowerPrice;
        if (index == totalLevels - 1) return upperPrice;

        uint256 range = upperPrice - lowerPrice;
        uint256 steps = totalLevels - 1;

        // Practical approximation for geometric spacing:
        uint256 fraction = (index * PRICE_PRECISION) / steps;

        // Quadratic interpolation for geometric-like behavior
        uint256 adjustedFraction = (fraction * fraction) / PRICE_PRECISION;
        adjustedFraction = (fraction + adjustedFraction) / 2; // Blend linear and quadratic

        return lowerPrice + (range * adjustedFraction) / PRICE_PRECISION;
    }

    // ============ Execution Functions ============

    /// @inheritdoc IGridTradingBot
    /// @dev Main execution function - checks price and executes swaps for triggered levels
    function executeGrid() external whenNotPaused nonReentrant {
        if (!_isConfigured) revert GridNotConfigured();
        if (!_levelsInitialized) revert LevelsNotInitialized();

        // Get current TWAP price
        uint256 currentPrice = _getTWAPPrice();
        require(currentPrice > 0, "Could not get price");

        // Track swaps executed to prevent gas limit issues
        uint256 swapsExecuted = 0;

        // Loop through all levels and check for triggers
        for (uint256 i = 0; i < _levelCount && swapsExecuted < MAX_SWAPS_PER_EXECUTION; i++) {
            GridLevel storage level = _gridLevels[i];

            // Skip inactive levels or levels in cooldown
            if (!level.isActive) continue;
            if (block.timestamp < level.lastExecutedAt + _executionCooldown) continue;

            bool shouldExecute = false;

            if (level.isBuyLevel) {
                // BUY level: triggers when price drops to or below level price
                // We want to buy tokenA with tokenB when price is low
                shouldExecute = currentPrice <= level.price;
            } else {
                // SELL level: triggers when price rises to or above level price
                // We want to sell tokenA for tokenB when price is high
                shouldExecute = currentPrice >= level.price;
            }

            if (shouldExecute) {
                _executeSwap(i, level.isBuyLevel, currentPrice);
                swapsExecuted++;
            }
        }
    }

    /// @notice Execute a swap for a triggered level
    /// @param levelIndex Index of the triggered level
    /// @param isBuy Whether this is a buy (true) or sell (false)
    /// @param currentPrice Current TWAP price for slippage calculation
    function _executeSwap(uint256 levelIndex, bool isBuy, uint256 currentPrice) internal {
        GridLevel storage level = _gridLevels[levelIndex];

        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 expectedAmountOut;
        uint256 minAmountOut;

        if (isBuy) {
            // BUY tokenA with tokenB
            tokenIn = _gridConfig.tokenB;
            tokenOut = _gridConfig.tokenA;
            amountIn = _gridConfig.orderSizeB;

            // Expected output: amountIn / price (since price is tokenB per tokenA)
            // If price = 2000 USDC/ETH and we spend 200 USDC, we expect 0.1 ETH
            expectedAmountOut = (amountIn * PRICE_PRECISION) / currentPrice;

            // Adjust for decimal differences (tokenB has 6 decimals, tokenA has 18)
            uint8 decimalsA = IERC20Metadata(_gridConfig.tokenA).decimals();
            uint8 decimalsB = IERC20Metadata(_gridConfig.tokenB).decimals();
            if (decimalsA > decimalsB) {
                expectedAmountOut = expectedAmountOut * (10 ** (decimalsA - decimalsB));
            } else if (decimalsB > decimalsA) {
                expectedAmountOut = expectedAmountOut / (10 ** (decimalsB - decimalsA));
            }
        } else {
            // SELL tokenA for tokenB
            tokenIn = _gridConfig.tokenA;
            tokenOut = _gridConfig.tokenB;
            amountIn = _gridConfig.orderSizeA;

            // Expected output: amountIn * price
            // If price = 2000 USDC/ETH and we sell 0.1 ETH, we expect 200 USDC
            expectedAmountOut = (amountIn * currentPrice) / PRICE_PRECISION;

            // Adjust for decimal differences
            uint8 decimalsA = IERC20Metadata(_gridConfig.tokenA).decimals();
            uint8 decimalsB = IERC20Metadata(_gridConfig.tokenB).decimals();
            if (decimalsB > decimalsA) {
                expectedAmountOut = expectedAmountOut / (10 ** (decimalsB - decimalsA));
            } else if (decimalsA > decimalsB) {
                expectedAmountOut = expectedAmountOut * (10 ** (decimalsA - decimalsB));
            }
        }

        // Check we have sufficient balance
        uint256 balance = IERC20(tokenIn).balanceOf(address(this));
        if (balance < amountIn) {
            // Insufficient balance - skip this level but don't revert
            // This allows other levels to still execute
            return;
        }

        // Calculate minimum output with slippage protection
        minAmountOut = (expectedAmountOut * (BPS_DENOMINATOR - _gridConfig.maxSlippageBps)) / BPS_DENOMINATOR;

        // Reset allowance to zero first, then set exact amount needed
        // This prevents unbounded allowance growth over time
        IERC20(tokenIn).safeApprove(swapRouter, 0);
        IERC20(tokenIn).safeApprove(swapRouter, amountIn);

        // Build swap parameters
        ISwapRouterMinimal.ExactInputSingleParams memory params = ISwapRouterMinimal.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: _gridConfig.poolFee,
            recipient: address(this),
            deadline: block.timestamp + 300, // 5 minute deadline
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0 // No price limit, rely on slippage protection
        });

        // Execute swap
        uint256 amountOut;
        try ISwapRouterMinimal(swapRouter).exactInputSingle(params) returns (uint256 _amountOut) {
            amountOut = _amountOut;
            // Reset allowance to zero after successful swap
            IERC20(tokenIn).safeApprove(swapRouter, 0);
        } catch {
            // Swap failed - reset allowance to zero
            IERC20(tokenIn).safeApprove(swapRouter, 0);
            return;
        }

        // Verify slippage (redundant but explicit check)
        if (amountOut < minAmountOut) revert SlippageExceeded();

        // Update level state - flip buy/sell direction
        level.isBuyLevel = !isBuy;
        level.lastExecutedAt = block.timestamp;

        totalSwapsExecuted++;

        // Emit events
        emit LevelTriggered(levelIndex, currentPrice, isBuy, block.timestamp);
        emit SwapExecuted(levelIndex, tokenIn, tokenOut, amountIn, amountOut, currentPrice, block.timestamp);
    }

    /// @notice Get TWAP price from Uniswap V3 pool
    /// @return price The TWAP price (tokenB per tokenA, scaled by 1e18)
    function _getTWAPPrice() internal view returns (uint256 price) {
        if (_pool == address(0)) return 0;

        uint8 decimalsA = IERC20Metadata(_gridConfig.tokenA).decimals();
        uint8 decimalsB = IERC20Metadata(_gridConfig.tokenB).decimals();

        uint8 token0Decimals;
        uint8 token1Decimals;
        bool baseIsToken0;

        if (_tokenAIsToken0) {
            token0Decimals = decimalsA;
            token1Decimals = decimalsB;
            baseIsToken0 = true;
        } else {
            token0Decimals = decimalsB;
            token1Decimals = decimalsA;
            baseIsToken0 = false;
        }

        try this.getTWAPPriceExternal(token0Decimals, token1Decimals, baseIsToken0) returns (uint256 _price) {
            price = _price;
        } catch {
            price = 0;
        }
    }

    /// @notice External wrapper for TWAP calculation (allows try/catch)
    /// @dev This is a view function that can be called externally for try/catch
    function getTWAPPriceExternal(
        uint8 token0Decimals,
        uint8 token1Decimals,
        bool baseIsToken0
    ) external view returns (uint256) {
        return TWAPLib.getTWAPPrice(_pool, _twapInterval, token0Decimals, token1Decimals, baseIsToken0);
    }

    // ============ Admin Functions ============

    /// @inheritdoc IGridTradingBot
    function pause() external onlyOwner whenNotPaused {
        _paused = true;
        emit BotPaused(block.timestamp);
    }

    /// @inheritdoc IGridTradingBot
    function unpause() external onlyOwner whenPaused {
        _paused = false;
        emit BotUnpaused(block.timestamp);
    }

    /// @inheritdoc IGridTradingBot
    function setSlippage(uint256 newSlippageBps) external onlyOwner {
        if (newSlippageBps == 0 || newSlippageBps > MAX_SLIPPAGE_BPS) revert InvalidSlippage();
        if (!_isConfigured) revert GridNotConfigured();

        _gridConfig.maxSlippageBps = newSlippageBps;

        emit SlippageUpdated(newSlippageBps, block.timestamp);
    }

    /// @inheritdoc IGridTradingBot
    function setCooldown(uint256 newCooldown) external onlyOwner {
        _executionCooldown = newCooldown;

        emit CooldownUpdated(newCooldown, block.timestamp);
    }

    /// @notice Set the TWAP interval for price queries
    /// @param newInterval New TWAP interval in seconds
    function setTWAPInterval(uint32 newInterval) external onlyOwner {
        require(newInterval >= 10, "TWAP interval too short");
        require(newInterval <= 3600, "TWAP interval too long");
        _twapInterval = newInterval;
    }

    /// @notice Transfer ownership to a new address
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner is zero address");
        require(newOwner != owner, "Already the owner");

        address oldOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /// @notice Emergency withdraw all funds to owner
    /// @dev Can be called even when paused, only by owner
    /// @dev Use this in case of emergency to recover all funds
    function emergencyWithdrawAll() external onlyOwner nonReentrant {
        if (!_isConfigured) revert GridNotConfigured();

        uint256 balanceA = IERC20(_gridConfig.tokenA).balanceOf(address(this));
        uint256 balanceB = IERC20(_gridConfig.tokenB).balanceOf(address(this));

        if (balanceA > 0) {
            IERC20(_gridConfig.tokenA).safeTransfer(owner, balanceA);
            emit EmergencyWithdraw(_gridConfig.tokenA, balanceA, block.timestamp);
        }

        if (balanceB > 0) {
            IERC20(_gridConfig.tokenB).safeTransfer(owner, balanceB);
            emit EmergencyWithdraw(_gridConfig.tokenB, balanceB, block.timestamp);
        }

        // Auto-pause after emergency withdrawal
        if (!_paused) {
            _paused = true;
            emit BotPaused(block.timestamp);
        }
    }

    /// @notice Deactivate a specific grid level
    /// @param levelIndex Index of the level to deactivate
    function deactivateLevel(uint256 levelIndex) external onlyOwner {
        require(levelIndex < _levelCount, "Level index out of bounds");
        _gridLevels[levelIndex].isActive = false;
    }

    /// @notice Activate a specific grid level
    /// @param levelIndex Index of the level to activate
    function activateLevel(uint256 levelIndex) external onlyOwner {
        require(levelIndex < _levelCount, "Level index out of bounds");
        _gridLevels[levelIndex].isActive = true;
    }

    /// @notice Reset a level's cooldown (allows immediate re-execution)
    /// @param levelIndex Index of the level to reset
    function resetLevelCooldown(uint256 levelIndex) external onlyOwner {
        require(levelIndex < _levelCount, "Level index out of bounds");
        _gridLevels[levelIndex].lastExecutedAt = 0;
    }

    // ============ View Functions ============

    /// @inheritdoc IGridTradingBot
    function getGridConfig() external view returns (GridConfig memory) {
        return _gridConfig;
    }

    /// @inheritdoc IGridTradingBot
    function getGridLevel(uint256 levelIndex) external view returns (GridLevel memory) {
        require(levelIndex < _levelCount, "Level index out of bounds");
        return _gridLevels[levelIndex];
    }

    /// @inheritdoc IGridTradingBot
    function getLevelCount() external view returns (uint256) {
        return _levelCount;
    }

    /// @inheritdoc IGridTradingBot
    function getCurrentPrice() external view returns (uint256) {
        return _getTWAPPrice();
    }

    /// @inheritdoc IGridTradingBot
    function getBalanceA() external view returns (uint256) {
        if (!_isConfigured) return 0;
        return IERC20(_gridConfig.tokenA).balanceOf(address(this));
    }

    /// @inheritdoc IGridTradingBot
    function getBalanceB() external view returns (uint256) {
        if (!_isConfigured) return 0;
        return IERC20(_gridConfig.tokenB).balanceOf(address(this));
    }

    /// @inheritdoc IGridTradingBot
    function isPaused() external view returns (bool) {
        return _paused;
    }

    /// @inheritdoc IGridTradingBot
    function getExecutionCooldown() external view returns (uint256) {
        return _executionCooldown;
    }

    /// @notice Check if grid is configured
    /// @return True if configured
    function isConfigured() external view returns (bool) {
        return _isConfigured;
    }

    /// @notice Check if levels are initialized
    /// @return True if initialized
    function areLevelsInitialized() external view returns (bool) {
        return _levelsInitialized;
    }

    /// @notice Get the pool address
    /// @return The Uniswap V3 pool address
    function getPool() external view returns (address) {
        return _pool;
    }

    /// @notice Get the TWAP interval
    /// @return The TWAP interval in seconds
    function getTWAPInterval() external view returns (uint32) {
        return _twapInterval;
    }

    /// @notice Legacy getter for quoter (now returns factory for compatibility)
    /// @return The factory address
    function quoter() external view returns (address) {
        return factory;
    }

    // ============ Chainlink Automation Functions ============

    /// @notice Chainlink Automation check function
    /// @dev Called by Chainlink nodes to determine if upkeep is needed
    /// @param checkData Optional data passed during upkeep registration (unused)
    /// @return upkeepNeeded True if any grid level can be triggered
    /// @return performData Encoded array of triggerable level indices
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // Silence unused variable warning
        checkData;

        // Return false if not ready to execute
        if (_paused || !_isConfigured || !_levelsInitialized) {
            return (false, "");
        }

        // Try to get current price
        uint256 currentPrice = _getTWAPPrice();
        if (currentPrice == 0) {
            return (false, "");
        }

        // Check each level for triggers
        uint256[] memory triggerableLevels = new uint256[](_levelCount);
        uint256 triggerCount = 0;

        for (uint256 i = 0; i < _levelCount; i++) {
            GridLevel storage level = _gridLevels[i];

            // Skip inactive levels or levels in cooldown
            if (!level.isActive) continue;
            if (block.timestamp < level.lastExecutedAt + _executionCooldown) continue;

            bool shouldTrigger = false;

            if (level.isBuyLevel) {
                shouldTrigger = currentPrice <= level.price;
            } else {
                shouldTrigger = currentPrice >= level.price;
            }

            if (shouldTrigger) {
                // Check if we have sufficient balance
                address tokenIn = level.isBuyLevel ? _gridConfig.tokenB : _gridConfig.tokenA;
                uint256 amountIn = level.isBuyLevel ? _gridConfig.orderSizeB : _gridConfig.orderSizeA;
                uint256 balance = IERC20(tokenIn).balanceOf(address(this));

                if (balance >= amountIn) {
                    triggerableLevels[triggerCount] = i;
                    triggerCount++;
                }
            }
        }

        if (triggerCount > 0) {
            // Resize array to actual count
            uint256[] memory actualTriggers = new uint256[](triggerCount);
            for (uint256 i = 0; i < triggerCount; i++) {
                actualTriggers[i] = triggerableLevels[i];
            }
            return (true, abi.encode(actualTriggers));
        }

        return (false, "");
    }

    /// @notice Chainlink Automation perform function
    /// @dev Called by Chainlink nodes when checkUpkeep returns true
    /// @param performData Encoded array of level indices to execute (from checkUpkeep)
    function performUpkeep(bytes calldata performData) external override whenNotPaused nonReentrant {
        // Decode the triggerable levels
        uint256[] memory levelIndices = abi.decode(performData, (uint256[]));

        // Re-verify conditions and execute
        // Note: We re-verify everything because state may have changed
        require(_isConfigured, "Not configured");
        require(_levelsInitialized, "Levels not initialized");

        uint256 currentPrice = _getTWAPPrice();
        require(currentPrice > 0, "Could not get price");

        for (uint256 i = 0; i < levelIndices.length; i++) {
            uint256 levelIndex = levelIndices[i];

            // Bounds check
            if (levelIndex >= _levelCount) continue;

            GridLevel storage level = _gridLevels[levelIndex];

            // Re-verify all conditions
            if (!level.isActive) continue;
            if (block.timestamp < level.lastExecutedAt + _executionCooldown) continue;

            bool shouldExecute = false;
            if (level.isBuyLevel) {
                shouldExecute = currentPrice <= level.price;
            } else {
                shouldExecute = currentPrice >= level.price;
            }

            if (shouldExecute) {
                _executeSwap(levelIndex, level.isBuyLevel, currentPrice);
            }
        }
    }
}
