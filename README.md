# OTCTrading

**One trading contract per tenant. One offering per tradable instrument.**

An upgradeable, non-custodial OTC venue for tokenized securities. Makers rest orders backed by an
allowance rather than a deposit, both legs settle atomically at fill time, and a single deployment
carries every offering a tenant lists — each with its own base token, fee schedule, size band,
settlement assets and compliance gate.

> **Status: internally reviewed, not externally audited.** A full internal review of v2 found and
> remediated 3 Medium and 3 Low findings — see [AUDIT.md](AUDIT.md), each with a regression test.
> An independent audit remains a precondition for real money. See [SECURITY.md](SECURITY.md).

---

## Table of Contents

- [Why v2](#why-v2)
- [What it does](#what-it-does)
- [What it does not do](#what-it-does-not-do)
- [Offerings](#offerings)
- [Custody model](#custody-model)
- [Fee model](#fee-model)
- [Rounding](#rounding)
- [Compliance](#compliance)
- [Governance and roles](#governance-and-roles)
- [The two guarantees](#the-two-guarantees)
- [Quick start](#quick-start)
- [Walkthrough](#walkthrough)
- [Reading the book](#reading-the-book)
- [Who pays the gas](#who-pays-the-gas)
- [API reference](#api-reference)
- [Upgradeability](#upgradeability)
- [Testing](#testing)
- [Migrating from v1](#migrating-from-v1)
- [License](#license)

---

## Why v2

v1 was a venue for a single token. `baseToken` was contract-wide, so listing a second instrument
meant deploying a second contract — and governing it, monitoring it, upgrading it, and guarding a
second set of keys. A tenant with forty offerings had forty of everything.

Every property that was really a property of the *instrument* now lives on an **offering**:

| v1 (contract-wide) | v2 (per offering) |
| --- | --- |
| `baseToken` | `Offering.baseToken`, fixed for its life |
| `makerFeeBps` / `takerFeeBps` | `Offering.makerFeeBps` / `takerFeeBps` |
| `feeRecipient` | `Offering.feeRecipient` (four-eyes to change) |
| `minOrderSize` / `maxOrderSize` | `Offering.minOrderSize` / `maxOrderSize` |
| `defaultOrderExpiration` | `Offering.defaultOrderExpiration` |
| `allowedCounterpartyTokens` | `offeringCounterpartyTokens[offeringId]` |
| built-in `whitelist` | `Offering.eligibilityRegistry` — pluggable, fixed for its life |
| `pause()` only | `pause()` **and** `setOfferingPaused(offeringId, …)` |

What that buys, concretely: a fund priced in USDC and a token priced in ETH run side by side; one
book can be halted without touching the others; one offering's fees land somewhere else entirely;
and an issuer's second tranche is one transaction, not one deployment.

---

## What it does

- **Rests orders on a book.** A maker posts BUY or SELL at a fixed price, and takers fill it whole
  or in parts until it is exhausted, cancelled or expired.
- **Settles both legs atomically**, maker to taker, with the venue holding nothing.
- **Prices in anything the offering lists** — any ERC-20, or native ETH.
- **Charges the maker the maker fee and the taker the taker fee**, symmetrically in both
  directions, at rates snapshotted onto each order when it is created.
- **Gates trading per offering**, optionally, on a registry the offering names — including the
  security token's own ERC-3643 identity registry.
- **Splits duties across four roles** and puts the irreversible actions behind four eyes.

## What it does not do

- **It is not an order-matching engine.** There is no crossing, no price-time priority and no
  automatic matching: a taker names the order they want. Matching is the platform's job, off-chain,
  where it can be reasoned about and changed without an upgrade.
- **It does not custody your assets** — with the single escrowed exception below.
- **It does not support fee-on-transfer or rebasing tokens.** Settlement moves an exact amount
  between two parties; a transfer fee would silently short one of them.
- **It does not decide who may trade.** That question goes to a registry, and the contract only
  enforces the answer.

---

## Offerings

An offering is one tradable instrument with its own economics:

```solidity
otc.createOffering(OTCTrading.OfferingConfig({
    baseToken:              address(fundToken),   // fixed for the offering's life
    feeRecipient:           treasury,             // four-eyes to change
    eligibilityRegistry:    address(registry),    // fixed for its life; address(0) = ungated
    makerFeeBps:            25,                   // 0.25%
    takerFeeBps:            50,                   // 0.50%
    defaultOrderExpiration: 30 days,              // 0 = orders never expire
    minOrderSize:           1e18,
    maxOrderSize:           0,                    // 0 = no ceiling
    offeringRef:            keccak256("FUND-2026-A"),  // the off-chain record this book belongs to
    counterpartyTokens:     [address(usdc), address(0)] // address(0) enables native ETH
}));
```

Two fields are deliberately **immutable for the offering's life**:

- `baseToken` — an order resting on the book must not have the asset it settles in changed
  underneath it.
- `eligibilityRegistry` — an order admitted under one gate must never be judged by another.

Everything else is tunable by the role that owns it. An offering moves `Active ↔ Paused` freely,
and `Paused → Closed` once, irreversibly, and only with an empty book. Closing requires the pause
first, so nobody can rest a new order between the proposal and the approval.

---

## Custody model

**Orders are backed by an allowance, not a deposit.** A maker approves the contract for their side
and keeps their funds until a taker arrives; `transferFrom` moves both legs in the same
transaction. The trade-off is stated plainly: an allowance-backed order is *not* guaranteed
fillable — the maker may move funds or revoke. Use `isOrderFundable(orderId)` to filter the book.

**The one exception: a BUY priced in native ETH must escrow** `counterpartyAmount + makerFee` at
creation, because an allowance can pull ERC-20 at a later fill but nothing can pull ETH from a maker
who is not present in the taker's transaction. Escrow is tracked per order in `ethEscrowed`, and the
unfilled remainder is credited back to the maker on cancel, cleanup or force-cancel.

**ETH payouts are pull-payments.** Anything owed to a *resting* party — a maker's proceeds or escrow
refund, a fee recipient's fees — is booked into `pendingWithdrawals` and claimed with `withdraw()`.
Only the active caller is paid inline. A maker or fee recipient that cannot receive ETH therefore
never blocks a settlement, a cancel or a compliance force-cancel; they simply accrue a balance.

There is no `receive()` and no `fallback()`: a bare transfer to the contract reverts, so the only
ETH here is money with a claim on it.

---

## Fee model

Both sides pay their own fee, in the counterparty asset, in both directions:

| | SELL order (maker sells base) | BUY order (maker buys base) |
| --- | --- | --- |
| Maker | receives `price − makerFee` | pays `price + makerFee` |
| Taker | pays `price + takerFee` | receives `price − takerFee` |
| Fee recipient | `makerFee + takerFee` | `makerFee + takerFee` |

Rates are snapshotted onto the order at creation, so a later schedule change can never be applied
retroactively to a trade someone has already agreed to. `MAX_FEE_BPS` caps either side at 10%.

`quoteFill(orderId, baseAmount)` returns exactly what settlement will do, in both directions:
`takerNet` / `makerNet` are what the taker pays and the maker receives on a SELL, and what the
taker receives and the maker pays on a BUY.

**Minimum fill.** A partial fill must be at least the offering's `minOrderSize`, unless it takes the
order's remainder. Fees floor, so a fill settling below `10_000 / feeBps` counterparty units pays
none — without a floor on fill size an order could be taken in slices that each pay nothing. Set an
offering's minimum so a minimum fill at any sane price settles well above that.

---

## Rounding

A partial fill's counterparty amount is rounded **in the resting maker's favour**: up on a SELL,
down on a BUY.

Rounding down on a BUY is not a preference but a requirement. The escrow holds exactly
`counterpartyAmount + makerFee`, and since a sum of rounded-down parts never exceeds the rounded-down
whole, no sequence of partial fills can draw past it. Rounding up on a SELL costs the taker at most
one wei per fill and stops a maker being bled by a long tail of small ones.

A fill that settles to *zero* counterparty tokens is refused outright — otherwise a taker could take
base tokens repeatedly while paying nothing. There is a floor on price (`PriceTooLow`) but
deliberately no ceiling: a 0-decimal share priced at a thousand ETH is an ordinary tokenized asset,
and any band that would catch a fat-fingered price would catch it too. Show prices in human units in
the client; that is where fat-finger protection belongs.

---

## Compliance

Each offering names one gate, checked when an order is **created** and again, for **both sides**,
when it is **filled**. Three postures:

| Registry | Who decides | When to use it |
| --- | --- | --- |
| `address(0)` | nobody — ungated | a freely tradable token |
| `WhitelistRegistry` | the operator's own list | a venue keeping its own KYC list |
| `ERC3643EligibilityAdapter` | the security token's **own** identity registry | regulated offerings |

The ERC-3643 adapter is the one a regulated issuer's counsel actually asks for. A whitelist kept by
the venue operator is the same party attesting twice; an ERC-3643 identity registry is an
independent compliance layer — the same one that gates the token's own transfers — so "only verified
investors traded this offering" becomes a property the chain enforced. It also removes a failure
mode: a permissioned base token would revert inside settlement for an unverified counterparty
anyway, and gating on the same registry turns that late, opaque revert into an early, named one.

**Checked at settlement, not only at creation.** A maker whose verification lapses while their order
rests stops trading immediately, with no one having to sweep the book.

**Fails closed.** A registry that reverts, returns nothing, or has no code at all blocks the trade
rather than waving it through — `EligibilityCheckUnavailable`, never a silent pass.

**Exits are never gated.** `cancelOrder`, `batchCancelOrders` and `withdraw` stay open to a
de-listed address. A compliance gate stops new trading; it does not confiscate.

---

## Governance and roles

| Role | Holds | Does |
| --- | --- | --- |
| `DEFAULT_ADMIN_ROLE` | multisig behind a timelock | the role graph itself |
| `ADMIN_ROLE` | multisig | global pause, fee schedules, **proposes** the risky changes |
| `OPERATOR_ROLE` | multisig or ops key | lists offerings and settlement assets, size bands, per-offering pause, compliance force-cancel |
| `APPROVER_ROLE` | a **different** key | the second pair of eyes |
| `UPGRADER_ROLE` | timelock + multisig | authorizes UUPS upgrades |

`initialize` refuses an approver equal to the admin: the split is structural, not a policy hope.

### Four eyes

Four actions take a proposal by the owning role and an approval by an `APPROVER_ROLE` holder **who
is not the proposer**. Each proposal binds its exact parameters — approve a different offering or a
different address and there is simply no such proposal — and lapses after `PROPOSAL_TTL` (7 days).

| Action | Why |
| --- | --- |
| `SetOfferingFeeRecipient` | where the venue's revenue lands |
| `CloseOffering` | irreversible, and ends a book; requires the offering paused with an empty book |
| `SetTrustedForwarder` | a forwarder can act as any address here |
| `RescueAssets` | the only path that moves money outward |

### Delayed role grants

Granting a role must be announced with `scheduleRoleGrant` and takes effect only after
`ROLE_GRANT_DELAY` (2 days). Without it, whoever holds a role's admin could grant `APPROVER_ROLE` to
a second address they control and approve their own proposal in the very next call — two signatures,
one person, four eyes in name only.

The delay is one-directional: **granting waits, revoking does not.** A compromised key must be
removable this second. Either the role's admin or an `ADMIN_ROLE` guardian can veto a pending grant,
so the veto does not require the key that scheduled it.

### Governance is never relayed

Every role check, proposal and approval reads `msg.sender` directly. A trusted forwarder can act as
a *trader* — create, fill, cancel, withdraw — but never as a key that runs the venue. Otherwise
whoever controlled the forwarder would hold every role at once, and four eyes would be two.

---

## The two guarantees

Both are enforced on-chain and covered by stateful invariants, not just unit tests.

**1. No offering can spend another's money.**

Every wei the contract holds is either escrow for a specific order (`ethEscrowed`, summed in
`totalEthEscrowed`) or a booked withdrawal (`pendingWithdrawals`, summed in
`totalPendingWithdrawals`). `rescuableAmount()` is the balance minus both, so the emergency path can
only ever reach ETH forced in from outside the protocol. This is what makes a tenant-wide contract
safe to operate rather than a shared accident.

**2. The venue never holds a trading asset.**

Both legs move maker to taker directly, so an ERC-20 balance on this contract is by definition
stray — a mis-sent transfer — and never another offering's float.

---

## Quick start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node 18+ (only for the OpenZeppelin upgrade-safety validator)

### Install

```bash
git clone https://github.com/SimplyTokenized/OTCTradingContract.git
cd OTCTradingContract
forge install
```

### Build and test

```bash
npm test
```

The npm scripts clean before building on purpose: the OpenZeppelin upgrades validator needs a
*full* compilation and refuses to run after an incremental one.

### Configure

```bash
cp .env.example .env
# then edit .env
```

### Deploy

```bash
# 1. The tenant's contract — once.
npm run deploy:sepolia

# 2. One offering per instrument — as often as you list one.
OTC_PROXY=0x... forge script script/CreateOffering.s.sol:CreateOffering --rpc-url $ETH_SEPOLIA_RPC --broadcast
```

---

## Walkthrough

A fund lists a tranche, an investor sells into it, and the operator closes the book.

```solidity
// --- Operator: list the offering ---
uint256 offeringId = otc.createOffering(cfg);          // OPERATOR_ROLE

// --- Maker: rest a SELL, backed by an allowance ---
fundToken.approve(address(otc), 1_000e18);
uint256 orderId = otc.createOrder(
    offeringId, OTCTrading.OrderType.SELL, address(usdc), 1_000e18, 50_000e6
);

// --- Taker: check, then fill part of it ---
(uint256 cpt,, uint256 takerFee, uint256 takerNet,) = otc.quoteFill(orderId, 400e18);
usdc.approve(address(otc), takerNet);                  // on a SELL, takerNet is what the taker pays
otc.fillOrder(orderId, 400e18);                        // both legs settle atomically

// --- Maker: take the rest off the book ---
otc.cancelOrder(orderId);

// --- Operator + approver: pause, then close the offering once its book is empty ---
otc.setOfferingPaused(offeringId, true);               // OPERATOR_ROLE
otc.proposeCloseOffering(offeringId);                  // ADMIN_ROLE
otc.approveCloseOffering(offeringId);                  // APPROVER_ROLE, a different key
```

For a BUY priced in ETH, the maker escrows instead of approving:

```solidity
uint256 escrow = price + (price * makerFeeBps) / 10_000;
otc.createOrder{value: escrow}(offeringId, OTCTrading.OrderType.BUY, address(0), baseAmount, price);
// … and after a fill or a cancel:
otc.withdraw();   // pull-payment: proceeds, refunds and fees are all claimed this way
```

---

## Reading the book

Order ids are indexed **per offering** and **per maker**, so a question about one book never reads
another's. Two shapes, and the difference matters:

```solidity
// A slice of an index — cheap, exact, and what a frontend paginates on.
(uint256[] memory ids, uint256 total) = otc.getOfferingOrders(offeringId, offset, limit);
(uint256[] memory mine, uint256 myTotal) = otc.getMakerOrders(maker, offset, limit);

// A BOUNDED walk for orders that are live right now. It examines at most `maxScan` entries and
// hands back where it stopped, so the call costs what you allowed however long the book has grown.
(uint256[] memory live, uint256 cursor) = otc.scanActiveOrders(offeringId, 0, 200);
while (cursor < otc.offeringOrderCount(offeringId)) {
    (live, cursor) = otc.scanActiveOrders(offeringId, cursor, 200);
}
```

v1's "get all active orders" walked every id the contract had ever issued. Under one contract per
tenant that is a scan of every offering a tenant has ever listed, to answer a question about one of
them — which is why it is gone.

---

## Who pays the gas

By default, whoever calls. Set an ERC-2771 trusted forwarder (four-eyes) and a relayer can pay on a
user's behalf; both paths credit the real sender. Relaying can be switched off again the same way.

A relayed call may **not** carry value: the ETH would be the forwarder's, not the sender's, so
`createOrder` and `fillOrder` refuse it with `RelayedCallCannotCarryValue`. Escrowed BUY+ETH orders
and ETH fills are therefore always self-funded.

---

## API reference

### Trading

| Function | Who | Notes |
| --- | --- | --- |
| `createOrder(offeringId, type, cpToken, baseAmount, cpAmount)` | anyone eligible | `payable` for BUY+ETH |
| `fillOrder(orderId, baseAmount)` | anyone eligible | `payable` for SELL+ETH; partial fills ≥ `minOrderSize` unless taking the remainder |
| `cancelOrder(orderId)` | the maker | never paused, never gated |
| `batchCancelOrders(orderIds)` | the maker | ≤ 200; skips what is not yours |
| `cleanupExpiredOrders(orderIds)` | anyone | refunds the **maker**, not the caller |
| `withdraw()` | anyone owed | pull-payment for all ETH |

### Offerings

| Function | Role |
| --- | --- |
| `createOffering(cfg)` | `OPERATOR_ROLE` |
| `allowCounterpartyToken` / `disallowCounterpartyToken` | `OPERATOR_ROLE` |
| `setOfferingLimits(id, min, max, defaultExpiry)` | `OPERATOR_ROLE` |
| `setOfferingPaused(id, bool)` | `OPERATOR_ROLE` |
| `setOfferingFees(id, makerBps, takerBps)` | `ADMIN_ROLE` |
| `adminCancelOrder` / `adminCancelOrders` | `OPERATOR_ROLE` |
| `pause` / `unpause` | `ADMIN_ROLE` |

### Four-eyes pairs

`proposeSetOfferingFeeRecipient` / `approveSetOfferingFeeRecipient` ·
`proposeCloseOffering` / `approveCloseOffering` ·
`proposeSetTrustedForwarder` / `approveSetTrustedForwarder` ·
`proposeRescueAssets` / `approveRescueAssets` ·
plus `cancelProposal(proposalId)` and the `*ProposalId(...)` helpers that compute what an approval
must match.

### Views

`getOffering` · `getOrder` · `orderBaseToken` · `getRemainingAmount` · `isOrderExpired` ·
`isOrderFundable` · `quoteFill` · `isEligibleToTrade` · `offeringOrderCount` · `makerOrderCount` ·
`getOfferingOrders` · `getMakerOrders` · `scanActiveOrders` · `rescuableAmount` ·
`trustedForwarder` · `roleGrantWindow`

---

## Upgradeability

UUPS, authorized by `UPGRADER_ROLE`. Users hold standing allowances here (and BUY+ETH makers hold
escrow), so whoever holds that role can in principle change the settlement code beneath them. **Put
it behind a Timelock + multisig**, so every upgrade is publicly visible for the delay window and
users can revoke and exit before it lands. Storage is append-only across upgrades, enforced by the
OpenZeppelin upgrades validator in CI.

---

## Testing

```bash
npm test              # the full suite
npm run test:invariant # the stateful properties only
npm run test:gas      # with a gas report
FOUNDRY_PROFILE=lite forge test   # fast feedback while writing code
```

The suite covers offerings and their isolation, the order lifecycle, settlement in both directions
and both assets, compliance including the fail-closed paths, four-eyes governance and the grant
delay, pull-payment settlement against hostile recipients, the paginated views, ERC-2771 relaying,
fuzz tests over amounts and fills, **stateful invariants** over a random walk of many actors across
two offerings, and one regression test per finding of the v2 review (`test/Audit.t.sol`).

---

## Migrating from v1

There is no upgrade path. Storage layout and most of the external API changed, so v2 is deployed
fresh and 1.x instances keep serving their own books until they are drained.

1. Deploy v2 (`DeployOTC`).
2. Recreate each v1 contract as one offering on it (`CreateOffering`).
3. Move the whitelist into a `WhitelistRegistry` — or point the offering at the token's ERC-3643
   identity registry instead, which is usually the better answer.
4. Let v1 orders expire or have their makers cancel them; the v1 contract needs no migration of
   funds, because it never held any (beyond BUY+ETH escrow, which its makers reclaim by cancelling).
5. Point the frontend at the new proxy, with `offeringId` on every call.

See [CHANGELOG.md](CHANGELOG.md) for the full list of breaking changes.

---

## License

MIT — see [LICENSE](LICENSE).
