# shellcheck shell=bash
#
# thunder — the sidechain node. Component 3 of 4. Needs the enforcer's gRPC.
#
# Thunder only advances when a mainchain block commits to it, and those
# commitments only exist if a miner used an enforcer template. A Thunder that
# sits at height 0 with a connected peer is usually not a Thunder problem.

thunder_build() {
    need_root
    say "thunder — $THUNDER_REPO @ $THUNDER_REF — 10-20 min"
    clone_or_update "$THUNDER_REPO" "$SW_DIR/thunder-rust" "$THUNDER_REF" "$THUNDER_PIN"

    # --release for the same reason as the enforcer: a debug build misses BMM
    # windows, which reads as "the sidechain is stuck".
    if [ -x "$SW_DIR/thunder-rust/target/release/thunder_app" ] && [ "${FORCE:-0}" != 1 ]; then
        skip "thunder already built (FORCE=1 to rebuild)"
    else
        as_user "cd '$SW_DIR/thunder-rust' && cargo build --release"
    fi
    say "thunder build ok"
}

thunder_configure() {
    need_root
    say "configuring thunder"
    tmpl_load
    mkdir -p "$THUNDER_DATADIR"
    chown -R "$FORKNET_USER:$FORKNET_USER" "$THUNDER_DATADIR"

    install_unit thunder.service.tmpl "$THUNDER_UNIT" 644
    systemctl daemon-reload
    systemctl enable --quiet "$THUNDER_UNIT"
    write_host_state
    say "thunder configured ($THUNDER_UNIT, --network $THUNDER_NETWORK, sidechain #$SIDECHAIN_ID)"
}

thunder_cli() {
    sudo -u "$FORKNET_USER" "$SW_DIR/thunder-rust/target/release/thunder_app_cli" \
        --rpc-url "http://127.0.0.1:$THUNDER_RPC_PORT" "$@"
}

thunder_start() {
    need_root
    require_built "$SW_DIR/thunder-rust/target/release/thunder_app" thunder
    [ "$(unit_state "$ENFORCER_UNIT")" = active ] \
        || warn "$ENFORCER_UNIT is not active — Thunder needs its gRPC and will restart until it is"
    say "starting $THUNDER_UNIT"
    systemctl start "$THUNDER_UNIT"
    sleep 5

    if [ -n "$THUNDER_PEER" ]; then
        say "adding thunder peer $THUNDER_PEER"
        # connect-peer takes IP:PORT, never a hostname, and returns 0 as soon
        # as the address is recorded — that is not proof it connected. The
        # peer list in `verify` is.
        thunder_cli connect-peer "$THUNDER_PEER" || warn "connect-peer failed; add it later"
    else
        warn "profile $PROFILE sets no THUNDER_PEER — the node will sit alone until you add one"
    fi
    kv "$THUNDER_UNIT" "$(unit_state "$THUNDER_UNIT")"
}

thunder_verify() {
    local fail=0 st
    st=$(unit_state "$THUNDER_UNIT"); kv "$THUNDER_UNIT" "$st"; [ "$st" = active ] || fail=1

    printf '    %-26s ' 'height'
    thunder_cli get-blockcount 2>/dev/null || { echo "DOWN"; fail=1; }

    # QUIC over UDP: `ss -tln` lists TCP only and will never show this port,
    # so a healthy node reads as unbound if you check the wrong table.
    printf '    %-26s ' "p2p (UDP $THUNDER_P2P_PORT)"
    ss -uln | grep_has -E "[:.]$THUNDER_P2P_PORT\b" && echo "bound" || { echo "NOT BOUND"; fail=1; }

    printf '    %-26s ' 'peers'
    thunder_cli list-peers 2>/dev/null | jq -c '[.[] | {address, status}]' 2>/dev/null || echo '?'

    kv "wallet" "$THUNDER_DATADIR"
    return $fail
}

cmd_thunder() {
    case "${1:-all}" in
        build)     thunder_build ;;
        configure) thunder_configure ;;
        start)     thunder_start ;;
        verify)    say "verifying thunder"; thunder_verify ;;
        all)       thunder_build; thunder_configure; thunder_start
                   say "thunder ready — next: $SELF pool (optional)" ;;
        *) die "usage: $SELF thunder [all|build|configure|start|verify]" ;;
    esac
}
