// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

/// @title Interface of the on-chain sanctions registry
/// @author The Redstone Oracles team
interface ISanctionsRegistry {
  /// @notice Whether the given address is currently sanctioned
  function isSanctioned(address addr) external view returns (bool);

  /// @notice Batched version of isSanctioned, preserving input order
  function areSanctioned(address[] calldata addrs) external view returns (bool[] memory result);

  /// @notice Timestamp of the block in which the sanctioned-addresses set was last updated.
  /// Zero if it was never updated.
  function getLastUpdateBlockTimestamp() external view returns (uint256 result);
}
