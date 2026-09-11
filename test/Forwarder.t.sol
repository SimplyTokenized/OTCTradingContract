// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OTCTestBase} from "./utils/OTCTestBase.sol";
import {OTCTrading} from "../src/OTCTrading.sol";
import {MockForwarder} from "./utils/Mocks.sol";

/// @dev ERC-2771: one implementation serves tenants who pay their users' gas and tenants who do not.
contract ForwarderTest is OTCTestBase {
    MockForwarder internal forwarder;

    function setUp() public override {
        super.setUp();
        forwarder = new MockForwarder();

        vm.prank(admin);
        otc.proposeSetTrustedForwarder(address(forwarder));
        vm.prank(approver);
        otc.approveSetTrustedForwarder(address(forwarder));
    }

    function test_a_relayed_order_is_credited_to_the_real_maker() public {
        bytes memory data = abi.encodeCall(
            OTCTrading.createOrder, (alphaId, OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18)
        );

        bytes memory ret = forwarder.relay(address(otc), data, maker);
        uint256 orderId = abi.decode(ret, (uint256));

        assertEq(otc.getOrder(orderId).maker, maker, "the sender in the suffix is the maker");
    }

    function test_a_relayed_fill_is_credited_to_the_real_taker() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        bytes memory data = abi.encodeCall(OTCTrading.fillOrder, (orderId, 1000e18));
        forwarder.relay(address(otc), data, taker);

        assertEq(alphaToken.balanceOf(taker), 1_001_000e18, "the taker received the base tokens");
    }

    function test_a_relayed_cancel_works_for_the_real_maker() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        forwarder.relay(address(otc), abi.encodeCall(OTCTrading.cancelOrder, (orderId)), maker);
        assertFalse(otc.getOrder(orderId).isActive);
    }

    function test_a_relayed_cancel_by_someone_else_is_refused() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        vm.expectRevert(OTCTrading.NotOrderMaker.selector);
        forwarder.relay(address(otc), abi.encodeCall(OTCTrading.cancelOrder, (orderId)), taker);
    }

    /// @dev The value would be the forwarder's, not the sender's, so it is refused outright.
    function test_a_relayed_call_may_not_carry_value() public {
        bytes memory data =
            abi.encodeCall(OTCTrading.createOrder, (alphaId, OTCTrading.OrderType.BUY, ETH, 1000e18, 1 ether));

        vm.deal(address(this), 2 ether);
        vm.expectRevert(OTCTrading.RelayedCallCannotCarryValue.selector);
        forwarder.relay{value: 1 ether}(address(otc), data, maker);
    }

    function test_an_untrusted_forwarder_is_just_a_caller() public {
        MockForwarder rogue = new MockForwarder();

        bytes memory data = abi.encodeCall(
            OTCTrading.createOrder, (alphaId, OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18)
        );

        // The rogue's suffix is ignored, so the order would be its own — and it holds nothing.
        vm.expectRevert(OTCTrading.InsufficientAllowance.selector);
        rogue.relay(address(otc), data, maker);
    }

    function test_relaying_can_be_switched_off_again() public {
        vm.prank(admin);
        otc.proposeSetTrustedForwarder(address(0));
        vm.prank(approver);
        otc.approveSetTrustedForwarder(address(0));

        assertEq(otc.trustedForwarder(), address(0));
        assertFalse(otc.isTrustedForwarder(address(forwarder)));
    }
}
