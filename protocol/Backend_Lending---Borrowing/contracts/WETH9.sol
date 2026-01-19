// SPDX-License-Identifier: MIT

// WETH9: implementación mínima de WETH para pruebas locales (wrap/unwrap de ETH en un ERC20 de 18 dec).
// Tokens fijos: name "Wrapped Ether", symbol "WETH", decimals 18; guarda balances y allowances manuales.
// API: deposit() y receive() convierten ETH en WETH; withdraw(wad) revierte a ETH; approve/transfer/transferFrom siguen el patrón ERC20 básico.

pragma solidity ^0.8.24;

/// @notice Minimal WETH9 implementation for testing.
contract WETH9 {
    string public constant name = "Wrapped Ether";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;

    event Approval(address indexed src, address indexed guy, uint256 wad);
    event Transfer(address indexed src, address indexed dst, uint256 wad);
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Deposit(msg.sender, msg.value);
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "insufficient");
        balanceOf[msg.sender] -= wad;
        totalSupply -= wad;
        emit Withdrawal(msg.sender, wad);
        emit Transfer(msg.sender, address(0), wad);
        (bool ok, ) = payable(msg.sender).call{value: wad}("");
        require(ok, "eth-transfer-failed");
    }

    function approve(address guy, uint256 wad) external returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) external returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(
        address src,
        address dst,
        uint256 wad
    ) public returns (bool) {
        require(balanceOf[src] >= wad, "insufficient");

        if (src != msg.sender) {
            uint256 allowed = allowance[src][msg.sender];
            require(allowed >= wad, "no-allowance");
            if (allowed != type(uint256).max) {
                allowance[src][msg.sender] = allowed - wad;
            }
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);
        return true;
    }
}
