// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FillSlice, IFillSolver, ISTAR} from "../fill/IFillSolver.sol";
import {Authorization, IMorpho, MarketParams, Signature} from "../morpho/IMorpho.sol";
contract StarMorphoUnwinder is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    error NotMorpho();
    error NotBorrower();
    error ReceiverNotSelf();
    error WrongTokens();
    error WrongMatcher();
    error SlicesNotCollateral();
    error CollateralNotSold();
    error SolverFillFailed(address solver, bytes reason);
    error SlicesNotSigned();
    error SliceAlreadyUsed(uint256 index);
    error SliceNotSettled(uint256 index);
    error UnexpectedProceeds(uint256 arrived, uint256 owed);
    IMorpho public immutable morpho;
    ISTAR public immutable star;
    address public immutable matcher;
    event Unwound(
        bytes32 indexed marketId, address indexed borrower, uint256 collateral, uint256 repaid, uint256 proceeds
    );
    constructor(IMorpho _morpho, ISTAR _star, address _matcher) {
        morpho = _morpho;
        star = _star;
        matcher = _matcher;
    }

    function unwind(
        MarketParams calldata mp,
        ISTAR.SignedOrder calldata s,
        FillSlice[] calldata slices,
        Authorization calldata grant,
        Signature calldata grantSig,
        Authorization calldata revoke,
        Signature calldata revokeSig,
        bytes calldata slicesSig
    ) external nonReentrant {
        address borrower = s.order.seller;
        if (msg.sender != borrower) revert NotBorrower();
        if (s.order.receiver != address(this)) revert ReceiverNotSelf();
        if (s.order.matcher != matcher) revert WrongMatcher();
        if (s.order.sellToken != mp.collateralToken || s.order.buyToken != mp.loanToken) revert WrongTokens();
        bytes32 digest = keccak256(abi.encode(block.chainid, address(this), s, slices));
        if (!SignatureChecker.isValidSignatureNow(matcher, MessageHashUtils.toEthSignedMessageHash(digest), slicesSig)) {
            revert SlicesNotSigned();
        }
        if (!morpho.isAuthorized(borrower, address(this))) morpho.setAuthorizationWithSig(grant, grantSig);
        bytes32 marketId = keccak256(abi.encode(mp));
        (, uint128 borrowShares, uint128 collateral) = morpho.position(marketId, borrower);
        uint256 total;
        uint256 owed;
        for (uint256 i; i < slices.length; ++i) {
            total += slices[i].assignment.assignment.sellSlice;
            owed += slices[i].assignment.assignment.buySlice;
        }
        if (total != collateral) revert SlicesNotCollateral();
        bytes memory data = abi.encode(mp, s, slices, uint256(collateral));
        IERC20 coll = IERC20(mp.collateralToken);
        uint256 collBefore = coll.balanceOf(borrower);
        IERC20 loan = IERC20(mp.loanToken);
        uint256 loanBefore = loan.balanceOf(address(this));
        uint256 repaid;
        if (borrowShares > 0) {
            (repaid,) = morpho.repay(mp, 0, borrowShares, borrower, data);
        } else {
            _release(mp, s, slices, collateral);
        }
        if (coll.balanceOf(borrower) != collBefore) revert CollateralNotSold();
        uint256 arrived = loan.balanceOf(address(this)) + repaid - loanBefore;
        if (arrived != owed) revert UnexpectedProceeds(arrived, owed);
        uint256 proceeds = arrived - repaid;
        loan.safeTransfer(borrower, proceeds);
        if (morpho.isAuthorized(borrower, address(this))) {
            try morpho.setAuthorizationWithSig(revoke, revokeSig) {} catch {}
        }
        emit Unwound(marketId, borrower, collateral, repaid, proceeds);
    }

    function onMorphoRepay(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert NotMorpho();
        (MarketParams memory mp, ISTAR.SignedOrder memory s, FillSlice[] memory slices, uint256 collateral) =
            abi.decode(data, (MarketParams, ISTAR.SignedOrder, FillSlice[], uint256));
        _release(mp, s, slices, collateral);
        IERC20(mp.loanToken).forceApprove(address(morpho), assets);
    }

    function _release(MarketParams memory mp, ISTAR.SignedOrder memory s, FillSlice[] memory slices, uint256 collateral)
        private
    {
        morpho.withdrawCollateral(mp, collateral, s.order.seller, s.order.seller);
        bytes32 orderId = star.hashOrder(s.order);
        for (uint256 i; i < slices.length; ++i) {
            bytes32 id = star.hashAssignment(orderId, slices[i].solver, slices[i].assignment.assignment);
            if (star.assignmentUsed(id)) revert SliceAlreadyUsed(i);
            try IFillSolver(slices[i].solver).fill(s, slices[i].assignment, slices[i].execution) {}
            catch (bytes memory reason) {
                revert SolverFillFailed(slices[i].solver, reason);
            }
            if (!star.assignmentUsed(id)) revert SliceNotSettled(i);
        }
    }
}
