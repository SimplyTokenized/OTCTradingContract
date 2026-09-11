// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OTCTestBase} from "./utils/OTCTestBase.sol";
import {OTCTrading} from "../src/OTCTrading.sol";
import {MockERC20} from "./utils/Mocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev The v2 claim under test: one contract, many books, and nothing shared between them that
/// should not be.
contract OfferingsTest is OTCTestBase {
    function test_offerings_are_independent_instruments() public view {
        OTCTrading.Offering memory alpha = otc.getOffering(alphaId);
        OTCTrading.Offering memory beta = otc.getOffering(betaId);

        assertEq(alpha.baseToken, address(alphaToken));
        assertEq(beta.baseToken, address(betaToken));
        assertEq(alpha.feeRecipient, feeAlpha);
        assertEq(beta.feeRecipient, feeBeta);
        assertTrue(alpha.offeringRef != beta.offeringRef);
    }

    function test_createOffering_rejects_bad_configuration() public {
        address[] memory cpts = new address[](1);
        cpts[0] = address(usdc);

        OTCTrading.OfferingConfig memory cfg = OTCTrading.OfferingConfig({
            baseToken: address(alphaToken),
            feeRecipient: feeAlpha,
            eligibilityRegistry: address(0),
            makerFeeBps: uint16(MAKER_BPS),
            takerFeeBps: uint16(TAKER_BPS),
            defaultOrderExpiration: 0,
            minOrderSize: 100,
            maxOrderSize: 0,
            offeringRef: bytes32(0),
            counterpartyTokens: cpts
        });

        cfg.baseToken = address(0);
        vm.prank(admin);
        vm.expectRevert(OTCTrading.InvalidBaseToken.selector);
        otc.createOffering(cfg);
        cfg.baseToken = address(alphaToken);

        cfg.feeRecipient = address(0);
        vm.prank(admin);
        vm.expectRevert(OTCTrading.InvalidFeeRecipient.selector);
        otc.createOffering(cfg);
        cfg.feeRecipient = feeAlpha;

        cfg.makerFeeBps = 1001;
        vm.prank(admin);
        vm.expectRevert(OTCTrading.FeeTooHigh.selector);
        otc.createOffering(cfg);
        cfg.makerFeeBps = uint16(MAKER_BPS);

        cfg.minOrderSize = 0;
        vm.prank(admin);
        vm.expectRevert(OTCTrading.InvalidOrderSizeBounds.selector);
        otc.createOffering(cfg);
        cfg.minOrderSize = 100;

        cfg.maxOrderSize = 99;
        vm.prank(admin);
        vm.expectRevert(OTCTrading.InvalidOrderSizeBounds.selector);
        otc.createOffering(cfg);
    }

    function test_createOffering_rejects_base_token_as_its_own_counterparty() public {
        address[] memory cpts = new address[](1);
        cpts[0] = address(alphaToken);

        OTCTrading.OfferingConfig memory cfg = OTCTrading.OfferingConfig({
            baseToken: address(alphaToken),
            feeRecipient: feeAlpha,
            eligibilityRegistry: address(0),
            makerFeeBps: uint16(MAKER_BPS),
            takerFeeBps: uint16(TAKER_BPS),
            defaultOrderExpiration: 0,
            minOrderSize: 100,
            maxOrderSize: 0,
            offeringRef: bytes32(0),
            counterpartyTokens: cpts
        });

        vm.prank(admin);
        vm.expectRevert(OTCTrading.CounterpartyIsBaseToken.selector);
        otc.createOffering(cfg);
    }

    /// @dev The listing that mattered most in v1 was contract-wide. Here it is not.
    function test_counterparty_listing_is_per_offering() public {
        MockERC20 dai = new MockERC20("Dai", "DAI");

        vm.prank(admin);
        otc.allowCounterpartyToken(alphaId, address(dai));

        assertTrue(otc.offeringCounterpartyTokens(alphaId, address(dai)));
        assertFalse(otc.offeringCounterpartyTokens(betaId, address(dai)));

        dai.mint(maker, 1e24);
        vm.prank(maker);
        dai.approve(address(otc), type(uint256).max);

        // Fine on alpha, refused on beta.
        _sellOrder(alphaId, maker, address(dai), 1000, 1000);

        vm.prank(maker);
        vm.expectRevert(OTCTrading.TokenNotAllowed.selector);
        otc.createOrder(betaId, OTCTrading.OrderType.SELL, address(dai), 1000, 1000);
    }

    function test_delisting_does_not_cancel_resting_orders() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000, 2000);

        vm.prank(admin);
        otc.disallowCounterpartyToken(alphaId, address(usdc));

        // New orders are refused...
        vm.prank(maker);
        vm.expectRevert(OTCTrading.TokenNotAllowed.selector);
        otc.createOrder(alphaId, OTCTrading.OrderType.SELL, address(usdc), 1000, 2000);

        // ...but the resting one still settles. De-listing is not confiscation.
        vm.prank(taker);
        otc.fillOrder(orderId, 1000);
        assertEq(otc.getRemainingAmount(orderId), 0);
    }

    function test_fee_schedule_is_per_offering_and_not_retroactive() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(admin);
        otc.setOfferingFees(alphaId, 1000, 1000);

        // Beta is untouched by alpha's change.
        assertEq(otc.getOffering(betaId).makerFeeBps, uint16(MAKER_BPS));

        // And the resting order keeps the rates it was created with.
        (,, uint256 takerFee,,) = otc.quoteFill(orderId, 1000e18);
        assertEq(takerFee, (2000e18 * TAKER_BPS) / 10000);
    }

    function test_setOfferingFees_enforces_the_cap() public {
        vm.prank(admin);
        vm.expectRevert(OTCTrading.FeeTooHigh.selector);
        otc.setOfferingFees(alphaId, 1001, 0);
    }

    function test_size_band_is_per_offering() public {
        vm.prank(admin);
        otc.setOfferingLimits(alphaId, 1000, 5000, 0);

        vm.prank(maker);
        vm.expectRevert(OTCTrading.OrderSizeBelowMinimum.selector);
        otc.createOrder(alphaId, OTCTrading.OrderType.SELL, address(usdc), 999, 2000);

        vm.prank(maker);
        vm.expectRevert(OTCTrading.OrderSizeAboveMaximum.selector);
        otc.createOrder(alphaId, OTCTrading.OrderType.SELL, address(usdc), 5001, 10000);

        // Beta still takes what alpha now refuses.
        _sellOrder(betaId, maker, address(usdc), 999, 2000);
    }

    /// @dev A halt on one book must not reach the others — the reason a global pause is not enough.
    function test_pausing_one_offering_leaves_the_others_trading() public {
        vm.prank(admin);
        otc.setOfferingPaused(alphaId, true);

        vm.prank(maker);
        vm.expectRevert(OTCTrading.OfferingNotActive.selector);
        otc.createOrder(alphaId, OTCTrading.OrderType.SELL, address(usdc), 1000, 2000);

        uint256 betaOrder = _sellOrder(betaId, maker, address(usdc), 1000, 2000);
        vm.prank(taker);
        otc.fillOrder(betaOrder, 1000);

        vm.prank(admin);
        otc.setOfferingPaused(alphaId, false);
        _sellOrder(alphaId, maker, address(usdc), 1000, 2000);
    }

    function test_paused_offering_blocks_fills_but_not_exits() public {
        uint256 orderId = _buyEthOrder(alphaId, maker, 1000, 1 ether);

        vm.prank(admin);
        otc.setOfferingPaused(alphaId, true);

        vm.prank(taker);
        vm.expectRevert(OTCTrading.OfferingNotActive.selector);
        otc.fillOrder(orderId, 1000);

        // The maker can still leave and take their escrow with them.
        vm.prank(maker);
        otc.cancelOrder(orderId);
        assertEq(otc.pendingWithdrawals(maker), 1 ether + (1 ether * MAKER_BPS) / 10000);
    }

    function test_setOfferingPaused_rejects_a_no_op() public {
        vm.prank(admin);
        vm.expectRevert(OTCTrading.OfferingStateUnchanged.selector);
        otc.setOfferingPaused(alphaId, false);
    }

    function test_unknown_offering_is_rejected() public {
        vm.prank(admin);
        vm.expectRevert(OTCTrading.OfferingNotFound.selector);
        otc.setOfferingFees(999, 10, 10);

        vm.prank(maker);
        vm.expectRevert(OTCTrading.OfferingNotFound.selector);
        otc.createOrder(999, OTCTrading.OrderType.SELL, address(usdc), 1000, 2000);
    }

    function test_only_operator_may_list_an_offering() public {
        address[] memory cpts = new address[](1);
        cpts[0] = address(usdc);

        OTCTrading.OfferingConfig memory cfg = OTCTrading.OfferingConfig({
            baseToken: address(alphaToken),
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

        // The role is read BEFORE the prank on purpose: it is an external call, and it would
        // otherwise consume the prank and leave the test asserting about the wrong caller.
        bytes32 operatorRole = otc.OPERATOR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, operatorRole)
        );
        vm.prank(other);
        otc.createOffering(cfg);
    }

    /// @dev Two offerings may share a base token — a second tranche of the same instrument on
    /// different terms is a normal thing for an issuer to want.
    function test_two_offerings_may_share_a_base_token() public {
        uint256 secondAlpha = _createOffering(address(alphaToken), feeAlpha, address(0));
        assertTrue(secondAlpha != alphaId);

        uint256 a = _sellOrder(alphaId, maker, address(usdc), 1000, 2000);
        uint256 b = _sellOrder(secondAlpha, maker, address(usdc), 1000, 3000);

        assertEq(otc.getOrder(a).offeringId, alphaId);
        assertEq(otc.getOrder(b).offeringId, secondAlpha);
    }
}
