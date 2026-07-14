# OTC Trading Contract

An upgradeable, **non-custodial** on-chain **Over-The-Counter (OTC)** trading contract for ERC-20 tokens. Makers post fixed-price BUY or SELL orders backed by an **allowance** (they keep custody in their own wallet); takers fill them partially or fully and both legs settle atomically. The contract supports configurable maker/taker fees, an optional trading whitelist, multiple counterparty tokens (including native ETH), and order expiration.

> **Status:** Pre-production. This code has undergone an internal security review (see [AUDIT.md](AUDIT.md) and [Security](#-security)) but **has not been audited by an independent third party**. Do not deploy to mainnet with real funds until an external audit has been completed. See [DISCLAIMER](#-disclaimer).

---

## Table of Contents

- [Features](#-features)
- [Architecture](#-architecture)
- [Custody Model](#-custody-model)
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

- **Non-custodial** — makers grant an allowance instead of depositing; the contract never holds ERC-20 funds. Both settlement legs move directly between maker and taker at fill time. (One exception: a BUY order priced in native ETH escrows — see [Custody Model](#-custody-model).)
- **Upgradeable** — OpenZeppelin **UUPS** proxy; upgrades are authorized by `UPGRADER_ROLE` on the implementation.
- **BUY and SELL orders** — makers can bid for the base token or offer it for sale.
- **Multiple counterparty tokens** — any admin-approved ERC-20, plus native **ETH** (`address(0)`).
- **Configurable fees** — independent maker and taker fees in basis points, capped at 10% each. Fee rates are **snapshotted per order** at creation, so later fee changes never apply retroactively.
- **Optional whitelist** — restrict trading to approved addresses; a de-whitelisted maker's resting orders stop settling.
- **Order expiration** — optional per-deployment default expiry, with permissionless cleanup.
- **Partial fills** — orders can be filled incrementally.
- **Pausable** — admin can halt order creation and fills.
- **Pull-payment ETH** — ETH owed to resting parties is credited and claimed via `withdraw()`, so a party that can't receive ETH can never block settlement.
- **Reentrancy-protected** — all fund-moving external functions use `nonReentrant` via OpenZeppelin's [`ReentrancyGuardTransient`](https://docs.openzeppelin.com/contracts/5.x/api/utils#ReentrancyGuardTransient) (EIP-1153 transient storage, zero persistent storage), and settlement uses `SafeERC20`.

> ⚠️ **Fee-on-transfer / rebasing tokens are not supported.** The accounting assumes the exact amount transferred is the amount received. Do not approve such tokens as base or counterparty tokens.

## 🏗️ Architecture

The system is deployed behind an OpenZeppelin **UUPS proxy**:

| Component | Responsibility |
|-----------|----------------|
| **Proxy** (ERC-1967) | The stable address users interact with; holds all state. |
| **Implementation** (`OTCTrading`) | Trading logic **and** the upgrade authorization (`_authorizeUpgrade`); contains no persistent state of its own. |

Upgrades are authorized in-contract by `UPGRADER_ROLE` (part of the same `AccessControl` system as `ADMIN_ROLE`), not by a separate `ProxyAdmin`. See [Roles & Trust Model](#-roles--trust-model).

Solidity `0.8.27`, built with [Foundry](https://book.getfoundry.sh/), `via-IR` enabled, OpenZeppelin Contracts v5.

> **⚠️ Chain requirement:** Reentrancy protection uses `ReentrancyGuardTransient`, which relies on **EIP-1153 transient storage**. The contract must be deployed on a **Cancun-capable chain** (`evm_version = "cancun"`). All target networks — Ethereum mainnet/Sepolia, Avalanche C-Chain/Fuji, and major L2s — support this. Deploying to a pre-Cancun EVM will cause `nonReentrant` calls to fail.

## 🔒 Custody Model

Orders are backed by an **allowance**, not a deposit:

- **SELL (any counterparty)** and **BUY paid in ERC-20** — the maker `approve()`s the contract for their side of the trade and keeps the funds in their wallet. Nothing is escrowed; both legs settle by `transferFrom` at fill time. Because the maker can move funds or revoke the approval afterward, a fill is not *guaranteed* — use `isOrderFundable(orderId)` to filter the book off-chain.
- **BUY paid in native ETH** — the sole escrowed case. The maker sends `counterpartyTokenAmount + makerFee` as `msg.value` at creation and the contract holds it in `ethEscrowed[orderId]`, because native ETH cannot be pulled from an absent maker at fill time. The unfilled remainder is returned to the maker on cancel/cleanup.

**ETH payouts use pull payments.** ETH owed to a resting party (a maker's proceeds or escrow refund, and the fee recipient's fees) is booked into `pendingWithdrawals` and claimed via `withdraw()`; only the active taker is paid inline. A maker or fee recipient that cannot receive ETH therefore accrues a claimable balance rather than blocking anything. The contract has **no `receive()`/`fallback`**, so stray ETH transfers revert; the only ETH held backs live escrow or an unclaimed withdrawal (invariant: `balance == Σ ethEscrowed + Σ pendingWithdrawals`).

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

- **`SELL` (enum value `1`)** — the maker offers `baseTokenAmount` of the base token and wants counterparty tokens in return. Approve the base token. The taker supplies the counterparty token (or ETH) and receives base tokens.
- **`BUY` (enum value `0`)** — the maker wants `baseTokenAmount` of the base token and offers the counterparty token (or ETH). Approve `counterpartyTokenAmount + makerFee` of the counterparty token, **or** send that amount as `msg.value` when the counterparty is ETH. The taker supplies base tokens and receives the counterparty token/ETH.

The price is fixed at creation as the ratio `counterpartyTokenAmount / baseTokenAmount`. Fills are settled proportionally and any dust that rounds the counterparty amount to zero is rejected.

## 💰 Fee Model

Both fees are computed on the **counterparty amount** of each fill, using the rates **snapshotted into the order at creation**.

**SELL order** (taker pays the fee on top; maker receives net of the maker fee):

```
taker pays        = counterpartyAmount + takerFee
maker receives    = counterpartyAmount − makerFee
fee recipient     = makerFee + takerFee
```

**BUY order** (mirror of SELL: the maker covers the maker fee from their approved/escrowed amount, the taker's fee is deducted from proceeds):

```
maker provides    = counterpartyAmount + makerFee   (allowance, or ETH escrow)
taker receives    = counterpartyAmount − takerFee
fee recipient     = makerFee + takerFee
```

The fee incidence follows the maker/taker role in both directions: the order creator (maker) always bears the maker fee, and the filler (taker) always bears the taker fee. For a BUY+ETH order, the still-unused portion of the escrow — including the unused maker fee — is returned to the maker on cancellation or cleanup.

**Worked example — SELL 1000 BASE for 2000 USDC, fully filled (25/50 bps):**

| Party | Amount |
|-------|--------|
| Taker pays | 2010 USDC |
| Maker receives | 1995 USDC |
| Fee recipient | 15 USDC |

## 🔐 Roles & Trust Model

| Role | Powers |
|------|--------|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke roles. |
| `ADMIN_ROLE` | Manage fees, order limits, whitelist, counterparty tokens, pause/unpause, and **force-cancel** orders (`adminCancelOrder`). |
| `UPGRADER_ROLE` | Authorize UUPS implementation upgrades. |

> **⚠️ Centralization notice.** Because makers grant this contract an **allowance** (and BUY+ETH makers escrow ETH), whoever holds `UPGRADER_ROLE` can, in principle, upgrade the implementation to code that moves approved or escrowed balances. An `ADMIN_ROLE` holder can also **force-cancel** any order (funds/escrow are returned to the *maker*, never to the admin) and pause trading. **These are powerful, trust-critical capabilities.**
>
> For production you should:
> - Assign `UPGRADER_ROLE` (and ideally `DEFAULT_ADMIN_ROLE`/`ADMIN_ROLE`) to a **Timelock + multisig**, not a single EOA, so every upgrade is time-delayed and publicly visible — giving users a window to revoke approvals and exit. The default deploy script assigns all roles to one `ADMIN` address — **change this before mainnet.**
> - Publish the trust arrangement so users can assess counterparty risk.

## 🚀 Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)
- Node.js ≥ 18 (only for the npm convenience scripts and the OpenZeppelin upgrades plugin)

### Install

```bash
git clone https://github.com/SimplyTokenized/OTCTradingContract.git
cd OTCTradingContract
forge install        # pulls submodules in lib/
```

### Build & test

```bash
forge build --build-info   # --build-info is required by the OZ upgrades validator
forge test                 # runs the suite, incl. the UUPS upgrade-safety validation
forge test --gas-report
```

> **Note:** after `forge fmt` or any recompile, run `forge clean && forge build --build-info` before `forge test`, or the OpenZeppelin upgrades validator errors with "not from a full compilation".

### Configure

Copy the template and fill in real addresses:

```bash
cp .env.example .env
# then edit .env
```

`.env` is git-ignored and must never be committed. Never place private keys in `.env` for public networks — pass them via `--account`/keystore or a hardware signer at deploy time.

## 📤 Deployment

The deploy script reads `BASE_TOKEN`, `DEFAULT_COUNTERPARTY_TOKEN`, `FEE_RECIPIENT`, and `ADMIN` from the environment and deploys the implementation and a UUPS proxy, initializing it atomically.

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

After deploying, **use the proxy address** for all interactions. To enable native-ETH-denominated orders, the admin allow-lists the sentinel: `addCounterpartyToken(address(0))`. See [`CAST_COMMANDS.md`](CAST_COMMANDS.md) for ready-to-use `cast` snippets.

### Deployed addresses

| Network | Proxy | Implementation |
|---------|-------|----------------|
| _TBD_ | _TBD_ | _TBD_ |

## 📖 Contract API

### Trading

| Function | Description |
|----------|-------------|
| `createOrder(OrderType orderType, address counterpartyToken, uint256 baseTokenAmount, uint256 counterpartyTokenAmount)` `payable` → `uint256 orderId` | Create a BUY or SELL order. Approve your side first (base token for SELL; `counterpartyTokenAmount + makerFee` of the counterparty token for a BUY). For a **BUY priced in ETH**, send `counterpartyTokenAmount + makerFee` as `msg.value` instead of approving. |
| `fillOrder(uint256 orderId, uint256 baseTokenAmount)` `payable` | Fill an order partially or fully. Send ETH only when buying base off a SELL order priced in ETH (excess is refunded). |
| `cancelOrder(uint256 orderId)` | Cancel your own order; any BUY+ETH escrow remainder is credited back to you. |
| `batchCancelOrders(uint256[] orderIds)` | Cancel multiple of your own orders. |
| `cleanupExpiredOrders(uint256[] orderIds)` → `uint256 cleaned` | **Permissionless.** Deactivate expired orders; BUY+ETH escrow is credited to each order's maker. |
| `withdraw()` | Claim your accrued ETH (maker proceeds, escrow refunds, or fees). |

### Admin (`ADMIN_ROLE`)

`addCounterpartyToken` · `removeCounterpartyToken` · `updateFees` · `updateFeeRecipient` · `updateMinOrderSize` · `updateMaxOrderSize` · `updateDefaultOrderExpiration` · `updateWhitelistRequirement` · `addToWhitelist` · `removeFromWhitelist` · `batchAddToWhitelist` · `batchRemoveFromWhitelist` · `adminCancelOrder` · `adminCancelOrders` · `pause` · `unpause`

### Views

`getOrder` · `getUserOrders` · `getRemainingAmount` · `isOrderExpired` · `isOrderFundable` · `getActiveOrders(offset, limit)` · `getOrdersByToken(token, offset, limit)` · plus the public getters `orders`, `nextOrderId`, `ethEscrowed`, `pendingWithdrawals`, `makerFeeBps`, `takerFeeBps`, `minOrderSize`, `maxOrderSize`, `requireWhitelist`, `defaultOrderExpiration`, `baseToken`, `feeRecipient`, `allowedCounterpartyTokens`, `whitelist`.

### Events

`OrderCreated` · `OrderFilled` · `OrderCancelled` · `OrderAdminCancelled` · `EthEscrowRefunded` · `EthCredited` · `Withdrawn` · `CounterpartyTokenAdded` · `CounterpartyTokenRemoved` · `WhitelistAdded` · `WhitelistRemoved` · `FeesUpdated` · `MinOrderSizeUpdated` · `MaxOrderSizeUpdated` · `DefaultOrderExpirationUpdated` · `WhitelistRequirementUpdated` · `FeeRecipientUpdated` · `OrdersCleanedUp`

Full NatSpec-generated reference: `npm run docgen` (see [Documentation](#-documentation)).

### Upgrading

```solidity
// Executed by a UPGRADER_ROLE holder (a Timelock + multisig in production)
Upgrades.upgradeProxy(proxyAddress, "OTCTradingV2.sol", "");
```

Use `Upgrades.upgradeProxy` (OpenZeppelin upgrades plugin) so the storage-layout and upgrade-safety validation runs before every upgrade. New versions must only **append** storage variables.

## 🛡️ Security

- **Non-custodial:** the contract holds no ERC-20 at rest; allowances stay in makers' wallets and settle party-to-party. The only funds held are BUY+ETH escrow and unclaimed ETH withdrawals, which are exactly accounted.
- All fund-moving entry points are `nonReentrant` (OpenZeppelin `ReentrancyGuardTransient`, EIP-1153 — requires a Cancun-capable chain), with checks-effects-interactions; token transfers use `SafeERC20`.
- **Pull payments** for ETH: a maker or fee recipient that cannot receive ETH can never block a fill, cancel, or force-cancel.
- When the whitelist is enabled, `fillOrder` checks **both** taker and maker, so a de-whitelisted maker's resting orders stop settling.
- Fee rates are snapshotted per order and cannot be changed retroactively; fills that round the counterparty amount to zero are rejected.

An internal review and its remediations are documented in [AUDIT.md](AUDIT.md). **No independent external audit has been performed yet** — commission one before mainnet deployment.

To report a vulnerability, follow [SECURITY.md](SECURITY.md). Please do not open public issues for security reports.

## 📚 Documentation

- [AUDIT.md](AUDIT.md) — internal security review and remediations.
- [NONCUSTODIAL_DESIGN.md](NONCUSTODIAL_DESIGN.md) — the custody model and design rationale.
- [CAST_COMMANDS.md](CAST_COMMANDS.md) — copy-paste `cast` snippets.

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
