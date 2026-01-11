# OTC Trading Contract

An upgradeable Over-The-Counter (OTC) trading contract for ERC20 tokens with configurable fees, whitelist management, and multiple counterparty token support.

## ✨ Features

- ✅ **Proxy Contract Support** - Fully upgradeable using OpenZeppelin's transparent proxy pattern
- 💰 **Configurable Fees** - Maker fee (0.25% default) and Taker fee (0.5% default) in basis points
- 📋 **Whitelist Management** - Optional whitelist requirement for trading (enabled by default)
- 🪙 **Multiple Counterparty Tokens** - Admin can define allowed counterparty tokens (USDC as default)
- 📊 **Order Management** - Create, fill, and cancel orders
- ⏸️ **Pausable** - Admin can pause/unpause trading
- 🔒 **Access Control** - Role-based access control for admin functions
- 🛡️ **Reentrancy Protection** - Protected against reentrancy attacks

## 📋 Trading Parameters

| Parameter | Default Value | Description |
|-----------|--------------|-------------|
| Maker Fee | 0.25% (25 bps) | Fee charged to order creators |
| Taker Fee | 0.5% (50 bps) | Fee charged to order fillers |
| Minimum Order Size | 100 | Minimum base token amount for orders |
| Require Whitelist | true | Only whitelisted addresses can trade |

## 🏗️ Architecture

The contract uses OpenZeppelin's transparent proxy pattern:
- **Implementation Contract**: Contains the actual logic
- **Proxy Contract**: Points to the implementation and stores state
- **Proxy Admin**: Controls upgrades (has `DEFAULT_ADMIN_ROLE`)

## 🚀 Quick Start

### Prerequisites

1. Install dependencies:
```bash
# Using npm script (recommended)
npm run install:deps

# Or manually with forge
forge install OpenZeppelin/openzeppelin-contracts-upgradeable OpenZeppelin/openzeppelin-foundry-upgrades OpenZeppelin/openzeppelin-contracts
```

2. Set up environment variables in `.env`:
```bash
BASE_TOKEN=<address_of_erc20_token>  # The ERC20 token from ERC20 folder
DEFAULT_COUNTERPARTY_TOKEN=<usdc_address>  # Default counterparty token (e.g., USDC)
FEE_RECIPIENT=<address_to_receive_fees>
ADMIN=<admin_address>
```

### Build

```bash
forge build
```

### Test

```bash
# Run all tests
forge test

# Run with gas report
forge test --gas-report

# Run with verbose output
forge test -vv
```

### Deploy

```bash
# Local deployment
forge script script/DeployOTC.s.sol:DeployOTC --broadcast --rpc-url http://localhost:8545

# Testnet deployment
forge script script/DeployOTC.s.sol:DeployOTC \
  --private-key $DEPLOYER_KEY \
  --broadcast \
  --verify \
  --rpc-url $TESTNET_RPC \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --sender $DEPLOYER
```

## 📖 Contract Functions

### Admin Functions

#### Counterparty Token Management
- `addCounterpartyToken(address token)` - Add an allowed counterparty token
- `removeCounterpartyToken(address token)` - Remove a counterparty token

#### Fee Management
- `updateFees(uint256 makerFeeBps, uint256 takerFeeBps)` - Update trading fees (max 10% each)
- `updateFeeRecipient(address feeRecipient)` - Update fee recipient address

#### Order Configuration
- `updateMinOrderSize(uint256 minOrderSize)` - Update minimum order size
- `updateWhitelistRequirement(bool requireWhitelist)` - Enable/disable whitelist requirement

#### Whitelist Management
- `addToWhitelist(address account)` - Add address to whitelist
- `removeFromWhitelist(address account)` - Remove address from whitelist

#### Emergency Controls
- `pause()` - Pause all trading activities
- `unpause()` - Resume trading activities

### Trading Functions

#### Order Creation
- `createOrder(address counterpartyToken, uint256 baseTokenAmount, uint256 counterpartyTokenAmount)` 
  - Create a new order to sell base tokens for counterparty tokens
  - Returns: `orderId`

#### Order Filling
- `fillOrder(uint256 orderId, uint256 baseTokenAmount)` 
  - Fill an order (partially or fully)
  - Transfers tokens and applies fees

#### Order Cancellation
- `cancelOrder(uint256 orderId)` 
  - Cancel an active order
  - Returns remaining base tokens to maker

### View Functions

- `getOrder(uint256 orderId)` - Get complete order details
- `getUserOrders(address user)` - Get all order IDs for a user
- `getRemainingAmount(uint256 orderId)` - Get remaining unfilled amount
- `allowedCounterpartyTokens(address)` - Check if token is allowed
- `whitelist(address)` - Check if address is whitelisted
- `makerFeeBps()` - Get maker fee in basis points
- `takerFeeBps()` - Get taker fee in basis points
- `minOrderSize()` - Get minimum order size
- `requireWhitelist()` - Check if whitelist is required
- `baseToken()` - Get base token address
- `feeRecipient()` - Get fee recipient address

## 🔐 Roles

| Role | Description |
|------|-------------|
| `DEFAULT_ADMIN_ROLE` | Full admin access, can upgrade contract |
| `ADMIN_ROLE` | Can manage trading parameters, whitelist, and counterparty tokens |
| `FEE_RECIPIENT_ROLE` | Receives trading fees |

## 📝 Order Flow

### 1. Create Order (Maker)

```
1. User approves base tokens to OTC contract
2. User calls createOrder(counterpartyToken, baseAmount, counterpartyAmount)
3. Base tokens are transferred to contract
4. Order is created and stored
5. OrderCreated event is emitted
```

### 2. Fill Order (Taker)

```
1. User approves counterparty tokens to OTC contract
2. User calls fillOrder(orderId, fillAmount)
3. Contract calculates:
   - Counterparty token amount based on order price
   - Maker fee (from base token amount)
   - Taker fee (from counterparty token amount)
4. Tokens are swapped:
   - Counterparty tokens (minus maker fee) → Maker
   - Base tokens → Taker
   - Fees → Fee recipient
5. Order filled amount is updated
6. OrderFilled event is emitted
```

### 3. Cancel Order (Maker)

```
1. Maker calls cancelOrder(orderId)
2. Remaining base tokens are returned to maker
3. Order is marked as inactive
4. OrderCancelled event is emitted
```

## 💡 Example Usage

### Setup

```solidity
// 1. Deploy contract (done via script)
// 2. Admin adds USDC as counterparty token (done in initialization)
// 3. Admin adds users to whitelist
otc.addToWhitelist(userAddress);
```

### Trading

```solidity
// Maker creates order: sell 1000 BASE tokens for 2000 USDC
baseToken.approve(address(otc), 1000 * 10**18);
uint256 orderId = otc.createOrder(
    address(usdc), 
    1000 * 10**18,  // base token amount
    2000 * 10**6    // counterparty token amount
);

// Taker fills order: buy 500 BASE tokens
// Price: 500 BASE = 1000 USDC (plus fees)
uint256 fillAmount = 500 * 10**18;
uint256 counterpartyAmount = 1000 * 10**6;
uint256 takerFee = (counterpartyAmount * 50) / 10000; // 0.5%
usdc.approve(address(otc), counterpartyAmount + takerFee);
otc.fillOrder(orderId, fillAmount);

// Maker cancels remaining order
otc.cancelOrder(orderId);
```

## 🔄 Upgradeability

The contract uses OpenZeppelin's transparent proxy pattern:
- **Proxy Address**: Remains constant (this is the address users interact with)
- **Implementation**: Can be upgraded by `DEFAULT_ADMIN_ROLE`
- **State**: Stored in proxy, persists across upgrades

### Upgrade Process

```solidity
// Only DEFAULT_ADMIN_ROLE can upgrade
Upgrades.upgradeProxy(proxyAddress, "NewOTCTrading.sol", admin);
```

## ⚠️ Security Considerations

- ✅ **Reentrancy Protection**: All trading functions use `nonReentrant` modifier
- ✅ **Access Control**: Admin functions protected with role checks
- ✅ **Pausable**: Can pause trading in emergencies
- ✅ **Whitelist**: Optional additional security layer
- ✅ **SafeERC20**: Uses SafeERC20 for token transfers
- ✅ **Input Validation**: All inputs are validated
- ✅ **Order Validation**: Orders can only be filled by different addresses

## 📊 Fee Calculation

### Maker Fee
```
makerFee = (counterpartyTokenAmount * makerFeeBps) / 10000
Deducted from counterparty tokens received by maker
Paid to fee recipient in counterparty tokens
```

### Taker Fee
```
takerFee = (counterpartyTokenAmount * takerFeeBps) / 10000
Paid by taker in addition to counterparty token amount
```

### Example
- Order: 1000 BASE for 2000 USDC
- Maker fee: 0.25% = 5 USDC
- Taker fee: 0.5% = 10 USDC
- Maker receives: 1995 USDC
- Taker pays: 2010 USDC
- Fee recipient receives: 15 USDC total

## 🧪 Testing

See `CAST_COMMANDS.md` for detailed cast commands to test the contract.

## 📚 Documentation

Auto-generated API documentation from NatSpec comments is available in the `docs/` directory. Generate it with:

```bash
npm run docgen
```

Or generate and serve it locally (opens in browser automatically):

```bash
npm run docgen:serve
```

## 📄 License

MIT
