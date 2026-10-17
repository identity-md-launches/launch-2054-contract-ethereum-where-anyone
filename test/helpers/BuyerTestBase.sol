// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {WebsiteBuyer} from "src/WebsiteBuyer.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {MockIntake} from "../mocks/MockIntake.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

abstract contract BuyerTestBase is Test {
    bytes32 internal constant ACTION = bytes32("job.open@job-1");
    uint256 internal constant FEE = 0.003 ether;
    uint256 internal constant PRICE = 0.5 ether;
    address internal admin = makeAddr("edge admin");
    address internal alice = makeAddr("edge alice");
    address internal bob = makeAddr("edge bob");
    address internal treasury = makeAddr("edge treasury");
    address internal writer = makeAddr("edge writer");
    WebsiteBuyer internal buyer;
    MockToken internal token;
    MockIntake internal intake;
    MockPoolManager internal manager;

    function setUp() public virtual {
        token = new MockToken(18);
        intake = new MockIntake(treasury, writer);
        manager = new MockPoolManager();
        buyer = new WebsiteBuyer(admin, intake, address(token));
        intake.setPrice(ACTION, address(token), PRICE);
        token.mint(address(manager), 1_000_000 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        _route(address(0));
    }

    function _route(address input) internal {
        vm.prank(admin);
        buyer.setPool(IPoolManager(address(manager)), input, 3000, 60, IHooks(address(0)), "");
    }

    function _quote() internal view returns (WebsiteBuyer.Purchase memory) {
        return WebsiteBuyer.Purchase(0, PRICE, PRICE, block.timestamp, buyer.configurationVersion());
    }

    function _buy(address user) internal returns (bytes32) {
        WebsiteBuyer.Purchase memory quote = _quote();
        uint256 payment = buyer.ethPrice();
        vm.prank(user);
        return buyer.buyWebsite{value: payment}("a local bakery", quote);
    }

    function _repeat(bytes1 value, uint256 count) internal pure returns (string memory) {
        bytes memory result = new bytes(count);
        for (uint256 i; i < count; ++i) {
            result[i] = value;
        }
        return string(result);
    }
}
