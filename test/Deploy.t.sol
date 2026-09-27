// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {SwarmWorld} from "../src/SwarmWorld.sol";

contract DeployTest is Test {
    Deploy internal script;

    function setUp() public {
        script = new Deploy();
    }

    function test_deployProducesFreshWorld() public {
        SwarmWorld world = script.deploy();
        assertEq(world.getSettlement(0).energy, 500);
        assertEq(world.getSettlement(1).materials, 700);
        assertEq(world.getSettlement(2).energy, 120);
        assertEq(world.nextMissionId(), 1);
        assertEq(world.lastTickAt(), block.timestamp);
        assertEq(address(world).balance, 0);
    }

    function test_checkChainAcceptsAllowedChains() public view {
        script.checkChain(0, 1); // unset: skipped
        script.checkChain(31_337, 31_337);
        script.checkChain(11_155_111, 11_155_111);
    }

    function test_checkChainRejectsMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnexpectedChain.selector, 11_155_111, 1));
        script.checkChain(11_155_111, 1);
    }

    function test_checkChainRejectsUnsupportedChain() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainNotAllowed.selector, 1));
        script.checkChain(1, 1);
    }
}
