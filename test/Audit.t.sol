// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OTCTestBase} from "./utils/OTCTestBase.sol";
import {OTCTrading} from "../src/OTCTrading.sol";
import {MockERC20, MockForwarder} from "./utils/Mocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @dev Regression tests for the v2 audit findings, one per finding, named after them. Each began
 * life as a proof of concept that FAILED against the pre-remediation contract; see AUDIT.md.
 */
contract AuditTest is OTCTestBase {
    // ---- V2-M1: governance must not be relayable ----

    /// @dev A trusted forwarder can act as any address for TRADING. It must not be able to act as
    /// an approver: otherwise whoever controls the forwarder holds every role at once, and four
    /// eyes is two.
    function test_M1_a_forwarder_cannot_approve_on_behalf_of_the_approver() public {
        MockForwarder forwarder = new MockForwarder();
        vm.prank(admin);
        otc.proposeSetTrustedForwarder(address(forwarder));
        vm.prank(approver);
        otc.approveSetTrustedForwarder(address(forwarder));

        address thief = address(0xBAD);
        vm.prank(admin);
        otc.proposeSetOfferingFeeRecipient(alphaId, thief);

        // Relayed "as the approver": the role check must see the forwarder, not the suffix.
        bytes32 approverRole = otc.APPROVER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(forwarder), approverRole
            )
        );
        forwarder.relay(
            address(otc), abi.encodeCall(OTCTrading.approveSetOfferingFeeRecipient, (alphaId, thief)), approver
        );

        assertEq(otc.getOffering(alphaId).feeRecipient, feeAlpha, "fees were not redirected");
    }

    function test_M1_a_forwarder_cannot_propose_or_cancel_as_the_admin() public {
        MockForwarder forwarder = new MockForwarder();
        vm.prank(admin);
        otc.proposeSetTrustedForwarder(address(forwarder));
        vm.prank(approver);
        otc.approveSetTrustedForwarder(address(forwarder));

        bytes32 adminRole = otc.ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(forwarder), adminRole
            )
        );
        forwarder.relay(address(otc), abi.encodeCall(OTCTrading.pause, ()), admin);

        // cancelProposal is not role-gated but checks the caller against the proposer/admin: the
        // forwarder must not be able to withdraw someone else's proposal either.
        vm.prank(admin);
        otc.proposeSetOfferingFeeRecipient(alphaId, address(0xF00D));
        bytes32 id = otc.offeringFeeRecipientProposalId(alphaId, address(0xF00D));

        vm.expectRevert(OTCTrading.NotAllowedToCancel.selector);
        forwarder.relay(address(otc), abi.encodeCall(OTCTrading.cancelProposal, (id)), admin);
    }

    /// @dev And trading through the forwarder still works — the fix is scoped to governance.
    function test_M1_relayed_trading_is_unaffected() public {
        MockForwarder forwarder = new MockForwarder();
        vm.prank(admin);
        otc.proposeSetTrustedForwarder(address(forwarder));
        vm.prank(approver);
        otc.approveSetTrustedForwarder(address(forwarder));

        bytes memory data = abi.encodeCall(
            OTCTrading.createOrder, (alphaId, OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18)
        );
        uint256 orderId = abi.decode(forwarder.relay(address(otc), data, maker), (uint256));
        assertEq(otc.getOrder(orderId).maker, maker);
    }

    // ---- V2-M2: the price band must not reject legitimate instruments ----

    /// @dev A share with 0 decimals priced at 1,000 ETH is a perfectly ordinary tokenized asset,
    /// and v2's inherited band refused it with PriceTooHigh.
    function test_M2_a_high_value_low_decimal_instrument_can_be_listed_and_traded() public {
        MockERC20 share = new MockERC20("Building", "BLDG"); // treat units as whole shares
        address[] memory cpts = new address[](1);
        cpts[0] = ETH;

        OTCTrading.OfferingConfig memory cfg = OTCTrading.OfferingConfig({
            baseToken: address(share),
            feeRecipient: feeAlpha,
            eligibilityRegistry: address(0),
            makerFeeBps: uint16(MAKER_BPS),
            takerFeeBps: uint16(TAKER_BPS),
            defaultOrderExpiration: 0,
            minOrderSize: 1,
            maxOrderSize: 0,
            offeringRef: bytes32(0),
            counterpartyTokens: cpts
        });
        vm.prank(admin);
        uint256 offeringId = otc.createOffering(cfg);

        share.mint(maker, 10);
        vm.prank(maker);
        share.approve(address(otc), 10);

        // 1 share for 1,000 ETH: price = 1e21 * 1e18 / 1 = 1e39, past the old 1e36 ceiling.
        uint256 orderId = _sellOrder(offeringId, maker, ETH, 1, 1000 ether);

        vm.deal(taker, 2000 ether);
        (,,, uint256 takerPays,) = otc.quoteFill(orderId, 1);
        vm.prank(taker);
        otc.fillOrder{value: takerPays}(orderId, 1);
        assertEq(share.balanceOf(taker), 1);
    }

    function test_M2_zero_price_is_still_refused() public {
        vm.prank(maker);
        vm.expectRevert(OTCTrading.PriceTooLow.selector);
        otc.createOrder(alphaId, OTCTrading.OrderType.SELL, address(usdc), 1e30, 1);
    }

    // ---- V2-M3: dust fills must not evade fees ----

    /// @dev At 0.25%/0.50%, any fill settling below 400 counterparty units pays no fee at all. With
    /// no minimum fill, a taker could take an entire order in slices that each round to zero.
    function test_M3_a_partial_fill_below_the_offerings_minimum_is_refused() public {
        // minOrderSize is 100 on alpha. Price: 1e21 base for 1e6 USDC-units (1 USDC at 6dp).
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1e21, 1e6);

        // A 10-unit slice settles to ceil(10 * 1e6 / 1e21) = 1 unit — and 0 fee. Refused.
        vm.prank(taker);
        vm.expectRevert(OTCTrading.FillBelowMinimum.selector);
        otc.fillOrder(orderId, 10);
    }

    /// @dev The remainder is always takeable, however small, so an order can always be closed out.
    function test_M3_the_remainder_may_be_smaller_than_the_minimum() public {
        vm.prank(admin);
        otc.setOfferingLimits(alphaId, 400e18, 0, 0);
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(taker);
        otc.fillOrder(orderId, 900e18);

        // 100e18 is below the 400e18 minimum, but it is everything that is left.
        vm.prank(taker);
        otc.fillOrder(orderId, 100e18);
        assertFalse(otc.getOrder(orderId).isActive);
    }

    // ---- V2-L1: closing must not be raceable ----

    function test_L1_closing_requires_the_offering_to_be_paused_first() public {
        vm.prank(admin);
        vm.expectRevert(OTCTrading.OfferingNotPaused.selector);
        otc.proposeCloseOffering(alphaId);

        vm.prank(admin);
        otc.setOfferingPaused(alphaId, true);

        vm.prank(admin);
        otc.proposeCloseOffering(alphaId);

        // Nobody can slip an order in while it is paused, so the approval cannot be bricked.
        vm.prank(maker);
        vm.expectRevert(OTCTrading.OfferingNotActive.selector);
        otc.createOrder(alphaId, OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);

        vm.prank(approver);
        otc.approveCloseOffering(alphaId);
        assertEq(uint256(otc.getOffering(alphaId).state), uint256(OTCTrading.OfferingState.Closed));
    }

    // ---- V2-L2: the venue must not be its own fee recipient ----

    function test_L2_the_contract_itself_is_refused_as_fee_recipient() public {
        vm.prank(admin);
        vm.expectRevert(OTCTrading.InvalidFeeRecipient.selector);
        otc.proposeSetOfferingFeeRecipient(alphaId, address(otc));

        address[] memory cpts = new address[](1);
        cpts[0] = address(usdc);
        OTCTrading.OfferingConfig memory cfg = OTCTrading.OfferingConfig({
            baseToken: address(alphaToken),
            feeRecipient: address(otc),
            eligibilityRegistry: address(0),
            makerFeeBps: 0,
            takerFeeBps: 0,
            defaultOrderExpiration: 0,
            minOrderSize: 1,
            maxOrderSize: 0,
            offeringRef: bytes32(0),
            counterpartyTokens: cpts
        });
        vm.prank(admin);
        vm.expectRevert(OTCTrading.InvalidFeeRecipient.selector);
        otc.createOffering(cfg);
    }

    // ---- V2-L3: tokens must be contracts ----

    function test_L3_a_non_contract_base_token_is_refused_at_listing() public {
        address[] memory cpts = new address[](1);
        cpts[0] = address(usdc);
        OTCTrading.OfferingConfig memory cfg = OTCTrading.OfferingConfig({
            baseToken: address(0xDEAD),
            feeRecipient: feeAlpha,
            eligibilityRegistry: address(0),
            makerFeeBps: 0,
            takerFeeBps: 0,
            defaultOrderExpiration: 0,
            minOrderSize: 1,
            maxOrderSize: 0,
            offeringRef: bytes32(0),
            counterpartyTokens: cpts
        });
        vm.prank(admin);
        vm.expectRevert(OTCTrading.InvalidBaseToken.selector);
        otc.createOffering(cfg);
    }

    function test_L3_a_non_contract_counterparty_token_is_refused() public {
        vm.prank(admin);
        vm.expectRevert(OTCTrading.InvalidCounterpartyToken.selector);
        otc.allowCounterpartyToken(alphaId, address(0xDEAD));
    }

    // ---- V2-I1: cleanup is indexable per order ----

    function test_I1_cleanup_emits_one_event_per_order() public {
        vm.prank(admin);
        otc.setOfferingLimits(alphaId, 100, 0, 1 days);
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);
        vm.warp(block.timestamp + 2 days);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        vm.expectEmit(true, true, true, true);
        emit OTCTrading.OrderCleanedUp(orderId, alphaId, maker);
        vm.prank(other);
        otc.cleanupExpiredOrders(ids);
    }

    // ---- V2-I2: quoteFill answers for BUY orders too ----

    function test_I2_quoteFill_is_meaningful_in_both_directions() public {
        uint256 buyId = _buyOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);
        (uint256 cpt, uint256 makerFee, uint256 takerFee, uint256 takerNet, uint256 makerNet) =
            otc.quoteFill(buyId, 1000e18);

        assertEq(takerNet, cpt - takerFee, "what the taker RECEIVES on a BUY");
        assertEq(makerNet, cpt + makerFee, "what the maker PAYS on a BUY");

        uint256 takerBefore = usdc.balanceOf(taker);
        uint256 makerBefore = usdc.balanceOf(maker);
        vm.prank(taker);
        otc.fillOrder(buyId, 1000e18);
        assertEq(usdc.balanceOf(taker), takerBefore + takerNet);
        assertEq(usdc.balanceOf(maker), makerBefore - makerNet);
    }
}
