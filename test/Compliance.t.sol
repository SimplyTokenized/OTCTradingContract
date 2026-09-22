// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OTCTestBase} from "./utils/OTCTestBase.sol";
import {OTCTrading} from "../src/OTCTrading.sol";
import {WhitelistRegistry} from "../src/compliance/WhitelistRegistry.sol";
import {ERC3643EligibilityAdapter} from "../src/compliance/ERC3643EligibilityAdapter.sol";
import {MockIdentityRegistry, MockERC3643Token, RevertingRegistry, NotARegistry} from "./utils/Mocks.sol";

/// @dev The gate: per offering, fixed for life, checked when it matters, and never in the way of
/// an exit.
contract ComplianceTest is OTCTestBase {
    WhitelistRegistry internal registry;
    uint256 internal gatedId;

    function setUp() public override {
        super.setUp();

        registry = new WhitelistRegistry(admin);
        gatedId = _createOffering(address(alphaToken), feeAlpha, address(registry));

        vm.startPrank(admin);
        registry.add(maker);
        registry.add(taker);
        vm.stopPrank();
    }

    function test_an_ungated_offering_lets_anyone_trade() public {
        uint256 orderId = _sellOrder(alphaId, other, address(usdc), 1000e18, 2000e18);
        vm.prank(taker);
        otc.fillOrder(orderId, 1000e18);
    }

    function test_the_gate_is_per_offering() public {
        // `other` is not on the registry, but the ungated offering does not care.
        _sellOrder(alphaId, other, address(usdc), 1000e18, 2000e18);

        vm.prank(other);
        vm.expectRevert(OTCTrading.NotEligible.selector);
        otc.createOrder(gatedId, OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
    }

    function test_both_sides_are_checked_at_settlement() public {
        uint256 orderId = _sellOrder(gatedId, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(other);
        vm.expectRevert(OTCTrading.NotEligible.selector);
        otc.fillOrder(orderId, 1000e18);
    }

    /// @dev The case a creation-time-only check would miss.
    function test_a_maker_who_lapses_while_resting_stops_trading() public {
        uint256 orderId = _sellOrder(gatedId, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(admin);
        registry.remove(maker);

        vm.prank(taker);
        vm.expectRevert(OTCTrading.NotEligible.selector);
        otc.fillOrder(orderId, 1000e18);

        assertFalse(otc.isOrderFundable(orderId), "the book shows it as unfillable");
    }

    /// @dev A gate stops trading. It must never strand what someone already owns.
    function test_a_de_listed_maker_can_still_cancel_and_withdraw() public {
        uint256 orderId = _buyEthOrder(gatedId, maker, 1000e18, 5 ether);
        uint256 escrow = otc.ethEscrowed(orderId);

        vm.prank(admin);
        registry.remove(maker);

        vm.prank(maker);
        otc.cancelOrder(orderId);

        uint256 before = maker.balance;
        vm.prank(maker);
        otc.withdraw();
        assertEq(maker.balance, before + escrow);
    }

    function test_the_gate_fails_closed_when_the_registry_reverts() public {
        RevertingRegistry broken = new RevertingRegistry();
        uint256 offeringId = _createOffering(address(alphaToken), feeAlpha, address(broken));

        broken.arm();

        vm.prank(maker);
        vm.expectRevert(OTCTrading.EligibilityCheckUnavailable.selector);
        otc.createOrder(offeringId, OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);

        assertFalse(otc.isEligibleToTrade(offeringId, maker), "the view agrees: unknown is not eligible");
    }

    function test_listing_refuses_a_registry_that_cannot_answer() public {
        NotARegistry bogus = new NotARegistry();

        address[] memory cpts = new address[](1);
        cpts[0] = address(usdc);

        OTCTrading.OfferingConfig memory cfg = OTCTrading.OfferingConfig({
            baseToken: address(alphaToken),
            feeRecipient: feeAlpha,
            eligibilityRegistry: address(bogus),
            makerFeeBps: uint16(MAKER_BPS),
            takerFeeBps: uint16(TAKER_BPS),
            defaultOrderExpiration: 0,
            minOrderSize: 100,
            maxOrderSize: 0,
            offeringRef: bytes32(0),
            counterpartyTokens: cpts
        });

        vm.prank(admin);
        vm.expectRevert(OTCTrading.RegistryNotAnswering.selector);
        otc.createOffering(cfg);
    }

    function test_the_gate_cannot_be_changed_after_listing() public {
        // There is no setter: the ABI itself is the guarantee that an order admitted under one gate
        // is never judged by another.
        OTCTrading.Offering memory offering = otc.getOffering(gatedId);
        assertEq(offering.eligibilityRegistry, address(registry));
    }

    // ---- ERC-3643: the institutional posture ----

    function test_erc3643_adapter_defers_to_the_tokens_own_identity_registry() public {
        MockIdentityRegistry identity = new MockIdentityRegistry();
        MockERC3643Token security = new MockERC3643Token(address(identity));
        ERC3643EligibilityAdapter adapter = new ERC3643EligibilityAdapter(address(security));

        uint256 offeringId = _createOffering(address(security), feeAlpha, address(adapter));

        security.mint(maker, 1_000e18);
        vm.prank(maker);
        security.approve(address(otc), type(uint256).max);

        vm.prank(maker);
        vm.expectRevert(OTCTrading.NotEligible.selector);
        otc.createOrder(offeringId, OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);

        identity.setVerified(maker, true);
        identity.setVerified(taker, true);

        uint256 orderId = _sellOrder(offeringId, maker, address(usdc), 1000e18, 2000e18);
        vm.prank(taker);
        otc.fillOrder(orderId, 1000e18);
        assertEq(security.balanceOf(taker), 1000e18);
    }

    /// @dev The adapter follows the TOKEN, so swapping the registry takes effect immediately.
    function test_erc3643_adapter_follows_a_registry_swap() public {
        MockIdentityRegistry first = new MockIdentityRegistry();
        MockERC3643Token security = new MockERC3643Token(address(first));
        ERC3643EligibilityAdapter adapter = new ERC3643EligibilityAdapter(address(security));

        first.setVerified(maker, true);
        assertTrue(adapter.isEligible(maker));

        MockIdentityRegistry second = new MockIdentityRegistry();
        security.setIdentityRegistry(address(second));
        assertFalse(adapter.isEligible(maker), "the new registry has not verified them");
    }

    function test_erc3643_adapter_refuses_a_token_without_a_registry() public {
        MockERC3643Token security = new MockERC3643Token(address(0));
        vm.expectRevert("ERC3643EligibilityAdapter: no identity registry");
        new ERC3643EligibilityAdapter(address(security));
    }

    // ---- The whitelist companion ----

    function test_whitelist_registry_batches_and_bounds() public {
        address[] memory accounts = new address[](3);
        accounts[0] = address(0x1111);
        accounts[1] = address(0x2222);
        accounts[2] = address(0x3333);

        vm.prank(admin);
        registry.addBatch(accounts);
        assertTrue(registry.isEligible(accounts[1]));

        vm.prank(admin);
        registry.removeBatch(accounts);
        assertFalse(registry.isEligible(accounts[1]));

        address[] memory tooMany = new address[](201);
        vm.prank(admin);
        vm.expectRevert("WhitelistRegistry: invalid batch size");
        registry.addBatch(tooMany);
    }

    function test_whitelist_registry_is_owner_only() public {
        vm.prank(other);
        vm.expectRevert();
        registry.add(other);
    }

    /// @dev Several offerings may share one list — and a second list stays independent of it.
    function test_one_registry_can_gate_several_offerings() public {
        uint256 second = _createOffering(address(betaToken), feeBeta, address(registry));

        _sellOrder(gatedId, maker, address(usdc), 1000e18, 2000e18);
        _sellOrder(second, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(admin);
        registry.remove(maker);

        vm.prank(maker);
        vm.expectRevert(OTCTrading.NotEligible.selector);
        otc.createOrder(second, OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
    }
}
