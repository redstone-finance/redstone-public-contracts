// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
interface ISTAR {
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

    event Settled(
        address indexed sellToken,
        address indexed buyToken,
        address indexed seller,
        bytes32 orderId,
        bytes32 assignmentId,
        address solver,
        address matcher,
        address receiver,
        address sellRecipient,
        uint256 sellSlice,
        uint256 buyPaid,
        uint256 feePaid
    );
    function settle(SignedOrder calldata s, SignedAssignment calldata m, Execution calldata x)
        external
        returns (uint256 buyPaid);
    function settleFromSeller(SignedOrder calldata s, SignedAssignment calldata m, bytes calldata callbackData)
        external
        returns (uint256 buyPaid);
    function hashOrder(Order calldata o) external view returns (bytes32);
    function filled(bytes32 orderId) external view returns (uint256);
}

interface ISolverCallbackAbi {
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

struct FillSlice {
    address solver;
    ISTAR.SignedAssignment assignment;
    ISTAR.Execution execution;
}

interface IFillSolver {
    function fill(ISTAR.SignedOrder calldata s, ISTAR.SignedAssignment calldata m, ISTAR.Execution calldata x)
        external;
}
