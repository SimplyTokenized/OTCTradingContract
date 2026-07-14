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

Users interacting with a deployment should understand the following trust assumptions:

- **ProxyAdmin owner** can upgrade the implementation, replacing all contract logic.
- **`ADMIN_ROLE`** can change fees and limits, manage the whitelist and counterparty tokens,
  pause the contract, and — **while paused** — call `emergencyWithdraw` to move any token or ETH
  out of the contract, including funds backing open orders.

For production deployments these roles should be held by a **multisig and/or timelock**, and the
custody arrangement should be published so users can assess counterparty risk.

## Known limitations

- **Fee-on-transfer and rebasing tokens are not supported** and must not be configured as base or
  counterparty tokens; the accounting assumes exact-amount transfers.
- Order-enumeration views (`getActiveOrders`, `getOrdersByToken`) iterate over all orders and are
  intended for off-chain (`eth_call`) use, not on-chain composition.
