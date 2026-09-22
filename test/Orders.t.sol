// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OTCTestBase} from "./utils/OTCTestBase.sol";
import {OTCTrading} from "../src/OTCTrading.sol";
import {MockERC20} from "./utils/Mocks.sol";

/// @dev Placing, funding, expiring and withdrawing orders — the allowance/escrow custody model.
contract OrdersTest is OTCTestBase {
    function test_sell_order_is_backed_by_allowance_not_deposit() public {
        uint256 before = alphaToken.balanceOf(maker);
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        assertEq(alphaToken.balanceOf(maker), before, "maker kept custody");
        assertEq(alphaToken.balanceOf(address(otc)), 0, "venue took no custody");
        assertTrue(otc.isOrderFundable(orderId));
    }

    function test_buy_order_in_erc20_is_backed_by_allowance() public {
        uint256 before = usdc.balanceOf(maker);
        _buyOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        assertEq(usdc.balanceOf(maker), before);
        assertEq(usdc.balanceOf(address(otc)), 0);
    }

    /// @dev The single exception to non-custody, and the reason it exists.
    function test_buy_order_in_eth_must_escrow_counterparty_plus_maker_fee() public {
        uint256 counterparty = 10 ether;
        uint256 expected = counterparty + (counterparty * MAKER_BPS) / 10000;

        uint256 orderId = _buyEthOrder(alphaId, maker, 1000e18, counterparty);

        assertEq(otc.ethEscrowed(orderId), expected);
        assertEq(otc.totalEthEscrowed(), expected);
        assertEq(address(otc).balance, expected);
        _assertEthReserveHolds();
    }

    function test_buy_order_in_eth_rejects_a_wrong_deposit() public {
        vm.prank(maker);
        vm.expectRevert(OTCTrading.IncorrectEthAmount.selector);
        otc.createOrder{value: 1 ether}(alphaId, OTCTrading.OrderType.BUY, ETH, 1000e18, 1 ether);
    }

    function test_allowance_backed_order_refuses_value() public {
        vm.prank(maker);
        vm.expectRevert(OTCTrading.EthNotAccepted.selector);
        otc.createOrder{value: 1 wei}(alphaId, OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
    }

    function test_creation_prechecks_allowance_and_balance() public {
        address poor = address(0xD00D);
        vm.deal(poor, 1 ether);

        vm.prank(poor);
        vm.expectRevert(OTCTrading.InsufficientAllowance.selector);
        otc.createOrder(alphaId, OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);

        vm.prank(poor);
        alphaToken.approve(address(otc), type(uint256).max);

        vm.prank(poor);
        vm.expectRevert(OTCTrading.InsufficientBalance.selector);
        otc.createOrder(alphaId, OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
    }

    /// @dev The precheck is a courtesy, not a guarantee — and the contract says so.
    function test_allowance_backed_order_can_become_unfundable_without_being_cancelled() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(maker);
        alphaToken.approve(address(otc), 0);

        assertFalse(otc.isOrderFundable(orderId));
        assertTrue(otc.getOrder(orderId).isActive, "an unfunded order stays on the book");

        vm.prank(taker);
        vm.expectRevert();
        otc.fillOrder(orderId, 1000e18);
    }

    function test_zero_and_absurd_prices_are_refused() public {
        vm.prank(maker);
        vm.expectRevert(OTCTrading.InvalidCounterpartyAmount.selector);
        otc.createOrder(alphaId, OTCTrading.OrderType.SELL, address(usdc), 1000e18, 0);

        // 1 wei of counterparty against a huge base amount rounds the price below the floor.
        vm.prank(maker);
        vm.expectRevert(OTCTrading.PriceTooLow.selector);
        otc.createOrder(alphaId, OTCTrading.OrderType.SELL, address(usdc), 1e30, 1);

        // There is no upper band — see AuditTest.test_M2_*. A steep price is a legitimate price.
        _sellOrder(alphaId, maker, address(usdc), 100, 1e21);
    }

    function test_expiry_is_stamped_from_the_offerings_default() public {
        vm.prank(admin);
        otc.setOfferingLimits(alphaId, 100, 0, 1 days);

        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);
        assertEq(otc.getOrder(orderId).expiresAt, uint48(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 days);
        assertTrue(otc.isOrderExpired(orderId));
        assertEq(otc.getRemainingAmount(orderId), 0);

        vm.prank(taker);
        vm.expectRevert(OTCTrading.OrderExpired.selector);
        otc.fillOrder(orderId, 1000e18);
    }

    function test_cancel_returns_escrow_as_a_pending_withdrawal() public {
        uint256 orderId = _buyEthOrder(alphaId, maker, 1000e18, 10 ether);
        uint256 escrow = otc.ethEscrowed(orderId);

        vm.prank(maker);
        otc.cancelOrder(orderId);

        assertEq(otc.ethEscrowed(orderId), 0);
        assertEq(otc.totalEthEscrowed(), 0);
        assertEq(otc.pendingWithdrawals(maker), escrow);
        assertEq(otc.totalPendingWithdrawals(), escrow);
        _assertEthReserveHolds();

        uint256 before = maker.balance;
        vm.prank(maker);
        otc.withdraw();
        assertEq(maker.balance, before + escrow);
        assertEq(otc.totalPendingWithdrawals(), 0);
    }

    function test_only_the_maker_may_cancel() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(taker);
        vm.expectRevert(OTCTrading.NotOrderMaker.selector);
        otc.cancelOrder(orderId);
    }

    function test_cancel_is_idempotent_only_once() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(maker);
        otc.cancelOrder(orderId);

        vm.prank(maker);
        vm.expectRevert(OTCTrading.OrderNotActive.selector);
        otc.cancelOrder(orderId);
    }

    function test_batchCancel_skips_what_is_not_yours_and_bounds_its_size() public {
        uint256 mine1 = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);
        uint256 mine2 = _sellOrder(betaId, maker, address(usdc), 1000e18, 2000e18);
        uint256 theirs = _sellOrder(alphaId, taker, address(usdc), 1000e18, 2000e18);

        uint256[] memory ids = new uint256[](3);
        ids[0] = mine1;
        ids[1] = mine2;
        ids[2] = theirs;

        vm.prank(maker);
        otc.batchCancelOrders(ids);

        assertFalse(otc.getOrder(mine1).isActive);
        assertFalse(otc.getOrder(mine2).isActive);
        assertTrue(otc.getOrder(theirs).isActive, "someone else's order is untouched");

        uint256[] memory tooMany = new uint256[](201);
        vm.prank(maker);
        vm.expectRevert(OTCTrading.InvalidBatchSize.selector);
        otc.batchCancelOrders(tooMany);
    }

    /// @dev Permissionless cleanup pays the MAKER, never the caller — so there is nothing to farm.
    function test_cleanupExpiredOrders_is_permissionless_and_refunds_the_maker() public {
        vm.prank(admin);
        otc.setOfferingLimits(alphaId, 100, 0, 1 days);

        uint256 orderId = _buyEthOrder(alphaId, maker, 1000e18, 5 ether);
        uint256 escrow = otc.ethEscrowed(orderId);

        vm.warp(block.timestamp + 1 days + 1);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        uint256 callerBefore = other.balance;
        vm.prank(other);
        uint256 cleaned = otc.cleanupExpiredOrders(ids);

        assertEq(cleaned, 1);
        assertEq(other.balance, callerBefore, "the caller gains nothing");
        assertEq(otc.pendingWithdrawals(maker), escrow);
        assertEq(otc.pendingWithdrawals(other), 0);
    }

    function test_cleanup_ignores_live_orders() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        vm.prank(other);
        assertEq(otc.cleanupExpiredOrders(ids), 0);
        assertTrue(otc.getOrder(orderId).isActive);
    }

    function test_withdraw_with_nothing_owed_reverts() public {
        vm.prank(other);
        vm.expectRevert(OTCTrading.NothingToWithdraw.selector);
        otc.withdraw();
    }

    function testFuzz_escrow_always_covers_the_orders_obligation(uint96 base, uint96 counterparty) public {
        base = uint96(bound(base, 100, type(uint96).max));
        counterparty = uint96(bound(counterparty, 1e6, type(uint96).max));
        vm.assume(uint256(counterparty) * 1e18 / uint256(base) >= 1);

        uint256 escrow = uint256(counterparty) + (uint256(counterparty) * MAKER_BPS) / 10000;
        vm.deal(maker, escrow);

        vm.prank(maker);
        uint256 orderId = otc.createOrder{value: escrow}(
            alphaId, OTCTrading.OrderType.BUY, ETH, uint256(base), uint256(counterparty)
        );

        assertEq(otc.ethEscrowed(orderId), escrow);
        _assertEthReserveHolds();
    }
}
