# Security Audit — OTCTradingContract

## v2.0 — internal review (2026-09-11)

- **Scope:** [`src/OTCTrading.sol`](src/OTCTrading.sol) (tenant-wide, multi-offering UUPS venue),
  [`src/compliance/`](src/compliance/), [`script/`](script/), repo configuration.
- **Commit state:** working tree on `feature/multitrading`, uncommitted v2 rewrite.
- **Method:** full manual review, Slither static analysis, **executable proof-of-concept tests for
  every behavioural finding** (now permanent regression tests in
  [`test/Audit.t.sol`](test/Audit.t.sol), one per finding), plus the 7 stateful invariants in
  [`test/invariant/`](test/invariant/) re-run after remediation.
- **Status:** all findings **remediated** in this working tree.
- **Independence:** this is an *internal* review by the same party that wrote the code. It is not
  a substitute for an external audit, which remains a precondition for real money.

### Summary

| ID | Severity | Finding | Status | Regression test |
|----|----------|---------|--------|-----------------|
| V2-M1 | Medium | Governance was relayable: a trusted forwarder could call any `onlyRole` function *as* the approver or admin, collapsing four eyes to one party | **Fixed** | `test_M1_*` |
| V2-M2 | Medium | Inherited upper price band (`1e36`) rejected legitimate low-decimal, high-value instruments | **Fixed** | `test_M2_*` |
| V2-M3 | Medium | Fee evasion by dust fills: fees floor to zero below `10_000 / feeBps` counterparty units and there was no minimum fill | **Fixed** | `test_M3_*` |
| V2-L1 | Low | Closing an offering could be raced: an order placed between proposal and approval bricked the approval | **Fixed** | `test_L1_*` |
| V2-L2 | Low | The contract could be named as its own fee recipient, stranding ETH fees in an unclaimable slot | **Fixed** | `test_L2_*` |
| V2-L3 | Low | A non-contract base or counterparty token was accepted at listing; the first order then reverted anonymously | **Fixed** | `test_L3_*` |
| V2-I1 | Info | `cleanupExpiredOrders` emitted no per-order event, so a cleaned order was hard to index | **Fixed** | `test_I1_*` |
| V2-I2 | Info | `quoteFill` returned zeros for the net legs of a BUY | **Fixed** | `test_I2_*` |
| V2-I3 | Info | Slither residue | Reviewed | — |

No fund-draining vector was found. The reserve property
(`address(this).balance >= totalEthEscrowed + totalPendingWithdrawals`, with both sums equal to
their per-order and per-account parts) held under the stateful invariants before and after
remediation.

### V2-M1 (Medium) — governance was relayable through the trusted forwarder

`_msgSender()` was used uniformly, including inside `onlyRole` (via OpenZeppelin's
`_checkRole(role)` → `_msgSender()`), in `_propose`/`_approve`, and in `cancelProposal` /
`cancelRoleGrant`. With a trusted forwarder set, the forwarder could therefore append any address
to its calldata and pass every governance check as that address. The forwarder change is itself
four-eyes — but once one is set, whoever controls it (a compromised relayer, a malicious forwarder
contract approved by mistake) holds every role at once. Four eyes were two.

**Fix.** Governance is never relayed. `_checkRole(bytes32)` is overridden to use `msg.sender`, so
every `onlyRole` function sees the real caller; `_propose`, `_approve`, `cancelProposal`,
`scheduleRoleGrant`, `cancelRoleGrant` and the force-cancel events all read `msg.sender` directly.
`_msgSender()` is now used only where the actor is a trader: `createOrder`, `fillOrder`,
`cancelOrder`, `batchCancelOrders`, `withdraw`. `test_M1_relayed_trading_is_unaffected` shows the
fix is scoped.

### V2-M2 (Medium) — the upper price band rejected legitimate instruments

v1's `counterpartyTokenAmount * 1e18 / baseTokenAmount <= 1e36` was carried over. It exists to catch
a fat-fingered price, but it is expressed in raw units, and a 0-decimal share priced at 1,000 ETH
(`1e21 * 1e18 / 1 = 1e39`) is over it. Tokenized real assets with few decimals and high unit prices
are exactly what this venue lists.

**Fix.** The upper band is removed; the lower band (`PriceTooLow`) stays, since a zero-price order
would fail every fill with `FillRoundsToZero` anyway. Overflow was never the band's job —
settlement uses a 512-bit `mulDiv`. Fat-finger protection belongs in the client, where the price
can be shown in human units.

### V2-M3 (Medium) — fee evasion by dust fills

Fees are `counterparty × bps / 10_000`, floored. Any fill settling below `10_000 / bps`
counterparty units (400 at 25 bps) pays no fee. With no lower bound on fill size, an order could be
taken in slices that each pay nothing — cheap on an L2. Rounding fees *up* is not an option: a
BUY+ETH order escrows the floored total fee, and a sum of ceilinged parts can exceed it.

**Fix.** A partial fill must be at least the offering's `minOrderSize`, unless it takes the
order's remainder (`FillBelowMinimum`). The remainder exemption means an order can always be closed
out however small what is left. This bounds the number of fills an order can be split into and
hands the operator the lever: an offering's minimum should be set so a minimum fill at any sane
price settles well above `10_000 / bps` counterparty units. The residual — a minimum-size fill at
a price so low the fee still floors to zero — is a misconfigured offering, and is documented as
such.

### V2-L1 (Low) — closing an offering could be raced

`proposeCloseOffering` required `openOrderCount == 0` and checked it again at approval, but did not
require the offering to be paused. Between the two signatures any eligible address could rest an
order, and the approval would revert with `OfferingHasOpenOrders`. Not a loss of funds; a way to
make the four-eyes step unfinishable.

**Fix.** The lifecycle is now explicitly `Active → Paused → Closed`: both the proposal and the
approval require `state == Paused` (`OfferingNotPaused`). Pausing is what makes the empty book stay
empty.

### V2-L2 (Low) — the venue could be its own fee recipient

Nothing stopped `feeRecipient = address(this)`. ETH fees would then be credited to
`pendingWithdrawals[address(this)]`, which nothing can call `withdraw()` for, and ERC-20 fees
would sit in the contract looking like a stray transfer.

**Fix.** `createOffering`, `proposeSetOfferingFeeRecipient` and `approveSetOfferingFeeRecipient`
reject `address(this)` alongside `address(0)`.

### V2-L3 (Low) — non-contract tokens accepted at listing

`createOffering` only checked `baseToken != address(0)`, and `_allowCounterpartyToken` did not
check at all. A mistyped address would be accepted, and the first SELL would fail inside the
allowance precheck with an empty revert — the same class of anonymous failure the eligibility
probe was already hardened against.

**Fix.** `baseToken.code.length == 0` → `InvalidBaseToken`; a non-zero counterparty token with no
code → `InvalidCounterpartyToken`. Fail at listing, with a name.

### Informational

- **V2-I1** — `OrderCleanedUp(orderId, offeringId, maker)` is now emitted per cleaned order.
- **V2-I2** — `quoteFill` returns `takerNet` / `makerNet` in both directions: what the taker
  pays / maker receives on a SELL, what the taker receives / maker pays on a BUY.
- **V2-I3 — Slither residue cleared.** Two items were fixed outright and the rest are suppressed
  inline, each with its rationale written next to the directive so a reader sees *why* at the line:
  - `costly-loop` — **fixed.** Batch cancels (`batchCancelOrders`, `adminCancelOrders`,
    `cleanupExpiredOrders`) no longer write the two reserve totals once per order. `_releaseEscrow`
    does the per-order half and the totals move once per batch in `_moveEscrowToPending`. No
    external call happens between the two, so the totals are never observable out of step.
  - `cyclomatic-complexity` — **fixed.** `createOrder` and `fillOrder` each delegate their
    validation to a named helper (`_checkOrderTerms` + `_checkMakerFunding`, `_checkFillTerms`),
    which is also easier to review than one long block.
  - `timestamp` — suppressed. Every comparison is an order expiry, a proposal TTL or a grant
    window; shading the block time by seconds shifts those by seconds and gains nothing.
  - `missing-zero-check` — suppressed. `address(0)` is how relaying is switched *off*.
  - `dead-code` — suppressed. `_msgData` / `_contextSuffixLength` are the other half of
    `_msgSender`; an upgrade that adds Multicall would need them consistent.
  - `low-level-calls` — suppressed. The `staticcall` exists to detect undecodable replies (see the
    fail-closed gate); the `call` exists so smart-wallet takers are not starved by `transfer`.
  - `uninitialized-local` — fixed (explicit `= 0`).
  Post-remediation Slither reports no findings in `src/`.

### Accepted by design (no change)

- **The upgrade key is the root of trust.** `UPGRADER_ROLE` can replace the settlement code beneath
  users' standing allowances; the mitigation is operational (Timelock + multisig) and documented.
- **Four eyes cannot detect one person holding two keys.** The role-grant delay makes arming a
  second key visible; it cannot make it impossible.
- **An allowance-backed order is not guaranteed fillable.** `isOrderFundable` is the honest answer.
- **`openOrderCount` can be inflated** by anyone eligible, delaying a close until the operator
  pauses and force-cancels. Force-cancel returns escrow to makers, so this costs the griefer gas
  and gains them nothing.
- **A compliance registry is trusted to answer honestly**; the contract enforces the answer and
  fails closed when there is none.

### Positives

- Every fund-moving entry point is `nonReentrant` with strict checks-effects-interactions;
  settlement is split into `_priceFill` (view) → state writes → `_settle` (interactions), and
  `_settle` is the last statement of `fillOrder`.
- Pull-payment ETH means no resting party can block a fill, a cancel or a force-cancel.
- Exits (`cancelOrder`, `batchCancelOrders`, `withdraw`) are never pausable and never gated.
- The reserve totals make the emergency path structurally unable to reach user money, and the
  stateful invariants confirm the per-order and per-account sums match them.
- `_disableInitializers()` in the constructor; the OpenZeppelin upgrades validator runs in every
  test deployment.

---

## v1.1 — external-style review (2026-07-14)

> Everything below reviewed the single-token, single-book contract. **Every fix is carried
> forward into v2** and still covered by tests: pull-payment ETH (H-1, M-1, L-1), compliance
> checked at fill time for both sides (M-2), escrow dust returned on the closing fill (L-1).
> Of the v1 informational items, **I-3 (unbounded view scans) is addressed in v2** — order ids are
> indexed per offering and per maker, and `scanActiveOrders` walks a caller-bounded window.

- **Scope:** [`src/OTCTrading.sol`](src/OTCTrading.sol) (UUPS-upgradeable OTC order book),
  [`script/DeployOTC.s.sol`](script/DeployOTC.s.sol), repo configuration.
- **Commit state:** working tree on `main` (uncommitted redesign: allowance-based settlement,
  BUY+ETH escrow, UUPS, pull-payments).
- **Method:** full manual review, Slither 0.11.4 static analysis, **executable proof-of-concept
  tests for every behavioral finding**, plus a 2,000-run fuzz of escrow solvency.
- **Date:** 2026-07-14
- **Status:** all findings below **remediated** in this working tree; the PoCs were converted into
  permanent regression tests in [`test/OTCTrading.t.sol`](test/OTCTrading.t.sol) (39 passing).

### Summary

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
