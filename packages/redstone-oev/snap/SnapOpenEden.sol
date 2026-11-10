// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {RedeemingSnap} from "./RedeemingSnap.sol";
interface IOpenEdenVault {
    function redeem(uint256 shares, address receiver) external;
    function getWithdrawalUserInfo(address user) external view returns (uint256 shares);
}
struct SnapOpenEdenStorageData {
    mapping(address => uint256) queued;
}
library SnapOpenEdenStorageV1 {
    // keccak256("RedStone.Oev.SnapOpenEden.Storage.V1")
    bytes32 private constant STORAGE_LOCATION = 0x08cc76ff397a76db05bc708ea53982c2bab6b36ec67e51a153d81e46cf67d5cb;
    function load() internal pure returns (SnapOpenEdenStorageData storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
contract SnapOpenEden is RedeemingSnap {
    event OpenEdenRedeemRequested(address indexed rwa, uint256 amount);
    event OpenEdenRedemptionBooked(address indexed rwa, uint256 redeemed, uint256 returned, uint256 stableDeposited);
    event OpenEdenQueuedLowered(address indexed rwa, uint256 amount);
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IERC4626 _vault, address _redeemer, address _sanctionsList)
        RedeemingSnap(_vault, _redeemer, _sanctionsList)
    {}
    function queued(address rwa) external view returns (uint256) {
        return _getOpenEdenStorage().queued[rwa];
    }
    function redeemAtOpenEden(address rwa, uint256 amount) external onlyRedeemer nonReentrant {
        require(amount > 0, "ZERO_AMOUNT");
        mapping(address => uint256) storage accounted_ = _getStorage().accounted;
        require(amount <= accounted_[rwa], "EXCEEDS_ACCOUNTED");
        IOpenEdenVault tbill = IOpenEdenVault(rwa);
        uint256 before = tbill.getWithdrawalUserInfo(address(this));
        tbill.redeem(amount, address(this));
        require(tbill.getWithdrawalUserInfo(address(this)) == before + amount, "NOT_QUEUED");
        _getOpenEdenStorage().queued[rwa] += amount;
        accounted_[rwa] -= amount;
        emit OpenEdenRedeemRequested(rwa, amount);
    }
    function bookOpenEdenRedemption(address rwa) external onlyRedeemer nonReentrant {
        SnapOpenEdenStorageData storage o = _getOpenEdenStorage();
        uint256 pending = IOpenEdenVault(rwa).getWithdrawalUserInfo(address(this));
        uint256 queued_ = o.queued[rwa];
        mapping(address => uint256) storage accounted_ = _getStorage().accounted;
        uint256 balance = IERC20(rwa).balanceOf(address(this));
        uint256 unaccounted = balance > accounted_[rwa] ? balance - accounted_[rwa] : 0;
        uint256 returned = unaccounted < queued_ ? unaccounted : queued_;
        uint256 rest = queued_ - returned;
        uint256 redeemed = rest > pending ? rest - pending : 0;
        require(returned + redeemed > 0, "NOT_PROCESSED");
        o.queued[rwa] = rest - redeemed;
        if (returned > 0) accounted_[rwa] += returned;
        if (redeemed > 0) _lowerExposure(rwa, redeemed);
        emit OpenEdenRedemptionBooked(rwa, redeemed, returned, _depositHeld());
    }
    function depositHeld() external onlyRedeemer nonReentrant {
        require(_depositHeld() > 0, "NOTHING_HELD");
    }
    function lowerQueued(address rwa, uint256 amount) external onlyOwner {
        SnapOpenEdenStorageData storage o = _getOpenEdenStorage();
        require(amount > 0 && amount <= o.queued[rwa], "EXCEEDS_QUEUED");
        o.queued[rwa] -= amount;
        emit OpenEdenQueuedLowered(rwa, amount);
    }
    function _getOpenEdenStorage() private pure returns (SnapOpenEdenStorageData storage) {
        return SnapOpenEdenStorageV1.load();
    }
}
