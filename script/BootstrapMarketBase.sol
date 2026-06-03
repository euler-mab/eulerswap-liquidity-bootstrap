// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkOracle} from "euler-price-oracle/adapter/chainlink/ChainlinkOracle.sol";
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
/// @notice Shared logic for bootstrapping a USDC/<stable> EulerSwap market out of
///         UNGOVERNED Euler vaults, with cbBTC + WETH accepted as collateral so the
///         lending market has organic borrow demand.
///
/// Subclasses supply the second stablecoin (USDT, or your own new stable) and its
/// price oracle adapter — a Chainlink feed for an established stable, or a
/// FixedRateOracle($1) for a brand-new one. Everything else is identical.
///
/// In one deployMarket(...) call:
///   1. ChainlinkOracle adapters for USDC, cbBTC, WETH -> USD (the `stable` adapter
///      is built by the subclass and passed in).
///   2. A kink IRM for the borrowable stable vaults.
///   3. An Edge market via EdgeFactory: borrowable USDC/<stable>, collateral-only
///      ESCROW vaults (USDC/<stable>/cbBTC/WETH), a router, LTVs — then ALL
///      governance renounced (vaults + router immutable).
///   4. The LP's seed equity deposited into the stable escrow vaults (inventory).
///   5. A salt-mined USDC/<stable> EulerSwap pool (inventory in escrow, debt in the
///      borrowable vaults) with the EVC operator installed.
abstract contract BootstrapMarketBase is Script {
    // ─────────────────────────── Euler mainnet infra ───────────────────────────
    address constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address constant EDGE_FACTORY = 0xA969B8a46166B135fD5AC533AdC28c816E1659Bd;
    address constant EULERSWAP_FACTORY = 0xD05213331221fAB8a3C387F2affBb605Bb04DF5F;
    address constant ADAPTIVE_CURVE_IRM_FACTORY = 0x3EC2d5af936bBB57DD19C292BAfb89da0E377F42;
    address constant USD = address(840); // unit of account (== 0x...0348), 18 decimals

    // ───────────────────────────── Tokens (mainnet) ────────────────────────────
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 dec
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // 18 dec
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf; // 8 dec

    // ─────────────────── Chainlink feeds (mainnet aggregators) ──────────────────
    // VERIFY against https://docs.chain.link/data-feeds/price-feeds/addresses.
    // cbBTC is priced off BTC/USD (cbBTC is 1:1 BTC-backed).
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    uint256 constant FEED_STALENESS = 24 hours;

    // ──────────────────────────── LTVs (1e4 = 100%) ────────────────────────────
    uint16 constant STABLE_BORROW_LTV = 0.95e4; // stable-vs-stable: the loop / cross
    uint16 constant STABLE_LIQ_LTV = 0.96e4;
    uint16 constant VOL_BORROW_LTV = 0.80e4; // cbBTC / WETH collateral
    uint16 constant VOL_LIQ_LTV = 0.85e4;

    // ───────────── Reactive interest-rate model (Adaptive Curve) ────────────────
    // Ungoverned markets are immutable, so a static kink IRM could never be retuned.
    // The adaptive curve continuously nudges the rate-at-target up/down to hold
    // utilization near TARGET — self-correcting without governance. Rates are
    // WAD-per-second; `Xe18 / YEAR` reads as "X (as a fraction) APR". These are the
    // canonical adaptive-curve values; still review for your market.
    int256 constant YEAR = int256(365.2425 days);
    int256 constant IRM_TARGET_UTILIZATION = 0.90e18; // 90%
    int256 constant IRM_INITIAL_RATE_AT_TARGET = 0.04e18 / YEAR; // 4% APR at target
    int256 constant IRM_MIN_RATE_AT_TARGET = 0.001e18 / YEAR; // 0.1% APR floor
    int256 constant IRM_MAX_RATE_AT_TARGET = 2e18 / YEAR; // 200% APR ceiling
    int256 constant IRM_CURVE_STEEPNESS = 4e18; // 4x slope above target
    int256 constant IRM_ADJUSTMENT_SPEED = 50e18 / YEAR; // rate-at-target adjust speed

    // ──────────────────────────── Pool curve params ────────────────────────────
    uint64 constant CONCENTRATION = 0.9999e18; // near constant-sum for a $1 peg
    uint64 constant SWAP_FEE = 1e14; // 1 bps — the fee that offsets borrow cost

    struct Deployment {
        address router;
        address borrowUSDC;
        address borrowStable;
        address escrowUSDC;
        address escrowStable;
        address escrowCBBTC;
        address escrowWETH;
        address pool;
    }

    /// @notice Deploy + configure the whole market and seed the pool.
    /// @param eulerAccount  Owns the position. MUST equal the caller (msg.sender):
    ///        the token source for seeds and the EVC account authorizing the operator.
    /// @param stable        The second stablecoin paired with USDC.
    /// @param stableAdapter IPriceOracle adapter pricing `stable` -> USD.
    /// @dev   The pool's asset ordering and decimal-adjusted price are derived
    ///        automatically — `stable` may sort either side of USDC.
    function deployMarket(
        address eulerAccount,
        address stable,
        address stableAdapter,
        uint256 seedUSDC,
        uint256 seedStable
    ) public returns (Deployment memory d) {
        address aUSDC = address(new ChainlinkOracle(USDC, USD, FEED_USDC_USD, FEED_STALENESS));
        address aCBBTC = address(new ChainlinkOracle(CBBTC, USD, FEED_BTC_USD, FEED_STALENESS));
        address aWETH = address(new ChainlinkOracle(WETH, USD, FEED_ETH_USD, FEED_STALENESS));
        address irm = IEulerAdaptiveCurveIRMFactory(ADAPTIVE_CURVE_IRM_FACTORY).deploy(
            IRM_TARGET_UTILIZATION,
            IRM_INITIAL_RATE_AT_TARGET,
            IRM_MIN_RATE_AT_TARGET,
            IRM_MAX_RATE_AT_TARGET,
            IRM_CURVE_STEEPNESS,
            IRM_ADJUSTMENT_SPEED
        );

        (address router, address[] memory vaults) = _deployEdge(stable, irm, aUSDC, stableAdapter, aCBBTC, aWETH);
        d.router = router;
        d.borrowUSDC = vaults[0];
        d.borrowStable = vaults[1];
        d.escrowUSDC = vaults[2];
        d.escrowStable = vaults[3];
        d.escrowCBBTC = vaults[4];
        d.escrowWETH = vaults[5];

        // Seed the LP equity into the stable escrow vaults (the swap inventory).
        _safeApprove(USDC, d.escrowUSDC, seedUSDC);
        IEVault(d.escrowUSDC).deposit(seedUSDC, eulerAccount);
        _safeApprove(stable, d.escrowStable, seedStable);
        IEVault(d.escrowStable).deposit(seedStable, eulerAccount);

        d.pool = _deployPool(eulerAccount, d, stable, seedUSDC, seedStable);
    }

    // ───────────────────────────── internals ──────────────────────────────────

    function _deployEdge(address stable, address irm, address aUSDC, address aStable, address aCBBTC, address aWETH)
        internal
        returns (address router, address[] memory vaults)
    {
        IEdgeFactory.VaultParams[] memory vp = new IEdgeFactory.VaultParams[](6);
        vp[0] = IEdgeFactory.VaultParams({asset: USDC, irm: irm, escrow: false}); // borrowable USDC
        vp[1] = IEdgeFactory.VaultParams({asset: stable, irm: irm, escrow: false}); // borrowable stable
        vp[2] = IEdgeFactory.VaultParams({asset: USDC, irm: address(0), escrow: true}); // USDC escrow
        vp[3] = IEdgeFactory.VaultParams({asset: stable, irm: address(0), escrow: true}); // stable escrow
        vp[4] = IEdgeFactory.VaultParams({asset: CBBTC, irm: address(0), escrow: true}); // cbBTC escrow
        vp[5] = IEdgeFactory.VaultParams({asset: WETH, irm: address(0), escrow: true}); // WETH escrow

        IEdgeFactory.AdapterParams[] memory ap = new IEdgeFactory.AdapterParams[](4);
        ap[0] = IEdgeFactory.AdapterParams({base: USDC, adapter: aUSDC});
        ap[1] = IEdgeFactory.AdapterParams({base: stable, adapter: aStable});
        ap[2] = IEdgeFactory.AdapterParams({base: CBBTC, adapter: aCBBTC});
        ap[3] = IEdgeFactory.AdapterParams({base: WETH, adapter: aWETH});

        // Each borrowable vault (controllers 0,1) accepts all four escrows as
        // collateral. Stable escrows at 0.95/0.96 (loop + cross); cbBTC/WETH at
        // 0.80/0.85 (organic borrow demand).
        IEdgeFactory.LTVParams[] memory lp = new IEdgeFactory.LTVParams[](8);
        lp[0] = _ltv(2, 0, STABLE_BORROW_LTV, STABLE_LIQ_LTV); // USDC esc   -> borrow USDC
        lp[1] = _ltv(3, 0, STABLE_BORROW_LTV, STABLE_LIQ_LTV); // stable esc -> borrow USDC
        lp[2] = _ltv(4, 0, VOL_BORROW_LTV, VOL_LIQ_LTV); // cbBTC      -> borrow USDC
        lp[3] = _ltv(5, 0, VOL_BORROW_LTV, VOL_LIQ_LTV); // WETH       -> borrow USDC
        lp[4] = _ltv(2, 1, STABLE_BORROW_LTV, STABLE_LIQ_LTV); // USDC esc   -> borrow stable
        lp[5] = _ltv(3, 1, STABLE_BORROW_LTV, STABLE_LIQ_LTV); // stable esc -> borrow stable
        lp[6] = _ltv(4, 1, VOL_BORROW_LTV, VOL_LIQ_LTV); // cbBTC      -> borrow stable
        lp[7] = _ltv(5, 1, VOL_BORROW_LTV, VOL_LIQ_LTV); // WETH       -> borrow stable

        IEdgeFactory.DeployParams memory params = IEdgeFactory.DeployParams({
            vaults: vp,
            router: IEdgeFactory.RouterParams({externalResolvedVaults: new address[](0), adapters: ap}),
            ltv: lp,
            unitOfAccount: USD
        });

        (router, vaults) = IEdgeFactory(EDGE_FACTORY).deploy(params);
    }

    function _deployPool(address eulerAccount, Deployment memory d, address stable, uint256 seedUSDC, uint256 seedStable)
        internal
        returns (address pool)
    {
        // EulerSwap requires asset0 < asset1 (sorted by address) — `stable` may sort
        // either side of USDC, so order the vaults and the 1:1 price accordingly.
        bool usdcIs0 = USDC < stable;
        uint8 stableDec = IERC20(stable).decimals();
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
            feeRecipient: address(0) // fees accrue into the vaults
        });

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

        // EulerSwap pools double as Uniswap V4 hooks: the address must encode the
        // hook-permission flags, so mine a salt (off-chain) that produces a valid one.
        bytes memory cc = IEulerSwapFactory(EULERSWAP_FACTORY).creationCode(s);
        bytes32 salt;
        (pool, salt) = HookMiner.find(EULERSWAP_FACTORY, HookMiner.EULERSWAP_FLAGS, cc);

        // The pool must be authorized as an EVC operator BEFORE deployPool (it
        // reverts with OperatorNotInstalled otherwise).
        IEVC(EVC).setAccountOperator(eulerAccount, pool, true);

        // deployPool authenticates _msgSender() == eulerAccount via the EVC.
        bytes memory res = IEVC(EVC).call(
            EULERSWAP_FACTORY, eulerAccount, 0, abi.encodeCall(IEulerSwapFactory.deployPool, (s, dp, init, salt))
        );
        require(abi.decode(res, (address)) == pool, "pool address mismatch");
    }

    /// @dev priceX/priceY for a 1:1 human price between token0 (dec0) and token1 (dec1):
    ///      priceX/priceY = 10^(dec1 - dec0). One side is fixed at 1e18 and the other
    ///      is 1e18 / 10^|dec1 - dec0|, so values land in [1e6, 1e18] for the 6-/18-dp
    ///      stables we target — comfortably inside uint80. Assumes |dec1 - dec0| <= 18
    ///      (true for any real stablecoin pair); a larger gap would floor the divisor.
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
        console.log("=== Bootstrap market deployed ===");
        console.log("EulerRouter:      ", d.router);
        console.log("borrowable USDC:  ", d.borrowUSDC);
        console.log("borrowable stable:", d.borrowStable);
        console.log("escrow USDC:      ", d.escrowUSDC);
        console.log("escrow stable:    ", d.escrowStable);
        console.log("escrow cbBTC:     ", d.escrowCBBTC);
        console.log("escrow WETH:      ", d.escrowWETH);
        console.log("EulerSwap pool:   ", d.pool);
    }
}
