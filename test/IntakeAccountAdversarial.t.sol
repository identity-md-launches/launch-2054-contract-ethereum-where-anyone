// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IntakeAccount} from "src/IntakeAccount.sol";
import {WebsiteBuyer} from "src/WebsiteBuyer.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {BuyerTestBase} from "./helpers/BuyerTestBase.sol";

/// @dev Deliberately faulty external dependency; used to check atomic failure,
/// never as an oracle for the real Intake's admission or delivery behavior.
contract PaymentProbe is IIntake {
    using SafeERC20 for IERC20;
    address public immutable treasury;
    uint256 public amountToPull;
    uint256 public amountToReturn;
    uint256 public approvalSeen;
    uint256 public calls;
    bytes32 public requestId = keccak256("payment probe request");

    constructor(address treasury_, uint256 price) {
        treasury = treasury_;
        amountToPull = price;
    }

    function priceOf(bytes32, address) external pure returns (uint256) {
        return 0.5 ether;
    }

    function setBehavior(uint256 pull, uint256 giveBack, bytes32 id) external {
        amountToPull = pull;
        amountToReturn = giveBack;
        requestId = id;
    }

    function requestWithFailure(bytes32, bytes calldata, Callback calldata, bytes4, address asset, uint256)
        external
        payable
        returns (bytes32)
    {
        ++calls;
        approvalSeen = IERC20(asset).allowance(msg.sender, address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amountToPull);
        if (amountToReturn != 0) IERC20(asset).safeTransfer(msg.sender, amountToReturn);
        IERC20(asset).safeTransfer(treasury, IERC20(asset).balanceOf(address(this)));
        return requestId;
    }
}

contract ZeroFirstToken is MockToken {
    bool public refuseReset;

    constructor() MockToken(18) {}

    function setRefuseReset(bool value) external {
        refuseReset = value;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (amount == 0 && refuseReset) return false;
        require(amount == 0 || allowance(msg.sender, spender) == 0, "reset first");
        return super.approve(spender, amount);
    }
}

contract AccountTarget {
    error Refused(uint256 value);
    uint256 public calls;

    function echo(bytes calldata payload) external payable returns (bytes memory) {
        ++calls;
        return payload;
    }

    function reject(uint256 value) external payable {
        ++calls;
        revert Refused(value);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract IntakeAccountAdversarialTest is Test {
    uint256 internal constant PRICE = 0.5 ether;
    address internal user = makeAddr("account user");
    address internal stranger = makeAddr("account stranger");
    address internal treasury = makeAddr("account treasury");
    MockToken internal token;
    IntakeAccount internal account;
    PaymentProbe internal probe;

    function setUp() public {
        token = new MockToken(18);
        account = new IntakeAccount(user); // This test is the authorized hub.
        probe = new PaymentProbe(treasury, PRICE);
        token.mint(address(account), 10 ether);
    }

    function _ask(address asset) internal returns (bytes32) {
        return account.ask(
            probe,
            bytes32("job.open@job-1"),
            bytes('{"objective":"site","skill":"build-website"}'),
            IIntake.Callback(address(this), bytes4(keccak256("onResult(bytes32,bytes32,string)"))),
            bytes4(0),
            asset,
            PRICE
        );
    }

    function testUserAndStrangerCannotInvokeHubPaymentPath() public {
        for (uint256 i; i < 2; ++i) {
            vm.prank(i == 0 ? user : stranger);
            vm.expectRevert(IntakeAccount.NotHub.selector);
            _ask(address(token));
        }
        assertEq(token.balanceOf(address(account)), 10 ether);
        assertEq(probe.calls(), 0);
    }

    function testFreshPriceIsSpentWhileUserDonationsRemainRecoverable() public {
        bytes32 id = _ask(address(token));
        assertEq(id, probe.requestId());
        assertEq(probe.approvalSeen(), PRICE);
        assertEq(token.balanceOf(address(account)), 9.5 ether);
        assertEq(token.balanceOf(treasury), PRICE);
        assertEq(token.allowance(address(account), address(probe)), 0);
        vm.prank(user);
        account.execute(address(token), 0, abi.encodeCall(token.transfer, (user, 9.5 ether)));
        assertEq(token.balanceOf(user), 9.5 ether);
        assertEq(token.balanceOf(address(account)), 0);
    }

    function testFuzzUnderpullRevertsAllDependencyEffects(uint96 shortfallSeed) public {
        uint256 shortfall = bound(shortfallSeed, 1, PRICE);
        probe.setBehavior(PRICE - shortfall, 0, keccak256("short payment"));
        vm.expectRevert(IntakeAccount.IncorrectPayment.selector);
        _ask(address(token));
        _assertRollback();
    }

    function testRefundAndNetBalanceIncreaseAreRejected() public {
        // The Intake price is spent, never escrowed or refunded to the payer.
        probe.setBehavior(PRICE, 1, keccak256("partial refund"));
        vm.expectRevert(IntakeAccount.IncorrectPayment.selector);
        _ask(address(token));
        _assertRollback();
        token.mint(address(probe), PRICE + 1);
        probe.setBehavior(PRICE, 2 * PRICE + 1, keccak256("balance increase"));
        vm.expectRevert(IntakeAccount.IncorrectPayment.selector);
        _ask(address(token));
        _assertRollback();
        assertEq(token.balanceOf(address(probe)), PRICE + 1);
    }

    function testOldUnlimitedAllowanceIsReducedBeforeAnIntakeCanOverpull() public {
        vm.prank(user);
        account.execute(address(token), 0, abi.encodeCall(token.approve, (address(probe), type(uint256).max)));
        probe.setBehavior(PRICE + 1, 0, keccak256("overpull"));
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(probe), PRICE, PRICE + 1
            )
        );
        _ask(address(token));
        // The user's preexisting approval is restored when the whole transaction rolls back.
        assertEq(token.allowance(address(account), address(probe)), type(uint256).max);
        assertEq(token.balanceOf(address(account)), 10 ether);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(probe.calls(), 0);
        probe.setBehavior(PRICE, 0, keccak256("exact"));
        _ask(address(token));
        assertEq(probe.approvalSeen(), PRICE);
        assertEq(token.allowance(address(account), address(probe)), 0);
    }

    function testZeroFirstApprovalIsSupportedAndCleanupFailureIsAtomic() public {
        ZeroFirstToken special = new ZeroFirstToken();
        special.mint(address(account), 2 ether);
        vm.prank(user);
        account.execute(address(special), 0, abi.encodeCall(special.approve, (address(probe), 1)));
        _ask(address(special));
        assertEq(special.balanceOf(treasury), PRICE);
        assertEq(special.allowance(address(account), address(probe)), 0);
        special.setRefuseReset(true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(special)));
        _ask(address(special));
        assertEq(special.balanceOf(address(account)), 1.5 ether);
        assertEq(special.balanceOf(treasury), PRICE);
        assertEq(special.allowance(address(account), address(probe)), 0);
        assertEq(probe.calls(), 1);
    }

    function testExecuteBubblesRevertAndDoesNotSpendETHOrChangeTarget() public {
        AccountTarget target = new AccountTarget();
        vm.deal(address(account), 1 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AccountTarget.Refused.selector, uint256(42)));
        account.execute(address(target), 1 ether, abi.encodeCall(target.reject, (42)));
        assertEq(address(account).balance, 1 ether);
        assertEq(address(target).balance, 0);
        assertEq(target.calls(), 0);
        vm.prank(user);
        bytes memory result = account.execute(address(target), 1 ether, abi.encodeCall(target.echo, (bytes("ok"))));
        assertEq(abi.decode(result, (bytes)), bytes("ok"));
        assertEq(address(account).balance, 0);
        assertEq(address(target).balance, 1 ether);
        assertEq(target.calls(), 1);
    }

    function testHubCannotWithdrawEvenThoughItCanAsk() public {
        vm.deal(address(account), 1 ether);
        vm.expectRevert(IntakeAccount.NotUser.selector);
        account.execute(address(this), 1 ether, "");
        assertEq(address(account).balance, 1 ether);
    }

    function testCannotCreateAnAccountWithNoUser() public {
        vm.expectRevert(IntakeAccount.InvalidUser.selector);
        new IntakeAccount(address(0));
    }

    function _assertRollback() internal view {
        assertEq(token.balanceOf(address(account)), 10 ether);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.allowance(address(account), address(probe)), 0);
        assertEq(probe.calls(), 0);
    }
}

contract WebsiteBuyerPaymentProbeTest is BuyerTestBase {
    function testZeroRequestIdRollsBackSwapPaymentAndPayerCreation() public {
        PaymentProbe probe = new PaymentProbe(treasury, PRICE);
        probe.setBehavior(PRICE, 0, bytes32(0));
        vm.prank(admin);
        buyer.setIntake(probe);
        WebsiteBuyer.Purchase memory quote = _quote();
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.DuplicateRequest.selector);
        buyer.buyWebsite{value: FEE}("site", quote);
        assertEq(manager.swaps(), 0);
        assertEq(address(manager).balance, 0);
        assertEq(token.balanceOf(address(manager)), 1_000_000 ether);
        assertEq(token.balanceOf(address(buyer)), 0);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(address(buyer.accountOf(alice)), address(0));
        assertEq(probe.calls(), 0);
        assertEq(alice.balance, 100 ether);
        probe.setBehavior(PRICE, 0, keccak256("nonzero request"));
        _buy(alice);
        assertEq(token.balanceOf(treasury), PRICE);
    }
}
