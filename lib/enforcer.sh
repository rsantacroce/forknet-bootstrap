# shellcheck shell=bash
#
# enforcer — bip300301_enforcer. Component 2 of 4. Needs bitcoind's RPC and
# ZMQ at startup, and is what serves the BIP300/301 block template the pool
# must mine against.

enforcer_build() {
    need_root
    say "bip300301_enforcer — $ENFORCER_REPO @ $ENFORCER_REF — 10-20 min"
    clone_or_update "$ENFORCER_REPO" "$SW_DIR/bip300301_enforcer" "$ENFORCER_REF" "$ENFORCER_PIN"

    # --release is not optional: a debug enforcer cannot keep up with mempool
    # sync, and the symptom is a getblocktemplate port that never opens.
    if [ -x "$SW_DIR/bip300301_enforcer/target/release/bip300301_enforcer" ] && [ "${FORCE:-0}" != 1 ]; then
        skip "enforcer already built (FORCE=1 to rebuild)"
    else
        as_user "cd '$SW_DIR/bip300301_enforcer' && cargo build --release"
    fi

    # Presets come and go upstream: drynet3 exists in v0.3.4 and not on master.
    # Asking the binary now beats finding out from a crash loop after the unit
    # is installed and enabled.
    #
    # Read the WHOLE --network-preset block, not a fixed number of lines after
    # it. clap's long help puts the flag, its description, a blank line, then
    # `Possible values:` and only then the names — six lines down on the build
    # that carries drynet4/alphanet. A fixed -A2 window captures the
    # description and no names, which is not "no presets found", it is a
    # non-empty string that matches nothing, so the case below took the die
    # branch on a binary that supported the preset perfectly well.
    #
    # awk stops at the next option instead, so the window is right whatever
    # clap's spacing does next.
    local presets
    presets=$("$SW_DIR/bip300301_enforcer/target/release/bip300301_enforcer" --help 2>&1 \
              | awk '/--network-preset/{f=1; next}
                     f && /^[[:space:]]*--[a-z]/{exit}
                     f' | tr -d ' ' || true)
    case "$presets" in
        *"$ENFORCER_NETWORK_PRESET"*) kv "network-preset" "$ENFORCER_NETWORK_PRESET (supported)" ;;
        "") warn "could not read --network-preset values from this build; not checking" ;;
        *)  die "this enforcer build does not know preset '$ENFORCER_NETWORK_PRESET' — pin a version that does (profile $PROFILE)" ;;
    esac
    say "enforcer build ok"
}

enforcer_configure() {
    need_root
    say "configuring enforcer"
    ensure_credentials
    tmpl_load
    mkdir -p "$ENFORCER_DATADIR"
    chown -R "$FORKNET_USER:$FORKNET_USER" "$ENFORCER_DATADIR"

    # 0600: this unit file embeds the bitcoind RPC password in ExecStart.
    install_unit bip300301-enforcer.service.tmpl "$ENFORCER_UNIT" 600
    systemctl daemon-reload
    systemctl enable --quiet "$ENFORCER_UNIT"
    write_host_state
    say "enforcer configured ($ENFORCER_UNIT, preset $ENFORCER_NETWORK_PRESET)"
}

enforcer_start() {
    need_root
    require_built "$SW_DIR/bip300301_enforcer/target/release/bip300301_enforcer" enforcer
    [ "$(unit_state "$BITCOIND_UNIT")" = active ] \
        || die "$BITCOIND_UNIT is not running — the enforcer needs its RPC and ZMQ at startup. Run: $SELF bitcoin start"
    say "starting $ENFORCER_UNIT"
    systemctl start "$ENFORCER_UNIT"
    sleep 10
    kv "$ENFORCER_UNIT" "$(unit_state "$ENFORCER_UNIT")"
    warn "the getblocktemplate port stays closed until the initial mempool sync finishes"
}

enforcer_verify() {
    local fail=0 st
    st=$(unit_state "$ENFORCER_UNIT"); kv "$ENFORCER_UNIT" "$st"; [ "$st" = active ] || fail=1

    printf '    %-26s ' 'gRPC chain tip'
    curl -s -m 8 -X POST "http://$ENFORCER_GRPC/cusf.mainchain.v1.ValidatorService/GetChainTip" \
         -H 'content-type: application/json' -d '{}' 2>/dev/null \
         | jq -r '.blockHeaderInfo.height // "no answer"' || { echo "DOWN"; fail=1; }

    # This port only opens with --enable-block-template-server AND
    # --enable-mempool, and only once the initial mempool sync has finished.
    # Closed, a pool falls back to plain bitcoind templates whose coinbases
    # carry no BIP300/301 commitments — everything looks healthy and no
    # sidechain can ever advance.
    printf '    %-26s ' 'getblocktemplate'
    if ss -tln | grep_has -E "[:.]${ENFORCER_GBT##*:}\b"; then echo "listening on $ENFORCER_GBT"; else
        echo "NOT LISTENING (needs --enable-block-template-server, or still syncing)"; fail=1
    fi

    local seeds; seeds=$(ls -d "$ENFORCER_DATADIR"/*/ 2>/dev/null | tr '\n' ' ')
    [ -n "$seeds" ] && kv "wallet dirs" "$seeds"
    return $fail
}

cmd_enforcer() {
    case "${1:-all}" in
        build)     enforcer_build ;;
        configure) enforcer_configure ;;
        start)     enforcer_start ;;
        verify)    say "verifying enforcer"; enforcer_verify ;;
        all)       enforcer_build; enforcer_configure; enforcer_start
                   say "enforcer ready — next: $SELF thunder" ;;
        *) die "usage: $SELF enforcer [all|build|configure|start|verify]" ;;
    esac
}
