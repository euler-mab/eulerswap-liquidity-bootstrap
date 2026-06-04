# AGENTS.md

Coding-agent quickstart for this repo. Humans should start at [README.md](README.md).

## What this repo is

A worked, deployable Foundry example that bootstraps **deep stablecoin liquidity without a market maker**. It deploys an Aave/Spark-style **ungoverned (immutable) "mini market"** of Euler vaults with a customisable collateral set, then bootstraps one stablecoin (**RLUSD** in the default config) on top of it with an EulerSwap pool. The pool's swap inventory lives in collateral-only ESCROW vaults (ring-fenced — nothing can be borrowed out of them) while it borrows from the borrowable vaults. One script call deploys everything and renounces all governance. It's reference/deploy code, **unaudited**. The mechanism (collateral-only escrow vaults, borrow-funded inventory, the mini-market flywheel) is explained with diagrams in [README.md](README.md).

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

# Fork tests — mainnet fork, RPC REQUIRED (3 tests: full deploy, a real swap, a stale-feed revert)
MAINNET_RPC_URL=https://... forge test --match-path "test/*.fork.t.sol" -vvv

# Everything that doesn't need an RPC
forge test --no-match-path "test/*.fork.t.sol"

# Single test
forge test --match-test test_deploys_ungoverned_mini_market -vvv
```

The fork test deploys the whole mini market and asserts: every borrowable vault is ungoverned and has its own IRM, the full collateral/LTV matrix is wired, the cross/Lido oracles actually price (wstETH, cbETH, WBTC), inventory sits in the escrows, the operator is installed, the pool quotes ~1:1 minus fee, and a real swap moves inventory through the escrow vaults with no debt taken on. A third test confirms a crypto feed's quote reverts once past its staleness window.

## Deploy (broadcast)

ALWAYS fork-test first. Single entrypoint. The broadcasting EOA becomes the LP / `eulerAccount` and must already hold the seed amounts.

```bash
PRIVATE_KEY=0x... MAINNET_RPC_URL=https://... forge script \
  script/DeployBootstrapMarket.s.sol:DeployBootstrapMarket --rpc-url mainnet --broadcast --slow -vvvv
# broadcaster must hold SEED_USDC of USDC and SEED_STABLE of the bootstrapped stable.
```

## Repo layout

| Path | What lives here |
|---|---|
| [script/BootstrapMarketBase.sol](script/BootstrapMarketBase.sol) | **Everything.** All constants (token addresses, Chainlink feeds, LTV tiers, IRM params, vault-index enums, curve params), the vault/adapter/LTV builders, the pool deploy, asset ordering. Start here. |
| [script/DeployBootstrapMarket.s.sol](script/DeployBootstrapMarket.s.sol) | The single entrypoint — reads `PRIVATE_KEY`, seeds, calls `deployMarket`. |
| [src/Interfaces.sol](src/Interfaces.sol) | Minimal hand-vendored Euler interfaces (EVC, EVault, EdgeFactory, EulerSwap, EulerRouter). Only the functions actually called. |
| [src/HookMiner.sol](src/HookMiner.sol) | CREATE2 salt mining so the pool address encodes the Uniswap V4 hook flags. Runs off-chain. |
| [test/Unit.t.sol](test/Unit.t.sol) | Fork-less unit tests (`_price1to1`, `HookMiner`). |
| [test/DeployBootstrapMarket.fork.t.sol](test/DeployBootstrapMarket.fork.t.sol) | End-to-end mainnet-fork test + swap execution. |
| [viz/index.html](viz/index.html) | Self-contained, dependency-free visualizer — reads a deployed pool over RPC and renders the ring-fenced architecture + EulerSwap depth curve. See [viz/README.md](viz/README.md). |
| `assets/` | README diagrams. |

## The market it builds (default config)

14 vaults deployed via `EdgeFactory`, in this fixed index order (the `BORROW_*` / `ESC_*` constants):

- **Borrowable (controllers, own IRM each):** `USDC`, `USDT`, `STABLE` (RLUSD), `WETH`, `cbBTC`, `WBTC`. Stables 4% APR-at-target, WETH 2.5%, BTC 1%. Each borrowable vault **also doubles as yield-bearing collateral** (a depositor pledges the interest-earning eVault share).
- **Collateral-only (escrow):** `USDC`, `USDT`, `STABLE`, `WETH`, `cbBTC`, `WBTC`, `wstETH`, `cbETH`. "Escrow" = collateral that can't be lent out (non-rehypothecated) — the opt-out, and where the swap inventory *must* live. wstETH/cbETH are escrow-only.
- **Oracles → USD:** Chainlink for USDC/USDT/cbBTC/WBTC/WETH; `FixedRateOracle($1)` for RLUSD; `CrossAdapter` for wstETH (LidoFundamental → WETH → USD) and cbETH (Chainlink cbETH/ETH → WETH → USD), mirroring Euler's PrimeCluster.
- **LTV matrix (63 vault-level pairs, by risk tier — see `_tierLTV`):** stable↔stable 0.95/0.96 · WETH→WETH & BTC→BTC self-correlated 0.90/0.92 · LST→stable 0.85/0.87 · LST→WETH 0.94/0.95 · every other cross 0.80/0.85. Escrow and borrowable forms of an asset share a number; a vault never collateralises its own controller.
- **EulerSwap pool:** pairs `USDC` with `STABLE`; inventory in the two stable escrows, debt in the two stable borrowables. RLUSD (`0x82…`) sorts below USDC (`0xA0…`), so **RLUSD is token0**.

## Conventions

- **Single entrypoint, all logic in the base.** There's one deploy script; `BootstrapMarketBase` does the work. (An earlier two-script split — `DeployNewStableMarket` for FixedRate-priced stables — was folded into the base; the stable is now FixedRate-priced by default. Don't re-add a parallel script; extend the base.)
- **All tunables are top-of-base constants.** Token addresses, feeds, `LTV_*` tiers, `IRM_*`, `CONCENTRATION`, `SWAP_FEE`, and the `BORROW_*` / `ESC_*` vault indices live as labelled constants at the top of `BootstrapMarketBase.sol`. Change them there.
- **Vault-index constants are the single source of order.** `_vaults()`, `_adapters()`, `_ltvs()`, the `Deployment` wiring, and `logDeployment()` all key off the `BORROW_*` / `ESC_*` indices. If you add/remove/reorder a vault, update **all** of them together (see Pitfalls).
- **One IRM instance per borrowable vault.** `deployMarket` deploys a fresh adaptive-curve IRM per controller so each asset gets independent rate state/params. The fork test asserts they're distinct.
- **`eulerAccount == msg.sender`.** The position owner must be the caller — token source for the seeds and the EVC account authorizing the operator. Under `--broadcast` that's the EOA; in fork tests it's the script contract (`lp = address(script)`).
- **Pair sorted by address.** EulerSwap requires `asset0 < asset1`; the base sorts and derives the decimal-adjusted 1:1 price (`_price1to1`), so the stable may sort either side of USDC.
- **`_safeApprove` for non-standard ERC20s.** USDT's `approve` returns no bool — never call `IERC20.approve` on it directly (the bool decode reverts); use `_safeApprove` (or a low-level call in tests).
- **`.fork.t.sol` for RPC-dependent tests; `Unit.t.sol` for the rest.** Keep the split so `--no-match-path "test/*.fork.t.sol"` gives a clean RPC-free run.

## Invariants — do not break

- **Inventory lives in collateral-only escrow vaults.** Nothing can be borrowed *out* of an escrow vault, so the money market can never drain swap liquidity. Don't make the stable inventory borrowable.
- **`require(k == 63)` in `_ltvs()`.** The LTV builder hard-asserts the pair count. If you change the collateral/controller set you must update the loops *and* this count, or the deploy reverts.
- **Vault indices must match `EdgeFactory` return order.** The factory returns vaults in the order they were passed in `_vaults()`; the `BORROW_*` / `ESC_*` constants encode that order and are reused everywhere. A mismatch silently wires the wrong vault.
- **Operator installed before `deployPool`.** `IEVC.setAccountOperator(eulerAccount, pool, true)` must run first, or `deployPool` reverts with `OperatorNotInstalled`.
- **`deployPool` routed through the EVC.** Wrapped in `evc.call(factory, eulerAccount, ...)` because the factory authenticates `_msgSender() == eulerAccount`. Don't call the factory directly.
- **Pool address must encode the V4 hook flags.** The salt is mined (`HookMiner.find`) so the address carries `EULERSWAP_FLAGS` in its low 14 bits. Don't deploy with an unmined salt — it reverts `HookAddressNotValid`.
- **Unleveraged by default.** `equilibriumReserve == seed` and `minReserve == 0`, so a swap only draws inventory down to zero — it **never borrows**. To run leveraged inventory you must raise the equilibrium reserves above the deposited seed AND ensure the borrowable vaults have lender liquidity.
- **Ungoverned == immutable.** `EdgeFactory` renounces all governance (vaults + router). Nothing can be changed after deployment — calibrate everything before mainnet. See the `SECURITY CONSIDERATIONS` header in `BootstrapMarketBase.sol` (and the walkthrough) for the permanent-risk checklist: fixed-$1 RLUSD oracle, passive pool, no caps, wrapped/LST pricing, deployer still owns the pool.

## Common tasks

- **Bootstrap your own stable**: change the `STABLE` constant in `BootstrapMarketBase.sol`. It's priced by `FixedRateOracle($1)` in `_adapters()`; if your token has a Chainlink feed, swap that adapter for a `ChainlinkOracle`. Update `SEED_STABLE` decimals in the entrypoint to match.
- **Add/remove a collateral asset**: touch every layer — add the token constant, add a `BORROW_*`/`ESC_*` index, extend `_vaults()`, `_adapters()`, `_ltvs()` (and fix the `k == 63` count), the `Deployment` struct, and `logDeployment()`. The fork test's LTV/oracle assertions are the safety net.
- **Calibrate before mainnet**: review the parameter table in [README.md](README.md#calibrate-before-mainnet) — seeds, the `LTV_*` tiers, the adaptive-curve `IRM_*` values, `CONCENTRATION`, `SWAP_FEE`, and **verify every Chainlink feed** against docs.chain.link.
- **Add fork-less test coverage**: extend `test/Unit.t.sol`; expose any new `internal` helper via a harness like `PriceHarness`.
- **Visualize a deployed market**: open `viz/index.html` for the Graph/Matrix of the market (renders offline); paste an RPC + the pool address the deploy logged for live reserves + the depth curve. If you changed the collateral set, update the `NODES` list and `buildEdges()` in that file so the Graph/Matrix match (the live state + depth chart read from the pool and need no edits).

## Pitfalls

- **Fork tests fail without `MAINNET_RPC_URL`** — expected. Use `test/Unit.t.sol` (or `--no-match-path "test/*.fork.t.sol"`) for an RPC-free run.
- **`IERC20.approve` reverts on USDT** — it returns no bool; use `_safeApprove` / a low-level call.
- **Cross/LST oracle wiring is subtle** — wstETH and cbETH price through a two-hop `CrossAdapter` (asset → WETH → USD). Verify the Lido/cbETH adapters and the shared WETH adapter; the fork test sanity-checks the resulting USD prices.
- **Changing the collateral set is multi-file** — see "Add/remove a collateral asset"; missing one layer either reverts (`k == 63`) or mis-wires a vault.
- **Default feeds/addresses are mainnet placeholders** — verify everything before broadcasting; the deploy is immutable.
- **Oracle staleness is per-feed** — `STALE_CRYPTO` (3h, ETH/BTC), `STALE_USD`/`STALE_LST_RATE` (25h). It's heartbeat + buffer: a window set *below* a feed's real heartbeat bricks it permanently in an immutable market, so don't over-tighten.
- **Pool isn't registered.** The script deploys + activates the pool but doesn't `registerPool` in the `EulerSwapRegistry` (separate step, needs an ETH validity bond). Not required for swaps or v4 routing, but integrators prefer registered pools. See [docs/WALKTHROUGH.md](docs/WALKTHROUGH.md#registration-is-a-separate-optional-step).

## Where to read more, in order

1. [README.md](README.md) — the idea, the collateral-only vaults, the mini-market framing, diagrams, the parameter table, and the risks.
2. [script/BootstrapMarketBase.sol](script/BootstrapMarketBase.sol) — constants first, then `deployMarket` → `_vaults`/`_adapters`/`_ltvs` → `_deployPool`.
3. [test/DeployBootstrapMarket.fork.t.sol](test/DeployBootstrapMarket.fork.t.sol) — the clearest worked example of the end-to-end flow and what "correct" looks like.
4. [src/Interfaces.sol](src/Interfaces.sol) — the Euler surface area the deploy actually touches.

## Upstream / where things live

Built on [EulerSwap](https://github.com/euler-xyz/euler-swap), the [Euler Vault Kit](https://github.com/euler-xyz/euler-vault-kit), the [EVC](https://github.com/euler-xyz/ethereum-vault-connector), and [evk-periphery](https://github.com/euler-xyz/evk-periphery)'s `EdgeFactory`. The interfaces here are minimal vendored subsets — canonical sources are those repos.
