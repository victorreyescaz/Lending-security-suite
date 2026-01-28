// SPDX-License-Identifier: MIT

// MockUSDC: token ERC20 de prueba que emula USDC con 6 decimales para entornos locales.
// Config: nombre "Mock USDC", símbolo "mUSDC"; decimals() fija 6 como el USDC real.
// Función clave: mint(address to, uint256 amount) abierta para acuñar libremente en tests.

pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
