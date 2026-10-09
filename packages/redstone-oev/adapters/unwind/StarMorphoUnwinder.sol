// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FillSlice, IFillSolver, ISTAR} from "../fill/IFillSolver.sol";
import {Authorization, IMorpho, MarketParams, Signature} from "../morpho/IMorpho.sol";
contract StarMorphoUnwinder is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    error NotMorpho();
    error ReceiverNotSelf();
    error WrongTokens();
    error SlicesNotCollateral();
    error NotRevoked();
    IMorpho public immutable morpho;
    event Unwound(
        bytes32 indexed marketId, address indexed borrower, uint256 collateral, uint256 repaid, uint256 proceeds
    );
    constructor(IMorpho _morpho) {
        morpho = _morpho;
    }

    function unwind(
        MarketParams calldata mp,
        ISTAR.SignedOrder calldata s,
        FillSlice[] calldata slices,
        Authorization calldata grant,
        Signature calldata grantSig,
        Authorization calldata revoke,
        Signature calldata revokeSig
    ) external nonReentrant {
        address borrower = s.order.seller;
        if (s.order.receiver != address(this)) revert ReceiverNotSelf();
        if (s.order.sellToken != mp.collateralToken || s.order.buyToken != mp.loanToken) revert WrongTokens();
        if (!morpho.isAuthorized(borrower, address(this))) morpho.setAuthorizationWithSig(grant, grantSig);
        bytes32 marketId = keccak256(abi.encode(mp));
        (, uint128 borrowShares, uint128 collateral) = morpho.position(marketId, borrower);
        uint256 total;
        for (uint256 i; i < slices.length; ++i) {
            total += slices[i].assignment.assignment.sellSlice;
        }
        if (total != collateral) revert SlicesNotCollateral();
        bytes memory data = abi.encode(mp, s, slices, uint256(collateral));
        uint256 repaid;
        if (borrowShares > 0) {
            (repaid,) = morpho.repay(mp, 0, borrowShares, borrower, data);
        } else {
            _release(mp, s, slices, collateral);
        }
        IERC20 loan = IERC20(mp.loanToken);
        uint256 proceeds = loan.balanceOf(address(this));
        loan.safeTransfer(borrower, proceeds);
        morpho.setAuthorizationWithSig(revoke, revokeSig);
        if (morpho.isAuthorized(borrower, address(this))) revert NotRevoked();
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
        for (uint256 i; i < slices.length; ++i) {
            IFillSolver(slices[i].solver).fill(s, slices[i].assignment, slices[i].execution);
        }
    }
}
