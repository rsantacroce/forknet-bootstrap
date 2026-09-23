# shellcheck shell=bash
#
# bitcoin — the mainchain node. Component 1 of 4; nothing else works until
# this one is serving RPC.
#
#   forknet-bootstrap.sh bitcoin            build -> configure -> snapshot -> start
#   forknet-bootstrap.sh bitcoin build      just the compile
#   forknet-bootstrap.sh bitcoin verify     safe any time

bitcoin_build() {
    need_root
    local jobs; jobs=$(nproc)
    say "bitcoin core — $BITCOIN_REPO @ ${BITCOIN_REF} — 20-40 min"
    clone_or_update "$BITCOIN_REPO" "$SW_DIR/bitcoin" "$BITCOIN_REF" "$BITCOIN_PIN"

    if [ -x "$SW_DIR/bitcoin/build/bin/bitcoind" ] && [ "${FORCE:-0}" != 1 ]; then
        skip "bitcoind already built (FORCE=1 to rebuild)"
    else
        # -DENABLE_IPC=OFF is required, not a preference. Core's multiprocess
        # support (src/ipc/libmultiprocess) hard-fails cmake configure with
        # "Cap'n Proto is required but was not found" unless capnproto 1.0+ is
        # installed, and ecash-com/bitcoin @ alphanet-bridge defaults it ON.
        # Nothing in this stack talks to bitcoin-node over IPC — the enforcer
        # uses JSON-RPC and ZMQ — so the dependency buys nothing. The node
        # running in production on alphanet, same commit e0bbd81ae0, is
        # built exactly this way (ENABLE_IPC:BOOL=OFF, no capnproto present).
        # Branches that predate multiprocess ignore the flag with a warning.
        as_user "cd '$SW_DIR/bitcoin' && cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_GUI=OFF -DWITH_ZMQ=ON -DENABLE_IPC=OFF"
        as_user "cd '$SW_DIR/bitcoin' && cmake --build build -j$jobs"
    fi
    kv "bitcoind" "$("$SW_DIR/bitcoin/build/bin/bitcoind" --version | head -1)"

    # The config filename is compiled in, and it differs per fork. Checking the
    # built binary against the profile catches a repo/profile mismatch here,
    # rather than as a node that starts on stock defaults and syncs the wrong
    # chain for an hour.
    if command -v strings >/dev/null 2>&1; then
        if strings "$SW_DIR/bitcoin/build/bin/bitcoind" | grep_has -xF "$BTC_CONF_NAME"; then
            kv "config filename" "$BTC_CONF_NAME (present in the binary)"
        else
            warn "'$BTC_CONF_NAME' does not appear in the built bitcoind at all"
            warn "profile $PROFILE and $BITCOIN_REPO@$BITCOIN_REF disagree about the config"
            warn "filename — whichever is wrong, the config file will be silently ignored"
            warn "and the daemon will come up on stock defaults"
        fi
    fi
    say "bitcoin build ok"
}

bitcoin_configure() {
    need_root
    say "configuring bitcoind"
    ensure_credentials
    tmpl_load
    mkdir -p "$BTC_DATADIR"

    # rpcauth lives in its own file pulled in via includeconf, so the password
    # hash is not tangled up with the settings you actually edit. includeconf
    # is resolved RELATIVE TO THE DATADIR, so it must be a bare filename.
    printf 'rpcauth=%s\n' "$(gen_rpcauth "$RPC_USER" "$RPC_PASS")" > "$RPCAUTH_CONF"
    chown "$FORKNET_USER:$FORKNET_USER" "$RPCAUTH_CONF"
    chmod 600 "$RPCAUTH_CONF"

    if [ -f "$BTC_CONF" ] && [ "${FORCE:-0}" != 1 ]; then
        skip "$BTC_CONF exists (FORCE=1 to overwrite)"
    else
        render "$CONF_DIR/bitcoind.conf.tmpl" "$BTC_CONF"
        chown "$FORKNET_USER:$FORKNET_USER" "$BTC_CONF"
        chmod 640 "$BTC_CONF"
        say "wrote $BTC_CONF"
    fi

    # A config left behind under a different fork's name is read by nothing but
    # looks authoritative to whoever reads the datadir next.
    local stray
    for stray in drivechain-ecash.conf ecash.conf drivechain-forknet.conf bitcoin.conf; do
        [ "$stray" = "$BTC_CONF_NAME" ] && continue
        [ -f "$BTC_DATADIR/$stray" ] && warn "$BTC_DATADIR/$stray is ignored by this build (it reads $BTC_CONF_NAME)"
    done

    install_unit bitcoind.service.tmpl "$BITCOIND_UNIT" 644
    systemctl daemon-reload
    systemctl enable --quiet "$BITCOIND_UNIT"
    chown -R "$FORKNET_USER:$FORKNET_USER" "$BTC_DATADIR"
    write_host_state
    say "bitcoind configured ($BITCOIND_UNIT)"
}

bitcoin_snapshot() {
    need_root
    say "assumeutxo snapshot"

    if [ -z "$SNAPSHOT_URL" ] && [ -z "$SNAPSHOT_FROM" ] && [ ! -f "$SNAPSHOT_FILE" ]; then
        warn "profile $PROFILE publishes no snapshot"
        warn "the node will sync from the network instead — days, not hours"
        warn "set SNAPSHOT_FROM=user@host:/path/to/snapshot.dat to copy one from a node you run"
        return 0
    fi

    if [ -n "$SNAPSHOT_FROM" ] && [ ! -f "$SNAPSHOT_FILE" ]; then
        say "copying snapshot from $SNAPSHOT_FROM"
        scp "$SNAPSHOT_FROM" "$SNAPSHOT_FILE"
    elif [ -n "$SNAPSHOT_URL" ] && [ ! -f "$SNAPSHOT_FILE" ]; then
        say "downloading snapshot (~9.5G) from $SNAPSHOT_URL"
        # -C - resumes a partial file: the server sends accept-ranges, and
        # restarting a 9.5G download from zero over a dropped connection is
        # the kind of thing that turns a bad hour into a bad afternoon.
        curl -fL -C - --progress-bar -o "$SNAPSHOT_FILE" "$SNAPSHOT_URL" \
            || die "snapshot download failed; re-run this step to resume"
    fi

    if [ -f "$SNAPSHOT_FILE" ] && [ -n "$SNAPSHOT_BYTES" ]; then
        local got; got=$(stat -c %s "$SNAPSHOT_FILE")
        if [ "$got" != "$SNAPSHOT_BYTES" ]; then
            die "snapshot is $got bytes, expected $SNAPSHOT_BYTES — truncated or a different snapshot. Delete $SNAPSHOT_FILE and re-run."
        fi
        kv "size verified" "$got bytes"
    fi
    [ -f "$SNAPSHOT_FILE" ] || { warn "no snapshot at $SNAPSHOT_FILE — syncing from the network"; return 0; }

    chown "$FORKNET_USER:$FORKNET_USER" "$SNAPSHOT_FILE"
    kv "snapshot" "$(du -h "$SNAPSHOT_FILE" | cut -f1) at $SNAPSHOT_FILE"

    require_built "$SW_DIR/bitcoin/build/bin/bitcoind" bitcoin
    systemctl is-active --quiet "$BITCOIND_UNIT" || { say "starting $BITCOIND_UNIT"; systemctl start "$BITCOIND_UNIT"; }
    wait_rpc 300 || die "bitcoind RPC did not come up"

    local h; h=$(btc_cli getblockcount 2>/dev/null || echo 0)
    if [ "${h:-0}" -gt "${SNAPSHOT_HEIGHT:-0}" ]; then
        skip "chain already at height $h — snapshot not needed"
        return 0
    fi

    # The snapshot height must match an m_assumeutxo_data entry compiled into
    # this branch. A file from another network is rejected here, not silently
    # merged — which is the one good thing about this failure mode.
    say "loading snapshot (10-30 min, bitcoind is unresponsive during this)"
    btc_cli loadtxoutset "$SNAPSHOT_FILE" || die "loadtxoutset failed — see $BTC_DATADIR/debug.log"
    say "snapshot loaded; background sync of history continues for hours"
}

bitcoin_start() {
    need_root
    require_built "$SW_DIR/bitcoin/build/bin/bitcoind" bitcoin
    [ -f "$BTC_CONF" ] || die "$BTC_CONF is missing — run: $SELF bitcoin configure"
    say "starting $BITCOIND_UNIT"
    systemctl start "$BITCOIND_UNIT"
    wait_rpc 600 || die "bitcoind RPC never answered — check: journalctl -u $BITCOIND_UNIT, and $BTC_DATADIR/debug.log"
    kv "height" "$(btc_cli getblockcount)"
}

bitcoin_verify() {
    local fail=0 st
    st=$(unit_state "$BITCOIND_UNIT"); kv "$BITCOIND_UNIT" "$st"; [ "$st" = active ] || fail=1

    printf '    %-26s ' 'height'
    btc_cli getblockcount 2>/dev/null || { echo "DOWN"; fail=1; }

    printf '    %-26s ' 'chain'
    btc_cli getblockchaininfo 2>/dev/null \
        | jq -r '.chain + " (ibd=" + (.initialblockdownload|tostring) + ")"' || echo '?'

    # `chain` reads "main" on every one of these profiles — they are mainnet
    # forks, so ChainType::MAIN is correct and not a sign of the wrong network.
    printf '    %-26s ' 'peers'
    btc_cli getconnectioncount 2>/dev/null || echo '?'

    kv "config in use" "$BTC_CONF"
    return $fail
}

cmd_bitcoin() {
    case "${1:-all}" in
        build)     bitcoin_build ;;
        configure) bitcoin_configure ;;
        snapshot)  bitcoin_snapshot ;;
        start)     bitcoin_start ;;
        verify)    say "verifying bitcoin"; bitcoin_verify ;;
        all)       bitcoin_build; bitcoin_configure; bitcoin_snapshot; bitcoin_start
                   say "bitcoin ready — next: $SELF enforcer" ;;
        *) die "usage: $SELF bitcoin [all|build|configure|snapshot|start|verify]" ;;
    esac
}
