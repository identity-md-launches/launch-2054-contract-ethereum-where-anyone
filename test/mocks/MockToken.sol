// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    uint8 private immutable _decimals;
    uint256 public taxBps;
    bool public returnsFalse;

    constructor(uint8 decimals_) ERC20("Test IMD", "IMD") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTax(uint256 bps) external {
        taxBps = bps;
    }

    function setReturnsFalse(bool next) external {
        returnsFalse = next;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (returnsFalse) return false;
        return super.transfer(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        uint256 fee = from != address(0) && to != address(0) ? amount * taxBps / 10_000 : 0;
        if (fee != 0) super._update(from, address(0), fee);
        super._update(from, to, amount - fee);
    }
}

contract MockWETH is MockToken {
    constructor() MockToken(18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @dev ERC-20 ABI without return values on transfers/approval, as supported by SafeERC20.
contract NoReturnIMD {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
