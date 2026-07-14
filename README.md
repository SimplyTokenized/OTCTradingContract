# OTC Trading Contract

An upgradeable on-chain **Over-The-Counter (OTC)** trading contract for ERC-20 tokens. Makers post fixed-price BUY or SELL orders; takers fill them partially or fully. The contract supports configurable maker/taker fees, an optional trading whitelist, multiple counterparty tokens (including native ETH), and order expiration.

> **Status:** Pre-production. This code has undergone an internal security review (see [Security](#-security)) but **has not been audited by an independent third party**. Do not deploy to mainnet with real funds until an external audit has been completed. See [DISCLAIMER](#-disclaimer).

---

## Table of Contents

- [Features](#-features)
- [Architecture](#-architecture)
- [Trading Parameters](#-trading-parameters)
- [Order Model](#-order-model)
- [Fee Model](#-fee-model)
- [Roles & Trust Model](#-roles--trust-model)
- [Quick Start](#-quick-start)
- [Deployment](#-deployment)
- [Contract API](#-contract-api)
- [Security](#-security)
- [Documentation](#-documentation)
- [Disclaimer](#-disclaimer)
- [License](#-license)

---

## ✨ Features

- **Upgradeable** — OpenZeppelin transparent proxy pattern (UUPS-free, `ProxyAdmin`-controlled).
- **BUY and SELL orders** — makers can bid for the base token or offer it for sale.
- **Multiple counterparty tokens** — any admin-approved ERC-20, plus native **ETH** (`address(0)`).
- **Configurable fees** — independent maker and taker fees in basis points, capped at 10% each. Fee rates are **snapshotted per order** at creation, so later fee changes never apply retroactively.
- **Optional whitelist** — restrict trading to approved addresses.
- **Order expiration** — optional per-deployment default expiry.
- **Partial fills** — orders can be filled incrementally.
- **Pausable** — admin can halt trading.
- **Role-based access control** — separate admin and fee-recipient roles.
- **Reentrancy-protected** — all state-changing external functions use `nonReentrant`, and settlement uses `SafeERC20`.

> ⚠️ **Fee-on-transfer / rebasing tokens are not supported.** The accounting assumes the contract receives exactly the amount transferred. Do not approve such tokens as base or counterparty tokens.

## 🏗️ Architecture

The system is deployed behind an OpenZeppelin **transparent proxy**:

| Component | Responsibility |
|-----------|----------------|
| **Proxy** | The stable address users interact with; holds all state. |
| **Implementation** (`OTCTrading`) | Trading logic; contains no persistent state of its own. |
| **ProxyAdmin** | A separate contract that performs upgrades. Its **owner** is the `ADMIN` address supplied at deploy time. |

Upgrades are authorized by the **ProxyAdmin owner** — this is independent from the contract's internal `AccessControl` roles. See [Roles & Trust Model](#-roles--trust-model).

Solidity `0.8.27`, built with [Foundry](https://book.getfoundry.sh/), `via-IR` enabled, OpenZeppelin Contracts v5.

## 📋 Trading Parameters

Deploy-time defaults (configurable in [`script/DeployOTC.s.sol`](script/DeployOTC.s.sol)):

| Parameter | Default | Description |
|-----------|---------|-------------|
| Maker fee | 25 bps (0.25%) | Charged on the counterparty amount. Max 1000 bps. |
| Taker fee | 50 bps (0.50%) | Charged on the counterparty amount. Max 1000 bps. |
| Minimum order size | 100 | Minimum base-token amount per order (must be > 0). |
| Maximum order size | 0 | Upper bound on base-token amount (`0` = no limit). |
| Default order expiration | 0 | Seconds until orders expire (`0` = never). |
| Require whitelist | true | Whether traders must be whitelisted. |

## 📦 Order Model

An order is created with an explicit **type**:

- **`SELL` (enum value `1`)** — the maker deposits `baseTokenAmount` of the base token and wants counterparty tokens in return. The taker supplies the counterparty token and receives base tokens.
- **`BUY` (enum value `0`)** — the maker deposits `counterpartyTokenAmount` of the counterparty token (or ETH) and wants base tokens. The taker supplies base tokens and receives the counterparty token.

The price is fixed at creation as the ratio `counterpartyTokenAmount / baseTokenAmount`. Fills are settled proportionally and any dust that rounds the counterparty amount to zero is rejected.

## 💰 Fee Model

Both fees are computed on the **counterparty amount** of each fill, using the rates **snapshotted into the order at creation**.

**SELL order** (taker pays the fee on top; maker pays it out of proceeds):

```
taker pays        = counterpartyAmount + takerFee
maker receives    = counterpartyAmount − makerFee
fee recipient     = makerFee + takerFee
```

**BUY order** (both fees are drawn from the maker's deposited pot, keeping the contract solvent):

```
maker deposited   = counterpartyAmount
taker receives    = counterpartyAmount − makerFee − takerFee
fee recipient     = makerFee + takerFee
```

**Worked example — SELL 1000 BASE for 2000 USDC, fully filled (25/50 bps):**

| Party | Amount |
|-------|--------|
| Taker pays | 2010 USDC |
| Maker receives | 1995 USDC |
| Fee recipient | 15 USDC |

## 🔐 Roles & Trust Model

| Role | Powers |
|------|--------|
| **ProxyAdmin owner** | Upgrade the implementation contract. Set to the `ADMIN` address at deploy. |
| `DEFAULT_ADMIN_ROLE` | Grant/revoke roles. |
| `ADMIN_ROLE` | Manage fees, order limits, whitelist, counterparty tokens, pause/unpause, cleanup, and **emergency withdrawal**. |
| `FEE_RECIPIENT_ROLE` | Informational marker for the configured fee recipient. |

> **⚠️ Centralization notice.** An `ADMIN_ROLE` holder can pause trading and, **while the contract is paused**, call `emergencyWithdraw` to move any token or ETH out of the contract — including funds backing open orders. The ProxyAdmin owner can additionally replace the entire implementation. **These are powerful, trust-critical capabilities.**
>
> For production you should:
> - Assign the ProxyAdmin owner and `DEFAULT_ADMIN_ROLE`/`ADMIN_ROLE` to a **multisig** and/or a **timelock**, not a single EOA. The default deploy script assigns all of them to one `ADMIN` address — change this before mainnet.
> - Publish the custody arrangement so users can assess counterparty risk.

## 🚀 Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)
- Node.js ≥ 18 (only for the npm convenience scripts)

### Install

```bash
git clone https://github.com/SimplyTokenized/OTCTradingContract.git
cd OTCTradingContract
forge install        # pulls submodules in lib/
```

### Build & test

```bash
forge build
forge test            # 89 tests
forge test --gas-report
forge coverage        # optional
```

### Configure

Copy the template and fill in real addresses:

```bash
cp .env.example .env
# then edit .env
```

`.env` is git-ignored and must never be committed. Never place private keys in `.env` for public networks — pass them via `--account`/keystore or a hardware signer at deploy time.

## 📤 Deployment

The deploy script reads `BASE_TOKEN`, `DEFAULT_COUNTERPARTY_TOKEN`, `FEE_RECIPIENT`, and `ADMIN` from the environment and deploys the implementation, a `ProxyAdmin`, and the transparent proxy, initializing it atomically.

```bash
# Local (Anvil) — uses the well-known public Anvil key, LOCAL USE ONLY
npm run deploy:local

# Testnet (recommended: sign with a keystore account, not a raw key)
forge script script/DeployOTC.s.sol:DeployOTC \
  --rpc-url "$TESTNET_RPC" \
  --account deployer \
  --sender "$DEPLOYER" \
  --broadcast --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
```

After deploying, **use the proxy address** for all interactions. See [`CAST_COMMANDS.md`](CAST_COMMANDS.md) for ready-to-use `cast` snippets.

### Deployed addresses

| Network | Proxy | Implementation | ProxyAdmin |
|---------|-------|----------------|------------|
| _TBD_ | _TBD_ | _TBD_ | _TBD_ |

## 📖 Contract API

### Trading

| Function | Description |
|----------|-------------|
| `createOrder(OrderType orderType, address counterpartyToken, uint256 baseTokenAmount, uint256 counterpartyTokenAmount)` `payable` → `uint256 orderId` | Create a BUY or SELL order. For a SELL, the base token is pulled from the maker. For a BUY, the counterparty token is pulled (or ETH must be sent as `msg.value`). |
| `fillOrder(uint256 orderId, uint256 baseTokenAmount)` `payable` | Fill an order partially or fully. |
| `cancelOrder(uint256 orderId)` | Cancel your own order and reclaim the unfilled remainder. |
| `batchCancelOrders(uint256[] orderIds)` | Cancel multiple of your own orders. |

### Admin (`ADMIN_ROLE`)

`addCounterpartyToken` · `removeCounterpartyToken` · `updateFees` · `updateFeeRecipient` · `updateMinOrderSize` · `updateMaxOrderSize` · `updateDefaultOrderExpiration` · `updateWhitelistRequirement` · `addToWhitelist` · `removeFromWhitelist` · `batchAddToWhitelist` · `batchRemoveFromWhitelist` · `cleanupExpiredOrders` · `pause` · `unpause` · `emergencyWithdraw` *(only while paused)*

### Views

`getOrder` · `getUserOrders` · `getRemainingAmount` · `isOrderExpired` · `getActiveOrders(offset, limit)` · `getOrdersByToken(token, offset, limit)` · plus the public getters `orders`, `nextOrderId`, `makerFeeBps`, `takerFeeBps`, `minOrderSize`, `maxOrderSize`, `requireWhitelist`, `defaultOrderExpiration`, `baseToken`, `feeRecipient`, `allowedCounterpartyTokens`, `whitelist`.

### Events

`OrderCreated` · `OrderFilled` · `OrderCancelled` · `CounterpartyTokenAdded` · `CounterpartyTokenRemoved` · `WhitelistAdded` · `WhitelistRemoved` · `FeesUpdated` · `MinOrderSizeUpdated` · `MaxOrderSizeUpdated` · `DefaultOrderExpirationUpdated` · `WhitelistRequirementUpdated` · `FeeRecipientUpdated` · `OrdersCleanedUp` · `EmergencyWithdrawal`

Full NatSpec-generated reference: `npm run docgen` (see [Documentation](#-documentation)).

### Upgrading

```solidity
// Executed by the ProxyAdmin owner
Upgrades.upgradeProxy(proxyAddress, "OTCTradingV2.sol", "");
```

Run `Upgrades.validateUpgrade` (or `forge` with the OpenZeppelin upgrades plugin) before every upgrade to catch storage-layout incompatibilities.

## 🛡️ Security

- All trading entry points are `nonReentrant`; token transfers use `SafeERC20`; ETH transfers use checked low-level calls.
- Fee rates are snapshotted per order and cannot be changed retroactively.
- Fills that round the counterparty amount to zero are rejected.
- `emergencyWithdraw` is gated behind `whenPaused`, so any withdrawal is preceded by a visible on-chain pause.

An internal review and its remediations are documented alongside this repository. **No independent external audit has been performed yet** — commission one before mainnet deployment.

To report a vulnerability, follow [SECURITY.md](SECURITY.md). Please do not open public issues for security reports.

## 📚 Documentation

Generate the NatSpec API reference locally:

```bash
npm run docgen         # writes to docs/
npm run docgen:serve   # build and serve, opens in browser
```

The `docs/` output is generated and git-ignored.

## ⚖️ Disclaimer

This software is provided "as is", without warranty of any kind. It has not been audited by an independent third party. Deploying or interacting with these contracts is at your own risk, and the authors accept no liability for any loss of funds. Nothing here is financial, legal, or investment advice.

## 📄 License

[MIT](LICENSE) © SimplyTokenized
