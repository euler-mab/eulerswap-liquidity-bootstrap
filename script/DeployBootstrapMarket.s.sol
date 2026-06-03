// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BootstrapMarketBase} from "./BootstrapMarketBase.sol";

/// @title  DeployBootstrapMarket
/// @notice Deploys the ungoverned mini market and bootstraps RLUSD liquidity (paired
///         with USDC) on top of it. USDT is a core borrowable asset; cbBTC, WBTC, WETH,
///         wstETH and cbETH are collateral. See BootstrapMarketBase for the full wiring.
///
/// @dev Fork-test first (test/DeployBootstrapMarket.fork.t.sol), then:
///   PRIVATE_KEY=0x... MAINNET_RPC_URL=https://... \
///     forge script script/DeployBootstrapMarket.s.sol:DeployBootstrapMarket \
///     --rpc-url mainnet --broadcast --slow -vvvv
///   The broadcaster must hold SEED_USDC of USDC and SEED_STABLE of the stablecoin.
contract DeployBootstrapMarket is BootstrapMarketBase {
    uint256 constant SEED_USDC = 1_000_000e6; // 1.0M USDC
    uint256 constant SEED_STABLE = 1_000_000e18; // 1.0M RLUSD (18 dec)

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        Deployment memory d = deploy(deployer, SEED_USDC, SEED_STABLE);
        vm.stopBroadcast();

        logDeployment(d);
        logLTVMatrix(d);
    }

    /// @notice Thin wrapper so tests can drive the deploy without broadcasting.
    function deploy(address eulerAccount, uint256 seedUSDC, uint256 seedStable)
        public
        returns (Deployment memory)
    {
        return deployMarket(eulerAccount, seedUSDC, seedStable);
    }
}
