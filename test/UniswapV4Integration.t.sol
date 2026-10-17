// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WebsiteBuyer} from "../src/WebsiteBuyer.sol";
import {MockToken, MockWETH} from "./mocks/MockToken.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Test-only liquidity provider, funded before seeding; not an application to deploy.
contract LiquiditySeeder is IUnlockCallback {
    using SafeERC20 for IERC20;
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function seed(PoolKey memory key, int256 liquidity) external {
        manager.unlock(abi.encode(key, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, int256 liquidity) = abi.decode(data, (PoolKey, int256));
        (BalanceDelta delta,) =
            manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-887220, 887220, liquidity, 0), "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 delta) private {
        require(delta <= 0);
        uint256 amount = uint256(-int256(delta));
        manager.sync(currency);
        if (Currency.unwrap(currency) == address(0)) {
            manager.settle{value: amount}();
        } else {
            IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), amount);
            manager.settle();
        }
    }
}

/// @dev Test-only exact-input trader, used as a sandwiching searcher.
contract Swapper is IUnlockCallback {
    using SafeERC20 for IERC20;
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external {
        manager.unlock(abi.encode(key, zeroForOne, amountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = manager.swap(key, IPoolManager.SwapParams(zeroForOne, -int256(amountIn), limit), "");
        _move(key.currency0, delta.amount0());
        _move(key.currency1, delta.amount1());
        return "";
    }

    function _move(Currency currency, int128 delta) private {
        if (delta > 0) {
            manager.take(currency, address(this), uint256(uint128(delta)));
        } else if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), amount);
                manager.settle();
            }
        }
    }
}

/// @dev Leaves an ERC-20 synced before a native swap settles; consumers must explicitly sync native.
contract SyncDuringSwap {
    IPoolManager private immutable manager;
    Currency private immutable currency;

    constructor(IPoolManager manager_, Currency currency_) {
        manager = manager_;
        currency = currency_;
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        manager.sync(currency);
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }
}

contract UniswapV4IntegrationTest is Test {
    using StateLibrary for IPoolManager;
    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal treasury = makeAddr("treasury");
    address internal writer = makeAddr("writer");
    PoolManager internal manager;
    LiquiditySeeder internal seeder;
    MockToken internal imd;
    MockIntake internal intake;
    WebsiteBuyer internal buyer;

    function setUp() public {
        manager = new PoolManager(owner);
        seeder = new LiquiditySeeder(manager);
        imd = new MockToken(18);
        intake = new MockIntake(treasury, writer);
        buyer = new WebsiteBuyer(owner, intake, address(imd));
        intake.setPrice(bytes32("job.open@job-1"), address(imd), 0.5 ether);
        vm.deal(user, 10 ether);
        vm.deal(address(seeder), 100_000 ether);
        imd.mint(address(seeder), 1_000_000_000 ether);
    }

    function _key(address input, IHooks hooks) internal view returns (PoolKey memory) {
        (address a, address b) = input < address(imd) ? (input, address(imd)) : (address(imd), input);
        return PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, hooks);
    }

    function _configure(address input, IHooks hooks, bool liquidity) internal returns (PoolKey memory key) {
        key = _key(input, hooks);
        // Roughly 1000 IMD per ETH in either currency ordering.
        int24 tick = input < address(imd) ? int24(69060) : int24(-69060);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(tick));
        if (liquidity) seeder.seed(key, 1000 ether);
        vm.prank(owner);
        buyer.setPool(manager, input, 3000, 60, hooks, "");
    }

    function _purchase() internal view returns (WebsiteBuyer.Purchase memory) {
        return WebsiteBuyer.Purchase(0, 2.9 ether, 0.5 ether, block.timestamp + 120, buyer.configurationVersion());
    }

    function _buy() internal returns (bytes32 id) {
        WebsiteBuyer.Purchase memory p = _purchase();
        vm.prank(user);
        id = buyer.buyWebsite{value: 0.003 ether}("a florist in Kyoto", p);
    }

    function testRealNativePoolSettlesAndPaysIntake() public {
        PoolKey memory key = _configure(address(0), IHooks(address(0)), true);
        uint256 ethBefore = address(manager).balance;
        uint256 tokensBefore = imd.balanceOf(address(manager));
        (uint160 sqrtBefore,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        bytes32 id = _buy();
        uint256 bought = tokensBefore - imd.balanceOf(address(manager));
        assertGt(bought, 2.9 ether);
        assertLt(bought, 3 ether);
        assertEq(address(manager).balance - ethBefore, 0.003 ether);
        assertEq(imd.balanceOf(treasury), 0.5 ether);
        assertEq(imd.balanceOf(address(buyer)), bought - 0.5 ether);
        assertEq(address(buyer).balance, 0);
        assertEq(imd.balanceOf(address(buyer.accountOf(user))), 0);
        (uint160 sqrtAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertLt(sqrtAfter, sqrtBefore);
        vm.prank(writer);
        assertTrue(intake.complete(id, 0, keccak256("result"), "ipfs://site/result.json", 0));
        assertEq(buyer.requestOf(address(intake), id).uri, "ipfs://site/result.json");
    }

    function testRealPoolSlippageRevertsPoolStateETHAndTokens() public {
        PoolKey memory key = _configure(address(0), IHooks(address(0)), true);
        uint256 ethBefore = address(manager).balance;
        uint256 tokensBefore = imd.balanceOf(address(manager));
        (uint160 sqrtBefore,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        WebsiteBuyer.Purchase memory p = _purchase();
        p.minImdOut = 3 ether;
        vm.prank(user);
        vm.expectPartialRevert(WebsiteBuyer.InsufficientOutput.selector);
        buyer.buyWebsite{value: 0.003 ether}("x", p);
        (uint160 sqrtAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(sqrtAfter, sqrtBefore);
        assertEq(address(manager).balance, ethBefore);
        assertEq(imd.balanceOf(address(manager)), tokensBefore);
        assertEq(user.balance, 10 ether);
        assertEq(intake.count(), 0);
    }

    function testRealPoolRollbackWhenIntakeReverts() public {
        PoolKey memory key = _configure(address(0), IHooks(address(0)), true);
        (uint160 sqrtBefore,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        uint256 ethBefore = address(manager).balance;
        intake.setReject(true);
        WebsiteBuyer.Purchase memory p = _purchase();
        vm.prank(user);
        vm.expectRevert("intake unavailable");
        buyer.buyWebsite{value: 0.003 ether}("x", p);
        (uint160 sqrtAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(sqrtBefore, sqrtAfter);
        assertEq(address(manager).balance, ethBefore);
        assertEq(user.balance, 10 ether);
    }

    function testRealUninitializedAndEmptyPoolsRevert() public {
        vm.prank(owner);
        buyer.setPool(manager, address(0), 3000, 60, IHooks(address(0)), "");
        WebsiteBuyer.Purchase memory p = _purchase();
        vm.prank(user);
        vm.expectRevert();
        buyer.buyWebsite{value: 0.003 ether}("x", p);
        _configure(address(0), IHooks(address(0)), false);
        p = _purchase();
        vm.prank(user);
        vm.expectRevert(WebsiteBuyer.IncompleteSwap.selector);
        buyer.buyWebsite{value: 0.003 ether}("x", p);
        assertEq(user.balance, 10 ether);
        assertEq(intake.count(), 0);
    }

    function testRealWrappedNativePoolsInBothCurrencyOrders() public {
        // Etching the same test wrapper to opposite sides of IMD exercises both delta directions.
        MockWETH implementation = new MockWETH();
        address lower = address(uint160(address(imd)) - 1);
        address higher = address(uint160(address(imd)) + 1);
        vm.etch(lower, address(implementation).code);
        vm.etch(higher, address(implementation).code);
        for (uint256 i; i < 2; ++i) {
            MockWETH weth = MockWETH(i == 0 ? lower : higher);
            weth.mint(address(seeder), 100_000 ether);
            _configure(address(weth), IHooks(address(0)), true);
            uint256 wrappedBefore = weth.balanceOf(address(manager));
            _buy();
            assertEq(weth.balanceOf(address(manager)) - wrappedBefore, 0.003 ether);
            assertEq(weth.balanceOf(address(buyer)), 0);
            assertEq(address(weth).balance, 0.003 ether);
        }
        assertEq(imd.balanceOf(treasury), 1 ether);
        assertEq(address(buyer).balance, 0);
    }

    /// @dev The reviewer's 0.05% pool: without a floor, a 1.3 ETH front-run took ~98.7% of the surplus at a profit.
    function testOwnerFloorStopsSandwichOfSurplusOnLowFeePool() public {
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 500, 10, IHooks(address(0)));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(69080));
        seeder.seed(key, 30 ether);
        vm.startPrank(owner);
        buyer.setPool(manager, address(0), 500, 10, IHooks(address(0)), "");
        // A fresh quote for 0.003 ETH is about 2.4888 IMD; the owner tolerates about 5%.
        buyer.setIMDFloor(2.36 ether);
        vm.stopPrank();
        Swapper searcher = new Swapper(manager);
        vm.deal(address(searcher), 2 ether);
        // The buyer sets no minimum of their own: they get the same website whatever the swap returns.
        WebsiteBuyer.Purchase memory p =
            WebsiteBuyer.Purchase(0, 0, 0.5 ether, block.timestamp + 120, buyer.configurationVersion());

        searcher.swap(key, true, 1.3 ether);
        vm.prank(user);
        vm.expectPartialRevert(WebsiteBuyer.InsufficientOutput.selector);
        buyer.buyWebsite{value: 0.003 ether}("a florist in Kyoto", p);
        assertEq(user.balance, 10 ether);
        assertEq(intake.count(), 0);
        searcher.swap(key, false, imd.balanceOf(address(searcher)));
        assertLt(address(searcher).balance, 2 ether);

        vm.prank(user);
        buyer.buyWebsite{value: 0.003 ether}("a florist in Kyoto", p);
        assertGe(imd.balanceOf(address(buyer)), 2.36 ether - 0.5 ether);
        assertEq(imd.balanceOf(treasury), 0.5 ether);
    }

    function testNativeSettlementResetsCurrencySyncedByPoolHook() public {
        SyncDuringSwap implementation = new SyncDuringSwap(manager, Currency.wrap(address(imd)));
        address hook = address((uint160(makeAddr("sync hook")) & ~uint160((1 << 14) - 1)) | uint160(1 << 7));
        vm.etch(hook, address(implementation).code);
        _configure(address(0), IHooks(hook), true);
        _buy();
        assertEq(imd.balanceOf(treasury), 0.5 ether);
    }
}
