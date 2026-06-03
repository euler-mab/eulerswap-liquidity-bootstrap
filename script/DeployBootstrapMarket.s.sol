// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ChainlinkOracle} from "euler-price-oracle/adapter/chainlink/ChainlinkOracle.sol";
import {BootstrapMarketBase} from "./BootstrapMarketBase.sol";

/// @title  DeployBootstrapMarket — USDC/USDT
/// @notice Bootstraps a USDC/USDT market (USDT priced by its Chainlink feed). This is
///         the drop-in template: to bootstrap your OWN established stable, change the
///         USDT / feed constants. For a brand-new stable with no feed yet, use
///         DeployNewStableMarket.s.sol (FixedRateOracle) instead.
///
/// @dev Usage (ALWAYS fork-test first — see test/DeployBootstrapMarket.fork.t.sol):
///   PRIVATE_KEY=0x... MAINNET_RPC_URL=https://... \
///     forge script script/DeployBootstrapMarket.s.sol:DeployBootstrapMarket \
///     --rpc-url mainnet --broadcast --slow -vvvv
///   The broadcaster must already hold SEED_USDC of USDC and SEED_USDT of USDT.
contract DeployBootstrapMarket is BootstrapMarketBase {
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6 dec
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    uint256 constant SEED_USDC = 1_000_000e6; // 1.0M USDC
    uint256 constant SEED_USDT = 1_000_000e6; // 1.0M USDT

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        Deployment memory d = deploy(deployer, SEED_USDC, SEED_USDT);
        vm.stopBroadcast();

        logDeployment(d);
    }

    /// @notice Build the USDT adapter and deploy the market.
    function deploy(address eulerAccount, uint256 seedUSDC, uint256 seedUSDT)
        public
        returns (Deployment memory)
    {
        address aUSDT = address(new ChainlinkOracle(USDT, USD, FEED_USDT_USD, FEED_STALENESS));
        return deployMarket(eulerAccount, USDT, aUSDT, seedUSDC, seedUSDT);
    }
}
