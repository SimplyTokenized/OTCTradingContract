# Non-Custodial OTC — Design Concept

How OTCTrading settles trades without holding anyone's assets, and the one place where it must.

> v2 note: everything below is unchanged in spirit from v1, but the *scope* changed. The same
> contract now carries every offering a tenant lists, so "the contract holds nothing" is no longer
> a statement about one book — it is what keeps one book's mistake away from another's money. See
> [§7](#7-many-offerings-one-balance).

---

## 1. Motivation

A custodial OTC venue takes both sides' assets into the contract, holds them while orders rest, and
pays them out on a fill. That is simple, and it is also the shape of most of the money lost in this
space: every resting order is a deposit, so the contract's balance is the sum of everything anyone
has ever failed to withdraw, and one bug reaches all of it.

The alternative is to hold nothing. Makers keep custody; the contract is given permission to move
their assets at the moment a counterparty appears, and does so atomically.

## 2. Model

**An order is an allowance, not a deposit.**

1. The maker approves the contract for their side of the trade.
2. They create an order naming a price and a size. Nothing moves.
3. A taker fills it, whole or in part. In that single transaction the contract calls
   `transferFrom` on both legs — maker to taker, taker to maker — and pays the fees.
4. Cancelling is a state change. No funds move, because none were held.

The contract's ERC-20 balance is zero at the start and end of every transaction. If it ever holds
an ERC-20, someone mis-sent it.

### Settlement math

For a fill of `baseAmount` against an order of `(baseTokenAmount, counterpartyTokenAmount)`:

```
counterparty = baseAmount × counterpartyTokenAmount / baseTokenAmount
makerFee     = counterparty × order.makerFeeBps / 10_000
takerFee     = counterparty × order.takerFeeBps / 10_000
```

| | SELL (maker sells base) | BUY (maker buys base) |
| --- | --- | --- |
| Maker | −`baseAmount` base, +`counterparty − makerFee` | +`baseAmount` base, −`counterparty + makerFee` |
| Taker | +`baseAmount` base, −`counterparty + takerFee` | −`baseAmount` base, +`counterparty − takerFee` |
| Fees | `makerFee + takerFee` | `makerFee + takerFee` |

The division rounds **in the resting maker's favour**: up on a SELL, down on a BUY. On a BUY that is
a requirement rather than a preference — see [§4](#4-native-eth-and-the-one-escrowed-case). A fill
that settles to zero counterparty tokens is refused, or a taker could take base repeatedly while
paying nothing. And a partial fill must be at least the offering's `minOrderSize` unless it takes
the remainder: fees floor, so without a floor on fill size an order could be sliced into fills that
each pay none.

## 3. What it costs

Non-custody is not free, and the honest list is short:

- **A resting order is not guaranteed fillable.** The maker may move their funds or revoke the
  allowance at any moment. Fillability is a transient property, which is why `isOrderFundable` is a
  view for filtering the book and *not* something that deactivates an order.
- **A fill can fail on the maker's leg**, at the taker's gas expense. The frontend filters with
  `isOrderFundable`; the contract does not pretend to guarantee more than it can.
- **There is no "the contract owes you" ledger** for ERC-20. What you are owed is what your
  counterparty transfers when the trade settles.

What it buys: the contract is not a honeypot, a maker's assets stay productive while their order
rests, and a compromise of this contract cannot drain what it was never given.

## 4. Native ETH, and the one escrowed case

Native ETH has no `approve`. Three of the four combinations still work without custody:

| Order | Counterparty asset | Who sends at fill time | Custody |
| --- | --- | --- | --- |
| SELL | ERC-20 | taker, inline | none |
| BUY | ERC-20 | maker, via allowance | none |
| SELL | ETH | taker, as `msg.value` | none |
| **BUY** | **ETH** | the maker — **who is not present** | **escrow** |

A BUY priced in ETH is the exception: the maker's side must be paid in native ETH at a fill they do
not participate in, and nothing can pull ETH from an absent account. So the maker escrows
`counterpartyTokenAmount + makerFee` at creation. It is tracked per order in `ethEscrowed`, spent
only by fills of that order, and credited back to the maker on cancel, cleanup or force-cancel.

**Why BUY fills round down.** The escrow holds exactly `counterpartyTokenAmount + makerFee`. Because
a sum of rounded-down parts never exceeds the rounded-down whole, no sequence of partial fills can
draw past what is there — and the closing fill returns whatever rounding left behind, so escrow
never strands ETH.

## 5. Pull payments

ETH owed to a **resting** party is booked, not sent:

- a maker's proceeds from a SELL priced in ETH,
- a maker's escrow refund on a cancel, cleanup or force-cancel,
- a fee recipient's fees.

They land in `pendingWithdrawals` and are claimed with `withdraw()`. Only the **active caller** —
the taker collecting proceeds or an excess refund — is paid inline.

This is not stylistic. If proceeds were pushed, a maker or fee recipient that reverts on receipt
could make every fill on their order revert, every batch containing it fail, and a compliance
force-cancel impossible. With pull payments, a hostile recipient inconveniences exactly one person:
themselves.

`withdraw()` is never pausable and never gated by compliance. Money already owed is theirs.

## 6. Order validation is permissionless

- **Expiry** is deterministic, so `cleanupExpiredOrders` is open to anyone. There is nothing to
  farm: escrow goes back to the **maker**, never the caller.
- **Underfunding** is transient and therefore *not* grounds for a third party to clear an order.
  Filter with `isOrderFundable` and let the maker cancel.

## 7. Many offerings, one balance

v2's addition to this design. One contract now holds every offering a tenant lists, which makes
"the contract holds nothing" load-bearing in a way it was not when it held one book.

Two properties carry it, and both are invariants in the test suite rather than remarks here:

1. **Every wei is spoken for.** `address(this).balance >= totalEthEscrowed + totalPendingWithdrawals`.
   The rescue path can only take the difference, so it cannot reach a live order's escrow or an
   unclaimed withdrawal — anyone's, on any offering.
2. **The venue holds no trading asset.** Both ERC-20 legs move party to party, so a balance here is
   always stray and never another offering's float.

Plus the structural one: an offering's `baseToken` is fixed for its life, so a SELL on offering A
can only ever move offering A's token.

There is no `receive()` and no `fallback()`. A bare transfer reverts, so ETH cannot enter except
through a path that accounts for it.

## 8. Contract surface

| Concern | Where |
| --- | --- |
| Allowance-backed creation | `createOrder` |
| Atomic settlement | `fillOrder` → `_priceFill` → `_settle` |
| Escrow bookkeeping | `ethEscrowed`, `totalEthEscrowed`, `_drawEscrow`, `_refundEscrow` |
| Pull payments | `pendingWithdrawals`, `totalPendingWithdrawals`, `_creditETH`, `withdraw` |
| Inline payment to the caller | `_sendETH` |
| Reserve check | `rescuableAmount` |
| Fundability | `isOrderFundable` |

## 9. Trade-off accepted

A non-custodial book shows orders that may not be fillable. We consider that strictly better than a
custodial book where every order is fillable because the contract is holding everyone's money — and
we say so in the API rather than hiding it: `isOrderFundable` exists precisely because the guarantee
does not.
