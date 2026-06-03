// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FixedRateOracle} from "euler-price-oracle/adapter/fixed/FixedRateOracle.sol";
import {BootstrapMarketBase} from "./BootstrapMarketBase.sol";
import {IERC20} from "../src/Interfaces.sol";

/// @title  DeployNewStableMarket — USDC / your new stablecoin
/// @notice Bootstraps liquidity for a BRAND-NEW stablecoin (call it USDnew) paired
///         with USDC. A new stable has no Chainlink feed, so it's priced by a
///         FixedRateOracle pegged to $1. Everything else — the escrow ring-fencing,
///         borrow-funded inventory, cbBTC/WETH collateral, ungoverned deployment —
///         is identical to the USDC/USDT template.
///
/// @dev Usage (fork-test first — see test/DeployNewStableMarket.fork.t.sol):
///   PRIVATE_KEY=0x... NEW_STABLE=0xYourToken MAINNET_RPC_URL=https://... \
///     forge script script/DeployNewStableMarket.s.sol:DeployNewStableMarket \
///     --rpc-url mainnet --broadcast --slow -vvvv
///   The broadcaster must already hold SEED_USDC of USDC and SEED_STABLE of USDnew.
contract DeployNewStableMarket is BootstrapMarketBase {
    uint256 constant SEED_USDC = 1_000_000e6; // 1.0M USDC

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address newStable = vm.envAddress("NEW_STABLE");
        // Seed amount in the new stable's own decimals.
        uint256 seedStable = 1_000_000 * (10 ** IERC20(newStable).decimals());

        vm.startBroadcast(pk);
        Deployment memory d = deploy(deployer, newStable, SEED_USDC, seedStable);
        vm.stopBroadcast();

        logDeployment(d);
    }

    /// @notice Build a FixedRateOracle($1) for `newStable` and deploy the market.
    ///         Asset ordering and decimal-adjusted pricing are handled by the base.
    function deploy(address eulerAccount, address newStable, uint256 seedUSDC, uint256 seedStable)
        public
        returns (Deployment memory)
    {
        // rate is in the quote's decimals; USD is treated as 18-dp, so $1 == 1e18.
        address adapter = address(new FixedRateOracle(newStable, USD, 1e18));
        return deployMarket(eulerAccount, newStable, adapter, seedUSDC, seedStable);
    }
}
