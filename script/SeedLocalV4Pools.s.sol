// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LocalQuoteToken} from "./SeedLocalQuotes.s.sol";
import {LocalV4Liquidity} from "./LocalV4Liquidity.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @notice Seeds ETH/quote Uniswap v4 pools on localnet so Kickpad can swap ETH into stocks.
contract SeedLocalV4Pools is Script {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int256 constant LIQUIDITY = 2e20;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    address[17] internal QUOTES = [
        0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168,
        0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9,
        0x86923f96303D656E4aa86D9d42D1e57ad2023fdC,
        0x12f190a9F9d7D37a250758b26824B97CE941bF54,
        0x6330D8C3178a418788dF01a47479c0ce7CCF450b,
        0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5,
        0x1b0E319c6A659F002271B69dB8A7df2F911c153E,
        0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3,
        0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35,
        0xe93237C50D904957Cf27E7B1133b510C669c2e74,
        0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD,
        0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC,
        0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A,
        0xB90A19fF0Af67f7779afF50A882A9CfF42446400,
        0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa,
        0x117cc2133c37B721F49dE2A7a74833232B3B4C0C,
        0x322F0929c4625eD5bAd873c95208D54E1c003b2d
    ];

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        LocalV4Liquidity lp = new LocalV4Liquidity(POOL_MANAGER);
        for (uint256 i; i < QUOTES.length; ++i) {
            address quote = QUOTES[i];
            uint8 decimals = IERC20Decimals(quote).decimals();
            if (decimals != 18) continue;
            uint256 inventory = 100_000_000 * (10 ** uint256(decimals));
            LocalQuoteToken(quote).mint(address(lp), inventory);
            lp.seed{value: 500 ether}(
                quote, FEE, TICK_SPACING, SQRT_PRICE_1_1, LIQUIDITY, int24(0)
            );
            console2.log("pooled", quote);
        }

        vm.stopBroadcast();
        console2.log("liquidityHelper", address(lp));
    }
}
