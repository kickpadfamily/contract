// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {KickpadFactory} from "../src/KickpadFactory.sol";
import {IPonsV2FeeEscrow, IPonsV2LaunchFactory} from "../src/interfaces/IPonsV2.sol";

/// @notice Deploys Kickpad against canonical Pons V2 on Robinhood Chain.
contract DeployKickpad is Script {
    address internal constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address internal constant PONS_FEE_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;

    function run() external returns (KickpadFactory factory) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address platformFeeRecipient = vm.envAddress("PLATFORM_FEE_RECIPIENT");
        uint256 launchConfigId = vm.envUint("PONS_LAUNCH_CONFIG_ID");

        vm.startBroadcast(deployerPrivateKey);
        factory = new KickpadFactory(
            IPonsV2LaunchFactory(PONS_FACTORY), IPonsV2FeeEscrow(PONS_FEE_ESCROW), platformFeeRecipient, launchConfigId
        );
        vm.stopBroadcast();

        console2.log("KickpadFactory", address(factory));
        console2.log("PonsFactory", PONS_FACTORY);
        console2.log("PonsFeeEscrow", PONS_FEE_ESCROW);
        console2.log("PonsLaunchConfigId", launchConfigId);
        console2.log("PonsCanLaunchKickpad", IPonsV2LaunchFactory(PONS_FACTORY).canLaunch(address(factory)));
    }
}
