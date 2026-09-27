// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title SwarmWorld launch token
/// @notice Fixed-supply ERC-20 required by the IMD project-launch pipeline. 1,000,000,000 tokens
///         (10^27 minor units, 18 decimals) are minted once to the deployer in the constructor.
///         No mint, burn, owner, pause, blocklist, fee or upgrade functions exist.
/// @dev SwarmWorld itself never references this token. Mission rewards are native ETH only.
contract LaunchToken {
    string public constant name = "SwarmWorld";
    string public constant symbol = "SWARM";
    uint8 public constant decimals = 18;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    uint256 public immutable totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(address from, uint256 balance, uint256 needed);
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ZeroAddress();

    constructor() {
        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(msg.sender, allowed, amount);
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance(from, bal, amount);
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount; // total supply is fixed, so no balance can exceed it
        }
        emit Transfer(from, to, amount);
    }
}
