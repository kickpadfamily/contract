// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IKickpadGraduationManager} from "./interfaces/IKickpadGraduationManager.sol";
import {FlatMarket} from "./market/FlatMarket.sol";

/// @notice Holds FlatMarket creation bytecode so KickpadFactory stays under EIP-170.
contract KickpadMarketDeployer {
    error OnlyFactory();

    address public immutable factory;

    constructor() {
        factory = msg.sender;
    }

    function deploy(bytes32 salt, FlatMarket.LaunchTerms calldata terms) external payable returns (address market) {
        if (msg.sender != factory) revert OnlyFactory();
        market = address(new FlatMarket{salt: salt, value: msg.value}(IKickpadGraduationManager(factory), terms));
    }

    function marketInitCodeHash(FlatMarket.LaunchTerms memory terms) external view returns (bytes32) {
        return keccak256(
            abi.encodePacked(type(FlatMarket).creationCode, abi.encode(IKickpadGraduationManager(factory), terms))
        );
    }
}
