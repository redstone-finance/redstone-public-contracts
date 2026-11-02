// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
struct PriceFeed {
    address feed;
    uint32 maxAge;
}
struct STARStorageData {
    mapping(bytes32 => uint256) filled;
    mapping(bytes32 => bool) cancelled;
    mapping(bytes32 => bool) assignmentUsed;
    mapping(address => bool) solverAllowed;
    mapping(address => PriceFeed) priceFeeds;
}
library STARStorageV1 {
    bytes32 private constant STORAGE_LOCATION = 0x1d1d17022c28d449884cbbce78341a7398459484b6a13f2090d92f54ddb36e93;
    function load() internal pure returns (STARStorageData storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
