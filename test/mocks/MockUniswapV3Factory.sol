// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockUniswapV3Factory
/// @notice A mock Uniswap V3 Factory for testing
contract MockUniswapV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) public pools;

    /// @notice Set a pool address for a token pair and fee
    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        // Sort tokens
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pools[token0][token1][fee] = pool;
    }

    /// @notice Get the pool address for a token pair and fee
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return pools[token0][token1][fee];
    }
}
