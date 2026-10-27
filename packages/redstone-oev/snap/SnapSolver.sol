// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SettleNativeAtomicProvider} from "./SettleNativeAtomicProvider.sol";
import {ISTAR, ISolverCallbackAbi} from "../adapters/fill/IFillSolver.sol";
contract SnapSolver is Ownable2Step, Pausable, ISolverCallbackAbi {
    using SafeERC20 for IERC20;
    ISTAR public immutable settlement;
    SettleNativeAtomicProvider public immutable snap;
    IERC20 public immutable stable;
    mapping(address => bool) public isOperator;
    event OperatorSet(address indexed operator, bool allowed);
    event Filled(
        bytes32 indexed orderId, address indexed sellToken, uint256 sellSlice, uint256 received, uint256 margin
    );
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    error ZeroAddress();
    error NotOperator();
    error FlowOrder();
    error NotSettlement();
    error NotSellRecipient();
    error WrongBuyToken();
    error VenuePaidShort(uint256 received, uint256 owed);
    error NoRenounce();
    constructor(address owner_, ISTAR settlement_, SettleNativeAtomicProvider snap_) Ownable(owner_) {
        if (address(settlement_) == address(0) || address(snap_) == address(0)) revert ZeroAddress();
        settlement = settlement_;
        snap = snap_;
        stable = snap_.stable();
    }
    function fill(ISTAR.SignedOrder calldata s, ISTAR.SignedAssignment calldata m, ISTAR.Execution calldata x)
        external
        whenNotPaused
    {
        if (!isOperator[msg.sender]) revert NotOperator();
        address seller = s.order.seller;
        address receiver = s.order.receiver;
        if ((isOperator[seller] && seller != msg.sender) || (isOperator[receiver] && receiver != msg.sender)) {
            revert FlowOrder();
        }
        settlement.settle(s, m, x);
    }
    function onSettle(SettleContext calldata ctx, bytes calldata) external override {
        if (msg.sender != address(settlement)) revert NotSettlement();
        if (ctx.sellRecipient != address(this)) revert NotSellRecipient();
        if (ctx.buyToken != address(stable)) revert WrongBuyToken();
        uint256 owed = ctx.buySlice + ctx.feeSlice;
        IERC20(ctx.sellToken).forceApprove(address(snap), ctx.sellSlice);
        uint256 before = stable.balanceOf(address(this));
        snap.sell(ctx.sellToken, ctx.sellSlice, owed);
        uint256 received = stable.balanceOf(address(this)) - before;
        if (received < owed) revert VenuePaidShort(received, owed);
        stable.forceApprove(address(settlement), owed);
        emit Filled(ctx.orderId, ctx.sellToken, ctx.sellSlice, received, received - owed);
    }
    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
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
}
