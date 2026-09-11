// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OTCTestBase} from "./utils/OTCTestBase.sol";
import {OTCTrading} from "../src/OTCTrading.sol";

/// @dev Settlement: who pays what, in both directions, in ERC-20 and in ETH, whole and in parts.
contract FillsTest is OTCTestBase {
    function test_sell_in_erc20_settles_both_legs_directly() public {
        uint256 base = 1000e18;
        uint256 counterparty = 2000e18;
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), base, counterparty);

        uint256 makerFee = (counterparty * MAKER_BPS) / 10000;
        uint256 takerFee = (counterparty * TAKER_BPS) / 10000;

        uint256 makerAlpha = alphaToken.balanceOf(maker);
        uint256 makerUsdc = usdc.balanceOf(maker);
        uint256 takerAlpha = alphaToken.balanceOf(taker);
        uint256 takerUsdc = usdc.balanceOf(taker);

        vm.prank(taker);
        otc.fillOrder(orderId, base);

        assertEq(alphaToken.balanceOf(maker), makerAlpha - base);
        assertEq(alphaToken.balanceOf(taker), takerAlpha + base);
        assertEq(usdc.balanceOf(maker), makerUsdc + counterparty - makerFee);
        assertEq(usdc.balanceOf(taker), takerUsdc - counterparty - takerFee);
        assertEq(usdc.balanceOf(feeAlpha), makerFee + takerFee);
        assertEq(usdc.balanceOf(address(otc)), 0, "the venue never holds the counterparty asset");
    }

    /// @dev The fee split is symmetric: the maker bears the maker fee whichever side they are on.
    function test_buy_in_erc20_is_fee_symmetric_with_sell() public {
        uint256 base = 1000e18;
        uint256 counterparty = 2000e18;
        uint256 orderId = _buyOrder(alphaId, maker, address(usdc), base, counterparty);

        uint256 makerFee = (counterparty * MAKER_BPS) / 10000;
        uint256 takerFee = (counterparty * TAKER_BPS) / 10000;

        uint256 makerUsdc = usdc.balanceOf(maker);
        uint256 takerUsdc = usdc.balanceOf(taker);

        vm.prank(taker);
        otc.fillOrder(orderId, base);

        assertEq(usdc.balanceOf(maker), makerUsdc - counterparty - makerFee, "maker pays price plus maker fee");
        assertEq(usdc.balanceOf(taker), takerUsdc + counterparty - takerFee, "taker receives price minus taker fee");
        assertEq(usdc.balanceOf(feeAlpha), makerFee + takerFee);
    }

    function test_sell_in_eth_credits_the_maker_and_refunds_the_takers_excess() public {
        uint256 base = 1000e18;
        uint256 counterparty = 10 ether;
        uint256 orderId = _sellOrder(alphaId, maker, ETH, base, counterparty);

        uint256 makerFee = (counterparty * MAKER_BPS) / 10000;
        uint256 takerFee = (counterparty * TAKER_BPS) / 10000;
        uint256 takerBalance = taker.balance;

        vm.prank(taker);
        otc.fillOrder{value: counterparty + takerFee + 3 ether}(orderId, base);

        assertEq(taker.balance, takerBalance - counterparty - takerFee, "excess came back inline");
        assertEq(otc.pendingWithdrawals(maker), counterparty - makerFee, "maker proceeds are pull-payment");
        assertEq(otc.pendingWithdrawals(feeAlpha), makerFee + takerFee);
        _assertEthReserveHolds();
    }

    function test_sell_in_eth_requires_enough_value() public {
        uint256 orderId = _sellOrder(alphaId, maker, ETH, 1000e18, 10 ether);

        vm.prank(taker);
        vm.expectRevert(OTCTrading.InsufficientEthSent.selector);
        otc.fillOrder{value: 1 ether}(orderId, 1000e18);
    }

    function test_buy_in_eth_pays_the_taker_out_of_escrow() public {
        uint256 base = 1000e18;
        uint256 counterparty = 10 ether;
        uint256 orderId = _buyEthOrder(alphaId, maker, base, counterparty);

        uint256 makerFee = (counterparty * MAKER_BPS) / 10000;
        uint256 takerFee = (counterparty * TAKER_BPS) / 10000;
        uint256 takerBalance = taker.balance;

        vm.prank(taker);
        otc.fillOrder(orderId, base);

        assertEq(taker.balance, takerBalance + counterparty - takerFee, "taker is paid inline");
        assertEq(otc.pendingWithdrawals(feeAlpha), makerFee + takerFee);
        assertEq(otc.ethEscrowed(orderId), 0, "escrow is fully spent");
        assertEq(otc.totalEthEscrowed(), 0);
        _assertEthReserveHolds();
    }

    function test_taker_may_not_send_value_where_none_is_owed() public {
        uint256 orderId = _buyEthOrder(alphaId, maker, 1000e18, 10 ether);

        vm.prank(taker);
        vm.expectRevert(OTCTrading.EthNotAccepted.selector);
        otc.fillOrder{value: 1 wei}(orderId, 1000e18);
    }

    function test_partial_fills_accumulate_and_close_the_order() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(taker);
        otc.fillOrder(orderId, 400e18);
        assertEq(otc.getRemainingAmount(orderId), 600e18);
        assertTrue(otc.getOrder(orderId).isActive);

        vm.prank(taker);
        otc.fillOrder(orderId, 600e18);
        assertEq(otc.getRemainingAmount(orderId), 0);
        assertFalse(otc.getOrder(orderId).isActive);
        assertEq(otc.getOffering(alphaId).openOrderCount, 0);
    }

    function test_overfilling_is_refused() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(taker);
        vm.expectRevert(OTCTrading.ExceedsOrderSize.selector);
        otc.fillOrder(orderId, 1001e18);
    }

    function test_a_maker_cannot_fill_their_own_order() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(maker);
        vm.expectRevert(OTCTrading.CannotFillOwnOrder.selector);
        otc.fillOrder(orderId, 1000e18);
    }

    function test_a_zero_fill_is_refused() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(taker);
        vm.expectRevert(OTCTrading.InvalidFillAmount.selector);
        otc.fillOrder(orderId, 0);
    }

    /// @dev A BUY rounds down so escrow can never be overdrawn; a SELL rounds up so a long tail of
    /// small fills cannot bleed the resting maker.
    function test_rounding_favours_the_resting_maker_in_both_directions() public {
        // 100 of a 300-unit order priced at 1000: the exact share is 333.33...
        uint256 sellId = _sellOrder(alphaId, maker, address(usdc), 300, 1000);
        (uint256 sellCpt,,,,) = otc.quoteFill(sellId, 100);
        assertEq(sellCpt, 334, "SELL rounds up, so the maker receives the fraction");

        uint256 buyId = _buyOrder(alphaId, maker, address(usdc), 300, 1000);
        (uint256 buyCpt,,,,) = otc.quoteFill(buyId, 100);
        assertEq(buyCpt, 333, "BUY rounds down, so the maker never pays it");
    }

    function test_a_fill_that_settles_to_zero_is_refused() public {
        // 1000 units of counterparty over 1e12 of base: a minimum-size (100) fill still rounds to
        // nothing — floor(100 * 1000 / 1e12) = 0.
        uint256 orderId = _buyOrder(alphaId, maker, address(usdc), 1e12, 1000);

        vm.prank(taker);
        vm.expectRevert(OTCTrading.FillRoundsToZero.selector);
        otc.fillOrder(orderId, 100);
    }

    /// @dev The escrow arithmetic across many partial fills, including the dust returned at the end.
    function test_partial_eth_buy_fills_never_overdraw_escrow_and_return_the_dust() public {
        uint256 base = 999;
        uint256 counterparty = 10 ether + 7;
        uint256 orderId = _buyEthOrder(alphaId, maker, base, counterparty);
        uint256 escrow = otc.ethEscrowed(orderId);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(taker);
            otc.fillOrder(orderId, 333);
            _assertEthReserveHolds();
        }

        assertEq(otc.ethEscrowed(orderId), 0, "escrow is fully released at the close");
        assertEq(otc.totalEthEscrowed(), 0);
        assertFalse(otc.getOrder(orderId).isActive);

        // Whatever rounding left behind went back to the maker, not to the venue.
        uint256 makerRefund = otc.pendingWithdrawals(maker);
        uint256 fees = otc.pendingWithdrawals(feeAlpha);
        assertLe(makerRefund + fees, escrow);
    }

    function test_a_global_pause_stops_fills_but_not_exits() public {
        uint256 orderId = _buyEthOrder(alphaId, maker, 1000e18, 10 ether);

        vm.prank(admin);
        otc.pause();

        vm.prank(taker);
        vm.expectRevert();
        otc.fillOrder(orderId, 1000e18);

        vm.prank(maker);
        otc.cancelOrder(orderId);
        vm.prank(maker);
        otc.withdraw();
    }

    /// @dev Two books, one contract: filling on one must not move anything on the other.
    function testFuzz_fills_on_one_offering_never_touch_another(uint96 baseRaw) public {
        uint256 base = bound(baseRaw, 100, 1_000e18);

        uint256 alphaOrder = _sellOrder(alphaId, maker, address(usdc), base, base * 2);
        uint256 betaOrder = _sellOrder(betaId, maker, address(usdc), base, base * 3);

        uint256 betaBefore = betaToken.balanceOf(maker);
        uint256 feeBetaBefore = usdc.balanceOf(feeBeta);

        vm.prank(taker);
        otc.fillOrder(alphaOrder, base);

        assertEq(betaToken.balanceOf(maker), betaBefore, "beta's base token did not move");
        assertEq(usdc.balanceOf(feeBeta), feeBetaBefore, "beta's fee recipient was not paid");
        assertTrue(otc.getOrder(betaOrder).isActive);
    }
}
