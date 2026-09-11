// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OTCTestBase} from "./utils/OTCTestBase.sol";
import {OTCTrading} from "../src/OTCTrading.sol";

/// @dev Reading the book: per-offering indexes and bounded scans, which is what an unbounded
/// "get all active orders" cannot be once one contract carries every offering a tenant has listed.
contract ViewsTest is OTCTestBase {
    function test_order_ids_are_indexed_per_offering() public {
        uint256 a1 = _sellOrder(alphaId, maker, address(usdc), 1000, 2000);
        uint256 b1 = _sellOrder(betaId, maker, address(usdc), 1000, 2000);
        uint256 a2 = _sellOrder(alphaId, taker, address(usdc), 1000, 2000);

        assertEq(otc.offeringOrderCount(alphaId), 2);
        assertEq(otc.offeringOrderCount(betaId), 1);

        (uint256[] memory alphaIds, uint256 total) = otc.getOfferingOrders(alphaId, 0, 10);
        assertEq(total, 2);
        assertEq(alphaIds[0], a1);
        assertEq(alphaIds[1], a2);

        (uint256[] memory betaIds,) = otc.getOfferingOrders(betaId, 0, 10);
        assertEq(betaIds[0], b1);
    }

    function test_maker_index_spans_every_offering() public {
        _sellOrder(alphaId, maker, address(usdc), 1000, 2000);
        _sellOrder(betaId, maker, address(usdc), 1000, 2000);

        (uint256[] memory ids, uint256 total) = otc.getMakerOrders(maker, 0, 10);
        assertEq(total, 2);
        assertEq(ids.length, 2);
        assertEq(otc.makerOrderCount(maker), 2);
    }

    function test_pagination_slices_and_bounds() public {
        for (uint256 i = 0; i < 5; i++) {
            _sellOrder(alphaId, maker, address(usdc), 1000, 2000);
        }

        (uint256[] memory page, uint256 total) = otc.getOfferingOrders(alphaId, 2, 2);
        assertEq(total, 5);
        assertEq(page.length, 2);

        (uint256[] memory past,) = otc.getOfferingOrders(alphaId, 99, 10);
        assertEq(past.length, 0, "an offset past the end is empty, not a revert");

        vm.expectRevert(OTCTrading.InvalidPageSize.selector);
        otc.getOfferingOrders(alphaId, 0, 0);

        vm.expectRevert(OTCTrading.InvalidPageSize.selector);
        otc.getOfferingOrders(alphaId, 0, 201);
    }

    /// @dev The scan costs what the caller allowed, however long the book has grown.
    function test_scanActiveOrders_is_bounded_and_resumable() public {
        uint256[] memory created = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            created[i] = _sellOrder(alphaId, maker, address(usdc), 1000, 2000);
        }

        vm.prank(maker);
        otc.cancelOrder(created[1]);
        vm.prank(maker);
        otc.cancelOrder(created[4]);

        (uint256[] memory first, uint256 cursor) = otc.scanActiveOrders(alphaId, 0, 3);
        assertEq(cursor, 3);
        assertEq(first.length, 2, "one of the first three was cancelled");

        (uint256[] memory second, uint256 nextCursor) = otc.scanActiveOrders(alphaId, cursor, 3);
        assertEq(nextCursor, 6);
        assertEq(second.length, 2);

        (uint256[] memory done, uint256 endCursor) = otc.scanActiveOrders(alphaId, nextCursor, 3);
        assertEq(done.length, 0);
        assertEq(endCursor, 6, "the cursor stops at the end of the book");
    }

    function test_scanActiveOrders_skips_expired_orders() public {
        vm.prank(admin);
        otc.setOfferingLimits(alphaId, 100, 0, 1 days);

        _sellOrder(alphaId, maker, address(usdc), 1000, 2000);
        vm.warp(block.timestamp + 2 days);

        (uint256[] memory ids,) = otc.scanActiveOrders(alphaId, 0, 10);
        assertEq(ids.length, 0);
    }

    function test_scanActiveOrders_bounds_its_window() public {
        vm.expectRevert(OTCTrading.InvalidPageSize.selector);
        otc.scanActiveOrders(alphaId, 0, 0);

        vm.expectRevert(OTCTrading.InvalidPageSize.selector);
        otc.scanActiveOrders(alphaId, 0, 201);
    }

    function test_quoteFill_matches_what_settlement_actually_does() public {
        uint256 base = 1000e18;
        uint256 counterparty = 2000e18;
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), base, counterparty);

        (uint256 cpt, uint256 makerFee, uint256 takerFee, uint256 takerPays, uint256 makerReceives) =
            otc.quoteFill(orderId, base / 2);

        uint256 takerBefore = usdc.balanceOf(taker);
        uint256 makerBefore = usdc.balanceOf(maker);

        vm.prank(taker);
        otc.fillOrder(orderId, base / 2);

        assertEq(usdc.balanceOf(taker), takerBefore - takerPays);
        assertEq(usdc.balanceOf(maker), makerBefore + makerReceives);
        assertEq(takerPays, cpt + takerFee);
        assertEq(makerReceives, cpt - makerFee);
    }

    function test_isOrderFundable_reflects_the_offerings_state() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);
        assertTrue(otc.isOrderFundable(orderId));

        vm.prank(admin);
        otc.setOfferingPaused(alphaId, true);
        assertFalse(otc.isOrderFundable(orderId), "a halted book has nothing fillable on it");
    }

    function test_orderBaseToken_reports_the_offerings_asset() public {
        uint256 a = _sellOrder(alphaId, maker, address(usdc), 1000, 2000);
        uint256 b = _sellOrder(betaId, maker, address(usdc), 1000, 2000);

        assertEq(otc.orderBaseToken(a), address(alphaToken));
        assertEq(otc.orderBaseToken(b), address(betaToken));
    }

    function test_views_answer_for_orders_that_do_not_exist() public view {
        assertEq(otc.getRemainingAmount(4242), 0);
        assertFalse(otc.isOrderExpired(4242));
        assertFalse(otc.isOrderFundable(4242));
    }
}
