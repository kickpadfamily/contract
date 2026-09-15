// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {KickpadFactory} from "../../src/KickpadFactory.sol";
import {PonsFeeVault} from "../../src/fees/PonsFeeVault.sol";
import {IPonsV2LaunchFactory} from "../../src/interfaces/IPonsV2.sol";
import {FlatMarket} from "../../src/market/FlatMarket.sol";
import {MockPonsFeeEscrow, MockPonsHook, MockPonsLaunchFactory, MockQuoteToken} from "../mocks/MockPonsV2.sol";

contract PonsKickstartTest is Test {
    uint256 internal constant PONS_LAUNCH_FEE = 0.0005 ether;
    uint256 internal constant KICKPAD_LAUNCH_FEE = 0.0005 ether;
    uint256 internal constant DISTRIBUTION_BOND = 0.00005 ether;

    MockPonsLaunchFactory internal pons;
    MockPonsFeeEscrow internal ponsEscrow;
    KickpadFactory internal factory;

    address internal launcher = makeAddr("launcher");
    address internal creator = makeAddr("creator");
    address internal platform = makeAddr("platform");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        pons = new MockPonsLaunchFactory();
        ponsEscrow = new MockPonsFeeEscrow();
        factory = new KickpadFactory(pons, ponsEscrow, platform, 0);

        vm.deal(launcher, 20 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function test_CreateLaunchDeploysDeterministicMarketAndFeeVault() public {
        KickpadFactory.LaunchParams memory params = _params(bytes32("create"), 0);
        (address predictedMarket, address predictedVault) = factory.predictLaunchAddresses(launcher, params);

        vm.prank(launcher);
        (address marketAddress, address vaultAddress) = factory.createLaunch{value: _createFee()}(params);

        assertEq(marketAddress, predictedMarket);
        assertEq(vaultAddress, predictedVault);
        assertEq(address(FlatMarket(payable(marketAddress)).graduationManager()), address(factory));
        assertEq(FlatMarket(payable(marketAddress)).creator(), creator);
        assertEq(FlatMarket(payable(marketAddress)).launchFeeReserve(), PONS_LAUNCH_FEE);
        assertEq(factory.creationFeesAccrued(), KICKPAD_LAUNCH_FEE);
        assertEq(factory.currentCreateFee(), _createFee());
        assertEq(factory.maxCreatorTaxBps(), pons.maxCreatorTaxBps());
        assertEq(PonsFeeVault(payable(vaultAddress)).creator(), creator);
        assertEq(PonsFeeVault(payable(vaultAddress)).platform(), platform);

        KickpadFactory.Launch memory launch = factory.getLaunch(marketAddress);
        assertEq(launch.market, marketAddress);
        assertEq(launch.feeVault, vaultAddress);
        assertEq(launch.token, address(0));
        assertFalse(launch.graduated);
        assertEq(factory.marketAt(0), marketAddress);
    }

    function test_ContributionsCanBePartiallyWithdrawnAtPar() public {
        FlatMarket market = _createMarket(bytes32("withdraw"), 0);

        vm.prank(alice);
        market.buy{value: 1 ether + DISTRIBUTION_BOND}(alice);
        assertEq(market.paid(alice), 1 ether);
        assertEq(market.totalRaised(), 1 ether);
        assertEq(market.distributionBond(alice), DISTRIBUTION_BOND);
        assertEq(market.distributionBondPool(), DISTRIBUTION_BOND);

        uint256 balanceBefore = bob.balance;
        vm.prank(alice);
        market.sell(0.4 ether, bob);

        assertEq(market.paid(alice), 0.6 ether);
        assertEq(market.totalRaised(), 0.6 ether);
        assertEq(bob.balance, balanceBefore + 0.4 ether);
    }

    function test_FinalContributionLaunchesPonsAndPushesTokensProRata() public {
        FlatMarket market = _createMarket(bytes32("graduate"), 0);
        uint256 target = market.kickstartTarget();
        uint256 first = 1 ether;

        vm.prank(alice);
        market.buy{value: first + DISTRIBUTION_BOND}(alice);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        market.buy{value: (target - first) + DISTRIBUTION_BOND}(bob);

        assertTrue(market.graduated());
        assertFalse(market.distributionComplete());
        assertEq(market.nextDistributionIndex(), 0);
        assertEq(market.distributionBondPool(), 2 * DISTRIBUTION_BOND);
        assertEq(IERC20(market.token()).balanceOf(address(market)), market.tokensBought());
        assertEq(bob.balance, bobBefore - (target - first) - DISTRIBUTION_BOND);
        assertEq(pons.lastCreatorFeeRecipient(), market.feeVault());
        assertEq(pons.lastCreatorTaxBps(), 0);
        assertFalse(pons.lastBuybackEnabled());
        assertEq(pons.lastExemption(), address(market));

        uint256 crankerBefore = launcher.balance;
        vm.prank(launcher);
        market.distribute(type(uint256).max);

        assertTrue(market.distributionComplete());
        assertEq(market.nextDistributionIndex(), 2);
        assertEq(market.distributionBondPool(), 0);
        assertEq(market.distributionBond(alice), 0);
        assertEq(market.distributionBond(bob), 0);
        assertEq(launcher.balance, crankerBefore + 2 * DISTRIBUTION_BOND);

        IERC20 token = IERC20(market.token());
        uint256 bought = market.tokensBought();
        uint256 expectedAlice = (bought * first) / target;
        assertEq(token.balanceOf(alice), expectedAlice);
        assertEq(token.balanceOf(bob), (bought * (target - first)) / target);
        assertEq(token.balanceOf(creator), bought - token.balanceOf(alice) - token.balanceOf(bob));

        KickpadFactory.Launch memory launch = factory.getLaunch(address(market));
        assertTrue(launch.graduated);
        assertEq(launch.token, address(token));
        assertEq(factory.marketForToken(address(token)), address(market));
        assertEq(launch.pairToken, address(0));
    }

    function test_QuoteTokenContributionsWithdrawAndGraduate() public {
        MockQuoteToken quote = new MockQuoteToken();
        pons.setPairToken(address(quote), 1 ether, 4.2 ether, 18);
        quote.mint(alice, 20 ether);
        quote.mint(bob, 20 ether);

        KickpadFactory.LaunchParams memory params = _params(bytes32("tsla"), 0);
        params.pairToken = address(quote);
        vm.prank(launcher);
        (address marketAddress,) = factory.createLaunch{value: _createFee()}(params);
        FlatMarket market = FlatMarket(payable(marketAddress));

        assertEq(market.pairToken(), address(quote));
        assertEq(factory.getLaunch(address(market)).pairToken, address(quote));
        uint256 target = market.kickstartTarget();
        assertEq(target, factory.previewKickstartTarget(0, address(quote)));

        vm.startPrank(alice);
        quote.approve(address(market), type(uint256).max);
        market.buyQuote{value: DISTRIBUTION_BOND}(1 ether, alice);
        vm.stopPrank();
        assertEq(market.paid(alice), 1 ether);
        assertEq(quote.balanceOf(address(market)), 1 ether);

        uint256 aliceQuoteBefore = quote.balanceOf(alice);
        uint256 aliceEthBefore = alice.balance;
        vm.prank(alice);
        market.sell(0.4 ether, alice);
        assertEq(market.paid(alice), 0.6 ether);
        assertEq(quote.balanceOf(alice), aliceQuoteBefore + 0.4 ether);
        assertEq(alice.balance, aliceEthBefore);

        uint256 remaining = target - market.totalRaised();
        vm.startPrank(bob);
        quote.approve(address(market), type(uint256).max);
        market.buyQuote{value: DISTRIBUTION_BOND}(remaining, bob);
        vm.stopPrank();

        assertTrue(market.graduated());
        assertEq(pons.lastPairToken(), address(quote));
        assertEq(IERC20(market.token()).balanceOf(address(market)), market.tokensBought());
        assertEq(quote.balanceOf(address(market)), 0);

        vm.prank(launcher);
        market.distribute(type(uint256).max);
        assertTrue(market.distributionComplete());
        assertGt(IERC20(market.token()).balanceOf(alice), 0);
        assertGt(IERC20(market.token()).balanceOf(bob), 0);
    }

    function test_UnapprovedPairTokenReverts() public {
        MockQuoteToken quote = new MockQuoteToken();
        KickpadFactory.LaunchParams memory params = _params(bytes32("bad-pair"), 0);
        params.pairToken = address(quote);
        vm.prank(launcher);
        vm.expectRevert(KickpadFactory.PairTokenNotApproved.selector);
        factory.createLaunch{value: _createFee()}(params);
    }

    function test_EthBuyOnQuoteMarketReverts() public {
        MockQuoteToken quote = new MockQuoteToken();
        pons.setPairToken(address(quote), 1 ether, 4.2 ether, 18);
        KickpadFactory.LaunchParams memory params = _params(bytes32("eth-on-quote"), 0);
        params.pairToken = address(quote);
        vm.prank(launcher);
        (address marketAddress,) = factory.createLaunch{value: _createFee()}(params);

        vm.prank(alice);
        vm.expectRevert(FlatMarket.WrongQuoteAsset.selector);
        FlatMarket(payable(marketAddress)).buy{value: 1 ether}(alice);
    }

    function test_CreateLaunchAndBuyQuoteDepositsPairToken() public {
        MockQuoteToken quote = new MockQuoteToken();
        pons.setPairToken(address(quote), 1 ether, 4.2 ether, 18);
        quote.mint(launcher, 20 ether);

        KickpadFactory.LaunchParams memory params = _params(bytes32("dev-quote"), 0);
        params.pairToken = address(quote);
        uint256 buyAmount = 1 ether;

        vm.startPrank(launcher);
        quote.approve(address(factory), buyAmount);
        (address marketAddress,, uint256 accepted) =
            factory.createLaunchAndBuyQuote{value: _createFee() + DISTRIBUTION_BOND}(params, launcher, buyAmount);
        vm.stopPrank();

        FlatMarket market = FlatMarket(payable(marketAddress));
        assertEq(accepted, buyAmount);
        assertEq(market.paid(launcher), buyAmount);
        assertEq(quote.balanceOf(address(market)), buyAmount);
        assertFalse(market.graduated());
    }

    function test_FinalContributionIsClampedAndRefunded() public {
        FlatMarket market = _createMarket(bytes32("clamp"), 0);
        uint256 target = market.kickstartTarget();
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        (uint256 accepted, uint256 refunded) = market.buy{value: target + 1 ether + DISTRIBUTION_BOND}(alice);

        assertEq(accepted, target);
        assertEq(refunded, 1 ether);
        assertEq(alice.balance, balanceBefore - target - DISTRIBUTION_BOND);
        assertTrue(market.graduated());
        assertFalse(market.distributionComplete());
    }

    function test_CreatorTaxIsIncludedInGrossKickstartTarget() public {
        FlatMarket market = _createMarket(bytes32("tax"), 100);
        uint256 expected = Math.mulDiv(4.2 ether + 1, 10_000, 9_800, Math.Rounding.Ceil);
        assertEq(market.kickstartTarget(), expected);
    }

    function test_CreatorTaxCanUseFullPonsMaximum() public {
        uint16 maxTax = uint16(pons.maxCreatorTaxBps());
        FlatMarket market = _createMarket(bytes32("pons-max-tax"), maxTax);
        assertEq(market.creatorTaxBps(), maxTax);
    }

    function test_CreatorTaxAbovePonsMaximumReverts() public {
        pons.setMaxCreatorTaxBps(250);
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(KickpadFactory.InvalidCreatorTax.selector, uint16(251)));
        factory.createLaunch{value: _createFee()}(_params(bytes32("over-cap"), 251));
    }

    function test_PlatformCanClaimKickpadLaunchFee() public {
        _createMarket(bytes32("fee-claim"), 0);
        uint256 beforeBal = platform.balance;
        vm.prank(platform);
        uint256 claimed = factory.claimProtocolFees();
        assertEq(claimed, KICKPAD_LAUNCH_FEE);
        assertEq(platform.balance, beforeBal + KICKPAD_LAUNCH_FEE);
        assertEq(factory.creationFeesAccrued(), 0);
    }

    function test_CreateLaunchAndBuyCreditsDevShare() public {
        KickpadFactory.LaunchParams memory params = _params(bytes32("dev-buy"), 0);
        uint256 target = factory.previewKickstartTarget(0);
        uint256 buyAmount = (target * 10) / 100;
        uint256 before = launcher.balance;

        vm.prank(launcher);
        (address marketAddress,, uint256 accepted) =
            factory.createLaunchAndBuy{value: _createFee() + buyAmount + DISTRIBUTION_BOND}(params, launcher);

        FlatMarket market = FlatMarket(payable(marketAddress));
        assertEq(accepted, buyAmount);
        assertEq(market.paid(launcher), buyAmount);
        assertEq(market.totalRaised(), buyAmount);
        assertEq(market.distributionBond(launcher), DISTRIBUTION_BOND);
        assertEq(launcher.balance, before - _createFee() - buyAmount - DISTRIBUTION_BOND);
        assertFalse(market.graduated());
    }

    function test_CreateLaunchAndBuyRefundsOverfillAndGraduates() public {
        KickpadFactory.LaunchParams memory params = _params(bytes32("dev-fill"), 0);
        uint256 target = factory.previewKickstartTarget(0);
        uint256 before = launcher.balance;

        vm.prank(launcher);
        (address marketAddress,, uint256 accepted) =
            factory.createLaunchAndBuy{value: _createFee() + target + 1 ether + DISTRIBUTION_BOND}(params, address(0));

        FlatMarket market = FlatMarket(payable(marketAddress));
        assertEq(accepted, target);
        assertEq(market.paid(launcher), target);
        assertTrue(market.graduated());
        assertFalse(market.distributionComplete());
        assertEq(launcher.balance, before - _createFee() - target - DISTRIBUTION_BOND);
        assertEq(IERC20(market.token()).balanceOf(address(market)), market.tokensBought());

        vm.prank(alice);
        market.distribute(type(uint256).max);
        assertTrue(market.distributionComplete());
        assertGt(IERC20(market.token()).balanceOf(launcher), 0);
    }

    function test_CreateLaunchAndBuyRevertsWithoutContribution() public {
        vm.prank(launcher);
        vm.expectRevert(KickpadFactory.NoDevBuy.selector);
        factory.createLaunchAndBuy{value: _createFee()}(_params(bytes32("no-dev-buy"), 0), launcher);
    }

    function test_EconomicsChangeRollsBackFinalContribution() public {
        FlatMarket market = _createMarket(bytes32("economics"), 0);
        uint256 target = market.kickstartTarget();
        pons.setEconomics(keccak256("changed"));

        vm.prank(alice);
        vm.expectRevert(KickpadFactory.PonsEconomicsChanged.selector);
        market.buy{value: target + DISTRIBUTION_BOND}(alice);

        assertEq(market.totalRaised(), 0);
        assertEq(market.paid(alice), 0);
        assertFalse(market.graduated());
    }

    function test_LaunchFeeIncreaseRequiresTopUpButThenGraduates() public {
        FlatMarket market = _createMarket(bytes32("fee-increase"), 0);
        uint256 target = market.kickstartTarget();
        uint256 newFee = PONS_LAUNCH_FEE * 2;
        pons.setLaunchFee(newFee);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(FlatMarket.InsufficientLaunchFeeReserve.selector, PONS_LAUNCH_FEE, newFee)
        );
        market.buy{value: target + DISTRIBUTION_BOND}(alice);

        market.fundLaunchFee{value: newFee - PONS_LAUNCH_FEE}();
        vm.prank(alice);
        market.buy{value: target + DISTRIBUTION_BOND}(alice);
        assertTrue(market.graduated());
    }

    function test_CreateRevertsWhileKickpadIsNotAllowedByPons() public {
        pons.setLaunchAllowed(false);
        vm.prank(launcher);
        vm.expectRevert(KickpadFactory.FactoryNotAllowedByPons.selector);
        factory.createLaunch{value: _createFee()}(_params(bytes32("gated"), 0));
    }

    function test_SameContributorIsEnumeratedOnlyOnce() public {
        FlatMarket market = _createMarket(bytes32("enumeration"), 0);
        vm.startPrank(alice);
        market.buy{value: 1 ether + DISTRIBUTION_BOND}(alice);
        market.sell(1 ether, alice);
        assertEq(market.buyerCount(), 0);
        assertEq(market.distributionBondPool(), 0);
        market.buy{value: 1 ether + DISTRIBUTION_BOND}(alice);
        vm.stopPrank();

        assertEq(market.buyerCount(), 1);
        assertEq(market.buyerAt(0), alice);
    }

    function test_FirstBuyRequiresDistributionBond() public {
        FlatMarket market = _createMarket(bytes32("need-bond"), 0);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                FlatMarket.InsufficientDistributionBond.selector, DISTRIBUTION_BOND, DISTRIBUTION_BOND - 1
            )
        );
        market.buy{value: DISTRIBUTION_BOND - 1}(alice);
    }

    function test_RepeatBuyDoesNotChargeSecondBond() public {
        FlatMarket market = _createMarket(bytes32("second-bond"), 0);

        vm.startPrank(alice);
        market.buy{value: 1 ether + DISTRIBUTION_BOND}(alice);
        market.buy{value: 0.5 ether}(alice);
        vm.stopPrank();

        assertEq(market.paid(alice), 1.5 ether);
        assertEq(market.distributionBond(alice), DISTRIBUTION_BOND);
        assertEq(market.distributionBondPool(), DISTRIBUTION_BOND);
        assertEq(market.buyerCount(), 1);
    }

    function test_PartialSellKeepsBond() public {
        FlatMarket market = _createMarket(bytes32("keep-bond"), 0);

        vm.prank(alice);
        market.buy{value: 1 ether + DISTRIBUTION_BOND}(alice);
        vm.prank(alice);
        market.sell(0.4 ether, alice);

        assertEq(market.paid(alice), 0.6 ether);
        assertEq(market.distributionBond(alice), DISTRIBUTION_BOND);
        assertEq(market.distributionBondPool(), DISTRIBUTION_BOND);
        assertEq(market.buyerCount(), 1);
        assertTrue(market.isBuyer(alice));
    }

    function test_FullSellRefundsBondAndRemovesBuyer() public {
        FlatMarket market = _createMarket(bytes32("refund-bond"), 0);
        uint256 before = alice.balance;

        vm.startPrank(alice);
        market.buy{value: 1 ether + DISTRIBUTION_BOND}(alice);
        market.sell(1 ether, bob);
        vm.stopPrank();

        assertEq(market.paid(alice), 0);
        assertEq(market.buyerCount(), 0);
        assertFalse(market.isBuyer(alice));
        assertEq(market.distributionBond(alice), 0);
        assertEq(market.distributionBondPool(), 0);
        assertEq(alice.balance, before - 1 ether - DISTRIBUTION_BOND);
        assertEq(bob.balance, 11 ether + DISTRIBUTION_BOND);
    }

    function test_SwapAndPopKeepsRemainingBuyers() public {
        FlatMarket market = _createMarket(bytes32("swap-pop"), 0);
        address carol = makeAddr("carol");
        vm.deal(carol, 5 ether);

        vm.prank(alice);
        market.buy{value: 1 ether + DISTRIBUTION_BOND}(alice);
        vm.prank(bob);
        market.buy{value: 1 ether + DISTRIBUTION_BOND}(bob);
        vm.prank(carol);
        market.buy{value: 1 ether + DISTRIBUTION_BOND}(carol);

        vm.prank(alice);
        market.sell(1 ether, alice);

        assertEq(market.buyerCount(), 2);
        assertFalse(market.isBuyer(alice));
        assertTrue(market.isBuyer(bob));
        assertTrue(market.isBuyer(carol));
        assertEq(market.buyerAt(0) == bob || market.buyerAt(0) == carol, true);
        assertEq(market.buyerAt(1) == bob || market.buyerAt(1) == carol, true);
        assertTrue(market.buyerAt(0) != market.buyerAt(1));
    }

    function test_CompleteDistributePaysNothing() public {
        FlatMarket market = _createMarket(bytes32("empty-crank"), 0);
        uint256 target = market.kickstartTarget();

        vm.prank(alice);
        market.buy{value: target + DISTRIBUTION_BOND}(alice);
        assertTrue(market.graduated());
        assertFalse(market.distributionComplete());

        vm.prank(alice);
        market.distribute(type(uint256).max);
        assertTrue(market.distributionComplete());

        uint256 crankerBefore = bob.balance;
        vm.prank(bob);
        uint256 processed = market.distribute(type(uint256).max);

        assertEq(processed, 0);
        assertEq(bob.balance, crankerBefore);
        assertEq(market.distributionBondPool(), 0);
    }

    function test_DistributeRevertsBeforeGraduation() public {
        FlatMarket market = _createMarket(bytes32("too-soon"), 0);
        vm.expectRevert(FlatMarket.DistributionNotReady.selector);
        market.distribute(1);
    }

    function test_PublicDistributePaysCrankerFromBondPool() public {
        FlatMarket market = _createMarket(bytes32("cranker"), 0);
        uint256 share = 0.05 ether;

        for (uint256 i = 1; i <= 20; ++i) {
            address user = makeAddr(string.concat("buyer-", vm.toString(i)));
            vm.deal(user, share + DISTRIBUTION_BOND);
            vm.prank(user);
            market.buy{value: share + DISTRIBUTION_BOND}(user);
        }

        uint256 remaining = market.remainingQuote();
        address filler = makeAddr("filler");
        vm.deal(filler, remaining + DISTRIBUTION_BOND);
        vm.prank(filler);
        market.buy{value: remaining + DISTRIBUTION_BOND}(filler);
        assertTrue(market.graduated());
        assertFalse(market.distributionComplete());
        uint256 pool = market.distributionBondPool();
        assertGt(pool, 0);

        uint256 crankerBefore = alice.balance;
        vm.prank(alice);
        uint256 processed = market.distribute(type(uint256).max);

        assertGt(processed, 0);
        assertTrue(market.distributionComplete());
        assertEq(market.distributionBondPool(), 0);
        assertEq(alice.balance, crankerBefore + pool);
        assertGt(IERC20(market.token()).balanceOf(filler), 0);
    }

    function _createMarket(bytes32 salt, uint16 taxBps) private returns (FlatMarket market) {
        vm.prank(launcher);
        (address marketAddress,) = factory.createLaunch{value: _createFee()}(_params(salt, taxBps));
        market = FlatMarket(payable(marketAddress));
    }

    function _createFee() private pure returns (uint256) {
        return KICKPAD_LAUNCH_FEE + PONS_LAUNCH_FEE;
    }

    function _params(bytes32 salt, uint16 taxBps) private view returns (KickpadFactory.LaunchParams memory params) {
        params = KickpadFactory.LaunchParams({
            name: "Pons Kickstart",
            symbol: "KICK",
            logo: "ipfs://logo",
            description: "A Kickpad Pons V2 kickstart",
            socials: IPonsV2LaunchFactory.Socials({
                twitter: "https://x.com/kickpad", telegram: "", discord: "", website: "", farcaster: ""
            }),
            creatorFeeRecipient: creator,
            creatorTaxBps: taxBps,
            salt: salt,
            pairToken: address(0)
        });
    }
}

contract PonsFeeVaultTest is Test {
    MockPonsFeeEscrow internal escrow;
    PonsFeeVault internal vault;

    address internal creator = makeAddr("creator");
    address internal platform = makeAddr("platform");

    function setUp() public {
        escrow = new MockPonsFeeEscrow();
        vault = new PonsFeeVault(escrow, creator, platform);
        vm.deal(address(this), 10 ether);
    }

    function test_HarvestSplitsPonsRevenueSeventyThirtyAndClaimsIndependently() public {
        escrow.credit{value: 10 ether}(address(vault));
        vault.harvest();

        assertEq(vault.creatorClaimable(), 7 ether);
        assertEq(vault.platformClaimable(), 3 ether);

        vm.prank(creator);
        vault.claim();
        vm.prank(platform);
        vault.claim();

        assertEq(creator.balance, 7 ether);
        assertEq(platform.balance, 3 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_SweepPoolAndHarvestCallsHookThenHarvests() public {
        MockPonsHook hook = new MockPonsHook();
        bytes32 poolId = keccak256("banana");
        escrow.credit{value: 1 ether}(address(vault));

        uint256 harvested = vault.sweepPoolAndHarvest(hook, poolId, 1, 0);

        assertEq(hook.sweeps(), 1);
        assertEq(hook.lastPoolId(), poolId);
        assertEq(hook.lastMinConversionQuoteOut(), 1);
        assertEq(harvested, 1 ether);
        assertEq(vault.creatorClaimable(), 0.7 ether);
    }

    function test_SweepPoolAndHarvestNoopsHarvestWhenEscrowIsEmpty() public {
        MockPonsHook hook = new MockPonsHook();
        uint256 harvested = vault.sweepPoolAndHarvest(hook, keccak256("empty"), 0, 0);
        assertEq(hook.sweeps(), 1);
        assertEq(harvested, 0);
        assertEq(vault.creatorClaimable(), 0);
    }

    function test_SameCreatorAndPlatformCanClaimBothShares() public {
        PonsFeeVault sharedVault = new PonsFeeVault(escrow, creator, creator);
        escrow.credit{value: 10 ether}(address(sharedVault));
        sharedVault.harvest();

        vm.prank(creator);
        sharedVault.claim();
        assertEq(creator.balance, 10 ether);
    }
}
