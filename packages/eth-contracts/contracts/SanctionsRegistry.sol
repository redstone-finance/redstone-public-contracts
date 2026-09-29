// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./ISanctionsRegistry.sol";

/// @title On-Chain Sanctions List
/// @dev Inspired by and continuing the Chainalysis sanctions oracle at 0x40C57923924B5c5c5455c48D93317139ADDaC8fb.
abstract contract SanctionsRegistry is Initializable, ISanctionsRegistry {
  bytes32 private constant SANCTIONS_REGISTRY_STORAGE_LOCATION =
    0xab36462e12e911bd16bf7ca83c9da382ecf08907e54efd6ecb0dd5a94066ba25; // keccak256("RedStone.SanctionsRegistry.storage")

  bytes32 private constant LAST_UPDATE_BLOCK_TIMESTAMP_STORAGE_LOCATION =
    0xdda23943c93ee6908a02c9d9799a0744663ddb061f2c8196b2d73478502becea; // keccak256("RedStone.SanctionsRegistry.lastUpdateBlockTimestamp")

  struct SanctionsRegistryStorage {
    mapping(address => bool) sanctionedAddresses;
  }

  event AddressesSetAsSanctioned(address[] addrs);
  event AddressesUnsetAsSanctioned(address[] addrs);

  error OnlyAdminCanUpdateSanctions();

  function initialize() public initializer {}

  function setAsSanctioned(address[] calldata newSanctions) public onlyAdmin {
    SanctionsRegistryStorage storage $ = _getSanctionsRegistryStorage();
    for (uint256 i = 0; i < newSanctions.length; i++) {
      $.sanctionedAddresses[newSanctions[i]] = true;
    }
    _updateLastUpdateTimestamp();
    emit AddressesSetAsSanctioned(newSanctions);
  }

  function unsetAsSanctioned(address[] calldata removeSanctions) public onlyAdmin {
    SanctionsRegistryStorage storage $ = _getSanctionsRegistryStorage();
    for (uint256 i = 0; i < removeSanctions.length; i++) {
      $.sanctionedAddresses[removeSanctions[i]] = false;
    }
    _updateLastUpdateTimestamp();
    emit AddressesUnsetAsSanctioned(removeSanctions);
  }

  function isSanctioned(address addr) public view returns (bool) {
    return _getSanctionsRegistryStorage().sanctionedAddresses[addr];
  }

  function areSanctioned(address[] calldata addrs) public view returns (bool[] memory result) {
    SanctionsRegistryStorage storage $ = _getSanctionsRegistryStorage();
    result = new bool[](addrs.length);
    for (uint256 i = 0; i < addrs.length; i++) {
      result[i] = $.sanctionedAddresses[addrs[i]];
    }
  }

  function getLastUpdateBlockTimestamp() public view returns (uint256 result) {
    assembly {
      result := sload(LAST_UPDATE_BLOCK_TIMESTAMP_STORAGE_LOCATION)
    }
  }

  function _updateLastUpdateTimestamp() private {
    assembly {
      sstore(LAST_UPDATE_BLOCK_TIMESTAMP_STORAGE_LOCATION, timestamp())
    }
  }

  /// @dev We don't store admin in storage. To change the admin the contract should be upgraded
  function isAdmin(address addr) public view virtual returns (bool);

  function description() external pure returns (string memory) {
    return "On-chain sanctions list, synced with OFAC and opensanctions.org data. Provided best-effort, \"AS IS\", with no warranty.";
  }

  function _getSanctionsRegistryStorage() private pure returns (SanctionsRegistryStorage storage $) {
    assembly {
      $.slot := SANCTIONS_REGISTRY_STORAGE_LOCATION
    }
  }

  modifier onlyAdmin() {
    if (!isAdmin(msg.sender)) {
      revert OnlyAdminCanUpdateSanctions();
    }
    _;
  }
}
