// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {FillSlice, IFillSolver, ISTAR} from "../fill/IFillSolver.sol";
import {IMorpho, MarketParams} from "../morpho/IMorpho.sol";
struct SellerApproval {
    address spender;
    uint256 amount;
    bytes32 hash;
}

contract StarMorphoLiquidator is IERC1271 {
    using SafeERC20 for IERC20;
    using TransientSlot for *;
    error NotExecutor();
    error NotMorpho();
    error WrongSigner();
    error WrongMatcher();
    error WrongTokens();
    error NotSelf();
    bytes32 private constant SIGNS = keccak256("StarMorphoLiquidator.signs");
    IMorpho public immutable morpho;
    ISTAR public immutable star;
    address public immutable executor;
    address public immutable signer;
    address public immutable matcher;
    address public immutable surplusRecipient;
    event Liquidated(
        bytes32 indexed marketId, address indexed borrower, uint256 seized, uint256 repaid, uint256 surplus
    );
    constructor(
        IMorpho _morpho,
        ISTAR _star,
        address _executor,
        address _signer,
        address _matcher,
        address _surplusRecipient
    ) {
        morpho = _morpho;
        star = _star;
        executor = _executor;
        signer = _signer;
        matcher = _matcher;
        surplusRecipient = _surplusRecipient;
    }

    function liquidate(uint256, address solver, bytes calldata operationData) external {
        if (msg.sender != executor) revert NotExecutor();
        if (solver != signer) revert WrongSigner();
        (bytes32 marketId, address borrower, ISTAR.SignedOrder memory s, FillSlice[] memory slices,) =
            abi.decode(operationData, (bytes32, address, ISTAR.SignedOrder, FillSlice[], SellerApproval[]));
        if (s.order.matcher != matcher) revert WrongMatcher();
        MarketParams memory mp = morpho.idToMarketParams(marketId);
        if (s.order.sellToken != mp.collateralToken || s.order.buyToken != mp.loanToken) revert WrongTokens();
        if (s.order.seller != address(this) || s.order.receiver != address(this)) revert NotSelf();
        uint256 seized;
        for (uint256 i; i < slices.length; ++i) {
            seized += slices[i].assignment.assignment.sellSlice;
        }
        (, uint256 repaid) = morpho.liquidate(mp, borrower, seized, 0, operationData);
        IERC20 loan = IERC20(mp.loanToken);
        uint256 surplus = loan.balanceOf(address(this));
        loan.safeTransfer(surplusRecipient, surplus);
        emit Liquidated(marketId, borrower, seized, repaid, surplus);
    }

    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert NotMorpho();
        (,, ISTAR.SignedOrder memory s, FillSlice[] memory slices, SellerApproval[] memory approvals) =
            abi.decode(data, (bytes32, address, ISTAR.SignedOrder, FillSlice[], SellerApproval[]));
        IERC20 coll = IERC20(s.order.sellToken);
        coll.forceApprove(address(star), coll.balanceOf(address(this)));
        bytes32 orderHash = star.hashOrder(s.order);
        _signs(orderHash).asBoolean().tstore(true);
        _grant(coll, approvals, true);
        for (uint256 i; i < slices.length; ++i) {
            IFillSolver(slices[i].solver).fill(s, slices[i].assignment, slices[i].execution);
        }
        _grant(coll, approvals, false);
        _signs(orderHash).asBoolean().tstore(false);
        coll.forceApprove(address(star), 0);
        IERC20(s.order.buyToken).forceApprove(address(morpho), repaidAssets);
    }

    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return _signs(hash).asBoolean().tload() ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    function _grant(IERC20 coll, SellerApproval[] memory approvals, bool on) private {
        for (uint256 i; i < approvals.length; ++i) {
            coll.forceApprove(approvals[i].spender, on ? approvals[i].amount : 0);
            _signs(approvals[i].hash).asBoolean().tstore(on);
        }
    }

    function _signs(bytes32 hash) private pure returns (bytes32) {
        return keccak256(abi.encode(SIGNS, hash));
    }

    function payBid(uint256) external {}
}
