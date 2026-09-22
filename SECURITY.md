# Security Policy

## Audit status

**This code has had an internal review, not an external audit.** The v2 review is recorded in
[AUDIT.md](AUDIT.md): 3 Medium, 3 Low and 3 informational findings, all remediated, each with a
regression test. It was performed by the same party that wrote the code, which is exactly why it is
not a substitute for an independent audit — that remains a precondition for handling real money.

v2 is a substantial rewrite of v1: one contract now carries every offering a tenant lists, which
changes the blast radius of a mistake from one book to all of them. That is why the properties in
[The two guarantees](README.md#the-two-guarantees) are enforced on-chain and covered by stateful
invariants rather than stated in a comment.

## Supported versions

| Version | Supported |
| --- | --- |
| 2.x | ✅ |
| 1.x | ⚠️ security fixes only; no upgrade path to 2.x |

## Reporting a vulnerability

**Do not open a public issue.** Email **security@simplytokenized.com** with:

- the contract and function involved,
- what an attacker gains and what they need to start,
- a proof of concept (a failing Foundry test is ideal),
- your assessment of severity.

### What to expect

| | |
| --- | --- |
| Acknowledgement | within 2 business days |
| Initial assessment | within 5 business days |
| Fix or mitigation plan | within 30 days for high and critical |

We will credit you in the release notes unless you ask us not to. Please give us a reasonable window
to ship a fix before disclosing publicly.

## Trust model and privileged roles

This contract is **not trustless**, and the places where it is not are deliberate and listed here.

| Role | Can | Cannot |
| --- | --- | --- |
| `DEFAULT_ADMIN_ROLE` | change the role graph | move user funds directly |
| `ADMIN_ROLE` | halt the whole venue, set fee schedules (≤ 10%), propose the four-eyes actions | execute them alone |
| `OPERATOR_ROLE` | list offerings and settlement assets, set size bands, halt one offering, force-cancel orders | take funds — a force-cancel returns escrow to the **maker** |
| `APPROVER_ROLE` | approve what someone else proposed | propose |
| `UPGRADER_ROLE` | replace the implementation | be undone once an upgrade lands |

**`UPGRADER_ROLE` is the root of trust.** Users grant this contract standing allowances and BUY+ETH
makers hold escrow in it, so whoever can upgrade can in principle change the settlement code beneath
them. Hold it on a **Timelock + multisig**, so every upgrade is publicly visible for the delay
window and users can revoke and exit before it takes effect. The same applies to
`DEFAULT_ADMIN_ROLE`, which ultimately controls every other role.

### What the governance design buys

- **Four eyes** on the actions that direct value or cannot be undone: redirecting an offering's
  fees, closing an offering, changing the trusted forwarder, and rescuing stray assets. A proposal
  binds its exact parameters, so an approver can never be shown one change and asked to approve
  another, and it lapses after 7 days.
- **Governance is never relayed.** Every role check, proposal and approval reads `msg.sender`, so
  a trusted forwarder can act as a trader but never as a key that runs the venue.
- **A delay on role grants (2 days), none on revocations.** Without it, the role-admin root could
  grant `APPROVER_ROLE` to a second address it controls and approve its own proposal in the next
  call. With it, adding a key is visible before it counts, while a compromised key stays removable
  this second. An `ADMIN_ROLE` guardian can veto a pending grant without holding the key that
  scheduled it.
- **An approver who is not the admin, from the first block.** `initialize` refuses otherwise.

## Guarantees that hold whatever the operator does

- **Exits are never gated and never pausable.** `cancelOrder`, `batchCancelOrders` and `withdraw`
  work for a de-listed maker, on a paused offering, and while the whole venue is halted. A
  compliance gate stops new trading; it does not confiscate.
- **A force-cancel cannot take funds.** An allowance-backed order simply goes inactive; a BUY+ETH
  order's escrow is credited to its **maker**, never the operator, and it emits a distinct event.
- **The rescue path cannot reach user money.** `rescuableAmount(ETH)` is the balance minus every wei
  of live escrow and every booked withdrawal, so an approved rescue can only take ETH forced in from
  outside the protocol.
- **Fee changes are never retroactive.** Each order snapshots its rates at creation.
- **Permissionless cleanup pays the maker**, never the caller, so there is nothing to farm.

## Known limitations

These are accepted trade-offs, not oversights.

- **Fee-on-transfer and rebasing tokens are unsupported**, as base or counterparty assets.
  Settlement moves an exact amount between two parties; a transfer fee would silently short one of
  them. Do not list one.
- **An allowance-backed order is not guaranteed fillable.** A maker may move funds or revoke at any
  time, so `isOrderFundable` is a transient property and a `false` answer does not deactivate
  anything. Filter the book with it off-chain.
- **A BUY priced in ETH is custodial for its escrow.** It is the one case where the contract holds
  money, because nothing can pull native ETH from an absent maker at fill time.
- **No matching engine.** There is no crossing or price-time priority; a taker names the order.
  Ordering within a block is the sequencer's, so two takers racing for the same order is a first-mover
  race, not a fairness guarantee this contract makes.
- **A compliance registry is trusted to answer honestly.** The contract enforces the answer; it does
  not audit the registry. A registry that cannot answer blocks the trade rather than allowing it.
- **`scanActiveOrders` is bounded by design.** Reading a very long book takes several calls; that is
  the price of a view whose cost does not grow with every offering a tenant has ever listed.
- **Fees floor, and the minimum-fill rule is the lever.** A fill settling below `10_000 / feeBps`
  counterparty units pays no fee. Partial fills must be at least the offering's `minOrderSize`, so
  set that minimum such that a minimum fill at any sane price clears the threshold; an offering
  where it does not is misconfigured, not exploited.
- **There is no upper price band.** Fat-finger protection belongs in the client, in human units.

## Testing

```bash
npm test                # full suite: unit, fuzz and stateful invariants
npm run test:invariant  # the invariants alone
npm run slither         # static analysis
```

CI runs `forge fmt --check`, `forge build --sizes`, the full suite under the `ci` profile (1000 fuzz
runs, 500 invariant runs), and the OpenZeppelin upgrade-safety validator on every push.
