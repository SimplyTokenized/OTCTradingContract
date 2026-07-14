# Cast Commands for OTC Trading Contract

This document contains `cast` commands to interact with and test the OTC Trading contract.

> ⚠️ **The private keys in this document are the well-known, publicly published Anvil/Foundry
> development keys.** They are intended for **local testing only**. They control no real funds and
> must **never** be used on a public testnet or mainnet. On live networks, sign with a keystore
> account (`--account <name>`) or a hardware wallet — never paste a raw private key.
>
> **Interface note:** `createOrder` takes an `OrderType` as its first argument
> (`0` = BUY, `1` = SELL). All examples below use `1` (SELL) unless noted.

## Prerequisites

- Start a local Anvil node: `anvil` (runs on `http://localhost:8545`)
- Deploy the OTC contract first (see deployment section)
- Deploy the base ERC20 token and counterparty token (e.g., USDC)
- Set environment variables:
  ```bash
  export OTC_ADDRESS=<your_otc_contract_address>
  export BASE_TOKEN=<base_erc20_token_address>
  export COUNTERPARTY_TOKEN=<usdc_or_other_token_address>
  export RPC_URL=http://localhost:8545  # or your testnet RPC
  export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # Anvil default
  export ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266  # Anvil default account
  export USER1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8  # Anvil account 1
  export USER2=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC  # Anvil account 2
  ```

## Default Anvil Accounts (Local Testing)

- **Account 0 (Admin)**: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- **Account 1**: `0x70997970C51812dc3A010C7d01b50e0d17dc79C8`
- **Account 2**: `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC`
- **Private Key (Account 0)**: `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`

---

## 1. Contract Information (Read Operations)

### Get Base Token Address
```bash
cast call $OTC_ADDRESS "baseToken()(address)" --rpc-url $RPC_URL
```

### Get Fee Recipient
```bash
cast call $OTC_ADDRESS "feeRecipient()(address)" --rpc-url $RPC_URL
```

### Get Maker Fee (in basis points)
```bash
cast call $OTC_ADDRESS "makerFeeBps()(uint256)" --rpc-url $RPC_URL
```

### Get Taker Fee (in basis points)
```bash
cast call $OTC_ADDRESS "takerFeeBps()(uint256)" --rpc-url $RPC_URL
```

### Get Minimum Order Size
```bash
cast call $OTC_ADDRESS "minOrderSize()(uint256)" --rpc-url $RPC_URL
```

### Check if Whitelist is Required
```bash
cast call $OTC_ADDRESS "requireWhitelist()(bool)" --rpc-url $RPC_URL
```

### Check if Address is Whitelisted
```bash
cast call $OTC_ADDRESS "whitelist(address)(bool)" <ADDRESS> --rpc-url $RPC_URL
```

**Example:**
```bash
cast call $OTC_ADDRESS "whitelist(address)(bool)" $USER1 --rpc-url $RPC_URL
```

### Check if Counterparty Token is Allowed
```bash
cast call $OTC_ADDRESS "allowedCounterpartyTokens(address)(bool)" <TOKEN_ADDRESS> --rpc-url $RPC_URL
```

**Example:**
```bash
cast call $OTC_ADDRESS "allowedCounterpartyTokens(address)(bool)" $COUNTERPARTY_TOKEN --rpc-url $RPC_URL
```

### Get Next Order ID
```bash
cast call $OTC_ADDRESS "nextOrderId()(uint256)" --rpc-url $RPC_URL
```

### Check if Contract is Paused
```bash
cast call $OTC_ADDRESS "paused()(bool)" --rpc-url $RPC_URL
```

### Check ETH Escrowed for a BUY+ETH Order
```bash
cast call $OTC_ADDRESS "ethEscrowed(uint256)(uint256)" <ORDER_ID> --rpc-url $RPC_URL
```

### Check Claimable ETH (pending withdrawal) for an Address
```bash
cast call $OTC_ADDRESS "pendingWithdrawals(address)(uint256)" <ADDRESS> --rpc-url $RPC_URL
```

---

## 2. Order Operations

### Get Order Details
```bash
cast call $OTC_ADDRESS "getOrder(uint256)(uint256,address,uint8,address,uint256,uint256,uint256,bool,uint256,uint256,uint256,uint256)" <ORDER_ID> --rpc-url $RPC_URL
```

**Note:** The return values are: `(id, maker, orderType, counterpartyToken, baseTokenAmount, counterpartyTokenAmount, filledAmount, isActive, createdAt, expiresAt, makerFeeBps, takerFeeBps)` where `orderType` is `0` = BUY, `1` = SELL.

**Example:**
```bash
cast call $OTC_ADDRESS "getOrder(uint256)(uint256,address,uint8,address,uint256,uint256,uint256,bool,uint256,uint256,uint256,uint256)" 1 --rpc-url $RPC_URL
```

### Get Remaining Amount in Order
```bash
cast call $OTC_ADDRESS "getRemainingAmount(uint256)(uint256)" <ORDER_ID> --rpc-url $RPC_URL
```

**Example:**
```bash
cast call $OTC_ADDRESS "getRemainingAmount(uint256)(uint256)" 1 --rpc-url $RPC_URL
```

### Get User's Order IDs
```bash
cast call $OTC_ADDRESS "getUserOrders(address)(uint256[])" <USER_ADDRESS> --rpc-url $RPC_URL
```

**Example:**
```bash
cast call $OTC_ADDRESS "getUserOrders(address)(uint256[])" $USER1 --rpc-url $RPC_URL
```

### Check if an Order is Currently Fundable
```bash
# True if the maker's side is currently covered (allowance+balance, or ETH escrow).
# A false result does NOT deactivate the order — fundability is transient. Use this to filter the book.
cast call $OTC_ADDRESS "isOrderFundable(uint256)(bool)" <ORDER_ID> --rpc-url $RPC_URL
```

---

## 3. Trading Functions

### Create Order

> **Non-custodial:** approving grants an **allowance** — your tokens stay in your wallet until a
> taker fills. (Exception: a BUY order priced in ETH escrows `msg.value` at creation, since ETH
> can't be pulled later.) A SELL maker approves the base token; a BUY maker approves
> `counterpartyTokenAmount + makerFee` of the counterparty token.

First, approve the base token (SELL) — an allowance, not a transfer:
```bash
cast send $BASE_TOKEN "approve(address,uint256)" $OTC_ADDRESS <AMOUNT> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example:**
```bash
# Approve 1000 tokens (assuming 18 decimals)
cast send $BASE_TOKEN "approve(address,uint256)" $OTC_ADDRESS 1000000000000000000000 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

Then create the order (first argument is the order type: `0` = BUY, `1` = SELL):
```bash
cast send $OTC_ADDRESS "createOrder(uint8,address,uint256,uint256)" \
  <ORDER_TYPE> \
  <COUNTERPARTY_TOKEN> \
  <BASE_TOKEN_AMOUNT> \
  <COUNTERPARTY_TOKEN_AMOUNT> \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example (SELL):**
```bash
# SELL order: sell 1000 BASE tokens for 2000 USDC (assuming 6 decimals for USDC)
cast send $OTC_ADDRESS "createOrder(uint8,address,uint256,uint256)" \
  1 \
  $COUNTERPARTY_TOKEN \
  1000000000000000000000 \
  2000000000 \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example (BUY with ETH counterparty):**
```bash
# BUY order: buy 1000 BASE tokens for 2 ETH.
# The maker pre-funds the maker fee, so the ETH sent = price + maker fee.
# With the default 25 bps maker fee: 2 ETH + 0.005 ETH = 2.005 ETH.
# Requires ETH (address(0)) to be an allowed counterparty token.
cast send $OTC_ADDRESS "createOrder(uint8,address,uint256,uint256)" \
  0 \
  0x0000000000000000000000000000000000000000 \
  1000000000000000000000 \
  2000000000000000000 \
  --value 2005000000000000000 \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

> **Note for BUY orders (ERC-20 counterparty):** approve `counterpartyTokenAmount + makerFee`
> before calling `createOrder`, since the maker pre-funds the maker fee.

### Fill Order

First, approve counterparty tokens (including taker fee):
```bash
# Calculate: counterpartyAmount + takerFee
# takerFee = (counterpartyAmount * takerFeeBps) / 10000
cast send $COUNTERPARTY_TOKEN "approve(address,uint256)" $OTC_ADDRESS <TOTAL_AMOUNT> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example:**
```bash
# For 1000 USDC fill with 0.5% taker fee = 1005 USDC total
cast send $COUNTERPARTY_TOKEN "approve(address,uint256)" $OTC_ADDRESS 1005000000 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

Then fill the order:
```bash
cast send $OTC_ADDRESS "fillOrder(uint256,uint256)" \
  <ORDER_ID> \
  <BASE_TOKEN_FILL_AMOUNT> \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example:**
```bash
# Fill 500 BASE tokens from order 1
cast send $OTC_ADDRESS "fillOrder(uint256,uint256)" \
  1 \
  500000000000000000000 \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Cancel Order
```bash
cast send $OTC_ADDRESS "cancelOrder(uint256)" <ORDER_ID> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example:**
```bash
cast send $OTC_ADDRESS "cancelOrder(uint256)" 1 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Withdraw Accrued ETH (pull payment)
```bash
# Claim ETH owed to you: maker proceeds, escrow refunds, or (for the fee recipient) fees.
cast send $OTC_ADDRESS "withdraw()" --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Cleanup Expired Orders (permissionless)
```bash
# Anyone may deactivate expired orders; BUY+ETH escrow is credited back to each maker.
cast send $OTC_ADDRESS "cleanupExpiredOrders(uint256[])" "[1,2,3]" --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

---

## 4. Admin Functions

### Add Counterparty Token
```bash
cast send $OTC_ADDRESS "addCounterpartyToken(address)" <TOKEN_ADDRESS> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example:**
```bash
cast send $OTC_ADDRESS "addCounterpartyToken(address)" 0xNewTokenAddress --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Remove Counterparty Token
```bash
cast send $OTC_ADDRESS "removeCounterpartyToken(address)" <TOKEN_ADDRESS> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example:**
```bash
cast send $OTC_ADDRESS "removeCounterpartyToken(address)" $COUNTERPARTY_TOKEN --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Update Fees
```bash
cast send $OTC_ADDRESS "updateFees(uint256,uint256)" <MAKER_FEE_BPS> <TAKER_FEE_BPS> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example:**
```bash
# Set maker fee to 0.3% (30 bps) and taker fee to 0.6% (60 bps)
cast send $OTC_ADDRESS "updateFees(uint256,uint256)" 30 60 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Update Minimum Order Size
```bash
cast send $OTC_ADDRESS "updateMinOrderSize(uint256)" <MIN_ORDER_SIZE> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example:**
```bash
cast send $OTC_ADDRESS "updateMinOrderSize(uint256)" 200 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Update Whitelist Requirement
```bash
cast send $OTC_ADDRESS "updateWhitelistRequirement(bool)" <true_or_false> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example:**
```bash
# Disable whitelist requirement
cast send $OTC_ADDRESS "updateWhitelistRequirement(bool)" false --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# Enable whitelist requirement
cast send $OTC_ADDRESS "updateWhitelistRequirement(bool)" true --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Add to Whitelist
```bash
cast send $OTC_ADDRESS "addToWhitelist(address)" <ADDRESS> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example:**
```bash
cast send $OTC_ADDRESS "addToWhitelist(address)" $USER1 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Remove from Whitelist
```bash
cast send $OTC_ADDRESS "removeFromWhitelist(address)" <ADDRESS> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example:**
```bash
cast send $OTC_ADDRESS "removeFromWhitelist(address)" $USER1 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Update Fee Recipient
```bash
cast send $OTC_ADDRESS "updateFeeRecipient(address)" <NEW_FEE_RECIPIENT> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Example:**
```bash
cast send $OTC_ADDRESS "updateFeeRecipient(address)" 0xNewFeeRecipient --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Admin Force-Cancel an Order (compliance)
```bash
# Deactivates any active order (e.g. a de-whitelisted maker's). Non-custodial: any BUY+ETH escrow
# is credited back to the MAKER, never to the admin. Emits OrderAdminCancelled.
cast send $OTC_ADDRESS "adminCancelOrder(uint256)" <ORDER_ID> --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# Batch variant:
cast send $OTC_ADDRESS "adminCancelOrders(uint256[])" "[1,2,3]" --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Pause Trading
```bash
cast send $OTC_ADDRESS "pause()" --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### Unpause Trading
```bash
cast send $OTC_ADDRESS "unpause()" --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

---

## 5. Role Management

### Check if Address has DEFAULT_ADMIN_ROLE
```bash
# DEFAULT_ADMIN_ROLE is 0x0000000000000000000000000000000000000000000000000000000000000000
cast call $OTC_ADDRESS "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  <ADDRESS> \
  --rpc-url $RPC_URL
```

### Check if Address has ADMIN_ROLE
```bash
ADMIN_ROLE=$(cast keccak "ADMIN_ROLE")
cast call $OTC_ADDRESS "hasRole(bytes32,address)(bool)" $ADMIN_ROLE <ADDRESS> --rpc-url $RPC_URL
```

### Check if Address has UPGRADER_ROLE
```bash
UPGRADER_ROLE=$(cast keccak "UPGRADER_ROLE")
cast call $OTC_ADDRESS "hasRole(bytes32,address)(bool)" $UPGRADER_ROLE <ADDRESS> --rpc-url $RPC_URL
```

---

## 6. Complete Testing Workflow

Here's a complete workflow to test all functionality:

```bash
# 1. Set variables
export OTC_ADDRESS=<your_deployed_otc_address>
export BASE_TOKEN=<base_token_address>
export COUNTERPARTY_TOKEN=<usdc_address>
export RPC_URL=http://localhost:8545
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export USER1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
export USER1_KEY=0x59c6995e998f97a5a0044966f0945389ac9e75b579d0e2e7e5b1e7b2e2b2e2b2

# 2. Check contract info
cast call $OTC_ADDRESS "baseToken()(address)" --rpc-url $RPC_URL
cast call $OTC_ADDRESS "makerFeeBps()(uint256)" --rpc-url $RPC_URL
cast call $OTC_ADDRESS "takerFeeBps()(uint256)" --rpc-url $RPC_URL
cast call $OTC_ADDRESS "minOrderSize()(uint256)" --rpc-url $RPC_URL

# 3. Add user to whitelist
cast send $OTC_ADDRESS "addToWhitelist(address)" $USER1 --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# 4. Check if user is whitelisted
cast call $OTC_ADDRESS "whitelist(address)(bool)" $USER1 --rpc-url $RPC_URL

# 5. Check counterparty token
cast call $OTC_ADDRESS "allowedCounterpartyTokens(address)(bool)" $COUNTERPARTY_TOKEN --rpc-url $RPC_URL

# 6. Create order (as USER1)
# First approve base tokens
cast send $BASE_TOKEN "approve(address,uint256)" $OTC_ADDRESS 1000000000000000000000 \
  --private-key $USER1_KEY --rpc-url $RPC_URL

# Create SELL order: sell 1000 BASE for 2000 USDC (order type 1 = SELL)
cast send $OTC_ADDRESS "createOrder(uint8,address,uint256,uint256)" \
  1 \
  $COUNTERPARTY_TOKEN \
  1000000000000000000000 \
  2000000000 \
  --private-key $USER1_KEY --rpc-url $RPC_URL

# 7. Get order details
cast call $OTC_ADDRESS "getOrder(uint256)(uint256,address,uint8,address,uint256,uint256,uint256,bool,uint256,uint256,uint256,uint256)" \
  1 --rpc-url $RPC_URL

# 8. Fill order (as ADMIN)
# First approve counterparty tokens (1000 USDC + 5 USDC fee = 1005 USDC)
cast send $COUNTERPARTY_TOKEN "approve(address,uint256)" $OTC_ADDRESS 1005000000 \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# Fill 500 BASE tokens
cast send $OTC_ADDRESS "fillOrder(uint256,uint256)" \
  1 \
  500000000000000000000 \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# 9. Check remaining amount
cast call $OTC_ADDRESS "getRemainingAmount(uint256)(uint256)" 1 --rpc-url $RPC_URL

# 10. Cancel remaining order (as USER1)
cast send $OTC_ADDRESS "cancelOrder(uint256)" 1 --private-key $USER1_KEY --rpc-url $RPC_URL

# 11. Check balances
cast call $BASE_TOKEN "balanceOf(address)(uint256)" $USER1 --rpc-url $RPC_URL
cast call $BASE_TOKEN "balanceOf(address)(uint256)" $ADMIN --rpc-url $RPC_URL
cast call $COUNTERPARTY_TOKEN "balanceOf(address)(uint256)" $USER1 --rpc-url $RPC_URL
cast call $COUNTERPARTY_TOKEN "balanceOf(address)(uint256)" $ADMIN --rpc-url $RPC_URL
```

---

## 7. Helper Scripts

### Get all role hashes
```bash
echo "DEFAULT_ADMIN_ROLE: 0x0000000000000000000000000000000000000000000000000000000000000000"
echo "ADMIN_ROLE: $(cast keccak "ADMIN_ROLE")"
echo "UPGRADER_ROLE: $(cast keccak "UPGRADER_ROLE")"
```

### Calculate fees
```bash
# Calculate maker fee (0.25% = 25 bps)
# makerFee = (amount * 25) / 10000
BASE_AMOUNT=1000000000000000000000  # 1000 tokens
MAKER_FEE_BPS=25
MAKER_FEE=$(cast --to-uint256 $((BASE_AMOUNT * MAKER_FEE_BPS / 10000)))
echo "Maker fee: $MAKER_FEE"

# Calculate taker fee (0.5% = 50 bps)
COUNTERPARTY_AMOUNT=2000000000  # 2000 USDC
TAKER_FEE_BPS=50
TAKER_FEE=$(cast --to-uint256 $((COUNTERPARTY_AMOUNT * TAKER_FEE_BPS / 10000)))
echo "Taker fee: $TAKER_FEE"
```

### Convert amounts
```bash
# Convert 1 token to wei (18 decimals)
cast --to-wei 1 ether

# Convert wei to tokens
cast --from-wei <amount_in_wei> ether

# For USDC (6 decimals): 1 USDC = 1000000
cast --to-uint256 1000000
```

### Get current block number
```bash
cast block-number --rpc-url $RPC_URL
```

### Get account balance (ETH)
```bash
cast balance <ADDRESS> --rpc-url $RPC_URL
```

---

## 8. Event Monitoring

### Monitor OrderCreated events
```bash
cast logs --from-block 0 "OrderCreated(uint256,address,uint8,address,uint256,uint256)" --rpc-url $RPC_URL
```

### Monitor OrderFilled events
```bash
cast logs --from-block 0 "OrderFilled(uint256,address,uint256,uint256,uint256,uint256)" --rpc-url $RPC_URL
```

### Monitor OrderCancelled events
```bash
cast logs --from-block 0 "OrderCancelled(uint256,address)" --rpc-url $RPC_URL
```

---

## Notes

- All amounts are in the token's smallest unit (wei equivalent)
- For tokens with 18 decimals: 1 token = 1000000000000000000 wei
- For USDC (6 decimals): 1 USDC = 1000000
- Always approve tokens before creating or filling orders
- Order type is the first `createOrder` argument: `0` = BUY, `1` = SELL
- **Non-custodial:** makers grant an allowance and keep custody; nothing is escrowed except a BUY order priced in ETH (which sends `counterpartyAmount + makerFee` as `msg.value`)
- **SELL orders:** the taker pays `counterpartyAmount + takerFee`; the maker receives `counterpartyAmount − makerFee`
- **BUY orders:** the maker provides `counterpartyAmount + makerFee` (allowance, or ETH escrow); the taker (seller) receives `counterpartyAmount − takerFee`
- The order creator (maker) always bears the maker fee; the filler (taker) always bears the taker fee
- **ETH payouts are pull-based:** maker proceeds, escrow refunds, and fees accrue as `pendingWithdrawals` and are claimed with `withdraw()`; only the taker is paid inline
- Fee rates are snapshotted per order at creation and are not affected by later `updateFees` calls
- Orders can be filled partially or fully
- Only the order maker can cancel their own order; `ADMIN_ROLE` can force-cancel (escrow returns to the maker); anyone can `cleanupExpiredOrders`
- When using testnet, replace `$RPC_URL` with your testnet RPC URL and use appropriate private keys
- Always verify you have the required role before attempting admin operations
