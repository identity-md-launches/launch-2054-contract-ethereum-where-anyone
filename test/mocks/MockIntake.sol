// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIntake} from "../../src/interfaces/IIntake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Protocol-shaped mock: pays the treasury immediately and attempts writer-only callbacks once, with 200k gas.
contract MockIntake is IIntake {
    using SafeERC20 for IERC20;

    struct Ask {
        address payer;
        bytes32 action;
        bytes body;
        Callback callback;
        bytes4 onFailure;
        address asset;
        uint256 amount;
        bool completed;
        bool delivered;
    }
    mapping(bytes32 => mapping(address => uint256)) public priceOf;
    mapping(bytes32 => Ask) private _asks;
    address public immutable treasury;
    address public immutable writer;
    uint256 public count;
    bool public reject;
    bool public skipPull;
    bytes32 public forcedId;
    address public attackTarget;
    bytes public attackData;
    bool public attackSucceeded;
    bytes public attackResult;

    event Requested(
        bytes32 indexed requestId,
        address indexed payer,
        bytes32 indexed action,
        bytes body,
        address callbackTarget,
        bytes4 callbackSelector,
        address asset,
        uint256 amount
    );
    event Completed(bytes32 indexed requestId, uint8 status, bytes32 resultHash, string uri, bool delivered);

    constructor(address treasury_, address writer_) {
        treasury = treasury_;
        writer = writer_;
    }

    function setPrice(bytes32 action, address asset, uint256 price) external {
        priceOf[action][asset] = price;
    }

    function setReject(bool next) external {
        reject = next;
    }

    function setSkipPull(bool next) external {
        skipPull = next;
    }

    function setForcedId(bytes32 next) external {
        forcedId = next;
    }

    function setAttack(address target, bytes calldata data) external {
        attackTarget = target;
        attackData = data;
    }

    function askOf(bytes32 id) external view returns (Ask memory) {
        return _asks[id];
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        require(!reject, "intake unavailable");
        require(msg.value == 0, "native not sold");
        require(priceOf[action][asset] != 0, "action not sold");
        require(amount >= priceOf[action][asset], "short payment");
        require(body.length > 0 && body.length <= 16_384, "bad body size");
        if (attackTarget != address(0)) {
            (attackSucceeded, attackResult) = attackTarget.call(attackData);
        }
        if (!skipPull) {
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(asset).safeTransfer(treasury, amount);
        }
        ++count;
        id = forcedId != bytes32(0) ? forcedId : keccak256(abi.encode(address(this), msg.sender, count));
        _asks[id] = Ask(msg.sender, action, body, callback, onFailure, asset, amount, false, false);
        emit Requested(id, msg.sender, action, body, callback.target, callback.selector, asset, amount);
    }

    function complete(bytes32 id, uint8 status, bytes32 resultHash, string calldata uri, bytes32 reason)
        external
        returns (bool delivered)
    {
        require(msg.sender == writer, "not writer");
        Ask storage a = _asks[id];
        require(a.payer != address(0) && !a.completed, "not pending");
        a.completed = true;
        bytes memory data = status == 0
            ? abi.encodeWithSelector(a.callback.selector, id, resultHash, uri)
            : abi.encodeWithSelector(a.onFailure, id, status, reason, uint16(0), uint16(0), bytes(""));
        (delivered,) = a.callback.target.call{gas: 200_000}(data);
        a.delivered = delivered;
        emit Completed(id, status, resultHash, uri, delivered);
    }

    /// @dev Models the plane's payer identity check for a project continuation.
    function continueProject(bytes32 openingRequest) external view returns (address) {
        require(_asks[openingRequest].payer == msg.sender, "wrong project payer");
        return msg.sender;
    }
}
