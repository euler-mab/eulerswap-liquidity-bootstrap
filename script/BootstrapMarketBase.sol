// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkOracle} from "euler-price-oracle/adapter/chainlink/ChainlinkOracle.sol";
import {FixedRateOracle} from "euler-price-oracle/adapter/fixed/FixedRateOracle.sol";
import {CrossAdapter} from "euler-price-oracle/adapter/CrossAdapter.sol";
import {LidoFundamentalOracle} from "euler-price-oracle/adapter/lido/LidoFundamentalOracle.sol";
import {
    IERC20,
    IEVC,
    IEVault,
    IEulerAdaptiveCurveIRMFactory,
    IEdgeFactory,
    IEulerSwap,
    IEulerSwapFactory
} from "../src/Interfaces.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @title  BootstrapMarketBase
/// @notice Deploys an Aave/Spark-style "mini market" of UNGOVERNED Euler vaults, then
///         bootstraps liquidity for one stablecoin on top of it with EulerSwap.
///
/// It's effectively your own immutable lending market with a customisable collateral
/// set chosen at deploy time:
///   • Borrowable stables: USDC, USDT, and the stable you're bootstrapping (RLUSD here)
///   • Borrowable ETH:     WETH
///   • Collateral:         cbBTC, WBTC, WETH, wstETH, cbETH (edit the lists below)
///   • Reactive adaptive-curve IRM, prices via Chainlink / FixedRate / Lido cross
///   • ...then ALL governance renounced — vaults + router are immutable.
///
/// The EulerSwap pool then pairs USDC with the bootstrapped stable; its swap inventory
/// lives in collateral-only ESCROW vaults (ring-fenced — nothing can be borrowed out of
/// an escrow vault) while it borrows from the borrowable vaults.
///
/// To bootstrap YOUR stablecoin, change `STABLE` to your token. It's priced by a
/// FixedRateOracle($1); swap in a Chainlink adapter if it has a feed.
///
/// ─────────────────────────── SECURITY CONSIDERATIONS ───────────────────────────
/// This market is IMMUTABLE once deployed (all governance renounced), so every
/// parameter and oracle below is permanent and cannot be patched. Immutability is the
/// selling point, but it magnifies every choice — there is no on-chain remediation.
/// A deployer MUST consciously accept the following (see docs/WALKTHROUGH.md for the
/// full discussion):
///
///   1. Hard-coded $1 oracle on the bootstrapped stable. RLUSD is priced at a fixed $1
///      and accepted as 0.95 collateral. The market's solvency ASSUMES RLUSD never
///      trades materially below $1; a downward depeg lets it be over-borrowed against,
///      creating bad debt with no recourse. For a peg you don't fully trust, use a
///      market feed and/or a lower LTV for that asset.
///   2. Passive pool. The EulerSwap pool has no oracle hook, so it quotes ~1:1 through a
///      depeg and bleeds the pegged-up side to arbitrageurs (LVR). Attach a dynamic-fee
///      / rebalancing hook before deploying meaningful size.
///   3. No supply/borrow caps. EdgeFactory does not set caps, so exposure is unbounded
///      and cannot be capped later. Deploy vaults manually first if you need caps.
///   4. Wrapped/LST pricing. cbBTC/WBTC are priced 1:1 with BTC, and wstETH/cbETH via
///      on-chain LST exchange rates — both ignore secondary-market/bridge depegs. LTVs
///      are haircut accordingly, but the assumption is permanent.
///   5. Ungoverned market, governed position. The vaults are immutable, but the
///      eulerAccount (the deployer) still OWNS the pool and can reconfigure it (fees,
///      reserves, even install an arbitrary swapHook). Use a dedicated sub-account or
///      multisig, and treat that key as the trust root of the position.
///   6. Oracle staleness. Windows are per-feed (heartbeat + buffer); a Chainlink
///      aggregator deprecation would permanently brick the corresponding adapter.
abstract contract BootstrapMarketBase is Script {
    // ─────────────────────────── Euler mainnet infra ───────────────────────────
    address constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address constant EDGE_FACTORY = 0xA969B8a46166B135fD5AC533AdC28c816E1659Bd;
    address constant EULERSWAP_FACTORY = 0xD05213331221fAB8a3C387F2affBb605Bb04DF5F;
    address constant ADAPTIVE_CURVE_IRM_FACTORY = 0x3EC2d5af936bBB57DD19C292BAfb89da0E377F42;
    address constant USD = address(840); // unit of account (== 0x...0348), 18 decimals

    // ───────────────────────────── Tokens (mainnet) ────────────────────────────
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 dec
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6 dec
    address constant STABLE = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD; // RLUSD, 18 dec — the one we bootstrap
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf; // 8 dec
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // 8 dec
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // 18 dec
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // 18 dec
    address constant CBETH = 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704; // 18 dec

    // ─────────────────── Chainlink feeds (mainnet aggregators) ──────────────────
    // VERIFY against https://docs.chain.link/data-feeds/price-feeds/addresses.
    // cbBTC + WBTC are priced off BTC/USD. wstETH uses Lido x ETH/USD (Euler's setup);
    // cbETH uses cbETH/ETH x ETH/USD. RLUSD uses a FixedRateOracle($1).
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant FEED_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant FEED_CBETH_ETH = 0xF017fcB346A1885194689bA23Eff2fE6fA5C483b;

    // Per-feed staleness = the feed's heartbeat + a margin. Set PER FEED, not uniform:
    // ETH/USD and BTC/USD update ~hourly, so a day-long window would accept stale prices.
    // NOTE: in an IMMUTABLE market, a window set BELOW the real heartbeat bricks the feed
    // permanently, so these are heartbeat + buffer (deliberately not ultra-tight). Verify
    // each feed's heartbeat and tighten to your risk appetite before deploying.
    uint256 constant STALE_CRYPTO = 3 hours; // ETH/USD, BTC/USD (~1h heartbeat)
    uint256 constant STALE_USD = 25 hours; // USDC/USD, USDT/USD (~24h heartbeat)
    uint256 constant STALE_LST_RATE = 25 hours; // cbETH/ETH exchange-rate feed (~24h heartbeat)

    // ───────────────────────────── LTV tiers (1e4) ─────────────────────────────
    uint16 constant LTV_STABLE_B = 0.95e4; // stable <-> stable (the loop / cross)
    uint16 constant LTV_STABLE_L = 0.96e4;
    uint16 constant LTV_VOL_B = 0.80e4; // BTC/ETH -> stables, stables -> WETH
    uint16 constant LTV_VOL_L = 0.85e4;
    uint16 constant LTV_BTC_ETH_B = 0.78e4; // BTC -> WETH
    uint16 constant LTV_BTC_ETH_L = 0.83e4;
    uint16 constant LTV_LST_STABLE_B = 0.85e4; // wstETH/cbETH -> stables
    uint16 constant LTV_LST_STABLE_L = 0.87e4;
    uint16 constant LTV_LST_ETH_B = 0.94e4; // wstETH/cbETH -> WETH (high, correlated)
    uint16 constant LTV_LST_ETH_L = 0.95e4;

    // ───────────── Reactive interest-rate model (Adaptive Curve) ────────────────
    // Ungoverned markets are immutable, so a static kink IRM could never be retuned.
    // The adaptive curve self-adjusts the rate-at-target to hold utilization near
    // TARGET — no governance. Each borrowable vault gets its OWN IRM instance so the
    // curve can be tuned per asset (stables vs ETH here). Rates are WAD-per-second;
    // `Xe18 / YEAR` reads as "X APR". Bounds are shared; initial rate-at-target varies.
    int256 constant YEAR = int256(365.2425 days);
    int256 constant IRM_TARGET_UTILIZATION = 0.90e18;
    int256 constant IRM_INIT_RATE_STABLE = 0.04e18 / YEAR; // 4% APR at target (stables)
    int256 constant IRM_INIT_RATE_ETH = 0.025e18 / YEAR; // 2.5% APR at target (WETH)
    int256 constant IRM_MIN_RATE_AT_TARGET = 0.001e18 / YEAR; // 0.1% APR
    int256 constant IRM_MAX_RATE_AT_TARGET = 2e18 / YEAR; // 200% APR
    int256 constant IRM_CURVE_STEEPNESS = 4e18;
    int256 constant IRM_ADJUSTMENT_SPEED = 50e18 / YEAR;

    // ──────────────────────────── Pool curve params ────────────────────────────
    uint64 constant CONCENTRATION = 0.9999e18; // near constant-sum for a $1 peg
    uint64 constant SWAP_FEE = 1e14; // 1 bps — the fee that offsets borrow cost

    // ─────────────────── Vault indices (EdgeFactory order) ──────────────────────
    uint256 constant BORROW_USDC = 0;
    uint256 constant BORROW_USDT = 1;
    uint256 constant BORROW_STABLE = 2;
    uint256 constant BORROW_WETH = 3;
    uint256 constant ESC_USDC = 4;
    uint256 constant ESC_USDT = 5;
    uint256 constant ESC_STABLE = 6;
    uint256 constant ESC_CBBTC = 7;
    uint256 constant ESC_WBTC = 8;
    uint256 constant ESC_WETH = 9;
    uint256 constant ESC_WSTETH = 10;
    uint256 constant ESC_CBETH = 11;

    struct Deployment {
        address router;
        address pool;
        address borrowUSDC;
        address escrowUSDC;
        address borrowStable; // RLUSD
        address escrowStable;
        address borrowUSDT;
        address escrowUSDT;
        address borrowWETH;
        address escrowWETH;
        address escrowCBBTC;
        address escrowWBTC;
        address escrowWSTETH;
        address escrowCBETH;
    }

    /// @notice Deploy the mini market + bootstrap the USDC/STABLE EulerSwap pool.
    /// @param eulerAccount MUST equal the caller (msg.sender): token source for the
    ///        seeds and the EVC account that authorizes the pool operator.
    function deployMarket(address eulerAccount, uint256 seedUSDC, uint256 seedStable)
        public
        returns (Deployment memory d)
    {
        // Each borrowable vault gets its own IRM instance (independent state + params).
        address irmUSDC = _deployIRM(IRM_INIT_RATE_STABLE);
        address irmUSDT = _deployIRM(IRM_INIT_RATE_STABLE);
        address irmStable = _deployIRM(IRM_INIT_RATE_STABLE);
        address irmWETH = _deployIRM(IRM_INIT_RATE_ETH);

        (address router, address[] memory v) = IEdgeFactory(EDGE_FACTORY).deploy(
            IEdgeFactory.DeployParams({
                vaults: _vaults(irmUSDC, irmUSDT, irmStable, irmWETH),
                router: IEdgeFactory.RouterParams({externalResolvedVaults: new address[](0), adapters: _adapters()}),
                ltv: _ltvs(),
                unitOfAccount: USD
            })
        );

        d.router = router;
        d.borrowUSDC = v[BORROW_USDC];
        d.borrowUSDT = v[BORROW_USDT];
        d.borrowStable = v[BORROW_STABLE];
        d.borrowWETH = v[BORROW_WETH];
        d.escrowUSDC = v[ESC_USDC];
        d.escrowUSDT = v[ESC_USDT];
        d.escrowStable = v[ESC_STABLE];
        d.escrowCBBTC = v[ESC_CBBTC];
        d.escrowWBTC = v[ESC_WBTC];
        d.escrowWETH = v[ESC_WETH];
        d.escrowWSTETH = v[ESC_WSTETH];
        d.escrowCBETH = v[ESC_CBETH];

        // Defend against any change in EdgeFactory's return ordering: assert each vault
        // holds the asset we expect before we seed it or wire it into the pool.
        _verifyVaults(d);

        // Seed the LP equity into the two stable escrow vaults (the swap inventory).
        _safeApprove(USDC, d.escrowUSDC, seedUSDC);
        IEVault(d.escrowUSDC).deposit(seedUSDC, eulerAccount);
        _safeApprove(STABLE, d.escrowStable, seedStable);
        IEVault(d.escrowStable).deposit(seedStable, eulerAccount);

        d.pool = _deployPool(eulerAccount, d, seedUSDC, seedStable);
    }

    // ───────────────────────────── build edge params ───────────────────────────

    /// @dev Deploy a fresh adaptive-curve IRM. Shared bounds/target/steepness/speed;
    ///      `initialRateAtTarget` lets each vault start on its own curve.
    function _deployIRM(int256 initialRateAtTarget) internal returns (address) {
        return IEulerAdaptiveCurveIRMFactory(ADAPTIVE_CURVE_IRM_FACTORY).deploy(
            IRM_TARGET_UTILIZATION,
            initialRateAtTarget,
            IRM_MIN_RATE_AT_TARGET,
            IRM_MAX_RATE_AT_TARGET,
            IRM_CURVE_STEEPNESS,
            IRM_ADJUSTMENT_SPEED
        );
    }

    function _vaults(address irmUSDC, address irmUSDT, address irmStable, address irmWETH)
        internal
        pure
        returns (IEdgeFactory.VaultParams[] memory vp)
    {
        vp = new IEdgeFactory.VaultParams[](12);
        // borrowable (controllers) — each with its own IRM
        vp[BORROW_USDC] = IEdgeFactory.VaultParams({asset: USDC, irm: irmUSDC, escrow: false});
        vp[BORROW_USDT] = IEdgeFactory.VaultParams({asset: USDT, irm: irmUSDT, escrow: false});
        vp[BORROW_STABLE] = IEdgeFactory.VaultParams({asset: STABLE, irm: irmStable, escrow: false});
        vp[BORROW_WETH] = IEdgeFactory.VaultParams({asset: WETH, irm: irmWETH, escrow: false});
        // collateral-only (escrow)
        vp[ESC_USDC] = IEdgeFactory.VaultParams({asset: USDC, irm: address(0), escrow: true});
        vp[ESC_USDT] = IEdgeFactory.VaultParams({asset: USDT, irm: address(0), escrow: true});
        vp[ESC_STABLE] = IEdgeFactory.VaultParams({asset: STABLE, irm: address(0), escrow: true});
        vp[ESC_CBBTC] = IEdgeFactory.VaultParams({asset: CBBTC, irm: address(0), escrow: true});
        vp[ESC_WBTC] = IEdgeFactory.VaultParams({asset: WBTC, irm: address(0), escrow: true});
        vp[ESC_WETH] = IEdgeFactory.VaultParams({asset: WETH, irm: address(0), escrow: true});
        vp[ESC_WSTETH] = IEdgeFactory.VaultParams({asset: WSTETH, irm: address(0), escrow: true});
        vp[ESC_CBETH] = IEdgeFactory.VaultParams({asset: CBETH, irm: address(0), escrow: true});
    }

    function _adapters() internal returns (IEdgeFactory.AdapterParams[] memory ap) {
        address aWETH = address(new ChainlinkOracle(WETH, USD, FEED_ETH_USD, STALE_CRYPTO));
        ap = new IEdgeFactory.AdapterParams[](8);
        ap[0] = IEdgeFactory.AdapterParams(USDC, address(new ChainlinkOracle(USDC, USD, FEED_USDC_USD, STALE_USD)));
        ap[1] = IEdgeFactory.AdapterParams(USDT, address(new ChainlinkOracle(USDT, USD, FEED_USDT_USD, STALE_USD)));
        // SECURITY: RLUSD is priced at a hard-coded $1, immutable. Market solvency assumes
        // RLUSD never trades materially below $1 — see the SECURITY CONSIDERATIONS header.
        ap[2] = IEdgeFactory.AdapterParams(STABLE, address(new FixedRateOracle(STABLE, USD, 1e18)));
        // SECURITY: cbBTC/WBTC are priced 1:1 with BTC — assumes the wrapper holds its peg.
        ap[3] = IEdgeFactory.AdapterParams(CBBTC, address(new ChainlinkOracle(CBBTC, USD, FEED_BTC_USD, STALE_CRYPTO)));
        ap[4] = IEdgeFactory.AdapterParams(WBTC, address(new ChainlinkOracle(WBTC, USD, FEED_BTC_USD, STALE_CRYPTO)));
        ap[5] = IEdgeFactory.AdapterParams(WETH, aWETH);
        // wstETH -> WETH (Lido fundamental) -> USD, exactly as Euler's PrimeCluster does it.
        // SECURITY: the Lido fundamental rate ignores any secondary-market stETH depeg.
        ap[6] = IEdgeFactory.AdapterParams(
            WSTETH, address(new CrossAdapter(WSTETH, WETH, USD, address(new LidoFundamentalOracle()), aWETH))
        );
        // cbETH -> WETH (Chainlink cbETH/ETH) -> USD. Same LST caveat as wstETH.
        ap[7] = IEdgeFactory.AdapterParams(
            CBETH,
            address(
                new CrossAdapter(
                    CBETH, WETH, USD, address(new ChainlinkOracle(CBETH, WETH, FEED_CBETH_ETH, STALE_LST_RATE)), aWETH
                )
            )
        );
    }

    /// @dev Collateral -> controller LTVs. Stables loop/cross at 0.95; BTC + ETH back
    ///      stables; ETH LSTs back WETH at a high (correlated) LTV.
    function _ltvs() internal pure returns (IEdgeFactory.LTVParams[] memory lp) {
        uint256[3] memory stableC = [BORROW_USDC, BORROW_USDT, BORROW_STABLE];
        uint256[3] memory stableE = [ESC_USDC, ESC_USDT, ESC_STABLE];
        uint256[2] memory btcE = [ESC_CBBTC, ESC_WBTC];
        uint256[2] memory lstE = [ESC_WSTETH, ESC_CBETH];

        lp = new IEdgeFactory.LTVParams[](31);
        uint256 k;
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 3; ++j) {
                lp[k++] = _ltv(stableE[i], stableC[j], LTV_STABLE_B, LTV_STABLE_L); // stable -> stable
            }
            lp[k++] = _ltv(stableE[i], BORROW_WETH, LTV_VOL_B, LTV_VOL_L); // stable -> WETH
        }
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 3; ++j) {
                lp[k++] = _ltv(btcE[i], stableC[j], LTV_VOL_B, LTV_VOL_L); // BTC -> stable
            }
            lp[k++] = _ltv(btcE[i], BORROW_WETH, LTV_BTC_ETH_B, LTV_BTC_ETH_L); // BTC -> WETH
        }
        for (uint256 j; j < 3; ++j) {
            lp[k++] = _ltv(ESC_WETH, stableC[j], LTV_VOL_B, LTV_VOL_L); // WETH -> stable
        }
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 3; ++j) {
                lp[k++] = _ltv(lstE[i], stableC[j], LTV_LST_STABLE_B, LTV_LST_STABLE_L); // LST -> stable
            }
            lp[k++] = _ltv(lstE[i], BORROW_WETH, LTV_LST_ETH_B, LTV_LST_ETH_L); // LST -> WETH (high)
        }
        require(k == 31, "ltv count");
    }

    // ───────────────────────────── pool deploy ─────────────────────────────────

    function _deployPool(address eulerAccount, Deployment memory d, uint256 seedUSDC, uint256 seedStable)
        internal
        returns (address pool)
    {
        // EulerSwap requires asset0 < asset1 (by address) — STABLE may sort either side.
        bool usdcIs0 = USDC < STABLE;
        uint8 stableDec = IERC20(STABLE).decimals();
        (uint8 dec0, uint8 dec1) = usdcIs0 ? (uint8(6), stableDec) : (stableDec, uint8(6));
        (uint80 priceX, uint80 priceY) = _price1to1(dec0, dec1);
        uint112 eq0 = uint112(usdcIs0 ? seedUSDC : seedStable);
        uint112 eq1 = uint112(usdcIs0 ? seedStable : seedUSDC);

        IEulerSwap.StaticParams memory s = IEulerSwap.StaticParams({
            supplyVault0: usdcIs0 ? d.escrowUSDC : d.escrowStable, // inventory (ring-fenced)
            supplyVault1: usdcIs0 ? d.escrowStable : d.escrowUSDC,
            borrowVault0: usdcIs0 ? d.borrowUSDC : d.borrowStable, // debt
            borrowVault1: usdcIs0 ? d.borrowStable : d.borrowUSDC,
            eulerAccount: eulerAccount,
            feeRecipient: address(0)
        });

        // SECURITY: passive pool — no swapHook/oracle (swapHookedOperations = 0) and
        // minReserve 0. It quotes ~1:1 even through a depeg, so arbitrageurs can drain the
        // pegged-up side and leave the LP holding the other. Attach a dynamic-fee /
        // rebalancing hook before deploying real size (see SECURITY CONSIDERATIONS header).
        IEulerSwap.DynamicParams memory dp = IEulerSwap.DynamicParams({
            equilibriumReserve0: eq0,
            equilibriumReserve1: eq1,
            minReserve0: 0,
            minReserve1: 0,
            priceX: priceX,
            priceY: priceY,
            concentrationX: CONCENTRATION,
            concentrationY: CONCENTRATION,
            fee0: SWAP_FEE,
            fee1: SWAP_FEE,
            expiration: 0,
            swapHookedOperations: 0,
            swapHook: address(0)
        });

        IEulerSwap.InitialState memory init = IEulerSwap.InitialState({reserve0: eq0, reserve1: eq1});

        // EulerSwap pools double as Uniswap V4 hooks: the address must encode the hook
        // flags, so mine a salt (off-chain) that produces a valid one.
        bytes memory cc = IEulerSwapFactory(EULERSWAP_FACTORY).creationCode(s);
        bytes32 salt;
        (pool, salt) = HookMiner.find(EULERSWAP_FACTORY, HookMiner.EULERSWAP_FLAGS, cc);

        // The pool must be an authorized EVC operator BEFORE deployPool.
        IEVC(EVC).setAccountOperator(eulerAccount, pool, true);
        bytes memory res = IEVC(EVC).call(
            EULERSWAP_FACTORY, eulerAccount, 0, abi.encodeCall(IEulerSwapFactory.deployPool, (s, dp, init, salt))
        );
        require(abi.decode(res, (address)) == pool, "pool address mismatch");
    }

    // ───────────────────────────── helpers ─────────────────────────────────────

    /// @dev Assert each vault holds the asset its index claims. Cheap insurance against
    ///      a future EdgeFactory change reordering the returned array.
    function _verifyVaults(Deployment memory d) internal view {
        require(IEVault(d.borrowUSDC).asset() == USDC, "wire: borrowUSDC");
        require(IEVault(d.borrowUSDT).asset() == USDT, "wire: borrowUSDT");
        require(IEVault(d.borrowStable).asset() == STABLE, "wire: borrowStable");
        require(IEVault(d.borrowWETH).asset() == WETH, "wire: borrowWETH");
        require(IEVault(d.escrowUSDC).asset() == USDC, "wire: escrowUSDC");
        require(IEVault(d.escrowUSDT).asset() == USDT, "wire: escrowUSDT");
        require(IEVault(d.escrowStable).asset() == STABLE, "wire: escrowStable");
        require(IEVault(d.escrowCBBTC).asset() == CBBTC, "wire: escrowCBBTC");
        require(IEVault(d.escrowWBTC).asset() == WBTC, "wire: escrowWBTC");
        require(IEVault(d.escrowWETH).asset() == WETH, "wire: escrowWETH");
        require(IEVault(d.escrowWSTETH).asset() == WSTETH, "wire: escrowWSTETH");
        require(IEVault(d.escrowCBETH).asset() == CBETH, "wire: escrowCBETH");
    }

    /// @dev priceX/priceY for a 1:1 human price between token0 (dec0) and token1 (dec1).
    function _price1to1(uint8 dec0, uint8 dec1) internal pure returns (uint80 px, uint80 py) {
        if (dec1 >= dec0) {
            px = 1e18;
            py = uint80(uint256(1e18) / (10 ** (uint256(dec1) - dec0)));
        } else {
            py = 1e18;
            px = uint80(uint256(1e18) / (10 ** (uint256(dec0) - dec1)));
        }
    }

    /// @dev Approve that tolerates non-standard ERC20s (e.g. USDT returns no bool).
    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.approve, (spender, amount)));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "approve failed");
    }

    function _ltv(uint256 collateral, uint256 controller, uint16 borrowLTV, uint16 liqLTV)
        internal
        pure
        returns (IEdgeFactory.LTVParams memory)
    {
        return IEdgeFactory.LTVParams({
            collateralVaultIndex: collateral,
            controllerVaultIndex: controller,
            borrowLTV: borrowLTV,
            liquidationLTV: liqLTV
        });
    }

    function logDeployment(Deployment memory d) public pure {
        console.log("=== Mini market deployed (ungoverned) ===");
        console.log("EulerRouter:      ", d.router);
        console.log("EulerSwap pool:   ", d.pool);
        console.log("borrow USDC/USDT: ", d.borrowUSDC, d.borrowUSDT);
        console.log("borrow STABLE/WETH:", d.borrowStable, d.borrowWETH);
        console.log("escrow USDC/STABLE:", d.escrowUSDC, d.escrowStable);
        console.log("escrow cbBTC/WBTC: ", d.escrowCBBTC, d.escrowWBTC);
        console.log("escrow WETH:      ", d.escrowWETH);
        console.log("escrow wstETH/cbETH:", d.escrowWSTETH, d.escrowCBETH);
    }

    /// @notice Print the ACTUAL on-chain LTV matrix, read back from the deployed vaults —
    ///         the source of truth, so the docs can never silently drift. Each cell is
    ///         "borrowLTV/liqLTV" as integer percent; "-" means not accepted as collateral.
    function logLTVMatrix(Deployment memory d) public view {
        address[4] memory ctrl = [d.borrowUSDC, d.borrowUSDT, d.borrowStable, d.borrowWETH];
        console.log("=== On-chain LTV matrix (borrow/liq, percent) | deposit row x borrow column ===");
        console.log(
            string.concat(_padR("deposit", 9), _padR("USDC", 8), _padR("USDT", 8), _padR("RLUSD", 8), "WETH")
        );
        _logLTVRow("USDC", d.escrowUSDC, ctrl);
        _logLTVRow("USDT", d.escrowUSDT, ctrl);
        _logLTVRow("RLUSD", d.escrowStable, ctrl);
        _logLTVRow("cbBTC", d.escrowCBBTC, ctrl);
        _logLTVRow("WBTC", d.escrowWBTC, ctrl);
        _logLTVRow("WETH", d.escrowWETH, ctrl);
        _logLTVRow("wstETH", d.escrowWSTETH, ctrl);
        _logLTVRow("cbETH", d.escrowCBETH, ctrl);
    }

    function _logLTVRow(string memory name, address coll, address[4] memory ctrl) internal view {
        console.log(
            string.concat(
                _padR(name, 9),
                _padR(_ltvCell(ctrl[0], coll), 8),
                _padR(_ltvCell(ctrl[1], coll), 8),
                _padR(_ltvCell(ctrl[2], coll), 8),
                _ltvCell(ctrl[3], coll)
            )
        );
    }

    function _ltvCell(address controller, address collateral) internal view returns (string memory) {
        uint16 b = IEVault(controller).LTVBorrow(collateral);
        uint16 l = IEVault(controller).LTVLiquidation(collateral);
        if (b == 0 && l == 0) return "-";
        return string.concat(vm.toString(uint256(b) / 100), "/", vm.toString(uint256(l) / 100));
    }

    function _padR(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = b.length; i < n; ++i) {
            s = string.concat(s, " ");
        }
        return s;
    }
}
