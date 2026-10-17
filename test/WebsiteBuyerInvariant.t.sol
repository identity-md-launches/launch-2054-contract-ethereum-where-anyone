// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WebsiteBuyerHandler} from "./invariant/WebsiteBuyerHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract WebsiteBuyerInvariantTest is Test {
    WebsiteBuyerHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        handler = new WebsiteBuyerHandler();
        // Seed all actors and both terminal states, with requests still pending too.
        // This makes the invariants meaningful even if a random sequence starts paused.
        for (uint256 i; i < 4; ++i) {
            handler.buy(i, i, 0);
        }
        handler.settle(0, true, keccak256("initial result"), 0);
        handler.settle(1, false, bytes32(0), 0);
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.rejectPurchase.selector;
        selectors[2] = handler.configure.selector;
        selectors[3] = handler.settle.selector;
        selectors[4] = handler.forgeCallback.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.depositETH.selector;
        selectors[7] = handler.withdrawAccount.selector;
        selectors[8] = handler.unauthorized.selector;
        selectors[9] = handler.buy.selector; // Keep purchases frequent among administrative calls.
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_EveryWeiAndTokenIsAccountedFor() public view {
        handler.checkConservation();
    }

    function invariant_RequestIdentityAndTerminalResultsAreImmutable() public view {
        handler.checkRequests();
    }

    function invariant_OnlyAuthorizedConfigurationAndPayersPersist() public view {
        handler.checkConfigurationAndPayers();
    }

    function testHandlerExercisesMigrationsFailuresAndRecovery() public {
        handler.depositETH(0, 1 ether, true);
        handler.depositETH(0, 1 ether, false);
        handler.donate(0, 0, 10 ether, false);
        handler.donate(0, 0, 3 ether, true);
        for (uint8 i; i < 7; ++i) {
            handler.rejectPurchase(0, i);
        }
        handler.configure(2, 1); // New token disables the previous route.
        handler.buy(0, 0, 0);
        handler.configure(3, 1); // Restore the route, using wrapped ETH.
        handler.configure(1, 1); // New Intake, same payer accounts.
        handler.buy(0, 2 ether, 1 ether);
        handler.configure(4, 1); // Pause purchases while old callbacks still work.
        handler.settle(2, true, keccak256("old Intake result"), 0);
        handler.configure(4, 0);
        handler.withdrawAccount(0, 0, type(uint256).max, true);
        handler.withdrawAccount(0, 0, type(uint256).max, false);
        handler.buy(1, 0, 0);
        assertGt(handler.successfulPurchases(), 4);
        assertGe(handler.rejectedPurchases(), 8);
        assertGe(handler.settlements(), 3);
        handler.checkConservation();
        handler.checkRequests();
        handler.checkConfigurationAndPayers();
    }
}
