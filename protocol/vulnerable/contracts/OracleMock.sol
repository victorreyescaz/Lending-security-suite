// SPDX-License-Identifier: MIT

// OracleMock: oráculo ETH/USD simulado que retorna un precio configurable con 8 decimales (estilo Chainlink).
// Estado: price (uint256, 8 dec) inicializado en el constructor.
// API: setPrice(newPrice) para tests; getEthUsdPrice() expone el valor actual.

pragma solidity ^0.8.24;

contract OracleMock {
    uint256 public price; // 8 decimals

    constructor(uint256 initialPrice) {
        price = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function getEthUsdPrice() external view returns (uint256) {
        return price;
    }
}
