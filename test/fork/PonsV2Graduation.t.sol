// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {KickpadFactory} from "../../src/KickpadFactory.sol";
import {IPonsV2FeeEscrow, IPonsV2LaunchFactory} from "../../src/interfaces/IPonsV2.sol";
import {FlatMarket} from "../../src/market/FlatMarket.sol";

contract PonsV2GraduationForkTest is Test {
    using stdStorage for StdStorage;

    address internal constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address internal constant PONS_FEE_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;

    StdStorage internal store;
    bool internal forkEnabled;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl);
        forkEnabled = true;
    }

    function test_FillLaunchesAndDistributesCanonicalPonsToken() public {
        if (!forkEnabled) return;

        address platform = makeAddr("platform");
        address creator = makeAddr("creator");
        address buyer = makeAddr("buyer");
        KickpadFactory factory =
            new KickpadFactory(IPonsV2LaunchFactory(PONS_FACTORY), IPonsV2FeeEscrow(PONS_FEE_ESCROW), platform, 0);

        // Only needed if this fork predates Pons reopening public launching.
        if (!IPonsV2LaunchFactory(PONS_FACTORY).canLaunch(address(factory))) {
            store.target(PONS_FACTORY)
                .sig("whitelistedLaunchers(address)")
                .with_key(address(factory))
                .checked_write(true);
        }

        KickpadFactory.LaunchParams memory params = KickpadFactory.LaunchParams({
            name: "Kickpad Fork Test",
            symbol: "FAIRFORK",
            logo: "ipfs://kickpad-fork-test",
            description: "Canonical Pons V2 integration test",
            socials: IPonsV2LaunchFactory.Socials({twitter: "", telegram: "", discord: "", website: "", farcaster: ""}),
            creatorFeeRecipient: creator,
            creatorTaxBps: 0,
            salt: keccak256(abi.encode("kickpad-fork", block.number)),
            pairToken: address(0)
        });

        uint256 launchFee = factory.currentCreateFee();
        vm.deal(creator, launchFee);
        vm.prank(creator);
        (address marketAddress,) = factory.createLaunch{value: launchFee}(params);

        FlatMarket market = FlatMarket(payable(marketAddress));
        uint256 target = market.kickstartTarget();
        vm.deal(buyer, target + market.DISTRIBUTION_BOND());
        vm.prank(buyer);
        market.buy{value: target + market.DISTRIBUTION_BOND()}(buyer);

        assertTrue(market.graduated());
        assertFalse(market.distributionComplete());
        assertNotEq(market.token(), address(0));

        vm.prank(buyer);
        market.distribute(type(uint256).max);

        assertTrue(market.distributionComplete());
        assertGt(IERC20(market.token()).balanceOf(buyer), 0);
        assertEq(factory.marketForToken(market.token()), address(market));
    }
}
