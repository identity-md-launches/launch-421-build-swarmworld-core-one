// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "SwarmWorld");
        assertEq(token.symbol(), "SWARM");
        assertEq(token.decimals(), 18);
    }

    function test_fixedSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transfer() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferInsufficientBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroReverts() public {
        vm.prank(deployer);
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        token.approve(alice, 500e18);
        assertEq(token.allowance(deployer, alice), 500e18);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 200e18));
        assertEq(token.balanceOf(bob), 200e18);
        assertEq(token.allowance(deployer, alice), 300e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, alice, 300e18, 301e18));
        token.transferFrom(deployer, bob, 301e18);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_noMintOrAdminEntrypoints() public {
        string[6] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "transferOwnership(address)",
            "pause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < sigs.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], deployer, uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
