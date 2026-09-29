// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
struct Asset {
    address priceFeed;
    uint16 discountBps;
    uint32 maxAge;
    uint256 maxExposure;
    uint256 exposure;
}
struct SettleNativeAtomicProviderStorageData {
    mapping(address => Asset) assets;
    address pauser;
    bool paused;
    address stableFeed;
    uint16 stableMaxDeviationBps;
    uint32 stableMaxAge;
    address morphoAdapterFactory;
}
library SettleNativeAtomicProviderStorageV1 {
    // keccak256("RedStone.Oev.SettleNativeAtomicProvider.Storage.V1")
    bytes32 private constant STORAGE_LOCATION = 0x456244fe874a97345aefb2ad39ebbde23aa4a21c4fa3b1f7d5cf5a3bfa163fcb;
    function load() internal pure returns (SettleNativeAtomicProviderStorageData storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
