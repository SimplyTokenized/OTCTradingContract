# Contributing

Thanks for your interest in improving the OTC Trading Contract. This document describes how to
set up the project and the standards we expect for contributions.

## Getting started

```bash
git clone https://github.com/SimplyTokenized/OTCTradingContract.git
cd OTCTradingContract
forge install        # fetches submodules under lib/
forge build
forge test
```

## Development workflow

1. **Branch** off `main` (e.g. `fix/buy-order-fee`, `feat/order-book-view`).
2. Make your change with accompanying tests.
3. Ensure the full checklist below passes locally.
4. Open a pull request describing **what** changed and **why**, and reference any related issue.

Keep pull requests focused: one logical change per PR.

## Checklist before opening a PR

The CI workflow (`.github/workflows/test.yml`) enforces these — run them locally first:

```bash
forge fmt --check     # formatting
forge build --sizes   # compiles, reports contract sizes
forge test -vvv       # all tests pass
```

Additionally, for any non-trivial change:

- [ ] New behavior is covered by tests (happy path **and** failure cases).
- [ ] Security-relevant changes include a regression test.
- [ ] Public interfaces (functions, events, the `Order` struct) changed? Update `README.md` and
      `CAST_COMMANDS.md` so signatures stay accurate.
- [ ] NatSpec comments are added/updated for new or changed external functions.

## Coding standards

- Solidity `0.8.27`; follow the existing style (enforced by `forge fmt`).
- Prefer OpenZeppelin components over bespoke implementations.
- All state-changing external functions that move value must be `nonReentrant` and use
  `SafeERC20` for token transfers.
- Use custom errors or descriptive `require` strings consistent with the existing `OTCTrading:`
  prefix.

## Upgrade safety

This is an upgradeable contract. When changing storage:

- **Never** reorder or remove existing storage variables or `Order` struct fields — only append.
- Validate storage-layout compatibility with the OpenZeppelin upgrades plugin
  (`Upgrades.validateUpgrade`) before proposing an implementation change.

## Reporting security issues

Do **not** file security vulnerabilities as public issues or PRs. Follow [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
