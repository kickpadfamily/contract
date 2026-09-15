// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PonsFeeVault} from "./fees/PonsFeeVault.sol";
import {IKickpadGraduationManager} from "./interfaces/IKickpadGraduationManager.sol";
import {IPonsV2BondingCurve, IPonsV2FeeEscrow, IPonsV2LaunchFactory} from "./interfaces/IPonsV2.sol";
import {KickpadMarketDeployer} from "./KickpadMarketDeployer.sol";
import {FlatMarket} from "./market/FlatMarket.sol";

/// @title KickpadFactory
/// @notice Creates refundable kickstarts and atomically launches filled ones on Pons V2.
contract KickpadFactory is IKickpadGraduationManager, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Kickpad's own kickstart creation fee, paid in addition to Pons's launch fee.
    uint256 public constant LAUNCH_FEE = 0.0005 ether;

    bytes32 private constant MARKET_SALT_DOMAIN = keccak256("KICKPAD_PONS_MARKET");
    bytes32 private constant VAULT_SALT_DOMAIN = keccak256("KICKPAD_PONS_FEE_VAULT");

    struct LaunchParams {
        string name;
        string symbol;
        string logo;
        string description;
        IPonsV2LaunchFactory.Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bytes32 salt;
        /// @notice Quote asset for the kickstart and later Pons launch. `address(0)` is ETH.
        address pairToken;
    }

    struct Launch {
        address market;
        address launcher;
        address creatorFeeRecipient;
        address feeVault;
        address token;
        address curve;
        uint16 creatorTaxBps;
        uint64 createdAt;
        uint256 kickstartTarget;
        bytes32 expectedEconomics;
        bool graduated;
        address pairToken;
    }

    IPonsV2LaunchFactory public immutable ponsFactory;
    IPonsV2FeeEscrow public immutable ponsFeeEscrow;
    address public immutable platformFeeRecipient;
    uint256 public immutable ponsLaunchConfigId;
    KickpadMarketDeployer public immutable marketDeployer;

    uint256 public creationFeesAccrued;
    uint256 public ponsRefundsAccrued;

    mapping(address market => Launch launch) private _launches;
    mapping(address token => address market) public marketForToken;
    mapping(address launcher => mapping(bytes32 salt => bool used)) public saltUsed;
    address[] private _markets;

    error FactoryNotAllowedByPons();
    error InvalidCreatorTax(uint16 creatorTaxBps);
    error InvalidGraduationCaller();
    error InvalidGraduationData();
    error InvalidPonsConfig();
    error InvalidPonsContracts();
    error InvalidRecipient();
    error InvalidLaunchFee(uint256 expected, uint256 actual);
    error NoDevBuy();
    error NoProtocolFees();
    error NotPlatformFeeRecipient();
    error PairTokenNotApproved();
    error PonsCurveNotCompleted();
    error PonsEconomicsChanged();
    error SaltAlreadyUsed();
    error UnknownLaunch();
    error WrongQuoteAsset();

    event LaunchCreated(
        address indexed market,
        address indexed launcher,
        address indexed feeVault,
        address creatorFeeRecipient,
        uint16 creatorTaxBps,
        uint256 kickstartTarget,
        bytes32 salt
    );
    event LaunchGraduated(address indexed market, address indexed token, address indexed curve, uint256 tokensBought);
    event PonsRefundAccrued(uint256 amount);
    event ProtocolFeesClaimed(address indexed recipient, uint256 amount);

    constructor(
        IPonsV2LaunchFactory ponsFactory_,
        IPonsV2FeeEscrow ponsFeeEscrow_,
        address platformFeeRecipient_,
        uint256 ponsLaunchConfigId_
    ) {
        if (
            address(ponsFactory_) == address(0) || address(ponsFactory_).code.length == 0
                || address(ponsFeeEscrow_) == address(0) || address(ponsFeeEscrow_).code.length == 0
        ) {
            revert InvalidPonsContracts();
        }
        if (platformFeeRecipient_ == address(0)) revert InvalidRecipient();

        IPonsV2LaunchFactory.LaunchConfig memory config = ponsFactory_.getLaunchConfig(ponsLaunchConfigId_);
        if (!config.enabled || config.graduationThreshold == 0 || config.curveFeeBps >= BPS_DENOMINATOR) {
            revert InvalidPonsConfig();
        }

        ponsFactory = ponsFactory_;
        ponsFeeEscrow = ponsFeeEscrow_;
        platformFeeRecipient = platformFeeRecipient_;
        ponsLaunchConfigId = ponsLaunchConfigId_;
        marketDeployer = new KickpadMarketDeployer();
    }

    /// @notice Creates a deterministic ETH kickstart and reserves Pons's current launch fee.
    /// @dev `msg.value` must equal Kickpad's `LAUNCH_FEE` plus Pons's current launch fee.
    function createLaunch(LaunchParams calldata params)
        external
        payable
        nonReentrant
        returns (address market, address feeVault)
    {
        uint256 expectedValue = LAUNCH_FEE + ponsFactory.launchFee();
        if (msg.value != expectedValue) revert InvalidLaunchFee(expectedValue, msg.value);
        return _createLaunch(params);
    }

    /// @notice Creates a kickstart and buys into it for `recipient` in the same transaction.
    /// @dev `msg.value` is Kickpad's fee, Pons's launch fee, the contribution, and
    /// `FlatMarket.DISTRIBUTION_BOND` when `recipient` is new. Excess beyond the
    /// kickstart target is refunded to the caller. Token payouts are a later
    /// `distribute` call, not part of this transaction.
    function createLaunchAndBuy(LaunchParams calldata params, address recipient)
        external
        payable
        nonReentrant
        returns (address market, address feeVault, uint256 quoteAccepted)
    {
        if (params.pairToken != address(0)) revert WrongQuoteAsset();
        uint256 createFee = LAUNCH_FEE + ponsFactory.launchFee();
        if (msg.value < createFee) revert InvalidLaunchFee(createFee, msg.value);
        uint256 buyAmount = msg.value - createFee;
        if (buyAmount == 0) revert NoDevBuy();

        (market, feeVault) = _createLaunch(params);
        if (recipient == address(0)) recipient = msg.sender;

        uint256 balanceBefore = address(this).balance;
        (quoteAccepted,) = FlatMarket(payable(market)).buy{value: buyAmount}(recipient);
        uint256 returned = address(this).balance - (balanceBefore - buyAmount);
        if (returned != 0) Address.sendValue(payable(msg.sender), returned);
    }

    /// @notice Creates a tokenized kickstart and deposits `quoteIn` of the pair token.
    /// @dev `msg.value` is Kickpad's fee, Pons's launch fee, and `FlatMarket.DISTRIBUTION_BOND`.
    function createLaunchAndBuyQuote(LaunchParams calldata params, address recipient, uint256 quoteIn)
        external
        payable
        nonReentrant
        returns (address market, address feeVault, uint256 quoteAccepted)
    {
        if (params.pairToken == address(0)) revert WrongQuoteAsset();
        if (quoteIn == 0) revert NoDevBuy();
        uint256 createFee = LAUNCH_FEE + ponsFactory.launchFee();
        uint256 bond = 0.00005 ether;
        uint256 expectedValue = createFee + bond;
        if (msg.value != expectedValue) revert InvalidLaunchFee(expectedValue, msg.value);

        (market, feeVault) = _createLaunch(params);
        if (recipient == address(0)) recipient = msg.sender;

        IERC20 pair = IERC20(params.pairToken);
        pair.safeTransferFrom(msg.sender, address(this), quoteIn);
        pair.forceApprove(market, quoteIn);
        (quoteAccepted,) = FlatMarket(payable(market)).buyQuote{value: bond}(quoteIn, recipient);
        uint256 leftover = pair.balanceOf(address(this));
        if (leftover != 0) pair.safeTransfer(msg.sender, leftover);
    }

    function _createLaunch(LaunchParams calldata params) private returns (address market, address feeVault) {
        // Pons's public gate, not a Kickpad-specific allowlist. While
        // launchEnabled is true this is true for every address.
        if (!ponsFactory.canLaunch(address(this))) revert FactoryNotAllowedByPons();
        if (params.creatorTaxBps > ponsFactory.maxCreatorTaxBps()) {
            revert InvalidCreatorTax(params.creatorTaxBps);
        }
        if (saltUsed[msg.sender][params.salt]) revert SaltAlreadyUsed();

        uint256 ponsLaunchFee = ponsFactory.launchFee();
        address creatorFeeRecipient = params.creatorFeeRecipient == address(0) ? msg.sender : params.creatorFeeRecipient;
        (bytes32 vaultSalt, bytes32 marketSalt) = _deriveSalts(msg.sender, params.salt);
        IPonsV2LaunchFactory.LaunchConfig memory config = ponsFactory.getLaunchConfig(ponsLaunchConfigId);
        if (!config.enabled) revert InvalidPonsConfig();

        (bytes32 expectedEconomics, uint256 kickstartTarget) = _launchEconomics(params.creatorTaxBps, params.pairToken);

        saltUsed[msg.sender][params.salt] = true;
        feeVault = address(new PonsFeeVault{salt: vaultSalt}(ponsFeeEscrow, creatorFeeRecipient, platformFeeRecipient));

        FlatMarket.LaunchTerms memory terms = FlatMarket.LaunchTerms({
            name: params.name,
            symbol: params.symbol,
            logo: params.logo,
            description: params.description,
            socials: params.socials,
            creator: creatorFeeRecipient,
            feeVault: feeVault,
            creatorTaxBps: params.creatorTaxBps,
            launchConfigId: ponsLaunchConfigId,
            expectedEconomics: expectedEconomics,
            ponsSalt: keccak256(abi.encode(msg.sender, params.salt)),
            kickstartTarget: kickstartTarget,
            pairToken: params.pairToken
        });
        creationFeesAccrued += LAUNCH_FEE;
        market = marketDeployer.deploy{value: ponsLaunchFee}(marketSalt, terms);

        _launches[market] = Launch({
            market: market,
            launcher: msg.sender,
            creatorFeeRecipient: creatorFeeRecipient,
            feeVault: feeVault,
            token: address(0),
            curve: address(0),
            creatorTaxBps: params.creatorTaxBps,
            createdAt: uint64(block.timestamp),
            kickstartTarget: kickstartTarget,
            expectedEconomics: expectedEconomics,
            graduated: false,
            pairToken: params.pairToken
        });
        _markets.push(market);

        emit LaunchCreated(
            market, msg.sender, feeVault, creatorFeeRecipient, params.creatorTaxBps, kickstartTarget, params.salt
        );
    }

    /// @inheritdoc IKickpadGraduationManager
    function currentPonsLaunchFee() external view returns (uint256) {
        return ponsFactory.launchFee();
    }

    /// @notice ETH required to open a kickstart: Kickpad's fee plus Pons's current launch fee.
    function currentCreateFee() external view returns (uint256) {
        return LAUNCH_FEE + ponsFactory.launchFee();
    }

    /// @notice Live Pons cap for the optional creator tax, in basis points.
    function maxCreatorTaxBps() external view returns (uint256) {
        return ponsFactory.maxCreatorTaxBps();
    }

    /// @notice Kickstart target for a given creator tax and quote asset.
    function previewKickstartTarget(uint16 creatorTaxBps) external view returns (uint256) {
        (, uint256 kickstartTarget) = _launchEconomics(creatorTaxBps, address(0));
        return kickstartTarget;
    }

    /// @notice Kickstart target for a given creator tax, quoted in `pairToken`.
    function previewKickstartTarget(uint16 creatorTaxBps, address pairToken) external view returns (uint256) {
        (, uint256 kickstartTarget) = _launchEconomics(creatorTaxBps, pairToken);
        return kickstartTarget;
    }

    /// @inheritdoc IKickpadGraduationManager
    function graduate(IPonsV2LaunchFactory.TokenParams calldata params, uint256 launchConfigId, uint256 kickstartTarget)
        external
        payable
        returns (address token, address curve, uint256 tokensBought)
    {
        Launch storage launch = _launches[msg.sender];
        if (launch.market == address(0)) revert UnknownLaunch();
        if (launch.market != msg.sender || launch.graduated) revert InvalidGraduationCaller();

        uint256 balanceBefore = address(this).balance - msg.value;
        uint256 launchFee = ponsFactory.launchFee();
        address pairToken = launch.pairToken;
        if (pairToken == address(0)) {
            if (msg.value != launchFee + kickstartTarget) {
                revert InvalidLaunchFee(launchFee + kickstartTarget, msg.value);
            }
        } else if (msg.value != launchFee) {
            revert InvalidLaunchFee(launchFee, msg.value);
        }
        if (
            launchConfigId != ponsLaunchConfigId || kickstartTarget != launch.kickstartTarget
                || params.creatorFeeRecipient != launch.feeVault || params.creatorTaxBps != launch.creatorTaxBps
                || params.buybackEnabled || params.expectedEconomics != launch.expectedEconomics
        ) {
            revert InvalidGraduationData();
        }
        if (ponsFactory.previewLaunchEconomics(launchConfigId, pairToken) != launch.expectedEconomics) {
            revert PonsEconomicsChanged();
        }

        // Mark first so a nested createLaunchAndBuy fill cannot double-graduate.
        launch.graduated = true;

        if (pairToken != address(0)) {
            IERC20(pairToken).safeTransferFrom(msg.sender, address(this), kickstartTarget);
        }

        address[] memory exemptions = new address[](1);
        exemptions[0] = msg.sender;
        (token, curve) = ponsFactory.launchToken{value: launchFee}(params, launchConfigId, pairToken, exemptions);

        if (pairToken == address(0)) {
            tokensBought = IPonsV2BondingCurve(curve).buy{value: kickstartTarget}(kickstartTarget, 1, msg.sender);
        } else {
            IERC20(pairToken).forceApprove(curve, kickstartTarget);
            tokensBought = IPonsV2BondingCurve(curve).buy(kickstartTarget, 1, msg.sender);
        }
        if (IPonsV2BondingCurve(curve).sellableTokens() != 0) revert PonsCurveNotCompleted();
        if (IERC20(token).balanceOf(msg.sender) < tokensBought) revert PonsCurveNotCompleted();

        launch.token = token;
        launch.curve = curve;
        marketForToken[token] = msg.sender;

        uint256 refund = address(this).balance - balanceBefore;
        if (refund != 0) {
            ponsRefundsAccrued += refund;
            emit PonsRefundAccrued(refund);
        }
        if (pairToken != address(0)) {
            uint256 leftover = IERC20(pairToken).balanceOf(address(this));
            if (leftover != 0) IERC20(pairToken).safeTransfer(launch.feeVault, leftover);
        }
        emit LaunchGraduated(msg.sender, token, curve, tokensBought);
    }

    function getLaunch(address market) external view returns (Launch memory) {
        Launch memory launch = _launches[market];
        if (launch.market == address(0)) revert UnknownLaunch();
        return launch;
    }

    function launchCount() external view returns (uint256) {
        return _markets.length;
    }

    function marketAt(uint256 index) external view returns (address) {
        return _markets[index];
    }

    function predictLaunchAddresses(address launcher, LaunchParams calldata params)
        external
        view
        returns (address market, address feeVault)
    {
        address creatorFeeRecipient = params.creatorFeeRecipient == address(0) ? launcher : params.creatorFeeRecipient;
        (bytes32 vaultSalt, bytes32 marketSalt) = _deriveSalts(launcher, params.salt);

        bytes32 vaultInitCodeHash = keccak256(
            abi.encodePacked(
                type(PonsFeeVault).creationCode, abi.encode(ponsFeeEscrow, creatorFeeRecipient, platformFeeRecipient)
            )
        );
        feeVault = Create2.computeAddress(vaultSalt, vaultInitCodeHash, address(this));

        (bytes32 expectedEconomics, uint256 kickstartTarget) = _launchEconomics(params.creatorTaxBps, params.pairToken);
        FlatMarket.LaunchTerms memory terms = FlatMarket.LaunchTerms({
            name: params.name,
            symbol: params.symbol,
            logo: params.logo,
            description: params.description,
            socials: params.socials,
            creator: creatorFeeRecipient,
            feeVault: feeVault,
            creatorTaxBps: params.creatorTaxBps,
            launchConfigId: ponsLaunchConfigId,
            expectedEconomics: expectedEconomics,
            ponsSalt: keccak256(abi.encode(launcher, params.salt)),
            kickstartTarget: kickstartTarget,
            pairToken: params.pairToken
        });
        market = Create2.computeAddress(marketSalt, marketDeployer.marketInitCodeHash(terms), address(marketDeployer));
    }

    function claimProtocolFees() external nonReentrant returns (uint256 amount) {
        if (msg.sender != platformFeeRecipient) revert NotPlatformFeeRecipient();
        amount = creationFeesAccrued + ponsRefundsAccrued;
        if (amount == 0) revert NoProtocolFees();
        creationFeesAccrued = 0;
        ponsRefundsAccrued = 0;

        emit ProtocolFeesClaimed(msg.sender, amount);
        Address.sendValue(payable(msg.sender), amount);
    }

    function _launchEconomics(uint16 creatorTaxBps, address pairToken)
        private
        view
        returns (bytes32 expectedEconomics, uint256 kickstartTarget)
    {
        IPonsV2LaunchFactory.LaunchConfig memory config = ponsFactory.getLaunchConfig(ponsLaunchConfigId);
        if (!config.enabled || config.curveFeeBps >= BPS_DENOMINATOR) revert InvalidPonsConfig();

        uint256 threshold = config.graduationThreshold;
        if (pairToken == address(0)) {
            if (threshold == 0) revert InvalidPonsConfig();
        } else {
            if (!ponsFactory.approvedPairTokens(pairToken)) revert PairTokenNotApproved();
            (uint256 phantomQuote, uint256 pairThreshold,) = ponsFactory.pairTokenEconomics(pairToken);
            if (phantomQuote == 0 || pairThreshold == 0) revert PairTokenNotApproved();
            threshold = pairThreshold;
        }

        expectedEconomics = ponsFactory.previewLaunchEconomics(ponsLaunchConfigId, pairToken);
        kickstartTarget = _grossKickstartTarget(threshold, config.curveFeeBps, creatorTaxBps);
    }

    function _grossKickstartTarget(uint256 graduationThreshold, uint256 curveFeeBps, uint256 creatorTaxBps)
        private
        pure
        returns (uint256)
    {
        uint256 totalFeeBps = curveFeeBps + creatorTaxBps;
        if (totalFeeBps >= BPS_DENOMINATOR) revert InvalidPonsConfig();

        // Pons charges fees before curve pricing. One extra net wei covers
        // the curve's exact-output rounding at the reserved-token boundary.
        return Math.mulDiv(graduationThreshold + 1, BPS_DENOMINATOR, BPS_DENOMINATOR - totalFeeBps, Math.Rounding.Ceil);
    }

    function _deriveSalts(address launcher, bytes32 salt) private pure returns (bytes32 vaultSalt, bytes32 marketSalt) {
        bytes32 namespacedSalt = keccak256(abi.encode(launcher, salt));
        vaultSalt = keccak256(abi.encode(namespacedSalt, VAULT_SALT_DOMAIN));
        marketSalt = keccak256(abi.encode(namespacedSalt, MARKET_SALT_DOMAIN));
    }

    receive() external payable {}
}
