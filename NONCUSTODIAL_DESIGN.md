# Non-Custodial OTC — Design Concept

Status: **adopted.** `OTCTrading` is the settlement model described here — a **single** contract
([`src/OTCTrading.sol`](src/OTCTrading.sol), UUPS-upgradeable) that handles both ERC-20 and native
ETH. It is non-custodial **except** for BUY orders priced in ETH, which must escrow (see §4).

## 1. Motivation

The old contract was **custodial**: makers deposited tokens into escrow, orders rested on-book,
and takers filled later. That single choice was the root cause of a cluster of problems —
dividend/income attribution on escrowed security tokens, a native-ETH handling surface, BUY-order
fee pre-funding/refunds (Variant A), and an `emergencyWithdraw` power over user funds.

Going **non-custodial** removes the root cause: the contract never holds user funds. Makers keep
custody in their own wallets and grant an **allowance**; settlement happens atomically at fill time
via `transferFrom` on both legs. Every symptom above disappears rather than being patched.

## 2. Model

- Makers **`approve()`** the OTC contract for what they're offering; they do **not** deposit. An
  order is backed by an allowance, not escrow.
- At **fill**, both legs move atomically in one transaction: base and counterparty change hands
  directly between maker and taker (plus fees to the fee recipient).
- **Native ETH is a first-class counterparty token**, denoted by the sentinel `address(0)` — exactly
  as in the original contract. No WETH, no wrapping, no periphery contract; `createOrder` and
  `fillOrder` stay `payable`.

### Settlement math

For a fill of `b` base on an order priced `P` counterparty per `B` base, settlement is
`s = b * P / B` (must be `> 0`, else revert). Fees use the order's **snapshotted** rates:
`makerFee = s * makerFeeBps / 10000`, `takerFee = s * takerFeeBps / 10000`.

**SELL** (maker sells base, taker pays counterparty): base maker→taker `b`; counterparty
taker→maker `s − makerFee`; fees taker→feeRecipient `makerFee + takerFee`. Taker pays `s + takerFee`.

**BUY** (maker buys base, taker sells base): base taker→maker `b`; counterparty maker→taker
`s − takerFee`; fees maker→feeRecipient `makerFee + takerFee`. Maker pays `s + makerFee`.

Fee incidence is **symmetric for free**: the maker always bears the maker fee, the taker the taker
fee — with no pre-funding and no refund logic, because nothing is ever escrowed.

## 3. What changed vs the custodial contract

**Gone:** escrow transfers in `createOrder` for every case **except BUY+ETH**; `emergencyWithdraw`
over user funds; the `receive()` fallback; fund-returning cancel/cleanup for allowance-backed orders
(now a flag flip).

**Kept:** order book, BUY/SELL, partial fills, snapshotted fees, whitelist, expiration, counterparty
allowlist, pausability, role-based admin, reentrancy protection (`ReentrancyGuardTransient`), and the
original `address(0) = ETH` API with `payable` `createOrder`/`fillOrder`.

**Fee incidence is symmetric in every case**: the maker bears the maker fee, the taker the taker fee.
For allowance-backed orders this needs no pre-funding at all. For BUY+ETH the maker's escrow simply
includes the maker fee up front, and each fill draws its share — no refund arithmetic beyond
returning the unfilled remainder.

## 4. Native ETH — and the one escrowed case

Enable ETH orders by allow-listing the sentinel: `addCounterpartyToken(address(0))`.

The asymmetry that drives the design: **an allowance can pull ERC-20 at a later fill, but nothing
can pull native ETH from an absent wallet.** So whether ETH can be allowance-backed depends entirely
on *who has to pay at fill time*:

| Order | Who pays counterparty at fill | ETH works without escrow? |
|-------|-------------------------------|---------------------------|
| **SELL** priced in ETH | the **taker** — present in the fill tx | ✅ yes — sends `msg.value` with `fillOrder` |
| **BUY** priced in ETH | the **maker** — *absent* from the fill tx | ❌ no — must pre-fund |

So **BUY + ETH is the sole custodial path**: the maker sends exactly
`counterpartyAmount + makerFee` with `createOrder`, and the contract holds it. This is a deliberate,
accepted trade-off — the alternative (making the maker wrap to WETH and approve) keeps the contract
fund-free but changes the maker's UX.

Escrow is bounded and exactly accounted:

- Tracked per order in `ethEscrowed[orderId]`. There is **no `receive()`/`fallback`** — raw ETH sent
  to the contract reverts — so the only ETH ever held backs either live escrow or an unclaimed
  withdrawal. Invariant: `address(this).balance == Σ ethEscrowed + Σ pendingWithdrawals`.
- Each fill draws down exactly its cost (`settlement + makerFee`); the closing fill also releases any
  rounding **dust** to the maker, so escrow never strands ETH.
- Any unfilled remainder is returned to the **maker** on `cancelOrder`, `cleanupExpiredOrders`, and
  `adminCancelOrder`. An admin force-cancel returns the ETH to its maker — **never to the admin**;
  a permissionless cleanup returns it to the maker — **never to the caller**.

**ETH payouts to resting parties use PULL PAYMENTS.** A maker's ETH proceeds/refund and the fee
recipient's fees are booked into `pendingWithdrawals` (event `EthCredited`) and claimed later via
`withdraw()`; they are never pushed. Only the active taker (`msg.sender`) is paid inline. This means
a maker or fee recipient that cannot receive ETH can **never** block settlement, a cancel, or an
admin/compliance force-cancel — they just accrue a claimable balance. (This closes the earlier
push-payment liveness/lock bugs: a hostile maker could otherwise brick `adminCancelOrder` and poison
admin batches, and a broken `feeRecipient` could halt all ETH fills.)

Everything else — SELL in ETH, SELL in ERC-20, BUY in ERC-20 — escrows **nothing**.

## 5. Order validation (permissionless)

A stale order **locks no funds** — it's just a dead row — so validation is book hygiene, not fund
safety, and is **permissionless** (not an admin power). Safety comes from guarding the *condition*:

- `isOrderFundable(orderId)` → view, anyone: frontends/relayers filter unfundable orders off the book.
- `cleanupExpiredOrders(orderIds)` → state change, anyone, **expiry-only** (deterministic, ungameable).
- Underfunding is transient and **not** third-party prunable; only the maker cancels early.

## 6. Security notes

- **Upgradeability (UUPS) + Timelock is load-bearing.** Users grant the contract an allowance (and
  BUY+ETH makers escrow ETH in it), so whoever controls the upgrade can in principle change the
  settlement code and move approved/escrowed balances. `_authorizeUpgrade` is gated by
  `UPGRADER_ROLE`; that role **MUST** be held by a **Timelock + multisig** so every upgrade is
  time-delayed and publicly visible, letting users revoke approvals, cancel orders, and exit before
  it lands. Upgrades must be **append-only** in storage (validated by the OpenZeppelin plugin).
- **Alternatives to reduce upgrade trust** (future): Permit2 scoped/expiring approvals (no standing
  allowance to drain), or a split immutable-settlement + upgradeable-config design.
- **Reentrancy:** every fund-moving entry point is `nonReentrant` (`ReentrancyGuardTransient`,
  EIP-1153) — `createOrder`, `fillOrder`, `cancelOrder`/`batchCancelOrders`, `adminCancelOrder(s)`,
  `cleanupExpiredOrders`, and `withdraw` — and all state (order flags, `ethEscrowed`,
  `pendingWithdrawals`) is written **before** any transfer or `call` (CEI). Pull-payments shrink the
  ETH-callout surface to a single inline transfer to `msg.sender` at the end of a fill, plus
  `withdraw`.
- **Compliance:** when `requireWhitelist` is on, `fillOrder` checks **both** the taker and the
  order's maker, so a de-whitelisted maker's resting orders stop trading immediately (not just their
  ability to create new ones).
- **Open question — ERC-3643/1400 base tokens.** The atomic dual-`transferFrom` assumes a plain
  `transferFrom(maker → taker)` succeeds. If the base token enforces compliant transfers, both legs
  must pass compliance in the same tx; validate against the real token or fall back to a DvD manager.

## 7. Contract surface

**One contract**, `OTCTrading` (UUPS-upgradeable). There is no periphery and no WETH interface.

- **Trading:** `createOrder` (payable), `fillOrder` (payable), `cancelOrder` / `batchCancelOrders`,
  `cleanupExpiredOrders`, `withdraw` (claim accrued ETH — pull-payment).
- **Admin:** `adminCancelOrder` / `adminCancelOrders` (ADMIN_ROLE force-cancel; refunds escrow to the
  maker, distinct `OrderAdminCancelled` event), counterparty-token allowlist (pass `address(0)` to
  enable ETH), fees, order sizes, expiration, whitelist, fee recipient, pause/unpause.
- **Upgrade:** `_authorizeUpgrade` (UPGRADER_ROLE).
- **Views:** `getOrder`, `getUserOrders`, `getRemainingAmount`, `isOrderExpired`, `isOrderFundable`,
  `ethEscrowed`, and the `ETH` sentinel constant.

## 8. Trade-off accepted

Allowance-backed orders are **not guaranteed fundable** — a maker can move funds or revoke the
allowance, so a fill can revert. This is a UX/relayer concern, not a safety one (no funds are lost);
`isOrderFundable` plus off-chain filtering handles it, as production RFQ/OTC systems (0x, CoW) do.
BUY+ETH orders are escrowed and therefore always fundable, which is the upside of that trade.
