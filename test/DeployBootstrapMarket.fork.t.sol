// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DeployBootstrapMarket} from "../script/DeployBootstrapMarket.s.sol";
import {IERC20, IEVC, IEVault, IEulerSwapPool, IEulerRouter} from "../src/Interfaces.sol";

/// @notice End-to-end validation of the ungoverned mini market + RLUSD bootstrap pool
///         against a mainnet fork.
/// @dev    MAINNET_RPC_URL=https://... forge test --match-path test/DeployBootstrapMarket.fork.t.sol -vvv
contract DeployBootstrapMarketForkTest is Test {
    DeployBootstrapMarket internal script;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant CBETH = 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USD = address(840);
    address constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    uint256 constant SEED_USDC = 1_000_000e6;
    uint256 constant SEED_STABLE = 1_000_000e18; // RLUSD, 18 dec

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        script = new DeployBootstrapMarket();
    }

    function _deploy(address lp) internal returns (DeployBootstrapMarket.Deployment memory) {
        deal(USDC, lp, SEED_USDC);
        deal(RLUSD, lp, SEED_STABLE);
        return script.deploy(lp, SEED_USDC, SEED_STABLE);
    }

    function test_deploys_ungoverned_mini_market() public {
        // The script contract acts as the LP / eulerAccount.
        address lp = address(script);
        DeployBootstrapMarket.Deployment memory d = _deploy(lp);

        // Print the actual on-chain LTV matrix (visible with -vv).
        script.logLTVMatrix(d);

        // 1. Every borrowable vault is ungoverned (immutable), and there are 6 of them.
        assertEq(IEVault(d.borrowUSDC).governorAdmin(), address(0), "USDC governed");
        assertEq(IEVault(d.borrowUSDT).governorAdmin(), address(0), "USDT governed");
        assertEq(IEVault(d.borrowStable).governorAdmin(), address(0), "RLUSD governed");
        assertEq(IEVault(d.borrowWETH).governorAdmin(), address(0), "WETH governed");
        assertEq(IEVault(d.borrowCBBTC).governorAdmin(), address(0), "cbBTC governed");
        assertEq(IEVault(d.borrowWBTC).governorAdmin(), address(0), "WBTC governed");

        // Each borrowable vault has its OWN IRM instance (distinct, non-zero).
        address[6] memory irms = [
            IEVault(d.borrowUSDC).interestRateModel(),
            IEVault(d.borrowUSDT).interestRateModel(),
            IEVault(d.borrowStable).interestRateModel(),
            IEVault(d.borrowWETH).interestRateModel(),
            IEVault(d.borrowCBBTC).interestRateModel(),
            IEVault(d.borrowWBTC).interestRateModel()
        ];
        for (uint256 i; i < 6; ++i) {
            assertTrue(irms[i] != address(0), "IRM zero");
            for (uint256 j = i + 1; j < 6; ++j) {
                assertTrue(irms[i] != irms[j], "IRMs not distinct");
            }
        }

        // 2. Collateral matrix wired as intended.
        assertEq(IEVault(d.borrowStable).LTVBorrow(d.escrowUSDC), 0.95e4, "USDC -> RLUSD (cross)");
        assertEq(IEVault(d.borrowUSDC).LTVBorrow(d.escrowStable), 0.95e4, "RLUSD -> USDC (cross)");
        assertEq(IEVault(d.borrowUSDC).LTVBorrow(d.escrowWBTC), 0.8e4, "WBTC -> USDC");
        assertEq(IEVault(d.borrowUSDC).LTVBorrow(d.escrowWETH), 0.8e4, "WETH -> USDC");
        assertEq(IEVault(d.borrowUSDC).LTVBorrow(d.escrowWSTETH), 0.85e4, "wstETH -> USDC");
        // The high-LTV LST leverage play: borrow WETH against wstETH / cbETH.
        assertEq(IEVault(d.borrowWETH).LTVBorrow(d.escrowWSTETH), 0.94e4, "wstETH -> WETH (high)");
        assertEq(IEVault(d.borrowWETH).LTVBorrow(d.escrowCBETH), 0.94e4, "cbETH -> WETH (high)");
        // New: BTC controllers, self-correlated tiers, stable -> BTC.
        assertEq(IEVault(d.borrowCBBTC).LTVBorrow(d.escrowUSDC), 0.8e4, "USDC -> cbBTC");
        assertEq(IEVault(d.borrowWETH).LTVBorrow(d.escrowWETH), 0.9e4, "WETH -> WETH (self)");
        assertEq(IEVault(d.borrowCBBTC).LTVBorrow(d.escrowWBTC), 0.9e4, "WBTC -> cbBTC (BTC self)");
        // Yield-bearing collateral: the BORROWABLE WETH/BTC vaults are collateral too...
        assertEq(IEVault(d.borrowUSDC).LTVBorrow(d.borrowWETH), 0.8e4, "borrowable WETH -> USDC");
        assertEq(IEVault(d.borrowStable).LTVBorrow(d.borrowCBBTC), 0.8e4, "borrowable cbBTC -> RLUSD");
        // ...but a vault can never collateralise its own controller (self-pair skipped).
        assertEq(IEVault(d.borrowWETH).LTVBorrow(d.borrowWETH), 0, "WETH borrowable self-collateral");

        // 3. The cross/Lido oracles actually price (validates the wstETH + cbETH wiring).
        uint256 pWst = IEulerRouter(d.router).getQuote(1e18, WSTETH, USD);
        uint256 pCb = IEulerRouter(d.router).getQuote(1e18, CBETH, USD);
        uint256 pWbtc = IEulerRouter(d.router).getQuote(1e8, WBTC, USD);
        console.log("wstETH/USD:", pWst / 1e18, "  cbETH/USD:", pCb / 1e18);
        console.log("WBTC/USD:", pWbtc / 1e18);
        assertGt(pWst, 1_000e18, "wstETH price low");
        assertLt(pWst, 100_000e18, "wstETH price high");
        assertGt(pCb, 1_000e18, "cbETH price low");
        assertGt(pWbtc, 10_000e18, "WBTC price low");

        // 4. Inventory sits in the escrow vaults; pool is an authorized operator.
        assertEq(IEVault(d.escrowUSDC).convertToAssets(IEVault(d.escrowUSDC).balanceOf(lp)), SEED_USDC, "USDC inv");
        assertEq(
            IEVault(d.escrowStable).convertToAssets(IEVault(d.escrowStable).balanceOf(lp)), SEED_STABLE, "RLUSD inv"
        );
        assertTrue(IEVC(EVC).isAccountOperatorAuthorized(lp, d.pool), "operator not installed");

        // 5. Pool quotes ~1:1 minus the 1 bps fee. 100k USDC -> ~99.99k RLUSD (18 dec).
        uint256 out = IEulerSwapPool(d.pool).computeQuote(USDC, RLUSD, 100_000e6, true);
        console.log("quote: 100,000 USDC -> RLUSD (1e18) =", out);
        assertGt(out, 99_900e18, "quote low");
        assertLe(out, 100_000e18, "quote exceeds input");
    }

    /// @notice Adversarial: the per-feed staleness window must actually bite. A crypto
    ///         feed (ETH/USD, 3h) goes stale well before a day, and the quote must revert.
    function test_oracle_reverts_when_crypto_feed_is_stale() public {
        DeployBootstrapMarket.Deployment memory d = _deploy(address(script));

        // Fresh: the ETH/USD-backed WETH quote prices fine.
        assertGt(IEulerRouter(d.router).getQuote(1e18, WETH, USD), 0, "fresh WETH price");

        // Past the 3h crypto-feed window: the same quote must revert (a 24h window wouldn't).
        vm.warp(block.timestamp + 4 hours);
        vm.expectRevert();
        IEulerRouter(d.router).getQuote(1e18, WETH, USD);
    }

    function test_executes_a_swap_through_escrow_inventory() public {
        address lp = address(script);
        DeployBootstrapMarket.Deployment memory d = _deploy(lp);

        // RLUSD (0x82..) < USDC (0xA0..), so RLUSD is token0 and USDC is token1.
        // A trader swaps 100k USDC in for RLUSD out (amount0Out).
        address trader = makeAddr("trader");
        uint256 amountIn = 100_000e6;
        deal(USDC, trader, amountIn);
        uint256 out = IEulerSwapPool(d.pool).computeQuote(USDC, RLUSD, amountIn, true);

        uint256 rlusdEscrowBefore = IEVault(d.escrowStable).convertToAssets(IEVault(d.escrowStable).balanceOf(lp));
        uint256 usdcEscrowBefore = IEVault(d.escrowUSDC).convertToAssets(IEVault(d.escrowUSDC).balanceOf(lp));

        vm.startPrank(trader);
        IERC20(USDC).transfer(d.pool, amountIn);
        IEulerSwapPool(d.pool).swap(out, 0, trader, ""); // RLUSD is token0 -> amount0Out
        vm.stopPrank();

        // Trader received the quoted RLUSD.
        assertEq(IERC20(RLUSD).balanceOf(trader), out, "trader did not receive output");

        // Output left the RLUSD escrow; input entered the USDC escrow. No debt taken on
        // (equilibrium reserves == seed, so inventory alone covers it).
        uint256 rlusdEscrowAfter = IEVault(d.escrowStable).convertToAssets(IEVault(d.escrowStable).balanceOf(lp));
        uint256 usdcEscrowAfter = IEVault(d.escrowUSDC).convertToAssets(IEVault(d.escrowUSDC).balanceOf(lp));
        assertApproxEqAbs(rlusdEscrowBefore - rlusdEscrowAfter, out, 1e12, "RLUSD not withdrawn from escrow");
        assertApproxEqAbs(usdcEscrowAfter - usdcEscrowBefore, amountIn, 1, "USDC not deposited to escrow");
        assertEq(IEVault(d.borrowStable).debtOf(lp), 0, "unexpected debt: template is unleveraged");
    }
}
