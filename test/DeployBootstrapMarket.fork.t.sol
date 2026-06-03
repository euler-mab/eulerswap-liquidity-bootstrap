// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DeployBootstrapMarket} from "../script/DeployBootstrapMarket.s.sol";
import {IERC20, IEVC, IEVault, IEulerSwapPool} from "../src/Interfaces.sol";

/// @notice End-to-end validation of the bootstrap deploy against a mainnet fork.
/// @dev    MAINNET_RPC_URL=https://... forge test --match-path test/*.fork.t.sol -vvv
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
        // deployMarket are sent by it, so it must hold the seed and own the account.
        address lp = address(script);
        deal(USDC, lp, SEED_USDC);
        deal(USDT, lp, SEED_USDT);

        DeployBootstrapMarket.Deployment memory d = script.deployMarket(lp, SEED_USDC, SEED_USDT);

        // 1. Borrowable vaults are ungoverned (immutable).
        assertEq(IEVault(d.borrowUSDC).governorAdmin(), address(0), "USDC vault still governed");
        assertEq(IEVault(d.borrowUSDT).governorAdmin(), address(0), "USDT vault still governed");

        // 2. Collateral relationships wired as intended.
        assertEq(IEVault(d.borrowUSDC).LTVBorrow(d.escrowUSDT), 0.95e4, "stable cross LTV");
        assertEq(IEVault(d.borrowUSDC).LTVBorrow(d.escrowUSDC), 0.95e4, "stable self/loop LTV");
        assertEq(IEVault(d.borrowUSDC).LTVBorrow(d.escrowWETH), 0.80e4, "WETH collateral LTV");
        assertEq(IEVault(d.borrowUSDT).LTVBorrow(d.escrowCBBTC), 0.80e4, "cbBTC collateral LTV");

        // 3. Inventory really sits in the escrow vaults.
        assertEq(IEVault(d.escrowUSDC).convertToAssets(IEVault(d.escrowUSDC).balanceOf(lp)), SEED_USDC, "USDC inventory");
        assertEq(IEVault(d.escrowUSDT).convertToAssets(IEVault(d.escrowUSDT).balanceOf(lp)), SEED_USDT, "USDT inventory");

        // 4. The pool is authorized as an EVC operator and is live.
        assertTrue(IEVC(EVC).isAccountOperatorAuthorized(lp, d.pool), "operator not installed");

        // 5. Pool quotes ~1:1 minus the 1 bps fee. 100k USDC -> ~99.99k USDT.
        uint256 out = IEulerSwapPool(d.pool).computeQuote(USDC, USDT, 100_000e6, true);
        console.log("quote: 100,000 USDC -> USDT =", out);
        assertGt(out, 99_900e6, "quote unexpectedly low");
        assertLe(out, 100_000e6, "quote exceeds input");
    }
}
