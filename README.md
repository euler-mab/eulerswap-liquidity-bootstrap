# Bootstrapping stablecoin liquidity with EulerSwap

A worked, deployable example of bootstrapping deep stablecoin liquidity **without a
market maker** — by manufacturing exit liquidity out of an Euler lending market.

The script in [`script/DeployBootstrapMarket.s.sol`](script/DeployBootstrapMarket.s.sol)
deploys a complete, **ungoverned** (immutable) USDC/USDT market on Ethereum mainnet:
borrowable vaults, collateral-only escrow vaults, a price router, an EulerSwap pool,
and the seed LP position — in one run, validated against a mainnet fork.

> ⚠️ **Experimental, unaudited reference code.** Verify every address and parameter,
> fork-test, and get a review before risking real funds. See [Risks](#risks).

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

### Make it a real money market

![Flywheel](assets/3-flywheel.png)

The borrowable vaults accept **cbBTC and WETH** as collateral too, so outsiders can
borrow your stables against their crypto. That organic borrow demand pays interest to
lenders (deepening the pool you borrow from) and — when the second leg is a new stable
— creates genuine demand for it.

### Capital efficiency

![Capital efficiency](assets/4-capital-efficiency.png)

At 0.95 LTV both ways the loop is generous (~20× from stable collateral), and EulerSwap
v2 lets you concentrate the curve inside a tight band around $1 for maximum depth where
trades actually cluster.

---

## What the script deploys

```
                         EulerRouter (Chainlink adapters, governance renounced)
                          │
   ┌──────────────────────┴───────────────────────────────────────────┐
   │  BORROWABLE (controllers, ungoverned)   COLLATERAL-ONLY (escrow)  │
   │  ┌────────────┐  ┌────────────┐          ┌──────────┐ ┌──────────┐ │
   │  │ eUSDC      │  │ eUSDT      │          │ USDC esc │ │ USDT esc │ │  ← swap inventory
   │  └────────────┘  └────────────┘          └──────────┘ └──────────┘ │
   │        ▲ accepts as collateral ─────────▶┌──────────┐ ┌──────────┐ │
   │                                          │ cbBTC esc│ │ WETH esc │ │  ← organic demand
   │                                          └──────────┘ └──────────┘ │
   └───────────────────────────────────────────────────────────────────┘
                          │
              EulerSwap pool (USDC/USDT)
              supply = escrows (inventory) · borrow = borrowable vaults (debt)
```

In one `deployMarket(...)` call:

1. **Four ChainlinkOracle adapters** (USDC, USDT, cbBTC, WETH → USD).
2. **A kink IRM** for the borrowable stable vaults.
3. **An Edge market** via the canonical `EdgeFactory`: borrowable eUSDC/eUSDT,
   collateral-only escrow vaults for USDC/USDT/cbBTC/WETH, a fresh `EulerRouter`,
   LTVs between them — then **all governance renounced** (vaults + router immutable).
4. **The seed LP equity** deposited into the stable escrow vaults.
5. **A USDC/USDT EulerSwap pool** whose inventory sits in the escrows (ring-fenced)
   and which borrows from the borrowable vaults. The pool address is **salt-mined**
   so it carries valid Uniswap V4 hook flags, and it's installed as an EVC operator
   before deployment.

All Euler infrastructure addresses, token addresses, Chainlink feeds, LTVs, IRM and
curve parameters live in clearly-labelled constants at the top of the script.

---

## Run it

```bash
forge install                       # forge-std + euler-price-oracle
cp .env.example .env                # set MAINNET_RPC_URL (+ PRIVATE_KEY to broadcast)

# 1. Validate end-to-end against a mainnet fork (deploys everything, asserts a quote):
MAINNET_RPC_URL=https://... forge test --match-path "test/*.fork.t.sol" -vvv

# 2. Broadcast for real (the deployer must already hold SEED_USDC + SEED_USDT):
forge script script/DeployBootstrapMarket.s.sol:DeployBootstrapMarket \
  --rpc-url mainnet --broadcast --slow -vvvv
```

The fork test deploys the full market and asserts the vaults are ungoverned, the LTVs
are wired, the inventory is in escrow, the operator is installed, and the pool quotes
~1:1 minus the swap fee.

---

## Slot in your own stablecoin

This is a **template**. To bootstrap *your* stable (call it USDnew) instead of USDT,
change the `USDT` constant to your token's address — the escrow/borrowable/LTV wiring
is identical.

The one thing that differs for a **brand-new** stable: it has no Chainlink feed yet.
Swap its adapter for a **`FixedRateOracle`** pegged to $1 (or your own vetted adapter):

```solidity
// instead of: new ChainlinkOracle(USDnew, USD, feed, staleness)
new FixedRateOracle(USDnew, USD, 1e18); // 1 USDnew = 1 USD (18-dp unit of account)
```

Everything else — the escrow ring-fencing, the borrow-funded inventory, the cbBTC/WETH
collateral, the ungoverned deployment — carries over unchanged.

---

## Calibrate before mainnet

The defaults are sensible starting points, **not** tuned values. Review:

| Parameter | Default | Notes |
|-----------|---------|-------|
| `SEED_USDC` / `SEED_USDT` | 1M each | Your real LP equity (the inventory). |
| `STABLE_*_LTV` | 0.95 / 0.96 | Stable-vs-stable; drives the loop & cross. |
| `VOL_*_LTV` | 0.80 / 0.85 | cbBTC / WETH collateral. |
| `IRM_*` | ~5% @ 90% kink | **Example only** — calibrate with Euler's IRM tooling. |
| `CONCENTRATION` | 0.9999e18 | Higher = tighter peg / deeper near $1. |
| `SWAP_FEE` | 1 bps | The fee that offsets borrow cost. |
| Chainlink feeds | mainnet | **Verify** against docs.chain.link; cbBTC uses BTC/USD. |

**Leverage:** this template seeds equity 1:1 (eq reserves = deposits). To run the
leveraged inventory described above you raise the equilibrium reserves and let the pool
borrow from the borrowable vaults — which requires those vaults to have lender liquidity
(seed it yourself, or let organic cbBTC/WETH borrow demand attract lenders first).

---

## Risks

- This is a **leveraged stablecoin position**. A depeg drops your collateral while debt
  stays fixed — size LTVs conservatively.
- USDC borrow cost rises with utilisation; organic borrowers compete for the same USDC.
- The IRM and Chainlink feed constants are **examples** — verify and calibrate.
- Ungoverned vaults are **immutable**: parameters cannot be changed after deployment.
- Unaudited reference code. Fork-test and get a review first.

---

## Layout

```
script/DeployBootstrapMarket.s.sol   # the deploy (run + deployMarket)
test/DeployBootstrapMarket.fork.t.sol# end-to-end mainnet-fork validation
src/Interfaces.sol                   # minimal vendored Euler interfaces
src/HookMiner.sol                    # CREATE2 salt mining for V4 hook flags
assets/                              # the diagrams above
```

Built on [EulerSwap](https://github.com/euler-xyz/euler-swap),
[Euler Vault Kit](https://github.com/euler-xyz/euler-vault-kit), the
[EVC](https://github.com/euler-xyz/ethereum-vault-connector), and
[evk-periphery](https://github.com/euler-xyz/evk-periphery)'s `EdgeFactory`.
