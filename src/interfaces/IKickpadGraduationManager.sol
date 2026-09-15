// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPonsV2LaunchFactory} from "./IPonsV2.sol";

/// @notice Authenticated handoff from a filled Kickpad market into Pons V2.
interface IKickpadGraduationManager {
    function currentPonsLaunchFee() external view returns (uint256);

    function graduate(IPonsV2LaunchFactory.TokenParams calldata params, uint256 launchConfigId, uint256 kickstartTarget)
        external
        payable
        returns (address token, address curve, uint256 tokensBought);
}
