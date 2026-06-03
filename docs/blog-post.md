# How to bootstrap deep stablecoin liquidity without a market maker

## Introduction

Every team launching a new stablecoin hits the same wall: you need deep, reliable liquidity so people can get in and out of your token - and the going rate is brutal. A private market maker will run you 10–20% a year, plus inventory risk, plus you're trusting them with your float. Liquidity mining rents mercenary capital that leaves the moment emissions dry up. A CEX listing is its own gauntlet.

A quick word on what "bootstrapping" means here. Usually it describes a project paying to *onboard* liquidity - emissions, a market-maker retainer, a listing deal. You can run this strategy that way too: instead of supplying the inventory yourself, you incentivise others to supply it. The nuance is *which* asset the incentives sit on - it's the asset you borrow to hand out (USDC or USDT), not your own stablecoin. Reward USDC/USDT lenders and you deepen the exact vault your exit liquidity is drawn from. But the more interesting route is to provide that inventory yourself, by LPing directly - and on EulerSwap that's cheap enough the incentive bill mostly disappears.

Either way the mechanism is the same, and it falls straight out of how EulerSwap v2 works. You manufacture exit liquidity out of a lending market, and the all-in cost can land around 2–3% a year. We'll use **RLUSD** as the worked example throughout - swap in your own stablecoin anywhere you see it.

Here's the idea.

![Market-maker fees vs. manufacturing liquidity on EulerSwap: 10–20% vs ~3–4% gross vs ~1–2% net per year](../assets/1-cost.png)

## Liquidity is just borrowed inventory

When someone holding RLUSD wants out, what they actually need is USDC (or USDT) on the other side of the trade. That's it. Deep liquidity for RLUSD→USDC is really just a question of having USDC inventory ready to hand out.

And the cheapest USDC inventory is borrowed USDC from DeFi protocols like Euler, Aave, or Morpho. If RLUSD is solid collateral, borrowing USDC against it costs roughly 3–4% a year at today's rates. That borrow rate is your cost of liquidity. Nothing else.

## The setup

Deploy four Euler vaults:

- USDC - borrowable
- RLUSD - borrowable
- USDC Escrow - collateral only, can't be borrowed from
- RLUSD Escrow - collateral only

Wire up cross-collateral between them through the EVC, and you've got a self-contained RLUSD⇄USDC money market. (We pair RLUSD with USDC here, but USDT works just as well as the counter-asset - or run both RLUSD⇄USDC and RLUSD⇄USDT pools for wider coverage and better routing.)

The escrow vaults are the trick, and the beauty of EulerSwap v2. Your swap inventory lives there - and because nothing can ever be borrowed out of an escrow vault, the liquidity you've set aside for swappers can't be drained by anyone else, even while the borrowable vaults are wide open. That ring-fencing is what makes the whole structure safe.

![A swap routes through ring-fenced escrow inventory: RLUSD in to escrow, USDC out from borrowed inventory, while the borrowable money market stays separate](../assets/2-mechanism.png)

Now build the position. At 0.95 LTV both ways, the looping math is generous - 1M of stable collateral can back up to ~20×, roughly 20M of borrowed inventory. We'll run it well within that. With ~$2M of equity (say 1M RLUSD + 1M USDC), deposit the RLUSD into its escrow and loop USDC until you hold ~11M USDC in escrow against 10M USDC of debt - about half your borrowing power, leaving a wide health buffer. Net: 11M USDC collateral, 10M debt, 1M RLUSD.

Flip on EulerSwap for the RLUSD→USDC pair, and that 10M of borrowed USDC becomes live exit liquidity. When someone swaps RLUSD in, their RLUSD lands in the RLUSD escrow and USDC flows out to them from inventory. Because both legs sit at ~$1, the book stays roughly 1:1 collateralized the whole way.

## The maths

You're paying interest on 10M of USDC debt. At today's ~3–4% that's roughly $300–400k a year to keep 10M of stable liquidity live and on-chain.

Compare that to a market maker: 10–20% on the same depth, plus spread, plus inventory risk, plus custody of your float. It isn't close.

And it gets cheaper, because every swap pays you a fee. Earn 1–2% annualized in swap fees and you're often down to ~1–2% net - close to free.

## Make it a real money market

You can do better than a single-purpose loop. Let the borrowable USDC and RLUSD vaults accept ETH, BTC and other blue-chips as collateral too. Now outsiders can borrow your stablecoins against their crypto - organic demand.

![The flywheel: outside collateral creates organic borrow demand, borrowers pay interest to lenders, lenders deepen the pool you borrow from, and people use your stablecoin](../assets/3-flywheel.png)

The interest those borrowers pay flows to lenders, which makes supplying USDC genuinely attractive, pulls in real lenders, and deepens the very pool you borrow from. Your liquidity stops leaning on your own capital and starts riding a real, two-sided market. And just as importantly: people borrowing and using RLUSD is exactly the organic demand a new stablecoin is launched to create.

Your swap inventory stays untouched through all of it - it's sitting in escrow, where the money market can't reach it.

## Squeeze it tighter

EulerSwap v2 adds one more lever. You can bound your liquidity to a price range, the way Uniswap v3 users will recognize - but you can go further and shape concentrated, curve-style liquidity inside that range, not just a flat band. For a stablecoin pair you'd pin a tight range around $1 and concentrate everything there, so the same 10M of inventory delivers far more usable depth exactly where every trade happens. Same capital, dramatically more liquidity.

![Capital efficiency: 1M of stable collateral backs up to ~20× borrowing power, and v2 concentrates that depth in a tight band around $1](../assets/4-capital-efficiency.png)

## From a loop to a full lending market

Once you're accepting outside collateral, you're not really running a stablecoin loop any more - you're running a small Aave or Spark. So build it like one.

A production-grade version pairs several stablecoins - USDC, USDT and the one you're launching - all borrowable and all usable as collateral, against a real collateral set: cbBTC, WBTC, WETH, plus the ETH liquid-staking tokens wstETH and cbETH. WETH is borrowable too, which unlocks the most natural source of organic demand on-chain: someone deposits wstETH and borrows ETH against it at a high, correlated LTV (wstETH *is* staked ETH, so the position barely moves). Every one of those borrowers is paying interest into the same vaults your exit liquidity is funded from.

That's the flywheel made concrete: RLUSD ships inside a money market people already want to use, and the borrow demand that market generates is what makes your liquidity cheap. The LST collateral, the BTC, the ETH borrowing - none of it can touch your swap inventory, which stays ring-fenced in escrow the whole time.

## Make it immutable

Here's a property issuers tend to want and rarely get from a market maker: the rails can't change under you. Deploy the vaults ungoverned - governance renounced at creation - and the collateral set, LTVs and oracles are frozen forever. No multisig, no admin key, no governance vote can touch them.

That changes one design decision. If you can never retune the market, you can't lean on a static interest-rate curve that you'd adjust by hand when conditions move. So each borrowable vault gets a reactive (adaptive-curve) interest-rate model instead: it continuously nudges its own rate toward a target utilization, finding the right price for capital on its own. Immutability and a reactive rate model go together - one is what makes the other safe.

## A reference you can deploy today

This isn't hypothetical. There's a complete, fork-tested reference implementation on GitHub:

→ **[github.com/euler-mab/eulerswap-liquidity-bootstrap](https://github.com/euler-mab/eulerswap-liquidity-bootstrap)**

A single Foundry script deploys the entire thing in one transaction - the ungoverned mini-market (USDC/USDT/RLUSD/WETH borrowable; cbBTC, WBTC, WETH, wstETH and cbETH as collateral; a reactive IRM per vault; all governance renounced) and a USDC/RLUSD EulerSwap pool seeded with inventory on top. It uses RLUSD as the worked example; pointing it at your own stablecoin is a one-line change.

It's validated end-to-end against a mainnet fork: the liquid-staking cross-oracles price correctly (wstETH ≈ $2,245, cbETH ≈ $2,055), the pool quotes 100,000 USDC → 99,988.89 RLUSD, and a real swap settles out of the ring-fenced escrow inventory with zero debt. The [walkthrough](https://github.com/euler-mab/eulerswap-liquidity-bootstrap/blob/main/docs/WALKTHROUGH.md) has the full architecture.

## Be honest about the risks

This is a leveraged stable position, so treat it like one:

- If RLUSD depegs, your collateral drops while your debt doesn't. Size LTVs conservatively.
- USDC borrow cost rises with utilization. Organic borrowers deepen the market but also compete for the same USDC, so keep the supply side healthy.
- Watch your health factor.

Cheap isn't free. But for a stablecoin issuer, this turns liquidity bootstrapping from a recurring market-maker invoice into a financing decision you control - one that a healthy money market can largely pay for itself.
