// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {OTCTrading} from "../../src/OTCTrading.sol";
import {MockERC20} from "../utils/Mocks.sol";

/**
 * @dev Drives the venue the way a crowd would: several actors, two offerings, every settlement
 * asset, orders placed, filled in parts, cancelled, expired and withdrawn in any order.
 *
 * It records nothing the contract does not — the ghost state is only the list of order ids and
 * accounts to look at, so the invariants read the contract's own numbers rather than a parallel
 * model that could agree with the bug.
 */
contract OTCHandler is CommonBase, StdCheats, StdUtils {
    OTCTrading public immutable OTC;
    MockERC20 public immutable ALPHA;
    MockERC20 public immutable BETA;
    MockERC20 public immutable USDC;

    uint256 public immutable ALPHA_ID;
    uint256 public immutable BETA_ID;

    address[] public actors;
    uint256[] public orderIds;

    uint256 public calls;

    constructor(
        OTCTrading otc_,
        MockERC20 alpha_,
        MockERC20 beta_,
        MockERC20 usdc_,
        uint256 alphaId_,
        uint256 betaId_,
        address[] memory actors_
    ) {
        OTC = otc_;
        ALPHA = alpha_;
        BETA = beta_;
        USDC = usdc_;
        ALPHA_ID = alphaId_;
        BETA_ID = betaId_;
        actors = actors_;
    }

    modifier counted() {
        calls++;
        _;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _offering(uint256 seed) internal view returns (uint256) {
        return seed % 2 == 0 ? ALPHA_ID : BETA_ID;
    }

    function createSellOrder(uint256 actorSeed, uint256 offeringSeed, uint256 base, uint256 counterparty)
        external
        counted
    {
        base = bound(base, 100, 10_000e18);
        counterparty = bound(counterparty, 1e6, 100_000e18);

        vm.prank(_actor(actorSeed));
        try OTC.createOrder(
            _offering(offeringSeed), OTCTrading.OrderType.SELL, address(USDC), base, counterparty
        ) returns (
            uint256 orderId
        ) {
            orderIds.push(orderId);
        } catch {}
    }

    function createSellEthOrder(uint256 actorSeed, uint256 offeringSeed, uint256 base, uint256 counterparty)
        external
        counted
    {
        base = bound(base, 100, 10_000e18);
        counterparty = bound(counterparty, 1e12, 50 ether);

        vm.prank(_actor(actorSeed));
        try OTC.createOrder(
            _offering(offeringSeed), OTCTrading.OrderType.SELL, address(0), base, counterparty
        ) returns (
            uint256 orderId
        ) {
            orderIds.push(orderId);
        } catch {}
    }

    function createBuyOrder(uint256 actorSeed, uint256 offeringSeed, uint256 base, uint256 counterparty)
        external
        counted
    {
        base = bound(base, 100, 10_000e18);
        counterparty = bound(counterparty, 1e6, 100_000e18);

        vm.prank(_actor(actorSeed));
        try OTC.createOrder(
            _offering(offeringSeed), OTCTrading.OrderType.BUY, address(USDC), base, counterparty
        ) returns (
            uint256 orderId
        ) {
            orderIds.push(orderId);
        } catch {}
    }

    /// @dev The escrowed path — the only place this contract takes custody of anything.
    function createBuyEthOrder(uint256 actorSeed, uint256 offeringSeed, uint256 base, uint256 counterparty)
        external
        counted
    {
        base = bound(base, 100, 10_000e18);
        counterparty = bound(counterparty, 1e12, 50 ether);
        uint256 escrow = counterparty + (counterparty * 25) / 10000;

        address actor = _actor(actorSeed);
        if (actor.balance < escrow) return;

        vm.prank(actor);
        try OTC.createOrder{value: escrow}(
            _offering(offeringSeed), OTCTrading.OrderType.BUY, address(0), base, counterparty
        ) returns (
            uint256 orderId
        ) {
            orderIds.push(orderId);
        } catch {}
    }

    function fill(uint256 actorSeed, uint256 orderSeed, uint256 amount) external counted {
        if (orderIds.length == 0) return;

        uint256 orderId = orderIds[orderSeed % orderIds.length];
        OTCTrading.Order memory order = OTC.getOrder(orderId);
        if (!order.isActive) return;

        uint256 remaining = order.baseTokenAmount - order.filledAmount;
        if (remaining == 0) return;
        // A partial fill must be at least the offering's minimum (100) unless it takes the rest.
        uint256 floor_ = remaining < 100 ? remaining : 100;
        amount = bound(amount, floor_, remaining);

        address actor = _actor(actorSeed);
        if (actor == order.maker) return;

        // A SELL priced in ETH is the only fill the taker funds with value.
        uint256 value = 0;
        if (order.counterpartyToken == address(0) && order.orderType == OTCTrading.OrderType.SELL) {
            (,,, uint256 takerPays,) = OTC.quoteFill(orderId, amount);
            if (actor.balance < takerPays) return;
            value = takerPays;
        }

        vm.prank(actor);
        try OTC.fillOrder{value: value}(orderId, amount) {} catch {}
    }

    function cancel(uint256 actorSeed, uint256 orderSeed) external counted {
        if (orderIds.length == 0) return;

        uint256 orderId = orderIds[orderSeed % orderIds.length];
        vm.prank(_actor(actorSeed));
        try OTC.cancelOrder(orderId) {} catch {}
    }

    function cleanup(uint256 actorSeed, uint256 orderSeed) external counted {
        if (orderIds.length == 0) return;

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderIds[orderSeed % orderIds.length];

        vm.prank(_actor(actorSeed));
        try OTC.cleanupExpiredOrders(ids) returns (uint256) {} catch {}
    }

    function withdraw(uint256 actorSeed) external counted {
        vm.prank(_actor(actorSeed));
        try OTC.withdraw() {} catch {}
    }

    /// @dev Time moves, so expiry and cleanup are part of the search rather than a separate test.
    function warp(uint256 secondsAhead) external counted {
        vm.warp(block.timestamp + bound(secondsAhead, 1, 30 days));
    }

    function orderCount() external view returns (uint256) {
        return orderIds.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}
