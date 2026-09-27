// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SwarmWorld} from "../src/SwarmWorld.sol";

/// @title SwarmWorld deploy script
/// @notice Deploys exactly one SwarmWorld. The contract has no constructor arguments, no owner and
///         no post-deployment configuration, so the only deployment parameter is the chain.
/// @dev Reads no keys. The only environment variable is EXPECTED_CHAIN_ID, and only in run():
///      when set to a nonzero value it must equal block.chainid and be one of the allowed chains.
///      Tests call deploy() directly and never touch the environment.
contract Deploy is Script {
    uint256 public constant ANVIL_CHAIN_ID = 31_337;
    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;

    error UnexpectedChain(uint256 expected, uint256 actual);
    error ChainNotAllowed(uint256 chainId);

    /// @notice Pure deployment step, callable from tests with an explicit chain id to check.
    function deploy() public returns (SwarmWorld world) {
        world = new SwarmWorld();
    }

    /// @notice Validates the target chain against `expectedChainId` (0 skips the check).
    function checkChain(uint256 expectedChainId, uint256 actualChainId) public pure {
        if (expectedChainId == 0) return;
        if (expectedChainId != actualChainId) revert UnexpectedChain(expectedChainId, actualChainId);
        if (expectedChainId != ANVIL_CHAIN_ID && expectedChainId != SEPOLIA_CHAIN_ID) {
            revert ChainNotAllowed(expectedChainId);
        }
    }

    function run() external returns (SwarmWorld world) {
        checkChain(vm.envOr("EXPECTED_CHAIN_ID", uint256(0)), block.chainid);
        vm.startBroadcast();
        world = deploy();
        vm.stopBroadcast();
    }
}
