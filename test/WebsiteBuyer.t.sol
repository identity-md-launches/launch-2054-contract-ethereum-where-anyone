// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {WebsiteBuyer} from "../src/WebsiteBuyer.sol";
import {IntakeAccount} from "../src/IntakeAccount.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {JsonText} from "../src/libraries/JsonText.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {MockToken, MockWETH, NoReturnIMD} from "./mocks/MockToken.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

contract WebsiteBuyerTest is Test {
    uint256 internal constant ETH_PRICE = 0.003 ether;
    uint256 internal constant IMD_PRICE = 0.5 ether;
    bytes32 internal constant JOB_OPEN = bytes32("job.open@job-1");
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal writer = makeAddr("writer");
    address internal treasury = makeAddr("treasury");
    WebsiteBuyer internal buyer;
    MockToken internal imd;
    MockIntake internal intake;
    MockPoolManager internal manager;

    event WebsiteResult(
        bytes32 indexed requestId, address indexed user, address indexed intake, bytes32 resultHash, string uri
    );
    event WebsiteFailed(
        bytes32 indexed requestId, address indexed user, address indexed intake, uint8 status, bytes32 reason
    );

    function setUp() public {
        imd = new MockToken(18);
        intake = new MockIntake(treasury, writer);
        manager = new MockPoolManager();
        buyer = new WebsiteBuyer(owner, intake, address(imd));
        intake.setPrice(JOB_OPEN, address(imd), IMD_PRICE);
        imd.mint(address(manager), 1000 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        _configurePool(address(0));
    }

    function _configurePool(address input) internal {
        vm.prank(owner);
        buyer.setPool(IPoolManager(address(manager)), input, 3000, 60, IHooks(address(0)), "");
    }

    function _purchase() internal view returns (WebsiteBuyer.Purchase memory) {
        return WebsiteBuyer.Purchase(0, IMD_PRICE, IMD_PRICE, block.timestamp + 300, buyer.configurationVersion());
    }

    function _buy(address user) internal returns (bytes32 id) {
        WebsiteBuyer.Purchase memory p = _purchase();
        uint256 price = buyer.ethPrice();
        vm.prank(user);
        id = buyer.buyWebsite{value: price}("a bakery in Lisbon", p);
    }

    function _state(bytes32 id) internal view returns (WebsiteBuyer.State) {
        return buyer.requestOf(address(intake), id).state;
    }

    function testPurchasePaysExactLivePriceAndRetainsSurplus() public {
        bytes32 id = _buy(alice);
        IntakeAccount account = buyer.accountOf(alice);
        MockIntake.Ask memory ask = intake.askOf(id);
        assertEq(ask.payer, address(account));
        assertEq(account.user(), alice);
        assertEq(account.hub(), address(buyer));
        assertEq(ask.action, JOB_OPEN);
        assertEq(ask.asset, address(imd));
        assertEq(ask.amount, IMD_PRICE);
        assertEq(ask.callback.target, address(buyer));
        assertEq(ask.callback.selector, buyer.onIntakeResult.selector);
        assertEq(ask.onFailure, buyer.onIntakeFailure.selector);
        assertEq(imd.balanceOf(treasury), IMD_PRICE);
        assertEq(imd.balanceOf(address(buyer)), 0.5 ether);
        assertEq(imd.balanceOf(address(account)), 0);
        assertEq(imd.balanceOf(address(intake)), 0);
        assertEq(imd.allowance(address(account), address(intake)), 0);
        assertEq(imd.allowance(address(buyer), address(manager)), 0);
        assertEq(address(buyer).balance, 0);
        assertEq(address(manager).balance, ETH_PRICE);
        assertEq(alice.balance, 10 ether - ETH_PRICE);
        WebsiteBuyer.Request memory r = buyer.requestOf(address(intake), id);
        assertEq(r.user, alice);
        assertEq(uint8(r.state), uint8(WebsiteBuyer.State.Pending));
        assertEq(r.imdPaid, IMD_PRICE);
        assertEq(r.asset, address(imd));
        assertEq(r.bodyHash, keccak256(ask.body));
    }

    function testDefaultBodyIncludesCallerOwnerAndCannotNameSomeoneElse() public {
        bytes memory expected = abi.encodePacked(
            '{"objective":"Build a one-page website: a bakery in Lisbon","skill":"build-website","host":true,"owner":"',
            Strings.toHexString(alice),
            '"}'
        );
        assertEq(buyer.bodyOf(0, alice, "a bakery in Lisbon"), expected);
        bytes32 id = _buy(alice);
        assertEq(intake.askOf(id).body, expected);
    }

    function testDifferentUsersHaveSeparateStablePayers() public {
        bytes32 first = _buy(alice);
        bytes32 second = _buy(alice);
        bytes32 third = _buy(bob);
        address account = address(buyer.accountOf(alice));
        assertEq(intake.askOf(first).payer, intake.askOf(second).payer);
        assertNotEq(account, intake.askOf(third).payer);
        assertNotEq(account, address(buyer));
        bytes32 initHash = keccak256(abi.encodePacked(type(IntakeAccount).creationCode, abi.encode(alice)));
        assertEq(account, vm.computeCreate2Address(bytes32(uint256(uint160(alice))), initHash, address(buyer)));
    }

    function testAUserCanContinueOnlyTheirOwnProjectThroughAccount() public {
        bytes32 first = _buy(alice);
        _buy(bob);
        IntakeAccount aliceAccount = buyer.accountOf(alice);
        IntakeAccount bobAccount = buyer.accountOf(bob);
        vm.prank(alice);
        bytes memory result = aliceAccount.execute(address(intake), 0, abi.encodeCall(intake.continueProject, (first)));
        assertEq(abi.decode(result, (address)), address(aliceAccount));
        vm.prank(bob);
        vm.expectRevert("wrong project payer");
        bobAccount.execute(address(intake), 0, abi.encodeCall(intake.continueProject, (first)));
        vm.prank(bob);
        vm.expectRevert(IntakeAccount.NotUser.selector);
        aliceAccount.execute(address(intake), 0, abi.encodeCall(intake.continueProject, (first)));
        vm.prank(owner);
        vm.expectRevert(IntakeAccount.NotUser.selector);
        aliceAccount.execute(owner, 0, "");
    }

    function testOnlyHubCanAskAndOnlyUserCanRecoverAccountFunds() public {
        _buy(alice);
        IntakeAccount account = buyer.accountOf(alice);
        vm.expectRevert(IntakeAccount.NotHub.selector);
        account.ask(
            intake,
            JOB_OPEN,
            "{}",
            IIntake.Callback(address(buyer), buyer.onIntakeResult.selector),
            buyer.onIntakeFailure.selector,
            address(imd),
            IMD_PRICE
        );
        vm.deal(address(account), 1 ether);
        imd.mint(address(account), 2 ether);
        vm.startPrank(alice);
        account.execute(alice, 1 ether, "");
        account.execute(address(imd), 0, abi.encodeCall(imd.transfer, (alice, 2 ether)));
        vm.stopPrank();
        assertEq(alice.balance, 11 ether - ETH_PRICE);
        assertEq(imd.balanceOf(alice), 2 ether);
    }

    function testResultStoresHashURIAndEmitsUnderStipend() public {
        bytes32 id = _buy(alice);
        bytes32 hash = keccak256("canonical result.json bytes");
        string memory uri = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/result.json";
        vm.expectEmit(true, true, true, true, address(buyer));
        emit WebsiteResult(id, alice, address(intake), hash, uri);
        vm.cool(address(buyer));
        vm.prank(writer);
        assertTrue(intake.complete(id, 0, hash, uri, 0));
        WebsiteBuyer.Request memory r = buyer.requestOf(address(intake), id);
        assertEq(uint8(r.state), uint8(WebsiteBuyer.State.Done));
        assertEq(r.resultHash, hash);
        assertEq(r.uri, uri);
        assertEq(imd.balanceOf(treasury), IMD_PRICE);
        assertEq(imd.balanceOf(address(buyer)), 0.5 ether);
    }

    function testMaximumURIStoresUnder200000Gas() public {
        bytes32 id = _buy(alice);
        bytes memory uri = new bytes(buyer.MAX_RESULT_URI_BYTES());
        for (uint256 i; i < uri.length; ++i) {
            uri[i] = "a";
        }
        vm.cool(address(buyer));
        vm.prank(writer);
        assertTrue(intake.complete(id, 0, keccak256("result"), string(uri), 0));
        assertEq(buyer.requestOf(address(intake), id).uri, string(uri));
    }

    function testOversizedURIIsNotStoredAndMissingCallbackNeverBlocksPurchases() public {
        bytes32 id = _buy(alice);
        vm.prank(writer);
        assertFalse(intake.complete(id, 0, keccak256("result"), string(new bytes(193)), 0));
        assertEq(uint8(_state(id)), uint8(WebsiteBuyer.State.Pending));
        assertNotEq(_buy(alice), id);
    }

    function testRefusalAndFailureSpendThePriceWithoutRefund() public {
        for (uint8 status = 1; status <= 2; ++status) {
            bytes32 id = _buy(alice);
            bytes32 reason = status == 1 ? bytes32("admission_refused") : bytes32("failed");
            vm.expectEmit(true, true, true, true, address(buyer));
            emit WebsiteFailed(id, alice, address(intake), status, reason);
            vm.prank(writer);
            assertTrue(intake.complete(id, status, 0, "", reason));
            WebsiteBuyer.Request memory r = buyer.requestOf(address(intake), id);
            assertEq(uint8(r.state), uint8(WebsiteBuyer.State.Failed));
            assertEq(r.failureStatus, status);
            assertEq(r.failureReason, reason);
        }
        assertEq(imd.balanceOf(treasury), 1 ether);
        assertEq(alice.balance, 10 ether - 2 * ETH_PRICE);
    }

    function testCallbacksRejectWrongSenderUnknownAndDuplicateInBothDirections() public {
        bytes32 id = _buy(alice);
        vm.expectRevert(WebsiteBuyer.NotPending.selector);
        buyer.onIntakeResult(id, 0, "");
        vm.expectRevert(WebsiteBuyer.NotPending.selector);
        buyer.onIntakeFailure(id, 1, "bad", 0, 0, "");
        vm.startPrank(address(intake));
        vm.expectRevert(WebsiteBuyer.NotPending.selector);
        buyer.onIntakeResult("unknown", 0, "");
        vm.expectRevert(WebsiteBuyer.NotPending.selector);
        buyer.onIntakeFailure("unknown", 1, "bad", 0, 0, "");
        vm.expectRevert(WebsiteBuyer.InvalidFailureStatus.selector);
        buyer.onIntakeFailure(id, 0, "bad", 0, 0, "");
        buyer.onIntakeResult(id, keccak256("result"), "ipfs://result");
        vm.expectRevert(WebsiteBuyer.NotPending.selector);
        buyer.onIntakeResult(id, 0, "");
        vm.expectRevert(WebsiteBuyer.NotPending.selector);
        buyer.onIntakeFailure(id, 2, "failed", 0, 0, "");
        vm.stopPrank();
        bytes32 failed = _buy(bob);
        vm.startPrank(address(intake));
        buyer.onIntakeFailure(failed, 1, "refused", 0, 0, "");
        vm.expectRevert(WebsiteBuyer.NotPending.selector);
        buyer.onIntakeResult(failed, 0, "");
        vm.expectRevert(WebsiteBuyer.NotPending.selector);
        buyer.onIntakeFailure(failed, 1, "refused", 0, 0, "");
        vm.stopPrank();
    }

    function testIntakeMigrationPreservesOldCallbacksAndNamespacesIdenticalIds() public {
        bytes32 shared = keccak256("same raw id on two Intakes");
        intake.setForcedId(shared);
        _buy(alice);
        MockIntake next = new MockIntake(treasury, writer);
        next.setPrice(JOB_OPEN, address(imd), IMD_PRICE);
        next.setForcedId(shared);
        vm.prank(owner);
        buyer.setIntake(next);
        assertEq(_buy(bob), shared);
        vm.prank(writer);
        assertTrue(next.complete(shared, 0, keccak256("bob"), "ipfs://bob", 0));
        assertEq(uint8(_state(shared)), uint8(WebsiteBuyer.State.Pending));
        vm.prank(writer);
        assertTrue(intake.complete(shared, 0, keccak256("alice"), "ipfs://alice", 0));
        assertEq(buyer.requestOf(address(intake), shared).uri, "ipfs://alice");
        assertEq(buyer.requestOf(address(next), shared).uri, "ipfs://bob");
    }

    function testDuplicateIdFromSameIntakeRevertsEntireSecondPurchase() public {
        intake.setForcedId(keccak256("duplicate"));
        bytes32 id = _buy(alice);
        WebsiteBuyer.Purchase memory p = _purchase();
        vm.prank(bob);
        vm.expectRevert(WebsiteBuyer.DuplicateRequest.selector);
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        assertEq(intake.count(), 1);
        assertEq(manager.swaps(), 1);
        assertEq(imd.balanceOf(treasury), IMD_PRICE);
        assertEq(buyer.requestOf(address(intake), id).user, alice);
        assertEq(address(buyer.accountOf(bob)), address(0));
        assertEq(bob.balance, 10 ether);
    }

    function testWrongPaymentsExpiredDeadlineAndStaleConfiguration() public {
        WebsiteBuyer.Purchase memory p = _purchase();
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.IncorrectETH.selector, ETH_PRICE, ETH_PRICE - 1));
        buyer.buyWebsite{value: ETH_PRICE - 1}("x", p);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.IncorrectETH.selector, ETH_PRICE, ETH_PRICE + 1));
        buyer.buyWebsite{value: ETH_PRICE + 1}("x", p);
        vm.warp(p.deadline + 1);
        vm.expectRevert(WebsiteBuyer.Expired.selector);
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        vm.stopPrank();
        p.deadline = block.timestamp + 300;
        vm.prank(owner);
        buyer.setTemplate(0, "New objective: ", "build-website", true, true);
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.ConfigurationChanged.selector);
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        assertEq(manager.swaps(), 0);
    }

    function testDeadlineBoundaryAndChangedETHPrice() public {
        vm.prank(owner);
        buyer.setETHPrice(0.004 ether);
        WebsiteBuyer.Purchase memory p = _purchase();
        vm.warp(p.deadline);
        vm.prank(alice);
        buyer.buyWebsite{value: 0.004 ether}("x", p);
        assertEq(address(manager).balance, 0.004 ether);
    }

    function testLivePriceIncreaseAndCallerMaximum() public {
        intake.setPrice(JOB_OPEN, address(imd), 0.75 ether);
        WebsiteBuyer.Purchase memory p = _purchase();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.IntakePriceExceeded.selector, 0.75 ether, IMD_PRICE));
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        p.maxIntakePrice = 0.75 ether;
        vm.prank(alice);
        bytes32 id = buyer.buyWebsite{value: ETH_PRICE}("x", p);
        assertEq(intake.askOf(id).amount, 0.75 ether);
        assertEq(imd.balanceOf(address(buyer)), 0.25 ether);
    }

    function testAtLeastHalfIMDIsBoughtEvenWhenLivePriceFalls() public {
        intake.setPrice(JOB_OPEN, address(imd), 0.25 ether);
        manager.setAmountOut(IMD_PRICE - 1);
        WebsiteBuyer.Purchase memory p = _purchase();
        p.minImdOut = 0;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.InsufficientOutput.selector, IMD_PRICE - 1, IMD_PRICE));
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        manager.setAmountOut(IMD_PRICE);
        _buy(alice);
        assertEq(imd.balanceOf(address(buyer)), 0.25 ether);
    }

    function testShortSwapCannotUseOldSurplusAndRollsBackEverything() public {
        imd.mint(address(buyer), 50 ether);
        manager.setAmountOut(IMD_PRICE - 1);
        WebsiteBuyer.Purchase memory p = _purchase();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.InsufficientOutput.selector, IMD_PRICE - 1, IMD_PRICE));
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        assertEq(imd.balanceOf(address(buyer)), 50 ether);
        assertEq(imd.balanceOf(treasury), 0);
        assertEq(alice.balance, 10 ether);
        assertEq(manager.swaps(), 0);
        assertEq(intake.count(), 0);
        assertEq(address(buyer.accountOf(alice)), address(0));
    }

    function testCallerSlippageAndLiveIntakePriceAreBothFloors() public {
        WebsiteBuyer.Purchase memory p = _purchase();
        p.minImdOut = 1.1 ether;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.InsufficientOutput.selector, 1 ether, 1.1 ether));
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        p.minImdOut = 0;
        p.maxIntakePrice = 1.1 ether;
        intake.setPrice(JOB_OPEN, address(imd), 1.1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.InsufficientOutput.selector, 1 ether, 1.1 ether));
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
    }

    function testIntakeRevertAndIncorrectPullRevertSwapAndAccountCreation() public {
        WebsiteBuyer.Purchase memory p = _purchase();
        intake.setReject(true);
        vm.prank(alice);
        vm.expectRevert("intake unavailable");
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        intake.setReject(false);
        intake.setSkipPull(true);
        vm.prank(alice);
        vm.expectRevert(IntakeAccount.IncorrectPayment.selector);
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        assertEq(manager.swaps(), 0);
        assertEq(address(manager).balance, 0);
        assertEq(intake.count(), 0);
        assertEq(address(buyer.accountOf(alice)), address(0));
        assertEq(alice.balance, 10 ether);
    }

    function testUnpricedActionAndUnconfiguredPoolAndPause() public {
        intake.setPrice(JOB_OPEN, address(imd), 0);
        WebsiteBuyer.Purchase memory p = _purchase();
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.ActionNotSold.selector);
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        vm.prank(owner);
        buyer.setIMD(address(imd));
        p = _purchase();
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.PoolNotConfigured.selector);
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        _configurePool(address(0));
        intake.setPrice(JOB_OPEN, address(imd), IMD_PRICE);
        vm.prank(owner);
        buyer.setPaused(true);
        p = _purchase();
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.Paused.selector);
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        vm.prank(owner);
        buyer.setPaused(false);
        _buy(alice);
    }

    function testWordsRejectInjectionControlsEmptyOversizeAndMalformedUTF8() public {
        bytes[] memory invalid = new bytes[](11);
        invalid[0] = bytes('site","owner":"someone');
        invalid[1] = bytes("back\\slash");
        invalid[2] = bytes("new\nline");
        invalid[3] = bytes("");
        invalid[4] = new bytes(2001);
        invalid[5] = hex"c080";
        invalid[6] = hex"eda080";
        invalid[7] = hex"f4908080";
        invalid[8] = hex"e282";
        invalid[9] = hex"80";
        invalid[10] = hex"61ff62";
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(JsonText.InvalidText.selector);
            buyer.bodyOf(0, alice, string(invalid[i]));
        }
        buyer.bodyOf(0, alice, unicode"Café menu, prices in € 🍰");
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.UnknownTemplate.selector, 99));
        buyer.bodyOf(99, alice, "x");
    }

    function testOwnerTemplatesHaveExactBodiesAndCanBeDisabled() public {
        vm.prank(owner);
        buyer.setTemplate(1, "Design: ", "build-website", false, true);
        bytes memory expected = abi.encodePacked(
            '{"objective":"Design: hello","skill":"build-website","host":false,"owner":"',
            Strings.toHexString(bob),
            '"}'
        );
        assertEq(buyer.bodyOf(1, bob, "hello"), expected);
        WebsiteBuyer.Purchase memory p = _purchase();
        p.templateId = 1;
        vm.prank(bob);
        bytes32 id = buyer.buyWebsite{value: ETH_PRICE}("hello", p);
        assertEq(intake.askOf(id).body, expected);
        vm.prank(owner);
        buyer.setTemplate(1, "Design: ", "build-website", false, false);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.UnknownTemplate.selector, 1));
        buyer.bodyOf(1, bob, "hello");
    }

    function testSwapRejectsPartialInputOverspendAndInvalidCallbacks() public {
        WebsiteBuyer.Purchase memory p = _purchase();
        for (int256 adjustment = -1; adjustment <= 1; adjustment += 2) {
            manager.setAdjustment(adjustment);
            vm.prank(alice);
            vm.expectRevert(WebsiteBuyer.IncompleteSwap.selector);
            buyer.buyWebsite{value: ETH_PRICE}("x", p);
        }
        manager.setAdjustment(0);
        vm.expectRevert(WebsiteBuyer.UnexpectedCallback.selector);
        buyer.unlockCallback(abi.encode(ETH_PRICE, IMD_PRICE));
        vm.prank(address(manager));
        vm.expectRevert(WebsiteBuyer.UnexpectedCallback.selector);
        buyer.unlockCallback(abi.encode(ETH_PRICE, IMD_PRICE));
        for (uint256 i; i < 3; ++i) {
            manager.setModes(i == 0, i == 1, i == 2, false);
            vm.prank(alice);
            vm.expectRevert(WebsiteBuyer.UnexpectedCallback.selector);
            buyer.buyWebsite{value: ETH_PRICE}("x", p);
        }
        manager.setModes(false, false, false, true);
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.IncorrectTokenMovement.selector);
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
    }

    function testReentrancyDuringSwapAndIntakeCannotBuyAgain() public {
        WebsiteBuyer.Purchase memory p = _purchase();
        bytes memory data = abi.encodeCall(buyer.buyWebsite, ("reentry", p));
        manager.setAttack(address(buyer), data);
        intake.setAttack(address(buyer), data);
        _buy(alice);
        assertFalse(manager.attackSucceeded());
        assertEq(manager.attackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertFalse(intake.attackSucceeded());
        assertEq(intake.attackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(intake.count(), 1);
    }

    function testFeeOnTransferAndFalseReturningTokensRevert() public {
        WebsiteBuyer.Purchase memory p = _purchase();
        imd.setTax(100);
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.IncorrectTokenMovement.selector);
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        imd.setTax(0);
        imd.setReturnsFalse(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
        assertEq(alice.balance, 10 ether);
        assertEq(imd.balanceOf(treasury), 0);
    }

    function testWrappedETHRouteSpendsFullPayment() public {
        MockWETH weth = new MockWETH();
        _configurePool(address(weth));
        _buy(alice);
        assertEq(weth.balanceOf(address(manager)), ETH_PRICE);
        assertEq(weth.balanceOf(address(buyer)), 0);
        assertEq(address(weth).balance, ETH_PRICE);
        assertEq(address(buyer).balance, 0);
        assertEq(manager.lastZeroForOne(), address(weth) < address(imd));
        assertEq(imd.balanceOf(treasury), IMD_PRICE);
    }

    function testTokenWithNoReturnValuesIsPaidWithNoResidualApproval() public {
        NoReturnIMD token = new NoReturnIMD();
        vm.prank(owner);
        buyer.setIMD(address(token));
        _configurePool(address(0));
        token.mint(address(manager), 10 ether);
        intake.setPrice(JOB_OPEN, address(token), IMD_PRICE);
        _buy(alice);
        assertEq(token.balanceOf(treasury), IMD_PRICE);
        assertEq(token.balanceOf(address(buyer)), 0.5 ether);
        assertEq(token.balanceOf(address(buyer.accountOf(alice))), 0);
        assertEq(token.allowance(address(buyer.accountOf(alice)), address(intake)), 0);
    }

    function testOwnerContractCannotRetargetConfigurationDuringSwap() public {
        vm.prank(owner);
        buyer.transferOwnership(address(manager));
        vm.prank(address(manager));
        buyer.acceptOwnership();
        manager.setAttack(address(buyer), abi.encodeCall(buyer.setIntake, (IIntake(bob))));
        uint256 version = buyer.configurationVersion();
        _buy(alice);
        assertFalse(manager.attackSucceeded());
        assertEq(manager.attackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(address(buyer.intake()), address(intake));
        assertEq(buyer.configurationVersion(), version);
    }

    function testAccountCannotExecuteReentrantlyEvenWhenUserIsIntake() public {
        address user = address(intake);
        bytes32 initHash = keccak256(abi.encodePacked(type(IntakeAccount).creationCode, abi.encode(user)));
        address account = vm.computeCreate2Address(bytes32(uint256(uint160(user))), initHash, address(buyer));
        intake.setAttack(account, abi.encodeCall(IntakeAccount.execute, (bob, 0, bytes(""))));
        vm.deal(user, 1 ether);
        _buy(user);
        assertEq(address(buyer.accountOf(user)), account);
        assertFalse(intake.attackSucceeded());
        assertEq(intake.attackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function testFuzzInjectedJSONSyntaxCannotReachSwap(uint8 which, uint16 position) public {
        bytes memory words = bytes("a perfectly ordinary one page website");
        uint256 at = bound(uint256(position), 0, words.length - 1);
        uint8 c = uint8(bound(uint256(which), 0, 33));
        words[at] = c < 32 ? bytes1(c) : (c == 32 ? bytes1(0x22) : bytes1(0x5c));
        WebsiteBuyer.Purchase memory p = _purchase();
        vm.prank(alice);
        vm.expectRevert(JsonText.InvalidText.selector);
        buyer.buyWebsite{value: ETH_PRICE}(string(words), p);
        assertEq(manager.swaps(), 0);
        assertEq(intake.count(), 0);
        assertEq(alice.balance, 10 ether);
    }

    function testTokenMigrationRequiresNewPoolAndUnsupportedDecimalsFail() public {
        MockToken replacement = new MockToken(18);
        vm.prank(owner);
        buyer.setIMD(address(replacement));
        assertFalse(buyer.poolConfigured());
        _configurePool(address(0));
        intake.setPrice(JOB_OPEN, address(replacement), IMD_PRICE);
        replacement.mint(address(manager), 10 ether);
        _buy(alice);
        assertEq(replacement.balanceOf(treasury), IMD_PRICE);
        MockToken wrong = new MockToken(6);
        vm.prank(owner);
        buyer.setIMD(address(wrong));
        _configurePool(address(0));
        WebsiteBuyer.Purchase memory p = _purchase();
        vm.prank(bob);
        vm.expectRevert(WebsiteBuyer.UnsupportedDecimals.selector);
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
    }

    function testOnlyOwnerCanConfigureAndOwnershipUsesTwoSteps() public {
        vm.startPrank(alice);
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.expectRevert(unauthorized);
        buyer.setETHPrice(1 ether);
        vm.expectRevert(unauthorized);
        buyer.setIntake(intake);
        vm.expectRevert(unauthorized);
        buyer.setIMD(address(imd));
        vm.expectRevert(unauthorized);
        buyer.setAction(JOB_OPEN);
        vm.expectRevert(unauthorized);
        buyer.setTemplate(0, "x", "build-website", true, true);
        vm.expectRevert(unauthorized);
        buyer.setPool(IPoolManager(address(manager)), address(0), 3000, 60, IHooks(address(0)), "");
        vm.expectRevert(unauthorized);
        buyer.setPaused(true);
        vm.stopPrank();
        vm.prank(owner);
        buyer.transferOwnership(alice);
        assertEq(buyer.owner(), owner);
        assertEq(buyer.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        buyer.acceptOwnership();
        vm.prank(alice);
        buyer.acceptOwnership();
        assertEq(buyer.owner(), alice);
    }

    function testInvalidAdminSettingsAndMissingCode() public {
        vm.startPrank(owner);
        vm.expectRevert(WebsiteBuyer.InvalidPrice.selector);
        buyer.setETHPrice(0);
        vm.expectRevert(WebsiteBuyer.InvalidPrice.selector);
        buyer.setETHPrice(type(uint256).max);
        vm.expectRevert(WebsiteBuyer.InvalidAddress.selector);
        buyer.setIntake(IIntake(address(0)));
        vm.expectRevert(WebsiteBuyer.InvalidAddress.selector);
        buyer.setIMD(address(0));
        vm.expectRevert(WebsiteBuyer.InvalidAction.selector);
        buyer.setAction(0);
        vm.expectRevert(JsonText.InvalidText.selector);
        buyer.setTemplate(0, 'bad"', "build-website", true, true);
        vm.expectRevert(WebsiteBuyer.InvalidPool.selector);
        buyer.setPool(IPoolManager(address(manager)), address(imd), 3000, 60, IHooks(address(0)), "");
        vm.expectRevert(WebsiteBuyer.InvalidPool.selector);
        buyer.setPool(IPoolManager(address(manager)), address(0), 3000, 0, IHooks(address(0)), "");
        vm.expectRevert(WebsiteBuyer.InvalidPool.selector);
        buyer.setPool(IPoolManager(address(manager)), address(0), 1_000_001, 60, IHooks(address(0)), "");
        buyer.setIntake(IIntake(bob));
        vm.stopPrank();
        WebsiteBuyer.Purchase memory p = _purchase();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.DependencyHasNoCode.selector, bob));
        buyer.buyWebsite{value: ETH_PRICE}("x", p);
    }

    function testActionVersionCanBeUpdated() public {
        bytes32 next = bytes32("job.open@job-2");
        vm.prank(owner);
        buyer.setAction(next);
        intake.setPrice(next, address(imd), IMD_PRICE);
        bytes32 id = _buy(alice);
        assertEq(intake.askOf(id).action, next);
    }

    function testFuzzConservationAcrossPurchases(uint96 output, uint8 count) public {
        uint256 bought = bound(uint256(output), IMD_PRICE, 20 ether);
        uint256 n = bound(uint256(count), 1, 8);
        manager.setAmountOut(bought);
        for (uint256 i; i < n; ++i) {
            _buy(i % 2 == 0 ? alice : bob);
        }
        assertEq(imd.balanceOf(treasury), n * IMD_PRICE);
        assertEq(imd.balanceOf(address(buyer)), n * (bought - IMD_PRICE));
        assertEq(imd.balanceOf(address(manager)), 1000 ether - n * bought);
        assertEq(address(manager).balance, n * ETH_PRICE);
        assertEq(address(buyer).balance, 0);
        assertEq(imd.balanceOf(address(buyer.accountOf(alice))), 0);
        assertEq(imd.balanceOf(address(buyer.accountOf(bob))), 0);
    }

    function testFuzzValidWordsHaveExactBody(bytes32 seed, uint16 length) public view {
        uint256 n = bound(uint256(length), 1, 2000);
        bytes memory words = new bytes(n);
        for (uint256 i; i < n; ++i) {
            words[i] = bytes1(uint8(97 + uint8(seed[i % 32]) % 26));
        }
        bytes memory expected = abi.encodePacked(
            '{"objective":"Build a one-page website: ',
            words,
            '","skill":"build-website","host":true,"owner":"',
            Strings.toHexString(alice),
            '"}'
        );
        assertEq(buyer.bodyOf(0, alice, string(words)), expected);
    }
}
