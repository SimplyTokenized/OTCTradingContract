# `cast` command reference

Every call against an OTCTrading v2 deployment, as `cast` one-liners. v1's commands are gone: almost
all of them took a contract-wide setting that is now a property of an **offering**, so nearly every
command here carries an `offeringId`.

## Setup

```bash
export OTC=0x...                  # the proxy — always the proxy, never the implementation
export RPC=$ETH_SEPOLIA_RPC
export ACCOUNT=my-keystore-account   # cast wallet; never a raw key on a public network
```

Read-only calls use `cast call`; anything that changes state uses `cast send`. Every `cast send`
below assumes `--rpc-url $RPC --account $ACCOUNT`.

---

## Offerings

### List an offering

`createOffering` takes one struct. The tuple order is:
`(baseToken, feeRecipient, eligibilityRegistry, makerFeeBps, takerFeeBps, defaultOrderExpiration, minOrderSize, maxOrderSize, offeringRef, counterpartyTokens[])`

```bash
cast send $OTC \
  "createOffering((address,address,address,uint16,uint16,uint48,uint256,uint256,bytes32,address[]))" \
  "($BASE_TOKEN,$FEE_RECIPIENT,$REGISTRY,25,50,2592000,1000000000000000000,0,$(cast keccak "FUND-2026-A"),[$USDC,0x0000000000000000000000000000000000000000])" \
  --rpc-url $RPC --account $ACCOUNT
```

`address(0)` in `counterpartyTokens` enables native-ETH pricing. `$REGISTRY` may be `0x0` for an
ungated offering. The returned id is in the `OfferingCreated` event.

### Read one

```bash
cast call $OTC "getOffering(uint256)" 1 --rpc-url $RPC
cast call $OTC "offeringCounterpartyTokens(uint256,address)" 1 $USDC --rpc-url $RPC
cast call $OTC "nextOfferingId()" --rpc-url $RPC     # ids run 1 … nextOfferingId-1
```

### Settlement assets

```bash
cast send $OTC "allowCounterpartyToken(uint256,address)"    1 $USDC --rpc-url $RPC --account $ACCOUNT
cast send $OTC "allowCounterpartyToken(uint256,address)"    1 0x0000000000000000000000000000000000000000 --rpc-url $RPC --account $ACCOUNT
cast send $OTC "disallowCounterpartyToken(uint256,address)" 1 $USDC --rpc-url $RPC --account $ACCOUNT
```

De-listing stops **new** orders. Orders already resting in that asset stay fillable — clear them
with `adminCancelOrders` if that is what you meant.

### Economics and limits

```bash
# ADMIN_ROLE. Max 1000 bps (10%) either side. Never retroactive: resting orders keep their rates.
cast send $OTC "setOfferingFees(uint256,uint16,uint16)" 1 25 50 --rpc-url $RPC --account $ACCOUNT

# OPERATOR_ROLE. maxOrderSize 0 = no ceiling; expiry 0 = orders never expire.
cast send $OTC "setOfferingLimits(uint256,uint256,uint256,uint48)" 1 1000000000000000000 0 2592000 \
  --rpc-url $RPC --account $ACCOUNT
```

### Halt one offering

```bash
cast send $OTC "setOfferingPaused(uint256,bool)" 1 true  --rpc-url $RPC --account $ACCOUNT
cast send $OTC "setOfferingPaused(uint256,bool)" 1 false --rpc-url $RPC --account $ACCOUNT
```

Cancelling and withdrawing keep working while an offering is paused.

---

## Trading

### Place an order

```bash
# SELL 1000 base for 50,000 USDC — approve first; nothing is deposited.
cast send $BASE_TOKEN "approve(address,uint256)" $OTC 1000000000000000000000 --rpc-url $RPC --account $ACCOUNT
cast send $OTC "createOrder(uint256,uint8,address,uint256,uint256)" \
  1 1 $USDC 1000000000000000000000 50000000000 --rpc-url $RPC --account $ACCOUNT

# BUY 1000 base for 50,000 USDC — approve price + maker fee.
cast send $USDC "approve(address,uint256)" $OTC 50125000000 --rpc-url $RPC --account $ACCOUNT
cast send $OTC "createOrder(uint256,uint8,address,uint256,uint256)" \
  1 0 $USDC 1000000000000000000000 50000000000 --rpc-url $RPC --account $ACCOUNT

# BUY priced in ETH — the ONE escrowed case: send price + maker fee as value.
cast send $OTC "createOrder(uint256,uint8,address,uint256,uint256)" \
  1 0 0x0000000000000000000000000000000000000000 1000000000000000000000 10000000000000000000 \
  --value 10025000000000000000 --rpc-url $RPC --account $ACCOUNT
```

`orderType`: `0` = BUY, `1` = SELL.

### Quote before you fill

```bash
# returns (counterpartyAmount, makerFee, takerFee, takerNet, makerNet)
# SELL: takerNet is what the taker pays, makerNet what the maker receives.
# BUY:  takerNet is what the taker receives, makerNet what the maker pays.
cast call $OTC "quoteFill(uint256,uint256)" 1 400000000000000000000 --rpc-url $RPC
```

### Fill

```bash
# ERC-20-priced: approve takerNet, then fill. A partial fill must be at least the offering's
# minOrderSize unless it takes the remainder.
cast send $USDC "approve(address,uint256)" $OTC 20100000000 --rpc-url $RPC --account $ACCOUNT
cast send $OTC "fillOrder(uint256,uint256)" 1 400000000000000000000 --rpc-url $RPC --account $ACCOUNT

# Filling a SELL priced in ETH: send takerNet as value. Excess comes straight back.
cast send $OTC "fillOrder(uint256,uint256)" 1 400000000000000000000 \
  --value 4020000000000000000 --rpc-url $RPC --account $ACCOUNT
```

### Cancel and clean up

```bash
cast send $OTC "cancelOrder(uint256)"        1 --rpc-url $RPC --account $ACCOUNT
cast send $OTC "batchCancelOrders(uint256[])" "[1,2,3]" --rpc-url $RPC --account $ACCOUNT

# Permissionless. Escrow goes back to the MAKER, never the caller. Max 200 ids.
cast send $OTC "cleanupExpiredOrders(uint256[])" "[7,8,9]" --rpc-url $RPC --account $ACCOUNT
```

### Claim your ETH

```bash
cast call $OTC "pendingWithdrawals(address)" $ME --rpc-url $RPC
cast send $OTC "withdraw()" --rpc-url $RPC --account $ACCOUNT
```

Maker proceeds, escrow refunds and fees are all claimed this way. Never pausable, never gated.

---

## Reading the book

```bash
cast call $OTC "getOrder(uint256)" 1 --rpc-url $RPC
cast call $OTC "getRemainingAmount(uint256)" 1 --rpc-url $RPC
cast call $OTC "isOrderFundable(uint256)" 1 --rpc-url $RPC
cast call $OTC "isOrderExpired(uint256)" 1 --rpc-url $RPC
cast call $OTC "orderBaseToken(uint256)" 1 --rpc-url $RPC

# One page of an offering's ids → (uint256[] ids, uint256 total)
cast call $OTC "getOfferingOrders(uint256,uint256,uint256)" 1 0 100 --rpc-url $RPC
cast call $OTC "getMakerOrders(address,uint256,uint256)" $ME 0 100 --rpc-url $RPC
cast call $OTC "offeringOrderCount(uint256)" 1 --rpc-url $RPC

# Live orders, in caller-bounded windows → (uint256[] ids, uint256 nextCursor).
# Keep calling with the cursor it returns until it reaches offeringOrderCount.
cast call $OTC "scanActiveOrders(uint256,uint256,uint256)" 1 0 200 --rpc-url $RPC
```

---

## Compliance

```bash
cast call $OTC "isEligibleToTrade(uint256,address)" 1 $WHO --rpc-url $RPC

# WhitelistRegistry (the companion contract), owner-only:
cast send $REGISTRY "add(address)"          $WHO --rpc-url $RPC --account $ACCOUNT
cast send $REGISTRY "remove(address)"       $WHO --rpc-url $RPC --account $ACCOUNT
cast send $REGISTRY "addBatch(address[])"   "[$A,$B]" --rpc-url $RPC --account $ACCOUNT
cast call $REGISTRY "isWhitelisted(address)" $WHO --rpc-url $RPC
```

An offering's registry cannot be changed after it is listed — there is no setter. To move an
instrument to a different gate, list a new offering.

### Force an order off the book (compliance)

```bash
cast send $OTC "adminCancelOrder(uint256)"    42 --rpc-url $RPC --account $ACCOUNT
cast send $OTC "adminCancelOrders(uint256[])" "[42,43]" --rpc-url $RPC --account $ACCOUNT
```

Escrow returns to the **maker**. The distinct `OrderAdminCancelled` event keeps it auditable.

---

## Four-eyes actions

Each needs a proposal by the owning role and an approval from a **different** APPROVER. Proposals
lapse after 7 days.

```bash
# Redirect an offering's fees
cast send $OTC "proposeSetOfferingFeeRecipient(uint256,address)" 1 $NEW --rpc-url $RPC --account $ADMIN_ACCOUNT
cast send $OTC "approveSetOfferingFeeRecipient(uint256,address)" 1 $NEW --rpc-url $RPC --account $APPROVER_ACCOUNT

# Close an offering for good — pause it first, and its book must be empty
cast send $OTC "setOfferingPaused(uint256,bool)" 1 true --rpc-url $RPC --account $ACCOUNT
cast send $OTC "proposeCloseOffering(uint256)" 1 --rpc-url $RPC --account $ADMIN_ACCOUNT
cast send $OTC "approveCloseOffering(uint256)" 1 --rpc-url $RPC --account $APPROVER_ACCOUNT

# Turn ERC-2771 relaying on (an address) or off (0x0)
cast send $OTC "proposeSetTrustedForwarder(address)" $FWD --rpc-url $RPC --account $ADMIN_ACCOUNT
cast send $OTC "approveSetTrustedForwarder(address)" $FWD --rpc-url $RPC --account $APPROVER_ACCOUNT

# Rescue stray assets (0x0 = ETH). Cannot touch escrow or pending withdrawals.
cast call $OTC "rescuableAmount(address)" 0x0000000000000000000000000000000000000000 --rpc-url $RPC
cast send $OTC "proposeRescueAssets(address,address,uint256)" $TOKEN $TO $AMT --rpc-url $RPC --account $ADMIN_ACCOUNT
cast send $OTC "approveRescueAssets(address,address,uint256)" $TOKEN $TO $AMT --rpc-url $RPC --account $APPROVER_ACCOUNT

# Inspect or withdraw a pending proposal
cast call $OTC "offeringFeeRecipientProposalId(uint256,address)" 1 $NEW --rpc-url $RPC
cast call $OTC "proposals(bytes32)" $PROPOSAL_ID --rpc-url $RPC
cast send $OTC "cancelProposal(bytes32)" $PROPOSAL_ID --rpc-url $RPC --account $ACCOUNT
```

---

## Roles

Granting waits 2 days. Revoking does not.

```bash
export ADMIN_ROLE=$(cast call $OTC "ADMIN_ROLE()" --rpc-url $RPC)
export OPERATOR_ROLE=$(cast call $OTC "OPERATOR_ROLE()" --rpc-url $RPC)
export APPROVER_ROLE=$(cast call $OTC "APPROVER_ROLE()" --rpc-url $RPC)
export UPGRADER_ROLE=$(cast call $OTC "UPGRADER_ROLE()" --rpc-url $RPC)

cast send $OTC "scheduleRoleGrant(bytes32,address)" $OPERATOR_ROLE $WHO --rpc-url $RPC --account $ACCOUNT
cast call $OTC "roleGrantWindow(bytes32,address)"   $OPERATOR_ROLE $WHO --rpc-url $RPC   # (effectiveFrom, expiresAt)

# …two days later, and within 7 days of that:
cast send $OTC "grantRole(bytes32,address)" $OPERATOR_ROLE $WHO --rpc-url $RPC --account $ACCOUNT

# Veto a pending grant (the role's admin, or an ADMIN_ROLE guardian)
cast send $OTC "cancelRoleGrant(bytes32,address)" $OPERATOR_ROLE $WHO --rpc-url $RPC --account $ACCOUNT

# Immediate, by design
cast send $OTC "revokeRole(bytes32,address)" $OPERATOR_ROLE $WHO --rpc-url $RPC --account $ACCOUNT
```

---

## Venue-wide

```bash
cast send $OTC "pause()"   --rpc-url $RPC --account $ADMIN_ACCOUNT
cast send $OTC "unpause()" --rpc-url $RPC --account $ADMIN_ACCOUNT

# Reserve accounting — what the venue holds and what it owes
cast call $OTC "totalEthEscrowed()" --rpc-url $RPC
cast call $OTC "totalPendingWithdrawals()" --rpc-url $RPC
cast balance $OTC --rpc-url $RPC
```

The balance must always be at least the sum of the two.

---

## Events worth indexing

```bash
cast logs --address $OTC "OrderCreated(uint256,uint256,address,uint8,address,uint256,uint256,uint48)" --rpc-url $RPC
cast logs --address $OTC "OrderFilled(uint256,uint256,address,uint256,uint256,uint256,uint256)" --rpc-url $RPC
cast logs --address $OTC "OfferingCreated(uint256,address,bytes32,address,address)" --rpc-url $RPC
cast logs --address $OTC "ActionProposed(bytes32,uint8,address)" --rpc-url $RPC
cast logs --address $OTC "OrderCleanedUp(uint256,uint256,address)" --rpc-url $RPC
```

`OrderCreated` and `OrderFilled` both index `offeringId`, so a per-offering feed is one filter.
