// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {WebsiteBuyer} from "src/WebsiteBuyer.sol";
import {IntakeAccount} from "src/IntakeAccount.sol";
import {MockToken, MockWETH} from "../mocks/MockToken.sol";
import {MockIntake} from "../mocks/MockIntake.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @dev Only the explicitly selected actions are fuzz targets. Ghost amounts come from
/// operation inputs, never from the balance or request field being checked.
contract WebsiteBuyerHandler is Test {
    uint256 internal constant RESERVE = 1_000_000 ether;
    uint256 internal constant ACTOR_ETH = 1_000 ether;
    uint256 internal constant FLOOR = 0.5 ether;
    WebsiteBuyer public buyer;
    MockPoolManager public manager;
    MockWETH public weth;
    MockToken[2] public tokens;
    MockIntake[2] public intakes;
    address[4] public actors;
    address public treasury = makeAddr("invariant treasury");
    address public writer = makeAddr("invariant writer");
    uint256 public tokenIndex;
    uint256 public intakeIndex;
    uint256 public expectedVersion;
    uint256 public expectedFee = 0.003 ether;
    bool public expectedPaused;
    bool public expectedRoute = true;
    bool public expectedHost = true;
    bool public expectedEnabled = true;
    bool public wrapped;
    bytes32 public expectedAction = bytes32("job.open@job-1");

    uint256[2] public bought;
    uint256[2] public paid;
    uint256[2] public hubDonations;
    uint256[2] public accountMints;
    uint256 public nativeSpent;
    uint256 public wrappedSpent;
    uint256 public forcedETH;
    uint256 public successfulPurchases;
    uint256 public rejectedPurchases;
    uint256 public settlements;
    mapping(address => uint256) public userSpent;
    mapping(address => uint256) public userETHDeposited;
    mapping(address => uint256) public userETHWithdrawn;
    mapping(address => mapping(uint256 => uint256)) public accountDeposited;
    mapping(address => mapping(uint256 => uint256)) public accountWithdrawn;
    mapping(address => address) public expectedAccount;

    struct ExpectedRequest {
        address source;
        bytes32 id;
        address user;
        address asset;
        uint256 price;
        bytes32 bodyHash;
        WebsiteBuyer.State state;
        bytes32 resultHash;
        string uri;
        uint8 failureStatus;
        bytes32 failureReason;
    }
    ExpectedRequest[] internal requests;

    constructor() {
        manager = new MockPoolManager();
        weth = new MockWETH();
        for (uint256 i; i < 2; ++i) {
            tokens[i] = new MockToken(18);
            intakes[i] = new MockIntake(treasury, writer);
            tokens[i].mint(address(manager), RESERVE);
        }
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                intakes[i].setPrice(bytes32("job.open@job-1"), address(tokens[j]), FLOOR);
                intakes[i].setPrice(bytes32("job.open@job-2"), address(tokens[j]), FLOOR);
            }
        }
        buyer = new WebsiteBuyer(address(this), intakes[0], address(tokens[0]));
        _route();
        expectedVersion = 2;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("invariant user ", vm.toString(i)));
            vm.deal(actors[i], ACTOR_ETH);
        }
    }

    function _route() internal {
        buyer.setPool(
            IPoolManager(address(manager)), wrapped ? address(weth) : address(0), 3000, 60, IHooks(address(0)), ""
        );
    }

    function _quote(uint256 minimum) internal view returns (WebsiteBuyer.Purchase memory) {
        return WebsiteBuyer.Purchase(0, minimum, _price(), block.timestamp + 60, expectedVersion);
    }

    function _price() internal view returns (uint256) {
        return intakes[intakeIndex].priceOf(expectedAction, address(tokens[tokenIndex]));
    }

    function _disabledError() internal view returns (bytes memory) {
        if (expectedPaused) return abi.encodeWithSelector(WebsiteBuyer.Paused.selector);
        if (!expectedRoute) return abi.encodeWithSelector(WebsiteBuyer.PoolNotConfigured.selector);
        if (!expectedEnabled) return abi.encodeWithSelector(WebsiteBuyer.UnknownTemplate.selector, uint256(0));
        return "";
    }

    function buy(uint256 actorSeed, uint256 surplusSeed, uint256 minimumSeed) public {
        address user = actors[actorSeed % actors.length];
        uint256 price = _price();
        uint256 minimum = bound(minimumSeed, 0, 5 ether);
        uint256 output = FLOOR + price + minimum + bound(surplusSeed, 0, 10 ether);
        manager.setAmountOut(output);
        WebsiteBuyer.Purchase memory quote = _quote(minimum);
        bytes memory disabled = _disabledError();
        if (disabled.length != 0) {
            _expectRejected(user, quote, expectedFee, disabled);
            return;
        }
        string memory words = string.concat("website number ", vm.toString(successfulPurchases));
        bytes memory body = abi.encodePacked(
            '{"objective":"Build a one-page website: ',
            words,
            '","skill":"build-website","host":',
            expectedHost ? "true" : "false",
            ',"owner":"',
            Strings.toHexString(user),
            '"}'
        );
        vm.prank(user);
        bytes32 id = buyer.buyWebsite{value: expectedFee}(words, quote);
        MockIntake.Ask memory ask = intakes[intakeIndex].askOf(id);
        assertEq(ask.body, body, "paid body differs from selected template");
        assertEq(ask.action, expectedAction);
        assertEq(ask.asset, address(tokens[tokenIndex]));
        assertEq(ask.amount, price);
        assertEq(ask.callback.target, address(buyer));
        assertEq(ask.callback.selector, buyer.onIntakeResult.selector);
        assertEq(ask.onFailure, buyer.onIntakeFailure.selector);
        address account = address(buyer.accountOf(user));
        if (expectedAccount[user] == address(0)) {
            bytes32 initHash = keccak256(abi.encodePacked(type(IntakeAccount).creationCode, abi.encode(user)));
            expectedAccount[user] = vm.computeCreate2Address(bytes32(uint256(uint160(user))), initHash, address(buyer));
        }
        assertEq(account, expectedAccount[user]);
        assertEq(ask.payer, account);
        requests.push(
            ExpectedRequest({
                source: address(intakes[intakeIndex]),
                id: id,
                user: user,
                asset: address(tokens[tokenIndex]),
                price: price,
                bodyHash: keccak256(body),
                state: WebsiteBuyer.State.Pending,
                resultHash: 0,
                uri: "",
                failureStatus: 0,
                failureReason: 0
            })
        );
        bought[tokenIndex] += output;
        paid[tokenIndex] += price;
        userSpent[user] += expectedFee;
        if (wrapped) wrappedSpent += expectedFee;
        else nativeSpent += expectedFee;
        ++successfulPurchases;
    }

    /// @dev Each case asserts an exact rejection and no partial payment/account creation.
    function rejectPurchase(uint256 actorSeed, uint8 failureSeed) external {
        address user = actors[actorSeed % actors.length];
        uint256 price = _price();
        WebsiteBuyer.Purchase memory quote = _quote(0);
        manager.setAmountOut(FLOOR + price);
        uint256 value = expectedFee;
        bytes memory error = _disabledError();
        if (error.length == 0) {
            uint256 mode = failureSeed % 7;
            if (mode == 0) {
                uint256 minimum = price > FLOOR ? price : FLOOR;
                manager.setAmountOut(minimum - 1);
                error = abi.encodeWithSelector(WebsiteBuyer.InsufficientOutput.selector, minimum - 1, minimum);
            } else if (mode == 1) {
                value -= 1;
                error = abi.encodeWithSelector(WebsiteBuyer.IncorrectETH.selector, expectedFee, value);
            } else if (mode == 2) {
                quote.deadline = block.timestamp - 1;
                error = abi.encodeWithSelector(WebsiteBuyer.Expired.selector);
            } else if (mode == 3) {
                --quote.configurationVersion;
                error = abi.encodeWithSelector(WebsiteBuyer.ConfigurationChanged.selector);
            } else if (mode == 4) {
                quote.maxIntakePrice = price - 1;
                error = abi.encodeWithSelector(WebsiteBuyer.IntakePriceExceeded.selector, price, price - 1);
            } else if (mode == 5) {
                intakes[intakeIndex].setReject(true);
                error = abi.encodeWithSignature("Error(string)", "intake unavailable");
            } else {
                intakes[intakeIndex].setSkipPull(true);
                error = abi.encodeWithSelector(IntakeAccount.IncorrectPayment.selector);
            }
        }
        _expectRejected(user, quote, value, error);
        intakes[intakeIndex].setReject(false);
        intakes[intakeIndex].setSkipPull(false);
    }

    function _expectRejected(address user, WebsiteBuyer.Purchase memory quote, uint256 value, bytes memory error)
        internal
    {
        uint256 balance = user.balance;
        address account = address(buyer.accountOf(user));
        vm.prank(user);
        vm.expectRevert(error);
        buyer.buyWebsite{value: value}("a site", quote);
        assertEq(user.balance, balance, "failed purchase spent ETH");
        assertEq(address(buyer.accountOf(user)), account, "failed purchase created a payer");
        ++rejectedPurchases;
    }

    /// @dev Migrations remain separate actions, including the interval with a disabled route.
    function configure(uint8 choice, uint256 value) external {
        uint256 mode = choice % 9;
        if (mode == 0) {
            expectedFee = bound(value, 1, 0.1 ether);
            buyer.setETHPrice(expectedFee);
        } else if (mode == 1) {
            intakeIndex = value % 2;
            buyer.setIntake(intakes[intakeIndex]);
        } else if (mode == 2) {
            tokenIndex = value % 2;
            buyer.setIMD(address(tokens[tokenIndex]));
            expectedRoute = false;
        } else if (mode == 3) {
            wrapped = value % 2 == 1;
            _route();
            expectedRoute = true;
        } else if (mode == 4) {
            expectedPaused = value % 2 == 1;
            buyer.setPaused(expectedPaused);
        } else if (mode == 5) {
            expectedEnabled = value % 4 != 0;
            expectedHost = value % 2 == 1;
            buyer.setTemplate(0, "Build a one-page website: ", "build-website", expectedHost, expectedEnabled);
        } else if (mode == 6) {
            expectedAction = value % 2 == 0 ? bytes32("job.open@job-1") : bytes32("job.open@job-2");
            buyer.setAction(expectedAction);
        } else if (mode == 7) {
            intakes[intakeIndex].setPrice(expectedAction, address(tokens[tokenIndex]), bound(value, 1, 4 ether));
            return; // An external price change must not change the buyer's version.
        } else {
            vm.warp(block.timestamp + bound(value, 1, 7 days));
            return;
        }
        ++expectedVersion;
    }

    function settle(uint256 requestSeed, bool success, bytes32 result, uint8 statusSeed) public {
        ExpectedRequest storage r = requests[requestSeed % requests.length];
        if (r.state != WebsiteBuyer.State.Pending) {
            _rejectCallbacks(r, r.source);
            return;
        }
        string memory uri = string.concat("ipfs://", Strings.toHexString(uint256(result), 32), "/result.json");
        uint8 status = success ? 0 : uint8(1 + statusSeed % 2);
        bytes32 reason = status == 1 ? bytes32("admission_refused") : bytes32("failed");
        vm.cool(address(buyer));
        vm.prank(writer);
        assertTrue(
            MockIntake(r.source).complete(r.id, status, result, uri, reason), "callback exceeds stipend or reverts"
        );
        if (success) {
            r.state = WebsiteBuyer.State.Done;
            r.resultHash = result;
            r.uri = uri;
        } else {
            r.state = WebsiteBuyer.State.Failed;
            r.failureStatus = status;
            r.failureReason = reason;
        }
        ++settlements;
    }

    function forgeCallback(uint256 requestSeed, uint256 actorSeed) external {
        ExpectedRequest storage r = requests[requestSeed % requests.length];
        _rejectCallbacks(r, actors[actorSeed % actors.length]);
    }

    function _rejectCallbacks(ExpectedRequest storage r, address sender) internal {
        vm.startPrank(sender);
        vm.expectRevert(WebsiteBuyer.NotPending.selector);
        buyer.onIntakeResult(r.id, keccak256("forged"), "ipfs://forged");
        vm.expectRevert(WebsiteBuyer.NotPending.selector);
        buyer.onIntakeFailure(r.id, 1, "forged", 0, 0, "");
        vm.stopPrank();
    }

    function donate(uint256 actorSeed, uint256 assetSeed, uint96 amountSeed, bool toAccount) external {
        uint256 amount = bound(amountSeed, 1, 10 ether);
        uint256 asset = assetSeed % 2;
        address user = actors[actorSeed % actors.length];
        if (toAccount) {
            tokens[asset].mint(expectedAccount[user], amount);
            accountDeposited[user][asset] += amount;
            accountMints[asset] += amount;
        } else {
            tokens[asset].mint(address(buyer), amount);
            hubDonations[asset] += amount;
        }
    }

    function depositETH(uint256 actorSeed, uint96 amountSeed, bool forceToHub) external {
        uint256 amount = bound(amountSeed, 1, 1 ether);
        if (forceToHub) {
            // Model unsolicited ETH (e.g. SELFDESTRUCT) without executing that opcode.
            forcedETH += amount;
            vm.deal(address(buyer), address(buyer).balance + amount);
        } else {
            address user = actors[actorSeed % actors.length];
            vm.prank(user);
            (bool ok,) = expectedAccount[user].call{value: amount}("");
            assertTrue(ok);
            userETHDeposited[user] += amount;
        }
    }

    function withdrawAccount(uint256 actorSeed, uint256 assetSeed, uint256 amountSeed, bool eth) external {
        address user = actors[actorSeed % actors.length];
        IntakeAccount account = IntakeAccount(payable(expectedAccount[user]));
        if (eth) {
            uint256 amount = bound(amountSeed, 0, userETHDeposited[user] - userETHWithdrawn[user]);
            vm.prank(user);
            account.execute(user, amount, "");
            userETHWithdrawn[user] += amount;
        } else {
            uint256 asset = assetSeed % 2;
            uint256 amount = bound(amountSeed, 0, accountDeposited[user][asset] - accountWithdrawn[user][asset]);
            vm.prank(user);
            account.execute(address(tokens[asset]), 0, abi.encodeCall(tokens[asset].transfer, (user, amount)));
            accountWithdrawn[user][asset] += amount;
        }
    }

    function unauthorized(uint256 actorSeed, uint256 victimSeed) external {
        address caller = actors[actorSeed % actors.length];
        address victim = actors[(actorSeed % actors.length + 1 + victimSeed % 3) % actors.length];
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        buyer.setETHPrice(1);
        vm.expectRevert(IntakeAccount.NotUser.selector);
        IntakeAccount(payable(expectedAccount[victim])).execute(caller, 1, "");
        vm.stopPrank();
    }

    function checkConservation() external view {
        for (uint256 t; t < 2; ++t) {
            MockToken token = tokens[t];
            assertEq(token.balanceOf(address(buyer)), bought[t] - paid[t] + hubDonations[t], "surplus consumed or lost");
            assertEq(token.balanceOf(address(manager)), RESERVE - bought[t], "pool output mismatch");
            assertEq(token.balanceOf(treasury), paid[t], "price not forwarded exactly");
            uint256 accounted =
                token.balanceOf(address(buyer)) + token.balanceOf(address(manager)) + token.balanceOf(treasury);
            for (uint256 i; i < actors.length; ++i) {
                address user = actors[i];
                assertEq(token.balanceOf(expectedAccount[user]), accountDeposited[user][t] - accountWithdrawn[user][t]);
                assertEq(token.balanceOf(user), accountWithdrawn[user][t]);
                accounted += token.balanceOf(expectedAccount[user]) + token.balanceOf(user);
                for (uint256 j; j < 2; ++j) {
                    assertEq(token.allowance(expectedAccount[user], address(intakes[j])), 0, "residual payer approval");
                }
            }
            for (uint256 i; i < 2; ++i) {
                assertEq(token.balanceOf(address(intakes[i])), 0);
            }
            assertEq(accounted, RESERVE + hubDonations[t] + accountMints[t]);
            assertEq(token.totalSupply(), accounted);
        }
        assertEq(address(manager).balance, nativeSpent);
        assertEq(manager.paid(), nativeSpent + wrappedSpent);
        assertEq(manager.swaps(), successfulPurchases, "rejected call changed pool state");
        assertEq(address(buyer).balance, forcedETH, "preexisting ETH spent");
        assertEq(address(weth).balance, wrappedSpent);
        assertEq(weth.balanceOf(address(manager)), wrappedSpent);
        assertEq(weth.balanceOf(address(buyer)), 0);
        for (uint256 i; i < actors.length; ++i) {
            address user = actors[i];
            assertEq(user.balance, ACTOR_ETH - userSpent[user] - userETHDeposited[user] + userETHWithdrawn[user]);
            assertEq(expectedAccount[user].balance, userETHDeposited[user] - userETHWithdrawn[user]);
        }
    }

    function checkRequests() external view {
        assertEq(intakes[0].count() + intakes[1].count(), successfulPurchases, "phantom or missing request");
        assertEq(requests.length, successfulPurchases);
        for (uint256 i; i < requests.length; ++i) {
            ExpectedRequest storage expected = requests[i];
            WebsiteBuyer.Request memory actual = buyer.requestOf(expected.source, expected.id);
            assertEq(actual.user, expected.user);
            assertEq(actual.asset, expected.asset);
            assertEq(actual.imdPaid, expected.price);
            assertEq(actual.bodyHash, expected.bodyHash);
            assertEq(uint256(actual.state), uint256(expected.state), "illegal lifecycle transition");
            assertEq(actual.resultHash, expected.resultHash);
            assertEq(actual.uri, expected.uri);
            assertEq(actual.failureStatus, expected.failureStatus);
            assertEq(actual.failureReason, expected.failureReason);
        }
    }

    function checkConfigurationAndPayers() external view {
        assertEq(buyer.owner(), address(this));
        assertEq(buyer.ethPrice(), expectedFee);
        assertEq(buyer.configurationVersion(), expectedVersion);
        assertEq(address(buyer.intake()), address(intakes[intakeIndex]));
        assertEq(buyer.imd(), address(tokens[tokenIndex]));
        assertEq(buyer.paused(), expectedPaused);
        assertEq(buyer.poolConfigured(), expectedRoute);
        assertEq(buyer.action(), expectedAction);
        WebsiteBuyer.Template memory template = buyer.templateOf(0);
        assertEq(template.host, expectedHost);
        assertEq(template.enabled, expectedEnabled);
        for (uint256 i; i < actors.length; ++i) {
            IntakeAccount account = buyer.accountOf(actors[i]);
            assertEq(address(account), expectedAccount[actors[i]]);
            assertEq(account.user(), actors[i]);
            assertEq(account.hub(), address(buyer));
            for (uint256 j; j < i; ++j) {
                assertNotEq(address(account), expectedAccount[actors[j]]);
            }
        }
    }
}
