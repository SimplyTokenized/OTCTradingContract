// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OTCTestBase} from "./utils/OTCTestBase.sol";
import {OTCTrading} from "../src/OTCTrading.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockERC20} from "./utils/Mocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Four eyes on the irreversible actions, and a delay on the grant that would otherwise defeat
/// them.
contract GovernanceTest is OTCTestBase {
    function test_initialize_refuses_an_approver_who_is_the_admin() public {
        address implementation = address(new OTCTrading());
        bytes memory badInit = abi.encodeCall(OTCTrading.initialize, (admin, admin, upgrader, address(0)));

        vm.expectRevert(OTCTrading.ApproverMustNotBeAdmin.selector);
        new ERC1967Proxy(implementation, badInit);
    }

    function test_roles_are_split_at_initialization() public view {
        assertTrue(otc.hasRole(otc.ADMIN_ROLE(), admin));
        assertTrue(otc.hasRole(otc.OPERATOR_ROLE(), admin));
        assertTrue(otc.hasRole(otc.APPROVER_ROLE(), approver));
        assertFalse(otc.hasRole(otc.APPROVER_ROLE(), admin), "the admin is not their own approver");
        assertTrue(otc.hasRole(otc.UPGRADER_ROLE(), upgrader));
    }

    // ---- fee recipient ----

    function test_redirecting_fees_takes_two_people() public {
        address newRecipient = address(0xF00D);

        vm.prank(approver);
        vm.expectRevert(OTCTrading.NoSuchProposal.selector);
        otc.approveSetOfferingFeeRecipient(alphaId, newRecipient);

        vm.prank(admin);
        otc.proposeSetOfferingFeeRecipient(alphaId, newRecipient);

        vm.prank(approver);
        otc.approveSetOfferingFeeRecipient(alphaId, newRecipient);

        assertEq(otc.getOffering(alphaId).feeRecipient, newRecipient);
    }

    function test_the_proposer_cannot_be_the_approver() public {
        address newRecipient = address(0xF00D);

        _grantRoleAfterDelay(otc.APPROVER_ROLE(), admin);

        vm.prank(admin);
        otc.proposeSetOfferingFeeRecipient(alphaId, newRecipient);

        vm.prank(admin);
        vm.expectRevert(OTCTrading.ApproverMustNotBeProposer.selector);
        otc.approveSetOfferingFeeRecipient(alphaId, newRecipient);
    }

    function test_an_approval_binds_the_exact_parameters() public {
        vm.prank(admin);
        otc.proposeSetOfferingFeeRecipient(alphaId, address(0xF00D));

        // A different recipient is a different proposal, and there is none.
        vm.prank(approver);
        vm.expectRevert(OTCTrading.NoSuchProposal.selector);
        otc.approveSetOfferingFeeRecipient(alphaId, address(0xBEEF));

        // So is a different offering.
        vm.prank(approver);
        vm.expectRevert(OTCTrading.NoSuchProposal.selector);
        otc.approveSetOfferingFeeRecipient(betaId, address(0xF00D));
    }

    function test_a_proposal_lapses() public {
        vm.prank(admin);
        otc.proposeSetOfferingFeeRecipient(alphaId, address(0xF00D));

        vm.warp(block.timestamp + otc.PROPOSAL_TTL() + 1);

        vm.prank(approver);
        vm.expectRevert(OTCTrading.ProposalExpired.selector);
        otc.approveSetOfferingFeeRecipient(alphaId, address(0xF00D));
    }

    function test_a_proposal_can_be_withdrawn() public {
        vm.prank(admin);
        otc.proposeSetOfferingFeeRecipient(alphaId, address(0xF00D));

        bytes32 id = otc.offeringFeeRecipientProposalId(alphaId, address(0xF00D));

        vm.prank(other);
        vm.expectRevert(OTCTrading.NotAllowedToCancel.selector);
        otc.cancelProposal(id);

        vm.prank(admin);
        otc.cancelProposal(id);

        vm.prank(approver);
        vm.expectRevert(OTCTrading.NoSuchProposal.selector);
        otc.approveSetOfferingFeeRecipient(alphaId, address(0xF00D));
    }

    // ---- closing an offering ----

    function test_closing_an_offering_takes_two_people_and_an_empty_book() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(admin);
        otc.setOfferingPaused(alphaId, true);
        vm.prank(admin);
        vm.expectRevert(OTCTrading.OfferingHasOpenOrders.selector);
        otc.proposeCloseOffering(alphaId);
        vm.prank(admin);
        otc.setOfferingPaused(alphaId, false);

        vm.prank(maker);
        otc.cancelOrder(orderId);

        // The lifecycle is Active -> Paused -> Closed; see AuditTest.test_L1_*.
        vm.prank(admin);
        otc.setOfferingPaused(alphaId, true);

        vm.prank(admin);
        otc.proposeCloseOffering(alphaId);
        vm.prank(approver);
        otc.approveCloseOffering(alphaId);

        assertEq(uint256(otc.getOffering(alphaId).state), uint256(OTCTrading.OfferingState.Closed));

        vm.prank(maker);
        vm.expectRevert(OTCTrading.OfferingNotActive.selector);
        otc.createOrder(alphaId, OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
    }

    function test_a_closed_offering_never_reopens() public {
        vm.prank(admin);
        otc.setOfferingPaused(betaId, true);
        vm.prank(admin);
        otc.proposeCloseOffering(betaId);
        vm.prank(approver);
        otc.approveCloseOffering(betaId);

        vm.prank(admin);
        vm.expectRevert(OTCTrading.OfferingIsClosed.selector);
        otc.setOfferingPaused(betaId, false);

        vm.prank(admin);
        vm.expectRevert(OTCTrading.OfferingIsClosed.selector);
        otc.setOfferingFees(betaId, 10, 10);
    }

    function test_closing_one_offering_leaves_the_others_alone() public {
        vm.prank(admin);
        otc.setOfferingPaused(betaId, true);
        vm.prank(admin);
        otc.proposeCloseOffering(betaId);
        vm.prank(approver);
        otc.approveCloseOffering(betaId);

        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);
        vm.prank(taker);
        otc.fillOrder(orderId, 1000e18);
    }

    // ---- the forwarder ----

    function test_changing_the_forwarder_takes_two_people() public {
        address forwarder = address(0xF0F0);

        vm.prank(admin);
        otc.proposeSetTrustedForwarder(forwarder);
        vm.prank(approver);
        otc.approveSetTrustedForwarder(forwarder);

        assertEq(otc.trustedForwarder(), forwarder);
        assertTrue(otc.isTrustedForwarder(forwarder));
        assertFalse(otc.isTrustedForwarder(address(0)), "address(0) is never trusted");
    }

    // ---- rescue ----

    function test_rescue_cannot_reach_escrow_or_pending_withdrawals() public {
        _buyEthOrder(alphaId, maker, 1000e18, 10 ether);
        uint256 reserved = otc.totalEthEscrowed();

        assertEq(otc.rescuableAmount(ETH), 0, "everything held is spoken for");

        vm.prank(admin);
        otc.proposeRescueAssets(ETH, admin, reserved);
        vm.prank(approver);
        vm.expectRevert(OTCTrading.AmountIsReserved.selector);
        otc.approveRescueAssets(ETH, admin, reserved);
    }

    function test_rescue_recovers_forced_eth_only() public {
        _buyEthOrder(alphaId, maker, 1000e18, 10 ether);

        // ETH forced in from outside the protocol — there is no receive(), so this is the only way.
        vm.deal(address(otc), address(otc).balance + 3 ether);
        assertEq(otc.rescuableAmount(ETH), 3 ether);

        vm.prank(admin);
        otc.proposeRescueAssets(ETH, admin, 3 ether);
        vm.prank(approver);
        otc.approveRescueAssets(ETH, admin, 3 ether);

        assertEq(admin.balance, 3 ether);
        _assertEthReserveHolds();
    }

    function test_rescue_recovers_a_mis_sent_erc20() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY");
        stray.mint(address(otc), 5e18);

        vm.prank(admin);
        otc.proposeRescueAssets(address(stray), admin, 5e18);
        vm.prank(approver);
        otc.approveRescueAssets(address(stray), admin, 5e18);

        assertEq(stray.balanceOf(admin), 5e18);
    }

    function test_rescue_works_while_paused() public {
        vm.prank(admin);
        otc.pause();

        vm.prank(admin);
        otc.proposeRescueAssets(ETH, admin, 0);
        vm.prank(approver);
        otc.approveRescueAssets(ETH, admin, 0);
    }

    // ---- delayed role grants ----

    function test_a_role_grant_must_be_announced_and_waited_out() public {
        bytes32 approverRole = otc.APPROVER_ROLE();

        vm.prank(admin);
        vm.expectRevert(OTCTrading.GrantNotScheduled.selector);
        otc.grantRole(approverRole, other);

        vm.prank(admin);
        otc.scheduleRoleGrant(approverRole, other);

        vm.prank(admin);
        vm.expectRevert(OTCTrading.GrantStillWaiting.selector);
        otc.grantRole(approverRole, other);

        vm.warp(block.timestamp + otc.ROLE_GRANT_DELAY());
        vm.prank(admin);
        otc.grantRole(approverRole, other);
        assertTrue(otc.hasRole(approverRole, other));
    }

    /// @dev The attack the delay exists for: arm a second approver and self-approve in one block.
    function test_the_root_cannot_arm_an_approver_and_self_approve_in_one_transaction() public {
        address puppet = address(0x9999);
        bytes32 approverRole = otc.APPROVER_ROLE();

        vm.startPrank(admin);
        otc.scheduleRoleGrant(approverRole, puppet);
        vm.expectRevert(OTCTrading.GrantStillWaiting.selector);
        otc.grantRole(approverRole, puppet);
        vm.stopPrank();

        vm.prank(puppet);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, puppet, approverRole)
        );
        otc.approveSetOfferingFeeRecipient(alphaId, puppet);
    }

    function test_a_pending_grant_lapses() public {
        bytes32 approverRole = otc.APPROVER_ROLE();

        vm.prank(admin);
        otc.scheduleRoleGrant(approverRole, other);

        vm.warp(block.timestamp + otc.ROLE_GRANT_DELAY() + otc.PROPOSAL_TTL() + 1);

        vm.prank(admin);
        vm.expectRevert(OTCTrading.GrantExpired.selector);
        otc.grantRole(approverRole, other);
    }

    function test_a_pending_grant_can_be_vetoed() public {
        bytes32 approverRole = otc.APPROVER_ROLE();

        vm.prank(admin);
        otc.scheduleRoleGrant(approverRole, other);

        vm.prank(admin);
        otc.cancelRoleGrant(approverRole, other);

        vm.warp(block.timestamp + otc.ROLE_GRANT_DELAY());
        vm.prank(admin);
        vm.expectRevert(OTCTrading.GrantNotScheduled.selector);
        otc.grantRole(approverRole, other);
    }

    /// @dev Removing a key is urgent in a way adding one never is.
    function test_revocation_is_immediate() public {
        bytes32 operatorRole = otc.OPERATOR_ROLE();
        _grantRoleAfterDelay(operatorRole, other);

        vm.prank(admin);
        otc.revokeRole(operatorRole, other);
        assertFalse(otc.hasRole(operatorRole, other));
    }

    function test_scheduling_a_role_someone_already_holds_is_refused() public {
        bytes32 adminRole = otc.ADMIN_ROLE();

        vm.expectRevert(OTCTrading.AlreadyHasRole.selector);
        vm.prank(admin);
        otc.scheduleRoleGrant(adminRole, admin);
    }

    // ---- compliance force-cancel ----

    function test_force_cancel_returns_escrow_to_the_maker_not_the_operator() public {
        uint256 orderId = _buyEthOrder(alphaId, maker, 1000e18, 10 ether);
        uint256 escrow = otc.ethEscrowed(orderId);

        vm.prank(admin);
        otc.adminCancelOrder(orderId);

        assertFalse(otc.getOrder(orderId).isActive);
        assertEq(otc.pendingWithdrawals(maker), escrow);
        assertEq(otc.pendingWithdrawals(admin), 0);
    }

    function test_force_cancel_is_operator_only() public {
        uint256 orderId = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);

        bytes32 operatorRole = otc.OPERATOR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, operatorRole)
        );
        vm.prank(other);
        otc.adminCancelOrder(orderId);
    }

    function test_force_cancel_in_batch_skips_inactive_orders() public {
        uint256 a = _sellOrder(alphaId, maker, address(usdc), 1000e18, 2000e18);
        uint256 b = _sellOrder(betaId, maker, address(usdc), 1000e18, 2000e18);

        vm.prank(maker);
        otc.cancelOrder(a);

        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;

        vm.prank(admin);
        otc.adminCancelOrders(ids);
        assertFalse(otc.getOrder(b).isActive);
    }
}
