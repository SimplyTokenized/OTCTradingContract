# Security Policy

## Audit status

- **Internal review:** Completed. Findings and their remediations are tracked in the project history.
- **Independent external audit:** ❌ Not yet performed.

> This code has **not** been audited by an independent third party. Do not deploy it to a
> production network with real funds until a reputable external audit has been completed and
> its findings resolved.

## Supported versions

This repository targets a single, actively developed implementation. Security fixes are applied
to the `main` branch. There are no long-term support branches for older revisions.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report privately using one of:

- GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
  ("Report a vulnerability" under the repository's **Security** tab), or
- Email the maintainers at **security@simplytokenized.example** *(replace with a monitored address before publishing)*.

Please include:

- A description of the issue and its impact.
- Step-by-step reproduction, ideally a failing Foundry test or PoC.
- Affected contract(s), function(s), and commit hash.
- Any suggested remediation.

### What to expect

- **Acknowledgement:** within 3 business days.
- **Assessment & triage:** within 10 business days, including a severity rating.
- **Coordinated disclosure:** we will agree on a disclosure timeline with you and credit you
  (if desired) once a fix is released.

Please give us a reasonable opportunity to remediate before any public disclosure.

## Trust model & privileged roles

The contract is **non-custodial**: orders are backed by allowances, so it holds no ERC-20 funds at
rest. The only funds it holds are native-ETH escrow for BUY-in-ETH orders and unclaimed ETH
withdrawals, both exactly accounted. Users should still understand the following trust assumptions:

- **`UPGRADER_ROLE`** can upgrade the UUPS implementation, replacing all contract logic. Because
  makers grant standing allowances (and BUY+ETH makers escrow ETH), a malicious upgrade could reach
  those balances. This role **must** be held by a Timelock + multisig so upgrades are time-delayed
  and publicly visible, giving users a window to revoke approvals and exit.
- **`ADMIN_ROLE`** can change fees and limits, manage the whitelist and counterparty tokens, pause
  the contract, and **force-cancel** any order (`adminCancelOrder`). A force-cancel only deactivates
  the order and returns any ETH escrow to the **maker** — the admin cannot take funds.

There is **no `emergencyWithdraw`** and no admin path that can move a user's funds to the admin.

For production deployments these roles should be held by a **multisig and/or timelock**, and the
trust arrangement should be published so users can assess counterparty risk.

## Known limitations

- **Fee-on-transfer and rebasing tokens are not supported** and must not be configured as base or
  counterparty tokens; the accounting assumes exact-amount transfers.
- **Allowance-backed orders are not guaranteed fillable:** a maker can move funds or revoke their
  approval, so a fill may revert. This is a UX/liveness concern, not a fund-safety one; use
  `isOrderFundable` to filter the book off-chain. (BUY+ETH orders are escrowed and always fillable.)
- **ETH payouts to resting parties are pull-based** (`pendingWithdrawals` + `withdraw`). A maker or
  fee recipient that cannot receive ETH accrues a claimable balance rather than blocking settlement.
- Order-enumeration views (`getActiveOrders`, `getOrdersByToken`) iterate over all orders and are
  intended for off-chain (`eth_call`) use, not on-chain composition.
- Reentrancy protection uses OpenZeppelin `ReentrancyGuardTransient` (EIP-1153 transient storage).
  The contract **must** be deployed on a Cancun-capable chain; on a pre-Cancun EVM, `nonReentrant`
  calls will revert. This guard holds **zero persistent storage**, so it cannot shift or collide with
  the contract's storage layout across upgrades.
