// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RedeemingSnap} from "./RedeemingSnap.sol";
interface IMidasRedemptionVault {
    function redeemRequest(address tokenOut, uint256 amountMTokenIn) external returns (uint256 requestId);
    function redeemRequests(uint256 requestId)
        external
        view
        returns (
            address sender,
            address tokenOut,
            uint8 status,
            uint256 amountMToken,
            uint256 mTokenRate,
            uint256 tokenOutRate
        );
}
struct SnapMidasStorageData {
    mapping(address => address) midasVault;
    mapping(address => mapping(address => mapping(uint256 => uint256))) filed;
}
library SnapMidasStorageV1 {
    // keccak256("RedStone.Oev.SnapMidas.Storage.V1")
    bytes32 private constant STORAGE_LOCATION = 0x4773d88d0817677577f754ae95f15a85db5e002682c0c070bc0b3cbb8769ab45;
    function load() internal pure returns (SnapMidasStorageData storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
contract SnapMidas is RedeemingSnap {
    using SafeERC20 for IERC20;
    uint8 private constant MIDAS_PROCESSED = 1;
    uint8 private constant MIDAS_CANCELED = 2;
    event MidasVaultSet(address indexed rwa, address indexed redemptionVault);
    event MidasRedeemRequested(
        address indexed rwa, address indexed redemptionVault, uint256 indexed requestId, uint256 amount
    );
    event MidasRedemptionBooked(address indexed rwa, uint256 indexed requestId, uint256 amount, uint256 stableDeposited);
    event ReturnedAccounted(address indexed rwa, uint256 amount);
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IERC4626 _vault, address _redeemer, address _sanctionsList)
        RedeemingSnap(_vault, _redeemer, _sanctionsList)
    {}
    function midasVault(address rwa) external view returns (address) {
        return _getMidasStorage().midasVault[rwa];
    }
    function filed(address rwa, address redemptionVault, uint256 requestId) external view returns (uint256) {
        return _getMidasStorage().filed[rwa][redemptionVault][requestId];
    }
    function setMidasVault(address rwa, address redemptionVault) external onlyOwner {
        _getMidasStorage().midasVault[rwa] = redemptionVault;
        emit MidasVaultSet(rwa, redemptionVault);
    }
    function redeemAtMidas(address rwa, uint256 amount) external onlyRedeemer nonReentrant returns (uint256 requestId) {
        SnapMidasStorageData storage m = _getMidasStorage();
        address redemptionVault = m.midasVault[rwa];
        require(redemptionVault != address(0), "NO_MIDAS_VAULT");
        require(amount > 0, "ZERO_AMOUNT");
        mapping(address => uint256) storage accounted_ = _getStorage().accounted;
        require(amount <= accounted_[rwa], "EXCEEDS_ACCOUNTED");
        IERC20(rwa).forceApprove(redemptionVault, amount);
        requestId = IMidasRedemptionVault(redemptionVault).redeemRequest(address(stable), amount);
        (address sender, address tokenOut,,,,) = IMidasRedemptionVault(redemptionVault).redeemRequests(requestId);
        require(sender == address(this) && tokenOut == address(stable), "NOT_RECORDED");
        require(m.filed[rwa][redemptionVault][requestId] == 0, "ALREADY_FILED");
        m.filed[rwa][redemptionVault][requestId] = amount;
        accounted_[rwa] -= amount;
        emit MidasRedeemRequested(rwa, redemptionVault, requestId, amount);
    }
    function bookMidasRedemption(address rwa, address redemptionVault, uint256 requestId)
        external
        onlyRedeemer
        nonReentrant
    {
        mapping(uint256 => uint256) storage filed_ = _getMidasStorage().filed[rwa][redemptionVault];
        uint256 amount = filed_[requestId];
        require(amount > 0, "NOT_FILED");
        (,, uint8 status,,,) = IMidasRedemptionVault(redemptionVault).redeemRequests(requestId);
        require(status == MIDAS_PROCESSED, "NOT_PROCESSED");
        delete filed_[requestId];
        _lowerExposure(rwa, amount);
        emit MidasRedemptionBooked(rwa, requestId, amount, _depositHeld());
    }
    function accountReturned(address rwa, address redemptionVault, uint256 requestId, uint256 amount)
        external
        onlyRedeemer
    {
        mapping(uint256 => uint256) storage filed_ = _getMidasStorage().filed[rwa][redemptionVault];
        uint256 filedAmount = filed_[requestId];
        require(filedAmount > 0, "NOT_FILED");
        require(amount > 0 && amount <= filedAmount, "EXCEEDS_FILED");
        (,, uint8 status,,,) = IMidasRedemptionVault(redemptionVault).redeemRequests(requestId);
        require(status == MIDAS_CANCELED, "NOT_CANCELED");
        mapping(address => uint256) storage accounted_ = _getStorage().accounted;
        require(IERC20(rwa).balanceOf(address(this)) >= accounted_[rwa] + amount, "NOT_RECEIVED");
        filed_[requestId] = filedAmount - amount;
        accounted_[rwa] += amount;
        emit ReturnedAccounted(rwa, amount);
    }
    function writeOff(address rwa, address redemptionVault, uint256 requestId) external onlyOwner {
        mapping(uint256 => uint256) storage filed_ = _getMidasStorage().filed[rwa][redemptionVault];
        uint256 amount = filed_[requestId];
        require(amount > 0, "NOT_FILED");
        delete filed_[requestId];
        _lowerExposure(rwa, amount);
    }
    function _getMidasStorage() private pure returns (SnapMidasStorageData storage) {
        return SnapMidasStorageV1.load();
    }
}
