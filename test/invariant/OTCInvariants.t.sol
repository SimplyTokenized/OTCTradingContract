// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {OTCTrading} from "../../src/OTCTrading.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {OTCHandler} from "./OTCHandler.sol";

/**
 * @dev The properties a tenant-wide venue lives or dies by, checked against a random walk rather
 * than against the cases someone thought to write down.
 *
 * v1 could state "the balance equals escrow plus withdrawals" in a comment because it held one
 * book. v2 holds every book a tenant has, so the same sentence is now the thing standing between
 * one offering's mistake and another offering's money — which is why it is an invariant here and
 * not a remark.
 */
contract OTCInvariantsTest is Test {
    OTCTrading internal otc;
    OTCHandler internal handler;

    MockERC20 internal alphaToken;
    MockERC20 internal betaToken;
    MockERC20 internal usdc;

    address internal admin = address(0xA0);
    address internal approver = address(0xA1);
    address internal upgrader = address(0xA2);
    address internal feeAlpha = address(0xFEE1);
    address internal feeBeta = address(0xFEE2);

    uint256 internal alphaId;
    uint256 internal betaId;

    address[] internal actors;

    function setUp() public {
        alphaToken = new MockERC20("Alpha", "ALPHA");
        betaToken = new MockERC20("Beta", "BETA");
        usdc = new MockERC20("USD Coin", "USDC");

        address proxy = Upgrades.deployUUPSProxy(
            "OTCTrading.sol", abi.encodeCall(OTCTrading.initialize, (admin, approver, upgrader, address(0)))
        );
        otc = OTCTrading(proxy);

        alphaId = _createOffering(address(alphaToken), feeAlpha, 0);
        betaId = _createOffering(address(betaToken), feeBeta, 1 days);

        for (uint256 i = 0; i < 4; i++) {
            address actor = address(uint160(0xACC0 + i));
            actors.push(actor);

            alphaToken.mint(actor, 1_000_000e18);
            betaToken.mint(actor, 1_000_000e18);
            usdc.mint(actor, 1_000_000e18);
            vm.deal(actor, 500 ether);

            vm.startPrank(actor);
            alphaToken.approve(address(otc), type(uint256).max);
            betaToken.approve(address(otc), type(uint256).max);
            usdc.approve(address(otc), type(uint256).max);
            vm.stopPrank();
        }

        handler = new OTCHandler(otc, alphaToken, betaToken, usdc, alphaId, betaId, actors);
        targetContract(address(handler));
    }

    function _createOffering(address baseToken, address feeRecipient, uint48 expiry) internal returns (uint256) {
        address[] memory cpts = new address[](2);
        cpts[0] = address(usdc);
        cpts[1] = address(0);

        OTCTrading.OfferingConfig memory cfg = OTCTrading.OfferingConfig({
            baseToken: baseToken,
            feeRecipient: feeRecipient,
            eligibilityRegistry: address(0),
            makerFeeBps: 25,
            takerFeeBps: 50,
            defaultOrderExpiration: expiry,
            minOrderSize: 100,
            maxOrderSize: 0,
            offeringRef: keccak256(abi.encode(baseToken)),
            counterpartyTokens: cpts
        });

        vm.prank(admin);
        return otc.createOffering(cfg);
    }

    /// @dev Nothing the venue holds is unaccounted for: every wei backs an order or a claim.
    function invariant_ethHeldCoversWhatIsOwed() public view {
        assertGe(address(otc).balance, otc.totalEthEscrowed() + otc.totalPendingWithdrawals());
    }

    /// @dev The per-order escrow really does add up to the contract-wide reserve — the sum that
    /// {approveRescueAssets} trusts when it decides what is spare.
    function invariant_escrowSumEqualsTheReserve() public view {
        uint256 sum;
        uint256 n = handler.orderCount();
        for (uint256 i = 0; i < n; i++) {
            sum += otc.ethEscrowed(handler.orderIds(i));
        }
        assertEq(sum, otc.totalEthEscrowed());
    }

    /// @dev And so do the pending withdrawals, across actors and both fee recipients.
    function invariant_pendingSumEqualsTheReserve() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            sum += otc.pendingWithdrawals(handler.actors(i));
        }
        sum += otc.pendingWithdrawals(feeAlpha);
        sum += otc.pendingWithdrawals(feeBeta);

        assertEq(sum, otc.totalPendingWithdrawals());
    }

    /// @dev No order is ever filled past its size, however the partial fills interleave.
    function invariant_ordersAreNeverOverfilled() public view {
        uint256 n = handler.orderCount();
        for (uint256 i = 0; i < n; i++) {
            OTCTrading.Order memory order = otc.getOrder(handler.orderIds(i));
            assertLe(order.filledAmount, order.baseTokenAmount);
        }
    }

    /// @dev Each offering's live count matches its own book — the number {proposeCloseOffering}
    /// relies on to know that closing strands nobody.
    function invariant_openOrderCountMatchesTheBook() public view {
        assertEq(otc.getOffering(alphaId).openOrderCount, _countActive(alphaId));
        assertEq(otc.getOffering(betaId).openOrderCount, _countActive(betaId));
    }

    /// @dev An inactive order holds no escrow: whatever it had went back to its maker.
    function invariant_closedOrdersHoldNoEscrow() public view {
        uint256 n = handler.orderCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 orderId = handler.orderIds(i);
            if (!otc.getOrder(orderId).isActive) {
                assertEq(otc.ethEscrowed(orderId), 0);
            }
        }
    }

    /// @dev The venue never ends up holding a trading asset: both legs move party to party.
    function invariant_theVenueHoldsNoTradingAssets() public view {
        assertEq(usdc.balanceOf(address(otc)), 0);
        assertEq(alphaToken.balanceOf(address(otc)), 0);
        assertEq(betaToken.balanceOf(address(otc)), 0);
    }

    function _countActive(uint256 offeringId) private view returns (uint256 count) {
        uint256 n = handler.orderCount();
        for (uint256 i = 0; i < n; i++) {
            OTCTrading.Order memory order = otc.getOrder(handler.orderIds(i));
            if (order.offeringId == offeringId && order.isActive) count++;
        }
    }
}
