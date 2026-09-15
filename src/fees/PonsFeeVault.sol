// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPonsV2BondingCurve, IPonsV2FeeEscrow, IPonsV2MemeHook} from "../interfaces/IPonsV2.sol";

/// @title PonsFeeVault
/// @notice Per-launch receiver that splits Pons creator revenue 70/30.
/// @dev A vault is unique to one Kickpad launch because Pons escrow balances
/// are keyed by recipient rather than launch token.
contract PonsFeeVault is ReentrancyGuard {
    uint256 public constant CREATOR_SHARE_BPS = 7_000;
    uint256 public constant PLATFORM_SHARE_BPS = 3_000;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    IPonsV2FeeEscrow public immutable ponsFeeEscrow;
    address public immutable creator;
    address public immutable platform;

    uint256 public creatorClaimable;
    uint256 public platformClaimable;

    error DirectEthNotAccepted();
    error InvalidRecipient();
    error NoFeesAvailable();
    error NotBeneficiary();

    event FeesHarvested(uint256 amount, uint256 creatorAmount, uint256 platformAmount);
    event FeesClaimed(address indexed recipient, uint256 amount);

    constructor(IPonsV2FeeEscrow ponsFeeEscrow_, address creator_, address platform_) {
        if (address(ponsFeeEscrow_) == address(0) || creator_ == address(0) || platform_ == address(0)) {
            revert InvalidRecipient();
        }

        ponsFeeEscrow = ponsFeeEscrow_;
        creator = creator_;
        platform = platform_;
    }

    /// @notice Pulls every currently credited native fee from Pons escrow.
    function harvest() public nonReentrant returns (uint256 amount) {
        amount = ponsFeeEscrow.balanceOf(address(this));
        if (amount == 0) revert NoFeesAvailable();

        ponsFeeEscrow.claim(amount);

        uint256 platformAmount = (amount * PLATFORM_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 creatorAmount = amount - platformAmount;
        creatorClaimable += creatorAmount;
        platformClaimable += platformAmount;

        emit FeesHarvested(amount, creatorAmount, platformAmount);
    }

    /// @notice Asks a live Pons curve to sweep, then harvests the resulting credit.
    /// @dev The vault is the Pons creator recipient, so the curve recognizes this call.
    function sweepCurveAndHarvest(IPonsV2BondingCurve curve, uint256 minBuybackTokensOut)
        external
        returns (uint256 amount)
    {
        curve.sweepFees(minBuybackTokensOut);
        amount = harvest();
    }

    /// @notice Asks the Pons hook to sweep a graduated pool, then harvests any new credit.
    /// @dev The vault is the Pons creator recipient, so quote-only sweeps are authorized.
    /// Token conversion still requires Pons's fee-sweep operator.
    function sweepPoolAndHarvest(
        IPonsV2MemeHook hook,
        bytes32 poolId,
        uint256 minConversionQuoteOut,
        uint256 minBuybackTokensOut
    ) external returns (uint256 amount) {
        hook.sweepPoolFees(poolId, minConversionQuoteOut, minBuybackTokensOut);
        if (ponsFeeEscrow.balanceOf(address(this)) == 0) {
            return 0;
        }
        amount = harvest();
    }

    /// @notice Claims the caller's complete Kickpad-side fee balance.
    function claim() external nonReentrant returns (uint256 amount) {
        bool isCreator = msg.sender == creator;
        bool isPlatform = msg.sender == platform;
        if (!isCreator && !isPlatform) revert NotBeneficiary();

        if (isCreator) {
            amount += creatorClaimable;
            creatorClaimable = 0;
        }
        if (isPlatform) {
            amount += platformClaimable;
            platformClaimable = 0;
        }
        if (amount == 0) revert NoFeesAvailable();

        emit FeesClaimed(msg.sender, amount);
        Address.sendValue(payable(msg.sender), amount);
    }

    receive() external payable {
        if (msg.sender != address(ponsFeeEscrow)) revert DirectEthNotAccepted();
    }
}
