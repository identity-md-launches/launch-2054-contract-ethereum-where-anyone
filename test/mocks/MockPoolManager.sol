// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Deterministic delta/settlement double for adversarial tests; real PoolManager integration is tested separately.
contract MockPoolManager {
    using SafeERC20 for IERC20;
    uint256 public amountOut = 1 ether;
    int256 public inputAdjustment;
    uint256 public swaps;
    uint256 public paid;
    bool public skipCallback;
    bool public corruptData;
    bool public doubleCallback;
    bool public lieAboutOutput;
    address public attackTarget;
    bytes public attackData;
    bool public attackSucceeded;
    bytes public attackResult;
    bytes public lastHookData;
    bool public lastZeroForOne;
    address private _locker;
    address private _input;
    address private _syncedCurrency;
    uint256 private _syncedBalance;
    uint256 private _owed;

    function setAmountOut(uint256 next) external {
        amountOut = next;
    }

    function setAdjustment(int256 next) external {
        inputAdjustment = next;
    }

    function setModes(bool skip, bool corrupt, bool twice, bool lie) external {
        skipCallback = skip;
        corruptData = corrupt;
        doubleCallback = twice;
        lieAboutOutput = lie;
    }

    function setAttack(address target, bytes calldata data) external {
        attackTarget = target;
        attackData = data;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(_locker == address(0), "already unlocked");
        _locker = msg.sender;
        if (skipCallback) return abi.encode(uint256(0));
        result = IUnlockCallback(msg.sender).unlockCallback(corruptData ? abi.encode(uint256(1), uint256(0)) : data);
        if (doubleCallback) IUnlockCallback(msg.sender).unlockCallback(data);
        require(_owed == 0, "unsettled");
        _locker = address(0);
        if (lieAboutOutput) return abi.encode(amountOut + 1);
    }

    function swap(PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata data)
        external
        returns (BalanceDelta)
    {
        require(msg.sender == _locker, "not locker");
        ++swaps;
        lastHookData = data;
        lastZeroForOne = params.zeroForOne;
        _input = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
        _owed = uint256(-params.amountSpecified + inputAdjustment);
        if (attackTarget != address(0)) {
            (attackSucceeded, attackResult) = attackTarget.call(attackData);
        }
        int128 inDelta = -int128(int256(_owed));
        int128 outDelta = int128(int256(amountOut));
        return params.zeroForOne ? toBalanceDelta(inDelta, outDelta) : toBalanceDelta(outDelta, inDelta);
    }

    function sync(Currency currency) external {
        _syncedCurrency = Currency.unwrap(currency);
        _syncedBalance = _syncedCurrency == address(0) ? 0 : IERC20(_syncedCurrency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 amount) {
        require(msg.sender == _locker && _syncedCurrency == _input, "bad settlement");
        amount = _input == address(0) ? msg.value : IERC20(_input).balanceOf(address(this)) - _syncedBalance;
        require(amount == _owed, "wrong input");
        _owed = 0;
        paid += amount;
    }

    function take(Currency currency, address to, uint256 amount) external {
        require(msg.sender == _locker, "not locker");
        IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
    }
}
