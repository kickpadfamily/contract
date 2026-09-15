// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {KickpadFactory} from "../src/KickpadFactory.sol";
import {IPonsV2LaunchFactory} from "../src/interfaces/IPonsV2.sol";
import {FlatMarket} from "../src/market/FlatMarket.sol";

/// @notice Seeds a local deployment with one open test kickstart and one filled Pons launch.
contract SeedLocalnet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        KickpadFactory factory = KickpadFactory(payable(vm.envAddress("FACTORY")));
        address buyer = vm.addr(deployerPrivateKey);
        uint256 launchFee = factory.currentCreateFee();

        KickpadFactory.LaunchParams memory liveParams = _params(
            "Test Kickstart",
            "TEST",
            vm.envOr("LIVE_METADATA_URI", string("")),
            "Localnet test kickstart. Fill it to launch a real Pons V2 token copied from Robinhood on demand.",
            keccak256("kickpad.seed.live")
        );
        KickpadFactory.LaunchParams memory completedParams = _params(
            "Graduated Test",
            "DONE",
            vm.envOr("SMOKE_METADATA_URI", string("")),
            "Seeded Kickpad kickstart that already launched on canonical Pons V2.",
            keccak256("kickpad.seed.completed")
        );

        vm.startBroadcast(deployerPrivateKey);

        (address liveMarket,) = factory.createLaunch{value: launchFee}(liveParams);
        uint256 bond = FlatMarket(payable(liveMarket)).DISTRIBUTION_BOND();
        FlatMarket(payable(liveMarket)).buy{value: 0.1 ether + bond}(buyer);
        console2.log("live market", liveMarket);
        console2.log("live raised", FlatMarket(payable(liveMarket)).totalRaised());
        console2.log("live target", FlatMarket(payable(liveMarket)).kickstartTarget());

        (address completedMarket,) = factory.createLaunch{value: launchFee}(completedParams);
        uint256 target = FlatMarket(payable(completedMarket)).kickstartTarget();
        FlatMarket(payable(completedMarket)).buy{value: target + bond}(buyer);
        FlatMarket(payable(completedMarket)).distribute(type(uint256).max);
        console2.log("completed market", completedMarket);
        console2.log("Pons token", FlatMarket(payable(completedMarket)).token());

        vm.stopBroadcast();
    }

    function _params(
        string memory name,
        string memory symbol,
        string memory metadataUri,
        string memory description,
        bytes32 salt
    ) private pure returns (KickpadFactory.LaunchParams memory params) {
        params = KickpadFactory.LaunchParams({
            name: name,
            symbol: symbol,
            logo: metadataUri,
            description: description,
            socials: IPonsV2LaunchFactory.Socials({twitter: "", telegram: "", discord: "", website: "", farcaster: ""}),
            creatorFeeRecipient: address(0),
            creatorTaxBps: 0,
            salt: salt,
            pairToken: address(0)
        });
    }
}
