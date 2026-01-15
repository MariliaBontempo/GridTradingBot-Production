// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockUniswapV3Pool
/// @notice A mock Uniswap V3 Pool for testing TWAP functionality
contract MockUniswapV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;

    // Slot0 data
    uint160 public sqrtPriceX96;
    int24 public tick;

    // Observation data for TWAP
    int56 public tickCumulative0;
    int56 public tickCumulative1;

    constructor(address _token0, address _token1, uint24 _fee) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        // Default price around 2000 (for WETH/USDC)
        // tick ~= 74000 for price around 2000
        tick = 74000;
        sqrtPriceX96 = 3543191142285914378072637291053; // ~2000 price
    }

    /// @notice Set the current tick (for testing different prices)
    function setTick(int24 _tick) external {
        tick = _tick;
        // Update sqrtPriceX96 based on tick (simplified)
        // sqrtPriceX96 = sqrt(1.0001^tick) * 2^96
        sqrtPriceX96 = _tickToSqrtPrice(_tick);
    }

    /// @notice Set tick cumulatives for TWAP testing
    function setTickCumulatives(int56 _tickCumulative0, int56 _tickCumulative1) external {
        tickCumulative0 = _tickCumulative0;
        tickCumulative1 = _tickCumulative1;
    }

    /// @notice Set sqrtPriceX96 directly
    function setSqrtPriceX96(uint160 _sqrtPriceX96) external {
        sqrtPriceX96 = _sqrtPriceX96;
    }

    /// @notice Returns slot0 data
    function slot0()
        external
        view
        returns (
            uint160 _sqrtPriceX96,
            int24 _tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (sqrtPriceX96, tick, 0, 1, 1, 0, true);
    }

    /// @notice Returns tick cumulative data for TWAP calculation
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);

        for (uint256 i = 0; i < secondsAgos.length; i++) {
            if (secondsAgos[i] == 0) {
                tickCumulatives[i] = tickCumulative1;
            } else {
                tickCumulatives[i] = tickCumulative0;
            }
            secondsPerLiquidityCumulativeX128s[i] = 0;
        }

        return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
    }

    /// @notice Helper to convert tick to sqrtPriceX96 (simplified)
    function _tickToSqrtPrice(int24 _tick) internal pure returns (uint160) {
        // Simplified calculation - in reality this uses TickMath library
        // For testing purposes, we use approximate values
        if (_tick == 74000) {
            return 3543191142285914378072637291053; // ~2000
        } else if (_tick == 73000) {
            return 3345771302781712856988949988352; // ~1800
        } else if (_tick == 75000) {
            return 3749320589658090000000000000000; // ~2200
        } else if (_tick == 74500) {
            return 3645000000000000000000000000000; // ~2100
        } else if (_tick == 73500) {
            return 3445000000000000000000000000000; // ~1900
        }
        // Default fallback
        return 3543191142285914378072637291053;
    }
}
