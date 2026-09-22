// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {OTCTrading} from "../src/OTCTrading.sol";
import {WhitelistRegistry} from "../src/compliance/WhitelistRegistry.sol";
import {ERC3643EligibilityAdapter} from "../src/compliance/ERC3643EligibilityAdapter.sol";

/**
 * @title CreateOffering
 * @notice List one tradable instrument on an existing OTCTrading deployment.
 *
 * @dev Run once per offering. Everything an instrument needs — its base token, its fee schedule and
 * recipient, its size band, its default expiry, its counterparty tokens and its compliance gate —
 * is set here, on the offering, and never contract-wide.
 *
 * Required: OTC_PROXY, OFFERING_BASE_TOKEN, OFFERING_FEE_RECIPIENT, OFFERING_COUNTERPARTY_TOKENS
 * (comma-separated; use 0x0 for native ETH).
 * Optional: OFFERING_MAKER_FEE_BPS, OFFERING_TAKER_FEE_BPS, OFFERING_MIN_ORDER_SIZE,
 * OFFERING_MAX_ORDER_SIZE, OFFERING_EXPIRATION_SECONDS, OFFERING_REF, and ONE of
 * OFFERING_ELIGIBILITY_REGISTRY (an address) or OFFERING_ERC3643_TOKEN (deploys an adapter for that
 * token's identity registry) or OFFERING_DEPLOY_WHITELIST=true (deploys an operator-kept list).
 */
contract CreateOffering is Script {
    function run() public returns (uint256 offeringId) {
        OTCTrading otc = OTCTrading(vm.envAddress("OTC_PROXY"));

        address[] memory counterpartyTokens = vm.envAddress("OFFERING_COUNTERPARTY_TOKENS", ",");
        require(counterpartyTokens.length > 0, "CreateOffering: no counterparty tokens");

        vm.startBroadcast();

        address registry = _resolveRegistry();

        OTCTrading.OfferingConfig memory cfg = OTCTrading.OfferingConfig({
            baseToken: vm.envAddress("OFFERING_BASE_TOKEN"),
            feeRecipient: vm.envAddress("OFFERING_FEE_RECIPIENT"),
            eligibilityRegistry: registry,
            makerFeeBps: uint16(vm.envOr("OFFERING_MAKER_FEE_BPS", uint256(25))),
            takerFeeBps: uint16(vm.envOr("OFFERING_TAKER_FEE_BPS", uint256(50))),
            defaultOrderExpiration: uint48(vm.envOr("OFFERING_EXPIRATION_SECONDS", uint256(0))),
            minOrderSize: vm.envOr("OFFERING_MIN_ORDER_SIZE", uint256(1)),
            maxOrderSize: vm.envOr("OFFERING_MAX_ORDER_SIZE", uint256(0)),
            offeringRef: vm.envOr("OFFERING_REF", bytes32(0)),
            counterpartyTokens: counterpartyTokens
        });

        offeringId = otc.createOffering(cfg);

        vm.stopBroadcast();

        console.log("===========================================");
        console.log("Offering id:", offeringId);
        console.log("Base token :", cfg.baseToken);
        console.log("Gate       :", registry == address(0) ? "none (ungated)" : "registry");
        console.log("Registry   :", registry);
        console.log("===========================================");
    }

    /// @dev Pick the offering's compliance posture: none, an existing registry, a fresh whitelist,
    /// or an adapter deferring to an ERC-3643 token's own identity registry.
    function _resolveRegistry() private returns (address) {
        address existing = vm.envOr("OFFERING_ELIGIBILITY_REGISTRY", address(0));
        if (existing != address(0)) return existing;

        address erc3643 = vm.envOr("OFFERING_ERC3643_TOKEN", address(0));
        if (erc3643 != address(0)) {
            ERC3643EligibilityAdapter adapter = new ERC3643EligibilityAdapter(erc3643);
            console.log("Deployed ERC3643EligibilityAdapter:", address(adapter));
            return address(adapter);
        }

        if (vm.envOr("OFFERING_DEPLOY_WHITELIST", false)) {
            WhitelistRegistry whitelist = new WhitelistRegistry(vm.envAddress("OFFERING_WHITELIST_OWNER"));
            console.log("Deployed WhitelistRegistry:", address(whitelist));
            return address(whitelist);
        }

        return address(0);
    }
}
