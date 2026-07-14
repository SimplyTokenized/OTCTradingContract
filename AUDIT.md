# Security Audit — OTCTradingContract

- **Scope:** [`src/OTCTrading.sol`](src/OTCTrading.sol) (UUPS-upgradeable OTC order book),
  [`script/DeployOTC.s.sol`](script/DeployOTC.s.sol), repo configuration.
- **Commit state:** working tree on `main` (uncommitted redesign: allowance-based settlement,
  BUY+ETH escrow, UUPS, pull-payments).
- **Method:** full manual review, Slither 0.11.4 static analysis, **executable proof-of-concept
  tests for every behavioral finding**, plus a 2,000-run fuzz of escrow solvency.
- **Date:** 2026-07-14
- **Status:** all findings below **remediated** in this working tree; the PoCs were converted into
  permanent regression tests in [`test/OTCTrading.t.sol`](test/OTCTrading.t.sol) (39 passing).

## Summary

| ID | Severity | Finding | Status | Regression test |
|----|----------|---------|--------|-----------------|
| H-1 | High | BUY+ETH order of an ETH-rejecting maker could never be cancelled by anyone, and poisoned admin batches | **Fixed** | `test_ETH_RefundToNonReceiverIsCredited_H1`, `test_ETH_AdminCancelNonReceiver_DoesNotBlock_H1` |
| M-1 | Medium | Reverting `feeRecipient` halted **all** ETH-denominated settlement | **Fixed** | `test_ETH_RevertingFeeRecipientDoesNotBlockFills_M1` |
| M-2 | Medium | De-whitelisted maker's resting orders stayed passively fillable | **Fixed** | `test_ETH_DewhitelistedMakerCannotBeFilled_M2` |
| L-1 | Low | Rounding dust of BUY+ETH escrow permanently stranded on full fill | **Fixed** | `test_ETH_DustCreditedToMakerOnFullFill_L1` |
| L-2 | Low | `FEE_RECIPIENT_ROLE` was dead code and drifted on `updateFeeRecipient` | **Fixed** | n/a (removed) |
| I-1…I-5 | Info | see below | Acknowledged | — |

No theft/fund-draining vector was found. The escrow-solvency invariant
(`address(this).balance == Σ ethEscrowed + Σ pendingWithdrawals`, no underflow under arbitrary fill
sequences) was fuzz-verified. Core settlement math, access control, initialization, upgrade
authorization, and storage-layout upgrade-safety all check out.

---

## The core fix — pull payments (closes H-1, M-1, L-1)

**Root cause:** every ETH payout was a **push** with `require(success)`. A single party that could
not receive ETH (or deliberately reverted) could lock funds, block settlement, or grief batches.

**Remediation:** ETH owed to any **resting** party — a maker's proceeds/refund and the fee
recipient's fees — is now booked into `pendingWithdrawals[account]` (event `EthCredited`) and claimed
via `withdraw()`. Only the **active caller** (`msg.sender`, the taker) is paid inline, so a hostile
or broken third party can only ever fail to claim *their own* funds. See
[`_creditETH`](src/OTCTrading.sol) / [`withdraw`](src/OTCTrading.sol).

### H-1 (High) — uncancellable order / poisoned batches
`_refundEscrow` now credits instead of pushing, so `cancelOrder`, `adminCancelOrder(s)`,
`batchCancelOrders`, and `cleanupExpiredOrders` never revert on a non-ETH-receiving maker. The
compliance force-cancel objective holds, and one hostile order no longer reverts a whole admin batch.

### M-1 (Medium) — broken fee recipient halted ETH market
Fees are credited, so an ETH fill can no longer be blocked by a `feeRecipient` that rejects ETH.

### L-1 (Low) — stranded escrow dust
On the **closing** fill of a BUY+ETH order, any rounding remainder in `ethEscrowed[orderId]` is
credited to the maker and the slot zeroed, so escrow never strands ETH.

## M-2 (Medium) — de-whitelisted maker kept trading

When `requireWhitelist` is on, [`fillOrder`](src/OTCTrading.sol) now requires **both**
`whitelist[msg.sender]` (taker) **and** `whitelist[order.maker]`. A maker removed from the whitelist
has their resting orders stop settling immediately, not just their ability to create new ones.

## L-2 (Low) — dead role removed

`FEE_RECIPIENT_ROLE` was granted at init but never used in any `onlyRole` check, and
`updateFeeRecipient` never moved it. Removed entirely (a constant, so no storage-layout impact).

---

## Informational (acknowledged, no change required)

- **I-1 — Powerful admin / UUPS upgrade key.** `ADMIN_ROLE` + `UPGRADER_ROLE` are granted to one
  `_admin` at init. A compromised key can upgrade and reach all standing allowances. Mitigation is
  operational and already documented in-code: move `UPGRADER_ROLE` (and ideally `ADMIN_ROLE`) to a
  Timelock + multisig before mainnet. Consider `AccessControlDefaultAdminRules` (2-step) for
  `DEFAULT_ADMIN_ROLE`.
- **I-2 — `createOrder` funding precheck is advisory.** For allowance-backed orders the
  balance/allowance check can be invalidated later by the maker; correctly documented, and clients
  must rely on `isOrderFundable` rather than creation success.
- **I-3 — Unbounded view scans.** `getActiveOrders` / `getOrdersByToken` are `O(nextOrderId)`; fine
  off-chain but they will eventually exceed `eth_call` gas caps on a large book. Prefer event
  indexing for production frontends.
- **I-4 — Fee-on-transfer / rebasing tokens unsupported.** Documented in the contract NatSpec;
  settlement assumes exact-amount transfers.
- **I-5 — Slither residue reviewed & accepted.** `arbitrary-send-erc20` is the intended
  allowance-based settlement (`transferFrom(maker, …)`); `divide-before-multiply` in fee math is
  negligible precision loss matching the original; `timestamp` comparisons are expiry checks not
  manipulable at the relevant scale; the `reentrancy-eth`/`calls-loop` flags on the batch cancels are
  idempotent `isActive` writes guarded by `nonReentrant`.

## Positives

- All fund-moving entry points are `nonReentrant` with checks-effects-interactions; pull-payments
  shrink the ETH call surface to one inline transfer to `msg.sender` per fill, plus `withdraw`.
- Storage layout verified append-only vs. the original (`ethEscrowed`, then `pendingWithdrawals`
  appended last) — upgrade-safe.
- `_disableInitializers()` in the constructor blocks implementation-contract initialization.
- No secrets in the repo; `.env` is git-ignored and holds only well-known Anvil test addresses.
