// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {OTCTrading} from "../src/OTCTrading.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A maker/taker contract that refuses to receive ETH (used to prove payouts revert loudly).
contract EthRejecter {
    function createBuyEth(OTCTrading otc, uint256 baseAmt, uint256 cptAmt) external payable returns (uint256) {
        return otc.createOrder{value: msg.value}(OTCTrading.OrderType.BUY, address(0), baseAmt, cptAmt);
    }
}

contract OTCTradingTest is Test {
    OTCTrading otc;
    MockERC20 base;
    MockERC20 usdc;

    address constant ETH = address(0);

    address admin = address(this);
    address feeRecipient = address(0xFEE);
    address user1 = address(0xA11CE); // maker
    address user2 = address(0xB0B); // taker

    uint256 constant MAKER_BPS = 25;
    uint256 constant TAKER_BPS = 50;

    function setUp() public {
        base = new MockERC20("Base", "BASE");
        usdc = new MockERC20("USD Coin", "USDC");

        // Deploy behind a UUPS proxy (also runs the OZ upgrade-safety validator).
        address proxy = Upgrades.deployUUPSProxy(
            "OTCTrading.sol",
            abi.encodeCall(
                OTCTrading.initialize,
                (address(base), address(usdc), feeRecipient, admin, MAKER_BPS, TAKER_BPS, 100, 0, 0, true)
            )
        );
        otc = OTCTrading(proxy);
        otc.addCounterpartyToken(ETH); // enable native-ETH-denominated orders

        otc.addToWhitelist(user1);
        otc.addToWhitelist(user2);

        base.mint(user1, 100_000e18);
        base.mint(user2, 100_000e18);
        usdc.mint(user1, 100_000e18);
        usdc.mint(user2, 100_000e18);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }

    /// @dev Wrap a single order id as the calldata array cleanupExpiredOrders/batch* expect.
    function _ids(uint256 id) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = id;
    }

    // ---------- createOrder ----------

    function test_CreateSell_NoFundsMoved() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 balBefore = base.balanceOf(user1);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        vm.stopPrank();

        assertEq(id, 1);
        assertEq(base.balanceOf(user1), balBefore, "no escrow: balance unchanged");
        assertEq(base.balanceOf(address(otc)), 0, "core holds nothing");
        assertTrue(otc.getOrder(id).isActive);
    }

    function test_CreateSell_RevertsWithoutApproval() public {
        vm.prank(user1);
        vm.expectRevert("OTCTrading: approve first");
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
    }

    function test_CreateBuy_RequiresCounterpartyPlusMakerFee() public {
        uint256 makerFee = (2000e18 * MAKER_BPS) / 10000; // 5e18
        vm.startPrank(user1);
        usdc.approve(address(otc), 2000e18); // not enough (missing maker fee)
        vm.expectRevert("OTCTrading: approve first");
        otc.createOrder(OTCTrading.OrderType.BUY, address(usdc), 1000e18, 2000e18);

        usdc.approve(address(otc), 2000e18 + makerFee);
        uint256 id = otc.createOrder(OTCTrading.OrderType.BUY, address(usdc), 1000e18, 2000e18);
        vm.stopPrank();
        assertEq(usdc.balanceOf(user1), 100_000e18, "no escrow on BUY create");
        assertTrue(otc.getOrder(id).isActive);
    }

    // ---------- fillOrder: fee symmetry ----------

    function test_FillSell_FeeSymmetry() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        vm.stopPrank();

        uint256 fill = 500e18;
        uint256 settlement = 1000e18;
        uint256 makerFee = (settlement * MAKER_BPS) / 10000; // 2.5e18
        uint256 takerFee = (settlement * TAKER_BPS) / 10000; // 5e18

        uint256 makerUsdc0 = usdc.balanceOf(user1);
        uint256 takerUsdc0 = usdc.balanceOf(user2);

        vm.startPrank(user2);
        usdc.approve(address(otc), settlement + takerFee);
        otc.fillOrder(id, fill);
        vm.stopPrank();

        // base moved maker -> taker
        assertEq(base.balanceOf(user2), 100_000e18 + fill);
        assertEq(base.balanceOf(user1), 100_000e18 - fill);
        // maker receives settlement - makerFee; taker pays settlement + takerFee
        assertEq(usdc.balanceOf(user1), makerUsdc0 + settlement - makerFee);
        assertEq(usdc.balanceOf(user2), takerUsdc0 - (settlement + takerFee));
        assertEq(usdc.balanceOf(feeRecipient), makerFee + takerFee);
        // core is non-custodial: holds nothing
        assertEq(base.balanceOf(address(otc)), 0);
        assertEq(usdc.balanceOf(address(otc)), 0);
    }

    function test_FillBuy_FeeSymmetry() public {
        uint256 makerFee0 = (2000e18 * MAKER_BPS) / 10000;
        vm.startPrank(user1);
        usdc.approve(address(otc), 2000e18 + makerFee0);
        uint256 id = otc.createOrder(OTCTrading.OrderType.BUY, address(usdc), 1000e18, 2000e18);
        vm.stopPrank();

        uint256 fill = 500e18;
        uint256 settlement = 1000e18;
        uint256 makerFee = (settlement * MAKER_BPS) / 10000;
        uint256 takerFee = (settlement * TAKER_BPS) / 10000;

        uint256 makerUsdc0 = usdc.balanceOf(user1);

        vm.startPrank(user2);
        base.approve(address(otc), fill);
        otc.fillOrder(id, fill);
        vm.stopPrank();

        // base moved taker -> maker
        assertEq(base.balanceOf(user1), 100_000e18 + fill);
        assertEq(base.balanceOf(user2), 100_000e18 - fill);
        // taker receives settlement - takerFee; maker pays settlement + makerFee
        assertEq(usdc.balanceOf(user2), 100_000e18 + settlement - takerFee);
        assertEq(usdc.balanceOf(user1), makerUsdc0 - (settlement + makerFee));
        assertEq(usdc.balanceOf(feeRecipient), makerFee + takerFee);
        assertEq(usdc.balanceOf(address(otc)), 0);
    }

    function test_PartialFills() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(otc), type(uint256).max);
        otc.fillOrder(id, 300e18);
        assertEq(otc.getRemainingAmount(id), 700e18);
        assertTrue(otc.getOrder(id).isActive);
        otc.fillOrder(id, 700e18);
        vm.stopPrank();
        assertFalse(otc.getOrder(id).isActive);
        assertEq(base.balanceOf(user2), 100_000e18 + 1000e18);
    }

    // ---------- cancel / validation ----------

    function test_Cancel_IsFlagFlip_NoFundsMoved() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        uint256 bal = base.balanceOf(user1);
        otc.cancelOrder(id);
        vm.stopPrank();
        assertFalse(otc.getOrder(id).isActive);
        assertEq(base.balanceOf(user1), bal, "cancel never moves funds");
    }

    function test_UnfundableOrder_FillReverts_AndViewFalse() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        // maker revokes allowance after posting
        base.approve(address(otc), 0);
        vm.stopPrank();

        assertFalse(otc.isOrderFundable(id));

        vm.startPrank(user2);
        usdc.approve(address(otc), type(uint256).max);
        vm.expectRevert(); // core pulls base from maker -> insufficient allowance
        otc.fillOrder(id, 500e18);
        vm.stopPrank();
    }

    function test_PruneExpired_Permissionless_OnlyWhenExpired() public {
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(1 hours);

        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        vm.stopPrank();

        // not yet expired -> skipped, nothing cleaned
        vm.prank(address(0xDEAD));
        assertEq(otc.cleanupExpiredOrders(_ids(id)), 0, "not expired: nothing cleaned");
        assertTrue(otc.getOrder(id).isActive);

        vm.warp(block.timestamp + 2 hours);

        // now anyone can clean it up (permissionless)
        vm.prank(address(0xDEAD));
        assertEq(otc.cleanupExpiredOrders(_ids(id)), 1, "expired: cleaned");
        assertFalse(otc.getOrder(id).isActive);
    }

    function test_FillReverts_OwnOrder_Expired_RoundsToZero() public {
        vm.startPrank(user1);
        base.approve(address(otc), type(uint256).max);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        // own order
        vm.expectRevert("OTCTrading: cannot fill own order");
        otc.fillOrder(id, 100e18);
        vm.stopPrank();

        // rounds to zero: 1e18 base for 1 wei counterparty, fill tiny amount
        vm.startPrank(user1);
        uint256 id2 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1e18, 1);
        vm.stopPrank();
        vm.startPrank(user2);
        usdc.approve(address(otc), type(uint256).max);
        vm.expectRevert("OTCTrading: amount rounds to zero");
        otc.fillOrder(id2, 1e17); // 1e17 * 1 / 1e18 = 0
        vm.stopPrank();
    }

    // ---------- native ETH (counterparty token == address(0)) ----------

    /// @dev SELL priced in ETH: allowance-backed, nothing escrowed. Taker pays ETH at fill.
    function test_ETH_SellOrder_EscrowsNothing() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, ETH, 1000e18, 2e18);
        vm.stopPrank();

        assertEq(otc.ethEscrowed(id), 0, "SELL escrows nothing");
        assertEq(address(otc).balance, 0, "contract holds no ETH");
    }

    function test_ETH_SellOrder_RejectsSentEth() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        vm.expectRevert("OTCTrading: ETH not needed");
        otc.createOrder{value: 1 ether}(OTCTrading.OrderType.SELL, ETH, 1000e18, 2e18);
        vm.stopPrank();
    }

    /// @dev Taker buys base off a SELL order by sending ETH; overpayment is refunded.
    function test_ETH_FillSell_PayWithEth_RefundsExcess() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, ETH, 1000e18, 2e18);
        vm.stopPrank();

        uint256 fill = 500e18;
        uint256 settlement = 1e18; // 500 * 2 / 1000
        uint256 makerFee = (settlement * MAKER_BPS) / 10000; // 2.5e15
        uint256 takerFee = (settlement * TAKER_BPS) / 10000; // 5e15
        uint256 owed = settlement + takerFee;

        uint256 makerEth0 = user1.balance;
        uint256 takerEth0 = user2.balance;

        vm.prank(user2);
        otc.fillOrder{value: owed + 0.1 ether}(id, fill); // overpay to exercise the refund

        assertEq(base.balanceOf(user2), 100_000e18 + fill, "taker got base");
        // Maker proceeds and fees are CREDITED (pull-payment), not pushed.
        assertEq(user1.balance, makerEth0, "maker balance unchanged until withdraw");
        assertEq(otc.pendingWithdrawals(user1), settlement - makerFee, "maker proceeds credited");
        assertEq(otc.pendingWithdrawals(feeRecipient), makerFee + takerFee, "fees credited");
        // Taker (the active caller) is refunded inline.
        assertEq(user2.balance, takerEth0 - owed, "taker paid exactly settlement+takerFee (excess refunded)");
        assertEq(address(otc).balance, owed, "contract holds only credited (claimable) ETH");

        // Maker can pull their proceeds.
        vm.prank(user1);
        otc.withdraw();
        assertEq(user1.balance, makerEth0 + (settlement - makerFee), "maker withdrew proceeds");
    }

    function test_ETH_FillSell_InsufficientEthReverts() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, ETH, 1000e18, 2e18);
        vm.stopPrank();

        vm.prank(user2);
        vm.expectRevert("OTCTrading: insufficient ETH sent");
        otc.fillOrder{value: 1e15}(id, 500e18); // needs 1e18 + 5e15
    }

    /// @dev BUY priced in ETH: the one escrowed case. Maker pre-funds counterparty + maker fee.
    function test_ETH_BuyOrder_EscrowsAtCreation() public {
        uint256 cpt = 2e18;
        uint256 makerFee = (cpt * MAKER_BPS) / 10000;
        uint256 deposit = cpt + makerFee;

        uint256 makerEth0 = user1.balance;
        vm.prank(user1);
        uint256 id = otc.createOrder{value: deposit}(OTCTrading.OrderType.BUY, ETH, 1000e18, cpt);

        assertEq(otc.ethEscrowed(id), deposit, "escrow recorded");
        assertEq(address(otc).balance, deposit, "contract holds the escrow");
        assertEq(user1.balance, makerEth0 - deposit, "maker funded the escrow");
    }

    function test_ETH_BuyOrder_WrongValueReverts() public {
        uint256 cpt = 2e18;
        uint256 deposit = cpt + (cpt * MAKER_BPS) / 10000;

        vm.startPrank(user1);
        vm.expectRevert("OTCTrading: incorrect ETH amount");
        otc.createOrder{value: deposit - 1}(OTCTrading.OrderType.BUY, ETH, 1000e18, cpt);

        vm.expectRevert("OTCTrading: incorrect ETH amount");
        otc.createOrder{value: deposit + 1}(OTCTrading.OrderType.BUY, ETH, 1000e18, cpt);
        vm.stopPrank();
    }

    /// @dev Taker sells base into a BUY+ETH order and is paid native ETH out of the escrow.
    function test_ETH_FillBuy_TakerReceivesEth() public {
        uint256 cpt = 2e18;
        uint256 makerFeeTotal = (cpt * MAKER_BPS) / 10000;
        uint256 deposit = cpt + makerFeeTotal;

        vm.prank(user1);
        uint256 id = otc.createOrder{value: deposit}(OTCTrading.OrderType.BUY, ETH, 1000e18, cpt);

        uint256 fill = 500e18;
        uint256 settlement = 1e18;
        uint256 makerFee = (settlement * MAKER_BPS) / 10000;
        uint256 takerFee = (settlement * TAKER_BPS) / 10000;

        uint256 takerEth0 = user2.balance;
        vm.startPrank(user2);
        base.approve(address(otc), fill);
        otc.fillOrder(id, fill); // no ETH sent: proceeds come from escrow
        vm.stopPrank();

        assertEq(base.balanceOf(user1), 100_000e18 + fill, "maker got base");
        // Taker (active caller) is paid inline out of escrow; fees are credited.
        assertEq(user2.balance, takerEth0 + (settlement - takerFee), "taker received native ETH");
        assertEq(otc.pendingWithdrawals(feeRecipient), makerFee + takerFee, "fees credited");
        // Escrow drawn down by exactly this fill's cost (proceeds + both fees).
        assertEq(otc.ethEscrowed(id), deposit - (settlement + makerFee), "escrow decremented");
        assertEq(
            address(otc).balance,
            otc.ethEscrowed(id) + otc.pendingWithdrawals(feeRecipient),
            "contract balance == remaining escrow + credited fees"
        );
    }

    function test_ETH_FillBuy_RejectsSentEth() public {
        uint256 cpt = 2e18;
        uint256 deposit = cpt + (cpt * MAKER_BPS) / 10000;
        vm.prank(user1);
        uint256 id = otc.createOrder{value: deposit}(OTCTrading.OrderType.BUY, ETH, 1000e18, cpt);

        vm.startPrank(user2);
        base.approve(address(otc), 500e18);
        vm.expectRevert("OTCTrading: ETH not needed");
        otc.fillOrder{value: 1 ether}(id, 500e18);
        vm.stopPrank();
    }

    /// @dev A fully-filled BUY+ETH order leaves no escrow behind; only credited fees remain until
    /// the fee recipient withdraws.
    function test_ETH_FillBuy_FullFill_DrainsEscrow() public {
        uint256 cpt = 2e18;
        uint256 deposit = cpt + (cpt * MAKER_BPS) / 10000;
        vm.prank(user1);
        uint256 id = otc.createOrder{value: deposit}(OTCTrading.OrderType.BUY, ETH, 1000e18, cpt);

        vm.startPrank(user2);
        base.approve(address(otc), 1000e18);
        otc.fillOrder(id, 1000e18);
        vm.stopPrank();

        assertEq(otc.ethEscrowed(id), 0, "escrow fully drawn down");
        assertEq(address(otc).balance, otc.pendingWithdrawals(feeRecipient), "only credited fees remain");

        vm.prank(feeRecipient);
        otc.withdraw();
        assertEq(address(otc).balance, 0, "no ETH left after fee recipient withdraws");
    }

    function test_ETH_CancelRefundsRemainingEscrow() public {
        uint256 cpt = 2e18;
        uint256 deposit = cpt + (cpt * MAKER_BPS) / 10000;
        vm.prank(user1);
        uint256 id = otc.createOrder{value: deposit}(OTCTrading.OrderType.BUY, ETH, 1000e18, cpt);

        // Partially fill, then cancel the rest.
        vm.startPrank(user2);
        base.approve(address(otc), 500e18);
        otc.fillOrder(id, 500e18);
        vm.stopPrank();

        uint256 remaining = otc.ethEscrowed(id);
        assertGt(remaining, 0, "escrow remains after partial fill");

        uint256 makerEth0 = user1.balance;
        vm.prank(user1);
        otc.cancelOrder(id);

        assertEq(otc.ethEscrowed(id), 0, "escrow zeroed");
        assertEq(otc.pendingWithdrawals(user1), remaining, "remainder credited to maker");

        vm.prank(user1);
        otc.withdraw();
        assertEq(user1.balance, makerEth0 + remaining, "maker withdrew the remainder");
    }

    function test_ETH_CleanupExpiredRefundsMaker() public {
        otc.updateDefaultOrderExpiration(1 days);

        uint256 cpt = 2e18;
        uint256 deposit = cpt + (cpt * MAKER_BPS) / 10000;
        vm.prank(user1);
        uint256 id = otc.createOrder{value: deposit}(OTCTrading.OrderType.BUY, ETH, 1000e18, cpt);

        vm.warp(block.timestamp + 2 days);

        uint256 makerEth0 = user1.balance;
        uint256 pruneEth0 = user2.balance;
        vm.prank(user2); // a third party cleans up; they must gain nothing
        otc.cleanupExpiredOrders(_ids(id));

        assertEq(otc.pendingWithdrawals(user1), deposit, "escrow credited to the MAKER");
        assertEq(otc.pendingWithdrawals(user2), 0, "cleaner gained nothing");
        assertEq(user2.balance, pruneEth0, "cleaner balance unchanged");

        vm.prank(user1);
        otc.withdraw();
        assertEq(user1.balance, makerEth0 + deposit, "maker withdrew the escrow");
    }

    function test_ETH_AdminCancelRefundsMakerNotAdmin() public {
        uint256 cpt = 2e18;
        uint256 deposit = cpt + (cpt * MAKER_BPS) / 10000;
        vm.prank(user1);
        uint256 id = otc.createOrder{value: deposit}(OTCTrading.OrderType.BUY, ETH, 1000e18, cpt);

        uint256 makerEth0 = user1.balance;
        otc.adminCancelOrder(id); // admin (this)

        assertEq(otc.pendingWithdrawals(user1), deposit, "escrow credited to the MAKER");
        assertEq(otc.pendingWithdrawals(admin), 0, "admin credited nothing");

        vm.prank(user1);
        otc.withdraw();
        assertEq(user1.balance, makerEth0 + deposit, "maker withdrew the escrow");
    }

    /// @dev The escrow is always fundable; an allowance-backed order is not.
    function test_ETH_BuyOrderAlwaysFundable() public {
        uint256 cpt = 2e18;
        uint256 deposit = cpt + (cpt * MAKER_BPS) / 10000;
        vm.prank(user1);
        uint256 id = otc.createOrder{value: deposit}(OTCTrading.OrderType.BUY, ETH, 1000e18, cpt);

        assertTrue(otc.isOrderFundable(id), "escrowed order is fundable by construction");
    }

    /// @dev H-1 fix: a maker that cannot receive ETH no longer blocks cancel/force-cancel. The
    /// refund is CREDITED (pull-payment), so the order deactivates cleanly and the funds sit
    /// claimable. (The maker withdrawing later is the maker's own problem, not a liveness risk.)
    function test_ETH_RefundToNonReceiverIsCredited_H1() public {
        EthRejecter rejecter = new EthRejecter();
        otc.addToWhitelist(address(rejecter));
        vm.deal(address(rejecter), 10 ether);

        uint256 cpt = 2e18;
        uint256 deposit = cpt + (cpt * MAKER_BPS) / 10000;
        uint256 id = rejecter.createBuyEth{value: deposit}(otc, 1000e18, cpt);

        // Maker (a non-receiving contract) can cancel — no revert.
        vm.prank(address(rejecter));
        otc.cancelOrder(id);

        assertFalse(otc.getOrder(id).isActive, "order deactivated");
        assertEq(otc.ethEscrowed(id), 0, "escrow released");
        assertEq(otc.pendingWithdrawals(address(rejecter)), deposit, "refund credited, not lost");
    }

    /// @dev H-1 fix: admin force-cancel of a non-receiving maker's order also succeeds, and a hostile
    /// order can no longer poison an admin batch.
    function test_ETH_AdminCancelNonReceiver_DoesNotBlock_H1() public {
        EthRejecter rejecter = new EthRejecter();
        otc.addToWhitelist(address(rejecter));
        vm.deal(address(rejecter), 10 ether);

        uint256 cpt = 2e18;
        uint256 deposit = cpt + (cpt * MAKER_BPS) / 10000;
        uint256 badId = rejecter.createBuyEth{value: deposit}(otc, 1000e18, cpt);

        // A normal order in the same batch must still be cancelled.
        vm.prank(user1);
        uint256 goodId = otc.createOrder{value: deposit}(OTCTrading.OrderType.BUY, ETH, 1000e18, cpt);

        uint256[] memory ids = new uint256[](2);
        ids[0] = badId;
        ids[1] = goodId;
        otc.adminCancelOrders(ids); // must not revert

        assertFalse(otc.getOrder(badId).isActive, "hostile order cancelled");
        assertFalse(otc.getOrder(goodId).isActive, "batch not poisoned");
        assertEq(otc.pendingWithdrawals(address(rejecter)), deposit, "hostile maker credited");
        assertEq(otc.pendingWithdrawals(user1), deposit, "normal maker credited");
    }

    /// @dev M-1 fix: a fee recipient that cannot receive ETH no longer blocks ETH settlement — the
    /// fee is credited instead of pushed.
    function test_ETH_RevertingFeeRecipientDoesNotBlockFills_M1() public {
        address badFee = address(new EthRejecter());
        otc.updateFeeRecipient(badFee);

        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, ETH, 1000e18, 2e18);
        vm.stopPrank();

        uint256 settlement = 1e18;
        uint256 takerFee = (settlement * TAKER_BPS) / 10000;

        vm.prank(user2);
        otc.fillOrder{value: settlement + takerFee}(id, 500e18); // succeeds despite bad fee recipient

        uint256 makerFee = (settlement * MAKER_BPS) / 10000;
        assertEq(otc.pendingWithdrawals(badFee), makerFee + takerFee, "fee credited to (bad) recipient");
    }

    /// @dev M-2 fix: a de-whitelisted maker's resting order can no longer be filled.
    function test_ETH_DewhitelistedMakerCannotBeFilled_M2() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        vm.stopPrank();

        otc.removeFromWhitelist(user1); // maker offboarded

        vm.startPrank(user2);
        usdc.approve(address(otc), type(uint256).max);
        vm.expectRevert("OTCTrading: maker not whitelisted");
        otc.fillOrder(id, 1000e18);
        vm.stopPrank();
    }

    /// @dev L-1 fix: rounding dust left after the closing fill is credited to the maker, not stranded.
    function test_ETH_DustCreditedToMakerOnFullFill_L1() public {
        // Price 999 wei per 1000 base so per-fill settlement floors and leaves 1 wei dust.
        uint256 deposit = 999 + (uint256(999) * MAKER_BPS) / 10000; // 999 + 2 = 1001
        vm.prank(user1);
        uint256 id = otc.createOrder{value: deposit}(OTCTrading.OrderType.BUY, ETH, 1000, 999);

        vm.startPrank(user2);
        base.approve(address(otc), 1000);
        otc.fillOrder(id, 500); // draws 500
        otc.fillOrder(id, 500); // draws 500, closes order, 1 wei dust remains
        vm.stopPrank();

        assertFalse(otc.getOrder(id).isActive, "order complete");
        assertEq(otc.ethEscrowed(id), 0, "escrow fully released (dust included)");
        assertEq(otc.pendingWithdrawals(user1), 1, "dust credited to maker");
    }

    function test_Withdraw_RevertsWhenNothingOwed() public {
        vm.prank(user1);
        vm.expectRevert("OTCTrading: nothing to withdraw");
        otc.withdraw();
    }

    /// @dev No receive()/fallback: raw ETH sent to the contract is rejected.
    function test_ETH_DirectTransferRejected() public {
        vm.prank(user1);
        (bool ok,) = address(otc).call{value: 1 ether}("");
        assertFalse(ok, "direct ETH transfers are rejected");
    }

    // ---------- admin cancel ----------

    function test_AdminCancel_DeactivatesAnyOrder_NoFundsMoved() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 bal = base.balanceOf(user1);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        vm.stopPrank();

        // admin (this) force-cancels a maker's active order
        otc.adminCancelOrder(id);

        assertFalse(otc.getOrder(id).isActive);
        assertEq(base.balanceOf(user1), bal, "admin cancel moves no funds");
        assertEq(base.balanceOf(address(otc)), 0);
    }

    function test_AdminCancel_NonAdminReverts() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        vm.stopPrank();

        vm.prank(user2); // not admin, and not the maker
        vm.expectRevert();
        otc.adminCancelOrder(id);

        vm.prank(user1); // even the maker cannot use the admin path
        vm.expectRevert();
        otc.adminCancelOrder(id);
    }

    function test_AdminCancel_RevertsIfInactive() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        otc.cancelOrder(id);
        vm.stopPrank();

        vm.expectRevert("OTCTrading: order not active");
        otc.adminCancelOrder(id);
    }

    function test_AdminCancel_PreventsFill() public {
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        vm.stopPrank();

        otc.adminCancelOrder(id);

        vm.startPrank(user2);
        usdc.approve(address(otc), type(uint256).max);
        vm.expectRevert("OTCTrading: order not active");
        otc.fillOrder(id, 500e18);
        vm.stopPrank();
    }

    function test_AdminCancelBatch_SkipsInactive() public {
        vm.startPrank(user1);
        base.approve(address(otc), type(uint256).max);
        uint256 id1 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        uint256 id2 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        otc.cancelOrder(id1); // already inactive
        vm.stopPrank();

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;
        otc.adminCancelOrders(ids);

        assertFalse(otc.getOrder(id1).isActive);
        assertFalse(otc.getOrder(id2).isActive);
    }

    // ---------- upgradeability (UUPS) ----------

    function test_Upgrade_AdminHoldsUpgraderRole() public view {
        assertTrue(otc.hasRole(otc.UPGRADER_ROLE(), admin));
    }

    function test_Upgrade_NonUpgraderReverts() public {
        address newImpl = address(new OTCTrading());
        vm.prank(user1); // no UPGRADER_ROLE
        vm.expectRevert();
        otc.upgradeToAndCall(newImpl, "");
    }

    function test_Upgrade_UpgraderCanUpgrade_StatePersists() public {
        // seed some state before the upgrade
        vm.startPrank(user1);
        base.approve(address(otc), 1000e18);
        uint256 id = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), 1000e18, 2000e18);
        vm.stopPrank();

        address implBefore = _impl();
        address newImpl = address(new OTCTrading());

        // admin holds UPGRADER_ROLE
        otc.upgradeToAndCall(newImpl, "");

        assertEq(_impl(), newImpl, "implementation swapped");
        assertTrue(_impl() != implBefore);
        // storage persists across the upgrade
        assertEq(otc.makerFeeBps(), MAKER_BPS);
        assertEq(otc.baseToken(), address(base));
        assertTrue(otc.getOrder(id).isActive);
        assertEq(otc.getOrder(id).maker, user1);
    }

    function test_Upgrade_CannotReinitialize() public {
        vm.expectRevert(); // InvalidInitialization
        otc.initialize(address(base), address(usdc), feeRecipient, admin, MAKER_BPS, TAKER_BPS, 100, 0, 0, true);
    }

    /// @dev Read the EIP-1967 implementation slot of the proxy.
    function _impl() internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(address(otc), slot))));
    }
}
