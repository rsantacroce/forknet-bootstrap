# shellcheck shell=bash
#
# preflight — the checks worth doing before an hour of compiling.

cmd_preflight() {
    need_root
    say "preflight — profile $PROFILE"
    kv "network" "$PROFILE_DESC"

    . /etc/os-release 2>/dev/null || die "cannot read /etc/os-release"
    case "${VERSION_ID:-}" in
        24.*|22.*) kv "os" "${PRETTY_NAME:-unknown}" ;;
        *) warn "untested on ${PRETTY_NAME:-unknown} (built for Ubuntu 22.04/24.04) — continuing" ;;
    esac

    local cores ram_gb disk_gb
    cores=$(nproc)
    ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    mkdir -p "$HOME_DIR"
    disk_gb=$(df -BG --output=avail "$HOME_DIR" | tail -1 | tr -dc '0-9')

    kv "cores / ram" "$cores cores, ${ram_gb}G"
    kv "free disk on $HOME_DIR" "${disk_gb}G"
    [ "$ram_gb"  -ge "$MIN_RAM_GB"  ] || warn "only ${ram_gb}G RAM; ${MIN_RAM_GB}G+ recommended (dbcache=$DBCACHE_MB)"
    [ "$disk_gb" -ge "$MIN_DISK_GB" ] || die  "need ~${MIN_DISK_GB}G free — the $PROFILE datadir reaches ~878G. Got ${disk_gb}G."
    [ "$cores"   -ge 4 ] || warn "only $cores cores; the Rust builds will be slow"

    # Ports this profile is about to claim. Thunder's is UDP and will never
    # show in `ss -tln`, which is its own trap further down the install.
    local busy=0 p
    for p in "$BTC_RPC_PORT" "$BTC_P2P_PORT" "${ENFORCER_GRPC##*:}" "${ENFORCER_GBT##*:}" "$THUNDER_RPC_PORT"; do
        if ss -tln 2>/dev/null | grep_has -E "[:.]$p\b"; then warn "TCP port $p already in use"; busy=1; fi
    done
    if ss -uln 2>/dev/null | grep_has -E "[:.]$THUNDER_P2P_PORT\b"; then
        warn "UDP port $THUNDER_P2P_PORT already in use"; busy=1
    fi
    [ "$busy" = 0 ] && kv "ports" "all free (tcp $BTC_RPC_PORT/$BTC_P2P_PORT/${ENFORCER_GRPC##*:}/${ENFORCER_GBT##*:}/$THUNDER_RPC_PORT, udp $THUNDER_P2P_PORT)"

    say "preflight ok"
}
