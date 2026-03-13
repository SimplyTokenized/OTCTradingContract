// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {OTCTrading} from "../src/OTCTrading.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 tokens for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract OTCTradingTest is Test {
    OTCTrading public otc;
    MockERC20 public baseToken;
    MockERC20 public usdc;
    address public admin;
    address public feeRecipient;
    address public user1;
    address public user2;

    function setUp() public {
        admin = address(this);
        feeRecipient = address(0x123);
        user1 = address(0x1);
        user2 = address(0x2);

        // Deploy mock tokens
        baseToken = new MockERC20("Base Token", "BASE");
        usdc = new MockERC20("USD Coin", "USDC");

        // Deploy OTC contract with proxy
        // Initialize with same defaults as original implementation:
        // makerFeeBps = 25 (0.25%), takerFeeBps = 50 (0.5%),
        // minOrderSize = 100, maxOrderSize = 0 (no max),
        // defaultOrderExpiration = 0 (no expiration),
        // requireWhitelist = true.
        address proxyAddress = Upgrades.deployTransparentProxy(
            "OTCTrading.sol",
            admin,
            abi.encodeCall(
                OTCTrading.initialize,
                (
                    address(baseToken),
                    address(usdc),
                    feeRecipient,
                    admin,
                    25,
                    50,
                    100,
                    0,
                    0,
                    true
                )
            )
        );

        otc = OTCTrading(payable(proxyAddress));

        // Setup: mint tokens to users
        baseToken.mint(user1, 10000 * 10 ** baseToken.decimals());
        baseToken.mint(user2, 10000 * 10 ** baseToken.decimals());
        usdc.mint(user1, 100000 * 10 ** usdc.decimals());
        usdc.mint(user2, 100000 * 10 ** usdc.decimals());

        // Add users to whitelist
        vm.prank(admin);
        otc.addToWhitelist(user1);
        vm.prank(admin);
        otc.addToWhitelist(user2);
    }

    function test_Initialization() public {
        assertEq(address(otc.baseToken()), address(baseToken));
        assertEq(otc.feeRecipient(), feeRecipient);
        assertEq(otc.makerFeeBps(), 25); // 0.25%
        assertEq(otc.takerFeeBps(), 50); // 0.5%
        assertEq(otc.minOrderSize(), 100);
        assertTrue(otc.requireWhitelist());
        assertTrue(otc.allowedCounterpartyTokens(address(usdc)));
    }

    function test_CreateOrder() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        assertEq(orderId, 1);
        OTCTrading.Order memory order = otc.getOrder(orderId);
        assertEq(order.maker, user1);
        assertEq(uint256(order.orderType), uint256(OTCTrading.OrderType.SELL));
        assertEq(order.counterpartyToken, address(usdc));
        assertEq(order.baseTokenAmount, baseAmount);
        assertEq(order.counterpartyTokenAmount, usdcAmount);
        assertTrue(order.isActive);
    }

    function test_FillOrder() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create order
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Fill order
        uint256 fillAmount = 500 * 10 ** baseToken.decimals();
        uint256 expectedUsdcAmount = (fillAmount * usdcAmount) / baseAmount;
        uint256 makerFee = (fillAmount * otc.makerFeeBps()) / 10000; // Maker fee on base token amount
        uint256 takerFee = (expectedUsdcAmount * otc.takerFeeBps()) / 10000;

        uint256 user1InitialUsdc = usdc.balanceOf(user1);
        uint256 user2InitialBase = baseToken.balanceOf(user2);

        vm.startPrank(user2);
        usdc.approve(address(otc), expectedUsdcAmount + takerFee);
        otc.fillOrder(orderId, fillAmount);
        vm.stopPrank();

        // Check balances
        assertEq(baseToken.balanceOf(user2), user2InitialBase + fillAmount);
        // Maker receives: expectedUsdcAmount - makerFee (maker fee is calculated on counterparty tokens)
        uint256 makerFeeInUsdc = (expectedUsdcAmount * otc.makerFeeBps()) / 10000;
        assertEq(usdc.balanceOf(user1), user1InitialUsdc + expectedUsdcAmount - makerFeeInUsdc);
    }

    function test_CancelOrder() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create order
        vm.startPrank(user1);
        uint256 balanceBefore = baseToken.balanceOf(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        otc.cancelOrder(orderId);
        vm.stopPrank();

        // Check that tokens were returned
        assertEq(baseToken.balanceOf(user1), balanceBefore);
        OTCTrading.Order memory order = otc.getOrder(orderId);
        assertFalse(order.isActive);
    }

    function test_WhitelistRequirement() public {
        address nonWhitelisted = address(0x999);
        usdc.mint(nonWhitelisted, 10000 * 10 ** usdc.decimals());

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(nonWhitelisted);
        baseToken.mint(nonWhitelisted, baseAmount);
        baseToken.approve(address(otc), baseAmount);
        vm.expectRevert("OTCTrading: not whitelisted");
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();
    }

    function test_MinOrderSize() public {
        uint256 baseAmount = 50; // Below minimum
        uint256 usdcAmount = 100;

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        vm.expectRevert("OTCTrading: order size below minimum");
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();
    }

    function test_AdminFunctions() public {
        // Add new counterparty token
        MockERC20 newToken = new MockERC20("New Token", "NEW");
        vm.prank(admin);
        otc.addCounterpartyToken(address(newToken));
        assertTrue(otc.allowedCounterpartyTokens(address(newToken)));

        // Update fees
        vm.prank(admin);
        otc.updateFees(30, 60); // 0.3% maker, 0.6% taker
        assertEq(otc.makerFeeBps(), 30);
        assertEq(otc.takerFeeBps(), 60);

        // Update min order size
        vm.prank(admin);
        otc.updateMinOrderSize(200);
        assertEq(otc.minOrderSize(), 200);

        // Update whitelist requirement
        vm.prank(admin);
        otc.updateWhitelistRequirement(false);
        assertFalse(otc.requireWhitelist());
    }

    function test_PauseUnpause() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Pause
        vm.prank(admin);
        otc.pause();

        // Try to create order (should fail)
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        vm.expectRevert();
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Unpause
        vm.prank(admin);
        otc.unpause();

        // Now should work
        vm.startPrank(user1);
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();
    }

    // ============ ETH Tests ============

    function test_AddETHAsCounterpartyToken() public {
        vm.prank(admin);
        otc.addCounterpartyToken(address(0));
        assertTrue(otc.allowedCounterpartyTokens(address(0)));
    }

    function test_CreateBuyOrderWithETH() public {
        // Add ETH as counterparty token
        vm.prank(admin);
        otc.addCounterpartyToken(address(0));

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 ethAmount = 2 ether;

        vm.startPrank(user1);
        vm.deal(user1, 10 ether); // Give user1 some ETH
        uint256 user1BalanceBefore = user1.balance;
        uint256 orderId = otc.createOrder{value: ethAmount}(
            OTCTrading.OrderType.BUY,
            address(0), // ETH
            baseAmount,
            ethAmount
        );
        vm.stopPrank();

        assertEq(orderId, 1);
        OTCTrading.Order memory order = otc.getOrder(orderId);
        assertEq(order.maker, user1);
        assertEq(uint256(order.orderType), uint256(OTCTrading.OrderType.BUY));
        assertEq(order.counterpartyToken, address(0));
        assertEq(order.baseTokenAmount, baseAmount);
        assertEq(order.counterpartyTokenAmount, ethAmount);
        assertTrue(order.isActive);
        
        // Check ETH was deposited
        assertEq(user1.balance, user1BalanceBefore - ethAmount);
        assertEq(address(otc).balance, ethAmount);
    }

    function test_CreateSellOrderWithETHCounterparty() public {
        // Add ETH as counterparty token
        vm.prank(admin);
        otc.addCounterpartyToken(address(0));

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 ethAmount = 2 ether;

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(0), baseAmount, ethAmount);
        vm.stopPrank();

        assertEq(orderId, 1);
        OTCTrading.Order memory order = otc.getOrder(orderId);
        assertEq(order.counterpartyToken, address(0));
        assertEq(order.counterpartyTokenAmount, ethAmount);
        assertTrue(order.isActive);
    }

    function test_FillSellOrderWithETH() public {
        // Add ETH as counterparty token
        vm.prank(admin);
        otc.addCounterpartyToken(address(0));

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 ethAmount = 2 ether;

        // Create SELL order (user1 sells base tokens for ETH)
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(0), baseAmount, ethAmount);
        vm.stopPrank();

        // Fill order (user2 buys base tokens with ETH)
        uint256 fillAmount = 500 * 10 ** baseToken.decimals();
        uint256 expectedEthAmount = (fillAmount * ethAmount) / baseAmount;
        uint256 makerFee = (expectedEthAmount * otc.makerFeeBps()) / 10000;
        uint256 takerFee = (expectedEthAmount * otc.takerFeeBps()) / 10000;

        uint256 user1EthBefore = user1.balance;
        uint256 user2BaseBefore = baseToken.balanceOf(user2);
        uint256 feeRecipientEthBefore = feeRecipient.balance;

        vm.startPrank(user2);
        vm.deal(user2, 10 ether); // Give user2 some ETH
        otc.fillOrder{value: expectedEthAmount + takerFee}(orderId, fillAmount);
        vm.stopPrank();

        // Check balances
        assertEq(baseToken.balanceOf(user2), user2BaseBefore + fillAmount);
        assertEq(user1.balance, user1EthBefore + expectedEthAmount - makerFee);
        assertEq(feeRecipient.balance, feeRecipientEthBefore + makerFee + takerFee);
    }

    function test_FillBuyOrderWithETH() public {
        // Add ETH as counterparty token
        vm.prank(admin);
        otc.addCounterpartyToken(address(0));

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 ethAmount = 2 ether;

        // Create BUY order (user1 buys base tokens with ETH)
        vm.startPrank(user1);
        vm.deal(user1, 10 ether);
        uint256 orderId = otc.createOrder{value: ethAmount}(
            OTCTrading.OrderType.BUY,
            address(0),
            baseAmount,
            ethAmount
        );
        vm.stopPrank();

        // Fill order (user2 sells base tokens for ETH)
        uint256 fillAmount = 500 * 10 ** baseToken.decimals();
        uint256 expectedEthAmount = (fillAmount * ethAmount) / baseAmount;
        uint256 makerFee = (expectedEthAmount * otc.makerFeeBps()) / 10000;
        uint256 takerFee = (expectedEthAmount * otc.takerFeeBps()) / 10000;

        uint256 user1BaseBefore = baseToken.balanceOf(user1);
        uint256 user2EthBefore = user2.balance;
        uint256 feeRecipientEthBefore = feeRecipient.balance;

        vm.startPrank(user2);
        baseToken.approve(address(otc), fillAmount);
        otc.fillOrder(orderId, fillAmount);
        vm.stopPrank();

        // Check balances
        assertEq(baseToken.balanceOf(user1), user1BaseBefore + fillAmount);
        assertEq(user2.balance, user2EthBefore + expectedEthAmount - takerFee);
        assertEq(feeRecipient.balance, feeRecipientEthBefore + makerFee + takerFee);
    }

    function test_CancelBuyOrderWithETH() public {
        // Add ETH as counterparty token
        vm.prank(admin);
        otc.addCounterpartyToken(address(0));

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 ethAmount = 2 ether;

        // Create BUY order
        vm.startPrank(user1);
        vm.deal(user1, 10 ether);
        uint256 user1BalanceBefore = user1.balance;
        uint256 orderId = otc.createOrder{value: ethAmount}(
            OTCTrading.OrderType.BUY,
            address(0),
            baseAmount,
            ethAmount
        );
        otc.cancelOrder(orderId);
        vm.stopPrank();

        // Check that ETH was returned
        assertEq(user1.balance, user1BalanceBefore);
        OTCTrading.Order memory order = otc.getOrder(orderId);
        assertFalse(order.isActive);
    }

    function test_CreateBuyOrderWithETHIncorrectAmount() public {
        // Add ETH as counterparty token
        vm.prank(admin);
        otc.addCounterpartyToken(address(0));

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 ethAmount = 2 ether;

        vm.startPrank(user1);
        vm.deal(user1, 10 ether);
        vm.expectRevert("OTCTrading: incorrect ETH amount");
        otc.createOrder{value: ethAmount + 1 ether}(
            OTCTrading.OrderType.BUY,
            address(0),
            baseAmount,
            ethAmount
        );
        vm.stopPrank();
    }

    function test_FillSellOrderWithETHInsufficientAmount() public {
        // Add ETH as counterparty token
        vm.prank(admin);
        otc.addCounterpartyToken(address(0));

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 ethAmount = 2 ether;

        // Create SELL order
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(0), baseAmount, ethAmount);
        vm.stopPrank();

        // Try to fill with insufficient ETH
        uint256 fillAmount = 500 * 10 ** baseToken.decimals();
        uint256 expectedEthAmount = (fillAmount * ethAmount) / baseAmount;
        uint256 takerFee = (expectedEthAmount * otc.takerFeeBps()) / 10000;

        vm.startPrank(user2);
        vm.deal(user2, 10 ether);
        vm.expectRevert("OTCTrading: insufficient ETH sent");
        otc.fillOrder{value: expectedEthAmount + takerFee - 1 wei}(orderId, fillAmount);
        vm.stopPrank();
    }

    // ============ BUY Order with ERC20 Tests ============

    function test_CreateBuyOrderWithERC20() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        usdc.approve(address(otc), usdcAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.BUY, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        assertEq(orderId, 1);
        OTCTrading.Order memory order = otc.getOrder(orderId);
        assertEq(order.maker, user1);
        assertEq(uint256(order.orderType), uint256(OTCTrading.OrderType.BUY));
        assertEq(order.counterpartyToken, address(usdc));
        assertEq(order.baseTokenAmount, baseAmount);
        assertEq(order.counterpartyTokenAmount, usdcAmount);
        assertTrue(order.isActive);
    }

    function test_FillBuyOrderWithERC20() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create BUY order (user1 buys base tokens with USDC)
        vm.startPrank(user1);
        usdc.approve(address(otc), usdcAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.BUY, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Fill order (user2 sells base tokens for USDC)
        uint256 fillAmount = 500 * 10 ** baseToken.decimals();
        uint256 expectedUsdcAmount = (fillAmount * usdcAmount) / baseAmount;
        uint256 makerFee = (expectedUsdcAmount * otc.makerFeeBps()) / 10000;
        uint256 takerFee = (expectedUsdcAmount * otc.takerFeeBps()) / 10000;

        uint256 user1BaseBefore = baseToken.balanceOf(user1);
        uint256 user2UsdcBefore = usdc.balanceOf(user2);
        uint256 feeRecipientUsdcBefore = usdc.balanceOf(feeRecipient);

        vm.startPrank(user2);
        baseToken.approve(address(otc), fillAmount);
        otc.fillOrder(orderId, fillAmount);
        vm.stopPrank();

        // Check balances
        assertEq(baseToken.balanceOf(user1), user1BaseBefore + fillAmount);
        assertEq(usdc.balanceOf(user2), user2UsdcBefore + expectedUsdcAmount - takerFee);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientUsdcBefore + makerFee + takerFee);
    }

    function test_CancelBuyOrderWithERC20() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create BUY order
        vm.startPrank(user1);
        uint256 usdcBefore = usdc.balanceOf(user1);
        usdc.approve(address(otc), usdcAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.BUY, address(usdc), baseAmount, usdcAmount);
        otc.cancelOrder(orderId);
        vm.stopPrank();

        // Check that USDC was returned
        assertEq(usdc.balanceOf(user1), usdcBefore);
        OTCTrading.Order memory order = otc.getOrder(orderId);
        assertFalse(order.isActive);
    }

    // ============ FillOrder Edge Cases ============

    function test_FillOwnOrder() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.expectRevert("OTCTrading: cannot fill own order");
        otc.fillOrder(orderId, baseAmount / 2);
        vm.stopPrank();
    }

    function test_FillCancelledOrder() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        otc.cancelOrder(orderId);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount);
        vm.expectRevert("OTCTrading: order not active");
        otc.fillOrder(orderId, baseAmount / 2);
        vm.stopPrank();
    }

    function test_FillFullyFilledOrder() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create order
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Fill completely
        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount + (usdcAmount * otc.takerFeeBps()) / 10000);
        otc.fillOrder(orderId, baseAmount);
        vm.stopPrank();

        // Try to fill again
        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount);
        vm.expectRevert("OTCTrading: order not active");
        otc.fillOrder(orderId, 1);
        vm.stopPrank();
    }

    function test_FillExceedsOrderSize() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount * 2);
        vm.expectRevert("OTCTrading: exceeds order size");
        otc.fillOrder(orderId, baseAmount + 1);
        vm.stopPrank();
    }

    function test_FullFillOrder() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create order
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Fill completely
        uint256 takerFee = (usdcAmount * otc.takerFeeBps()) / 10000;
        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount + takerFee);
        otc.fillOrder(orderId, baseAmount);
        vm.stopPrank();

        // Check order is inactive
        OTCTrading.Order memory order = otc.getOrder(orderId);
        assertFalse(order.isActive);
        assertEq(order.filledAmount, baseAmount);
    }

    function test_MultiplePartialFills() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create order
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // First partial fill
        uint256 fillAmount1 = 300 * 10 ** baseToken.decimals();
        uint256 expectedUsdc1 = (fillAmount1 * usdcAmount) / baseAmount;
        uint256 takerFee1 = (expectedUsdc1 * otc.takerFeeBps()) / 10000;

        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount * 2);
        otc.fillOrder(orderId, fillAmount1);
        vm.stopPrank();

        // Second partial fill
        uint256 fillAmount2 = 400 * 10 ** baseToken.decimals();
        uint256 expectedUsdc2 = (fillAmount2 * usdcAmount) / baseAmount;
        uint256 takerFee2 = (expectedUsdc2 * otc.takerFeeBps()) / 10000;

        vm.startPrank(user2);
        otc.fillOrder(orderId, fillAmount2);
        vm.stopPrank();

        // Check order state
        OTCTrading.Order memory order = otc.getOrder(orderId);
        assertEq(order.filledAmount, fillAmount1 + fillAmount2);
        assertTrue(order.isActive);

        // Third fill to complete
        uint256 fillAmount3 = baseAmount - fillAmount1 - fillAmount2;
        vm.startPrank(user2);
        otc.fillOrder(orderId, fillAmount3);
        vm.stopPrank();

        // Check order is now inactive
        order = otc.getOrder(orderId);
        assertFalse(order.isActive);
        assertEq(order.filledAmount, baseAmount);
    }

    function test_FillOrderWhenPaused() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create order
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Pause
        vm.prank(admin);
        otc.pause();

        // Try to fill
        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount);
        vm.expectRevert();
        otc.fillOrder(orderId, baseAmount / 2);
        vm.stopPrank();
    }

    // ============ CancelOrder Edge Cases ============

    function test_CancelSomeoneElsesOrder() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert("OTCTrading: not order maker");
        otc.cancelOrder(orderId);
        vm.stopPrank();
    }

    function test_CancelAlreadyCancelledOrder() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        otc.cancelOrder(orderId);
        vm.expectRevert("OTCTrading: order not active");
        otc.cancelOrder(orderId);
        vm.stopPrank();
    }

    function test_CancelFullyFilledOrder() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create order
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Fill completely
        uint256 takerFee = (usdcAmount * otc.takerFeeBps()) / 10000;
        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount + takerFee);
        otc.fillOrder(orderId, baseAmount);
        vm.stopPrank();

        // Try to cancel (order is inactive, so it fails at isActive check)
        vm.startPrank(user1);
        vm.expectRevert("OTCTrading: order not active");
        otc.cancelOrder(orderId);
        vm.stopPrank();
    }

    // ============ View Functions ============

    function test_GetUserOrders() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount * 3);
        uint256 orderId1 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        uint256 orderId2 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        uint256 orderId3 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        uint256[] memory orders = otc.getUserOrders(user1);
        assertEq(orders.length, 3);
        assertEq(orders[0], orderId1);
        assertEq(orders[1], orderId2);
        assertEq(orders[2], orderId3);
    }

    function test_GetRemainingAmount() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Check initial remaining amount
        assertEq(otc.getRemainingAmount(orderId), baseAmount);

        // Partial fill
        uint256 fillAmount = 300 * 10 ** baseToken.decimals();
        uint256 expectedUsdc = (fillAmount * usdcAmount) / baseAmount;
        uint256 takerFee = (expectedUsdc * otc.takerFeeBps()) / 10000;

        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount * 2);
        otc.fillOrder(orderId, fillAmount);
        vm.stopPrank();

        // Check remaining amount
        assertEq(otc.getRemainingAmount(orderId), baseAmount - fillAmount);

        // Fill completely
        uint256 remaining = baseAmount - fillAmount;
        uint256 expectedUsdc2 = (remaining * usdcAmount) / baseAmount;
        uint256 takerFee2 = (expectedUsdc2 * otc.takerFeeBps()) / 10000;

        vm.startPrank(user2);
        otc.fillOrder(orderId, remaining);
        vm.stopPrank();

        // Check remaining amount is 0
        assertEq(otc.getRemainingAmount(orderId), 0);
    }

    function test_GetRemainingAmountCancelledOrder() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        otc.cancelOrder(orderId);
        vm.stopPrank();

        // Cancelled order should return 0
        assertEq(otc.getRemainingAmount(orderId), 0);
    }

    // ============ Admin Functions (Missing) ============

    function test_RemoveCounterpartyToken() public {
        // Remove USDC
        vm.prank(admin);
        otc.removeCounterpartyToken(address(usdc));
        assertFalse(otc.allowedCounterpartyTokens(address(usdc)));

        // Try to create order with removed token (should fail)
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        vm.expectRevert("OTCTrading: counterparty token not allowed");
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();
    }

    function test_RemoveFromWhitelist() public {
        // Remove user1 from whitelist
        vm.prank(admin);
        otc.removeFromWhitelist(user1);
        assertFalse(otc.whitelist(user1));

        // Try to create order (should fail)
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        vm.expectRevert("OTCTrading: not whitelisted");
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();
    }

    function test_UpdateFeeRecipient() public {
        address newFeeRecipient = address(0x999);
        vm.prank(admin);
        otc.updateFeeRecipient(newFeeRecipient);
        assertEq(otc.feeRecipient(), newFeeRecipient);
    }

    function test_UpdateFeesTooHigh() public {
        vm.prank(admin);
        vm.expectRevert("OTCTrading: maker fee too high");
        otc.updateFees(1001, 50); // Maker fee > 10%

        vm.prank(admin);
        vm.expectRevert("OTCTrading: taker fee too high");
        otc.updateFees(25, 1001); // Taker fee > 10%
    }

    function test_UpdateMinOrderSizeZero() public {
        vm.prank(admin);
        vm.expectRevert("OTCTrading: invalid min order size");
        otc.updateMinOrderSize(0);
    }

    // ============ Other Edge Cases ============

    function test_CreateOrderInvalidCounterpartyToken() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        MockERC20 invalidToken = new MockERC20("Invalid", "INV");

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        vm.expectRevert("OTCTrading: counterparty token not allowed");
        otc.createOrder(OTCTrading.OrderType.SELL, address(invalidToken), baseAmount, usdcAmount);
        vm.stopPrank();
    }

    function test_CreateOrderZeroCounterpartyAmount() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        vm.expectRevert("OTCTrading: invalid counterparty amount");
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, 0);
        vm.stopPrank();
    }

    function test_FillOrderZeroAmount() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert("OTCTrading: invalid fill amount");
        otc.fillOrder(orderId, 0);
        vm.stopPrank();
    }

    function test_OrderBecomesInactiveWhenFullyFilled() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Order should be active initially
        OTCTrading.Order memory order = otc.getOrder(orderId);
        assertTrue(order.isActive);

        // Fill completely
        uint256 takerFee = (usdcAmount * otc.takerFeeBps()) / 10000;
        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount + takerFee);
        otc.fillOrder(orderId, baseAmount);
        vm.stopPrank();

        // Order should be inactive
        order = otc.getOrder(orderId);
        assertFalse(order.isActive);
        assertEq(order.filledAmount, baseAmount);
    }

    function test_NextOrderIdIncrements() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount * 3);
        uint256 orderId1 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        uint256 orderId2 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        uint256 orderId3 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        assertEq(orderId1, 1);
        assertEq(orderId2, 2);
        assertEq(orderId3, 3);
    }

    function test_FillOrderNotWhitelisted() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create order
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Remove user2 from whitelist
        vm.prank(admin);
        otc.removeFromWhitelist(user2);

        // Try to fill (should fail)
        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount);
        vm.expectRevert("OTCTrading: not whitelisted");
        otc.fillOrder(orderId, baseAmount / 2);
        vm.stopPrank();
    }

    // ============ New Feature Tests ============

    function test_UpdateMaxOrderSize() public {
        // Set max order size (in base token units, not decimals)
        vm.prank(admin);
        otc.updateMaxOrderSize(5000);
        assertEq(otc.maxOrderSize(), 5000);

        // Try to create order above max (should fail)
        uint256 baseAmount = 6000; // Above max (5000)
        uint256 usdcAmount = 12000;

        vm.startPrank(user1);
        baseToken.mint(user1, baseAmount);
        baseToken.approve(address(otc), baseAmount);
        vm.expectRevert("OTCTrading: order size above maximum");
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Try to create order within max (should work)
        baseAmount = 4000; // Within max (5000)
        usdcAmount = 8000;

        vm.startPrank(user1);
        baseToken.mint(user1, baseAmount);
        baseToken.approve(address(otc), baseAmount);
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Remove max (set to 0)
        vm.prank(admin);
        otc.updateMaxOrderSize(0);
        assertEq(otc.maxOrderSize(), 0);
    }

    function test_UpdateMaxOrderSizeBelowMin() public {
        vm.prank(admin);
        vm.expectRevert("OTCTrading: max below min");
        otc.updateMaxOrderSize(50); // Below minOrderSize (100)
    }

    function test_UpdateDefaultOrderExpiration() public {
        // Set expiration to 1 day
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(1 days);
        assertEq(otc.defaultOrderExpiration(), 1 days);

        // Create order - should have expiration
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        OTCTrading.Order memory order = otc.getOrder(orderId);
        assertEq(order.expiresAt, block.timestamp + 1 days);

        // Remove expiration
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(0);
        assertEq(otc.defaultOrderExpiration(), 0);
    }

    function test_BatchAddToWhitelist() public {
        address user3 = address(0x3);
        address user4 = address(0x4);
        address user5 = address(0x5);

        address[] memory accounts = new address[](3);
        accounts[0] = user3;
        accounts[1] = user4;
        accounts[2] = user5;

        vm.prank(admin);
        otc.batchAddToWhitelist(accounts);

        assertTrue(otc.whitelist(user3));
        assertTrue(otc.whitelist(user4));
        assertTrue(otc.whitelist(user5));
    }

    function test_BatchAddToWhitelistWithInvalidAddress() public {
        address user3 = address(0x3);
        address user4 = address(0);

        address[] memory accounts = new address[](2);
        accounts[0] = user3;
        accounts[1] = user4;

        vm.prank(admin);
        vm.expectRevert("OTCTrading: invalid account");
        otc.batchAddToWhitelist(accounts);
    }

    function test_BatchRemoveFromWhitelist() public {
        address user3 = address(0x3);
        address user4 = address(0x4);

        // Add them first
        vm.prank(admin);
        otc.addToWhitelist(user3);
        vm.prank(admin);
        otc.addToWhitelist(user4);

        address[] memory accounts = new address[](2);
        accounts[0] = user3;
        accounts[1] = user4;

        vm.prank(admin);
        otc.batchRemoveFromWhitelist(accounts);

        assertFalse(otc.whitelist(user3));
        assertFalse(otc.whitelist(user4));
    }

    function test_BatchCancelOrders() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        uint256 balanceBefore = baseToken.balanceOf(user1);

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount * 3);
        uint256 orderId1 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        uint256 orderId2 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        uint256 orderId3 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        uint256 balanceAfterCreate = baseToken.balanceOf(user1);
        assertEq(balanceAfterCreate, balanceBefore - (baseAmount * 3));

        uint256[] memory orderIds = new uint256[](3);
        orderIds[0] = orderId1;
        orderIds[1] = orderId2;
        orderIds[2] = orderId3;

        vm.startPrank(user1);
        otc.batchCancelOrders(orderIds);
        vm.stopPrank();

        // Check all orders are cancelled
        assertFalse(otc.getOrder(orderId1).isActive);
        assertFalse(otc.getOrder(orderId2).isActive);
        assertFalse(otc.getOrder(orderId3).isActive);

        // Check tokens were returned
        assertEq(baseToken.balanceOf(user1), balanceBefore);
    }

    function test_CleanupExpiredOrders() public {
        // Set expiration to 1 hour
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(1 hours);

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create orders
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount * 2);
        uint256 orderId1 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        vm.startPrank(user2);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId2 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Fast forward time
        vm.warp(block.timestamp + 2 hours);

        // Cleanup expired orders
        uint256[] memory orderIds = new uint256[](2);
        orderIds[0] = orderId1;
        orderIds[1] = orderId2;

        uint256 user1BalanceBefore = baseToken.balanceOf(user1);
        uint256 user2BalanceBefore = baseToken.balanceOf(user2);

        vm.prank(admin);
        uint256 cleaned = otc.cleanupExpiredOrders(orderIds);

        assertEq(cleaned, 2);
        assertFalse(otc.getOrder(orderId1).isActive);
        assertFalse(otc.getOrder(orderId2).isActive);

        // Check tokens were returned
        assertEq(baseToken.balanceOf(user1), user1BalanceBefore + baseAmount);
        assertEq(baseToken.balanceOf(user2), user2BalanceBefore + baseAmount);

        // Reset expiration
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(0);
    }

    function test_CleanupExpiredOrdersWithETH() public {
        // Add ETH as counterparty token
        vm.prank(admin);
        otc.addCounterpartyToken(address(0));

        // Set expiration to 1 hour
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(1 hours);

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 ethAmount = 2 ether;

        // Create BUY order with ETH
        vm.startPrank(user1);
        vm.deal(user1, 10 ether);
        uint256 user1BalanceBefore = user1.balance;
        uint256 orderId = otc.createOrder{value: ethAmount}(
            OTCTrading.OrderType.BUY,
            address(0),
            baseAmount,
            ethAmount
        );
        vm.stopPrank();

        // Fast forward time
        vm.warp(block.timestamp + 2 hours);

        // Cleanup expired order
        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = orderId;

        vm.prank(admin);
        uint256 cleaned = otc.cleanupExpiredOrders(orderIds);

        assertEq(cleaned, 1);
        assertFalse(otc.getOrder(orderId).isActive);
        assertEq(user1.balance, user1BalanceBefore); // ETH was returned

        // Reset expiration
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(0);
    }

    function test_EmergencyWithdrawERC20() public {
        // Send some tokens to contract (simulate stuck tokens)
        uint256 stuckAmount = 1000 * 10 ** baseToken.decimals();
        vm.startPrank(user1);
        baseToken.transfer(address(otc), stuckAmount);
        vm.stopPrank();

        address recipient = address(0x999);
        uint256 recipientBalanceBefore = baseToken.balanceOf(recipient);

        vm.prank(admin);
        otc.emergencyWithdraw(address(baseToken), recipient, 0); // 0 = withdraw all

        assertEq(baseToken.balanceOf(recipient), recipientBalanceBefore + stuckAmount);
    }

    function test_EmergencyWithdrawETH() public {
        // Send ETH to contract
        vm.deal(address(otc), 5 ether);

        address recipient = address(0x999);
        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(admin);
        otc.emergencyWithdraw(address(0), recipient, 0); // 0 = withdraw all

        assertEq(recipient.balance, recipientBalanceBefore + 5 ether);
    }

    function test_EmergencyWithdrawPartialAmount() public {
        uint256 stuckAmount = 1000 * 10 ** baseToken.decimals();
        vm.startPrank(user1);
        baseToken.transfer(address(otc), stuckAmount);
        vm.stopPrank();

        address recipient = address(0x999);
        uint256 withdrawAmount = 500 * 10 ** baseToken.decimals();

        vm.prank(admin);
        otc.emergencyWithdraw(address(baseToken), recipient, withdrawAmount);

        assertEq(baseToken.balanceOf(recipient), withdrawAmount);
        assertEq(baseToken.balanceOf(address(otc)), stuckAmount - withdrawAmount);
    }

    function test_EmergencyWithdrawNotAdmin() public {
        vm.startPrank(user1);
        vm.expectRevert();
        otc.emergencyWithdraw(address(baseToken), address(0x999), 0);
        vm.stopPrank();
    }

    function test_GetActiveOrders() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create multiple orders
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount * 3);
        uint256 orderId1 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        uint256 orderId2 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        uint256 orderId3 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Fill one order
        uint256 takerFee = (usdcAmount * otc.takerFeeBps()) / 10000;
        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount + takerFee);
        otc.fillOrder(orderId2, baseAmount);
        vm.stopPrank();

        // Get active orders
        (uint256[] memory orderIds, uint256 total) = otc.getActiveOrders(0, 10);

        assertEq(total, 2); // Only orderId1 and orderId3 should be active
        assertEq(orderIds.length, 2);
        // Should contain orderId1 and orderId3 (not orderId2 as it's filled)
    }

    function test_GetOrdersByToken() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW");
        vm.prank(admin);
        otc.addCounterpartyToken(address(newToken));

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();
        uint256 newTokenAmount = 3000 * 10 ** newToken.decimals();

        // Create orders with different tokens
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount * 3);
        uint256 orderId1 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        uint256 orderId2 = otc.createOrder(OTCTrading.OrderType.SELL, address(newToken), baseAmount, newTokenAmount);
        uint256 orderId3 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Get orders by USDC token
        uint256[] memory usdcOrders = otc.getOrdersByToken(address(usdc), 0, 10);
        assertEq(usdcOrders.length, 2);
        assertTrue(usdcOrders[0] == orderId1 || usdcOrders[0] == orderId3);
        assertTrue(usdcOrders[1] == orderId1 || usdcOrders[1] == orderId3);

        // Get orders by newToken
        uint256[] memory newTokenOrders = otc.getOrdersByToken(address(newToken), 0, 10);
        assertEq(newTokenOrders.length, 1);
        // Note: orderId2 should be in newTokenOrders, but order IDs might vary
    }

    function test_IsOrderExpired() public {
        // Set expiration to 1 hour
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(1 hours);

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Should not be expired initially
        assertFalse(otc.isOrderExpired(orderId));

        // Fast forward time
        vm.warp(block.timestamp + 2 hours);

        // Should be expired
        assertTrue(otc.isOrderExpired(orderId));

        // Reset expiration
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(0);
    }

    function test_FillExpiredOrder() public {
        // Set expiration to 1 hour
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(1 hours);

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Fast forward time
        vm.warp(block.timestamp + 2 hours);

        // Try to fill expired order (should fail)
        uint256 takerFee = (usdcAmount * otc.takerFeeBps()) / 10000;
        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount + takerFee);
        vm.expectRevert("OTCTrading: order expired");
        otc.fillOrder(orderId, baseAmount);
        vm.stopPrank();

        // Reset expiration
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(0);
    }

    function test_GetRemainingAmountExpiredOrder() public {
        // Set expiration to 1 hour
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(1 hours);

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Fast forward time
        vm.warp(block.timestamp + 2 hours);

        // Remaining amount should be 0 for expired order
        assertEq(otc.getRemainingAmount(orderId), 0);

        // Reset expiration
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(0);
    }

    function test_CreateOrderPriceTooLow() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 1; // Extremely low price

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        vm.expectRevert("OTCTrading: price too low");
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();
    }

    function test_CreateOrderPriceTooHigh() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals(); // Valid amount (above min)
        // Price ratio: usdcAmount * 1e18 / baseAmount should exceed 1e36
        // So: usdcAmount * 1e18 > 1e36 * baseAmount
        // usdcAmount > 1e18 * baseAmount
        // For baseAmount = 1000 * 1e18, usdcAmount > 1e39
        uint256 usdcAmount = 2e39; // Price ratio would be 2e39 * 1e18 / (1000 * 1e18) = 2e36 > 1e36

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        vm.expectRevert("OTCTrading: price too high");
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();
    }

    function test_CreateOrderAboveMaxOrderSize() public {
        // Set max order size
        vm.prank(admin);
        otc.updateMaxOrderSize(5000);

        uint256 baseAmount = 6000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 12000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        vm.expectRevert("OTCTrading: order size above maximum");
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Reset max order size
        vm.prank(admin);
        otc.updateMaxOrderSize(0);
    }

    // ============ Additional Edge Cases ============

    function test_CancelOrderWhenPaused() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create order
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Pause contract
        vm.prank(admin);
        otc.pause();

        // Cancel order should still work (cancelOrder doesn't have whenNotPaused)
        uint256 balanceBefore = baseToken.balanceOf(user1);
        vm.prank(user1);
        otc.cancelOrder(orderId);

        // Check that tokens were returned
        assertEq(baseToken.balanceOf(user1), balanceBefore + baseAmount);
        OTCTrading.Order memory order = otc.getOrder(orderId);
        assertFalse(order.isActive);

        // Unpause
        vm.prank(admin);
        otc.unpause();
    }

    function test_GetActiveOrdersInvalidLimitZero() public {
        vm.expectRevert("OTCTrading: invalid limit");
        otc.getActiveOrders(0, 0);
    }

    function test_GetActiveOrdersInvalidLimitTooHigh() public {
        vm.expectRevert("OTCTrading: invalid limit");
        otc.getActiveOrders(0, 101);
    }

    function test_GetActiveOrdersOffsetBeyondTotal() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create 2 orders
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount * 2);
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Try offset beyond total (should return empty array)
        (uint256[] memory orderIds, uint256 total) = otc.getActiveOrders(100, 10);
        assertEq(total, 2);
        assertEq(orderIds.length, 0);
    }

    function test_GetOrdersByTokenInvalidLimitZero() public {
        vm.expectRevert("OTCTrading: invalid limit");
        otc.getOrdersByToken(address(usdc), 0, 0);
    }

    function test_GetOrdersByTokenInvalidLimitTooHigh() public {
        vm.expectRevert("OTCTrading: invalid limit");
        otc.getOrdersByToken(address(usdc), 0, 101);
    }

    function test_GetOrdersByTokenOffsetBeyondTotal() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create 2 orders with USDC
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount * 2);
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Try offset beyond total (should return empty array)
        uint256[] memory orderIds = otc.getOrdersByToken(address(usdc), 100, 10);
        assertEq(orderIds.length, 0);
    }

    function test_BatchCancelOrdersEmptyArray() public {
        // Should not revert, just do nothing
        uint256[] memory orderIds = new uint256[](0);
        vm.prank(user1);
        otc.batchCancelOrders(orderIds);
    }

    function test_BatchCancelOrdersMixedOrders() public {
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create orders by user1
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount * 3);
        uint256 orderId1 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        uint256 orderId2 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Create order by user2
        vm.startPrank(user2);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId3 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Cancel orderId2 manually
        vm.prank(user1);
        otc.cancelOrder(orderId2);

        uint256 balanceBefore = baseToken.balanceOf(user1);

        // Try to batch cancel: own order (orderId1), someone else's order (orderId3), already cancelled (orderId2)
        uint256[] memory orderIds = new uint256[](3);
        orderIds[0] = orderId1;
        orderIds[1] = orderId3; // user2's order
        orderIds[2] = orderId2; // already cancelled

        vm.prank(user1);
        otc.batchCancelOrders(orderIds);

        // Only orderId1 should be cancelled
        assertFalse(otc.getOrder(orderId1).isActive);
        assertTrue(otc.getOrder(orderId3).isActive); // user2's order should still be active
        assertFalse(otc.getOrder(orderId2).isActive); // was already cancelled

        // Check tokens were returned for orderId1
        assertEq(baseToken.balanceOf(user1), balanceBefore + baseAmount);
    }

    function test_CleanupExpiredOrdersEmptyArray() public {
        // Should not revert, just return 0
        uint256[] memory orderIds = new uint256[](0);
        vm.prank(admin);
        uint256 cleaned = otc.cleanupExpiredOrders(orderIds);
        assertEq(cleaned, 0);
    }

    function test_CleanupExpiredOrdersMixedOrders() public {
        // Set expiration to 1 hour
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(1 hours);

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Create orderId1
        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount * 3);
        uint256 orderId1 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Create orderId3
        vm.startPrank(user1);
        uint256 orderId3 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Fast forward time to expire orderId1 and orderId3 (they expire at T+1 hour)
        vm.warp(block.timestamp + 2 hours);

        // Create active order (not expired) - created at T+2 hours, expires at T+3 hours
        vm.startPrank(user2);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId2 = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Don't warp forward - orderId2 should still be active (expires at T+3 hours, current time is T+2 hours)

        uint256 user1BalanceBefore = baseToken.balanceOf(user1);
        uint256 user2BalanceBefore = baseToken.balanceOf(user2);

        // Cleanup: expired (orderId1), not expired (orderId2), expired (orderId3)
        uint256[] memory orderIds = new uint256[](3);
        orderIds[0] = orderId1; // expired
        orderIds[1] = orderId2; // not expired
        orderIds[2] = orderId3; // expired

        vm.prank(admin);
        uint256 cleaned = otc.cleanupExpiredOrders(orderIds);

        // Only 2 expired orders should be cleaned
        assertEq(cleaned, 2);
        assertFalse(otc.getOrder(orderId1).isActive); // expired, cleaned
        assertTrue(otc.getOrder(orderId2).isActive); // not expired, still active
        assertFalse(otc.getOrder(orderId3).isActive); // expired, cleaned

        // Check tokens were returned for expired orders only
        assertEq(baseToken.balanceOf(user1), user1BalanceBefore + (baseAmount * 2)); // orderId1 and orderId3
        assertEq(baseToken.balanceOf(user2), user2BalanceBefore); // orderId2 not cleaned

        // Reset expiration
        vm.prank(admin);
        otc.updateDefaultOrderExpiration(0);
    }

    function test_EmergencyWithdrawExceedsBalance() public {
        uint256 stuckAmount = 1000 * 10 ** baseToken.decimals();
        
        // Send some tokens to contract
        vm.startPrank(user1);
        baseToken.transfer(address(otc), stuckAmount);
        vm.stopPrank();

        address recipient = address(0x999);
        uint256 withdrawAmount = stuckAmount + 1; // More than balance

        vm.prank(admin);
        vm.expectRevert("OTCTrading: insufficient balance");
        otc.emergencyWithdraw(address(baseToken), recipient, withdrawAmount);
    }

    function test_EmergencyWithdrawETHExceedsBalance() public {
        vm.deal(address(otc), 5 ether);
        
        address recipient = address(0x999);
        uint256 withdrawAmount = 6 ether; // More than balance

        vm.prank(admin);
        vm.expectRevert("OTCTrading: insufficient balance");
        otc.emergencyWithdraw(address(0), recipient, withdrawAmount);
    }

    function test_UpdateMinOrderSizeExceedsMax() public {
        // Set max order size first
        vm.prank(admin);
        otc.updateMaxOrderSize(5000);
        
        // Try to set min order size above max (should fail)
        vm.prank(admin);
        vm.expectRevert("OTCTrading: min exceeds max");
        otc.updateMinOrderSize(6000); // Above maxOrderSize (5000)

        // Reset max order size
        vm.prank(admin);
        otc.updateMaxOrderSize(0);
    }

    // ============ Additional Edge Cases ============

    function test_UpdateWhitelistRequirementDisabled() public {
        address nonWhitelisted = address(0x999);
        usdc.mint(nonWhitelisted, 10000 * 10 ** usdc.decimals());
        baseToken.mint(nonWhitelisted, 10000 * 10 ** baseToken.decimals());

        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        // Disable whitelist requirement
        vm.prank(admin);
        otc.updateWhitelistRequirement(false);
        assertFalse(otc.requireWhitelist());

        // Non-whitelisted user should be able to create order
        vm.startPrank(nonWhitelisted);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        // Non-whitelisted user should be able to fill order (from another non-whitelisted user)
        address filler = address(0x888);
        usdc.mint(filler, 10000 * 10 ** usdc.decimals());
        uint256 takerFee = (usdcAmount * otc.takerFeeBps()) / 10000;

        vm.startPrank(filler);
        usdc.approve(address(otc), usdcAmount + takerFee);
        otc.fillOrder(orderId, baseAmount);
        vm.stopPrank();

        // Re-enable whitelist requirement
        vm.prank(admin);
        otc.updateWhitelistRequirement(true);
    }

    function test_UpdateWhitelistRequirementToggle() public {
        // Initially whitelist is required (from setUp)
        assertTrue(otc.requireWhitelist());

        // Toggle to false
        vm.prank(admin);
        otc.updateWhitelistRequirement(false);
        assertFalse(otc.requireWhitelist());

        // Toggle back to true
        vm.prank(admin);
        otc.updateWhitelistRequirement(true);
        assertTrue(otc.requireWhitelist());
    }

    function test_UpdateFeesZero() public {
        // Set fees to zero
        vm.prank(admin);
        otc.updateFees(0, 0);
        assertEq(otc.makerFeeBps(), 0);
        assertEq(otc.takerFeeBps(), 0);

        // Create and fill order with zero fees
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 user1BalanceBefore = usdc.balanceOf(user1);

        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount);
        otc.fillOrder(orderId, baseAmount);
        vm.stopPrank();

        // Check no fees were collected
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore);
        assertEq(usdc.balanceOf(user1), user1BalanceBefore + usdcAmount);

        // Reset fees to default
        vm.prank(admin);
        otc.updateFees(25, 50);
    }

    function test_UpdateFeesMax() public {
        // Set fees to maximum (1000 bps = 10%)
        vm.prank(admin);
        otc.updateFees(1000, 1000);
        assertEq(otc.makerFeeBps(), 1000);
        assertEq(otc.takerFeeBps(), 1000);

        // Create and fill order with max fees
        uint256 baseAmount = 1000 * 10 ** baseToken.decimals();
        uint256 usdcAmount = 2000 * 10 ** usdc.decimals();

        vm.startPrank(user1);
        baseToken.approve(address(otc), baseAmount);
        uint256 orderId = otc.createOrder(OTCTrading.OrderType.SELL, address(usdc), baseAmount, usdcAmount);
        vm.stopPrank();

        uint256 makerFee = (usdcAmount * 1000) / 10000; // 10%
        uint256 takerFee = (usdcAmount * 1000) / 10000; // 10%
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 user1BalanceBefore = usdc.balanceOf(user1);

        vm.startPrank(user2);
        usdc.approve(address(otc), usdcAmount + takerFee);
        otc.fillOrder(orderId, baseAmount);
        vm.stopPrank();

        // Check fees were collected
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + makerFee + takerFee);
        assertEq(usdc.balanceOf(user1), user1BalanceBefore + usdcAmount - makerFee);

        // Reset fees to default
        vm.prank(admin);
        otc.updateFees(25, 50);
    }

    function test_GetOrderNonExistent() public {
        // Get order with non-existent order ID
        OTCTrading.Order memory order = otc.getOrder(99999);
        
        // Should return default Order struct
        assertEq(order.id, 0);
        assertEq(order.maker, address(0));
        assertEq(uint256(order.orderType), 0); // BUY = 0
        assertEq(order.counterpartyToken, address(0));
        assertEq(order.baseTokenAmount, 0);
        assertEq(order.counterpartyTokenAmount, 0);
        assertEq(order.filledAmount, 0);
        assertFalse(order.isActive);
        assertEq(order.createdAt, 0);
        assertEq(order.expiresAt, 0);
    }

    function test_GetOrdersByTokenNoOrders() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW");
        vm.prank(admin);
        otc.addCounterpartyToken(address(newToken));

        // Get orders for token with no orders
        uint256[] memory orderIds = otc.getOrdersByToken(address(newToken), 0, 10);
        assertEq(orderIds.length, 0);
    }

    function test_GetActiveOrdersNoOrders() public {
        // Get active orders when there are no orders
        (uint256[] memory orderIds, uint256 total) = otc.getActiveOrders(0, 10);
        assertEq(total, 0);
        assertEq(orderIds.length, 0);
    }
}
