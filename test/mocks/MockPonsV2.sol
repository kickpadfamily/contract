// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {
    IPonsV2BondingCurve,
    IPonsV2FeeEscrow,
    IPonsV2LaunchFactory,
    IPonsV2MemeHook
} from "../../src/interfaces/IPonsV2.sol";

contract MockPonsToken is ERC20 {
    uint256 public gasBurn;

    constructor(string memory name_, string memory symbol_, address recipient) ERC20(name_, symbol_) {
        _mint(recipient, 1_000_000_000 ether);
    }

    function setGasBurn(uint256 value) external {
        gasBurn = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (gasBurn != 0 && to.code.length == 0 && to != address(0)) {
            uint256 cutoff = gasleft() > gasBurn ? gasleft() - gasBurn : 0;
            uint256 unused;
            while (gasleft() > cutoff) {
                unused = uint256(keccak256(abi.encode(unused, gasleft())));
            }
        }
        super._update(from, to, value);
    }
}

contract MockPonsCurve is IPonsV2BondingCurve {
    using SafeERC20 for IERC20;

    uint256 public constant SALE_AMOUNT = 760_000_000 ether;

    IERC20 public immutable launchToken;
    address public immutable pairToken;
    bool public completed;
    bool public shouldRevert;

    error ForcedFailure();

    constructor(IERC20 launchToken_, address pairToken_) {
        launchToken = launchToken_;
        pairToken = pairToken_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function buy(uint256 quoteIn, uint256, address recipient) external payable returns (uint256 tokensOut) {
        if (shouldRevert) revert ForcedFailure();
        if (pairToken == address(0)) {
            require(msg.value == quoteIn);
        } else {
            require(msg.value == 0);
            IERC20(pairToken).safeTransferFrom(msg.sender, address(this), quoteIn);
        }
        require(!completed);
        completed = true;
        tokensOut = SALE_AMOUNT;
        launchToken.safeTransfer(recipient, tokensOut);
    }

    function sellableTokens() external view returns (uint256) {
        return completed ? 0 : SALE_AMOUNT;
    }

    function sweepFees(uint256) external {}
}

contract MockPonsHook is IPonsV2MemeHook {
    uint256 public sweeps;
    bytes32 public lastPoolId;
    uint256 public lastMinConversionQuoteOut;
    uint256 public lastMinBuybackTokensOut;

    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut)
        external
        override
    {
        sweeps += 1;
        lastPoolId = poolId;
        lastMinConversionQuoteOut = minConversionQuoteOut;
        lastMinBuybackTokensOut = minBuybackTokensOut;
    }
}

contract MockPonsFeeEscrow is IPonsV2FeeEscrow {
    mapping(address recipient => uint256 amount) public override balanceOf;

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
    }

    function claim(uint256 amount) external returns (uint256 claimed) {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        Address.sendValue(payable(msg.sender), amount);
        return amount;
    }
}

contract MockQuoteToken is ERC20 {
    constructor() ERC20("Tesla", "TSLA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPonsLaunchFactory is IPonsV2LaunchFactory {
    uint256 public override launchFee = 0.0005 ether;
    uint256 public override maxCreatorTaxBps = 1_000;
    bool public launchAllowed = true;
    bytes32 public economics = keccak256("mock-pons-economics");

    LaunchConfig private _config = LaunchConfig({
        supply: 1_000_000_000 ether,
        curveFeeBps: 100,
        phantomQuote: 1 ether,
        graduationThreshold: 4.2 ether,
        poolFee: 0,
        tickSpacing: 60,
        enabled: true
    });

    address public lastToken;
    address public lastCurve;
    address public lastCreatorFeeRecipient;
    address public lastPairToken;
    uint16 public lastCreatorTaxBps;
    bool public lastBuybackEnabled;
    address public lastExemption;
    uint256 public tokenTransferGasBurn;

    struct PairTokenEconomics {
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint8 decimals;
    }

    mapping(address pairToken => bool) public override approvedPairTokens;
    mapping(address pairToken => PairTokenEconomics) public pairTokenEconomics;

    function setPairToken(address pairToken, uint256 phantomQuote, uint256 graduationThreshold, uint8 decimals)
        external
    {
        approvedPairTokens[pairToken] = true;
        pairTokenEconomics[pairToken] = PairTokenEconomics({
            phantomQuote: phantomQuote, graduationThreshold: graduationThreshold, decimals: decimals
        });
    }

    function setTokenTransferGasBurn(uint256 value) external {
        tokenTransferGasBurn = value;
    }

    function setLaunchAllowed(bool value) external {
        launchAllowed = value;
    }

    function setLaunchFee(uint256 value) external {
        launchFee = value;
    }

    function setEconomics(bytes32 value) external {
        economics = value;
    }

    function setMaxCreatorTaxBps(uint256 value) external {
        maxCreatorTaxBps = value;
    }

    function canLaunch(address) external view returns (bool) {
        return launchAllowed;
    }

    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory) {
        require(id == 0);
        return _config;
    }

    function previewLaunchEconomics(uint256 id, address pairToken) external view returns (bytes32) {
        require(id == 0);
        if (pairToken == address(0)) return economics;
        require(approvedPairTokens[pairToken]);
        return keccak256(abi.encode(economics, pairToken));
    }

    function launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve) {
        require(launchAllowed);
        require(msg.value == launchFee);
        require(launchConfigId == 0);
        if (pairToken != address(0)) require(approvedPairTokens[pairToken]);
        require(params.expectedEconomics == this.previewLaunchEconomics(0, pairToken));

        MockPonsToken deployedToken = new MockPonsToken(params.name, params.symbol, address(this));
        if (tokenTransferGasBurn != 0) deployedToken.setGasBurn(tokenTransferGasBurn);
        MockPonsCurve deployedCurve = new MockPonsCurve(IERC20(deployedToken), pairToken);
        deployedToken.transfer(address(deployedCurve), deployedCurve.SALE_AMOUNT());

        token = address(deployedToken);
        curve = address(deployedCurve);
        lastToken = token;
        lastCurve = curve;
        lastPairToken = pairToken;
        lastCreatorFeeRecipient = params.creatorFeeRecipient;
        lastCreatorTaxBps = params.creatorTaxBps;
        lastBuybackEnabled = params.buybackEnabled;
        if (snipeTaxExemptions.length != 0) lastExemption = snipeTaxExemptions[0];
    }
}
