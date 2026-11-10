// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Asset} from "./SettleNativeAtomicProviderStorageV1.sol";
import {SettleNativeAtomicProvider} from "./SettleNativeAtomicProvider.sol";
interface ISanctionsList {
    function isSanctioned(address account) external view returns (bool);
}
abstract contract RedeemingSnap is SettleNativeAtomicProvider {
    using SafeERC20 for IERC20;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable redeemer;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable sanctionsList;
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IERC4626 _vault, address _redeemer, address _sanctionsList) SettleNativeAtomicProvider(_vault) {
        redeemer = _redeemer;
        sanctionsList = _sanctionsList;
    }
    modifier onlyRedeemer() {
        require(msg.sender == redeemer || msg.sender == owner(), "NOT_REDEEMER");
        _;
    }
    function sell(address rwa, uint256 amountIn, uint256 minOut)
        external
        nonReentrant
        whenOpen
        returns (uint256 amountOut)
    {
        address list = sanctionsList;
        if (list != address(0)) {
            require(!ISanctionsList(list).isSanctioned(msg.sender), "SANCTIONED");
            if (tx.origin != msg.sender) require(!ISanctionsList(list).isSanctioned(tx.origin), "SANCTIONED");
        }
        require(_getStorage().assets[rwa].priceFeed != address(0), "NOT_ACCEPTED");
        uint256 before = IERC20(rwa).balanceOf(address(this));
        IERC20(rwa).safeTransferFrom(msg.sender, address(this), amountIn);
        require(IERC20(rwa).balanceOf(address(this)) >= before + amountIn, "NOT_RECEIVED");
        return _sell(rwa, amountIn, minOut);
    }
    function _lowerExposure(address rwa, uint256 amount) internal {
        Asset storage a = _getStorage().assets[rwa];
        require(a.exposure >= amount, "EXCEEDS_EXPOSURE");
        a.exposure -= amount;
        emit ExposureReduced(rwa, amount);
    }
    function _depositHeld() internal returns (uint256 held) {
        held = stable.balanceOf(address(this));
        if (held > 0) {
            stable.forceApprove(address(vault), held);
            vault.deposit(held, address(this));
            emit VaultFunded(held);
        }
    }
}
