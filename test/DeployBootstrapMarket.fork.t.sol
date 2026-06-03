// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DeployBootstrapMarket} from "../script/DeployBootstrapMarket.s.sol";
import {IERC20, IEVC, IEVault, IEulerSwapPool} from "../src/Interfaces.sol";

/// @notice End-to-end validation of the USDC/USDT deploy against a mainnet fork.
/// @dev    MAINNET_RPC_URL=https://... forge test --match-path test/DeployBootstrapMarket.fork.t.sol -vvv
contract DeployBootstrapMarketForkTest is Test {
    DeployBootstrapMarket internal script;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    uint256 constant SEED_USDC = 1_000_000e6;
    uint256 constant SEED_USDT = 1_000_000e6;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        script = new DeployBootstrapMarket();
    }

    function test_deploys_ungoverned_market_and_quotes() public {
        // The script contract acts as the LP / eulerAccount: nested calls inside
        // deploy() are sent by it, so it must hold the seed and own the account.
        address lp = address(script);
        deal(USDC, lp, SEED_USDC);
        deal(USDT, lp, SEED_USDT);

        DeployBootstrapMarket.Deployment memory d = script.deploy(lp, SEED_USDC, SEED_USDT);

        // 1. Borrowable vaults are ungoverned (immutable).
        assertEq(IEVault(d.borrowUSDC).governorAdmin(), address(0), "USDC vault still governed");
        assertEq(IEVault(d.borrowStable).governorAdmin(), address(0), "USDT vault still governed");

        // 2. Collateral relationships wired as intended.
        assertEq(IEVault(d.borrowUSDC).LTVBorrow(d.escrowStable), 0.95e4, "stable cross LTV");
        assertEq(IEVault(d.borrowUSDC).LTVBorrow(d.escrowUSDC), 0.95e4, "stable self/loop LTV");
        assertEq(IEVault(d.borrowUSDC).LTVBorrow(d.escrowWETH), 0.80e4, "WETH collateral LTV");
        assertEq(IEVault(d.borrowStable).LTVBorrow(d.escrowCBBTC), 0.80e4, "cbBTC collateral LTV");

        // 3. Inventory really sits in the escrow vaults.
        assertEq(IEVault(d.escrowUSDC).convertToAssets(IEVault(d.escrowUSDC).balanceOf(lp)), SEED_USDC, "USDC inventory");
        assertEq(
            IEVault(d.escrowStable).convertToAssets(IEVault(d.escrowStable).balanceOf(lp)), SEED_USDT, "USDT inventory"
        );

        // 4. The pool is authorized as an EVC operator and is live.
        assertTrue(IEVC(EVC).isAccountOperatorAuthorized(lp, d.pool), "operator not installed");

        // 5. Pool quotes ~1:1 minus the 1 bps fee. 100k USDC -> ~99.99k USDT.
        uint256 out = IEulerSwapPool(d.pool).computeQuote(USDC, USDT, 100_000e6, true);
        console.log("quote: 100,000 USDC -> USDT =", out);
        assertGt(out, 99_900e6, "quote unexpectedly low");
        assertLe(out, 100_000e6, "quote exceeds input");
    }

    /// @notice Executes a real swap end-to-end and asserts the inventory moves through
    ///         the escrow vaults as designed (USDC < USDT, so USDC is token0).
    function test_executes_a_swap_through_escrow_inventory() public {
        address lp = address(script);
        deal(USDC, lp, SEED_USDC);
        deal(USDT, lp, SEED_USDT);
        DeployBootstrapMarket.Deployment memory d = script.deploy(lp, SEED_USDC, SEED_USDT);

        // A fresh trader swaps 100k USDC -> USDT.
        address trader = makeAddr("trader");
        uint256 amountIn = 100_000e6;
        deal(USDC, trader, amountIn);
        uint256 out = IEulerSwapPool(d.pool).computeQuote(USDC, USDT, amountIn, true);

        uint256 usdtEscrowBefore = IEVault(d.escrowStable).convertToAssets(IEVault(d.escrowStable).balanceOf(lp));
        uint256 usdcEscrowBefore = IEVault(d.escrowUSDC).convertToAssets(IEVault(d.escrowUSDC).balanceOf(lp));

        // Uniswap-V2-style: send input to the pool, then request the output. USDC is
        // token0, so the USDT output is amount1Out.
        vm.startPrank(trader);
        IERC20(USDC).transfer(d.pool, amountIn);
        IEulerSwapPool(d.pool).swap(0, out, trader, "");
        vm.stopPrank();

        // The trader received the quoted USDT.
        assertEq(IERC20(USDT).balanceOf(trader), out, "trader did not receive output");

        // Output came OUT of the USDT escrow; input went INTO the USDC escrow. No debt
        // is taken on — inventory alone covers it (equilibrium reserves == seed).
        uint256 usdtEscrowAfter = IEVault(d.escrowStable).convertToAssets(IEVault(d.escrowStable).balanceOf(lp));
        uint256 usdcEscrowAfter = IEVault(d.escrowUSDC).convertToAssets(IEVault(d.escrowUSDC).balanceOf(lp));
        assertApproxEqAbs(usdtEscrowBefore - usdtEscrowAfter, out, 1, "USDT not withdrawn from escrow");
        assertApproxEqAbs(usdcEscrowAfter - usdcEscrowBefore, amountIn, 1, "USDC not deposited to escrow");
        assertEq(IEVault(d.borrowStable).debtOf(lp), 0, "unexpected debt: template is unleveraged");
    }
}
