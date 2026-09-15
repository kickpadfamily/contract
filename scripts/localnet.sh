#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.foundry/bin:${PATH}"

ANVIL_PRIVATE_KEY="${ANVIL_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
ANVIL_ADDRESS="${ANVIL_ADDRESS:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
ANVIL_PORT="${LOCALNET_PORT:-8545}"
RPC_URL="${LOCALNET_RPC_URL:-http://127.0.0.1:${ANVIL_PORT}}"
FRONTEND_DIR="${FRONTEND_DIR:-$(cd "$ROOT/../../NextJS/fairpad" 2>/dev/null && pwd || true)}"
ANVIL_PID_FILE="${TMPDIR:-/tmp}/kickpad-anvil.pid"
FORK_URL="${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
PONS_FACTORY="0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e"
PONS_FEE_ESCROW="0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e"
ANVIL_STATE="${ANVIL_STATE:-$ROOT/deployments/anvil-state.json}"
USE_MOCKS="${LOCALNET_USE_MOCKS:-0}"

started_anvil=0

wait_for_rpc() {
  local attempts="${1:-40}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for ${RPC_URL}" >&2
  return 1
}

pons_code_size() {
  cast codesize "$PONS_FACTORY" --rpc-url "$RPC_URL" 2>/dev/null || true
}

# Anvil dumps of Robinhood often omit tokenized stocks and Pons pair-token
# approvals. Copy working ERC-20s onto those addresses and approve them so
# the create picker can list USDG/TSLA/NVDA instead of ETH only.
seed_quote_assets() {
  local pons_factory="$1"
  local t18 t6 code18 code6 owner addr symbol decimals approved unit phantom threshold wallet etched
  local wallets=(
    "$ANVIL_ADDRESS"
    0x70997970C51812dc3A010C7d01b50e0d17dc79C8
    0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
  )

  echo "Deploying local quote-token templates"
  forge script script/SeedLocalQuotes.s.sol:SeedLocalQuotes \
    --rpc-url "$RPC_URL" --broadcast --legacy
  t18="$(
    python3 - "$ROOT/broadcast/SeedLocalQuotes.s.sol/31337/run-latest.json" <<'PY'
import json, sys
txs = json.load(open(sys.argv[1])).get("transactions", [])
created = [tx.get("contractAddress") for tx in txs if tx.get("contractAddress")]
if len(created) < 2:
    raise SystemExit("quote templates missing from broadcast log")
print(created[0])
print(created[1])
PY
  )"
  t6="$(echo "$t18" | sed -n '2p')"
  t18="$(echo "$t18" | sed -n '1p')"
  if [[ -z "$t18" || -z "$t6" ]]; then
    echo "Failed to deploy quote-token templates" >&2
    exit 1
  fi
  code18="$(cast code "$t18" --rpc-url "$RPC_URL")"
  code6="$(cast code "$t6" --rpc-url "$RPC_URL")"

  if [[ "$USE_MOCKS" != "1" ]]; then
    # Stale Anvil dumps often have Pons owner = 0x0, which cannot send txs.
    # Slot 0 is Ownable._owner on the deployed factory.
    local owner_slot
    owner_slot="$(cast abi-encode 'f(address)' "$ANVIL_ADDRESS")"
    cast rpc anvil_setStorageAt "$pons_factory" 0 "$owner_slot" --rpc-url "$RPC_URL" >/dev/null
  fi

  echo "Seeding Pons-approved quote assets (USDG, TSLA, NVDA, ...)"
  while IFS=, read -r addr symbol decimals; do
    [[ -z "$addr" ]] && continue
    if [[ "$decimals" == "6" ]]; then
      cast rpc anvil_setCode "$addr" "$code6" --rpc-url "$RPC_URL" >/dev/null
    else
      cast rpc anvil_setCode "$addr" "$code18" --rpc-url "$RPC_URL" >/dev/null
    fi

    # ETH launch config is phantom 1.68 / threshold 4.2. Local 18-dec stocks
    # are 1:1 with ETH, so reuse those amounts. USDG keeps dollar economics.
    phantom="$(python3 -c "d=int('$decimals'); print((168 * 10 ** (d - 2)) if d == 18 else 3236 * 10 ** d)")"
    threshold="$(python3 -c "d=int('$decimals'); print((42 * 10 ** (d - 1)) if d == 18 else 8090 * 10 ** d)")"
    amount="$(python3 -c "print(1_000_000 * 10 ** int('$decimals'))")"

    approved="$(cast call "$pons_factory" "approvedPairTokens(address)(bool)" "$addr" --rpc-url "$RPC_URL" 2>/dev/null || echo false)"
    if [[ "$USE_MOCKS" == "1" ]]; then
      if [[ "$approved" != "true" ]]; then
        cast send "$pons_factory" "setPairToken(address,uint256,uint256,uint8)" \
          "$addr" "$phantom" "$threshold" "$decimals" \
          --private-key "$ANVIL_PRIVATE_KEY" --rpc-url "$RPC_URL" --legacy >/dev/null
      fi
    else
      cast send "$pons_factory" "setPairTokenEconomics(address,uint256,uint256,uint8)" \
        "$addr" "$phantom" "$threshold" "$decimals" \
        --private-key "$ANVIL_PRIVATE_KEY" --rpc-url "$RPC_URL" --legacy >/dev/null
      if [[ "$approved" != "true" ]]; then
        cast send "$pons_factory" "setPairTokenApproved(address,bool)" \
          "$addr" true \
          --private-key "$ANVIL_PRIVATE_KEY" --rpc-url "$RPC_URL" --legacy >/dev/null
      fi
    fi

    for wallet in "${wallets[@]}"; do
      cast send "$addr" "mint(address,uint256)" "$wallet" "$amount" \
        --private-key "$ANVIL_PRIVATE_KEY" --rpc-url "$RPC_URL" --legacy >/dev/null || true
    done
    echo "  $symbol $addr"
  done <<'EOF'
0x5fc5360d0400a0fd4f2af552add042d716f1d168,USDG,6
0xaf3d76f1834a1d425780943c99ea8a608f8a93f9,AAPL,18
0x86923f96303d656e4aa86d9d42d1e57ad2023fdc,AMD,18
0x12f190a9f9d7d37a250758b26824b97ce941bf54,AMZN,18
0x6330d8c3178a418788df01a47479c0ce7ccf450b,COIN,18
0xdf0992e440dd0be65bd8439b609d6d4366bf1cb5,CRCL,18
0x1b0e319c6a659f002271b69db8a7df2f911c153e,GME,18
0x2e0847e8910a9732eb3fb1bb4b70a580adad4fe3,GOOGL,18
0xc0d6457c16cc70d6790dd43521c899c87ce02f35,META,18
0xe93237c50d904957cf27e7b1133b510c669c2e74,MSFT,18
0xff080c8ce2e5feadaca0da81314ae59d232d4afd,MU,18
0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec,NVDA,18
0x894e1ec2d74ffe5aef8dc8a9e84686accb964f2a,PLTR,18
0xb90a19ff0af67f7779aff50a882a9cff42446400,SNDK,18
0x4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea,SPCX,18
0x117cc2133c37b721f49de2a7a74833232b3b4c0c,SPY,18
0x322f0929c4625ed5bad873c95208d54e1c003b2d,TSLA,18
EOF

  echo "Seeding local ETH/quote Uniswap v4 pools"
  forge script script/SeedLocalV4Pools.s.sol:SeedLocalV4Pools \
    --rpc-url "$RPC_URL" --broadcast --legacy
}

ensure_anvil() {
  if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    echo "Using existing RPC at ${RPC_URL} (chain id $(cast chain-id --rpc-url "$RPC_URL"))"
    return 0
  fi

  if [[ "$USE_MOCKS" == "1" ]]; then
    echo "Starting isolated Anvil development chain on ${RPC_URL}"
    nohup anvil \
      --chain-id 31337 \
      --host 127.0.0.1 \
      --port "$ANVIL_PORT" \
      --disable-code-size-limit \
      >/tmp/kickpad-anvil.log 2>&1 &
  else
    mkdir -p "$(dirname "$ANVIL_STATE")"
    local anvil_args=(
      --chain-id 31337
      --host 127.0.0.1
      --port "$ANVIL_PORT"
      --accounts 10
      --balance 10000
      --state "$ANVIL_STATE"
      --state-interval 15
      --disable-code-size-limit
    )
    if [[ -f "$ANVIL_STATE" ]]; then
      echo "Resuming Anvil from ${ANVIL_STATE} (offline snapshot, no live fork)"
    else
      local fork_block="${FORK_BLOCK_NUMBER:-}"
      if [[ -z "$fork_block" ]]; then
        fork_block="$(cast block-number --rpc-url "$FORK_URL")"
        if [[ "$fork_block" -gt 10 ]]; then
          fork_block=$((fork_block - 5))
        fi
      fi
      echo "Starting Anvil fork of Robinhood Chain on ${RPC_URL} at block ${fork_block}"
      echo "Pons V2 is copied from mainnet on demand, then snapshotted to ${ANVIL_STATE}."
      anvil_args+=(
        --fork-url "$FORK_URL"
        --fork-block-number "$fork_block"
        --timeout 120000
        --retries 8
      )
    fi
    nohup anvil "${anvil_args[@]}" >/tmp/kickpad-anvil.log 2>&1 &
  fi
  echo $! >"$ANVIL_PID_FILE"
  disown $! || true
  started_anvil=1
  wait_for_rpc
}

upsert_env() {
  local file="$1"
  local key="$2"
  local value="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -q "^${key}=" "$file"; then
    local escaped
    escaped="$(printf '%s' "$value" | sed -e 's/[&|]/\\&/g')"
    sed -i.bak "s|^${key}=.*|${key}=${escaped}|" "$file"
    rm -f "${file}.bak"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

write_frontend_env() {
  local factory="$1"
  local block="$2"
  local env_file="$3"

  upsert_env "$env_file" "NEXT_PUBLIC_CHAIN_ID" "31337"
  upsert_env "$env_file" "NEXT_PUBLIC_RPC_URL" "$RPC_URL"
  upsert_env "$env_file" "NEXT_PUBLIC_FACTORY_ADDRESS" "$factory"
  upsert_env "$env_file" "NEXT_PUBLIC_DEPLOY_BLOCK" "$block"
  upsert_env "$env_file" "DATABASE_URL" 'file:../.data/fairpad.db'
  local ws_url="${RPC_URL/http:/ws:}"
  ws_url="${ws_url/https:/wss:}"
  upsert_env "$env_file" "RPC_WS_URL" "$ws_url"
}

reset_frontend_index() {
  local db="$1"
  [[ -f "$db" ]] || return 0
  python3 - "$db" <<'PY'
import sqlite3, sys

conn = sqlite3.connect(sys.argv[1])
tables = {
    row[0]
    for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
}
for table in ("TokenTransfer", "Trade", "Launch", "SyncCursor"):
    if table in tables:
        conn.execute(f'DELETE FROM "{table}" WHERE chainId = 31337')
conn.commit()
PY
}

if [[ "${1:-}" == "quotes" ]]; then
  export DEPLOYER_PRIVATE_KEY="$ANVIL_PRIVATE_KEY"
  seed_quote_assets "$PONS_FACTORY"
  exit 0
fi

ensure_anvil

# Forked Robinhood blocks are days behind wall-clock. Warp so the UI
# does not show new local txs as "6d ago".
cast rpc evm_setNextBlockTimestamp "$(date +%s)" --rpc-url "$RPC_URL" >/dev/null || true

chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$chain_id" != "31337" ]]; then
  echo "Refusing to deploy: ${RPC_URL} is chain ${chain_id}, expected 31337 so wallets cannot hit Robinhood mainnet." >&2
  exit 1
fi

if [[ "$USE_MOCKS" != "1" ]]; then
  echo "Fetching canonical Pons factory from the Robinhood fork..."
  pons_size="$(pons_code_size)"
  if [[ -z "$pons_size" || "$pons_size" == "0" ]]; then
    echo "Existing ${RPC_URL} cannot lazy-load Pons from ${FORK_URL}." >&2
    echo "Stop that node (or set LOCALNET_PORT) and rerun. A stale pinned fork will not work." >&2
    exit 1
  fi
  echo "Pons factory ${PONS_FACTORY} (${pons_size} bytes) ready for on-demand clones"
fi

# Isolated Anvil already funds account #0; keep this explicit so a reused
# node with drained balances can still deploy and seed.
cast rpc anvil_setBalance "$ANVIL_ADDRESS" '"0x21e19e0c9bab2400000"' --rpc-url "$RPC_URL" >/dev/null
echo "Funded ${ANVIL_ADDRESS} with 10000 ETH (balance $(cast balance "$ANVIL_ADDRESS" --rpc-url "$RPC_URL") wei)"

export DEPLOYER_PRIVATE_KEY="$ANVIL_PRIVATE_KEY"
export PLATFORM_FEE_RECIPIENT="$ANVIL_ADDRESS"
export PONS_LAUNCH_CONFIG_ID="${PONS_LAUNCH_CONFIG_ID:-0}"

echo "Deploying Kickpad from ${ANVIL_ADDRESS}"
if [[ "$USE_MOCKS" == "1" ]]; then
  forge script script/DeployLocalKickpad.s.sol:DeployLocalKickpad --rpc-url "$RPC_URL" --broadcast --legacy
  broadcast="$ROOT/broadcast/DeployLocalKickpad.s.sol/31337/run-latest.json"
  parse_names="KickpadFactory MockPonsLaunchFactory MockPonsFeeEscrow"
else
  forge script script/DeployKickpad.s.sol:DeployKickpad --rpc-url "$RPC_URL" --broadcast --legacy
  broadcast="$ROOT/broadcast/DeployKickpad.s.sol/31337/run-latest.json"
  parse_names="KickpadFactory"
fi

if [[ ! -f "$broadcast" ]]; then
  echo "Missing broadcast file at ${broadcast}" >&2
  exit 1
fi

addresses="$(python3 - "$broadcast" $parse_names <<'PY'
import json, sys

path = sys.argv[1]
wanted = sys.argv[2:]
data = json.load(open(path))
found = {}
for tx in data.get("transactions", []):
    name = tx.get("contractName")
    address = tx.get("contractAddress")
    if name and address:
        found[name] = address
for name in wanted:
    if name not in found:
        raise SystemExit(f"missing {name} in {path}")
    print(found[name])
PY
)"

factory="$(echo "$addresses" | sed -n '1p')"
if [[ "$USE_MOCKS" == "1" ]]; then
  pons_factory="$(echo "$addresses" | sed -n '2p')"
  pons_escrow="$(echo "$addresses" | sed -n '3p')"
else
  pons_factory="$PONS_FACTORY"
  pons_escrow="$PONS_FEE_ESCROW"
fi
deploy_block="$(cast block-number --rpc-url "$RPC_URL")"

mkdir -p "$ROOT/deployments"
python3 - "$ROOT/deployments/localnet.json" "$factory" "$pons_factory" "$pons_escrow" "$deploy_block" "$RPC_URL" "$ANVIL_ADDRESS" "$USE_MOCKS" "$FORK_URL" <<'PY'
import json, sys

path, factory, pons_factory, pons_escrow, block, rpc, deployer, use_mocks, fork_url = sys.argv[1:]
payload = {
    "chainId": 31337,
    "rpcUrl": rpc,
    "deployBlock": int(block),
    "deployer": deployer,
    "contracts": {
        "KickpadFactory": factory,
        "PonsLaunchFactory": pons_factory,
        "PonsFeeEscrow": pons_escrow,
    },
}
if use_mocks == "1":
    payload["mode"] = "mocks"
    payload["contracts"]["MockPonsLaunchFactory"] = pons_factory
    payload["contracts"]["MockPonsFeeEscrow"] = pons_escrow
else:
    payload["mode"] = "fork"
    payload["forkUrl"] = fork_url
json.dump(payload, open(path, "w"), indent=2)
print(path)
PY

echo "KickpadFactory              $factory"
echo "PonsLaunchFactory           $pons_factory"
echo "PonsFeeEscrow               $pons_escrow"
echo "deploy block                $deploy_block"

export FACTORY="$factory"
export PONS_FACTORY="$pons_factory"
export LOCALNET_USE_MOCKS="$USE_MOCKS"
export LIVE_METADATA_URI="${LIVE_METADATA_URI:-}"
export SMOKE_METADATA_URI="${SMOKE_METADATA_URI:-}"

seed_quote_assets "$pons_factory"
echo "Seeding one open test kickstart and one completed Pons launch"
forge script script/SeedLocalnet.s.sol:SeedLocalnet --rpc-url "$RPC_URL" --broadcast --legacy

if [[ "$USE_MOCKS" != "1" ]]; then
  echo "Copying Uniswap v4 bytecode so Pons can seed locked pools"
  for addr in \
    0x8366a39CC670B4001A1121B8F6A443A643e40951 \
    0x58daec3116aae6D93017bAAea7749052E8a04fA7 \
    0x000000000022D473030F116dDEE9F6B43aC78BA3 \
    0x8876789976dEcBfCbBbe364623C63652db8C0904 \
    0x8dc178efb8111bb0973dd9d722ebeff267c98f94 \
    0xf3334192d15450cdd385c8b70e03f9a6bd9e673b
  do
    size="$(cast codesize "$addr" --rpc-url "$RPC_URL" 2>/dev/null || echo 0)"
    if [[ "$size" == "0" ]]; then
      code="$(cast code "$addr" --rpc-url "$FORK_URL")"
      if [[ -n "$code" && "$code" != "0x" ]]; then
        cast rpc anvil_setCode "$addr" "$code" --rpc-url "$RPC_URL" >/dev/null
      fi
    fi
  done

  count="$(cast call "$factory" "launchCount()(uint256)" --rpc-url "$RPC_URL")"
  for ((i = 0; i < count; i++)); do
    market="$(cast call "$factory" "marketAt(uint256)(address)" "$i" --rpc-url "$RPC_URL")"
    token="$(cast call "$market" "token()(address)" --rpc-url "$RPC_URL")"
    if [[ "$token" == "0x0000000000000000000000000000000000000000" ]]; then
      continue
    fi
    phase="$(python3 - "$PONS_FACTORY" "$token" "$RPC_URL" <<'PY'
import json, subprocess, sys
factory, token, rpc = sys.argv[1:]
raw = subprocess.check_output(
    [
        "cast", "call", factory,
        "getLaunchedToken(address)((address,address,address,address,address,uint256,uint24,int24,uint16,bool,uint8,uint256,uint256,uint256,bool))",
        token, "--rpc-url", rpc, "--json",
    ],
    text=True,
)
data = json.loads(raw)
if isinstance(data, list) and len(data) > 10:
    print(data[10])
elif isinstance(data, dict):
    print(data.get("phase", data.get("10", "")))
else:
    print("")
PY
)"
    if [[ "$phase" == "1" ]]; then
      echo "Seeding Pons Uniswap v4 pool for $token"
      cast send "$PONS_FACTORY" "createGraduatedPool(address)" "$token" \
        --private-key "$ANVIL_PRIVATE_KEY" --rpc-url "$RPC_URL" --legacy --gas-limit 8000000 >/dev/null
    fi
  done
fi

if [[ -n "${FRONTEND_DIR}" && -d "${FRONTEND_DIR}" ]]; then
  write_frontend_env "$factory" "$deploy_block" "${FRONTEND_DIR}/.env.local"
  write_frontend_env "$factory" "$deploy_block" "${FRONTEND_DIR}/.env"
  reset_frontend_index "${FRONTEND_DIR}/.data/fairpad.db"
  echo "Updated ${FRONTEND_DIR}/.env.local"
  echo "Local faucet: http://localhost:3000/local-faucet"
fi

if [[ "$started_anvil" -eq 1 ]]; then
  echo "Anvil is running in the background (pid $(cat "$ANVIL_PID_FILE")). Logs: /tmp/kickpad-anvil.log"
fi
