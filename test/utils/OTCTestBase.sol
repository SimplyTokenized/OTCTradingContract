// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {OTCTrading} from "../../src/OTCTrading.sol";
import {MockERC20} from "./Mocks.sol";

/**
 * @dev Shared setup for every suite: one tenant contract, two offerings on different base tokens,
 * and the actors the four-eyes split requires.
 *
 * Two offerings exist in the base fixture ON PURPOSE. v2's central claim is that one contract can
 * carry several books without them touching, and a fixture with a single offering would let a
 * cross-offering bug pass every suite unnoticed.
 */
abstract contract OTCTestBase is Test {
    OTCTrading internal otc;

    MockERC20 internal alphaToken; // offering 1's base token
    MockERC20 internal betaToken; // offering 2's base token
    MockERC20 internal usdc; // counterparty token, shared by both

    address internal constant ETH = address(0);

    address internal admin = address(0xA0);
    address internal approver = address(0xA1);
    address internal upgrader = address(0xA2);
    address internal feeAlpha = address(0xFEE1);
    address internal feeBeta = address(0xFEE2);

    address internal maker = address(0xAA11);
    address internal taker = address(0xBB22);
    address internal other = address(0xCC33);

    uint256 internal constant MAKER_BPS = 25; // 0.25%
    uint256 internal constant TAKER_BPS = 50; // 0.50%

    uint256 internal alphaId;
    uint256 internal betaId;

    function setUp() public virtual {
        alphaToken = new MockERC20("Alpha Fund", "ALPHA");
        betaToken = new MockERC20("Beta Fund", "BETA");
        usdc = new MockERC20("USD Coin", "USDC");

        address proxy = Upgrades.deployUUPSProxy(
            "OTCTrading.sol", abi.encodeCall(OTCTrading.initialize, (admin, approver, upgrader, address(0)))
        );
        otc = OTCTrading(proxy);

        alphaId = _createOffering(address(alphaToken), feeAlpha, address(0));
        betaId = _createOffering(address(betaToken), feeBeta, address(0));

        _fund(maker);
        _fund(taker);
        _fund(other);
    }

    // ---- helpers ----

    function _createOffering(address baseToken, address feeRecipient, address registry)
        internal
        returns (uint256 offeringId)
    {
        address[] memory cpts = new address[](2);
        cpts[0] = address(usdc);
        cpts[1] = ETH;

        OTCTrading.OfferingConfig memory cfg = OTCTrading.OfferingConfig({
            baseToken: baseToken,
            feeRecipient: feeRecipient,
            eligibilityRegistry: registry,
            makerFeeBps: uint16(MAKER_BPS),
            takerFeeBps: uint16(TAKER_BPS),
            defaultOrderExpiration: 0,
            minOrderSize: 100,
            maxOrderSize: 0,
            offeringRef: keccak256(abi.encode(baseToken)),
            counterpartyTokens: cpts
        });

        vm.prank(admin);
        offeringId = otc.createOffering(cfg);
    }

    /// @dev Give an actor every asset and a standing approval, so tests only set up what they mean to.
    function _fund(address account) internal {
        alphaToken.mint(account, 1_000_000e18);
        betaToken.mint(account, 1_000_000e18);
        usdc.mint(account, 1_000_000e18);
        vm.deal(account, 1_000 ether);

        vm.startPrank(account);
        alphaToken.approve(address(otc), type(uint256).max);
        betaToken.approve(address(otc), type(uint256).max);
        usdc.approve(address(otc), type(uint256).max);
        vm.stopPrank();
    }

    function _sellOrder(uint256 offeringId, address who, address cpt, uint256 base, uint256 counterparty)
        internal
        returns (uint256 orderId)
    {
        vm.prank(who);
        orderId = otc.createOrder(offeringId, OTCTrading.OrderType.SELL, cpt, base, counterparty);
    }

    function _buyOrder(uint256 offeringId, address who, address cpt, uint256 base, uint256 counterparty)
        internal
        returns (uint256 orderId)
    {
        vm.prank(who);
        orderId = otc.createOrder(offeringId, OTCTrading.OrderType.BUY, cpt, base, counterparty);
    }

    /// @dev A BUY priced in ETH must escrow the counterparty amount plus the maker fee.
    function _buyEthOrder(uint256 offeringId, address who, uint256 base, uint256 counterparty)
        internal
        returns (uint256 orderId)
    {
        uint256 escrow = counterparty + (counterparty * MAKER_BPS) / 10000;
        vm.prank(who);
        orderId = otc.createOrder{value: escrow}(offeringId, OTCTrading.OrderType.BUY, ETH, base, counterparty);
    }

    /// @dev Move a role to `account` through the delay, the way production has to.
    function _grantRoleAfterDelay(bytes32 role, address account) internal {
        vm.prank(admin);
        otc.scheduleRoleGrant(role, account);
        vm.warp(block.timestamp + otc.ROLE_GRANT_DELAY());
        vm.prank(admin);
        otc.grantRole(role, account);
    }

    /// @dev The property that makes a tenant-wide contract safe: every wei here is spoken for.
    function _assertEthReserveHolds() internal view {
        assertGe(
            address(otc).balance,
            otc.totalEthEscrowed() + otc.totalPendingWithdrawals(),
            "contract holds less ETH than it owes"
        );
    }
}
