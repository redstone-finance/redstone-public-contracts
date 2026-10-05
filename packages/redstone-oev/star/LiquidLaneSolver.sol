// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {STAR, ISolverCallback} from "./STAR.sol";
interface ILiquidLaneAdapter {
    struct Swap {
        address recipient;
        address tokenIn;
        uint256 amountIn;
        uint256 amountOut;
    }
    function swap(Swap calldata swap) external;
    function vault() external view returns (address);
    function marketMaker() external view returns (address);
    function isFiller(address marketMaker, address filler) external view returns (bool);
    function minDiscount(address tokenIn) external view returns (uint256 ppm);
    function getAmountOut(address tokenIn, uint256 amountIn) external view returns (uint256);
    function getMaxAssets(address tokenIn) external returns (uint256);
}
struct LiquidLaneSolverStorageData {
    address settlement;
    EnumerableSet.AddressSet adapters;
    mapping(address => bool) isOperator;
}
library LiquidLaneSolverStorageV1 {
    bytes32 private constant STORAGE_LOCATION = 0x6840f9d852040a8ae84c9ef1f9dd64f91da7aa53cd2b45a49d7fa33698e6d515;
    function load() internal pure returns (LiquidLaneSolverStorageData storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
contract LiquidLaneSolver is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, PausableUpgradeable,
    ISolverCallback {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    uint256 private constant DISCOUNT_PRECISION = 1e6;
    event OperatorSet(address indexed operator, bool allowed);
    event AdapterSet(address indexed adapter, bool allowed);
    event Filled(bytes32 indexed orderId, address indexed adapter, address indexed sellToken, uint256 sellSlice,
        uint256 received, uint256 margin);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    error ZeroAddress();
    error NotOperator();
    error NotSettlement();
    error UnknownAdapter();
    error WrongBuyToken();
    error VenueShort(uint256 offered, uint256 owed);
    error VenuePaidShort(uint256 received, uint256 owed);
    error NoRenounce();
    constructor() {
        _disableInitializers();
    }
    function initialize(address owner_, address settlement_) external initializer {
        if (settlement_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __Pausable_init();
        _getStorage().settlement = settlement_;
    }
    function settlement() public view returns (address) {
        return _getStorage().settlement;
    }
    function adapters() external view returns (address[] memory) {
        return _getStorage().adapters.values();
    }
    function isAdapter(address adapter) public view returns (bool) {
        return _getStorage().adapters.contains(adapter);
    }
    function isOperator(address account) external view returns (bool) {
        return _getStorage().isOperator[account];
    }
    function asset(address adapter) public view returns (address) {
        return IERC4626(ILiquidLaneAdapter(adapter).vault()).asset();
    }
    function quote(address adapter, address token, uint256 amountIn) public view returns (uint256) {
        if (!isAdapter(adapter)) return 0;
        ILiquidLaneAdapter a = ILiquidLaneAdapter(adapter);
        if (!a.isFiller(a.marketMaker(), address(this))) return 0;
        try a.getAmountOut(token, amountIn) returns (uint256 gross) {
            return (gross * (DISCOUNT_PRECISION - a.minDiscount(token))) / DISCOUNT_PRECISION;
        } catch {
            return 0;
        }
    }
    function capacity(address adapter, address token, uint256 oneUnit) external returns (uint256) {
        uint256 perUnit = quote(adapter, token, oneUnit);
        if (perUnit == 0) return 0;
        try ILiquidLaneAdapter(adapter).getMaxAssets(token) returns (uint256 maxAssets) {
            return (maxAssets * oneUnit) / perUnit;
        } catch {
            return 0;
        }
    }
    function fill(STAR.SignedOrder calldata s, STAR.SignedAssignment calldata m, STAR.Execution calldata x)
        external whenNotPaused {
        LiquidLaneSolverStorageData storage $ = _getStorage();
        if (!$.isOperator[msg.sender]) revert NotOperator();
        if (!$.adapters.contains(x.sellRecipient)) revert UnknownAdapter();
        STAR($.settlement).settle(s, m, x);
    }
    function onSettle(SettleContext calldata ctx, bytes calldata) external override {
        LiquidLaneSolverStorageData storage $ = _getStorage();
        if (msg.sender != $.settlement) revert NotSettlement();
        address adapter = ctx.sellRecipient;
        if (!$.adapters.contains(adapter)) revert UnknownAdapter();
        IERC20 stable = IERC20(asset(adapter));
        if (ctx.buyToken != address(stable)) revert WrongBuyToken();
        uint256 owed = ctx.buySlice + ctx.feeSlice;
        uint256 amountOut = quote(adapter, ctx.sellToken, ctx.sellSlice);
        if (amountOut < owed) revert VenueShort(amountOut, owed);
        uint256 before = stable.balanceOf(address(this));
        ILiquidLaneAdapter(adapter).swap(ILiquidLaneAdapter.Swap({
            recipient: address(this), tokenIn: ctx.sellToken, amountIn: ctx.sellSlice, amountOut: amountOut
        }));
        uint256 received = stable.balanceOf(address(this)) - before;
        if (received < owed) revert VenuePaidShort(received, owed);
        stable.safeTransfer(ctx.receiver, ctx.buySlice);
        stable.safeTransfer(ctx.feeCollector, ctx.feeSlice);
        emit Filled(ctx.orderId, adapter, ctx.sellToken, ctx.sellSlice, received, received - owed);
    }
    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        _getStorage().isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }
    function setAdapter(address adapter, bool allowed) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        LiquidLaneSolverStorageData storage $ = _getStorage();
        if (allowed) $.adapters.add(adapter);
        else $.adapters.remove(adapter);
        emit AdapterSet(adapter, allowed);
    }
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }
    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }
    function renounceOwnership() public pure override {
        revert NoRenounce();
    }
    function _authorizeUpgrade(address) internal view override onlyOwner {}
    function _getStorage() private pure returns (LiquidLaneSolverStorageData storage) {
        return LiquidLaneSolverStorageV1.load();
    }
}
