// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {PriceFeed, STARStorageData, STARStorageV1} from "./STARStorageV1.sol";
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
interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
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
    uint256 private constant BPS = 10_000;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable matcher;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable guardian;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable feeCollector;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable sanctionsList;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint16 public immutable maxFeeBps;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint16 public immutable maxDiscountBps;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint64 public immutable configVersion;
    struct SolverUpdate {
        address solver;
        bool allowed;
    }
    struct FeedUpdate {
        address token;
        address feed;
        uint32 maxAge;
    }
    event Settled(
        address indexed sellToken, address indexed buyToken, address indexed seller, bytes32 orderId,
        bytes32 assignmentId, address solver, address matcher, address receiver, address sellRecipient,
        uint256 sellSlice, uint256 buyPaid, uint256 feePaid
    );
    event Cancelled(bytes32 indexed orderId, address indexed by);
    event SolverSet(address indexed solver, bool allowed);
    event PriceFeedSet(address indexed token, address feed, uint32 maxAge);
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
    error NotSeller();
    error BadSolverSet();
    error SolverNotAllowed();
    error SellRecipientIsSeller();
    error WrongMatcher();
    error SolverNotListed();
    error FeeTooHigh();
    error NoPriceFeed(address token);
    error StalePrice(address token);
    error PriceTooLow();
    error NotGuardian();
    error BadConfig();
    error NoRenounce();
    error NotStar();
    error Sanctioned(address account);
    error SellerNotDebited();
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address matcher_, address guardian_, address feeCollector_, address sanctionsList_, uint16 maxFeeBps_,
        uint16 maxDiscountBps_, uint64 configVersion_) {
        if (matcher_ == address(0) || guardian_ == address(0) || feeCollector_ == address(0)) revert ZeroAddress();
        if (maxFeeBps_ > BPS || maxDiscountBps_ > BPS || configVersion_ == 0) revert BadConfig();
        matcher = matcher_;
        guardian = guardian_;
        feeCollector = feeCollector_;
        sanctionsList = sanctionsList_;
        maxFeeBps = maxFeeBps_;
        maxDiscountBps = maxDiscountBps_;
        configVersion = configVersion_;
        _disableInitializers();
    }
    function initialize(address owner_, SolverUpdate[] calldata solvers, FeedUpdate[] calldata feeds)
        public initializer {
        __EIP712_init("RedstoneRfq", "1");
        __Ownable_init(owner_);
        __Pausable_init();
        _configure(solvers, feeds);
    }
    function reconfigure(SolverUpdate[] calldata solvers, FeedUpdate[] calldata feeds)
        external onlyOwner reinitializer(configVersion) {
        _configure(solvers, feeds);
    }
    function solverAllowed(address solver) external view returns (bool) {
        return _getStorage().solverAllowed[solver];
    }
    function priceFeed(address token) external view returns (PriceFeed memory) {
        return _getStorage().priceFeeds[token];
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
    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        _;
    }
    function cancelOrders(bytes32[] calldata orderIds) external onlyGuardianOrOwner {
        STARStorageData storage $ = _getStorage();
        for (uint256 i; i < orderIds.length; ++i) {
            $.cancelled[orderIds[i]] = true;
            emit Cancelled(orderIds[i], msg.sender);
        }
    }
    function renounceOwnership() public pure override {
        revert NoRenounce();
    }
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        STAR newImpl = STAR(newImplementation);
        if (newImpl.KIND_SELL() != KIND_SELL) revert NotStar();
    }
    function _getStorage() private pure returns (STARStorageData storage) {
        return STARStorageV1.load();
    }
    function pause() external onlyGuardianOrOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }
    function _configure(SolverUpdate[] calldata solvers, FeedUpdate[] calldata feeds) private {
        STARStorageData storage $ = _getStorage();
        for (uint256 i; i < solvers.length; ++i) {
            if (solvers[i].solver == address(0)) revert ZeroAddress();
            $.solverAllowed[solvers[i].solver] = solvers[i].allowed;
            emit SolverSet(solvers[i].solver, solvers[i].allowed);
        }
        for (uint256 i; i < feeds.length; ++i) {
            FeedUpdate calldata f = feeds[i];
            if (f.token == address(0)) revert ZeroAddress();
            $.priceFeeds[f.token] = PriceFeed(f.feed, f.maxAge);
            emit PriceFeedSet(f.token, f.feed, f.maxAge);
        }
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
        _emitSettled(o, a, orderId, assignmentId, address(0), buyPaid, feePaid);
        return buyPaid;
    }
    function _validate(SignedOrder calldata s, SignedAssignment calldata m)
        private returns (bytes32 orderId, bytes32 assignmentId) {
        Order calldata o = s.order;
        Assignment calldata a = m.assignment;
        STARStorageData storage $ = _getStorage();
        if (o.kind != KIND_SELL) revert NotSell();
        if (o.sellToken == o.buyToken) revert SameToken();
        if (o.receiver == feeCollector) revert ReceiverIsFeeCollector();
        if (o.matcher != matcher) revert WrongMatcher();
        if (!$.solverAllowed[msg.sender]) revert SolverNotListed();
        if (o.feeAmount * BPS > o.buyAmount * maxFeeBps) revert FeeTooHigh();
        address list = sanctionsList;
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
        _checkPrice(o, a);
        $.assignmentUsed[assignmentId] = true;
        $.filled[orderId] += a.sellSlice;
    }
    function _callSolver(Order calldata o, Assignment calldata a, bytes32 orderId, address sellTo,
        bytes calldata callbackData) private returns (uint256 buyPaid, uint256 feePaid) {
        address collector = feeCollector;
        ISolverCallback(msg.sender).onSettle(
            ISolverCallback.SettleContext({
                orderId: orderId, sellToken: o.sellToken, sellSlice: a.sellSlice, sellRecipient: sellTo,
                buyToken: o.buyToken, buySlice: a.buySlice, receiver: o.receiver, feeSlice: a.feeSlice,
                feeCollector: collector
            }), callbackData
        );
        IERC20 buy = IERC20(o.buyToken);
        buyPaid = _pull(buy, o.receiver, a.buySlice);
        if (buyPaid < a.buySlice) revert Underpaid();
        feePaid = _pull(buy, collector, a.feeSlice);
        if (feePaid < a.feeSlice) revert FeeUnpaid();
    }
    function _checkPrice(Order calldata o, Assignment calldata a) private view {
        uint256 sellValue = _value(o.sellToken, a.sellSlice);
        uint256 buyValue = _value(o.buyToken, a.buySlice);
        if (buyValue * BPS < sellValue * (BPS - maxDiscountBps)) revert PriceTooLow();
    }
    function _value(address token, uint256 amount) private view returns (uint256) {
        PriceFeed memory f = _getStorage().priceFeeds[token];
        if (f.feed == address(0)) revert NoPriceFeed(token);
        (, int256 answer,, uint256 updatedAt,) = IPriceFeed(f.feed).latestRoundData();
        if (answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > f.maxAge) {
            revert StalePrice(token);
        }
        uint256 decimals = uint256(IERC20Metadata(token).decimals()) + IPriceFeed(f.feed).decimals();
        return Math.mulDiv(amount, uint256(answer) * 1e18, 10 ** decimals);
    }
    function _pull(IERC20 token, address to, uint256 amount) private returns (uint256) {
        if (amount == 0) return 0;
        uint256 before = token.balanceOf(to);
        token.safeTransferFrom(msg.sender, to, amount);
        uint256 afterBalance = token.balanceOf(to);
        return afterBalance > before ? afterBalance - before : 0;
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
