// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title Minimal interfaces for the Euler contracts this market deploy touches.
/// @notice Hand-vendored so the repo stays self-contained (no full Euler submodule
///         tree). Only the functions actually called by the deploy script and tests
///         are declared. Canonical sources: euler-xyz/euler-interfaces,
///         euler-xyz/euler-vault-kit, euler-xyz/ethereum-vault-connector,
///         euler-xyz/euler-swap, euler-xyz/evk-periphery.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Ethereum Vault Connector — the cross-vault auth/operator layer.
interface IEVC {
    function call(address targetContract, address onBehalfOfAccount, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result);
    function setAccountOperator(address account, address operator, bool authorized) external;
    function isAccountOperatorAuthorized(address account, address operator) external view returns (bool);
}

/// @notice EVK lending vault (ERC4626 + borrowing). Only the bits we use.
interface IEVault {
    function deposit(uint256 amount, address receiver) external returns (uint256);
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function debtOf(address account) external view returns (uint256);
    function governorAdmin() external view returns (address);
    function interestRateModel() external view returns (address);
    function LTVBorrow(address collateral) external view returns (uint16);
    function LTVLiquidation(address collateral) external view returns (uint16);
    function oracle() external view returns (address);
    function unitOfAccount() external view returns (address);
}

/// @notice Adaptive-curve (reactive) IRM factory (evk-periphery IRMFactory).
/// @dev The rate-at-target self-adjusts toward keeping utilization at target — the
///      right choice for an immutable/ungoverned market that can never be retuned.
///      Rates are WAD-per-second; TARGET_UTILIZATION/CURVE_STEEPNESS are WAD.
interface IEulerAdaptiveCurveIRMFactory {
    function deploy(
        int256 targetUtilization,
        int256 initialRateAtTarget,
        int256 minRateAtTarget,
        int256 maxRateAtTarget,
        int256 curveSteepness,
        int256 adjustmentSpeed
    ) external returns (address);
}

/// @notice EdgeFactory — one-shot ungoverned market deployer (evk-periphery).
///         Deploys a router, configures adapters, deploys escrow + borrowable
///         vaults, wires LTVs, then renounces ALL governance (vaults + router).
interface IEdgeFactory {
    struct VaultParams {
        address asset;
        address irm; // ignored when escrow == true
        bool escrow; // true = collateral-only, false = borrowable
    }

    struct AdapterParams {
        address base;
        address adapter; // IPriceOracle adapter pricing base -> unitOfAccount
    }

    struct RouterParams {
        address[] externalResolvedVaults;
        AdapterParams[] adapters;
    }

    struct LTVParams {
        uint256 collateralVaultIndex;
        uint256 controllerVaultIndex;
        uint16 borrowLTV; // 1e4 = 100%
        uint16 liquidationLTV; // 1e4 = 100%
    }

    struct DeployParams {
        VaultParams[] vaults;
        RouterParams router;
        LTVParams[] ltv;
        address unitOfAccount;
    }

    function deploy(DeployParams calldata params) external returns (address router, address[] memory vaults);
}

/// @notice EulerSwap param structs (euler-swap).
interface IEulerSwap {
    struct DynamicParams {
        uint112 equilibriumReserve0;
        uint112 equilibriumReserve1;
        uint112 minReserve0;
        uint112 minReserve1;
        uint80 priceX;
        uint80 priceY;
        uint64 concentrationX;
        uint64 concentrationY;
        uint64 fee0;
        uint64 fee1;
        uint40 expiration;
        uint8 swapHookedOperations;
        address swapHook;
    }

    struct InitialState {
        uint112 reserve0;
        uint112 reserve1;
    }

    struct StaticParams {
        address supplyVault0;
        address supplyVault1;
        address borrowVault0;
        address borrowVault1;
        address eulerAccount;
        address feeRecipient;
    }
}

interface IEulerSwapFactory {
    function computePoolAddress(IEulerSwap.StaticParams memory sParams, bytes32 salt) external view returns (address);
    function creationCode(IEulerSwap.StaticParams memory sParams) external view returns (bytes memory);
    function deployPool(
        IEulerSwap.StaticParams memory sParams,
        IEulerSwap.DynamicParams memory dParams,
        IEulerSwap.InitialState memory initialState,
        bytes32 salt
    ) external returns (address);
}

/// @notice Deployed EulerSwap pool — read helpers + the swap entrypoint used by tests.
interface IEulerSwapPool {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 status);
    function computeQuote(address tokenIn, address tokenOut, uint256 amount, bool exactIn)
        external
        view
        returns (uint256);
    function getDynamicParams() external view returns (IEulerSwap.DynamicParams memory);
    /// @dev Uniswap-V2-style: transfer `tokenIn` to the pool first, then call swap
    ///      requesting the output. The pool deposits the input / withdraws (or borrows)
    ///      the output through its vaults and verifies the curve invariant.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @notice EulerRouter price dispatcher — used by tests to validate the cross oracles.
interface IEulerRouter {
    function getQuote(uint256 inAmount, address base, address quote) external view returns (uint256);
}
