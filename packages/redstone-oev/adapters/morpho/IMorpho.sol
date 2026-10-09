// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct Authorization {
    address authorizer;
    address authorized;
    bool isAuthorized;
    uint256 nonce;
    uint256 deadline;
}

struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

interface IMorpho {
    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
    function isAuthorized(address authorizer, address authorized) external view returns (bool);
    function setAuthorizationWithSig(Authorization calldata authorization, Signature calldata signature) external;
    function repay(MarketParams calldata marketParams, uint256 assets, uint256 shares, address onBehalf, bytes calldata data)
        external
        returns (uint256 assetsRepaid, uint256 sharesRepaid);
    function withdrawCollateral(MarketParams calldata marketParams, uint256 assets, address onBehalf, address receiver)
        external;
    function liquidate(
        MarketParams calldata marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256 seizedAssetsOut, uint256 repaidAssets);
}
