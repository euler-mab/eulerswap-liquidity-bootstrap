# AGENTS.md

Coding-agent quickstart for this repo. Humans should start at [README.md](README.md).

## What this repo is

A worked, deployable Foundry example that bootstraps **deep stablecoin liquidity without a market maker** by manufacturing exit liquidity out of an Euler lending market. One script call deploys a complete **ungoverned (immutable)** USDC/`<stable>` market — Chainlink oracle adapters, a reactive adaptive-curve IRM, borrowable + collateral-only escrow vaults via the canonical `EdgeFactory`, a salt-mined EulerSwap pool, and the seed LP position — validated against a mainnet fork. It's reference/deploy code, **unaudited**. The full mechanism (the "escrow trick", borrow-funded inventory, the flywheel) is explained with diagrams in [README.md](README.md).

## First-time setup

```bash
forge install                       # pulls submodules: forge-std + euler-price-oracle
cp .env.example .env                # set MAINNET_RPC_URL (+ PRIVATE_KEY only to broadcast)
forge build                         # solc 0.8.27, via-IR, optimizer 800, cancun
```

If `forge install` doesn't fetch the submodules, run `git submodule update --init --recursive`.

## Build, test

```bash
# Build
forge build

# Fork-LESS unit tests — NO RPC required (7 tests: _price1to1 + HookMiner)
forge test --match-path "test/Unit.t.sol"

# Fork tests — mainnet fork, RPC REQUIRED (3 tests: both deploy paths + a real swap)
MAINNET_RPC_URL=https://... forge test --match-path "test/*.fork.t.sol" -vvv

# Everything that doesn't need an RPC
forge test --no-match-path "test/*.fork.t.sol"

# Single test
forge test --match-test test_executes_a_swap_through_escrow_inventory -vvv
```

The fork tests deploy the whole market and assert: vaults are ungoverned, LTVs are wired, inventory sits in the escrows, the operator is installed, the pool quotes ~1:1 minus fee, and a real swap moves inventory through the escrow vaults with no debt taken on.

## Deploy (broadcast)

ALWAYS fork-test first. The broadcaster must already hold the seed amounts; the broadcasting EOA becomes the LP / `eulerAccount` that owns the position.

```bash
# Established stable (USDC/USDT, Chainlink-priced):
PRIVATE_KEY=0x... MAINNET_RPC_URL=https://... forge script \
  script/DeployBootstrapMarket.s.sol:DeployBootstrapMarket --rpc-url mainnet --broadcast --slow -vvvv

# Brand-new stable (FixedRateOracle $1):
PRIVATE_KEY=0x... NEW_STABLE=0xYourToken MAINNET_RPC_URL=https://... forge script \
  script/DeployNewStableMarket.s.sol:DeployNewStableMarket --rpc-url mainnet --broadcast --slow -vvvv
```

## Repo layout

| Path | What lives here |
|---|---|
| [script/BootstrapMarketBase.sol](script/BootstrapMarketBase.sol) | Shared deploy logic — all constants (addresses, feeds, LTVs, IRM, curve params), vault wiring, pool deploy, asset ordering. Start here. |
| [script/DeployBootstrapMarket.s.sol](script/DeployBootstrapMarket.s.sol) | USDC/USDT entrypoint (USDT priced by Chainlink feed). The template for an *established* stable. |
| [script/DeployNewStableMarket.s.sol](script/DeployNewStableMarket.s.sol) | USDC/`<new stable>` entrypoint — prices a brand-new stable with a `FixedRateOracle` pegged to $1. |
| [src/Interfaces.sol](src/Interfaces.sol) | Minimal hand-vendored Euler interfaces (EVC, EVault, EdgeFactory, EulerSwap). Only the functions actually called. |
| [src/HookMiner.sol](src/HookMiner.sol) | CREATE2 salt mining so the pool address encodes the Uniswap V4 hook flags. Runs off-chain. |
| [test/Unit.t.sol](test/Unit.t.sol) | Fork-less unit tests (`_price1to1`, `HookMiner`). |
| [test/DeployBootstrapMarket.fork.t.sol](test/DeployBootstrapMarket.fork.t.sol) | USDC/USDT end-to-end fork test + swap execution. |
| [test/DeployNewStableMarket.fork.t.sol](test/DeployNewStableMarket.fork.t.sol) | New-stable path fork test (mock 18-dp token). |
| `test/mocks/MockERC20.sol` | Stand-in token for the new-stable fork test. |
| `assets/` | README diagrams. |

## Conventions

- **Two entrypoints, one base.** `DeployBootstrapMarket` and `DeployNewStableMarket` both extend `BootstrapMarketBase`; a subclass only supplies the second stablecoin and its price-oracle adapter (Chainlink feed vs `FixedRateOracle`). Everything else — escrow ring-fencing, asset ordering, ungoverned deploy — is shared. Add a new pairing by subclassing, not by forking the base.
- **All tunables are top-of-base constants.** Token addresses, Chainlink feeds, `*_LTV`, IRM params, `CONCENTRATION`, `SWAP_FEE` live as clearly-labelled constants at the top of `BootstrapMarketBase.sol`. Change them there.
- **`.fork.t.sol` for RPC-dependent tests; `Unit.t.sol` for the rest.** Keep this split so `--no-match-path "test/*.fork.t.sol"` gives a clean RPC-free run (CI signal without a key).
- **`eulerAccount == msg.sender`.** The account that owns the position must be the caller — it's the token source for the seeds and the EVC account authorizing the operator. Under `forge script --broadcast` that's the broadcasting EOA; in fork tests it's the script contract itself (`lp = address(script)`).
- **Pair sorted by address.** EulerSwap requires `asset0 < asset1`; the base sorts the pair and derives the decimal-adjusted 1:1 price (`_price1to1`) automatically, so your stable may sort either side of USDC.
- **`_safeApprove` for non-standard ERC20s.** USDT's `approve` returns no bool. Never call `IERC20.approve` directly on it (the bool decode reverts) — use `_safeApprove`, or a low-level call in tests.

## Invariants — do not break

- **Inventory lives in collateral-only escrow vaults.** Swap inventory goes into `escrow: true` vaults; nothing can be borrowed *out* of them, so the money market can never drain swap liquidity. Don't make the stable inventory borrowable.
- **Operator installed before `deployPool`.** `IEVC.setAccountOperator(eulerAccount, pool, true)` must run before the pool is deployed, or `deployPool` reverts with `OperatorNotInstalled`.
- **`deployPool` routed through the EVC.** It's wrapped in `evc.call(factory, eulerAccount, ...)` because the factory authenticates `_msgSender() == eulerAccount`. Don't call the factory directly — it'll revert.
- **Pool address must encode the V4 hook flags.** EulerSwap pools double as Uniswap V4 hooks; the salt is mined (`HookMiner.find`) so the deployed address carries `EULERSWAP_FLAGS` in its low 14 bits. Don't deploy with an unmined salt — `deployPool` reverts `HookAddressNotValid`.
- **The template is UNLEVERAGED by default.** `equilibriumReserve == seed` and `minReserve == 0`, so a swap can only draw inventory down to zero — it **never borrows**. To run leveraged inventory you must *raise the equilibrium reserves above the deposited seed* AND ensure the borrowable vaults have lender liquidity. Don't assume swaps borrow as-is.
- **Ungoverned == immutable.** The `EdgeFactory` renounces all governance (vaults + router). Parameters cannot be changed after deployment — calibrate everything before mainnet.

## Common tasks

- **Bootstrap your own established stable**: change the `USDT` / `FEED_USDT_USD` constants in `DeployBootstrapMarket.s.sol` to your token + feed.
- **Bootstrap a brand-new stable** (no Chainlink feed): use `DeployNewStableMarket` with `NEW_STABLE=0x...`; it prices the token at $1 via `FixedRateOracle`.
- **Calibrate before mainnet**: review the parameter table in [README.md](README.md#calibrate-before-mainnet) — `SEED_*`, `STABLE_*_LTV` / `VOL_*_LTV`, the adaptive-curve `IRM_*` values, `CONCENTRATION`, `SWAP_FEE`, and **verify the Chainlink feed addresses** against docs.chain.link.
- **Add fork-less test coverage**: extend `test/Unit.t.sol`; expose any new `internal` helper via a harness like `PriceHarness`.

## Pitfalls

- **Fork tests fail without `MAINNET_RPC_URL`** — expected. Use `test/Unit.t.sol` (or `--no-match-path "test/*.fork.t.sol"`) for an RPC-free run.
- **`IERC20.approve` reverts on USDT** — it returns no bool; use `_safeApprove` / a low-level call.
- **Default Chainlink feeds are mainnet placeholders** — verify every feed and address for your market before broadcasting; the deploy is immutable.
- **`FEED_STALENESS` is a uniform 24h** across all feeds — lenient; tighten for volatile collateral if you care.

## Where to read more, in order

1. [README.md](README.md) — the idea, the escrow trick, the flywheel, diagrams, the parameter table, and the risks.
2. [script/BootstrapMarketBase.sol](script/BootstrapMarketBase.sol) — the deploy logic top-to-bottom; constants first, then `deployMarket` → `_deployEdge` → `_deployPool`.
3. [src/Interfaces.sol](src/Interfaces.sol) — what Euler surface area the deploy actually touches.
4. The two `*.fork.t.sol` tests — the clearest worked example of the end-to-end flow and what "correct" looks like.

## Upstream / where things live

Built on [EulerSwap](https://github.com/euler-xyz/euler-swap), the [Euler Vault Kit](https://github.com/euler-xyz/euler-vault-kit), the [EVC](https://github.com/euler-xyz/ethereum-vault-connector), and [evk-periphery](https://github.com/euler-xyz/evk-periphery)'s `EdgeFactory`. The interfaces here are minimal vendored subsets — canonical sources are those repos.
