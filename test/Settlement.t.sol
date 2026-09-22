// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OTCTestBase} from "./utils/OTCTestBase.sol";
import {OTCTrading} from "../src/OTCTrading.sol";
import {EthRejecter} from "./utils/Mocks.sol";

/// @dev Pull payments and reserve accounting: the two things that let many books share one balance.
contract SettlementTest is OTCTestBase {
    EthRejecter internal hostile;

    function setUp() public override {
        super.setUp();
        hostile = new EthRejecter();

        alphaToken.mint(address(hostile), 1_000_000e18);
        usdc.mint(address(hostile), 1_000_000e18);
        vm.deal(address(hostile), 1_000 ether);

        vm.startPrank(address(hostile));
        alphaToken.approve(address(otc), type(uint256).max);
        usdc.approve(address(otc), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev A maker who cannot receive ETH must not be able to hold the book hostage.
    function test_a_maker_that_rejects_eth_cannot_block_settlement() public {
        uint256 base = 1000e18;
        uint256 counterparty = 10 ether;

        vm.prank(address(hostile));
        uint256 orderId = otc.createOrder(alphaId, OTCTrading.OrderType.SELL, ETH, base, counterparty);

        uint256 takerFee = (counterparty * TAKER_BPS) / 10000;
        vm.prank(taker);
        otc.fillOrder{value: counterparty + takerFee}(orderId, base);

        // The trade settled; the maker's ETH is simply waiting for them.
        assertEq(alphaToken.balanceOf(taker) > 0, true);
        assertGt(otc.pendingWithdrawals(address(hostile)), 0);

        // And their own withdrawal is the only thing that fails.
        vm.expectRevert(OTCTrading.EthTransferFailed.selector);
        hostile.withdraw(otc);
        _assertEthReserveHolds();
    }

    function test_a_fee_recipient_that_rejects_eth_cannot_block_settlement() public {
        vm.prank(admin);
        otc.proposeSetOfferingFeeRecipient(alphaId, address(hostile));
        vm.prank(approver);
        otc.approveSetOfferingFeeRecipient(alphaId, address(hostile));

        uint256 orderId = _buyEthOrder(alphaId, maker, 1000e18, 10 ether);

        vm.prank(taker);
        otc.fillOrder(orderId, 1000e18);

        assertGt(otc.pendingWithdrawals(address(hostile)), 0);
        _assertEthReserveHolds();
    }

    function test_a_maker_that_rejects_eth_cannot_block_a_force_cancel() public {
        uint256 counterparty = 5 ether;
        uint256 escrow = counterparty + (counterparty * MAKER_BPS) / 10000;

        uint256 orderId =
            hostile.createOrder{value: escrow}(otc, alphaId, OTCTrading.OrderType.BUY, 1000e18, counterparty);

        vm.prank(admin);
        otc.adminCancelOrder(orderId);

        assertEq(otc.pendingWithdrawals(address(hostile)), escrow);
        _assertEthReserveHolds();
    }

    function test_withdrawals_are_independent_per_account() public {
        uint256 a = _buyEthOrder(alphaId, maker, 1000e18, 4 ether);
        uint256 b = _buyEthOrder(betaId, taker, 1000e18, 6 ether);

        vm.prank(maker);
        otc.cancelOrder(a);
        vm.prank(taker);
        otc.cancelOrder(b);

        uint256 makerOwed = otc.pendingWithdrawals(maker);
        uint256 takerOwed = otc.pendingWithdrawals(taker);
        assertEq(otc.totalPendingWithdrawals(), makerOwed + takerOwed);

        vm.prank(maker);
        otc.withdraw();

        assertEq(otc.pendingWithdrawals(maker), 0);
        assertEq(otc.pendingWithdrawals(taker), takerOwed, "one withdrawal did not touch the other");
        assertEq(otc.totalPendingWithdrawals(), takerOwed);
        _assertEthReserveHolds();
    }

    /// @dev The cross-offering property, stated as money rather than as configuration.
    function test_one_offerings_escrow_is_never_spendable_by_another() public {
        uint256 alphaOrder = _buyEthOrder(alphaId, maker, 1000e18, 10 ether);
        uint256 betaOrder = _buyEthOrder(betaId, other, 1000e18, 2 ether);

        uint256 betaEscrow = otc.ethEscrowed(betaOrder);

        // Fill alpha's order completely: it can only ever draw on its own escrow.
        vm.prank(taker);
        otc.fillOrder(alphaOrder, 1000e18);

        assertEq(otc.ethEscrowed(alphaOrder), 0);
        assertEq(otc.ethEscrowed(betaOrder), betaEscrow, "beta's escrow is untouched");
        assertEq(otc.totalEthEscrowed(), betaEscrow);

        // And beta's maker can still take all of theirs back.
        vm.prank(other);
        otc.cancelOrder(betaOrder);
        vm.prank(other);
        otc.withdraw();
        assertEq(otc.totalEthEscrowed(), 0);
        _assertEthReserveHolds();
    }

    function test_the_contract_refuses_a_bare_transfer() public {
        vm.prank(maker);
        (bool ok,) = address(otc).call{value: 1 ether}("");
        assertFalse(ok, "there is no receive(): unaccounted ETH cannot get in");
    }

    function test_reserve_totals_track_every_movement() public {
        uint256 orderId = _buyEthOrder(alphaId, maker, 1000e18, 10 ether);
        uint256 escrow = otc.ethEscrowed(orderId);
        assertEq(otc.totalEthEscrowed(), escrow);
        assertEq(address(otc).balance, escrow);

        vm.prank(taker);
        otc.fillOrder(orderId, 400e18);
        _assertEthReserveHolds();

        vm.prank(maker);
        otc.cancelOrder(orderId);
        assertEq(otc.totalEthEscrowed(), 0);
        assertEq(address(otc).balance, otc.totalPendingWithdrawals());

        vm.prank(maker);
        otc.withdraw();
        vm.prank(feeAlpha);
        otc.withdraw();
        assertEq(address(otc).balance, 0, "the venue keeps nothing of its own");
    }

    function testFuzz_the_eth_reserve_always_holds(uint96 counterpartyRaw, uint96 fillRaw) public {
        uint256 counterparty = bound(counterpartyRaw, 1e12, 100 ether);
        uint256 base = 1000e18;
        uint256 fill = bound(fillRaw, 100, base); // alpha's minOrderSize is 100

        uint256 orderId = _buyEthOrder(alphaId, maker, base, counterparty);

        (uint256 cpt,,,,) = otc.quoteFill(orderId, fill);
        if (cpt == 0) return;

        vm.prank(taker);
        otc.fillOrder(orderId, fill);
        _assertEthReserveHolds();

        vm.prank(maker);
        otc.cancelOrder(orderId);
        _assertEthReserveHolds();

        assertEq(otc.totalEthEscrowed(), 0);
        assertEq(address(otc).balance, otc.totalPendingWithdrawals());
    }
}
