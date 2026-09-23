# shellcheck shell=bash
#
# deps — apt packages, the service user, and a Rust toolchain.
#
# Split from the component steps on purpose: this is the only step that needs
# to run once per host rather than once per component.

cmd_deps() {
    need_root
    say "installing build dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        build-essential cmake pkg-config python3 curl git ca-certificates \
        libevent-dev libboost-dev libsqlite3-dev libzmq3-dev \
        protobuf-compiler clang jq

    if ! id -u "$FORKNET_USER" >/dev/null 2>&1; then
        say "creating user $FORKNET_USER"
        useradd -m -s /bin/bash "$FORKNET_USER"
    else
        skip "user $FORKNET_USER exists"
    fi
    mkdir -p "$SW_DIR" "$BTC_DATADIR" "$THUNDER_DATADIR" "$ENFORCER_DATADIR"
    chown -R "$FORKNET_USER:$FORKNET_USER" "$HOME_DIR"

    # rustup rather than apt: the enforcer and Thunder both need a toolchain
    # newer than Ubuntu ships, and installing it as the service user keeps the
    # builds reproducible under `sudo -u`.
    if as_user 'command -v cargo' >/dev/null 2>&1; then
        skip "rust present: $(as_user 'rustc --version')"
    else
        say "installing rust toolchain (rustup)"
        as_user "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal"
    fi
    say "deps ok"
}
