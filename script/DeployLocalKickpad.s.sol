// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {KickpadFactory} from "../src/KickpadFactory.sol";
import {MockPonsFeeEscrow, MockPonsLaunchFactory} from "../test/mocks/MockPonsV2.sol";

/// @notice Deploys Kickpad with deterministic Pons mocks for local UI development.
contract DeployLocalKickpad is Script {
    function run()
        external
        returns (KickpadFactory factory, MockPonsLaunchFactory ponsFactory, MockPonsFeeEscrow ponsFeeEscrow)
    {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address platformFeeRecipient = vm.envAddress("PLATFORM_FEE_RECIPIENT");

        vm.startBroadcast(deployerPrivateKey);
        ponsFactory = new MockPonsLaunchFactory();
        ponsFeeEscrow = new MockPonsFeeEscrow();
        factory = new KickpadFactory(ponsFactory, ponsFeeEscrow, platformFeeRecipient, 0);
        vm.stopBroadcast();

        console2.log("KickpadFactory", address(factory));
        console2.log("MockPonsLaunchFactory", address(ponsFactory));
        console2.log("MockPonsFeeEscrow", address(ponsFeeEscrow));
    }
}
