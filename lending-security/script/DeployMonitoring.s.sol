// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
- Despliega contratos WETH9, MockUSDC, OracleMock y LendingPool en Anvil
- Guarda direcciones en un JSON
    · Crear addresses.json con las direcciones de weth, usdc, oracle y pool

Asi el monitor en Node.js puede leer ese JSON y conectarse automaticamente al pool que hemos desplegado
*/

import "forge-std/Script.sol";
import {LendingPool} from "protocol/LendingPool.sol";
import {MockUSDC} from "protocol/MockUSDC.sol";
import {OracleMock} from "protocol/OracleMock.sol";
import {WETH9} from "protocol/WETH9.sol";

contract DeployMonitoringScript is Script {
    function run() external {
        vm.startBroadcast();

        WETH9 weth = new WETH9();
        MockUSDC usdc = new MockUSDC();
        OracleMock oracle = new OracleMock(2000e8);

        LendingPool pool =
            new LendingPool(address(weth), address(usdc), address(oracle), 7500, 8000, 200, 400, 2000, 8000, 1000);

        vm.stopBroadcast();

        string memory obj = "addresses";
        vm.serializeAddress(obj, "weth", address(weth));
        vm.serializeAddress(obj, "usdc", address(usdc));
        vm.serializeAddress(obj, "oracle", address(oracle));
        string memory json = vm.serializeAddress(obj, "pool", address(pool));
        vm.writeJson(json, "../monitoring/addresses.json");
    }
}
