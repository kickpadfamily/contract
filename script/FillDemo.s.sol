// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {KickpadFactory} from "../src/KickpadFactory.sol";
import {IPonsV2LaunchFactory} from "../src/interfaces/IPonsV2.sol";
import {FlatMarket} from "../src/market/FlatMarket.sol";

/// @notice Localnet demo: 1% creator fee, several buyers, then a fill.
contract FillDemo is Script {
    uint256 internal constant CREATOR_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant ALICE_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant BOB_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant CAROL_KEY = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant DAVE_KEY = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;

    function run() external {
        KickpadFactory factory = KickpadFactory(payable(vm.envAddress("FACTORY")));
        uint256 createFee = factory.currentCreateFee();
        uint256 target = factory.previewKickstartTarget(100);
        bytes32 salt = keccak256(abi.encode("kickpad.fill-demo", block.timestamp, block.number));

        KickpadFactory.LaunchParams memory params = KickpadFactory.LaunchParams({
            name: "Crank Demo",
            symbol: "CRANK",
            logo: "",
            description: "Localnet fill demo with a 1% creator fee so we can watch the cranker, distribution, and vault.",
            socials: IPonsV2LaunchFactory.Socials({twitter: "", telegram: "", discord: "", website: "", farcaster: ""}),
            creatorFeeRecipient: address(0),
            creatorTaxBps: 100,
            salt: salt,
            pairToken: address(0)
        });

        vm.startBroadcast(CREATOR_KEY);
        (address market, address feeVault) = factory.createLaunch{value: createFee}(params);
        vm.stopBroadcast();

        uint256 bond = FlatMarket(payable(market)).DISTRIBUTION_BOND();
        console2.log("market", market);
        console2.log("feeVault", feeVault);
        console2.log("creator tax bps", uint256(100));
        console2.log("kickstart target", target);
        console2.log("create fee", createFee);
        console2.log("distribution bond", bond);

        _buy(market, ALICE_KEY, 0.8 ether + bond);
        _buy(market, BOB_KEY, 1.1 ether + bond);
        _buy(market, CAROL_KEY, 0.65 ether + bond);

        uint256 raised = FlatMarket(payable(market)).totalRaised();
        uint256 remaining = target - raised;
        console2.log("raised before fill", raised);
        console2.log("remaining", remaining);

        vm.startBroadcast(DAVE_KEY);
        FlatMarket(payable(market)).buy{value: remaining + bond}(vm.addr(DAVE_KEY));
        vm.stopBroadcast();

        console2.log("graduated", FlatMarket(payable(market)).graduated());
        console2.log("token", FlatMarket(payable(market)).token());
        console2.log("curve", FlatMarket(payable(market)).curve());
        console2.log("distribution complete", FlatMarket(payable(market)).distributionComplete());
        console2.log("alice paid", FlatMarket(payable(market)).paid(vm.addr(ALICE_KEY)));
        console2.log("bob paid", FlatMarket(payable(market)).paid(vm.addr(BOB_KEY)));
        console2.log("carol paid", FlatMarket(payable(market)).paid(vm.addr(CAROL_KEY)));
        console2.log("dave paid", FlatMarket(payable(market)).paid(vm.addr(DAVE_KEY)));
    }

    function _buy(address market, uint256 key, uint256 value) private {
        vm.startBroadcast(key);
        FlatMarket(payable(market)).buy{value: value}(vm.addr(key));
        vm.stopBroadcast();
    }
}
