# Market visualizer

A single self-contained HTML page that reads a **deployed** bootstrap market over RPC and
renders two things the generic Euler lending UIs don't: the **ring-fenced architecture**
(which vaults are borrowable vs collateral-only escrow, and where the swap inventory sits)
and the **EulerSwap liquidity depth** around the $1 peg.

No build, no server, no `node_modules` — [`index.html`](index.html) pulls `viem` from a CDN
and runs entirely in the browser. Read-only: it never sends a transaction.

## Run

```bash
open viz/index.html                     # macOS — or just double-click the file
# or serve it (any static server), e.g.
python3 -m http.server -d viz 8080      # then open http://localhost:8080
```

Then fill in:

| Field | Notes |
|---|---|
| **RPC URL** | A mainnet RPC (the pool's chain). Stays in your browser. |
| **Pool address** | The EulerSwap pool address logged by the deploy script (`EulerSwap pool:`). |
| **USDC / stable** | Prefilled with USDC + RLUSD; change if you bootstrapped a different pair. |

The **architecture panel renders without a connection** (it's the static market shape from
`BootstrapMarketBase`). The **live state** and **depth chart** appear once a reachable RPC +
deployed pool are loaded. You can also deep-link: `index.html?rpc=…&pool=0x…` auto-loads.

## What the depth chart shows

- **x-axis** — execution price (USDC per stable), centred on the $1 peg, auto-scaled to ±N bps.
- **y-axis** — cumulative dollars tradable to push the *marginal* price out to that level.
- **Two arms** — left = selling the stable for USDC (price < 1), right = buying it (price > 1).

It's derived by finite-differencing `computeQuote` across growing trade sizes: each step's
`Δout/Δin` is the marginal price, plotted against the cumulative notional. With concentration
≈ 1 the curve stacks almost all depth within a hair of $1; it tops out at the seeded inventory
because this template is unleveraged (it draws inventory down to the equilibrium reserves and
doesn't borrow). The summary table reports depth available within ±1/2/5/10/20 bps of peg —
note that the 1 bp swap fee means nothing executes closer than ~1 bp to the peg.

## Customising

If you change the market in `BootstrapMarketBase.sol` (different stable, collateral set, LTVs),
edit the `ARCH` config object near the top of the `<script>` in `index.html` so the architecture
panel matches. The live state + depth chart read everything from the pool, so they need no edits.

> Read-only reference tooling. It reads on-chain state; it never signs or sends anything.
