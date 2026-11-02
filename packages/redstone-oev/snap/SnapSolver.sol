// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ISTAR, ISolverCallbackAbi} from "../adapters/fill/IFillSolver.sol";
interface ISnap {
    function stable() external view returns (address);
    function isFiller(address account) external view returns (bool);
    function quote(address rwa, uint256 amountIn) external view returns (uint256);
    function maxAmountIn(address rwa) external view returns (uint256);
    function sellReceived(address rwa, uint256 amountIn, uint256 minOut) external returns (uint256);
}
struct SnapSolverStorageData {
    address settlement;
    EnumerableSet.AddressSet snaps;
    mapping(address => bool) isOperator;
}
library SnapSolverStorageV1 {
    // keccak256("RedStone.Oev.SnapSolver.Storage.V1")
    bytes32 private constant STORAGE_LOCATION = 0x21b4fd944660486efd9604d2ba78399a606a10056ae0b458cf633554fe031058;
    function load() internal pure returns (SnapSolverStorageData storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
contract SnapSolver is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, PausableUpgradeable, ISolverCallbackAbi {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    event OperatorSet(address indexed operator, bool allowed);
    event SnapSet(address indexed snap, bool allowed);
    event Filled(
        bytes32 indexed orderId,
        address indexed snap,
        address indexed sellToken,
        uint256 sellSlice,
        uint256 received,
        uint256 margin
    );
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    error ZeroAddress();
    error NotOperator();
    error FlowOrder();
    error NotSettlement();
    error UnknownSnap();
    error WrongBuyToken();
    error VenuePaidShort(uint256 received, uint256 owed);
    error NoRenounce();
    /// @custom:oz-upgrades-unsafe-allow constructor
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
    function snaps() external view returns (address[] memory) {
        return _getStorage().snaps.values();
    }
    function isSnap(address snap) public view returns (bool) {
        return _getStorage().snaps.contains(snap);
    }
    function isOperator(address account) external view returns (bool) {
        return _getStorage().isOperator[account];
    }
    function quote(address snap, address token, uint256 amountIn) public view returns (uint256) {
        if (!isSnap(snap) || !ISnap(snap).isFiller(address(this))) return 0;
        try ISnap(snap).quote(token, amountIn) returns (uint256 amountOut) {
            return amountOut;
        } catch {
            return 0;
        }
    }
    function capacity(address snap, address token) external view returns (uint256) {
        if (!isSnap(snap)) return 0;
        return ISnap(snap).maxAmountIn(token);
    }
    function fill(ISTAR.SignedOrder calldata s, ISTAR.SignedAssignment calldata m, ISTAR.Execution calldata x)
        external
        whenNotPaused
    {
        SnapSolverStorageData storage $ = _getStorage();
        if (!$.isOperator[msg.sender]) revert NotOperator();
        address seller = s.order.seller;
        address receiver = s.order.receiver;
        if (($.isOperator[seller] && seller != msg.sender) || ($.isOperator[receiver] && receiver != msg.sender)) {
            revert FlowOrder();
        }
        if (!$.snaps.contains(x.sellRecipient)) revert UnknownSnap();
        ISTAR($.settlement).settle(s, m, x);
    }
    function onSettle(SettleContext calldata ctx, bytes calldata) external override {
        SnapSolverStorageData storage $ = _getStorage();
        if (msg.sender != $.settlement) revert NotSettlement();
        address snap = ctx.sellRecipient;
        if (!$.snaps.contains(snap)) revert UnknownSnap();
        IERC20 stable = IERC20(ISnap(snap).stable());
        if (ctx.buyToken != address(stable)) revert WrongBuyToken();
        uint256 owed = ctx.buySlice + ctx.feeSlice;
        uint256 before = stable.balanceOf(address(this));
        ISnap(snap).sellReceived(ctx.sellToken, ctx.sellSlice, owed);
        uint256 received = stable.balanceOf(address(this)) - before;
        if (received < owed) revert VenuePaidShort(received, owed);
        stable.forceApprove($.settlement, owed);
        emit Filled(ctx.orderId, snap, ctx.sellToken, ctx.sellSlice, received, received - owed);
    }
    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        _getStorage().isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }
    function setSnap(address snap, bool allowed) external onlyOwner {
        if (snap == address(0)) revert ZeroAddress();
        SnapSolverStorageData storage $ = _getStorage();
        if (allowed) $.snaps.add(snap);
        else $.snaps.remove(snap);
        emit SnapSet(snap, allowed);
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
    function _getStorage() private pure returns (SnapSolverStorageData storage) {
        return SnapSolverStorageV1.load();
    }
}
