// SPDX-License-Identifier: MIT

// Oracle: wrapper minimo de Chainlink para ETH/USD usado por LendingPool.
// Claves: FEED (AggregatorV3), STALE_AFTER (segundos); normaliza el precio a 8 decimales y revierte si es stale o <= 0.
pragma solidity ^0.8.24;

/// @notice Minimal Chainlink oracle wrapper for ETH/USD.
/// @dev Returns price scaled to 8 decimals (Chainlink style), matching LendingPool's expectation.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

contract Oracle {
    error StalePrice();
    error InvalidPrice();

    IAggregatorV3 public immutable FEED;
    uint256 public immutable STALE_AFTER;

    constructor(address feed, uint256 staleAfterSeconds) {
        FEED = IAggregatorV3(feed);
        STALE_AFTER = staleAfterSeconds;
    }

    function getEthUsdPrice() external view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = FEED.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (STALE_AFTER != 0 && block.timestamp > updatedAt + STALE_AFTER)
            revert StalePrice();

        uint256 price = uint256(answer);
        uint8 feedDecimals = FEED.decimals();
        if (feedDecimals == 8) return price;
        if (feedDecimals > 8) return price / (10 ** (feedDecimals - 8));
        return price * (10 ** (8 - feedDecimals));
    }
}
