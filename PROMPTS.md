# Seed prompts

Verbatim prompts for an AI coding agent (Claude Code, Codex, etc.) working in this repo. Each is pre-validated to produce useful output without further clarification.

---

### Set up and verify

> "Set up this repo from scratch (`make setup`), run `make doctor`, then `make test`. Tell me if anything fails and stop."

Expected: agent runs the three commands in order, reports green or pinpoints the first failure.

---

### Understand the design

> "Explain what this repo deploys in three paragraphs — the ungoverned mini market, the EulerSwap pool that pairs against it, and why this gives you deep stablecoin liquidity without an external market maker. Cite specific files in [script/](script/)."

Expected: agent reads README, AGENTS, docs/WALKTHROUGH, and produces a grounded summary citing file paths.

---

### Run the demo against a forked mainnet

> "Run `make demo` to deploy the full bootstrap market against a forked mainnet. Summarize the deployed addresses (lending vaults, oracle adapters, EulerSwap pool) and which assertions passed."

Expected: agent runs the anvil demo, surfaces key addresses + pass/fail per assertion.

---

### Adapt to a different stablecoin

> "I want to bootstrap [stablecoin X] (address [...]) instead of RLUSD. Walk me through the constants and oracle changes needed in [script/BootstrapMarketBase.sol](script/BootstrapMarketBase.sol), then generate the diff."

Expected: agent identifies the `STABLE` constant, swaps in the new address, adjusts the oracle (FixedRateOracle for a pegged stable, or a real feed for non-pegged), generates the diff.

---

### Adapt the collateral set

> "Drop wstETH and cbETH from the collateral matrix and add LBTC instead. Generate the diff, including new oracle wiring and updated LTV configuration."

Expected: agent reads the existing matrix, edits the collateral configuration, wires the new oracle (Chainlink-style feed for LBTC), updates the LTV mapping, generates the diff.

---

### Trace what happens on a real swap

> "Trace what happens when someone swaps 100k USDC for RLUSD against the deployed pool, line by line. Cite the relevant code paths and explain what happens to the deposits/escrows."

Expected: agent reads the EulerSwap source via the submodule + the deployed config, produces a step-by-step trace.

---

### Calibrate before mainnet

> "Read [`docs/WALKTHROUGH.md`](docs/WALKTHROUGH.md) — the calibration section — and check whether the current pool parameters in [`script/BootstrapMarketBase.sol`](script/BootstrapMarketBase.sol) are sensible for a [size of inventory] / [your-token] bootstrap. Flag anything you'd change before broadcasting."

Expected: agent reads the calibration guidance, evaluates the current constants, flags concerns.

---

## Anti-patterns

- **"Deploy this to mainnet."** Never. Mainnet broadcasts are explicit `forge script ... --broadcast` commands run by you with `PRIVATE_KEY` in your own shell, after thorough fork testing.
- **"Audit this market design."** Agents are not auditors. Use them to surface candidate issues you verify yourself; never as the sole security review.
- **"Make my stable production-ready."** Too vague. Specify: oracle choice, LTV target, IRM parameters.
