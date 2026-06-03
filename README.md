# Bootstrapping stablecoin liquidity with EulerSwap

A worked, deployable example of bootstrapping deep stablecoin liquidity **without a
market maker** — by manufacturing exit liquidity out of an Euler lending market.

The script in [`script/DeployBootstrapMarket.s.sol`](script/DeployBootstrapMarket.s.sol)
deploys, in one run on Ethereum mainnet, a complete **ungoverned** (immutable)
**Aave/Spark-style mini lending market** — your own money market with a customisable
collateral set — and then bootstraps liquidity for one stablecoin on top of it with
EulerSwap. The example bootstraps **RLUSD** (paired with USDC, alongside USDT as a core
asset); change one constant to bootstrap your own. Validated end-to-end on a mainnet fork.

> ⚠️ **Experimental, unaudited reference code.** Verify every address and parameter,
> fork-test, and get a review before risking real funds. See [Risks](#risks).

📖 **Want the full story?** The [**walkthrough**](docs/WALKTHROUGH.md) covers the strategy
*and* a technical deep-dive on everything deployed; the [**blog post**](docs/blog-post.md)
is the narrative version.

---

## The idea

Every team launching a new stablecoin hits the same wall: you need deep, reliable
liquidity so people can get in and out of your token — and a private market maker
will quote you **10–20% a year**, plus inventory risk, plus custody of your float.

There's a much cheaper way, and it falls straight out of how EulerSwap works.

![Cost comparison](assets/1-cost.png)

**Liquidity is just borrowed inventory.** When someone holding your stablecoin wants
out, what they need is USDC on the other side. The cheapest USDC inventory in the
world is *borrowed* USDC: if your stable is solid collateral, borrowing USDC against
it costs ~3–4% a year. That borrow rate is your cost of liquidity — and swap fees you
earn offset most of it, often down to ~1–2% net.

### The escrow trick

![Mechanism](assets/2-mechanism.png)

The swap inventory lives in **collateral-only escrow vaults**. Nothing can be borrowed
*out* of an escrow vault, so your swap liquidity can never be drained by the money
market — even while you open the borrowable vaults to other users.

### It's a mini Aave/Spark market for your stablecoin

![Flywheel](assets/3-flywheel.png)

The borrowable vaults accept a **customisable collateral set** — here cbBTC, WBTC, WETH,
wstETH and cbETH — so outsiders can borrow your stables (and WETH) against their crypto.
wstETH/cbETH can borrow WETH at a high, correlated LTV (the classic LST-leverage play).
That organic borrow demand pays interest to lenders (deepening the pool you borrow from)
and builds genuine demand for the stable you're launching. It's effectively your own
immutable Aave/Spark instance, with EulerSwap providing the bootstrapped exit liquidity.

### Capital efficiency

![Capital efficiency](assets/4-capital-efficiency.png)

At 0.95 LTV both ways the loop is generous (~20× from stable collateral), and EulerSwap
v2 lets you concentrate the curve inside a tight band around $1 for maximum depth where
trades actually cluster.

---

## What the script deploys

```
                 EulerRouter (Chainlink / FixedRate / Lido-cross adapters, renounced)
                  │
  ┌───────────────┴───────────────────────────────────────────────────────────┐
  │  BORROWABLE (controllers, ungoverned)      COLLATERAL-ONLY (escrow)         │
  │  ┌──────┐ ┌──────┐ ┌───────┐ ┌──────┐      ┌──────┐┌──────┐┌───────┐        │
  │  │ USDC │ │ USDT │ │ RLUSD │ │ WETH │      │ USDC ││ USDT ││ RLUSD │  ← swap │
  │  └──────┘ └──────┘ └───────┘ └──────┘      └──────┘└──────┘└───────┘  inv.   │
  │      ▲ accepts as collateral ────────────▶ ┌──────┐┌──────┐┌──────┐┌──────┐ │
  │      │  (wstETH/cbETH → WETH at high LTV)   │cbBTC ││ WBTC ││wstETH││cbETH │ │
  │                                            └──────┘└──────┘└──────┘└──────┘ │
  │                                                + WETH escrow      ← organic │
  └───────────────────────────────────────────────────────────────────────────┘
                  │
        EulerSwap pool (USDC / RLUSD)
        supply = escrows (inventory) · borrow = borrowable vaults (debt)
```

In one `deployMarket(...)` call:

1. **Price adapters → USD**: Chainlink for USDC/USDT/cbBTC/WBTC/WETH, `FixedRateOracle($1)`
   for RLUSD, and Euler's own wstETH/cbETH **cross adapters** (Lido / Chainlink × ETH-USD).
2. **A reactive adaptive-curve IRM per borrowable vault** — each self-tunes its rate
   toward target utilization (the right choice for an immutable market that can never be
   retuned), with its own curve per asset (stables vs ETH).
3. **An Edge market** via the canonical `EdgeFactory`: borrowable USDC/USDT/RLUSD/WETH +
   collateral-only escrow vaults (USDC/USDT/RLUSD/cbBTC/WBTC/WETH/wstETH/cbETH), a fresh
   `EulerRouter`, the full LTV matrix — then **all governance renounced** (immutable).
4. **The seed LP equity** deposited into the USDC + RLUSD escrow vaults (the inventory).
5. **A USDC/RLUSD EulerSwap pool** whose inventory sits in the escrows (ring-fenced) and
   which borrows from the borrowable vaults. The address is **salt-mined** for valid
   Uniswap V4 hook flags, and installed as an EVC operator before deployment.

All addresses, feeds, the collateral set, LTV tiers, IRM and curve parameters live in
clearly-labelled constants in [`BootstrapMarketBase.sol`](script/BootstrapMarketBase.sol).

---

## Run it

```bash
forge install                       # forge-std + euler-price-oracle
cp .env.example .env                # set MAINNET_RPC_URL (+ PRIVATE_KEY to broadcast)

# 1. Validate end-to-end against a mainnet fork (deploys everything, asserts a quote):
MAINNET_RPC_URL=https://... forge test --match-path "test/*.fork.t.sol" -vvv

# 2. Broadcast for real (the deployer must already hold SEED_USDC + SEED_STABLE):
forge script script/DeployBootstrapMarket.s.sol:DeployBootstrapMarket \
  --rpc-url mainnet --broadcast --slow -vvvv
```

The fork tests deploy the full market and assert the vaults are ungoverned, the LTV
matrix is wired, the cross/Lido oracles price correctly, the inventory is in escrow, the
operator is installed, the pool quotes ~1:1, and a real swap moves through the escrows.

---

## Slot in your own stablecoin

To bootstrap *your* stable instead of RLUSD, change the `STABLE` constant in
[`BootstrapMarketBase.sol`](script/BootstrapMarketBase.sol) to your token's address. It's
priced by a `FixedRateOracle($1)` (a pegged stable needs no feed); swap in a
`ChainlinkOracle` if it has one. The base **sorts the USDC pair by address** (your stable
may fall either side of USDC) and derives the decimal-adjusted 1:1 price automatically
(6- or 18-dp). The collateral set is just as editable — add or drop assets in the vault,
adapter and LTV lists.

---

## Calibrate before mainnet

The defaults are sensible starting points, **not** tuned values. Review:

| Parameter | Default | Notes |
|-----------|---------|-------|
| `STABLE` | RLUSD | The stablecoin you're bootstrapping. Change to yours. |
| `SEED_USDC` / `SEED_STABLE` | 1M each | Your real LP equity (the inventory). |
| `LTV_STABLE_*` | 0.95 / 0.96 | Stable-vs-stable; drives the loop & cross. |
| `LTV_VOL_*` | 0.80 / 0.85 | BTC / ETH → stables, stables → WETH. |
| `LTV_LST_ETH_*` | 0.94 / 0.95 | wstETH / cbETH → WETH (high, correlated). |
| `LTV_LST_STABLE_*` | 0.85 / 0.87 | wstETH / cbETH → stables. |
| `IRM_*` (adaptive curve) | 4% APR @ 90% target | Reactive — self-adjusts toward target utilization (no governance). Canonical values; review per market. |
| `CONCENTRATION` | 0.9999e18 | Higher = tighter peg / deeper near $1. |
| `SWAP_FEE` | 1 bps | The fee that offsets borrow cost. |
| Chainlink feeds | mainnet | **Verify** against docs.chain.link; cbBTC/WBTC use BTC/USD. |

**Leverage:** this template seeds equity 1:1 (eq reserves = deposits). To run the
leveraged inventory described above you raise the equilibrium reserves and let the pool
borrow from the borrowable vaults — which requires those vaults to have lender liquidity
(seed it yourself, or let organic collateral borrow demand attract lenders first).

---

## Risks

- This is a **leveraged stablecoin position**. A depeg drops your collateral while debt
  stays fixed — size LTVs conservatively.
- USDC borrow cost rises with utilisation; organic borrowers compete for the same USDC.
- The adaptive-curve IRM uses canonical values and the Chainlink feed constants are
  defaults — verify and review for your market.
- Ungoverned vaults are **immutable**: parameters cannot be changed after deployment.
- Unaudited reference code. Fork-test and get a review first.

---

## Layout

```
script/BootstrapMarketBase.sol       # the mini market + pool builder (all config here)
script/DeployBootstrapMarket.s.sol   # thin entry: seeds + run()
test/DeployBootstrapMarket.fork.t.sol# end-to-end mainnet-fork validation
test/Unit.t.sol                      # fork-less unit tests (price math, hook miner)
src/Interfaces.sol                   # minimal vendored Euler interfaces
src/HookMiner.sol                    # CREATE2 salt mining for V4 hook flags
assets/                              # the diagrams above
```

Built on [EulerSwap](https://github.com/euler-xyz/euler-swap),
[Euler Vault Kit](https://github.com/euler-xyz/euler-vault-kit), the
[EVC](https://github.com/euler-xyz/ethereum-vault-connector), and
[evk-periphery](https://github.com/euler-xyz/evk-periphery)'s `EdgeFactory`.
