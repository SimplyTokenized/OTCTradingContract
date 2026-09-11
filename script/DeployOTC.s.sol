// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {OTCTrading} from "../src/OTCTrading.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";

/**
 * @title DeployOTC
 * @notice Deploy ONE trading contract for a tenant. Offerings are listed afterwards, one call each
 * — see {CreateOffering}.
 *
 * @dev v1 deployed a contract per instrument, so this script took a base token. v2 does not: the
 * contract knows nothing about any instrument until an operator lists one, which is what lets a
 * tenant add their fortieth offering without a fortieth deployment, a fortieth upgrade path and a
 * fortieth set of keys to guard.
 *
 * Required environment: ADMIN, APPROVER, UPGRADER.
 * Optional: TRUSTED_FORWARDER (ERC-2771 relaying; omit for "users pay their own gas").
 */
contract DeployOTC is Script {
    function run() public returns (OTCTrading otc) {
        address admin = vm.envAddress("ADMIN");
        address approver = vm.envAddress("APPROVER");
        address upgrader = vm.envAddress("UPGRADER");
        address forwarder = vm.envOr("TRUSTED_FORWARDER", address(0));

        require(approver != admin, "DeployOTC: APPROVER must differ from ADMIN");

        console.log("Deploying OTCTrading (one contract, many offerings)...");
        console.log("Admin     :", admin);
        console.log("Approver  :", approver);
        console.log("Upgrader  :", upgrader);
        console.log("Forwarder :", forwarder);

        vm.startBroadcast();

        // UUPS proxy. Upgrades are authorized by UPGRADER_ROLE on the implementation — put that role
        // behind a Timelock + multisig for production: users hold standing allowances here and need
        // a public window to revoke and exit before new settlement code takes effect.
        address proxy = Upgrades.deployUUPSProxy(
            "OTCTrading.sol", abi.encodeCall(OTCTrading.initialize, (admin, approver, upgrader, forwarder))
        );
        otc = OTCTrading(proxy);

        vm.stopBroadcast();

        console.log("===========================================");
        console.log("Proxy address (USE THIS):", proxy);
        console.log("===========================================");
        console.log("Implementation (reference only):", Upgrades.getImplementationAddress(proxy));
        console.log("");
        console.log("Next: list an offering with script/CreateOffering.s.sol");
    }
}
