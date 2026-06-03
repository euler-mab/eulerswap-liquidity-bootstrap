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

## The escrow trick

![Why the escrow vault is the trick](../assets/2-mechanism.png)

The swap inventory lives in **collateral-only escrow vaults**. Nothing can be borrowed
*out* of an escrow vault, so the liquidity you've set aside for swappers can never be
drained by the money market — even while you open the borrowable vaults wide to other
users. That ring-fencing is the property that makes the whole structure safe.

When someone swaps USDC in for the stable, their USDC lands in the USDC escrow and the
stable flows out of the stable escrow. Because both legs sit at ~$1, the book stays
roughly 1:1 collateralised the whole way through.

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

Loan-to-value is set per (collateral → controller) pair. The tiers:

| Collateral → Controller | Borrow / Liq LTV | Why |
|-------------------------|:----------------:|-----|
| stable → stable | 0.95 / 0.96 | The loop + cross; stables track each other |
| BTC / WETH → stables | 0.80 / 0.85 | Volatile collateral backing stables |
| stables → WETH | 0.80 / 0.85 | Borrow ETH against stables |
| BTC → WETH | 0.78 / 0.83 | Cross-volatile |
| wstETH / cbETH → stables | 0.85 / 0.87 | LST backing stables |
| **wstETH / cbETH → WETH** | **0.94 / 0.95** | **LST leverage — highly correlated to ETH** |

The high LST→WETH LTV is the classic staked-ETH leverage play: deposit wstETH, borrow
WETH at 0.94, and the position barely moves because wstETH *is* staked ETH. LTV tiers are
informed by Euler's own mainnet PrimeCluster.

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
deepens the exact vault your exit liquidity draws from, not your own stablecoin.

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

# Risks

- This is a **leveraged stablecoin position** when run levered. A depeg drops your
  collateral while debt stays fixed — size LTVs conservatively.
- Borrow cost rises with utilisation; organic borrowers compete for the same liquidity.
- The IRM and Chainlink feed constants are **examples / defaults** — verify and review.
- Ungoverned vaults are **immutable**: nothing can be changed after deployment.
- Unaudited reference code. Fork-test and get a review first.

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
