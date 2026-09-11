# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [2.0.0] — Unreleased

**One trading contract per tenant, many offerings.**

v1 was a venue for a single token: `baseToken` was contract-wide, so listing a second instrument
meant deploying, governing, monitoring and upgrading a second contract. v2 moves every property
that was really a property of the instrument onto an **offering** — its base token, its fee schedule
and recipient, its order-size band, its default expiry, its settlement assets and its compliance
gate — so one deployment runs many books, each configured, halted and closed on its own.

### BREAKING

There is **no upgrade path from 1.x**. Storage layout, constructor arguments and most of the
external API changed. v2 is deployed fresh; 1.x instances keep serving their own books until their
makers drain them. See [Migrating from v1](README.md#migrating-from-v1).

- `initialize` now takes `(admin, approver, upgrader, forwarder)` — no token, no fees, no limits.
  Those belong to an offering, and there are none until one is listed.
- Every trading call takes an `offeringId`. `createOrder` gained it as its first argument.
- `baseToken`, `makerFeeBps`, `takerFeeBps`, `minOrderSize`, `maxOrderSize`,
  `defaultOrderExpiration`, `feeRecipient`, `requireWhitelist`, `whitelist` and
  `allowedCounterpartyTokens` are gone as contract-wide state. Their per-offering equivalents live
  on `Offering` and in `offeringCounterpartyTokens[offeringId]`.
- `addToWhitelist`, `removeFromWhitelist`, `batchAddToWhitelist`, `batchRemoveFromWhitelist` and
  `updateWhitelistRequirement` are gone: compliance is now a registry the offering names.
- `updateFees`, `updateMinOrderSize`, `updateMaxOrderSize`, `updateDefaultOrderExpiration`,
  `updateFeeRecipient`, `addCounterpartyToken` and `removeCounterpartyToken` are replaced by their
  per-offering counterparts.
- `getActiveOrders` and `getOrdersByToken` are gone. Both walked every id the contract had ever
  issued, which under one contract per tenant means scanning every offering to answer a question
  about one. Replaced by `getOfferingOrders`, `getMakerOrders` and the bounded `scanActiveOrders`.
- `getUserOrders(address)` returned an unbounded array; `getMakerOrders(address, offset, limit)`
  returns a page and the total.
- Revert strings became **55 custom errors**. Breaking for anyone matching on revert reasons.
- `Order` gained `offeringId` and packs its flags, fees and timestamps; timestamps are `uint48`.

### Added

- **Offerings.** `createOffering(OfferingConfig)`, `allowCounterpartyToken`,
  `disallowCounterpartyToken`, `setOfferingFees`, `setOfferingLimits`, `setOfferingPaused`, and the
  four-eyes `CloseOffering` pair. `baseToken` and `eligibilityRegistry` are fixed for an offering's
  life; an order must never have its settlement asset, or the gate it was admitted under, changed
  underneath it.
- **`offeringRef`** — the off-chain offering record a book belongs to, carried on-chain so a trade
  can be tied back to the instrument it belongs to without trusting an off-chain index.
- **Pluggable compliance** (`src/compliance/`): `IEligibilityRegistry`, `WhitelistRegistry` and
  `ERC3643EligibilityAdapter`, which defers to the security token's own identity registry — an
  independent compliance layer rather than the venue operator attesting twice. The gate is checked
  at order creation **and, for both sides, at settlement**, so a maker whose verification lapses
  while their order rests stops trading. It fails closed, including for a registry that returns
  nothing or has no code.
- **Per-offering pause**, so one book can be halted without touching the others.
- **Four-eyes governance** on the four actions that direct value or cannot be undone: redirecting an
  offering's fees, closing an offering, changing the trusted forwarder, and rescuing stray assets.
  Proposals bind their exact parameters and lapse after `PROPOSAL_TTL`.
- **Delayed role grants** (`ROLE_GRANT_DELAY`, 2 days) with immediate revocation, so the role-admin
  root cannot arm a second approver and self-approve in one transaction.
- **`OPERATOR_ROLE` and `APPROVER_ROLE`**, splitting day-to-day venue operation from guardianship
  and from the second pair of eyes. `initialize` refuses an approver equal to the admin.
- **Reserve accounting.** `totalEthEscrowed` and `totalPendingWithdrawals` make
  `address(this).balance >= totalEthEscrowed + totalPendingWithdrawals` checkable on-chain;
  `rescuableAmount()` is the difference, so the emergency path can only reach ETH forced in from
  outside the protocol.
- **`RescueAssets`**, replacing nothing in v1 — a mis-sent ERC-20 previously had no way out.
- **ERC-2771 relaying**, with the forwarder in storage so one implementation serves tenants who pay
  their users' gas and tenants who do not. A relayed call may not carry value.
- **`quoteFill`**, returning exactly what settlement will do, and `isEligibleToTrade`,
  `orderBaseToken`, `offeringOrderCount`, `makerOrderCount`, `rescuableAmount`, `roleGrantWindow`.
- **Stateful invariants** over a random walk of four actors across two offerings: ETH held covers
  what is owed, the per-order escrow really sums to the reserve, so do the pending withdrawals, no
  order is overfilled, each offering's live count matches its own book, a closed order holds no
  escrow, and the venue never holds a trading asset.

### Changed

- **Rounding now favours the resting maker**: a partial fill's counterparty amount rounds up on a
  SELL and down on a BUY. v1 rounded down in both directions, which let a long tail of small fills
  bleed a selling maker by a wei each. Rounding down on a BUY is unchanged and is a requirement, not
  a preference: it is what keeps a sequence of partial fills inside the escrow.
- **Fee rates are snapshotted per order** against the *offering's* schedule rather than the venue's.
- **Batch functions are bounded** by `MAX_BATCH_SIZE` (200). `batchCancelOrders`,
  `adminCancelOrders` and `cleanupExpiredOrders` were unbounded and could be made to run out of gas.
- **Force-cancel moved to `OPERATOR_ROLE`**, the role that runs compliance, and keeps its distinct
  event.
- `cleanupExpiredOrders` returns and emits the count it actually cleaned, rather than echoing the
  ids it was asked about.
- The price band is computed with a 512-bit `mulDiv`, so a large but legitimate pair of amounts
  cannot overflow into it.

### Security

- **Internal review of v2** (see `AUDIT.md`): 3 Medium, 3 Low and 3 informational findings, all
  remediated, each with a regression test in `test/Audit.t.sol`.
  - *V2-M1* Governance is never relayed: role checks, proposals and approvals read `msg.sender`,
    so a trusted forwarder can act as a trader but never as the approver or admin.
  - *V2-M2* The inherited upper price band is removed; it rejected legitimate low-decimal,
    high-value instruments.
  - *V2-M3* A partial fill must be at least the offering's `minOrderSize` unless it takes the
    remainder (`FillBelowMinimum`), closing the dust-fill fee-evasion path.
  - *V2-L1* Closing an offering requires it to be paused first (`OfferingNotPaused`), so the
    approval cannot be raced by a new order.
  - *V2-L2* The contract cannot be its own fee recipient.
  - *V2-L3* Base and counterparty tokens must be contracts (`InvalidCounterpartyToken`).
  - *V2-I1/I2* `OrderCleanedUp` per cleaned order; `quoteFill` returns `takerNet` / `makerNet`
    meaningfully in both directions.
  - *V2-I3* Slither residue cleared: batch cancels update the reserve totals once per batch
    rather than per order; `createOrder` / `fillOrder` validation moved into named helpers; the
    intended uses of `block.timestamp`, low-level calls and the `address(0)` forwarder are
    suppressed inline with their rationale.
- Settlement checks compliance for **both** sides, at the moment money moves.
- Exits are never gated and never pausable: `cancelOrder`, `batchCancelOrders` and `withdraw` work
  for a de-listed maker, on a paused offering, and while the whole venue is halted.
- Still **unaudited**. An independent audit remains a precondition for real money.

---

## [1.1.0] — 2026-07-14

Non-custodial redesign. Orders became allowance-backed rather than deposit-backed, ETH payouts
became pull-payments, reentrancy protection standardized on `ReentrancyGuardTransient`, and the
contract moved to UUPS. BUY-order fees were made symmetric with SELL. See `AUDIT.md`.

## [1.0.0] — 2026-01-11

Initial release: a custodial OTC book for one ERC-20 base token, with a built-in whitelist and
contract-wide fees.
