// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {IMultiFeedAdapter} from "../interfaces/IMultiFeedAdapter.sol";
import {PriceFeedWithoutRoundsForMultiFeedAdapter} from "./PriceFeedWithoutRoundsForMultiFeedAdapter.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Reports first * second / 1e8 (all 8 decimals) with the newer of the two timestamps.
abstract contract MultipliedPriceFeedWithoutRoundsForMultiFeedAdapter is PriceFeedWithoutRoundsForMultiFeedAdapter {
  function getFirstDataFeedId() public view virtual returns (bytes32);
  function getSecondDataFeedId() public view virtual returns (bytes32);

  function latestAnswer() public view virtual override returns (int256) {
    IMultiFeedAdapter adapter = IMultiFeedAdapter(address(getPriceFeedAdapter()));
    return _calculateAnswer(adapter.getValueForDataFeed(getFirstDataFeedId()), adapter.getValueForDataFeed(getSecondDataFeedId()));
  }

  function latestRoundData() public view virtual override returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
    IMultiFeedAdapter adapter = IMultiFeedAdapter(address(getPriceFeedAdapter()));
    (, uint256 firstTimestamp, uint256 firstValue) = adapter.getLastUpdateDetails(getFirstDataFeedId());
    (, uint256 secondTimestamp, uint256 secondValue) = adapter.getLastUpdateDetails(getSecondDataFeedId());
    roundId = answeredInRound = latestRound();
    answer = _calculateAnswer(firstValue, secondValue);
    // Answer changes on either feed's update, so the newer timestamp is its last change
    startedAt = updatedAt = Math.max(firstTimestamp, secondTimestamp);
  }

  function _calculateAnswer(uint256 a, uint256 b) internal pure returns (int256) {
    return SafeCast.toInt256(Math.mulDiv(a, b, 1e8));
  }
}
