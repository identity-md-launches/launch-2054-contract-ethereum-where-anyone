// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {WebsiteBuyer} from "src/WebsiteBuyer.sol";
import {IntakeAccount} from "src/IntakeAccount.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {JsonText} from "src/libraries/JsonText.sol";
import {BuyerTestBase} from "./helpers/BuyerTestBase.sol";
import {MockToken, MockWETH} from "./mocks/MockToken.sol";

/// @dev A smart wallet calls the buyer; its controller must not become the project owner.
contract WebsiteWallet {
    function buy(WebsiteBuyer buyer, WebsiteBuyer.Purchase calldata quote) external payable returns (bytes32) {
        return buyer.buyWebsite{value: msg.value}("a wallet-owned website", quote);
    }

    function recover(IntakeAccount account, address recipient, uint256 value) external {
        account.execute(recipient, value, "");
    }
}

contract ShortMintWrapper is MockToken {
    constructor() MockToken(18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value - 1);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract WebsiteBuyerEdgesTest is BuyerTestBase {
    function testPurchaseEventContainsExactReceiptAndBodyCommitment() public {
        vm.recordLogs();
        bytes32 id = _buy(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 signature =
            keccak256("WebsiteRequested(bytes32,address,address,address,uint256,bytes32,uint256,uint256,uint256)");
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(buyer) || logs[i].topics[0] != signature) continue;
            ++matches;
            assertEq(logs[i].topics.length, 4);
            assertEq(logs[i].topics[1], id);
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))));
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(address(intake)))));
            (
                address account,
                uint256 templateId,
                bytes32 bodyHash,
                uint256 ethPaid,
                uint256 imdBought,
                uint256 imdPaid
            ) = abi.decode(logs[i].data, (address, uint256, bytes32, uint256, uint256, uint256));
            assertEq(account, address(buyer.accountOf(alice)));
            assertEq(templateId, 0);
            assertEq(bodyHash, keccak256(intake.askOf(id).body));
            assertEq(ethPaid, FEE);
            assertEq(imdBought, 1 ether);
            assertEq(imdPaid, PRICE);
        }
        assertEq(matches, 1, "missing or duplicated purchase event");
    }

    function testContractCallerOwnsPayerAndBodyRegardlessOfTransactionOrigin() public {
        WebsiteWallet wallet = new WebsiteWallet();
        WebsiteBuyer.Purchase memory quote = _quote();
        vm.prank(alice, bob);
        bytes32 id = wallet.buy{value: FEE}(buyer, quote);
        IntakeAccount account = buyer.accountOf(address(wallet));
        assertEq(account.user(), address(wallet));
        assertEq(buyer.requestOf(address(intake), id).user, address(wallet));
        assertEq(intake.askOf(id).payer, address(account));
        assertEq(
            intake.askOf(id).body,
            abi.encodePacked(
                '{"objective":"Build a one-page website: a wallet-owned website","skill":"build-website","host":true,"owner":"',
                Strings.toHexString(address(wallet)),
                '"}'
            )
        );
        assertEq(address(buyer.accountOf(alice)), address(0));
        assertEq(address(buyer.accountOf(bob)), address(0));
        vm.deal(address(account), 1 ether);
        vm.prank(alice);
        vm.expectRevert(IntakeAccount.NotUser.selector);
        account.execute(alice, 1 ether, "");
        wallet.recover(account, alice, 1 ether);
        assertEq(address(account).balance, 0);
    }

    function testMaximumSignedInputAndOutputDoNotTruncate() public {
        uint256 maximum = uint256(uint128(type(int128).max));
        vm.prank(admin);
        buyer.setETHPrice(maximum);
        token.mint(address(manager), maximum);
        manager.setAmountOut(maximum);
        vm.deal(alice, maximum);
        _buy(alice);
        assertEq(alice.balance, 0);
        assertEq(address(manager).balance, maximum);
        assertEq(token.balanceOf(address(buyer)), maximum - PRICE);
        vm.prank(admin);
        vm.expectRevert(WebsiteBuyer.InvalidPrice.selector);
        buyer.setETHPrice(maximum + 1);
        assertEq(buyer.ethPrice(), maximum);
    }

    function testOneWeiETHPriceAndExactMinimumOutput() public {
        vm.prank(admin);
        buyer.setETHPrice(1);
        manager.setAmountOut(PRICE);
        _buy(alice);
        assertEq(address(manager).balance, 1);
        assertEq(token.balanceOf(address(buyer)), 0);
        assertEq(token.balanceOf(treasury), PRICE);
    }

    function testFuzzFreshOutputMustSatisfyAllThreeFloors(
        uint96 outputSeed,
        uint96 priceSeed,
        uint96 minimumSeed,
        uint96 surplusSeed
    ) public {
        uint256 output = bound(outputSeed, 0, 6 ether);
        uint256 price = bound(priceSeed, 1, 3 ether);
        uint256 minimum = bound(minimumSeed, 0, 4 ether);
        uint256 oldSurplus = bound(surplusSeed, 0, 100 ether);
        intake.setPrice(ACTION, address(token), price);
        manager.setAmountOut(output);
        token.mint(address(buyer), oldSurplus);
        WebsiteBuyer.Purchase memory quote = _quote();
        quote.minImdOut = minimum;
        quote.maxIntakePrice = price;
        bool sufficient = output >= PRICE && output >= price && output >= minimum;
        uint256 required = PRICE > price ? PRICE : price;
        if (minimum > required) required = minimum;
        if (!sufficient) {
            vm.prank(alice);
            if (output == 0) vm.expectRevert(WebsiteBuyer.IncompleteSwap.selector);
            else vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.InsufficientOutput.selector, output, required));
            buyer.buyWebsite{value: FEE}("a site", quote);
            assertEq(token.balanceOf(address(buyer)), oldSurplus);
            assertEq(token.balanceOf(treasury), 0);
            assertEq(address(manager).balance, 0);
            assertEq(manager.swaps(), 0);
            assertEq(intake.count(), 0);
            assertEq(address(buyer.accountOf(alice)), address(0));
            assertEq(alice.balance, 100 ether);
            // A reverted unlock must leave the contract usable on the very next transaction.
            output = required;
            manager.setAmountOut(output);
        }
        vm.prank(alice);
        bytes32 id = buyer.buyWebsite{value: FEE}("a site", quote);
        assertEq(token.balanceOf(address(buyer)), oldSurplus + output - price);
        assertEq(token.balanceOf(treasury), price);
        assertEq(token.balanceOf(address(manager)), 1_000_000 ether - output);
        assertEq(buyer.requestOf(address(intake), id).imdPaid, price);
        assertEq(address(manager).balance, FEE);
        assertEq(alice.balance, 100 ether - FEE);
    }

    function testAllConfigurationSettersInvalidateAnAlreadyReviewedQuote() public {
        for (uint256 i; i < 7; ++i) {
            WebsiteBuyer.Purchase memory stale = _quote();
            vm.startPrank(admin);
            if (i == 0) buyer.setETHPrice(FEE);
            else if (i == 1) buyer.setIntake(intake);
            else if (i == 2) buyer.setIMD(address(token));
            else if (i == 3) buyer.setAction(ACTION);
            else if (i == 4) buyer.setTemplate(0, "Build a one-page website: ", "build-website", true, true);
            else if (i == 5) buyer.setPool(IPoolManager(address(manager)), address(0), 3000, 60, IHooks(address(0)), "");
            else buyer.setPaused(false);
            vm.stopPrank();
            assertEq(buyer.configurationVersion(), stale.configurationVersion + 1);
            vm.prank(alice);
            vm.expectRevert(WebsiteBuyer.ConfigurationChanged.selector);
            buyer.buyWebsite{value: FEE}("a site", stale);
        }
        assertEq(intake.count(), 0);
        _buy(alice);
    }

    function testPoolAndTemplateConfigurationBoundariesAreAtomic() public {
        uint256 version = buyer.configurationVersion();
        vm.startPrank(admin);
        vm.expectRevert(WebsiteBuyer.InvalidAddress.selector);
        buyer.setPool(IPoolManager(address(0)), address(0), 3000, 60, IHooks(address(0)), "");
        vm.expectRevert(WebsiteBuyer.InvalidPool.selector);
        buyer.setPool(IPoolManager(address(manager)), address(0), 3000, 32768, IHooks(address(0)), "");
        vm.expectRevert(WebsiteBuyer.InvalidPool.selector);
        buyer.setPool(IPoolManager(address(manager)), address(0), 3000, -1, IHooks(address(0)), "");
        vm.expectRevert(WebsiteBuyer.InvalidPool.selector);
        buyer.setPool(IPoolManager(address(manager)), address(0), 0x800000, 60, IHooks(address(0)), "");
        vm.expectRevert(WebsiteBuyer.InvalidPool.selector);
        buyer.setPool(IPoolManager(address(manager)), address(0), 3000, 60, IHooks(address(0)), new bytes(4097));
        vm.expectRevert(JsonText.InvalidText.selector);
        buyer.setTemplate(0, _repeat("a", 2001), "build-website", true, true);
        vm.expectRevert(JsonText.InvalidText.selector);
        buyer.setTemplate(0, "", "", true, true);
        vm.expectRevert(JsonText.InvalidText.selector);
        buyer.setTemplate(0, "", _repeat("a", 129), true, true);
        vm.stopPrank();
        assertEq(buyer.configurationVersion(), version);
        assertEq(buyer.templateOf(0).skill, "build-website");
        _buy(alice);
    }

    function testMaximumTemplateAndWordLengthsProduceParseableBoundedJSON() public {
        string memory prefix = _repeat("p", 2000);
        string memory skill = _repeat("s", 128);
        string memory words = _repeat("w", 2000);
        vm.prank(admin);
        buyer.setTemplate(type(uint256).max, prefix, skill, false, true);
        string memory body = string(buyer.bodyOf(type(uint256).max, alice, words));
        assertEq(vm.parseJsonString(body, ".objective"), string.concat(prefix, words));
        assertEq(vm.parseJsonString(body, ".skill"), skill);
        assertEq(vm.parseJsonString(body, ".owner"), Strings.toHexString(alice));
        assertFalse(vm.parseJsonBool(body, ".host"));
        assertLt(bytes(body).length, 16_384);
        vm.expectRevert(WebsiteBuyer.InvalidAddress.selector);
        buyer.bodyOf(0, address(0), "site");
    }

    function testWrappedRouteCannotSpendPreexistingWrappedTokensOrForcedETH() public {
        MockWETH weth = new MockWETH();
        _route(address(weth));
        weth.mint(address(buyer), 5 ether);
        vm.deal(address(buyer), 7 ether);
        _buy(alice);
        assertEq(weth.balanceOf(address(buyer)), 5 ether);
        assertEq(address(buyer).balance, 7 ether);
        assertEq(weth.balanceOf(address(manager)), FEE);
        assertEq(weth.allowance(address(buyer), address(manager)), 0);
    }

    function testShortWrapperMintCannotBeSubsidizedByOldBalance() public {
        ShortMintWrapper wrapper = new ShortMintWrapper();
        wrapper.mint(address(buyer), 1 ether);
        _route(address(wrapper));
        WebsiteBuyer.Purchase memory quote = _quote();
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.IncorrectTokenMovement.selector);
        buyer.buyWebsite{value: FEE}("a site", quote);
        assertEq(wrapper.balanceOf(address(buyer)), 1 ether);
        assertEq(address(wrapper).balance, 0);
        assertEq(manager.swaps(), 0);
        assertEq(alice.balance, 100 ether);
    }

    function testWrongSettlementReceiptRevertsNativeAndWrappedPayments() public {
        MockWETH weth = new MockWETH();
        for (uint256 i; i < 2; ++i) {
            _route(i == 0 ? address(0) : address(weth));
            vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.settle.selector), abi.encode(FEE - 1));
            WebsiteBuyer.Purchase memory quote = _quote();
            vm.prank(alice);
            vm.expectRevert(WebsiteBuyer.IncorrectTokenMovement.selector);
            buyer.buyWebsite{value: FEE}("site", quote);
            vm.clearMockedCalls();
            assertEq(address(manager).balance, 0);
            assertEq(weth.balanceOf(address(manager)), 0);
            assertEq(address(weth).balance, 0);
            assertEq(manager.swaps(), 0);
            assertEq(intake.count(), 0);
            assertEq(alice.balance, 100 ether);
        }
        _buy(alice);
        assertEq(weth.balanceOf(address(manager)), FEE);
    }

    function testFuzzEveryDependencyMustHaveCode(uint8 dependency) public {
        address missing = makeAddr("dependency without code");
        uint256 choice = dependency % 4;
        vm.startPrank(admin);
        if (choice == 0) {
            buyer.setIntake(IIntake(missing));
        } else if (choice == 1) {
            buyer.setIMD(missing);
            buyer.setPool(IPoolManager(address(manager)), address(0), 3000, 60, IHooks(address(0)), "");
        } else if (choice == 2) {
            buyer.setPool(IPoolManager(missing), address(0), 3000, 60, IHooks(address(0)), "");
        } else {
            buyer.setPool(IPoolManager(address(manager)), missing, 3000, 60, IHooks(address(0)), "");
        }
        vm.stopPrank();
        WebsiteBuyer.Purchase memory quote = _quote();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.DependencyHasNoCode.selector, missing));
        buyer.buyWebsite{value: FEE}("a site", quote);
        assertEq(intake.count(), 0);
        assertEq(alice.balance, 100 ether);
    }

    function testFuzzInvalidFailureStatusCannotSettle(uint8 status) public {
        // Generate every invalid uint8 status without discarding runs.
        status = status % 254;
        if (status != 0) status += 2;
        bytes32 id = _buy(alice);
        vm.prank(address(intake));
        vm.expectRevert(WebsiteBuyer.InvalidFailureStatus.selector);
        buyer.onIntakeFailure(id, status, "invalid", 0, 0, "");
        assertEq(uint8(buyer.requestOf(address(intake), id).state), uint8(WebsiteBuyer.State.Pending));
        vm.prank(writer);
        assertTrue(intake.complete(id, 0, keccak256("real result"), "ipfs://real", 0));
        assertEq(buyer.requestOf(address(intake), id).resultHash, keccak256("real result"));
    }
}
