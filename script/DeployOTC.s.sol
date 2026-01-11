// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {OTCTrading} from "../src/OTCTrading.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";

/**
 * @title DeployOTC
 * @dev Deployment script for OTC Trading contract with proxy
 */
contract DeployOTC is Script {
    function run() public returns (OTCTrading otc) {
        vm.startBroadcast();

        // Get deployment parameters from environment
        address baseToken = vm.envAddress("BASE_TOKEN");
        address defaultCounterpartyToken = vm.envAddress("DEFAULT_COUNTERPARTY_TOKEN"); // e.g., USDC
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address admin = vm.envAddress("ADMIN");

        console.log("Deploying OTC Trading contract with proxy...");
        console.log("Base Token:", baseToken);
        console.log("Default Counterparty Token:", defaultCounterpartyToken);
        console.log("Fee Recipient:", feeRecipient);
        console.log("Admin:", admin);

        // Deploy transparent proxy
        address proxyAddress = Upgrades.deployTransparentProxy(
            "OTCTrading.sol",
            admin, // Proxy admin
            abi.encodeCall(
                OTCTrading.initialize,
                (baseToken, defaultCounterpartyToken, feeRecipient, admin)
            )
        );

        otc = OTCTrading(payable(proxyAddress));

        console.log("===========================================");
        console.log("Proxy address (USE THIS):", proxyAddress);
        console.log("===========================================");
        address implementationAddress = Upgrades.getImplementationAddress(proxyAddress);
        console.log("Implementation address (reference only):", implementationAddress);

        vm.stopBroadcast();
    }
}
