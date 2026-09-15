// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Canonical Pons V2 launch-factory surface used by Kickpad.
interface IPonsV2LaunchFactory {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    struct LaunchConfig {
        uint256 supply;
        uint256 curveFeeBps;
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        bool enabled;
    }

    function launchFee() external view returns (uint256);
    function maxCreatorTaxBps() external view returns (uint256);
    function canLaunch(address launcher) external view returns (bool);
    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory);
    function approvedPairTokens(address pairToken) external view returns (bool);
    function pairTokenEconomics(address pairToken)
        external
        view
        returns (uint256 phantomQuote, uint256 graduationThreshold, uint8 decimals);
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);

    function launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve);
}

/// @notice Canonical Pons V2 bonding-curve surface used by Kickpad.
interface IPonsV2BondingCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);

    function sellableTokens() external view returns (uint256);
    function sweepFees(uint256 minBuybackTokensOut) external;
}

/// @notice Canonical Pons V2 fee escrow surface used by per-launch vaults.
interface IPonsV2FeeEscrow {
    function balanceOf(address recipient) external view returns (uint256);
    function claim(uint256 amount) external returns (uint256 claimed);
}

/// @notice Canonical Pons V2 meme-hook surface used to sweep graduated pool fees.
interface IPonsV2MemeHook {
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}
