#!/usr/bin/env bash
#
# forknet-bootstrap — provision a forknet node stack on a fresh Ubuntu host,
# one component at a time.
#
# Run as root ON THE NEW SERVER. Every step is idempotent: re-running is safe
# and skips work already done, so a failed run resumes rather than restarts.
#
#   ./forknet-bootstrap.sh preflight        checks worth doing before compiling
#   ./forknet-bootstrap.sh deps             apt, service user, rust
#   ./forknet-bootstrap.sh bitcoin          mainchain node   (build/configure/snapshot/start)
#   ./forknet-bootstrap.sh enforcer         BIP300/301       (build/configure/start)
#   ./forknet-bootstrap.sh thunder          sidechain #9     (build/configure/start)
#   ./forknet-bootstrap.sh pool             simplepool       (install/configure/start)
#   ./forknet-bootstrap.sh verify           health check, any time
#
# WHICH NETWORK is a profile, not a code change. `--profile alphanet` builds a
# different bitcoin branch, writes a differently-named config file on different
# ports, and hands the enforcer a different preset. See profiles/.
#
# Secrets are GENERATED on this host, never copied from another one. The RPC
# password lands in /root/forknet-credentials.txt (0600).
#
# That file does NOT contain the wallet mnemonics — the enforcer and Thunder
# create their own on first run, inside their datadirs. Backing up only the
# credentials file would leave the wallets unrecoverable. `verify` prints where
# they are.
#
set -euo pipefail

SELF=$0
HERE="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$HERE/conf"
LIB_DIR="$HERE/lib"
PROFILE_DIR="$HERE/profiles"

# ------------------------------------------------------------ arg parsing ----
# --profile has to be read before anything else: it decides which file the rest
# of the configuration comes from.
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--profile) PROFILE=${2:?--profile needs a name}; shift 2 ;;
        --profile=*)  PROFILE=${1#*=}; shift ;;
        -h|--help)    ARGS+=(help); shift ;;
        *)            ARGS+=("$1"); shift ;;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

# ------------------------------------------------------------ config load ----
# Precedence, strongest first:
#   1. environment          FORCE=1 BITCOIN_REF=x ./forknet-bootstrap.sh ...
#   2. ./bootstrap.env      this host's answers (gitignored)
#   3. profiles/$PROFILE.env
#   4. the defaults below
# It works out that way because every layer assigns with ${VAR:-...}, so the
# first layer to set a name wins and later ones fall through.
# shellcheck disable=SC1091
[ -f "$HERE/bootstrap.env" ] && . "$HERE/bootstrap.env"

PROFILE=${PROFILE:-drynet3}
[ -f "$PROFILE_DIR/$PROFILE.env" ] || {
    echo "unknown profile '$PROFILE'. available: $(cd "$PROFILE_DIR" && ls *.env | sed 's/\.env$//' | tr '\n' ' ')" >&2
    exit 1
}
# shellcheck disable=SC1090
. "$PROFILE_DIR/$PROFILE.env"

# --- host layout -----------------------------------------------------------
FORKNET_USER=${FORKNET_USER:-forknet}
HOME_DIR=${HOME_DIR:-/home/$FORKNET_USER}
SW_DIR=${SW_DIR:-$HOME_DIR/forknet-software}
CREDS_FILE=${CREDS_FILE:-/root/forknet-credentials.txt}

BTC_DATADIR=${BTC_DATADIR:-$HOME_DIR/$BTC_DATADIR_NAME}
BTC_CONF="$BTC_DATADIR/$BTC_CONF_NAME"
RPCAUTH_CONF="$BTC_DATADIR/rpcauth.conf"
THUNDER_DATADIR=${THUNDER_DATADIR:-$HOME_DIR/$THUNDER_DATADIR_NAME}
ENFORCER_DATADIR=${ENFORCER_DATADIR:-$HOME_DIR/.local/share/bip300301_enforcer}

# --- ports -----------------------------------------------------------------
THUNDER_P2P_PORT=${THUNDER_P2P_PORT:-$((4000 + SIDECHAIN_ID))}
THUNDER_RPC_PORT=${THUNDER_RPC_PORT:-$((6000 + SIDECHAIN_ID))}
ENFORCER_GRPC=${ENFORCER_GRPC:-127.0.0.1:50051}
ENFORCER_GBT=${ENFORCER_GBT:-127.0.0.1:8122}
ZMQ_ADDR=${ZMQ_ADDR:-tcp://127.0.0.1:29000}

# --- units -----------------------------------------------------------------
# SVC_SUFFIX exists so a second profile can coexist on one host: set it to
# e.g. "-alphanet" and the units become bitcoind-alphanet.service and friends.
# Give that profile its own CREDS_FILE and its own ENFORCER_GRPC/GBT/ZMQ ports
# too — the datadirs are already separated by the profile.
SVC_SUFFIX=${SVC_SUFFIX:-}
BITCOIND_UNIT="bitcoind$SVC_SUFFIX"
ENFORCER_UNIT="bip300301-enforcer$SVC_SUFFIX"
THUNDER_UNIT="thunder$SVC_SUFFIX"

# --- build behaviour -------------------------------------------------------
# PIN_VERSIONS=0 tracks branch tips instead of the profile's pinned commits.
# The three components are version-coupled through the BIP300 gRPC surface and
# the forknet magic bytes, so moving them is a deliberate act.
PIN_VERSIONS=${PIN_VERSIONS:-1}
DBCACHE_MB=${DBCACHE_MB:-2000}
# Skips script/signature verification for every block below this hash, which is
# where most of an IBD's CPU goes. Only ever set it to a hash you obtained from
# a node YOU control and trust. Empty = use whatever the branch compiles in.
BTC_ASSUMEVALID=${BTC_ASSUMEVALID:-}
MIN_RAM_GB=${MIN_RAM_GB:-16}
COINBASE_RECIPIENT=${COINBASE_RECIPIENT:-}

# --- snapshot --------------------------------------------------------------
SNAPSHOT_FILE=${SNAPSHOT_FILE:-$HOME_DIR/utxo-${SNAPSHOT_HEIGHT:-none}.dat}
SNAPSHOT_FROM=${SNAPSHOT_FROM:-}     # e.g. root@YOUR_OTHER_NODE:/home/forknet/utxo-957600.dat

# --- pool ------------------------------------------------------------------
POOL_REPO=${POOL_REPO:-https://github.com/LayerTwo-Labs/simplepool}
POOL_REF=${POOL_REF:-main}
POOL_FROM_SOURCE=${POOL_FROM_SOURCE:-0}   # 1 = git clone + make, 0 = published release
POOL_RELEASE_TAG=${POOL_RELEASE_TAG:-}    # empty = latest
POOL_INSTALLER=${POOL_INSTALLER:-/root/simplepool-install.sh}
POOL_INSTALLER_URL=${POOL_INSTALLER_URL:-}
POOL_ROOT=${POOL_ROOT:-$SW_DIR/simplepool}
POOL_DATA_DIR=${POOL_DATA_DIR:-}          # empty = keep the DB under $POOL_ROOT/data
POOL_UNITS=${POOL_UNITS:-"simplepool simplepool-dashboard simplepool-payout"}
POOL_MODE=${POOL_MODE:-pps-classic}
POOL_STRATUM_PORT=${POOL_STRATUM_PORT:-3334}
# Extra stratum ports beyond POOL_STRATUM_PORT, one `listener` line each, newline
# separated. This is how a rented fleet and a home ASIC share one pool without
# either getting the other's difficulty — a marketplace arrives as ONE
# connection aggregating a whole fleet, so the same hashrate that is 12
# shares/min from an ASIC is thousands of submits/sec here.
#
# Syntax (src/config.c parse_listener); port is the only required field:
#   port=N  min_diff=D  initial_diff=D  max_diff=D  max_coinbase_bytes=N  label=TEXT
#
# min_diff is the vardiff FLOOR and the starting difficulty: vardiff moves at
# most 4x per 30s window, so climbing 1 -> 65536 takes ~4 minutes and the
# reject flood on the way is what gets an order cancelled. The miner has to
# arrive at the right difficulty.
#
# min_diff is KEPT even when the chain is easier than it, which costs blocks:
# on a 500000 port over a chain at 1200, miners discard ~416 of every 417
# blocks they solve. Only set a floor you know sits below network difficulty.
POOL_LISTENERS=${POOL_LISTENERS:-}
# Templates come from the ENFORCER, never from bitcoind — see lib/pool.sh.
POOL_BITCOIND_URL=${POOL_BITCOIND_URL:-http://$ENFORCER_GBT}
POOL_OPERATOR_ADDRESS=${POOL_OPERATOR_ADDRESS:-}
POOL_FEE_BPS=${POOL_FEE_BPS:-100}
# The string stamped into the coinbase of every block this pool mines — the
# pool's identity on-chain, and what block explorers attribute a block to.
# Empty = leave the installer's own default (/simplepool/) alone.
POOL_COINBASE_TAG=${POOL_COINBASE_TAG:-}
# The name the DASHBOARD shows — page titles and the top-left brand link. It
# is not a config key upstream: "simplepool" is hard-coded across
# dashboard/views/*.ejs, so this is applied by rewriting them after install
# (pool_apply_brand). Empty = leave upstream's name alone.
# NOT the same thing as POOL_COINBASE_TAG, which is the on-chain identity.
POOL_BRAND=${POOL_BRAND:-}
POOL_BTC_ADDRESS=${POOL_BTC_ADDRESS:-}
POOL_THUNDER_ADDRESS=${POOL_THUNDER_ADDRESS:-}
# --- pplns-coinbase only ---------------------------------------------------
# The window, as a multiple of the CURRENT network difficulty, so it keeps
# meaning the same thing across a retarget. A pool whose share history is
# shorter than its window is not an error: it pays across everything it has.
POOL_PPLNS_WINDOW_MULTIPLE=${POOL_PPLNS_WINDOW_MULTIPLE:-2.0}
# Byte budget for the WHOLE serialized coinbase, which is what really limits
# how many miners one block can pay — on a drivechain pool the BIP300/301
# commitment OP_RETURNs are already spending part of it. Not a consensus
# limit: it exists because rented-hashrate marketplaces refuse a job whose
# coinbase they consider oversized, and that rule binds only on the port the
# rented hashrate connects to. Set a tighter per-listener cap there instead of
# making your own miners live under it.
POOL_COINBASE_MAX_BYTES=${POOL_COINBASE_MAX_BYTES:-3000}
# A claim worth less than this gets no output in THAT block. It is not lost
# and it does not come to you: it is shared among the miners the block could
# pay, and the skipped miner goes first in the queue for the next one. Being
# small costs frequency, not money. 546 = the dust limit.
POOL_PPLNS_PAYOUT_FLOOR_SATS=${POOL_PPLNS_PAYOUT_FLOOR_SATS:-546}
POOL_THUNDER_RPC_URL=${POOL_THUNDER_RPC_URL:-http://127.0.0.1:$THUNDER_RPC_PORT}
# EMPTY ON PURPOSE. Blank makes the proxy derive the rate per template from
# coinbasevalue, network difficulty and fee_bps. A fixed value goes stale as
# difficulty moves and bypasses fee_bps entirely — upstream's installer prompts
# "blank = derive from template, recommended" for exactly this reason.
#
# The old default here was 1000, which on a mainnet-difficulty fork is ~1e8x
# fair value: the pool logs "rate override 1000.0000 EXCEEDS fair value 0.0000"
# and credits shares at a rate no block reward can cover.
POOL_PPS_SATS_PER_DIFF=${POOL_PPS_SATS_PER_DIFF:-}
POOL_PAYOUT_INTERVAL_HOURS=${POOL_PAYOUT_INTERVAL_HOURS:-24}
POOL_HOSTNAME=${POOL_HOSTNAME:-}
POOL_DASHBOARD_PORT=${POOL_DASHBOARD_PORT:-8081}
POOL_ADMIN_USER=${POOL_ADMIN_USER:-admin}
POOL_ADMIN_PASSWORD=${POOL_ADMIN_PASSWORD:-}   # empty = installer generates and prints it once
POOL_TLS=${POOL_TLS:-0}
POOL_TLS_EMAIL=${POOL_TLS_EMAIL:-}
POOL_NGINX=${POOL_NGINX:-1}
POOL_DASHBOARD=${POOL_DASHBOARD:-1}
POOL_PAYOUT=${POOL_PAYOUT:-1}
POOL_FIREWALL=${POOL_FIREWALL:-0}

# ------------------------------------------------------------------- libs ----
# shellcheck source=lib/common.sh
. "$LIB_DIR/common.sh"
for step in preflight deps bitcoin enforcer thunder pool; do
    # shellcheck disable=SC1090
    . "$LIB_DIR/$step.sh"
done

# ----------------------------------------------------------------- verify ----
cmd_verify() {
    say "verifying — profile $PROFILE"
    local fail=0 checked=0

    # Only components that have actually been configured. Installing one at a
    # time is the normal path here, and a verify that reports three failures
    # because you have not got to the enforcer yet trains you to ignore it.
    unit_installed() { [ -f "/etc/systemd/system/$1.service" ]; }

    if unit_installed "$BITCOIND_UNIT"; then bitcoin_verify || fail=1; checked=1; echo
    else skip "bitcoin not configured yet ($SELF bitcoin)"; fi
    if unit_installed "$ENFORCER_UNIT"; then enforcer_verify || fail=1; checked=1; echo
    else skip "enforcer not configured yet ($SELF enforcer)"; fi
    if unit_installed "$THUNDER_UNIT"; then thunder_verify || fail=1; checked=1
    else skip "thunder not configured yet ($SELF thunder)"; fi
    if unit_installed "${POOL_UNITS%% *}"; then echo; pool_verify || fail=1; checked=1; fi
    [ "$checked" = 1 ] || { warn "nothing is installed yet — start with: $SELF bitcoin"; return 1; }

    echo
    echo "    wallet seeds (back these up — NOT in $CREDS_FILE):"
    # find, not a fixed-depth glob. The enforcer nests the seed one level
    # deeper than this used to assume — the real path on an alphanet node is
    # wallet/bitcoin-alphanet/seed.json, i.e. $ENFORCER_DATADIR/*/*/seed.json —
    # so `*/seed.json` matched nothing and the backup list came out EMPTY while
    # still printing its "back these up" heading. Silently omitting the seed
    # that holds the mining rewards is the worst way for this to fail.
    local f
    while IFS= read -r f; do
        [ -n "$f" ] && echo "      $f"
    done < <(find "$ENFORCER_DATADIR" -maxdepth 4 -name seed.json -type f 2>/dev/null)
    ls "$THUNDER_DATADIR" >/dev/null 2>&1 && echo "      $THUNDER_DATADIR (thunder wallet)"

    echo
    if [ "$fail" = 0 ]; then say "all checks passed"; else
        warn "some checks failed — see 'Troubleshooting' in README.md"; return 1
    fi
}

# ----------------------------------------------------------------- config ----
cmd_config() {
    say "resolved configuration — profile $PROFILE"
    kv "description"        "$PROFILE_DESC"
    echo
    kv "bitcoin repo"       "$BITCOIN_REPO"
    kv "bitcoin ref / pin"  "$BITCOIN_REF ${BITCOIN_PIN:-(no pin)}"
    kv "bitcoin config"     "$BTC_CONF"
    kv "bitcoin ports"      "rpc $BTC_RPC_PORT / p2p $BTC_P2P_PORT"
    kv "bitcoin addnode"    "${BTC_ADDNODE:-(none — DNS seeds)}"
    kv "snapshot"           "${SNAPSHOT_URL:-${SNAPSHOT_FROM:-(none)}}"
    echo
    kv "enforcer repo"      "$ENFORCER_REPO"
    kv "enforcer ref / pin" "$ENFORCER_REF ${ENFORCER_PIN:-(no pin)}"
    kv "enforcer preset"    "$ENFORCER_NETWORK_PRESET"
    kv "enforcer addrs"     "grpc $ENFORCER_GRPC / gbt $ENFORCER_GBT"
    echo
    kv "thunder repo"       "$THUNDER_REPO"
    kv "thunder ref / pin"  "$THUNDER_REF ${THUNDER_PIN:-(no pin)}"
    kv "thunder network"    "$THUNDER_NETWORK ${THUNDER_NETWORK_MAGIC:+magic $THUNDER_NETWORK_MAGIC}"
    kv "thunder ports"      "p2p udp $THUNDER_P2P_PORT / rpc $THUNDER_RPC_PORT"
    kv "thunder peer"       "${THUNDER_PEER:-(none)}"
    echo
    kv "pool source"        "$POOL_REPO @ $POOL_REF ($([ "$POOL_FROM_SOURCE" = 1 ] && echo source || echo release))"
    kv "pool mode"          "$POOL_MODE"
    kv "pool templates"     "$POOL_BITCOIND_URL"
    kv "pool root"          "$POOL_ROOT"
    echo
    kv "units"              "$BITCOIND_UNIT $ENFORCER_UNIT $THUNDER_UNIT"
    kv "pins honoured"      "$([ "$PIN_VERSIONS" = 1 ] && echo yes || echo "no — tracking branch tips")"
}

# ----------------------------------------------------------------- render ----
# Renders every template with this profile's values into a directory, without
# touching the host. The point is to be able to read what `configure` would
# install — the ExecStart lines in particular, where an omitted optional flag
# and an empty one are very different things.
cmd_render() {
    local out=${1:-./rendered-$PROFILE}
    mkdir -p "$out"
    RPC_USER=${RPC_USER:-RPC_USER_PLACEHOLDER}
    RPC_PASS=${RPC_PASS:-RPC_PASS_PLACEHOLDER}
    [ -r "$CREDS_FILE" ] && . "$CREDS_FILE"
    tmpl_load
    render "$CONF_DIR/bitcoind.conf.tmpl"             "$out/$BTC_CONF_NAME"
    render "$CONF_DIR/bitcoind.service.tmpl"          "$out/$BITCOIND_UNIT.service"
    render "$CONF_DIR/bip300301-enforcer.service.tmpl" "$out/$ENFORCER_UNIT.service"
    render "$CONF_DIR/thunder.service.tmpl"           "$out/$THUNDER_UNIT.service"
    say "rendered profile $PROFILE into $out"
    ls -1 "$out" | sed 's/^/    /'
}

cmd_profiles() {
    local f name
    for f in "$PROFILE_DIR"/*.env; do
        name=$(basename "$f" .env)
        # Read the description without executing the profile: sourcing three
        # profiles into one shell would leave a mixture of all of them.
        printf '  %-14s %s\n' "$name" \
            "$(sed -n 's/^PROFILE_DESC=\${PROFILE_DESC:-"\(.*\)"}$/\1/p' "$f" | head -1)"
    done
}

# ------------------------------------------------------------------- all ----
cmd_all() {
    cmd_preflight; cmd_deps
    cmd_bitcoin all
    cmd_enforcer all
    cmd_thunder all
    echo; say "node stack complete — profile $PROFILE"
    kv "credentials" "$CREDS_FILE  (back this up)"
    kv "verify" "$SELF verify"
    kv "control" "forknet status|start|stop|restart|logs"
    kv "pool" "$SELF pool   (optional, needs addresses in bootstrap.env)"
    echo
    warn "bitcoind will keep back-filling history for hours. The enforcer's"
    warn "getblocktemplate port stays closed until its mempool sync completes."
}

usage() {
    cat <<EOF
forknet-bootstrap — provision a forknet node stack, one component at a time

  $SELF [--profile NAME] <command> [sub-step]

components — each runs build -> configure -> start unless given a sub-step:
  bitcoin    [build|configure|snapshot|start|verify]   mainchain node
  enforcer   [build|configure|start|verify]            BIP300/301 enforcer
  thunder    [build|configure|start|verify]            sidechain #$SIDECHAIN_ID
  pool       [install|configure|start|verify]          simplepool (optional)

host-level:
  preflight   OS, cores, RAM, ~${MIN_DISK_GB}G disk, port availability
  deps        apt packages, service user, rust toolchain
  verify      health check across every installed component
  config      print the resolved configuration and exit
  render      render this profile's config + units to a directory, install nothing
  profiles    list available network profiles
  all         preflight -> deps -> bitcoin -> enforcer -> thunder

profiles (--profile, or PROFILE= in bootstrap.env; current: $PROFILE):
$(cmd_profiles)

env / bootstrap.env:
  SNAPSHOT_FROM=root@host:/path/utxo.dat   copy the snapshot over ssh
  PIN_VERSIONS=0                           track branch tips, not the pins
  FORCE=1                                  rebuild / overwrite configs
  SVC_SUFFIX=-alphanet                     run a second profile on this host

order matters: bitcoin -> enforcer -> thunder -> pool. The enforcer needs
bitcoind's RPC and ZMQ at startup, Thunder needs the enforcer's gRPC, and the
pool needs the enforcer's block template server.
EOF
}

case "${1:-help}" in
    preflight) cmd_preflight ;;
    deps)      cmd_deps ;;
    bitcoin|btc)      shift; cmd_bitcoin  "${1:-all}" ;;
    enforcer|enf)     shift; cmd_enforcer "${1:-all}" ;;
    thunder|thu)      shift; cmd_thunder  "${1:-all}" ;;
    pool)             shift; cmd_pool     "${1:-all}" ;;
    verify)    cmd_verify ;;
    config)    cmd_config ;;
    render)    shift; cmd_render "${1:-}" ;;
    profiles)  say "profiles"; cmd_profiles ;;
    all)       cmd_all ;;
    *)         usage ;;
esac
