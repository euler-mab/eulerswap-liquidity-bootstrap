// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {BootstrapMarketBase} from "../script/BootstrapMarketBase.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @notice Fork-less unit tests for the pure helpers — these run with NO RPC, so they
///         give the repo CI signal even where the mainnet-fork tests can't run.

/// @dev Exposes the base's internal pure helper for testing.
contract PriceHarness is BootstrapMarketBase {
    function price1to1(uint8 dec0, uint8 dec1) external pure returns (uint80 px, uint80 py) {
        return _price1to1(dec0, dec1);
    }
}

contract Price1to1Test is Test {
    PriceHarness internal h;

    function setUp() public {
        h = new PriceHarness();
    }

    /// @dev priceX/priceY must equal 10^(dec1 - dec0) so the human price is 1:1.
    function test_equal_decimals_is_unit() public view {
        (uint80 px, uint80 py) = h.price1to1(6, 6);
        assertEq(px, 1e18, "px");
        assertEq(py, 1e18, "py");
    }

    function test_6dp_token0_18dp_token1() public view {
        // dec1 >= dec0: px fixed at 1e18, py = 1e18 / 10^12.
        (uint80 px, uint80 py) = h.price1to1(6, 18);
        assertEq(px, 1e18, "px");
        assertEq(py, 1e6, "py");
        // ratio px/py == 10^(18-6) == 1e12
        assertEq(uint256(px) / py, 1e12, "ratio");
    }

    function test_18dp_token0_6dp_token1() public view {
        // dec0 > dec1: py fixed at 1e18, px = 1e18 / 10^12.
        (uint80 px, uint80 py) = h.price1to1(18, 6);
        assertEq(px, 1e6, "px");
        assertEq(py, 1e18, "py");
        assertEq(uint256(py) / px, 1e12, "ratio");
    }

    function test_8dp_token0_6dp_token1() public view {
        (uint80 px, uint80 py) = h.price1to1(8, 6);
        assertEq(px, 1e16, "px");
        assertEq(py, 1e18, "py");
    }

    /// @dev Both outputs must stay inside uint80 for every plausible stablecoin pair.
    function testFuzz_outputs_fit_uint80(uint8 dec0, uint8 dec1) public view {
        dec0 = uint8(bound(dec0, 0, 18));
        dec1 = uint8(bound(dec1, 0, 18));
        (uint80 px, uint80 py) = h.price1to1(dec0, dec1);
        // Non-zero (a zeroed divisor would break pricing) and within range by type.
        assertGt(px, 0, "px > 0");
        assertGt(py, 0, "py > 0");
    }
}

contract HookMinerTest is Test {
    function test_find_returns_address_with_required_flags() public view {
        address deployer = address(0xBEEF);
        bytes memory creationCode = hex"60806040523461001a57610010366100c8565b"; // arbitrary init code

        (address hook, bytes32 salt) = HookMiner.find(deployer, HookMiner.EULERSWAP_FLAGS, creationCode);

        // Low 14 bits encode exactly the EulerSwap flag set.
        assertEq(uint160(hook) & 0x3FFF, uint160(HookMiner.EULERSWAP_FLAGS), "flag bits");

        // The returned salt actually reproduces the address via CREATE2.
        address recomputed = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCode)))))
        );
        assertEq(recomputed, hook, "salt reproduces address");
    }

    function test_find_is_deterministic() public view {
        address deployer = address(0xCAFE);
        bytes memory cc = hex"6080604052";
        (address h1, bytes32 s1) = HookMiner.find(deployer, HookMiner.EULERSWAP_FLAGS, cc);
        (address h2, bytes32 s2) = HookMiner.find(deployer, HookMiner.EULERSWAP_FLAGS, cc);
        assertEq(h1, h2, "same address");
        assertEq(s1, s2, "same salt");
    }
}
