// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DeployNewStableMarket} from "../script/DeployNewStableMarket.s.sol";
import {IERC20, IEVC, IEVault, IEulerSwapPool} from "../src/Interfaces.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Validates the brand-new-stablecoin path (FixedRateOracle, 18-dp stable)
///         against a mainnet fork, using a mock token to stand in for the new stable.
/// @dev    MAINNET_RPC_URL=https://... forge test --match-path test/DeployNewStableMarket.fork.t.sol -vvv
contract DeployNewStableMarketForkTest is Test {
    DeployNewStableMarket internal script;
    MockERC20 internal usdnew;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    uint256 constant SEED_USDC = 1_000_000e6;
    uint256 constant SEED_STABLE = 1_000_000e18; // new stable has 18 decimals

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        script = new DeployNewStableMarket();
        usdnew = new MockERC20("USD New", "USDnew", 18);
    }

    function test_deploys_new_stable_market_with_fixed_rate_oracle() public {
        address lp = address(script);
        deal(USDC, lp, SEED_USDC);
        usdnew.mint(lp, SEED_STABLE);

        DeployNewStableMarket.Deployment memory d = script.deploy(lp, address(usdnew), SEED_USDC, SEED_STABLE);

        // Ungoverned + collateral wired (cbBTC/WETH organic demand still present).
        assertEq(IEVault(d.borrowUSDC).governorAdmin(), address(0), "USDC vault still governed");
        assertEq(IEVault(d.borrowStable).governorAdmin(), address(0), "USDnew vault still governed");
        assertEq(IEVault(d.borrowStable).LTVBorrow(d.escrowUSDC), 0.95e4, "USDC->USDnew LTV");
        assertEq(IEVault(d.borrowUSDC).LTVBorrow(d.escrowWETH), 0.80e4, "WETH collateral LTV");

        // Inventory in escrow, operator installed.
        assertEq(IEVault(d.escrowStable).convertToAssets(IEVault(d.escrowStable).balanceOf(lp)), SEED_STABLE, "USDnew inventory");
        assertTrue(IEVC(EVC).isAccountOperatorAuthorized(lp, d.pool), "operator not installed");

        // Decimal-adjusted 1:1 quote: 100k USDC (6dp) -> ~100k USDnew (18dp), minus fee.
        uint256 out = IEulerSwapPool(d.pool).computeQuote(USDC, address(usdnew), 100_000e6, true);
        console.log("quote: 100,000 USDC -> USDnew (1e18) =", out);
        assertGt(out, 99_900e18, "quote unexpectedly low");
        assertLe(out, 100_000e18, "quote exceeds input");
    }
}
