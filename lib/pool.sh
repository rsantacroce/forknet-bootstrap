# shellcheck shell=bash
#
# pool — simplepool (LayerTwo-Labs). Component 4 of 4, and the only optional
# one: a node is useful without it, a pool is not useful without the node.
#
# simplepool ships its own installer, which is authoritative for how the pool
# is laid out (build, database schema, three systemd units, nginx vhost, TLS).
# This step does not reimplement it — it fetches it at a known ref and drives
# it non-interactively with values derived from the profile, so that a pool
# install is reproducible and lands on the same network as everything else.

pool_repo_slug() {  # https://github.com/OWNER/REPO(.git) -> OWNER/REPO
    local s=${POOL_REPO#*github.com[:/]}
    s=${s%.git}
    printf '%s\n' "${s#/}"
}

pool_require_config() {
    # The pool moves money. Nothing here has a safe default, so refuse rather
    # than install something that pays out to the wrong address.
    [ -n "$POOL_OPERATOR_ADDRESS" ] || die "POOL_OPERATOR_ADDRESS is unset — the address that takes the fee cut. Set it in bootstrap.env."
    if [ "$POOL_MODE" = pps-classic ]; then
        [ -n "$POOL_BTC_ADDRESS" ] \
            || die "POOL_MODE=pps-classic needs POOL_BTC_ADDRESS (where the mined reward lands)"
        [ -n "$POOL_THUNDER_ADDRESS" ] \
            || die "POOL_MODE=pps-classic needs POOL_THUNDER_ADDRESS (Thunder reserve — dashboard deposits and the payout worker's source)"
    fi

    # The whole claim of pplns-coinbase is that the pool never holds the
    # reward: the block's own coinbase pays the window, one output per miner.
    # A configured pool wallet is the shape of a pool that does, so the proxy
    # refuses to start with one (src/config.c, -9) rather than run a
    # custodial-looking pool that quietly is not one. Catch it here, before a
    # twenty-minute build, instead of at the first restart.
    if [ "$POOL_MODE" = pplns-coinbase ]; then
        [ -z "$POOL_BTC_ADDRESS" ] \
            || die "POOL_MODE=pplns-coinbase must NOT set POOL_BTC_ADDRESS — this mode pays miners straight from the coinbase and the pool never receives the reward. Clear it in bootstrap.env."
    fi
    case "$POOL_MODE" in
        pplns-thunder|pplns-btc)
            die "POOL_MODE=$POOL_MODE is not wired up here yet — only solo, pps-classic and pplns-coinbase are. Both need the pool to custody the reward and a payout rail configured; add them the way pplns-coinbase is added below before using one." ;;
    esac

    # THE trap. Templates must come from the enforcer, not from bitcoind:
    # a bitcoind coinbase carries only the segwit commitment, so no BIP300/301
    # commitments reach the chain and no sidechain can ever be merge-mined.
    # Every other view of the pool looks healthy while this is wrong.
    case "$POOL_BITCOIND_URL" in
        *":${ENFORCER_GBT##*:}"|*":${ENFORCER_GBT##*:}/") ;;
        *":$BTC_RPC_PORT"|*":$BTC_RPC_PORT/")
            die "POOL_BITCOIND_URL points at bitcoind ($POOL_BITCOIND_URL). It must point at the ENFORCER's template server (http://$ENFORCER_GBT) or the pool mines commitment-free blocks." ;;
        *) warn "POOL_BITCOIND_URL=$POOL_BITCOIND_URL is neither the enforcer ($ENFORCER_GBT) nor bitcoind — assuming you meant it" ;;
    esac
}

pool_fetch_installer() {
    local slug url
    slug=$(pool_repo_slug)
    url=${POOL_INSTALLER_URL:-https://raw.githubusercontent.com/$slug/$POOL_REF/scripts/install.sh}
    say "fetching simplepool installer ($slug @ $POOL_REF)"
    curl -fsSL -m 60 "$url" -o "$POOL_INSTALLER" || die "could not fetch the installer from $url"
    chmod 700 "$POOL_INSTALLER"
    kv "installer" "$POOL_INSTALLER"
}

# simplepool ships its own installer and it is authoritative — except for one
# thing. On 2026-09-07-pplns-coinbase the PROXY implements all five modes, but
# scripts/install.sh still validates the mode against solo|pps-classic only:
#
#     [[ "$MODE" =~ ^(solo|pps-classic)$ ]] || die "invalid --mode: $MODE"
#
# So the binary accepts `pool_mode = pplns-coinbase` and the installer refuses
# to write it. Install under the mode that has the same SHAPE and re-assert
# the real one afterwards.
#
# For pplns-coinbase that shape is solo, and it is a genuine match rather than
# a placeholder: solo means BTC-address stratum usernames (same as here),
# installs no payout worker (this mode has none), and conf_unsets
# pool_btc_address — which pplns-coinbase refuses to start with.
pool_installer_mode() {
    case "$POOL_MODE" in
        pplns-coinbase) printf 'solo\n' ;;
        *)              printf '%s\n' "$POOL_MODE" ;;
    esac
}

pool_conf_set() {   # file key value
    local f=$1 k=$2 v=$3
    if grep_has -E "^[[:space:]]*$k[[:space:]]*=" < "$f"; then
        sed -i "s|^[[:space:]]*$k[[:space:]]*=.*|$k = $v|" "$f"
    else
        printf '%s = %s\n' "$k" "$v" >> "$f"
    fi
}

pool_conf_unset() { # file key
    sed -i "/^[[:space:]]*$2[[:space:]]*=/d" "$1"
}

# Re-assert everything the installer cannot write. Runs after every install,
# because the installer does `conf_set pool_mode "$MODE"` unconditionally —
# without this, re-running `pool install` to upgrade silently reverts a
# coinbase-direct pool to solo, and solo pays whoever finds the block instead
# of the window. That is a payout change with no error and no log line.
pool_apply_mode() {
    [ "$POOL_MODE" = pplns-coinbase ] || return 0
    local conf="$POOL_ROOT/proxy.conf"
    [ -f "$conf" ] || die "$conf missing — the installer did not get far enough to configure"

    say "re-asserting pool_mode=$POOL_MODE (the installer can only write solo|pps-classic)"
    pool_conf_set "$conf" pool_mode "$POOL_MODE"
    pool_conf_set "$conf" pplns_window_diff_multiple "$POOL_PPLNS_WINDOW_MULTIPLE"
    pool_conf_set "$conf" coinbase_max_bytes         "$POOL_COINBASE_MAX_BYTES"
    pool_conf_set "$conf" pplns_payout_floor_sats    "$POOL_PPLNS_PAYOUT_FLOOR_SATS"

    # Refused by the proxy in this mode; the installer's solo path already
    # unsets it, but an operator editing by hand is exactly who this catches.
    pool_conf_unset "$conf" pool_btc_address
    # pps-classic-only knobs. Harmless to the parser, but they describe a
    # payout model this pool no longer has, and proxy.conf is what an operator
    # reads to find out how the pool pays.
    pool_conf_unset "$conf" pps_sats_per_diff
    pool_conf_unset "$conf" pps_min_network_difficulty
    pool_conf_unset "$conf" pps_refuse_shares_below_min

    # sed -i renames a new file into place, so it lands owned by root on a
    # file the service reads as $FORKNET_USER with mode 0640.
    chown "$FORKNET_USER:$FORKNET_USER" "$conf"
    chmod 0640 "$conf"

    kv "pplns window"     "$POOL_PPLNS_WINDOW_MULTIPLE x network difficulty"
    kv "coinbase budget"  "$POOL_COINBASE_MAX_BYTES bytes"
    kv "payout floor"     "$POOL_PPLNS_PAYOUT_FLOOR_SATS sats"

    # The installer's last step enables and STARTS the services, so by the
    # time this runs the daemon is already live on the config the installer
    # wrote — pool_mode=solo. Solo pays whoever finds the block; this mode
    # pays the window. Leaving it running would be a silent payout change,
    # and nothing downstream could notice, so restart onto what we just wrote.
    if [ "$(unit_state simplepool)" = active ]; then
        say "restarting simplepool onto the re-asserted config"
        systemctl restart simplepool
    fi
}

# Local C patches to the checkout. Same problem as the brand below — an
# install replaces the checkout, so a hand-edit lasts until the next upgrade —
# but C has to be REBUILT, not just rewritten, so this also runs make and
# restarts the proxy.
#
# The patch script is the authority on what is applied and refuses to proceed
# on a missing anchor, so an upstream change surfaces here as a loud failure
# rather than as a feature that quietly stopped existing.
pool_apply_patches() {
    [ "${POOL_PATCHES:-1}" = 1 ] || { skip "POOL_PATCHES=0 — no local patches"; return 0; }
    local script="$HERE/tools/simplepool-patches.py"
    [ -f "$script" ] || { warn "$script missing — skipping local patches"; return 0; }
    need_root

    say "applying local simplepool patches"
    python3 "$script" "$POOL_ROOT" || die "simplepool patch failed — see above"

    # Rebuild as the service user so object files stay owned by it.
    say "rebuilding simplepool after patching"
    sudo -u "$FORKNET_USER" make -C "$POOL_ROOT" -j"$(nproc)" >/dev/null \
        || die "simplepool rebuild failed after patching"

    if [ "$(unit_state simplepool)" = active ]; then
        say "restarting simplepool onto the patched binary"
        systemctl restart simplepool
    fi
}

# The dashboard's displayed name. Upstream has no setting for it —
# "simplepool" is hard-coded across dashboard/views/*.ejs — so it is rewritten
# here, and rewritten AGAIN after every install, because `pool install` is the
# upgrade path and it replaces the checkout. A hand-edit on the box lasts
# exactly until the next upgrade, which is the same trap as the coinbase tag.
#
# Three of the strings in those files must survive untouched, so this does not
# sed the word globally:
#
#   https://github.com/LayerTwo-Labs/simplepool   upstream's real URL
#   <code>simplepool</code>                       the SYSTEMD UNIT name, in the
#                                                 "restart simplepool" hint
#
# The patterns below each carry enough context to miss all of them: the title
# strings always have the middot separator, the brand is an anchor with
# class="brand", and head.ejs's fallback is a quoted default.
pool_apply_brand() {
    [ -n "$POOL_BRAND" ] || return 0
    need_root
    local views="$POOL_ROOT/dashboard/views"
    [ -d "$views" ] || { warn "$views missing — skipping brand"; return 0; }

    local b; b=$(printf '%s' "$POOL_BRAND" | sed -e 's/[&|\\]/\\&/g')
    say "branding the dashboard as '$POOL_BRAND'"
    # -print0/-0 so a path with a space cannot split the list.
    find "$views" -name '*.ejs' -print0 | xargs -0 sed -i \
        -e "s|· simplepool|· $b|g" \
        -e "s|class=\"brand\">simplepool<|class=\"brand\">$b<|g" \
        -e "s|: 'simplepool'|: '$b'|g"

    local left
    left=$(grep -rl "simplepool" "$views" 2>/dev/null | wc -l | tr -d ' ')
    kv "brand" "$POOL_BRAND"
    kv "files still naming simplepool" "$left (expected: the GitHub links + the restart hint)"

    # EJS templates are cached in production, so the running dashboard keeps
    # serving the old name until it is restarted.
    if [ "$(unit_state simplepool-dashboard)" = active ]; then
        say "restarting simplepool-dashboard to pick up the new brand"
        systemctl restart simplepool-dashboard
    fi
}

# Extra stratum ports. Kept here rather than hand-edited into proxy.conf
# because this repo drives the file, but note the installer would NOT clobber
# them either: install.sh section 8 rewrites only its own managed keys and
# preserves everything else verbatim.
#
# ORDERING TRAP, and it fails silently. The installer reads listener ports back
# OUT of the finished proxy.conf to open ufw for them. A listener added after
# that read binds fine and the firewall refuses every miner to it — the log
# says "stratum listening on :3335" while nothing can connect. On a host with
# ufw enabled, run `pool install` again after this, or open the ports by hand.
pool_apply_listeners() {
    [ -n "$POOL_LISTENERS" ] || return 0
    need_root
    local conf="$POOL_ROOT/proxy.conf"
    [ -f "$conf" ] || { warn "$conf missing — skipping listeners"; return 0; }

    # Rewrite rather than append: re-running must not accumulate duplicates,
    # and the proxy refuses to start on two listeners sharing a port.
    sed -i '/^[[:space:]]*listener[[:space:]]*=/d' "$conf"
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        printf 'listener = %s\n' "$line" >> "$conf"
        kv "listener" "$line"
    done <<< "$POOL_LISTENERS"

    chown "$FORKNET_USER:$FORKNET_USER" "$conf"
    chmod 0640 "$conf"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        local p
        while IFS= read -r line; do
            p=$(printf '%s' "$line" | grep -oE 'port=[0-9]+' | cut -d= -f2)
            [ -n "$p" ] && { ufw allow "$p/tcp" >/dev/null 2>&1; kv "ufw" "allowed $p/tcp"; }
        done <<< "$POOL_LISTENERS"
    else
        skip "ufw inactive — nothing to open"
    fi
}

pool_install() {
    need_root
    pool_require_config
    ensure_credentials
    pool_fetch_installer

    local args=(--non-interactive --yes
        --root "$POOL_ROOT" --user "$FORKNET_USER"
        --mode "$(pool_installer_mode)" --stratum-port "$POOL_STRATUM_PORT"
        --bitcoind-url "$POOL_BITCOIND_URL"
        --bitcoind-user "$RPC_USER" --bitcoind-pass "$RPC_PASS"
        --operator-address "$POOL_OPERATOR_ADDRESS" --fee-bps "$POOL_FEE_BPS"
        --dashboard-port "$POOL_DASHBOARD_PORT" --admin-user "$POOL_ADMIN_USER")

    if [ "$POOL_FROM_SOURCE" = 1 ]; then
        args+=(--from-source --repo "$POOL_REPO" --branch "$POOL_REF")
    else
        args+=(--from-release)
        [ -n "$POOL_RELEASE_TAG" ] && args+=("$POOL_RELEASE_TAG")
    fi

    if [ "$POOL_MODE" = pps-classic ]; then
        args+=(--pool-btc-address "$POOL_BTC_ADDRESS"
               --thunder-address "$POOL_THUNDER_ADDRESS"
               --thunder-rpc-url "$POOL_THUNDER_RPC_URL"
               --payout-interval-hours "$POOL_PAYOUT_INTERVAL_HOURS")
        # Only pass the override when it is actually set. Passing it empty is
        # not the same as omitting it (README trap 15), and the whole point of
        # leaving it unset is to let the proxy derive the rate per template.
        [ -n "$POOL_PPS_SATS_PER_DIFF" ] && args+=(--pps-sats-per-diff "$POOL_PPS_SATS_PER_DIFF")
    fi

    [ -n "$POOL_COINBASE_TAG" ]   && args+=(--coinbase-tag "$POOL_COINBASE_TAG")
    [ -n "$POOL_HOSTNAME" ]       && args+=(--hostname "$POOL_HOSTNAME")
    [ -n "$POOL_ADMIN_PASSWORD" ] && args+=(--admin-password "$POOL_ADMIN_PASSWORD")
    [ "$POOL_TLS" = 1 ] && [ -n "$POOL_TLS_EMAIL" ] && args+=(--tls --email "$POOL_TLS_EMAIL")
    [ "$POOL_NGINX" = 0 ]     && args+=(--no-nginx)
    [ "$POOL_DASHBOARD" = 0 ] && args+=(--no-dashboard)
    [ "$POOL_PAYOUT" = 0 ]    && args+=(--no-payout)
    [ "$POOL_FIREWALL" = 1 ]  && args+=(--enable-firewall)

    say "running the simplepool installer (idempotent; re-running is how you upgrade)"
    kv "mode" "$POOL_MODE$([ "$(pool_installer_mode)" != "$POOL_MODE" ] && printf ' (installed as %s, re-asserted after)' "$(pool_installer_mode)")"
    kv "templates from" "$POOL_BITCOIND_URL"
    "$POOL_INSTALLER" "${args[@]}" || die "simplepool installer failed"
    pool_apply_mode
    pool_apply_patches
    pool_apply_brand
    pool_apply_listeners
    say "pool installed at $POOL_ROOT"
}

# The installer hard-codes $ROOT/data/shares.db. When the database has to live
# somewhere else — a bigger disk, a path that survives reinstalling the
# checkout — the supported shape is a symlink plus a ReadWritePaths drop-in:
# the systemd sandbox runs with ProtectHome=read-only and resolves the symlink,
# so without the drop-in the service can open the link and not the file.
pool_data_link() {
    [ -n "$POOL_DATA_DIR" ] || return 0
    need_root
    say "pointing pool data at $POOL_DATA_DIR"
    mkdir -p "$POOL_DATA_DIR"
    chown -R "$FORKNET_USER:$FORKNET_USER" "$POOL_DATA_DIR"

    local link="$POOL_ROOT/data"
    if [ -L "$link" ]; then
        [ "$(readlink -f "$link")" = "$(readlink -f "$POOL_DATA_DIR")" ] || \
            die "$link already points at $(readlink -f "$link") — move the data yourself, this step will not"
    elif [ -d "$link" ]; then
        if [ -n "$(ls -A "$link" 2>/dev/null)" ]; then
            say "moving existing pool data into $POOL_DATA_DIR"
            cp -a "$link/." "$POOL_DATA_DIR/"
            mv "$link" "$link.replaced-$(date -u +%Y%m%dT%H%M%SZ)"
        else
            rmdir "$link"
        fi
        ln -s "$POOL_DATA_DIR" "$link"
    else
        ln -s "$POOL_DATA_DIR" "$link"
    fi
    chown -h "$FORKNET_USER:$FORKNET_USER" "$link"

    local u
    for u in $POOL_UNITS; do
        [ -f "/etc/systemd/system/$u.service" ] || continue
        mkdir -p "/etc/systemd/system/$u.service.d"
        cat > "/etc/systemd/system/$u.service.d/zz-pool-data.conf" <<EOF
# The unit sandbox resolves $POOL_ROOT/data to its target, so the REAL path
# has to be writable — granting the symlink is not enough.
[Service]
ReadWritePaths=$POOL_DATA_DIR
EOF
    done
    systemctl daemon-reload
}

# The proxy REFUSES TO START until the enforcer can build a block template,
# which on a fresh node means the whole initial sync — days, not minutes:
#
#   bitcoind ping failed: rpc error: enforcer is still syncing,
#   and cannot build block templates yet
#
# That is correct behaviour, and the unit's Restart=on-failure eventually
# brings the pool up on its own. The defaults make it a coin flip, though:
# RestartSec=3s against StartLimitBurst=5 per 10s is ~3.3 starts per window,
# so it clears the limit by 1.7 starts. Any extra delay on one attempt — a
# slow enforcer RPC, load during IBD — trips it, systemd gives up, and the
# pool then sits in `failed` through the sync and never starts. Nothing
# restarts it, and the node looks healthy right up to the moment you need it.
#
# So: back the retry off to once a minute and take the start limit off
# entirely. A pool waiting for its node should poll patiently forever, not
# race a rate limiter. Costs at most 60s of delay once the node is ready.
pool_retry_dropin() {
    need_root
    local u="${POOL_UNITS%% *}"
    [ -f "/etc/systemd/system/$u.service" ] || return 0
    mkdir -p "/etc/systemd/system/$u.service.d"
    cat > "/etc/systemd/system/$u.service.d/zz-wait-for-sync.conf" <<EOF
# Written by forknet-bootstrap.sh — see pool_retry_dropin in lib/pool.sh.
# The proxy exits 3 until the enforcer can serve a template. Poll once a
# minute, forever, instead of every 3s against a 5-per-10s start limit.
[Unit]
StartLimitIntervalSec=0

[Service]
RestartSec=60
EOF
    systemctl daemon-reload
    say "pool will retry once a minute until the enforcer can serve templates"
}

pool_configure() {
    need_root
    pool_require_config
    pool_data_link
    pool_retry_dropin
    pool_apply_brand
    pool_apply_listeners
    write_host_state
    say "pool configured"
}

pool_start() {
    need_root
    [ "$(unit_state "$ENFORCER_UNIT")" = active ] \
        || warn "$ENFORCER_UNIT is not active — the pool will get no BIP300/301 templates until it is"
    local u
    for u in $POOL_UNITS; do
        [ -f "/etc/systemd/system/$u.service" ] || { skip "$u not installed"; continue; }
        say "starting $u"; systemctl start "$u"; sleep 2
    done
}

pool_verify() {
    local fail=0 u st
    for u in $POOL_UNITS; do
        if [ -f "/etc/systemd/system/$u.service" ]; then
            st=$(unit_state "$u"); kv "$u" "$st"; [ "$st" = active ] || fail=1
        else
            kv "$u" "not installed"
        fi
    done

    printf '    %-26s ' "stratum (TCP $POOL_STRATUM_PORT)"
    ss -tln | grep_has -E "[:.]$POOL_STRATUM_PORT\b" && echo "listening" || { echo "NOT LISTENING"; fail=1; }

    # Reading it back from the installed config rather than from our own
    # variables: this is the setting that silently produces commitment-free
    # blocks, and the file is what the daemon actually uses.
    local conf="$POOL_ROOT/proxy.conf"
    if [ -f "$conf" ]; then
        local url; url=$(awk -F= '/^[[:space:]]*bitcoind_url/{gsub(/[[:space:]]/,"",$2); print $2}' "$conf" | tail -1)
        printf '    %-26s ' 'template source'
        case "$url" in
            *":${ENFORCER_GBT##*:}"*) echo "$url (enforcer — correct)" ;;
            "") echo "not set in $conf"; fail=1 ;;
            *)  echo "$url — NOT the enforcer ($ENFORCER_GBT): blocks carry no sidechain commitments"; fail=1 ;;
        esac
        # The installer rewrites pool_mode on every run, so a pool whose mode
        # it cannot express is one upgrade away from silently paying
        # differently. Read it back from the file the daemon actually loads.
        local mode; mode=$(awk -F= '/^[[:space:]]*pool_mode/{gsub(/[[:space:]]/,"",$2); print $2}' "$conf" | tail -1)
        printf '    %-26s ' 'pool mode'
        if [ "$mode" = "$POOL_MODE" ]; then
            echo "$mode"
        else
            echo "$mode — but bootstrap.env says $POOL_MODE; re-run 'pool install' or fix $conf"; fail=1
        fi
        local tag; tag=$(awk -F= '/^[[:space:]]*coinbase_tag/{gsub(/[[:space:]]/,"",$2); print $2}' "$conf" | tail -1)
        kv "coinbase tag" "${tag:-<unset>}"
        kv "db" "$(readlink -f "$POOL_ROOT/data" 2>/dev/null || echo "$POOL_ROOT/data")"
    else
        kv "proxy.conf" "missing at $conf"; fail=1
    fi
    return $fail
}

cmd_pool() {
    case "${1:-all}" in
        install|build) pool_install ;;
        configure)     pool_configure ;;
        start)         pool_start ;;
        verify)        say "verifying pool"; pool_verify ;;
        all)           pool_install; pool_configure; pool_start
                       say "pool ready — miners connect to stratum+tcp://<host>:$POOL_STRATUM_PORT" ;;
        *) die "usage: $SELF pool [all|install|configure|start|verify]" ;;
    esac
}
