// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IGridTradingBot
/// @notice Interface for the Grid Trading Bot contract
/// @dev Defines the external functions and events for grid trading on Uniswap V3
interface IGridTradingBot {
    // ============ Structs ============

    /// @notice Configuration for the trading grid
    /// @param tokenA The base token (e.g., WETH)
    /// @param tokenB The quote token (e.g., USDC)
    /// @param lowerPrice Lower bound of the grid (tokenB per tokenA, scaled by 1e18)
    /// @param upperPrice Upper bound of the grid (tokenB per tokenA, scaled by 1e18)
    /// @param gridLevels Number of grid lines
    /// @param orderSizeA Amount of tokenA per grid order (in tokenA decimals)
    /// @param orderSizeB Amount of tokenB per grid order (in tokenB decimals)
    /// @param poolFee Uniswap V3 pool fee tier (500, 3000, or 10000)
    /// @param maxSlippageBps Maximum allowed slippage in basis points (1 bps = 0.01%)
    struct GridConfig {
        address tokenA;
        address tokenB;
        uint256 lowerPrice;
        uint256 upperPrice;
        uint256 gridLevels;
        uint256 orderSizeA;
        uint256 orderSizeB;
        uint24 poolFee;
        uint256 maxSlippageBps;
    }

    /// @notice State of a single grid level
    /// @param price Price at this level (tokenB per tokenA, scaled by 1e18)
    /// @param isBuyLevel True if waiting to buy tokenA, false if waiting to sell
    /// @param isActive Whether this level can be triggered
    /// @param lastExecutedAt Timestamp of last execution (for cooldown)
    struct GridLevel {
        uint256 price;
        bool isBuyLevel;
        bool isActive;
        uint256 lastExecutedAt;
    }

    // ============ Events ============

    /// @notice Emitted when tokens are deposited
    /// @param token Address of the deposited token
    /// @param amount Amount deposited
    /// @param timestamp Block timestamp
    event Deposited(address indexed token, uint256 amount, uint256 timestamp);

    /// @notice Emitted when tokens are withdrawn
    /// @param token Address of the withdrawn token
    /// @param amount Amount withdrawn
    /// @param timestamp Block timestamp
    event Withdrawn(address indexed token, uint256 amount, uint256 timestamp);

    /// @notice Emitted when grid is configured
    /// @param lowerPrice Lower bound of the grid
    /// @param upperPrice Upper bound of the grid
    /// @param gridLevels Number of grid levels
    /// @param timestamp Block timestamp
    event GridConfigured(uint256 lowerPrice, uint256 upperPrice, uint256 gridLevels, uint256 timestamp);

    /// @notice Emitted when grid levels are initialized
    /// @param levelCount Number of levels initialized
    /// @param timestamp Block timestamp
    event LevelsInitialized(uint256 levelCount, uint256 timestamp);

    /// @notice Emitted when a swap is executed
    /// @param levelIndex Index of the triggered level
    /// @param tokenIn Address of the input token
    /// @param tokenOut Address of the output token
    /// @param amountIn Amount of input token
    /// @param amountOut Amount of output token received
    /// @param executionPrice Price at execution
    /// @param timestamp Block timestamp
    event SwapExecuted(
        uint256 indexed levelIndex,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 executionPrice,
        uint256 timestamp
    );

    /// @notice Emitted when a level is triggered
    /// @param levelIndex Index of the triggered level
    /// @param triggerPrice Price that triggered the level
    /// @param isBuy Whether this was a buy (true) or sell (false)
    /// @param timestamp Block timestamp
    event LevelTriggered(uint256 indexed levelIndex, uint256 triggerPrice, bool isBuy, uint256 timestamp);

    /// @notice Emitted when the contract is paused
    /// @param timestamp Block timestamp
    event BotPaused(uint256 timestamp);

    /// @notice Emitted when the contract is unpaused
    /// @param timestamp Block timestamp
    event BotUnpaused(uint256 timestamp);

    /// @notice Emitted when execution cooldown is updated
    /// @param newCooldown New cooldown value in seconds
    /// @param timestamp Block timestamp
    event CooldownUpdated(uint256 newCooldown, uint256 timestamp);

    /// @notice Emitted when slippage is updated
    /// @param newSlippageBps New slippage value in basis points
    /// @param timestamp Block timestamp
    event SlippageUpdated(uint256 newSlippageBps, uint256 timestamp);

    /// @notice Emitted when ownership is transferred
    /// @param previousOwner Address of the previous owner
    /// @param newOwner Address of the new owner
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when emergency withdrawal occurs
    /// @param token Address of the withdrawn token
    /// @param amount Amount withdrawn
    /// @param timestamp Block timestamp
    event EmergencyWithdraw(address indexed token, uint256 amount, uint256 timestamp);

    // ============ Errors ============

    error NotOwner();
    error InvalidGridConfig();
    error InvalidAmount();
    error InvalidSlippage();
    error GridNotConfigured();
    error LevelsNotInitialized();
    error InsufficientBalance();
    error TransferFailed();
    error SwapFailed();
    error SlippageExceeded();
    error CooldownNotElapsed();
    error ZeroAddress();

    // ============ External Functions ============

    /// @notice Deposit tokenA (e.g., WETH) into the contract
    /// @param amount Amount to deposit
    function depositTokenA(uint256 amount) external;

    /// @notice Deposit tokenB (e.g., USDC) into the contract
    /// @param amount Amount to deposit
    function depositTokenB(uint256 amount) external;

    /// @notice Withdraw tokenA from the contract
    /// @param amount Amount to withdraw
    function withdrawTokenA(uint256 amount) external;

    /// @notice Withdraw tokenB from the contract
    /// @param amount Amount to withdraw
    function withdrawTokenB(uint256 amount) external;

    /// @notice Configure the trading grid parameters
    /// @param config The grid configuration
    function configureGrid(GridConfig calldata config) external;

    /// @notice Initialize grid levels based on current configuration
    /// @dev Calculates geometric spacing between levels
    function initializeLevels() external;

    /// @notice Main execution function - checks price and executes swaps
    /// @dev Called by Chainlink Automation or manually
    function executeGrid() external;

    /// @notice Pause the bot
    function pause() external;

    /// @notice Unpause the bot
    function unpause() external;

    /// @notice Update the maximum slippage
    /// @param newSlippageBps New slippage in basis points
    function setSlippage(uint256 newSlippageBps) external;

    /// @notice Update the execution cooldown
    /// @param newCooldown New cooldown in seconds
    function setCooldown(uint256 newCooldown) external;

    // ============ View Functions ============

    /// @notice Get the current grid configuration
    /// @return The grid configuration struct
    function getGridConfig() external view returns (GridConfig memory);

    /// @notice Get a specific grid level
    /// @param levelIndex Index of the level
    /// @return The grid level struct
    function getGridLevel(uint256 levelIndex) external view returns (GridLevel memory);

    /// @notice Get the total number of grid levels
    /// @return Number of levels
    function getLevelCount() external view returns (uint256);

    /// @notice Get the current price from the oracle/pool
    /// @return Current price (tokenB per tokenA, scaled by 1e18)
    function getCurrentPrice() external view returns (uint256);

    /// @notice Get the contract's balance of tokenA
    /// @return Balance of tokenA
    function getBalanceA() external view returns (uint256);

    /// @notice Get the contract's balance of tokenB
    /// @return Balance of tokenB
    function getBalanceB() external view returns (uint256);

    /// @notice Check if the bot is paused
    /// @return True if paused
    function isPaused() external view returns (bool);

    /// @notice Get the execution cooldown
    /// @return Cooldown in seconds
    function getExecutionCooldown() external view returns (uint256);
}
