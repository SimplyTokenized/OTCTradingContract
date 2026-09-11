// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OTCTestBase} from "./utils/OTCTestBase.sol";
import {OTCTrading} from "../src/OTCTrading.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev A second implementation, identical except that it says so.
contract OTCTradingV2Next is OTCTrading {
    function version() external pure returns (string memory) {
        return "next";
    }
}

/// @dev Upgrades are the root of trust here: users hold standing allowances, so whoever can replace
/// the settlement code can in principle change what those allowances do.
contract UpgradeTest is OTCTestBase {
    function test_only_the_upgrader_may_upgrade() public {
        address next = address(new OTCTradingV2Next());
        bytes32 upgraderRole = otc.UPGRADER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, upgraderRole)
        );
        vm.prank(admin);
        otc.upgradeToAndCall(next, "");

        vm.prank(upgrader);
        otc.upgradeToAndCall(next, "");
        assertEq(OTCTradingV2Next(address(otc)).version(), "next");
    }

    /// @dev The role that guards the venue is not the role that can replace it.
    function test_the_admin_is_not_the_upgrader() public view {
        assertFalse(otc.hasRole(otc.UPGRADER_ROLE(), admin));
        assertTrue(otc.hasRole(otc.UPGRADER_ROLE(), upgrader));
    }

    function test_state_survives_an_upgrade() public {
        uint256 orderId = _buyEthOrder(alphaId, maker, 1000e18, 10 ether);
        uint256 escrow = otc.ethEscrowed(orderId);

        // Deployed before the prank: a CREATE is a call too, and would consume it.
        address next = address(new OTCTradingV2Next());
        vm.prank(upgrader);
        otc.upgradeToAndCall(next, "");

        assertEq(otc.ethEscrowed(orderId), escrow);
        assertEq(otc.getOffering(alphaId).baseToken, address(alphaToken));
        assertEq(otc.getOrder(orderId).maker, maker);

        // And the order still settles across the upgrade.
        vm.prank(taker);
        otc.fillOrder(orderId, 1000e18);
        _assertEthReserveHolds();
    }

    function test_the_implementation_cannot_be_initialized_directly() public {
        OTCTrading implementation = new OTCTrading();
        vm.expectRevert();
        implementation.initialize(admin, approver, upgrader, address(0));
    }
}
