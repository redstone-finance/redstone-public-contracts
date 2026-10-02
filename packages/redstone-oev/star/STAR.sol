// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {STARStorageData, STARStorageV1} from "./STARStorageV1.sol";
interface ISolverCallback {
    struct SettleContext {
        bytes32 orderId;
        address sellToken;
        uint256 sellSlice;
        address sellRecipient;
        address buyToken;
        uint256 buySlice;
        address receiver;
        uint256 feeSlice;
        address feeCollector;
    }
    function onSettle(SettleContext calldata ctx, bytes calldata data) external;
}
interface ISanctionsList {
    function isSanctioned(address account) external view returns (bool);
}
contract STAR is Initializable, UUPSUpgradeable, EIP712Upgradeable, Ownable2StepUpgradeable, PausableUpgradeable,
    ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    struct Order {
        address seller;
        address sellToken;
        address buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        uint256 nonce;
        uint256 feeAmount;
        bytes32 kind;
        bytes32 solverSet;
        address matcher;
    }
    struct Assignment {
        uint256 sellSlice;
        uint256 buySlice;
        uint256 feeSlice;
        uint32 deadline;
    }
    struct SignedOrder {
        Order order;
        bytes signature;
        address[] allowedSolvers;
    }
    struct SignedAssignment {
        Assignment assignment;
        bytes signature;
    }
    struct Execution {
        address sellRecipient;
        bytes callbackData;
    }
    bytes32 private constant ORDER_TYPEHASH = keccak256(
        "Order(address seller,address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,uint256 nonce,uint256 feeAmount,string kind,bytes32 solverSet,address matcher)"
    );
    bytes32 private constant ASSIGNMENT_TYPEHASH = keccak256(
        "Assignment(bytes32 orderId,address solver,uint256 sellSlice,uint256 buySlice,uint256 feeSlice,uint32 deadline)"
    );
    bytes32 public constant KIND_SELL = keccak256("sell");
    uint256 public constant OVERPAY_SLACK = 16;
    event Settled(
        address indexed sellToken, address indexed buyToken, address indexed seller, bytes32 orderId,
        bytes32 assignmentId, address solver, address matcher, address receiver, address sellRecipient,
        uint256 sellSlice, uint256 buyPaid, uint256 feePaid
    );
    event Cancelled(bytes32 indexed orderId, address indexed by);
    event MatcherRevocationSet(address indexed matcher, bool revoked);
    event FeeCollectorSet(address indexed feeCollector);
    event SanctionsListSet(address indexed sanctionsList);
    error ZeroAddress();
    error NotSell();
    error SameToken();
    error ReceiverIsFeeCollector();
    error OrderExpired();
    error AssignmentExpired();
    error ZeroSlice();
    error OrderCancelled();
    error BadSellerSignature();
    error BadAssignmentSignature();
    error AssignmentAlreadyUsed();
    error Overfill();
    error BelowFloor();
    error FeeShort();
    error Underpaid();
    error FeeUnpaid();
    error Overpaid();
    error NotSeller();
    error BadSolverSet();
    error SolverNotAllowed();
    error SellRecipientIsSeller();
    error MatcherRevoked();
    error NoRenounce();
    error NotStar();
    error Sanctioned(address account);
    error SellerNotDebited();
    constructor() {
        _disableInitializers();
    }
    function initialize(address owner_, address feeCollector_) public initializer {
        __EIP712_init("RedstoneRfq", "1");
        __Ownable_init(owner_);
        __Pausable_init();
        _setFeeCollector(feeCollector_);
    }
    function matcherRevoked(address matcher) external view returns (bool) {
        return _getStorage().matcherRevoked[matcher];
    }
    function feeCollector() public view returns (address) {
        return _getStorage().feeCollector;
    }
    function filled(bytes32 orderId) external view returns (uint256) {
        return _getStorage().filled[orderId];
    }
    function cancelled(bytes32 orderId) external view returns (bool) {
        return _getStorage().cancelled[orderId];
    }
    function assignmentUsed(bytes32 assignmentId) external view returns (bool) {
        return _getStorage().assignmentUsed[assignmentId];
    }
    function sanctionsList() external view returns (address) {
        return _getStorage().sanctionsList;
    }
    function setMatcherRevoked(address matcher, bool revoked) external onlyOwner {
        if (matcher == address(0)) revert ZeroAddress();
        _getStorage().matcherRevoked[matcher] = revoked;
        emit MatcherRevocationSet(matcher, revoked);
    }
    function setSanctionsList(address list) external onlyOwner {
        _getStorage().sanctionsList = list;
        emit SanctionsListSet(list);
    }
    function ownerCancel(bytes32[] calldata orderIds) external onlyOwner {
        STARStorageData storage $ = _getStorage();
        for (uint256 i; i < orderIds.length; ++i) {
            $.cancelled[orderIds[i]] = true;
            emit Cancelled(orderIds[i], msg.sender);
        }
    }
    function setFeeCollector(address collector) external onlyOwner {
        _setFeeCollector(collector);
    }
    function renounceOwnership() public pure override {
        revert NoRenounce();
    }
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        STAR newImpl = STAR(newImplementation);
        if (newImpl.KIND_SELL() != KIND_SELL || newImpl.OVERPAY_SLACK() != OVERPAY_SLACK) revert NotStar();
    }
    function _getStorage() private pure returns (STARStorageData storage) {
        return STARStorageV1.load();
    }
    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }
    function _setFeeCollector(address collector) private {
        if (collector == address(0)) revert ZeroAddress();
        _getStorage().feeCollector = collector;
        emit FeeCollectorSet(collector);
    }
    function hashOrder(Order calldata o) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            ORDER_TYPEHASH, o.seller, o.sellToken, o.buyToken, o.receiver, o.sellAmount,
            o.buyAmount, o.validTo, o.nonce, o.feeAmount, o.kind, o.solverSet, o.matcher
        )));
    }
    function hashSolverSet(address[] calldata solvers) public pure returns (bytes32) {
        return keccak256(abi.encode(solvers));
    }
    function hashAssignment(bytes32 orderId, address solver, Assignment calldata a) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            ASSIGNMENT_TYPEHASH, orderId, solver, a.sellSlice, a.buySlice, a.feeSlice, a.deadline
        )));
    }
    function settle(SignedOrder calldata s, SignedAssignment calldata m, Execution calldata x)
        external nonReentrant whenNotPaused returns (uint256) {
        Order calldata o = s.order;
        Assignment calldata a = m.assignment;
        (bytes32 orderId, bytes32 assignmentId) = _validate(s, m);
        address sellTo = x.sellRecipient == address(0) ? msg.sender : x.sellRecipient;
        if (sellTo == o.seller) revert SellRecipientIsSeller();
        IERC20(o.sellToken).safeTransferFrom(o.seller, sellTo, a.sellSlice);
        (uint256 buyPaid, uint256 feePaid) = _callSolver(o, a, orderId, sellTo, x.callbackData);
        if (buyPaid + feePaid > a.buySlice + a.feeSlice + OVERPAY_SLACK) revert Overpaid();
        _emitSettled(o, a, orderId, assignmentId, sellTo, buyPaid, feePaid);
        return buyPaid;
    }
    function settleFromSeller(SignedOrder calldata s, SignedAssignment calldata m, bytes calldata callbackData)
        external nonReentrant whenNotPaused returns (uint256) {
        Order calldata o = s.order;
        Assignment calldata a = m.assignment;
        (bytes32 orderId, bytes32 assignmentId) = _validate(s, m);
        uint256 sellerBefore = IERC20(o.sellToken).balanceOf(o.seller);
        (uint256 buyPaid, uint256 feePaid) = _callSolver(o, a, orderId, address(0), callbackData);
        if (IERC20(o.sellToken).balanceOf(o.seller) + a.sellSlice != sellerBefore) revert SellerNotDebited();
        if (buyPaid + feePaid > a.buySlice + a.feeSlice + OVERPAY_SLACK) revert Overpaid();
        _emitSettled(o, a, orderId, assignmentId, address(0), buyPaid, feePaid);
        return buyPaid;
    }
    function _validate(SignedOrder calldata s, SignedAssignment calldata m)
        private returns (bytes32 orderId, bytes32 assignmentId) {
        Order calldata o = s.order;
        Assignment calldata a = m.assignment;
        STARStorageData storage $ = _getStorage();
        address collector = $.feeCollector;
        if (o.kind != KIND_SELL) revert NotSell();
        if (o.sellToken == o.buyToken) revert SameToken();
        if (o.receiver == collector) revert ReceiverIsFeeCollector();
        if (o.matcher == address(0)) revert ZeroAddress();
        if ($.matcherRevoked[o.matcher]) revert MatcherRevoked();
        address list = $.sanctionsList;
        if (list != address(0)) {
            if (ISanctionsList(list).isSanctioned(o.seller)) revert Sanctioned(o.seller);
            if (o.receiver != o.seller && ISanctionsList(list).isSanctioned(o.receiver)) revert Sanctioned(o.receiver);
        }
        if (block.timestamp > o.validTo) revert OrderExpired();
        if (block.timestamp > a.deadline) revert AssignmentExpired();
        if (a.sellSlice == 0) revert ZeroSlice();
        orderId = hashOrder(o);
        if ($.cancelled[orderId]) revert OrderCancelled();
        if (!SignatureChecker.isValidSignatureNow(o.seller, orderId, s.signature)) revert BadSellerSignature();
        if (o.solverSet != bytes32(0)) {
            if (hashSolverSet(s.allowedSolvers) != o.solverSet) revert BadSolverSet();
            if (!_isAllowed(s.allowedSolvers, msg.sender)) revert SolverNotAllowed();
        }
        assignmentId = hashAssignment(orderId, msg.sender, a);
        if ($.assignmentUsed[assignmentId]) revert AssignmentAlreadyUsed();
        if (!SignatureChecker.isValidSignatureNow(o.matcher, assignmentId, m.signature)) {
            revert BadAssignmentSignature();
        }
        if ($.filled[orderId] + a.sellSlice > o.sellAmount) revert Overfill();
        if (a.buySlice * o.sellAmount < o.buyAmount * a.sellSlice) revert BelowFloor();
        if (a.feeSlice * o.sellAmount < o.feeAmount * a.sellSlice) revert FeeShort();
        $.assignmentUsed[assignmentId] = true;
        $.filled[orderId] += a.sellSlice;
    }
    function _callSolver(Order calldata o, Assignment calldata a, bytes32 orderId, address sellTo,
        bytes calldata callbackData) private returns (uint256 buyPaid, uint256 feePaid) {
        address collector = _getStorage().feeCollector;
        uint256 receiverBefore = IERC20(o.buyToken).balanceOf(o.receiver);
        uint256 collectorBefore = IERC20(o.buyToken).balanceOf(collector);
        ISolverCallback(msg.sender).onSettle(
            ISolverCallback.SettleContext({
                orderId: orderId, sellToken: o.sellToken, sellSlice: a.sellSlice, sellRecipient: sellTo,
                buyToken: o.buyToken, buySlice: a.buySlice, receiver: o.receiver, feeSlice: a.feeSlice,
                feeCollector: collector
            }), callbackData
        );
        uint256 receiverAfter = IERC20(o.buyToken).balanceOf(o.receiver);
        uint256 collectorAfter = IERC20(o.buyToken).balanceOf(collector);
        if (receiverAfter < receiverBefore) revert Underpaid();
        if (collectorAfter < collectorBefore) revert FeeUnpaid();
        buyPaid = receiverAfter - receiverBefore;
        feePaid = collectorAfter - collectorBefore;
        if (buyPaid < a.buySlice) revert Underpaid();
        if (feePaid < a.feeSlice) revert FeeUnpaid();
    }
    function _emitSettled(Order calldata o, Assignment calldata a, bytes32 orderId, bytes32 assignmentId,
        address sellTo, uint256 buyPaid, uint256 feePaid) private {
        emit Settled(
            o.sellToken, o.buyToken, o.seller, orderId, assignmentId, msg.sender, o.matcher,
            o.receiver, sellTo, a.sellSlice, buyPaid, feePaid
        );
    }
    function cancel(Order calldata o) external {
        if (msg.sender != o.seller) revert NotSeller();
        bytes32 orderId = hashOrder(o);
        _getStorage().cancelled[orderId] = true;
        emit Cancelled(orderId, msg.sender);
    }
    function _isAllowed(address[] calldata solvers, address solver) private pure returns (bool) {
        for (uint256 i; i < solvers.length; ++i) {
            if (solvers[i] == solver) return true;
        }
        return false;
    }
}
