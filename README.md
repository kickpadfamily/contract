# Kickpad

Refundable kickstarts for [Pons V2](https://github.com/kickpadfamily) on
Robinhood Chain. Contributors deposit a quote asset — native ETH or a
Pons-approved token such as a tokenized stock — before any launch token
exists. When the kickstart fills, these contracts create the Pons token
and buy out its bonding curve in that same quote asset. A keeper then
pushes those tokens to contributors.

This repo is the contracts.
The post-fill keeper is [cranker](https://github.com/kickpadfamily/cranker).

## Lifecycle

```text
KICKSTART -> PONS LAUNCH + CURVE BUYOUT -> DISTRIBUTE -> PONS POOL
```

1. A creator opens a kickstart, pays Kickpad's 0.0005 ETH launch fee, and
   reserves Pons's current launch fee.
2. Contributors add or withdraw the quote asset at par. No ERC-20 launch
   token exists yet. ETH kickstarts use `buy`. Tokenized kickstarts use
   `buyQuote`, with an optional frontend ETH→quote swap.
3. The contribution that fills the target atomically:
   - creates the token through the canonical Pons V2 factory;
   - exempts the Kickpad market from Pons's opening snipe tax;
   - buys the curve's complete sellable allocation.
4. Fill does **not** pay out tokens. A keeper (or anyone) then calls
   `distribute(maxBuyers)`, paid from the per-contributor distribution bond.

The Pons graduation threshold is 4.2 ETH **net of Pons trade fees**. Kickpad's
`kickstartTarget` is grossed up for Pons's 1% base fee and the creator's
optional tax. With 0% creator tax that is about 4.242424 ETH.

Kickpad pins Pons launch economics when the kickstart is created. If Pons
changes those terms, or turns public launching off, fill reverts. Contributors
can still withdraw at par.

## Contracts

- `KickpadFactory` — CREATE2 market/vault deployment, launch indexing, pinned
  Pons economics, authenticated launch and curve buyout.
- `FlatMarket` — contribution ledger, refundable withdrawals, overfill
  refunds, graduation, and permissionless batched token distribution.
- `PonsFeeVault` — per-launch Pons creator-fee recipient. Harvests escrow and
  splits 70% creator / 30% Kickpad.
- `IPonsV2` — minimal interfaces for the canonical Pons factory, curve, and
  fee escrow.

Kickpad deploys no token and owns no AMM position. After fill, Pons owns the
curve, pool, and hook. Kickpad does not sweep Uniswap v4 pool trading fees.

## Fees

- Create: Kickpad's 0.0005 ETH plus Pons's current launch fee. Kickpad's share
  is claimable by the platform recipient. Pons's share is reserved until fill.
- Optional creator tax, capped at Pons's live `maxCreatorTaxBps`.
- The kickstart itself charges 0%.
- Pons keeps its protocol share (currently 0.30% of volume).
- Creator-side Pons fees plus optional tax go to that launch's `PonsFeeVault`,
  then 70 / 30 as above.
- Buybacks are disabled on Kickpad launches so the vault split stays ETH.

Each launch has its own vault because Pons escrow is keyed by recipient, not
by token.

## Canonical Pons V2

Robinhood Chain (chain id `4663`):

```text
Factory:    0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e
Fee escrow: 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e
```

Pons `canLaunch(address)` is a public gate, not a Kickpad allowlist. Kickpad
checks it at create. Existing kickstarts still cannot fill if Pons later
closes launching.

## Development

```shell
forge build
forge test
forge fmt --check
```

Fork integration is opt-in:

```shell
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge test --match-contract PonsV2GraduationForkTest
```

### Localnet

```shell
./scripts/localnet.sh
```

This forks Robinhood on Anvil (`31337`), deploys Kickpad against live Pons
addresses, writes `deployments/localnet.json`, and seeds a test kickstart.
Pons bytecode is fetched from mainnet on first `launchToken`.

Use `/local-faucet` on the app (loopback RPC, chain 31337 only).

In-process Pons mocks instead of a fork:

```shell
LOCALNET_USE_MOCKS=1 ./scripts/localnet.sh
```

### Production deploy

```text
ROBINHOOD_RPC_URL
DEPLOYER_PRIVATE_KEY
PLATFORM_FEE_RECIPIENT
PONS_LAUNCH_CONFIG_ID=0
```

```shell
forge script script/DeployKickpad.s.sol:DeployKickpad \
  --rpc-url "$ROBINHOOD_RPC_URL" --broadcast
```

The script logs `PonsCanLaunchKickpad`. That should be true while Pons public
launching is open.

## License

[MIT](LICENSE)
