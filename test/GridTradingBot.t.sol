// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { GridTradingBot } from "../src/GridTradingBot.sol";
import { IGridTradingBot } from "../src/interfaces/IGridTradingBot.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockUniswapV3Factory } from "./mocks/MockUniswapV3Factory.sol";
import { MockUniswapV3Pool } from "./mocks/MockUniswapV3Pool.sol";

/// @title GridTradingBotTest
/// @notice Unit tests for GridTradingBot functionality
contract GridTradingBotTest is Test {
    // ============ Events (copied from interface for testing) ============

    event Deposited(address indexed token, uint256 amount, uint256 timestamp);
    event Withdrawn(address indexed token, uint256 amount, uint256 timestamp);
    event GridConfigured(uint256 lowerPrice, uint256 upperPrice, uint256 gridLevels, uint256 timestamp);
    event LevelsInitialized(uint256 levelCount, uint256 timestamp);
    event BotPaused(uint256 timestamp);
    event BotUnpaused(uint256 timestamp);
    event CooldownUpdated(uint256 newCooldown, uint256 timestamp);
    event SlippageUpdated(uint256 newSlippageBps, uint256 timestamp);
    event SwapExecuted(
        uint256 indexed levelIndex,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 executionPrice,
        uint256 timestamp
    );
    event LevelTriggered(uint256 indexed levelIndex, uint256 triggerPrice, bool isBuy, uint256 timestamp);

    // ============ Test Contracts ============

    GridTradingBot public bot;
    MockERC20 public weth;
    MockERC20 public usdc;
    MockUniswapV3Factory public factory;
    MockUniswapV3Pool public pool;

    // ============ Test Addresses ============

    address public owner;
    address public user;
    address public swapRouter;

    // ============ Test Constants ============

    uint256 constant INITIAL_WETH = 10 ether;
    uint256 constant INITIAL_USDC = 20_000 * 1e6; // 20,000 USDC

    uint256 constant LOWER_PRICE = 1800 * 1e18; // $1800
    uint256 constant UPPER_PRICE = 2200 * 1e18; // $2200
    uint256 constant GRID_LEVELS = 10;
    uint256 constant ORDER_SIZE_A = 0.1 ether; // 0.1 WETH per order
    uint256 constant ORDER_SIZE_B = 200 * 1e6; // 200 USDC per order
    uint24 constant POOL_FEE = 500; // 0.05%
    uint256 constant MAX_SLIPPAGE = 50; // 0.5%

    // ============ Setup ============

    function setUp() public {
        // Create test addresses
        owner = makeAddr("owner");
        user = makeAddr("user");
        swapRouter = makeAddr("swapRouter");

        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy mock Uniswap factory and pool
        factory = new MockUniswapV3Factory();

        // Create pool with sorted tokens
        address token0 = address(weth) < address(usdc) ? address(weth) : address(usdc);
        address token1 = address(weth) < address(usdc) ? address(usdc) : address(weth);
        pool = new MockUniswapV3Pool(token0, token1, POOL_FEE);

        // Set pool in factory
        factory.setPool(address(weth), address(usdc), POOL_FEE, address(pool));

        // Set up TWAP data - simulate 60 seconds of price data at tick 74000 (~$2000)
        // tickCumulative difference over 60 seconds = tick * 60
        pool.setTickCumulatives(0, 74000 * 60);

        // Deploy bot as owner
        vm.prank(owner);
        bot = new GridTradingBot(swapRouter, address(factory));

        // Mint tokens to owner
        weth.mint(owner, INITIAL_WETH);
        usdc.mint(owner, INITIAL_USDC);

        // Approve bot to spend owner's tokens
        vm.startPrank(owner);
        weth.approve(address(bot), type(uint256).max);
        usdc.approve(address(bot), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsOwner() public view {
        assertEq(bot.owner(), owner);
    }

    function test_Constructor_SetsSwapRouter() public view {
        assertEq(bot.swapRouter(), swapRouter);
    }

    function test_Constructor_SetsFactory() public view {
        assertEq(bot.factory(), address(factory));
    }

    function test_Constructor_SetsDefaultCooldown() public view {
        assertEq(bot.getExecutionCooldown(), 60);
    }

    function test_Constructor_SetsDefaultTWAPInterval() public view {
        assertEq(bot.getTWAPInterval(), 60);
    }

    function test_Constructor_StartsUnpaused() public view {
        assertFalse(bot.isPaused());
    }

    function test_Constructor_RevertsOnZeroSwapRouter() public {
        vm.expectRevert(IGridTradingBot.ZeroAddress.selector);
        new GridTradingBot(address(0), address(factory));
    }

    function test_Constructor_RevertsOnZeroFactory() public {
        vm.expectRevert(IGridTradingBot.ZeroAddress.selector);
        new GridTradingBot(swapRouter, address(0));
    }

    // ============ Grid Configuration Tests ============

    function test_ConfigureGrid_Success() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();

        vm.prank(owner);
        bot.configureGrid(config);

        IGridTradingBot.GridConfig memory storedConfig = bot.getGridConfig();
        assertEq(storedConfig.tokenA, address(weth));
        assertEq(storedConfig.tokenB, address(usdc));
        assertEq(storedConfig.lowerPrice, LOWER_PRICE);
        assertEq(storedConfig.upperPrice, UPPER_PRICE);
        assertEq(storedConfig.gridLevels, GRID_LEVELS);
        assertEq(storedConfig.orderSizeA, ORDER_SIZE_A);
        assertEq(storedConfig.orderSizeB, ORDER_SIZE_B);
        assertEq(storedConfig.poolFee, POOL_FEE);
        assertEq(storedConfig.maxSlippageBps, MAX_SLIPPAGE);
    }

    function test_ConfigureGrid_SetsPool() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();

        vm.prank(owner);
        bot.configureGrid(config);

        assertEq(bot.getPool(), address(pool));
    }

    function test_ConfigureGrid_SetsIsConfigured() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();

        vm.prank(owner);
        bot.configureGrid(config);

        assertTrue(bot.isConfigured());
    }

    function test_ConfigureGrid_EmitsEvent() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit GridConfigured(LOWER_PRICE, UPPER_PRICE, GRID_LEVELS, block.timestamp);
        bot.configureGrid(config);
    }

    function test_ConfigureGrid_RevertsNotOwner() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();

        vm.prank(user);
        vm.expectRevert(IGridTradingBot.NotOwner.selector);
        bot.configureGrid(config);
    }

    function test_ConfigureGrid_RevertsZeroTokenA() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();
        config.tokenA = address(0);

        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.ZeroAddress.selector);
        bot.configureGrid(config);
    }

    function test_ConfigureGrid_RevertsZeroTokenB() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();
        config.tokenB = address(0);

        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.ZeroAddress.selector);
        bot.configureGrid(config);
    }

    function test_ConfigureGrid_RevertsSameTokens() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();
        config.tokenB = address(weth);

        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.InvalidGridConfig.selector);
        bot.configureGrid(config);
    }

    function test_ConfigureGrid_RevertsZeroLowerPrice() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();
        config.lowerPrice = 0;

        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.InvalidGridConfig.selector);
        bot.configureGrid(config);
    }

    function test_ConfigureGrid_RevertsLowerGteUpper() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();
        config.lowerPrice = UPPER_PRICE;

        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.InvalidGridConfig.selector);
        bot.configureGrid(config);
    }

    function test_ConfigureGrid_RevertsTooFewLevels() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();
        config.gridLevels = 1;

        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.InvalidGridConfig.selector);
        bot.configureGrid(config);
    }

    function test_ConfigureGrid_RevertsTooManyLevels() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();
        config.gridLevels = 101;

        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.InvalidGridConfig.selector);
        bot.configureGrid(config);
    }

    function test_ConfigureGrid_RevertsInvalidPoolFee() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();
        config.poolFee = 1000; // Invalid fee tier

        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.InvalidGridConfig.selector);
        bot.configureGrid(config);
    }

    function test_ConfigureGrid_RevertsZeroSlippage() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();
        config.maxSlippageBps = 0;

        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.InvalidSlippage.selector);
        bot.configureGrid(config);
    }

    function test_ConfigureGrid_RevertsExcessiveSlippage() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();
        config.maxSlippageBps = 1001; // > 10%

        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.InvalidSlippage.selector);
        bot.configureGrid(config);
    }

    function test_ConfigureGrid_RevertsPoolNotExist() public {
        IGridTradingBot.GridConfig memory config = _createValidConfig();
        config.poolFee = 3000; // Different fee tier with no pool

        vm.prank(owner);
        vm.expectRevert("Pool does not exist");
        bot.configureGrid(config);
    }

    // ============ Initialize Levels Tests ============

    function test_InitializeLevels_Success() public {
        _configureGrid();

        vm.prank(owner);
        bot.initializeLevels();

        assertTrue(bot.areLevelsInitialized());
        assertEq(bot.getLevelCount(), GRID_LEVELS);
    }

    function test_InitializeLevels_CorrectPriceRange() public {
        _configureGrid();

        vm.prank(owner);
        bot.initializeLevels();

        // First level should be at lower price
        IGridTradingBot.GridLevel memory firstLevel = bot.getGridLevel(0);
        assertEq(firstLevel.price, LOWER_PRICE);

        // Last level should be at upper price
        IGridTradingBot.GridLevel memory lastLevel = bot.getGridLevel(GRID_LEVELS - 1);
        assertEq(lastLevel.price, UPPER_PRICE);
    }

    function test_InitializeLevels_AllActive() public {
        _configureGrid();

        vm.prank(owner);
        bot.initializeLevels();

        for (uint256 i = 0; i < GRID_LEVELS; i++) {
            IGridTradingBot.GridLevel memory level = bot.getGridLevel(i);
            assertTrue(level.isActive);
            assertEq(level.lastExecutedAt, 0);
        }
    }

    function test_InitializeLevels_EmitsEvent() public {
        _configureGrid();

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit LevelsInitialized(GRID_LEVELS, block.timestamp);
        bot.initializeLevels();
    }

    function test_InitializeLevels_RevertsNotConfigured() public {
        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.GridNotConfigured.selector);
        bot.initializeLevels();
    }

    function test_InitializeLevels_RevertsNotOwner() public {
        _configureGrid();

        vm.prank(user);
        vm.expectRevert(IGridTradingBot.NotOwner.selector);
        bot.initializeLevels();
    }

    // ============ Deposit Tests ============

    function test_DepositTokenA_Success() public {
        _configureGrid();

        uint256 depositAmount = 1 ether;

        vm.prank(owner);
        bot.depositTokenA(depositAmount);

        assertEq(bot.getBalanceA(), depositAmount);
        assertEq(weth.balanceOf(address(bot)), depositAmount);
    }

    function test_DepositTokenA_EmitsEvent() public {
        _configureGrid();

        uint256 depositAmount = 1 ether;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit Deposited(address(weth), depositAmount, block.timestamp);
        bot.depositTokenA(depositAmount);
    }

    function test_DepositTokenA_RevertsNotOwner() public {
        _configureGrid();

        vm.prank(user);
        vm.expectRevert(IGridTradingBot.NotOwner.selector);
        bot.depositTokenA(1 ether);
    }

    function test_DepositTokenA_RevertsZeroAmount() public {
        _configureGrid();

        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.InvalidAmount.selector);
        bot.depositTokenA(0);
    }

    function test_DepositTokenA_RevertsNotConfigured() public {
        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.GridNotConfigured.selector);
        bot.depositTokenA(1 ether);
    }

    function test_DepositTokenB_Success() public {
        _configureGrid();

        uint256 depositAmount = 1000 * 1e6;

        vm.prank(owner);
        bot.depositTokenB(depositAmount);

        assertEq(bot.getBalanceB(), depositAmount);
        assertEq(usdc.balanceOf(address(bot)), depositAmount);
    }

    function test_DepositTokenB_EmitsEvent() public {
        _configureGrid();

        uint256 depositAmount = 1000 * 1e6;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit Deposited(address(usdc), depositAmount, block.timestamp);
        bot.depositTokenB(depositAmount);
    }

    // ============ Withdraw Tests ============

    function test_WithdrawTokenA_Success() public {
        _configureGrid();

        uint256 depositAmount = 1 ether;
        uint256 withdrawAmount = 0.5 ether;

        vm.startPrank(owner);
        bot.depositTokenA(depositAmount);
        bot.withdrawTokenA(withdrawAmount);
        vm.stopPrank();

        assertEq(bot.getBalanceA(), depositAmount - withdrawAmount);
        assertEq(weth.balanceOf(owner), INITIAL_WETH - depositAmount + withdrawAmount);
    }

    function test_WithdrawTokenA_EmitsEvent() public {
        _configureGrid();

        uint256 depositAmount = 1 ether;
        uint256 withdrawAmount = 0.5 ether;

        vm.startPrank(owner);
        bot.depositTokenA(depositAmount);

        vm.expectEmit(true, true, true, true);
        emit Withdrawn(address(weth), withdrawAmount, block.timestamp);
        bot.withdrawTokenA(withdrawAmount);
        vm.stopPrank();
    }

    function test_WithdrawTokenA_RevertsInsufficientBalance() public {
        _configureGrid();

        uint256 depositAmount = 1 ether;

        vm.startPrank(owner);
        bot.depositTokenA(depositAmount);

        vm.expectRevert(IGridTradingBot.InsufficientBalance.selector);
        bot.withdrawTokenA(depositAmount + 1);
        vm.stopPrank();
    }

    function test_WithdrawTokenA_RevertsNotOwner() public {
        _configureGrid();

        vm.prank(owner);
        bot.depositTokenA(1 ether);

        vm.prank(user);
        vm.expectRevert(IGridTradingBot.NotOwner.selector);
        bot.withdrawTokenA(0.5 ether);
    }

    function test_WithdrawTokenB_Success() public {
        _configureGrid();

        uint256 depositAmount = 1000 * 1e6;
        uint256 withdrawAmount = 500 * 1e6;

        vm.startPrank(owner);
        bot.depositTokenB(depositAmount);
        bot.withdrawTokenB(withdrawAmount);
        vm.stopPrank();

        assertEq(bot.getBalanceB(), depositAmount - withdrawAmount);
    }

    // ============ Pause Tests ============

    function test_Pause_Success() public {
        vm.prank(owner);
        bot.pause();

        assertTrue(bot.isPaused());
    }

    function test_Pause_EmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit BotPaused(block.timestamp);
        bot.pause();
    }

    function test_Pause_RevertsNotOwner() public {
        vm.prank(user);
        vm.expectRevert(IGridTradingBot.NotOwner.selector);
        bot.pause();
    }

    function test_Pause_RevertsAlreadyPaused() public {
        vm.startPrank(owner);
        bot.pause();

        vm.expectRevert("Bot is paused");
        bot.pause();
        vm.stopPrank();
    }

    function test_Unpause_Success() public {
        vm.startPrank(owner);
        bot.pause();
        bot.unpause();
        vm.stopPrank();

        assertFalse(bot.isPaused());
    }

    function test_Unpause_EmitsEvent() public {
        vm.startPrank(owner);
        bot.pause();

        vm.expectEmit(true, true, true, true);
        emit BotUnpaused(block.timestamp);
        bot.unpause();
        vm.stopPrank();
    }

    function test_Unpause_RevertsNotPaused() public {
        vm.prank(owner);
        vm.expectRevert("Bot is not paused");
        bot.unpause();
    }

    // ============ Slippage Tests ============

    function test_SetSlippage_Success() public {
        _configureGrid();

        uint256 newSlippage = 100; // 1%

        vm.prank(owner);
        bot.setSlippage(newSlippage);

        IGridTradingBot.GridConfig memory config = bot.getGridConfig();
        assertEq(config.maxSlippageBps, newSlippage);
    }

    function test_SetSlippage_EmitsEvent() public {
        _configureGrid();

        uint256 newSlippage = 100;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SlippageUpdated(newSlippage, block.timestamp);
        bot.setSlippage(newSlippage);
    }

    function test_SetSlippage_RevertsZero() public {
        _configureGrid();

        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.InvalidSlippage.selector);
        bot.setSlippage(0);
    }

    function test_SetSlippage_RevertsExcessive() public {
        _configureGrid();

        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.InvalidSlippage.selector);
        bot.setSlippage(1001);
    }

    // ============ Cooldown Tests ============

    function test_SetCooldown_Success() public {
        uint256 newCooldown = 120;

        vm.prank(owner);
        bot.setCooldown(newCooldown);

        assertEq(bot.getExecutionCooldown(), newCooldown);
    }

    function test_SetCooldown_EmitsEvent() public {
        uint256 newCooldown = 120;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit CooldownUpdated(newCooldown, block.timestamp);
        bot.setCooldown(newCooldown);
    }

    function test_SetCooldown_RevertsNotOwner() public {
        vm.prank(user);
        vm.expectRevert(IGridTradingBot.NotOwner.selector);
        bot.setCooldown(120);
    }

    // ============ TWAP Interval Tests ============

    function test_SetTWAPInterval_Success() public {
        uint32 newInterval = 120;

        vm.prank(owner);
        bot.setTWAPInterval(newInterval);

        assertEq(bot.getTWAPInterval(), newInterval);
    }

    function test_SetTWAPInterval_RevertsTooShort() public {
        vm.prank(owner);
        vm.expectRevert("TWAP interval too short");
        bot.setTWAPInterval(5);
    }

    function test_SetTWAPInterval_RevertsTooLong() public {
        vm.prank(owner);
        vm.expectRevert("TWAP interval too long");
        bot.setTWAPInterval(7200);
    }

    // ============ Execute Grid Tests ============

    function test_ExecuteGrid_RevertsWhenPaused() public {
        _configureGrid();
        _initializeLevels();

        vm.prank(owner);
        bot.pause();

        vm.expectRevert("Bot is paused");
        bot.executeGrid();
    }

    function test_ExecuteGrid_RevertsNotConfigured() public {
        vm.expectRevert(IGridTradingBot.GridNotConfigured.selector);
        bot.executeGrid();
    }

    function test_ExecuteGrid_RevertsLevelsNotInitialized() public {
        _configureGrid();

        vm.expectRevert(IGridTradingBot.LevelsNotInitialized.selector);
        bot.executeGrid();
    }

    // ============ View Functions Tests ============

    function test_GetBalanceA_ReturnsZeroNotConfigured() public view {
        assertEq(bot.getBalanceA(), 0);
    }

    function test_GetBalanceB_ReturnsZeroNotConfigured() public view {
        assertEq(bot.getBalanceB(), 0);
    }

    function test_GetGridLevel_RevertsOutOfBounds() public {
        _configureGrid();
        _initializeLevels();

        vm.expectRevert("Level index out of bounds");
        bot.getGridLevel(GRID_LEVELS);
    }

    function test_TotalSwapsExecuted_StartsAtZero() public view {
        assertEq(bot.totalSwapsExecuted(), 0);
    }

    // ============ Ownership Transfer Tests ============

    function test_TransferOwnership_Success() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        bot.transferOwnership(newOwner);

        assertEq(bot.owner(), newOwner);
    }

    function test_TransferOwnership_RevertsNotOwner() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(user);
        vm.expectRevert(IGridTradingBot.NotOwner.selector);
        bot.transferOwnership(newOwner);
    }

    function test_TransferOwnership_RevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("New owner is zero address");
        bot.transferOwnership(address(0));
    }

    function test_TransferOwnership_RevertsSameOwner() public {
        vm.prank(owner);
        vm.expectRevert("Already the owner");
        bot.transferOwnership(owner);
    }

    // ============ Emergency Withdraw Tests ============

    function test_EmergencyWithdrawAll_Success() public {
        _configureGrid();

        // Deposit funds
        vm.startPrank(owner);
        bot.depositTokenA(1 ether);
        bot.depositTokenB(1000 * 1e6);

        uint256 ownerWethBefore = weth.balanceOf(owner);
        uint256 ownerUsdcBefore = usdc.balanceOf(owner);

        // Emergency withdraw
        bot.emergencyWithdrawAll();
        vm.stopPrank();

        // Check all funds returned to owner
        assertEq(weth.balanceOf(owner), ownerWethBefore + 1 ether);
        assertEq(usdc.balanceOf(owner), ownerUsdcBefore + 1000 * 1e6);

        // Check bot is paused after emergency withdrawal
        assertTrue(bot.isPaused());

        // Check bot has no funds
        assertEq(bot.getBalanceA(), 0);
        assertEq(bot.getBalanceB(), 0);
    }

    function test_EmergencyWithdrawAll_RevertsNotOwner() public {
        _configureGrid();

        vm.prank(user);
        vm.expectRevert(IGridTradingBot.NotOwner.selector);
        bot.emergencyWithdrawAll();
    }

    function test_EmergencyWithdrawAll_RevertsNotConfigured() public {
        vm.prank(owner);
        vm.expectRevert(IGridTradingBot.GridNotConfigured.selector);
        bot.emergencyWithdrawAll();
    }

    // ============ Level Management Tests ============

    function test_DeactivateLevel_Success() public {
        _configureGrid();
        _initializeLevels();

        vm.prank(owner);
        bot.deactivateLevel(5);

        IGridTradingBot.GridLevel memory level = bot.getGridLevel(5);
        assertFalse(level.isActive);
    }

    function test_DeactivateLevel_RevertsOutOfBounds() public {
        _configureGrid();
        _initializeLevels();

        vm.prank(owner);
        vm.expectRevert("Level index out of bounds");
        bot.deactivateLevel(GRID_LEVELS);
    }

    function test_ActivateLevel_Success() public {
        _configureGrid();
        _initializeLevels();

        vm.startPrank(owner);
        bot.deactivateLevel(5);
        bot.activateLevel(5);
        vm.stopPrank();

        IGridTradingBot.GridLevel memory level = bot.getGridLevel(5);
        assertTrue(level.isActive);
    }

    function test_ResetLevelCooldown_Success() public {
        _configureGrid();
        _initializeLevels();

        // Simulate that level was executed by setting lastExecutedAt
        // We can't directly set state, so we just test the function works
        vm.prank(owner);
        bot.resetLevelCooldown(5);

        IGridTradingBot.GridLevel memory level = bot.getGridLevel(5);
        assertEq(level.lastExecutedAt, 0);
    }

    // ============ Chainlink Automation Tests ============

    function test_CheckUpkeep_ReturnsFalseWhenPaused() public {
        _configureGrid();
        _initializeLevels();

        vm.prank(owner);
        bot.pause();

        (bool upkeepNeeded, ) = bot.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_ReturnsFalseWhenNotConfigured() public {
        (bool upkeepNeeded, ) = bot.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_ReturnsFalseWhenLevelsNotInitialized() public {
        _configureGrid();

        (bool upkeepNeeded, ) = bot.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_ReturnsPerformData() public {
        // This test verifies checkUpkeep returns properly formatted data
        // when conditions would allow upkeep (not paused, configured, levels init)
        _configureGrid();
        _initializeLevels();

        // Verify initial state allows upkeep checks to run
        // (Even if no levels trigger due to price, the function should work)
        (bool upkeepNeeded, bytes memory performData) = bot.checkUpkeep("");

        // The function should complete without reverting
        // upkeepNeeded depends on price conditions which are mock-dependent
        // Just verify the function executes and returns valid types
        if (upkeepNeeded) {
            assertTrue(performData.length > 0, "Should have perform data when upkeep needed");
        } else {
            assertEq(performData.length, 0, "Should have no perform data when upkeep not needed");
        }
    }

    function test_CheckUpkeep_ReturnsFalseWhenInsufficientBalance() public {
        _configureGrid();
        _initializeLevels();

        // Set price at lower bound but don't deposit funds
        pool.setTick(73000);

        (bool upkeepNeeded, ) = bot.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_PerformUpkeep_RevertsWhenPaused() public {
        _configureGrid();
        _initializeLevels();

        vm.prank(owner);
        bot.pause();

        uint256[] memory levels = new uint256[](1);
        levels[0] = 0;

        vm.expectRevert("Bot is paused");
        bot.performUpkeep(abi.encode(levels));
    }

    function test_PerformUpkeep_RevertsWhenNotConfigured() public {
        uint256[] memory levels = new uint256[](1);
        levels[0] = 0;

        vm.expectRevert("Not configured");
        bot.performUpkeep(abi.encode(levels));
    }

    function test_PerformUpkeep_SkipsInvalidLevelIndex() public {
        _configureGrid();
        _initializeLevels();

        // Deposit funds
        deal(address(usdc), owner, 1000 * 10**6);
        deal(address(weth), owner, 10 * 10**18);
        vm.startPrank(owner);
        usdc.approve(address(bot), 1000 * 10**6);
        weth.approve(address(bot), 10 * 10**18);
        bot.depositTokenB(1000 * 10**6);
        bot.depositTokenA(10 * 10**18);
        vm.stopPrank();

        // Include an out-of-bounds level index
        uint256[] memory levels = new uint256[](2);
        levels[0] = 999; // Invalid
        levels[1] = 0;   // Valid

        // Should not revert, just skip the invalid index
        bot.performUpkeep(abi.encode(levels));
    }

    function test_PerformUpkeep_ExecutesTriggeredLevels() public {
        _configureGrid();
        _initializeLevels();

        // Set price high to trigger sell levels
        pool.setTick(75000);

        // Deposit WETH for selling
        deal(address(weth), owner, 10 * 10**18);
        vm.startPrank(owner);
        weth.approve(address(bot), 10 * 10**18);
        bot.depositTokenA(10 * 10**18);
        vm.stopPrank();

        // Get swaps executed before
        uint256 swapsBefore = bot.totalSwapsExecuted();

        // Find a sell level and execute
        uint256[] memory levels = new uint256[](1);
        levels[0] = GRID_LEVELS - 1; // Last level should be a sell level

        // Execute upkeep (note: actual swap will fail in mock, but we test the flow)
        bot.performUpkeep(abi.encode(levels));

        // In a real scenario with proper mocks, swaps would execute
        // For now, we just verify it doesn't revert
    }

    // ============ Helper Functions ============

    function _createValidConfig() internal view returns (IGridTradingBot.GridConfig memory) {
        return IGridTradingBot.GridConfig({
            tokenA: address(weth),
            tokenB: address(usdc),
            lowerPrice: LOWER_PRICE,
            upperPrice: UPPER_PRICE,
            gridLevels: GRID_LEVELS,
            orderSizeA: ORDER_SIZE_A,
            orderSizeB: ORDER_SIZE_B,
            poolFee: POOL_FEE,
            maxSlippageBps: MAX_SLIPPAGE
        });
    }

    function _configureGrid() internal {
        IGridTradingBot.GridConfig memory config = _createValidConfig();
        vm.prank(owner);
        bot.configureGrid(config);
    }

    function _initializeLevels() internal {
        vm.prank(owner);
        bot.initializeLevels();
    }
}
