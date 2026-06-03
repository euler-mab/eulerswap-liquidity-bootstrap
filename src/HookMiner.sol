// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title HookMiner
/// @notice Mines a CREATE2 salt so the deployed EulerSwap pool address encodes the
///         Uniswap V4 hook-permission flags in its low 14 bits. EulerSwap pools
///         double as V4 hooks, so deployPool reverts (HookAddressNotValid) unless
///         the address bits match. Vendored from euler-swap/test/utils/HookMiner.sol.
/// @dev    Runs locally (off-chain during `forge script`/tests) — never broadcast.
library HookMiner {
    /// @notice Bottom 14 bits — the Uniswap V4 hook flag region (Hooks.ALL_HOOK_MASK).
    uint160 constant FLAG_MASK = 0x3FFF;

    /// @notice EulerSwap's required hook flags:
    ///   BEFORE_INITIALIZE(1<<13) | BEFORE_ADD_LIQUIDITY(1<<11) | BEFORE_SWAP(1<<7)
    ///   | BEFORE_DONATE(1<<5) | BEFORE_SWAP_RETURNS_DELTA(1<<3) == 0x28A8.
    uint160 constant EULERSWAP_FLAGS = 0x28A8;

    /// @dev Iteration cap carried over from the canonical Uniswap/EulerSwap miner.
    ///      A valid salt must match all 14 low bits (P = 1/2^14), so this bound gives
    ///      ~10 expected hits — finding one in practice is near-certain.
    uint256 constant MAX_LOOP = 160_444;

    /// @param deployer    The CREATE2 deployer — the EulerSwap factory.
    /// @param flags       Desired low-14-bit flags (use EULERSWAP_FLAGS).
    /// @param creationCode Pool init code from factory.creationCode(staticParams).
    /// @return hookAddress The mined pool address.
    /// @return salt        The salt that produces it.
    function find(address deployer, uint160 flags, bytes memory creationCode)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        flags = flags & FLAG_MASK;
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 s; s < MAX_LOOP; s++) {
            hookAddress = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, s, initCodeHash))))
            );
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(s));
            }
        }
        revert("HookMiner: no salt found");
    }
}
