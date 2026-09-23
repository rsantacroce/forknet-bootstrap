# shellcheck shell=bash
#
# common.sh — helpers shared by every step. Sourced by forknet-bootstrap.sh,
# never executed on its own.
#
# Everything here assumes the caller has already resolved configuration
# (defaults <- profile <- bootstrap.env <- environment) and exported it.

# ---------------------------------------------------------------- output ----
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$c_ok"   "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '%s[x]%s %s\n' "$c_err"  "$c_off" "$*" >&2; exit 1; }
skip() { printf '%s    (skip) %s%s\n' "$c_dim" "$*" "$c_off"; }
kv()   { printf '    %-26s %s\n' "$1" "$2"; }

need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }

# `producer | grep -q PATTERN` is broken under `set -o pipefail`, which this
# script sets. grep -q exits the moment it finds a match; the producer then
# gets SIGPIPE writing to a closed pipe and dies with 141, and pipefail makes
# 141 the status of the whole pipeline. So the test reports FAILURE precisely
# when it SUCCEEDS — and when there is genuinely no match grep exits 1, which
# is also failure. Both branches are false: the check can never pass.
#
# It bit the trap-1 guard in bitcoin_build hardest (137k lines of `strings`
# output makes the race a certainty), where it meant every build warned that
# the config filename was missing from a binary that contained it. The port
# checks in preflight and the three verify steps have small enough output to
# usually win the race, which is worse: they fail intermittently.
#
# grep -c reads its input to the end, so nothing is ever SIGPIPEd and the
# count decides.
grep_has() {  # reads stdin; $@ = grep args, pattern last. 0 if >=1 match.
    local n
    n=$(grep -c "$@" 2>/dev/null || true)
    [ "${n:-0}" -gt 0 ]
}


as_user() { sudo -u "$FORKNET_USER" -H bash -lc "$1"; }

# ------------------------------------------------------------- templating ----
# TMPL_VARS is a flat list of KEY=VALUE strings. Values may contain spaces,
# backslashes and ampersands — which is exactly why substitution is done with
# bash parameter expansion instead of sed, where `&` and `\` in a replacement
# are metacharacters and silently produce the wrong file.
TMPL_VARS=()

tmpl_set() {  # $1=KEY  $2=VALUE
    TMPL_VARS+=("$1=$2")
}

tmpl_reset() { TMPL_VARS=(); }

# A key whose name ends in _LINE is an OPTIONAL LINE: when its value is empty
# the whole template line is dropped rather than blanked. These sit inside
# backslash-continued ExecStart= blocks, where a blank line terminates the
# continuation and systemd then starts the daemon with half its flags — a
# failure that looks like a bug in the daemon, not in this file.
render() {  # $1=template  $2=dest
    local tmpl=$1 dest=$2 line pair key val drop
    [ -f "$tmpl" ] || die "missing template: $tmpl"
    : > "$dest"
    while IFS= read -r line || [ -n "$line" ]; do
        drop=0
        for pair in "${TMPL_VARS[@]}"; do
            key=${pair%%=*}
            case "$line" in
                *"@@$key@@"*)
                    val=${pair#*=}
                    case "$key" in
                        *_LINE) [ -z "$val" ] && { drop=1; break; } ;;
                    esac
                    line=${line//"@@$key@@"/$val}
                    ;;
            esac
        done
        [ "$drop" = 1 ] && continue
        printf '%s\n' "$line" >> "$dest"
    done < "$tmpl"

    # A template that grew a placeholder nobody bound would otherwise install a
    # unit file containing a literal @@FOO@@, which systemd accepts and the
    # daemon then chokes on.
    local leftover
    leftover=$(grep -o '@@[A-Z_]*@@' "$dest" 2>/dev/null | sort -u | tr '\n' ' ') || true
    [ -z "$leftover" ] || die "unsubstituted placeholder in $dest: $leftover"
}

# ------------------------------------------------------------ credentials ----
# Salted HMAC-SHA256, the format bitcoind's share/rpcauth/rpcauth.py emits.
gen_rpcauth() {  # $1=user  $2=password -> prints "user:salt$hash"
    python3 - "$1" "$2" <<'PY'
import hashlib, hmac, os, sys
user, password = sys.argv[1], sys.argv[2]
salt = os.urandom(16).hex()
h = hmac.new(salt.encode(), password.encode(), hashlib.sha256).hexdigest()
print(f"{user}:{salt}${h}")
PY
}

# Generated on this host, once. Never lifted from another node: a shared RPC
# password means one compromised node is all of them.
#
# Both the bitcoin and the enforcer steps need these, and either may run first,
# so this is idempotent and callable from both.
ensure_credentials() {
    if [ -f "$CREDS_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CREDS_FILE"
        [ -n "${RPC_USER:-}" ] && [ -n "${RPC_PASS:-}" ] || die "$CREDS_FILE has no RPC_USER/RPC_PASS"
        return 0
    fi
    RPC_USER=${RPC_USER:-forknet}
    RPC_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 43)
    mkdir -p "$(dirname "$CREDS_FILE")"
    local old_umask; old_umask=$(umask)
    umask 077
    cat > "$CREDS_FILE" <<EOF
# forknet node credentials — profile $PROFILE
# generated $(date -u +%FT%TZ) on $(hostname)
# 0600, root-only. BACK THIS UP OFF THE MACHINE.
RPC_USER=$RPC_USER
RPC_PASS=$RPC_PASS
EOF
    umask "$old_umask"
    chmod 600 "$CREDS_FILE"
    say "generated RPC credentials -> $CREDS_FILE"
}

# ------------------------------------------------------------------ repos ----
clone_or_update() {  # $1=repo url  $2=dir  $3=ref  $4=pin
    local url=$1 dir=$2 ref=$3 pin=$4 name
    name=$(basename "$dir")

    if [ -d "$dir/.git" ]; then
        local have; have=$(as_user "cd '$dir' && git remote get-url origin" 2>/dev/null || echo '')
        if [ -n "$have" ] && [ "$have" != "$url" ]; then
            # Silently building a different fork's source into the same tree is
            # how you end up with a binary nobody can account for.
            die "$dir is a checkout of $have, not $url — remove it or set the matching profile"
        fi
    else
        say "cloning $name <- $url"
        mkdir -p "$(dirname "$dir")"
        chown "$FORKNET_USER:$FORKNET_USER" "$(dirname "$dir")"
        as_user "git clone --recurse-submodules '$url' '$dir'"
    fi

    as_user "cd '$dir' && git fetch --tags --quiet origin"
    if [ "$PIN_VERSIONS" = 1 ] && [ -n "$pin" ]; then
        as_user "cd '$dir' && git checkout --quiet '$pin'"
    else
        [ "$PIN_VERSIONS" = 1 ] && [ -z "$pin" ] && \
            warn "$name has no pin in profile $PROFILE — tracking '$ref'"
        as_user "cd '$dir' && git checkout --quiet '$ref' && git pull --ff-only --quiet"
    fi
    as_user "cd '$dir' && git submodule update --init --recursive --quiet"
    kv "$name" "$(as_user "cd '$dir' && git describe --tags --always") ($ref)"
}

# --------------------------------------------------------------- bitcoind ----
btc_cli() { sudo -u "$FORKNET_USER" "$SW_DIR/bitcoin/build/bin/bitcoin-cli" -datadir="$BTC_DATADIR" "$@"; }

wait_rpc() {  # $1=timeout seconds
    local t=${1:-120} i=0
    while [ "$i" -lt "$t" ]; do
        btc_cli getblockcount >/dev/null 2>&1 && return 0
        sleep 2; i=$((i+2))
    done
    return 1
}

# --------------------------------------------------------------- systemd ----
install_unit() {  # $1=template basename  $2=unit name  $3=mode
    render "$CONF_DIR/$1" "/etc/systemd/system/$2.service"
    chmod "${3:-644}" "/etc/systemd/system/$2.service"
}

unit_state() { systemctl is-active "$1" 2>/dev/null || true; }

require_built() {  # $1=path  $2=step name
    [ -x "$1" ] || die "$1 is missing — run: $SELF $2 build"
}

# ------------------------------------------------------- template bindings ----
# Built once, from the fully resolved configuration. Anything a .tmpl can
# reference has to appear here or render() aborts on the leftover placeholder.
tmpl_load() {
    tmpl_reset
    tmpl_set PROFILE                    "$PROFILE"
    tmpl_set PROFILE_DESC               "$PROFILE_DESC"
    tmpl_set FORKNET_USER               "$FORKNET_USER"
    tmpl_set HOME_DIR                   "$HOME_DIR"
    tmpl_set SW_DIR                     "$SW_DIR"

    tmpl_set BITCOIN_REF                "$BITCOIN_REF"
    tmpl_set BTC_DATADIR                "$BTC_DATADIR"
    tmpl_set BTC_CONF_NAME              "$BTC_CONF_NAME"
    tmpl_set BTC_RPC_PORT               "$BTC_RPC_PORT"
    tmpl_set BTC_P2P_PORT               "$BTC_P2P_PORT"
    tmpl_set BTC_NETWORK_MAGIC          "$BTC_NETWORK_MAGIC"
    tmpl_set BTC_ADDNODE_LINE           "${BTC_ADDNODE:+addnode=$BTC_ADDNODE}"
    tmpl_set DBCACHE_MB                 "$DBCACHE_MB"
    tmpl_set BTC_ASSUMEVALID_LINE       "${BTC_ASSUMEVALID:+assumevalid=$BTC_ASSUMEVALID}"
    tmpl_set ZMQ_ADDR                   "$ZMQ_ADDR"

    tmpl_set ENFORCER_DATADIR           "$ENFORCER_DATADIR"
    tmpl_set ENFORCER_GRPC              "$ENFORCER_GRPC"
    tmpl_set ENFORCER_GBT               "$ENFORCER_GBT"
    tmpl_set ENFORCER_NETWORK_PRESET    "$ENFORCER_NETWORK_PRESET"
    tmpl_set RPC_USER                   "${RPC_USER:-}"
    tmpl_set RPC_PASS                   "${RPC_PASS:-}"

    tmpl_set THUNDER_DATADIR            "$THUNDER_DATADIR"
    tmpl_set THUNDER_NETWORK            "$THUNDER_NETWORK"
    tmpl_set THUNDER_P2P_PORT           "$THUNDER_P2P_PORT"
    tmpl_set THUNDER_RPC_PORT           "$THUNDER_RPC_PORT"
    tmpl_set SIDECHAIN_ID               "$SIDECHAIN_ID"

    tmpl_set BITCOIND_UNIT              "$BITCOIND_UNIT"
    tmpl_set ENFORCER_UNIT              "$ENFORCER_UNIT"
    tmpl_set THUNDER_UNIT               "$THUNDER_UNIT"

    # Optional ExecStart lines. Empty value -> the line is removed, because a
    # flag with no value is not the same as an absent flag: the enforcer
    # refuses to start on `--coinbase-recipient` with nothing after it.
    tmpl_set COINBASE_RECIPIENT_LINE \
        "${COINBASE_RECIPIENT:+  --coinbase-recipient $COINBASE_RECIPIENT \\}"
    tmpl_set ENFORCER_NETWORK_MAGIC_LINE \
        "${ENFORCER_NETWORK_MAGIC:+  --network-magic $ENFORCER_NETWORK_MAGIC \\}"
    tmpl_set THUNDER_NETWORK_MAGIC_LINE \
        "${THUNDER_NETWORK_MAGIC:+  --network-magic $THUNDER_NETWORK_MAGIC \\}"
}

# ------------------------------------------------------------- host state ----
# The resolved profile, written where the `forknet` wrapper and any later
# `verify` can read it, plus the wrapper itself. Without the env file the
# wrapper has to re-derive paths and ports, and quietly reports on the wrong
# datadir when the profile is not the default.
#
# Called by every component's `configure`, so the wrapper is present as soon as
# there is anything to control.
write_host_state() {
    mkdir -p /etc/forknet
    cat > /etc/forknet/env <<EOF
# written by forknet-bootstrap.sh — do not edit, re-run 'configure' instead
PROFILE=$PROFILE
FORKNET_USER=$FORKNET_USER
HOME_DIR=$HOME_DIR
SW_DIR=$SW_DIR
BTC_DATADIR=$BTC_DATADIR
BTC_CONF_NAME=$BTC_CONF_NAME
BTC_RPC_PORT=$BTC_RPC_PORT
THUNDER_DATADIR=$THUNDER_DATADIR
THUNDER_RPC_PORT=$THUNDER_RPC_PORT
THUNDER_P2P_PORT=$THUNDER_P2P_PORT
ENFORCER_DATADIR=$ENFORCER_DATADIR
ENFORCER_GRPC=$ENFORCER_GRPC
ENFORCER_GBT=$ENFORCER_GBT
BITCOIND_UNIT=$BITCOIND_UNIT
ENFORCER_UNIT=$ENFORCER_UNIT
THUNDER_UNIT=$THUNDER_UNIT
POOL_ROOT=$POOL_ROOT
CREDS_FILE=$CREDS_FILE
EOF
    chmod 644 /etc/forknet/env

    install -m 755 "$HERE/forknet" /usr/local/bin/forknet
}
