// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {WebsiteBuyer} from "../src/WebsiteBuyer.sol";
import {IntakeAccount} from "../src/IntakeAccount.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";

contract DeploymentFactory {
    function deploy(address owner, address intake, address imd) external returns (WebsiteBuyer) {
        return new WebsiteBuyer(owner, IIntake(intake), imd);
    }
}

contract DeploymentTest is Test {
    function testFactoryDeploymentHasExplicitLaunchOwnerAndNoExternalConstructorCalls() public {
        address launchOwner = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
        address intake = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
        address imd = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
        assertEq(intake.code.length, 0);
        assertEq(imd.code.length, 0);
        DeploymentFactory factory = new DeploymentFactory();
        WebsiteBuyer buyer = factory.deploy(launchOwner, intake, imd);
        assertEq(buyer.owner(), launchOwner);
        assertNotEq(buyer.owner(), address(factory));
        assertEq(address(buyer.intake()), intake);
        assertEq(buyer.imd(), imd);
        assertEq(buyer.ethPrice(), 0.003 ether);
        assertFalse(buyer.poolConfigured());
        assertLe(type(WebsiteBuyer).creationCode.length + 3 * 32, 49_152);
        _checkRuntime(address(buyer).code);
        IntakeAccount account = new IntakeAccount(launchOwner);
        _checkRuntime(address(account).code);
    }

    function testZeroOwnerAndDependenciesRevert() public {
        address owner = makeAddr("owner");
        address intake = makeAddr("intake");
        address imd = makeAddr("imd");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new WebsiteBuyer(address(0), IIntake(intake), imd);
        vm.expectRevert(WebsiteBuyer.InvalidAddress.selector);
        new WebsiteBuyer(owner, IIntake(address(0)), imd);
        vm.expectRevert(WebsiteBuyer.InvalidAddress.selector);
        new WebsiteBuyer(owner, IIntake(intake), address(0));
    }

    function _checkRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }
    }
}
