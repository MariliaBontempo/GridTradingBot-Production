// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUniswapV3PoolMinimal
/// @notice Minimal interface for Uniswap V3 Pool needed for TWAP
interface IUniswapV3PoolMinimal {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

/// @title TWAPLib
/// @notice Library for calculating Time-Weighted Average Price from Uniswap V3 pools
/// @dev Uses pool.observe() to get historical tick data for TWAP calculation
library TWAPLib {
    /// @notice Min tick value from Uniswap V3
    int24 internal constant MIN_TICK = -887272;
    /// @notice Max tick value from Uniswap V3
    int24 internal constant MAX_TICK = 887272;

    /// @notice Calculates the TWAP price over a specified period
    /// @param pool The Uniswap V3 pool address
    /// @param twapInterval The time interval in seconds for TWAP calculation
    /// @param token0Decimals Decimals of token0
    /// @param token1Decimals Decimals of token1
    /// @param baseIsToken0 Whether the base token (tokenA) is token0 in the pool
    /// @return price The TWAP price scaled by 1e18 (quote per base)
    function getTWAPPrice(
        address pool,
        uint32 twapInterval,
        uint8 token0Decimals,
        uint8 token1Decimals,
        bool baseIsToken0
    ) internal view returns (uint256 price) {
        require(twapInterval > 0, "TWAP interval must be > 0");

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapInterval; // From twapInterval seconds ago
        secondsAgos[1] = 0; // To now

        // Get cumulative tick values at both timestamps
        (int56[] memory tickCumulatives,) = IUniswapV3PoolMinimal(pool).observe(secondsAgos);

        // Calculate the average tick over the interval
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(twapInterval)));

        // Always round to negative infinity for consistency
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(twapInterval)) != 0)) {
            arithmeticMeanTick--;
        }

        // Convert tick to sqrtPriceX96 using our implementation
        uint160 sqrtPriceX96 = getSqrtRatioAtTick(arithmeticMeanTick);

        // Convert sqrtPriceX96 to actual price
        price = _sqrtPriceX96ToPrice(sqrtPriceX96, token0Decimals, token1Decimals, baseIsToken0);
    }

    /// @notice Calculates sqrt(1.0001^tick) * 2^96
    /// @dev Attempt at a Solidity 0.8.x compatible implementation
    /// @param tick The tick for which to compute the sqrt ratio
    /// @return sqrtPriceX96 The sqrt ratio as a Q64.96 value
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            require(absTick <= uint256(int256(MAX_TICK)), "T");

            // Use precomputed values for powers of sqrt(1.0001)
            uint256 ratio = absTick & 0x1 != 0
                ? 0xfffcb933bd6fad37aa2d162d1a594001
                : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;

            // Downcast to uint160 with rounding up in the division
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    /// @notice Converts sqrtPriceX96 to a human-readable price scaled by 1e18
    /// @param sqrtPriceX96 The sqrt price from Uniswap V3
    /// @param token0Decimals Decimals of token0
    /// @param token1Decimals Decimals of token1
    /// @param baseIsToken0 Whether we want price in terms of token1/token0
    /// @return price Price scaled by 1e18
    function _sqrtPriceX96ToPrice(
        uint160 sqrtPriceX96,
        uint8 token0Decimals,
        uint8 token1Decimals,
        bool baseIsToken0
    ) internal pure returns (uint256 price) {
        // sqrtPriceX96 = sqrt(token1/token0) * 2^96
        // price (token1/token0) = (sqrtPriceX96 / 2^96)^2

        uint256 sqrtPrice = uint256(sqrtPriceX96);

        if (baseIsToken0) {
            // Price = token1 per token0 (e.g., USDC per WETH)
            uint256 numerator;
            uint256 denominator;

            if (sqrtPrice >= 2 ** 128) {
                numerator = (sqrtPrice >> 64) * (sqrtPrice >> 64);
                denominator = 2 ** 64;
            } else if (sqrtPrice >= 2 ** 64) {
                numerator = (sqrtPrice >> 32) * (sqrtPrice >> 32);
                denominator = 2 ** 128;
            } else {
                numerator = sqrtPrice * sqrtPrice;
                denominator = 2 ** 192;
            }

            // Apply decimal adjustment and 1e18 scaling
            uint256 decimalAdjustment;
            if (token0Decimals >= token1Decimals) {
                decimalAdjustment = 10 ** (token0Decimals - token1Decimals);
                price = (numerator * 1e18 * decimalAdjustment) / denominator;
            } else {
                decimalAdjustment = 10 ** (token1Decimals - token0Decimals);
                price = (numerator * 1e18) / (denominator * decimalAdjustment);
            }
        } else {
            // Price = token0 per token1 (inverse)
            uint256 numerator;
            uint256 denominator;

            if (sqrtPrice >= 2 ** 128) {
                numerator = (sqrtPrice >> 64) * (sqrtPrice >> 64);
                denominator = 2 ** 64;
            } else if (sqrtPrice >= 2 ** 64) {
                numerator = (sqrtPrice >> 32) * (sqrtPrice >> 32);
                denominator = 2 ** 128;
            } else {
                numerator = sqrtPrice * sqrtPrice;
                denominator = 2 ** 192;
            }

            // For inverse: price = denominator / numerator (with proper scaling)
            uint256 decimalAdjustment;
            if (token1Decimals >= token0Decimals) {
                decimalAdjustment = 10 ** (token1Decimals - token0Decimals);
                price = (denominator * 1e18 * decimalAdjustment) / numerator;
            } else {
                decimalAdjustment = 10 ** (token0Decimals - token1Decimals);
                price = (denominator * 1e18) / (numerator * decimalAdjustment);
            }
        }
    }

    /// @notice Gets the spot price from the pool (current tick)
    /// @param pool The Uniswap V3 pool address
    /// @param token0Decimals Decimals of token0
    /// @param token1Decimals Decimals of token1
    /// @param baseIsToken0 Whether the base token is token0
    /// @return price The spot price scaled by 1e18
    function getSpotPrice(
        address pool,
        uint8 token0Decimals,
        uint8 token1Decimals,
        bool baseIsToken0
    ) internal view returns (uint256 price) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
        price = _sqrtPriceX96ToPrice(sqrtPriceX96, token0Decimals, token1Decimals, baseIsToken0);
    }
}
