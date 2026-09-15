// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IKickpadGraduationManager} from "../interfaces/IKickpadGraduationManager.sol";
import {IPonsV2LaunchFactory} from "../interfaces/IPonsV2.sol";

/// @title FlatMarket
/// @notice Refundable, fixed-value kickstart ledger for a future Pons V2 token.
/// @dev No launch token exists during the kickstart. Once the target fills,
/// Kickpad atomically launches and buys out Pons. Token payouts are a
/// separate permissionless `distribute` crank so the fill transaction does
/// not have to pay every contributor. First-time contributors post a
/// refundable distribution bond that pays whoever finishes their payout.
contract FlatMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DISTRIBUTION_GAS_RESERVE = 120_000;
    /// @notice Per-contributor ETH deposit that pays the `distribute` cranker.
    /// @dev Not a trading fee: it is excluded from `paid` / `totalRaised` and
    /// refunded on a full pre-graduation exit.
    uint256 public constant DISTRIBUTION_BOND = 0.00005 ether;

    struct LaunchTerms {
        string name;
        string symbol;
        string logo;
        string description;
        IPonsV2LaunchFactory.Socials socials;
        address creator;
        address feeVault;
        uint16 creatorTaxBps;
        uint256 launchConfigId;
        bytes32 expectedEconomics;
        bytes32 ponsSalt;
        uint256 kickstartTarget;
        address pairToken;
    }

    IKickpadGraduationManager public immutable graduationManager;
    address public immutable creator;
    address public immutable feeVault;
    address public immutable pairToken;
    uint16 public immutable creatorTaxBps;
    uint256 public immutable launchConfigId;
    bytes32 public immutable expectedEconomics;
    bytes32 public immutable ponsSalt;
    uint256 public immutable kickstartTarget;

    string public name;
    string public symbol;
    string public logo;
    string public description;
    IPonsV2LaunchFactory.Socials private _socials;

    uint256 public totalRaised;
    uint256 public launchFeeReserve;
    uint256 public distributionBondPool;
    mapping(address contributor => uint256 amount) public paid;
    mapping(address contributor => uint256 amount) public distributionBond;
    mapping(address contributor => bool) public isBuyer;
    mapping(address contributor => uint256) private _buyerIndex;
    address[] private _buyers;

    bool public graduated;
    address public token;
    address public curve;
    uint256 public tokensBought;
    uint256 public tokensDistributed;
    uint256 public nextDistributionIndex;
    bool public distributionComplete;

    error DirectEthNotAccepted();
    error DistributionNotReady();
    error InsufficientContribution(uint256 available, uint256 requested);
    error InsufficientDistributionBond(uint256 required, uint256 provided);
    error InsufficientLaunchFeeReserve(uint256 available, uint256 required);
    error InvalidGraduationManager();
    error InvalidLaunchTerms();
    error InvalidRecipient();
    error MarketGraduated();
    error MarketNotGraduated();
    error NoContribution();
    error NoExcessLaunchFee();
    error NotCreator();
    error PonsTokenNotReceived();
    error UnexpectedNativeValue();
    error WrongQuoteAsset();

    event ContributionAdded(
        address indexed payer, address indexed contributor, uint256 quoteAmount, uint256 totalRaised
    );
    event ContributionWithdrawn(
        address indexed contributor, address indexed recipient, uint256 quoteAmount, uint256 totalRaised
    );
    event ExcessQuoteRefunded(address indexed payer, uint256 quoteAmount);
    event LaunchFeeFunded(address indexed funder, uint256 amount, uint256 reserve);
    event ExcessLaunchFeeClaimed(address indexed creator, uint256 amount);
    event Graduated(address indexed token, address indexed curve, uint256 quoteSpent, uint256 tokensBought);
    event TokensDistributed(address indexed contributor, uint256 amount);
    event DistributionCompleted(uint256 distributed, uint256 creatorDust);
    event DistributionBondPosted(address indexed contributor, uint256 amount);
    event DistributionBondRefunded(address indexed contributor, address indexed recipient, uint256 amount);
    event DistributionBountyPaid(address indexed cranker, uint256 contributorsProcessed, uint256 amount);
    event DistributionBondLeftover(address indexed creator, uint256 amount);

    constructor(IKickpadGraduationManager graduationManager_, LaunchTerms memory terms) payable {
        if (address(graduationManager_) == address(0)) revert InvalidGraduationManager();
        if (
            bytes(terms.name).length == 0 || bytes(terms.symbol).length == 0 || terms.creator == address(0)
                || terms.feeVault == address(0) || terms.kickstartTarget == 0
        ) {
            revert InvalidLaunchTerms();
        }

        graduationManager = graduationManager_;
        creator = terms.creator;
        feeVault = terms.feeVault;
        creatorTaxBps = terms.creatorTaxBps;
        launchConfigId = terms.launchConfigId;
        expectedEconomics = terms.expectedEconomics;
        ponsSalt = terms.ponsSalt;
        kickstartTarget = terms.kickstartTarget;
        pairToken = terms.pairToken;

        name = terms.name;
        symbol = terms.symbol;
        logo = terms.logo;
        description = terms.description;
        _socials = terms.socials;
        launchFeeReserve = msg.value;
    }

    /// @notice Adds ETH weight to a contributor at the fixed kickstart value.
    /// @dev A first-time `recipient` must include `DISTRIBUTION_BOND` on top of
    /// the contribution. That bond is not credited to the kickstart.
    function buy(address recipient)
        external
        payable
        nonReentrant
        returns (uint256 quoteAccepted, uint256 quoteRefunded)
    {
        if (pairToken != address(0)) revert WrongQuoteAsset();
        if (graduated) revert MarketGraduated();
        if (recipient == address(0)) revert InvalidRecipient();
        if (msg.value == 0) revert NoContribution();

        uint256 value = msg.value;
        bool newBuyer = !isBuyer[recipient];
        if (newBuyer) {
            if (value < DISTRIBUTION_BOND) {
                revert InsufficientDistributionBond(DISTRIBUTION_BOND, value);
            }
            value -= DISTRIBUTION_BOND;
        }
        if (value == 0) revert NoContribution();

        (quoteAccepted, quoteRefunded) = _credit(msg.sender, recipient, value, newBuyer);
        if (totalRaised == kickstartTarget) _graduate();
        if (quoteRefunded != 0) {
            emit ExcessQuoteRefunded(msg.sender, quoteRefunded);
            Address.sendValue(payable(msg.sender), quoteRefunded);
        }
    }

    /// @notice Deposits `quoteIn` of this kickstart's pair token.
    /// @dev First-time `recipient` must send `DISTRIBUTION_BOND` as `msg.value`.
    /// Existing contributors must send no ETH. Excess quote is refunded in-kind.
    function buyQuote(uint256 quoteIn, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 quoteAccepted, uint256 quoteRefunded)
    {
        if (pairToken == address(0)) revert WrongQuoteAsset();
        if (graduated) revert MarketGraduated();
        if (recipient == address(0)) revert InvalidRecipient();
        if (quoteIn == 0) revert NoContribution();

        bool newBuyer = !isBuyer[recipient];
        uint256 requiredValue = newBuyer ? DISTRIBUTION_BOND : 0;
        if (newBuyer && msg.value < DISTRIBUTION_BOND) {
            revert InsufficientDistributionBond(DISTRIBUTION_BOND, msg.value);
        }
        if (msg.value != requiredValue) revert UnexpectedNativeValue();

        IERC20(pairToken).safeTransferFrom(msg.sender, address(this), quoteIn);
        (quoteAccepted, quoteRefunded) = _credit(msg.sender, recipient, quoteIn, newBuyer);
        if (totalRaised == kickstartTarget) _graduate();
        if (quoteRefunded != 0) {
            emit ExcessQuoteRefunded(msg.sender, quoteRefunded);
            IERC20(pairToken).safeTransfer(msg.sender, quoteRefunded);
        }
    }

    /// @notice Withdraws part of the caller's contribution before graduation.
    /// @dev A full exit refunds the distribution bond and drops the caller from
    /// the payout list.
    function sell(uint256 quoteAmount, address recipient) external nonReentrant returns (uint256 quoteOut) {
        if (graduated) revert MarketGraduated();
        if (recipient == address(0)) revert InvalidRecipient();
        if (quoteAmount == 0) revert NoContribution();

        uint256 available = paid[msg.sender];
        if (quoteAmount > available) revert InsufficientContribution(available, quoteAmount);

        paid[msg.sender] = available - quoteAmount;
        totalRaised -= quoteAmount;
        quoteOut = quoteAmount;

        if (paid[msg.sender] == 0) {
            uint256 bond = distributionBond[msg.sender];
            if (bond != 0) {
                distributionBond[msg.sender] = 0;
                distributionBondPool -= bond;
                quoteOut += bond;
                emit DistributionBondRefunded(msg.sender, recipient, bond);
            }
            _removeBuyer(msg.sender);
        }

        emit ContributionWithdrawn(msg.sender, recipient, quoteAmount, totalRaised);
        if (pairToken == address(0)) {
            Address.sendValue(payable(recipient), quoteOut);
        } else {
            IERC20(pairToken).safeTransfer(recipient, quoteAmount);
            if (quoteOut > quoteAmount) {
                Address.sendValue(payable(recipient), quoteOut - quoteAmount);
            }
        }
    }

    /// @notice Adds to the reserve used for Pons's launch fee.
    /// @dev Needed if Pons raises its fee after this market was created.
    function fundLaunchFee() external payable {
        if (graduated) revert MarketGraduated();
        if (msg.value == 0) revert NoContribution();
        launchFeeReserve += msg.value;
        emit LaunchFeeFunded(msg.sender, msg.value, launchFeeReserve);
    }

    /// @notice Pushes Pons tokens to the next contributors in the queue.
    /// @dev Permissionless crank. Pays `DISTRIBUTION_BOND` per funded contributor
    /// processed so a keeper can cover gas from the pool.
    function distribute(uint256 maxBuyers) external nonReentrant returns (uint256 processed) {
        if (!graduated) revert DistributionNotReady();
        processed = _distribute(maxBuyers);
    }

    /// @notice Returns Pons metadata supplied for this kickstart.
    function socials() external view returns (IPonsV2LaunchFactory.Socials memory) {
        return _socials;
    }

    function buyerCount() external view returns (uint256) {
        return _buyers.length;
    }

    function buyerAt(uint256 index) external view returns (address) {
        return _buyers[index];
    }

    function remainingQuote() external view returns (uint256) {
        return graduated ? 0 : kickstartTarget - totalRaised;
    }

    function progressBps() external view returns (uint256) {
        return (totalRaised * BPS_DENOMINATOR) / kickstartTarget;
    }

    /// @notice Lets the creator recover an unused launch-fee reserve after graduation.
    function claimExcessLaunchFee() external nonReentrant returns (uint256 amount) {
        if (msg.sender != creator) revert NotCreator();
        if (!graduated) revert MarketNotGraduated();
        amount = launchFeeReserve;
        if (amount == 0) revert NoExcessLaunchFee();
        launchFeeReserve = 0;

        emit ExcessLaunchFeeClaimed(msg.sender, amount);
        Address.sendValue(payable(msg.sender), amount);
    }

    function _graduate() private {
        uint256 ponsLaunchFee = graduationManager.currentPonsLaunchFee();
        if (launchFeeReserve < ponsLaunchFee) {
            revert InsufficientLaunchFeeReserve(launchFeeReserve, ponsLaunchFee);
        }

        graduated = true;
        launchFeeReserve -= ponsLaunchFee;

        IPonsV2LaunchFactory.TokenParams memory params = IPonsV2LaunchFactory.TokenParams({
            name: name,
            symbol: symbol,
            logo: logo,
            description: description,
            socials: _socials,
            creatorFeeRecipient: feeVault,
            creatorTaxBps: creatorTaxBps,
            buybackEnabled: false,
            expectedEconomics: expectedEconomics,
            salt: ponsSalt
        });

        (address launchedToken, address launchedCurve, uint256 amountBought) = pairToken == address(0)
            ? graduationManager.graduate{value: kickstartTarget + ponsLaunchFee}(
                params, launchConfigId, kickstartTarget
            )
            : _graduateWithPair(params, ponsLaunchFee);

        if (launchedToken == address(0) || amountBought == 0) revert PonsTokenNotReceived();
        token = launchedToken;
        curve = launchedCurve;
        tokensBought = amountBought;
        emit Graduated(launchedToken, launchedCurve, kickstartTarget, amountBought);
    }

    function _graduateWithPair(IPonsV2LaunchFactory.TokenParams memory params, uint256 ponsLaunchFee)
        private
        returns (address launchedToken, address launchedCurve, uint256 amountBought)
    {
        IERC20(pairToken).forceApprove(address(graduationManager), kickstartTarget);
        return graduationManager.graduate{value: ponsLaunchFee}(params, launchConfigId, kickstartTarget);
    }

    function _credit(address payer, address contributor, uint256 quoteIn, bool newBuyer)
        private
        returns (uint256 quoteAccepted, uint256 quoteRefunded)
    {
        uint256 remaining = kickstartTarget - totalRaised;
        quoteAccepted = quoteIn < remaining ? quoteIn : remaining;
        quoteRefunded = quoteIn - quoteAccepted;

        if (newBuyer) {
            isBuyer[contributor] = true;
            _buyers.push(contributor);
            _buyerIndex[contributor] = _buyers.length;
            distributionBond[contributor] = DISTRIBUTION_BOND;
            distributionBondPool += DISTRIBUTION_BOND;
            emit DistributionBondPosted(contributor, DISTRIBUTION_BOND);
        }
        paid[contributor] += quoteAccepted;
        totalRaised += quoteAccepted;
        emit ContributionAdded(payer, contributor, quoteAccepted, totalRaised);
    }

    function _distribute(uint256 maxBuyers) private returns (uint256 processed) {
        if (distributionComplete || maxBuyers == 0) return 0;

        IERC20 launchToken = IERC20(token);
        uint256 length = _buyers.length;
        uint256 index = nextDistributionIndex;
        uint256 funded;

        while (index < length && processed < maxBuyers) {
            if (processed > 0 && gasleft() < DISTRIBUTION_GAS_RESERVE) break;
            address contributor = _buyers[index];
            uint256 contribution = paid[contributor];
            if (contribution != 0) {
                uint256 amount = (tokensBought * contribution) / kickstartTarget;
                tokensDistributed += amount;
                if (distributionBond[contributor] != 0) {
                    delete distributionBond[contributor];
                    unchecked {
                        ++funded;
                    }
                }
                launchToken.safeTransfer(contributor, amount);
                emit TokensDistributed(contributor, amount);
            }
            unchecked {
                ++index;
                ++processed;
            }
        }
        nextDistributionIndex = index;

        if (index == length) {
            uint256 dust = launchToken.balanceOf(address(this));
            if (dust != 0) {
                tokensDistributed += dust;
                launchToken.safeTransfer(creator, dust);
            }
            distributionComplete = true;
            emit DistributionCompleted(tokensDistributed, dust);
        }

        uint256 bounty = DISTRIBUTION_BOND * funded;
        if (bounty > distributionBondPool) bounty = distributionBondPool;
        if (bounty != 0) {
            distributionBondPool -= bounty;
            emit DistributionBountyPaid(msg.sender, funded, bounty);
            Address.sendValue(payable(msg.sender), bounty);
        }

        if (distributionComplete && distributionBondPool != 0) {
            uint256 leftover = distributionBondPool;
            distributionBondPool = 0;
            emit DistributionBondLeftover(creator, leftover);
            Address.sendValue(payable(creator), leftover);
        }
    }

    function _removeBuyer(address contributor) private {
        uint256 stored = _buyerIndex[contributor];
        uint256 index = stored - 1;
        uint256 lastIndex = _buyers.length - 1;
        if (index != lastIndex) {
            address last = _buyers[lastIndex];
            _buyers[index] = last;
            _buyerIndex[last] = index + 1;
        }
        _buyers.pop();
        delete _buyerIndex[contributor];
        delete isBuyer[contributor];
    }

    receive() external payable {
        revert DirectEthNotAccepted();
    }
}
