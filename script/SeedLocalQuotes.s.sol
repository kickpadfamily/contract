// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Local-only ERC-20 etched onto Robinhood quote-token addresses.
contract LocalQuoteToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Deploys 6- and 18-decimal templates whose bytecode localnet copies onto stock addresses.
contract SeedLocalQuotes is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        LocalQuoteToken token18 = new LocalQuoteToken("Quote", "Q", 18);
        LocalQuoteToken token6 = new LocalQuoteToken("USDG", "USDG", 6);
        vm.stopBroadcast();
        console2.log("quoteTemplate18", address(token18));
        console2.log("quoteTemplate6", address(token6));
    }
}
