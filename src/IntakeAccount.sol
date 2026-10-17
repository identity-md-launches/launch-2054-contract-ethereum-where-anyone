// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIntake} from "./interfaces/IIntake.sol";

/// @notice Adapted from the supplied canonical IntakeAccount. One payer per user keeps projects separate.
/// @dev Created by WebsiteBuyer on first purchase, not deployed separately by the launch factory.
contract IntakeAccount is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotHub();
    error NotUser();
    error InvalidUser();
    error IncorrectPayment();

    address public immutable hub;
    address public immutable user;

    constructor(address user_) {
        if (user_ == address(0)) revert InvalidUser();
        hub = msg.sender;
        user = user_;
    }

    /// @notice The hub funds exactly price before calling. Only that amount may be spent.
    function ask(
        IIntake intake,
        bytes32 action,
        bytes calldata body,
        IIntake.Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 price
    ) external nonReentrant returns (bytes32 requestId) {
        if (msg.sender != hub) revert NotHub();
        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.forceApprove(address(intake), price);
        requestId = intake.requestWithFailure(action, body, callback, onFailure, asset, price);
        token.forceApprove(address(intake), 0);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != price) revert IncorrectPayment();
    }

    /// @notice Only the user may act as their project's payer, including approving and paying for continuations.
    function execute(address target, uint256 value, bytes calldata data)
        external
        nonReentrant
        returns (bytes memory result)
    {
        if (msg.sender != user) revert NotUser();
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    receive() external payable {}
}
