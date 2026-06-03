// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkOracle} from "euler-price-oracle/adapter/chainlink/ChainlinkOracle.sol";
import {
    IERC20,
    IEVC,
    IEVault,
    IEulerKinkIRMFactory,
    IEdgeFactory,
    IEulerSwap,
    IEulerSwapFactory
} from "../src/Interfaces.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @title  DeployBootstrapMarket
/// @notice Worked example: bootstrap a USDC/USDT EulerSwap market on Ethereum
///         mainnet out of UNGOVERNED Euler vaults, with cbBTC + WETH accepted as
///         collateral so the lending market has organic borrow demand.
///
/// What this deploys, in one transaction:
///   1. Four ChainlinkOracle price adapters (USDC, USDT, cbBTC, WETH -> USD).
///   2. A kink interest-rate model for the borrowable stable vaults.
///   3. An Edge market via the canonical EdgeFactory:
///        - borrowable eUSDC, eUSDT vaults
///        - collateral-only ESCROW vaults for USDC, USDT, cbBTC, WETH
///        - a fresh EulerRouter wired to the adapters
///        - LTVs between them
///        - ...then ALL governance renounced (vaults + router are immutable).
///   4. The LP's seed equity deposited into the stable escrow vaults.
///   5. A USDC/USDT EulerSwap pool whose swap inventory lives in the escrow
///      vaults (ring-fenced) and which borrows from the borrowable vaults.
///
/// The escrow vaults are the trick: nothing can be borrowed *out* of an escrow
/// vault, so the swap inventory can never be drained by the money market — even
/// while cbBTC/WETH holders borrow stables against their collateral.
///
/// @dev Usage (ALWAYS fork-test first — see test/DeployBootstrapMarket.fork.t.sol):
///   PRIVATE_KEY=0x... MAINNET_RPC_URL=https://... \
///     forge script script/DeployBootstrapMarket.s.sol:DeployBootstrapMarket \
///     --rpc-url mainnet --broadcast --slow -vvvv
///
/// The broadcaster must already hold SEED_USDC of USDC and SEED_USDT of USDT.
contract DeployBootstrapMarket is Script {
    // ─────────────────────────── Euler mainnet infra ───────────────────────────
    address constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address constant EDGE_FACTORY = 0xA969B8a46166B135fD5AC533AdC28c816E1659Bd;
    address constant EULERSWAP_FACTORY = 0xD05213331221fAB8a3C387F2affBb605Bb04DF5F;
    address constant KINK_IRM_FACTORY = 0xcAe0A39B45Ee9C3213f64392FA6DF30CE034C9F9;
    address constant USD = address(840); // unit of account (== 0x...0348)

    // ───────────────────────────── Tokens (mainnet) ────────────────────────────
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 dec
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6 dec
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // 18 dec
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf; // 8 dec

    // ─────────────────── Chainlink feeds (mainnet aggregators) ──────────────────
    // VERIFY against https://docs.chain.link/data-feeds/price-feeds/addresses
    // before broadcasting. cbBTC is priced off BTC/USD here (cbBTC is 1:1 BTC-backed);
    // in production prefer a dedicated cbBTC/USD feed or a cbBTC/BTC x BTC/USD cross.
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant FEED_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    uint256 constant FEED_STALENESS = 24 hours;

    // ──────────────────────────── LTVs (1e4 = 100%) ────────────────────────────
    uint16 constant STABLE_BORROW_LTV = 0.95e4; // stable-vs-stable: the loop / cross
    uint16 constant STABLE_LIQ_LTV = 0.96e4;
    uint16 constant VOL_BORROW_LTV = 0.80e4; // cbBTC / WETH collateral
    uint16 constant VOL_LIQ_LTV = 0.85e4;

    // ───────────────── Interest-rate model (EXAMPLE — calibrate) ────────────────
    // EVK IRMLinearKink: rates are 1e27-per-second (ray/sec). ir(util) below kink =
    // baseRate + util*slope1 (util in [0, type(uint32).max]); above = +(util-kink)*slope2.
    // These values target ~5% APY at the 90% kink, ramping to ~50% APY at 100%.
    // Review against Euler's IRM tooling before mainnet.
    uint256 constant IRM_BASE_RATE = 0;
    uint256 constant IRM_SLOPE1 = 409_900_000; // ~5% APY at kink
    uint256 constant IRM_SLOPE2 = 33_200_000_000; // steep above kink
    uint32 constant IRM_KINK = 3_865_470_566; // 90% of type(uint32).max

    // ──────────────────────────── Pool curve params ────────────────────────────
    // USDC(6)/USDT(6) at 1:1 -> priceX/priceY = 1e18/1e18.
    uint80 constant PRICE_X = 1e18;
    uint80 constant PRICE_Y = 1e18;
    uint64 constant CONCENTRATION = 0.9999e18; // near constant-sum for a $1 peg
    uint64 constant SWAP_FEE = 1e14; // 1 bps — the fee that offsets borrow cost

    // ───────────────────────── Seed equity (configurable) ──────────────────────
    // The LP's real deposits into the stable escrow vaults. Inventory the pool
    // hands out. Scale leverage later by looping / by setting larger eq reserves
    // once the borrowable vaults have lender liquidity (see README).
    uint256 constant SEED_USDC = 1_000_000e6; // 1.0M USDC
    uint256 constant SEED_USDT = 1_000_000e6; // 1.0M USDT

    struct Deployment {
        address router;
        address borrowUSDC;
        address borrowUSDT;
        address escrowUSDC;
        address escrowUSDT;
        address escrowCBBTC;
        address escrowWETH;
        address pool;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        Deployment memory d = deployMarket(deployer, SEED_USDC, SEED_USDT);
        vm.stopBroadcast();

        _log(d);
    }

    /// @notice Deploy + configure the whole market and seed the pool.
    /// @param eulerAccount The account that owns the position. MUST equal the
    ///        caller (msg.sender) of this function: it is the token source for the
    ///        seed deposits and the EVC account that authorizes the pool operator.
    function deployMarket(address eulerAccount, uint256 seedUSDC, uint256 seedUSDT)
        public
        returns (Deployment memory d)
    {
        // 1. Price adapters: base -> USD.
        address aUSDC = address(new ChainlinkOracle(USDC, USD, FEED_USDC_USD, FEED_STALENESS));
        address aUSDT = address(new ChainlinkOracle(USDT, USD, FEED_USDT_USD, FEED_STALENESS));
        address aCBBTC = address(new ChainlinkOracle(CBBTC, USD, FEED_BTC_USD, FEED_STALENESS));
        address aWETH = address(new ChainlinkOracle(WETH, USD, FEED_ETH_USD, FEED_STALENESS));

        // 2. Interest-rate model for the borrowable stable vaults.
        address irm = IEulerKinkIRMFactory(KINK_IRM_FACTORY).deploy(IRM_BASE_RATE, IRM_SLOPE1, IRM_SLOPE2, IRM_KINK);

        // 3. Edge market — deploys vaults + router + LTVs, then renounces governance.
        (address router, address[] memory vaults) = _deployEdge(irm, aUSDC, aUSDT, aCBBTC, aWETH);
        d.router = router;
        d.borrowUSDC = vaults[0];
        d.borrowUSDT = vaults[1];
        d.escrowUSDC = vaults[2];
        d.escrowUSDT = vaults[3];
        d.escrowCBBTC = vaults[4];
        d.escrowWETH = vaults[5];

        // 4. Seed the LP equity into the stable escrow vaults (the swap inventory).
        _safeApprove(USDC, d.escrowUSDC, seedUSDC);
        IEVault(d.escrowUSDC).deposit(seedUSDC, eulerAccount);
        _safeApprove(USDT, d.escrowUSDT, seedUSDT);
        IEVault(d.escrowUSDT).deposit(seedUSDT, eulerAccount);

        // 5. EulerSwap pool: inventory in escrow (supply), debt in borrowable (borrow).
        d.pool = _deployPool(eulerAccount, d, uint112(seedUSDC), uint112(seedUSDT));
    }

    // ───────────────────────────── internals ──────────────────────────────────

    function _deployEdge(address irm, address aUSDC, address aUSDT, address aCBBTC, address aWETH)
        internal
        returns (address router, address[] memory vaults)
    {
        IEdgeFactory.VaultParams[] memory vp = new IEdgeFactory.VaultParams[](6);
        vp[0] = IEdgeFactory.VaultParams({asset: USDC, irm: irm, escrow: false}); // borrowable USDC
        vp[1] = IEdgeFactory.VaultParams({asset: USDT, irm: irm, escrow: false}); // borrowable USDT
        vp[2] = IEdgeFactory.VaultParams({asset: USDC, irm: address(0), escrow: true}); // USDC escrow
        vp[3] = IEdgeFactory.VaultParams({asset: USDT, irm: address(0), escrow: true}); // USDT escrow
        vp[4] = IEdgeFactory.VaultParams({asset: CBBTC, irm: address(0), escrow: true}); // cbBTC escrow
        vp[5] = IEdgeFactory.VaultParams({asset: WETH, irm: address(0), escrow: true}); // WETH escrow

        IEdgeFactory.AdapterParams[] memory ap = new IEdgeFactory.AdapterParams[](4);
        ap[0] = IEdgeFactory.AdapterParams({base: USDC, adapter: aUSDC});
        ap[1] = IEdgeFactory.AdapterParams({base: USDT, adapter: aUSDT});
        ap[2] = IEdgeFactory.AdapterParams({base: CBBTC, adapter: aCBBTC});
        ap[3] = IEdgeFactory.AdapterParams({base: WETH, adapter: aWETH});

        // Each borrowable vault (controllers 0,1) accepts all four escrows as
        // collateral. Stable escrows at 0.95/0.96 (the loop + cross); cbBTC/WETH
        // at 0.80/0.85 (organic borrow demand).
        IEdgeFactory.LTVParams[] memory lp = new IEdgeFactory.LTVParams[](8);
        lp[0] = _ltv(2, 0, STABLE_BORROW_LTV, STABLE_LIQ_LTV); // USDC esc -> borrow USDC
        lp[1] = _ltv(3, 0, STABLE_BORROW_LTV, STABLE_LIQ_LTV); // USDT esc -> borrow USDC
        lp[2] = _ltv(4, 0, VOL_BORROW_LTV, VOL_LIQ_LTV); // cbBTC   -> borrow USDC
        lp[3] = _ltv(5, 0, VOL_BORROW_LTV, VOL_LIQ_LTV); // WETH    -> borrow USDC
        lp[4] = _ltv(2, 1, STABLE_BORROW_LTV, STABLE_LIQ_LTV); // USDC esc -> borrow USDT
        lp[5] = _ltv(3, 1, STABLE_BORROW_LTV, STABLE_LIQ_LTV); // USDT esc -> borrow USDT
        lp[6] = _ltv(4, 1, VOL_BORROW_LTV, VOL_LIQ_LTV); // cbBTC   -> borrow USDT
        lp[7] = _ltv(5, 1, VOL_BORROW_LTV, VOL_LIQ_LTV); // WETH    -> borrow USDT

        IEdgeFactory.DeployParams memory params = IEdgeFactory.DeployParams({
            vaults: vp,
            router: IEdgeFactory.RouterParams({externalResolvedVaults: new address[](0), adapters: ap}),
            ltv: lp,
            unitOfAccount: USD
        });

        (router, vaults) = IEdgeFactory(EDGE_FACTORY).deploy(params);
    }

    function _deployPool(address eulerAccount, Deployment memory d, uint112 eq0, uint112 eq1)
        internal
        returns (address pool)
    {
        IEulerSwap.StaticParams memory s = IEulerSwap.StaticParams({
            supplyVault0: d.escrowUSDC, // inventory (ring-fenced)
            supplyVault1: d.escrowUSDT,
            borrowVault0: d.borrowUSDC, // debt
            borrowVault1: d.borrowUSDT,
            eulerAccount: eulerAccount,
            feeRecipient: address(0) // fees accrue into the vaults
        });

        IEulerSwap.DynamicParams memory dp = IEulerSwap.DynamicParams({
            equilibriumReserve0: eq0,
            equilibriumReserve1: eq1,
            minReserve0: 0,
            minReserve1: 0,
            priceX: PRICE_X,
            priceY: PRICE_Y,
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
        address deployed = abi.decode(res, (address));
        require(deployed == pool, "pool address mismatch");
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

    function _log(Deployment memory d) internal pure {
        console.log("=== Bootstrap market deployed ===");
        console.log("EulerRouter:    ", d.router);
        console.log("borrowable USDC:", d.borrowUSDC);
        console.log("borrowable USDT:", d.borrowUSDT);
        console.log("escrow USDC:    ", d.escrowUSDC);
        console.log("escrow USDT:    ", d.escrowUSDT);
        console.log("escrow cbBTC:   ", d.escrowCBBTC);
        console.log("escrow WETH:    ", d.escrowWETH);
        console.log("EulerSwap pool: ", d.pool);
    }
}
