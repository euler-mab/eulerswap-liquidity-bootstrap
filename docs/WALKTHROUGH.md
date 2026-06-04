# Bootstrapping a stablecoin with EulerSwap — a walkthrough

This is the long-form companion to the [README](../README.md): first the *why* (the
strategy), then the *what* (a technical deep-dive on everything this repo deploys). The
example bootstraps **RLUSD**, but every piece is a template you can repoint at your own
stablecoin and your own collateral set.

> ⚠️ Experimental, unaudited reference code. Verify every address and parameter and get a
> review before risking real funds.

---

# Part 1 — The idea

## The market-maker problem

Every team launching a new stablecoin hits the same wall: you need deep, reliable
liquidity so people can get in and out of your token — and the going rate is brutal. A
private market maker will quote you **10–20% a year**, plus inventory risk, plus you're
trusting them with your float. Liquidity mining rents mercenary capital that leaves the
moment emissions dry up. A CEX listing is its own gauntlet.

There's a much cheaper way, and it falls straight out of how EulerSwap works.

![The cost of deep stablecoin liquidity](../assets/1-cost.png)

## Liquidity is just borrowed inventory

When someone holding your stablecoin (call it USDnew) wants out, what they actually need
is USDC on the other side of the trade. That's it. Deep liquidity for USDnew→USDC is
really just a question of having USDC inventory ready to hand out.

And the cheapest USDC inventory in the world is *borrowed* USDC. If USDnew is solid
collateral, borrowing USDC against it costs roughly **3–4% a year** at today's rates.
That borrow rate is your cost of liquidity — and because every swap pays you a fee,
1–2% in swap fees nets you down to **~1–2% a year**. Self-custodied, on-chain, yours.

## Collateral-only vaults

![Collateral-only escrow vaults ring-fence the swap inventory](../assets/2-mechanism.png)

The swap inventory lives in **collateral-only vaults** — in Euler's world these are
*escrow* vaults. An escrow vault does one thing: it holds an asset you can post as
collateral, and **nothing can be borrowed out of it**. Here that collateral does double
duty — it's also the inventory EulerSwap hands to swappers. Because it can never be
borrowed away, your swap liquidity can't be drained by the money market, even with the
borrowable vaults wide open.

Step back and the structure is simpler than it sounds: you're running a leveraged
stablecoin position and **allowing collateral swaps on it**. When someone swaps USDC in
for the stable, their USDC lands in the USDC escrow and the stable flows out of the stable
escrow — they're just swapping between the collateral assets of your position. Because both
legs sit at ~$1, the book stays roughly 1:1 collateralised the whole way through.

## It's a mini Aave/Spark market

![Turn it into a flywheel](../assets/3-flywheel.png)

You can do better than a single-purpose loop. The borrowable vaults accept a **whole
collateral set** — cbBTC, WBTC, WETH, wstETH, cbETH — so outsiders can borrow your
stables (and WETH) against their crypto. It's effectively your own immutable Aave/Spark
instance, with EulerSwap bolted on to provide the bootstrapped exit liquidity.

That organic borrow demand does two things. First, the interest borrowers pay flows to
**lenders**, which makes supplying the vaults attractive, pulls in real lenders, and
deepens the very pool you borrow from. Second, people borrowing and *using* your stable
is exactly the organic demand a new stablecoin is launched to create.

## Capital efficiency

![How little capital this takes](../assets/4-capital-efficiency.png)

At 0.95 LTV both ways the loop is generous — ~20× from stable collateral — and EulerSwap
v2 lets you concentrate the curve inside a tight band around $1 so the same inventory
delivers far more usable depth exactly where stablecoin trades cluster.

---

# Part 2 — What actually gets deployed

One `deployMarket(...)` call ([`BootstrapMarketBase.sol`](../script/BootstrapMarketBase.sol))
builds the whole thing and renounces all governance. Two layers:

1. **An ungoverned mini lending market** — borrowable + escrow vaults, a price router,
   per-vault interest-rate models, an LTV matrix.
2. **An EulerSwap pool** on top that bootstraps one stablecoin's liquidity.

```
                 EulerRouter (Chainlink / FixedRate / Lido-cross adapters, renounced)
                  │
  ┌───────────────┴───────────────────────────────────────────────────────────┐
  │  BORROWABLE (controllers, ungoverned)      COLLATERAL-ONLY (escrow)         │
  │   USDC   USDT   RLUSD   WETH                USDC  USDT  RLUSD   ← swap inv.  │
  │     ▲ accepts as collateral ─────────────▶ cbBTC WBTC WETH wstETH cbETH     │
  │     │  wstETH/cbETH → WETH at high LTV                          ← organic    │
  └───────────────────────────────────────────────────────────────────────────┘
                  │
        EulerSwap pool (USDC / RLUSD): supply = escrows · borrow = borrowable vaults
```

## The lending market

### Assets

| Asset | Borrowable? | Collateral (escrow)? | Role |
|-------|:-----------:|:--------------------:|------|
| USDC  | ✅ | ✅ | Core stable + the pool's other leg |
| USDT  | ✅ | ✅ | Core stable |
| **RLUSD** | ✅ | ✅ | The stablecoin being bootstrapped |
| WETH  | ✅ | ✅ | Borrowable so LSTs can lever into ETH |
| cbBTC | — | ✅ | BTC collateral |
| WBTC  | — | ✅ | BTC collateral |
| wstETH | — | ✅ | Lido LST collateral |
| cbETH | — | ✅ | Coinbase LST collateral |

The stables are borrowable **and** usable as collateral, which is what powers both the
self-loop (deposit USDC, borrow USDC to build inventory) and the cross (borrow RLUSD
against USDC). Editing this set is the "customisable collateral at deploy" knob — add or
drop assets in the vault, adapter and LTV lists.

### Pricing each asset

The market needs every asset priced in a common unit of account (USD = `address(840)`).
Each gets an oracle **adapter**; the ones for the ETH LSTs reuse exactly the cross-adapter
construction Euler runs in its own PrimeCluster.

| Asset | Adapter | Source |
|-------|---------|--------|
| USDC, USDT | `ChainlinkOracle` | Chainlink USDC/USD, USDT/USD |
| **RLUSD** | `FixedRateOracle($1)` | Pegged $1 — a new stable needs no feed |
| cbBTC, WBTC | `ChainlinkOracle` | Chainlink BTC/USD (cbBTC/WBTC ≈ BTC) |
| WETH | `ChainlinkOracle` | Chainlink ETH/USD |
| wstETH | `CrossAdapter` | `LidoFundamentalOracle` (wstETH→ETH) × ETH/USD |
| cbETH | `CrossAdapter` | Chainlink cbETH/ETH × ETH/USD |

A `FixedRateOracle($1)` is the right call for a brand-new stable: it has no Chainlink feed
yet, and pegged-stable health checks against $1 are what you want anyway. If your stable
*does* have a feed, swap in a `ChainlinkOracle` instead.

The cross adapters are validated end-to-end in the fork test — on a recent block they
priced **wstETH/USD ≈ $2,245**, **cbETH/USD ≈ $2,055**, **WBTC/USD ≈ $64,599**.

### Reactive interest rates — one IRM per vault

Each borrowable vault gets its **own** [adaptive-curve IRM](https://github.com/euler-xyz/evk-periphery)
instance. This matters because the market is **immutable**: once governance is renounced
a static kink IRM could never be retuned, so a reactive model that continuously nudges
the rate-at-target up or down to hold utilization near 90% — with no governance — is the
right tool. Per-vault instances let each asset run its own curve:

| Vault | Initial rate @ 90% target | Bounds | Steepness | Adjustment |
|-------|---------------------------|--------|-----------|------------|
| USDC, USDT, RLUSD | 4% APR | 0.1%–200% | 4× | 50/yr |
| WETH | 2.5% APR | 0.1%–200% | 4× | 50/yr |

(Rates are WAD-per-second under the hood; the constants read as `Xe18 / YEAR` = X APR.)

### The LTV matrix

Loan-to-value is set per (collateral → controller) pair. Rows are what you **deposit**,
columns are what you can **borrow** against it; each cell is **borrow LTV / liquidation
LTV** (`—` = not accepted as collateral for that asset). Only USDC, USDT, RLUSD and WETH
are borrowable, so those are the only columns.

| Deposit ↓ \ Borrow → | USDC | USDT | RLUSD | WETH |
|----------------------|:---------:|:---------:|:---------:|:-------------:|
| **USDC**   | 0.95/0.96 | 0.95/0.96 | 0.95/0.96 | 0.80/0.85 |
| **USDT**   | 0.95/0.96 | 0.95/0.96 | 0.95/0.96 | 0.80/0.85 |
| **RLUSD**  | 0.95/0.96 | 0.95/0.96 | 0.95/0.96 | 0.80/0.85 |
| **cbBTC**  | 0.80/0.85 | 0.80/0.85 | 0.80/0.85 | 0.78/0.83 |
| **WBTC**   | 0.80/0.85 | 0.80/0.85 | 0.80/0.85 | 0.78/0.83 |
| **WETH**   | 0.80/0.85 | 0.80/0.85 | 0.80/0.85 | — |
| **wstETH** | 0.85/0.87 | 0.85/0.87 | 0.85/0.87 | **0.94/0.95** |
| **cbETH**  | 0.85/0.87 | 0.85/0.87 | 0.85/0.87 | **0.94/0.95** |

The shape, in words:

- **Stables back stables at 0.95** — the diagonal is the self-loop (USDC→USDC) and the
  off-diagonal is the cross (RLUSD→USDC) that the bootstrap relies on.
- **BTC, ETH and the LSTs back stables** at 0.80–0.85 — this is the organic borrow demand.
- **wstETH / cbETH back WETH at 0.94** — the classic staked-ETH leverage play: deposit
  wstETH, borrow WETH, and the position barely moves because wstETH *is* staked ETH.

These tiers live as named constants (`LTV_STABLE_*`, `LTV_VOL_*`, `LTV_LST_ETH_*`, …) and
are informed by Euler's own mainnet PrimeCluster.

The deploy script (and the fork test) print this matrix **read back from the live vaults**
via `logLTVMatrix` — so what you see on a run is the on-chain truth, not a copy that can
drift from the code:

```
=== On-chain LTV matrix (borrow/liq, percent) | deposit row x borrow column ===
deposit  USDC    USDT    RLUSD   WETH
USDC     95/96   95/96   95/96   80/85
USDT     95/96   95/96   95/96   80/85
RLUSD    95/96   95/96   95/96   80/85
cbBTC    80/85   80/85   80/85   78/83
WBTC     80/85   80/85   80/85   78/83
WETH     80/85   80/85   80/85   -
wstETH   85/87   85/87   85/87   94/95
cbETH    85/87   85/87   85/87   94/95
```

### Ungoverned by construction

The market is assembled through Euler's canonical [`EdgeFactory`](https://github.com/euler-xyz/evk-periphery),
which deploys the router, configures the adapters, deploys the escrow + borrowable vaults,
wires the LTVs, and then **renounces governance on every vault and the router** in the
same call. After it returns, nothing about the market can be changed — the parameters
above are frozen. The escrow vaults are also singletons per asset, so existing Euler
escrow vaults (USDC, WETH, …) are reused rather than duplicated.

## The EulerSwap pool

With the market in place, the script deposits the LP's seed equity into the USDC and
RLUSD escrow vaults (the inventory) and deploys a USDC/RLUSD EulerSwap pool. Three details
worth knowing:

- **Inventory in escrow, debt in the borrowable vaults.** The pool's `supplyVault`s are
  the escrow vaults (ring-fenced inventory); its `borrowVault`s are the borrowable vaults
  it draws debt from when a swap pushes past the inventory.
- **Salt-mined hook address.** EulerSwap pools double as Uniswap V4 hooks, so the pool
  *address* must encode the hook-permission flags in its low 14 bits (`0x28A8`). The
  script mines a CREATE2 salt off-chain ([`HookMiner.sol`](../src/HookMiner.sol)) so the
  deployed address is valid — otherwise `deployPool` reverts `HookAddressNotValid`.
- **Operator install first.** `deployPool` reverts `OperatorNotInstalled` unless the pool
  is authorized as an EVC operator for the LP account *before* deployment, so the script
  predicts the address, calls `setAccountOperator`, then deploys.

### Registration is a separate, optional step

The script deploys and *activates* the pool but does **not** register it in the
`EulerSwapRegistry`, and registration is not needed for the pool to work:

- **Swaps work without it** — `EulerSwapPeriphery` (and a direct `swap`) never consult the
  registry.
- **Uniswap v4 routing works without it** — that comes from `activate()` initialising the
  v4 pool, independent of the EulerSwap registry.

Registration (`EulerSwapRegistry.registerPool{value: bond}(pool)`, called by the
`eulerAccount`) makes the pool **discoverable inside EulerSwap's ecosystem** (the EulerSwap
UI and registry-indexing routers) and enrols it in the validity-bond / challenge mechanism.
That mechanism is exactly why **integrators prefer registered pools**: the bond plus
on-chain validity checks signal the pool actually works, and anyone can challenge a dead or
broken pool to claim its bond — so the registry stays curated of live, functioning pools.
So while registration is optional for the pool to *function*, in practice you'll want to
register if you want aggregators and routers to pick up your liquidity. Two things to know
before relying on it:

- it requires a **native-token validity bond** (`>= minimumValidityBond`), so a reference
  script shouldn't do it unconditionally; and
- the registry checks every supply/borrow vault against its curator-set
  `validVaultPerspective` (`isVerified`). A bespoke market's vaults must satisfy that
  perspective or `registerPool` reverts with `InvalidVaultImplementation` — verify on a
  fork before counting on it.

### Asset ordering and the 1:1 price

EulerSwap requires `asset0 < asset1` by address. RLUSD (`0x82…`) sorts *below* USDC
(`0xA0…`), so in the pool RLUSD is token0 and USDC is token1 — and the base sorts the
pair automatically, because your stable could land either side of USDC. The decimal
adjustment is handled too: USDC is 6-dp and RLUSD is 18-dp, so the 1:1 human price becomes
`priceX/priceY = 10^(dec1 − dec0)`. (`_price1to1` and the ordering logic have fork-less
unit tests in [`test/Unit.t.sol`](../test/Unit.t.sol).)

The pool is configured near-constant-sum (`concentration = 0.9999`) for a tight $1 peg
with a 1 bps fee. On a recent fork it quoted **100,000 USDC → 99,988.89 RLUSD**, and the
swap test executes that trade for real, confirming the output leaves the RLUSD escrow and
the input enters the USDC escrow with **zero debt** (inventory alone covers it).

---

# Part 3 — The economics

Run the example unlevered, 1:1, and the pool simply trades out of its $1M of seeded
inventory. The interesting regime is leverage: raise the equilibrium reserves so the pool
borrows from the borrowable vaults to service larger flow. Then:

- **Cost of liquidity = the borrow rate** on the stable you draw down — ~3–4% today.
- **Minus swap fees** you earn on the volume — ~1–2%.
- **≈ 1–2% net**, versus 10–20% for a market maker on the same depth.

Borrowing requires those borrowable vaults to have lender liquidity — which is the whole
point of opening the mini-market to cbBTC/WBTC/WETH/LST collateral: organic borrowers and
yield-seeking lenders deepen the book you draw on. If you'd rather kick-start that supply
with incentives, they go on the asset you *borrow* (USDC/USDT) — rewarding lenders there
deepens the exact vault your exit liquidity draws from, not your own stablecoin. And those
same rewards do double duty: one spend bootstraps both your exit liquidity *and* the
lending market itself, which then generates its own organic demand and fees.

---

# Part 4 — Run and verify

```bash
forge install                       # forge-std + euler-price-oracle
cp .env.example .env                # set MAINNET_RPC_URL (+ PRIVATE_KEY to broadcast)

# Full end-to-end validation against a mainnet fork:
MAINNET_RPC_URL=https://... forge test -vvv

# Broadcast for real (deployer must hold SEED_USDC + SEED_STABLE):
forge script script/DeployBootstrapMarket.s.sol:DeployBootstrapMarket \
  --rpc-url mainnet --broadcast --slow -vvvv
```

The fork tests assert: every borrowable vault is ungoverned; each has its own distinct
IRM; the LTV matrix is wired (including the high LST→WETH tier); the cross/Lido oracles
price correctly; the inventory sits in escrow; the pool is an authorized operator; the
pool quotes ~1:1; and a real swap moves through the escrow inventory. Plus fork-less unit
tests for the price math and hook miner.

---

# Part 5 — Make it yours

- **Bootstrap your stablecoin.** Change the `STABLE` constant in `BootstrapMarketBase.sol`
  to your token. It's priced by `FixedRateOracle($1)`; swap in a `ChainlinkOracle` if it
  has a feed. Ordering and decimals are handled for you.
- **Customise the collateral.** Add or remove assets in `_vaults`, `_adapters` and `_ltvs`.
  Keep the vault-index constants in sync; that's all the LTV matrix keys off.
- **Tune per-asset rates.** Each borrowable vault already gets its own IRM via
  `_deployIRM(initialRate)` — give any asset its own curve.

---

# Security considerations

This is unaudited reference code, and — more importantly — the market is **immutable**
once deployed: all governance is renounced, so no parameter or oracle can be patched
afterwards. Immutability is the selling point, but it magnifies every choice, because
there is no on-chain remediation. A self-review (in the style of an audit) surfaced the
points below; deploy nothing of value without consciously accepting or fixing each. They
are also recorded in the `SECURITY CONSIDERATIONS` header of `BootstrapMarketBase.sol`.

**Oracles**

- **Hard-coded $1 on the bootstrapped stable.** RLUSD is priced at a fixed $1 (a
  `FixedRateOracle`) and accepted as 0.95 collateral. Solvency therefore *assumes* RLUSD
  never trades materially below $1 — a downward depeg lets it be over-borrowed against,
  creating bad debt with no recourse. For a peg you don't fully trust, use a market feed
  and/or a lower LTV for that asset.
- **Wrapped/LST pricing.** cbBTC/WBTC are priced 1:1 with BTC; wstETH/cbETH via on-chain
  LST exchange rates (the way Euler's PrimeCluster does it). Both ignore secondary-market
  or bridge depegs. LTVs are haircut for this, but the assumption is permanent.
- **Staleness.** Windows are set per feed (heartbeat + buffer), not a uniform day — a
  window below a feed's real heartbeat would brick it permanently, so they err slightly
  loose. A Chainlink aggregator deprecation would likewise permanently brick that adapter.

**The pool**

- **Passive by design.** The EulerSwap pool has no oracle hook, so it quotes ~1:1 even
  through a depeg and bleeds the pegged-up side to arbitrageurs (loss-versus-rebalancing).
  Attach a dynamic-fee / rebalancing hook before deploying meaningful size.
- **Ungoverned market, governed position.** The vaults are immutable, but the
  `eulerAccount` (the deployer) still owns the pool and can reconfigure it — fees,
  reserves, even an arbitrary `swapHook`. Treat that key as the trust root; use a
  dedicated sub-account or multisig.

**The market**

- **No caps.** EdgeFactory does not set supply/borrow caps, so exposure is unbounded and
  can't be capped later. Deploy vaults manually first if you need caps.
- **Leverage.** Run levered, this is a leveraged stablecoin position: a depeg drops your
  collateral while debt stays fixed. Size LTVs conservatively and watch utilisation.
- **Thin liquidation buffers** on the aggressive tiers (stable cross 0.95/0.96, LST→WETH
  0.94/0.95) can make liquidations unprofitable in a fast move.

The deploy script asserts each vault holds its expected asset before wiring the pool, and
prints the live LTV matrix — but the economic assumptions above are yours to own. Fork-
test, add adversarial tests (depeg → bad debt, stale-feed revert), and get a real review.

---

# Code map

| File | What it is |
|------|-----------|
| [`script/BootstrapMarketBase.sol`](../script/BootstrapMarketBase.sol) | The market + pool builder; all config (assets, feeds, LTVs, IRMs) lives here |
| [`script/DeployBootstrapMarket.s.sol`](../script/DeployBootstrapMarket.s.sol) | Thin entry: seed amounts + `run()` |
| [`src/Interfaces.sol`](../src/Interfaces.sol) | Minimal vendored Euler interfaces |
| [`src/HookMiner.sol`](../src/HookMiner.sol) | CREATE2 salt mining for valid V4 hook addresses |
| [`test/DeployBootstrapMarket.fork.t.sol`](../test/DeployBootstrapMarket.fork.t.sol) | End-to-end mainnet-fork validation |
| [`test/Unit.t.sol`](../test/Unit.t.sol) | Fork-less unit tests (price math, hook miner) |

Built on [EulerSwap](https://github.com/euler-xyz/euler-swap),
[Euler Vault Kit](https://github.com/euler-xyz/euler-vault-kit), the
[EVC](https://github.com/euler-xyz/ethereum-vault-connector),
[euler-price-oracle](https://github.com/euler-xyz/euler-price-oracle), and
[evk-periphery](https://github.com/euler-xyz/evk-periphery)'s `EdgeFactory`.
