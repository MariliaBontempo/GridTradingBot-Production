// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";
import { GridTradingBot } from "../src/GridTradingBot.sol";
import { IGridTradingBot } from "../src/interfaces/IGridTradingBot.sol";

/// @title DeployScript
/// @notice Deploys the GridTradingBot contract
contract DeployScript is Script {
    // Arbitrum Mainnet addresses
    address constant ARBITRUM_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant ARBITRUM_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    // Arbitrum Sepolia addresses
    address constant ARBITRUM_SEPOLIA_SWAP_ROUTER = 0x101F443B4d1b059569D643917553c771E1b9663E;
    address constant ARBITRUM_SEPOLIA_FACTORY = 0x248AB79Bbb9bC29bB72f7Cd42F17e054Fc40188e;

    function run() external {
        // Get chain ID to determine network
        uint256 chainId = block.chainid;

        address swapRouter;
        address factory;

        if (chainId == 42161) {
            // Arbitrum Mainnet
            swapRouter = ARBITRUM_SWAP_ROUTER;
            factory = ARBITRUM_FACTORY;
            console.log("Deploying to Arbitrum Mainnet");
        } else if (chainId == 421614) {
            // Arbitrum Sepolia
            swapRouter = ARBITRUM_SEPOLIA_SWAP_ROUTER;
            factory = ARBITRUM_SEPOLIA_FACTORY;
            console.log("Deploying to Arbitrum Sepolia");
        } else {
            revert("Unsupported chain ID");
        }

        // SECURITY: Validate addresses are not zero
        require(swapRouter != address(0), "Invalid swap router address");
        require(factory != address(0), "Invalid factory address");

        console.log("SwapRouter:", swapRouter);
        console.log("Factory:", factory);

        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // SECURITY: Validate private key is set
        require(deployerPrivateKey != 0, "PRIVATE_KEY not set in environment");
        
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        // Start broadcast
        vm.startBroadcast(deployerPrivateKey);

        // Deploy GridTradingBot
        GridTradingBot bot = new GridTradingBot(swapRouter, factory);

        console.log("GridTradingBot deployed at:", address(bot));
        console.log("Owner:", bot.owner());

        vm.stopBroadcast();

        // Log summary
        console.log("\n=== Deployment Summary ===");
        console.log("Chain ID:", chainId);
        console.log("Contract:", address(bot));
        console.log("Owner:", bot.owner());
    }
}

/// @title ConfigureScript
/// @notice Configures an existing GridTradingBot deployment
contract ConfigureScript is Script {
    // Arbitrum token addresses
    address constant ARBITRUM_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // Arbitrum Sepolia token addresses
    address constant ARBITRUM_SEPOLIA_WETH = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
    address constant ARBITRUM_SEPOLIA_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

    function run() external {
        // Get bot address from environment
        address botAddress = vm.envAddress("BOT_ADDRESS");
        
        // SECURITY: Validate bot address is set
        require(botAddress != address(0), "BOT_ADDRESS not set in environment");
        
        GridTradingBot bot = GridTradingBot(botAddress);

        console.log("Configuring bot at:", botAddress);

        // Get chain ID to determine network
        uint256 chainId = block.chainid;

        address weth;
        address usdc;

        if (chainId == 42161) {
            weth = ARBITRUM_WETH;
            usdc = ARBITRUM_USDC;
        } else if (chainId == 421614) {
            weth = ARBITRUM_SEPOLIA_WETH;
            usdc = ARBITRUM_SEPOLIA_USDC;
        } else {
            revert("Unsupported chain ID");
        }

        // SECURITY: Validate token addresses
        require(weth != address(0), "Invalid WETH address");
        require(usdc != address(0), "Invalid USDC address");

        // Default configuration
        IGridTradingBot.GridConfig memory config = IGridTradingBot.GridConfig({
            tokenA: weth,
            tokenB: usdc,
            lowerPrice: 1800 * 1e18, // 1800 USDC per WETH
            upperPrice: 2200 * 1e18, // 2200 USDC per WETH
            gridLevels: 10,
            orderSizeA: 0.1 ether, // 0.1 WETH
            orderSizeB: 200 * 1e6, // 200 USDC
            poolFee: 3000, // 0.3%
            maxSlippageBps: 50 // 0.5%
        });

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // SECURITY: Validate private key is set
        require(deployerPrivateKey != 0, "PRIVATE_KEY not set in environment");

        vm.startBroadcast(deployerPrivateKey);

        // Configure grid
        bot.configureGrid(config);
        console.log("Grid configured");

        // Initialize levels
        bot.initializeLevels();
        console.log("Levels initialized");

        vm.stopBroadcast();

        console.log("\n=== Configuration Summary ===");
        console.log("Token A (WETH):", weth);
        console.log("Token B (USDC):", usdc);
        console.log("Lower Price: 1800 USDC/WETH");
        console.log("Upper Price: 2200 USDC/WETH");
        console.log("Grid Levels:", config.gridLevels);
    }
}
