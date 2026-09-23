# forknet-bootstrap

Stand up a **BIP300/301 drivechain node — and optionally a mining pool — on a
fresh Ubuntu server**, one reproducible step at a time.

It installs and wires together:

| component | what it is | upstream |
| --- | --- | --- |
| **bitcoind** | the forknet mainchain (a 1:1 Bitcoin fork) | [ecash-com/bitcoin](https://github.com/ecash-com/bitcoin) |
| **bip300301_enforcer** | validates drivechain rules, serves block templates | [LayerTwo-Labs/bip300301_enforcer](https://github.com/LayerTwo-Labs/bip300301_enforcer) |
| **Thunder** | a sidechain (slot 9) — optional for a pool | [LayerTwo-Labs/thunder-rust](https://github.com/LayerTwo-Labs/thunder-rust) |
| **simplepool** | stratum pool + web dashboard — optional | [LayerTwo-Labs/simplepool](https://github.com/LayerTwo-Labs/simplepool) |

Every non-obvious setting carries a comment explaining what breaks without it.
Most of them cost real debugging time on live nodes before they were written
down.

> **No secrets live in this repo.** RPC credentials and wallets are generated
> *on the target server*. Your answers go in `bootstrap.env`, which is
> gitignored.

---

## Requirements

| | |
| --- | --- |
| OS | Ubuntu 24.04 (22.04 works), root or sudo |
| Disk | **~950 GB free** — the chain is a full Bitcoin history. Check this first. |
| RAM | **32 GB recommended.** The enforcer alone plateaus near 18 GB while syncing; add a big swapfile on smaller boxes (see below). |
| CPU | 4+ cores (the Rust builds take 20–40 min on 4, ~10 on 16) |
| Time | ~1–2 h to build, then **~4–5 h** of chain sync on a decent link |

---

## Quick start

```sh
# on your machine
git clone https://github.com/rsantacroce/forknet-bootstrap
scp -r forknet-bootstrap root@YOUR_SERVER:/root/

# on the server
cd /root/forknet-bootstrap
cp bootstrap.env.example bootstrap.env
$EDITOR bootstrap.env                    # pick PROFILE, fill in your own addresses

./forknet-bootstrap.sh config            # show what will be installed — changes nothing
./forknet-bootstrap.sh all               # preflight → deps → bitcoin → enforcer → thunder
./forknet-bootstrap.sh pool              # optional: the mining pool
./forknet-bootstrap.sh verify
forknet status
```

Or go component by component. Each one splits into `build` / `configure` /
`start` / `verify`, so you can stop after a compile or fix a config without
rebuilding:

```sh
./forknet-bootstrap.sh preflight         # OS, disk, RAM, ports
./forknet-bootstrap.sh deps              # apt packages, service user, Rust
./forknet-bootstrap.sh bitcoin           # build → configure → snapshot → start
./forknet-bootstrap.sh enforcer
./forknet-bootstrap.sh thunder           # skip if you only want a pool
./forknet-bootstrap.sh pool

FORCE=1 ./forknet-bootstrap.sh bitcoin configure   # overwrite an existing config
./forknet-bootstrap.sh render /tmp/preview         # write configs without touching the host
```

Order matters: bitcoind → enforcer → thunder → pool. Each step checks that the
one before it is up. `forknet start|stop|status` handles the ordering for day-to-day use.

---

## Networks (profiles)

Pick one with `PROFILE=` in `bootstrap.env`, or `--profile NAME`.

| profile | bitcoin branch | fork height | P2P / RPC | enforcer preset |
| --- | --- | --- | --- | --- |
| **`betanet`** | `betanet-bridge` | 967,680 | 8533 / 8532 | `betanet` |
| `alphanet` | `alphanet-bridge` | 963,648 | 8533 / 8532 | `alphanet` |
| `drynet3` | `drynet3` | 957,600 | 8333 / 8332 | `drynet3` |
| `l2l-forknet` | LayerTwo-Labs `forknet-31` | — | 8333 / 8332 | *(unverified)* |

**These are different networks, not versions of one network.** Their magic
bytes differ (alphanet `eca5a104` vs betanet `eca5b104`), and betanet moved
`OP_DRIVECHAIN` from `OP_NOP5` to `OP_NOP8`. Pair the wrong enforcer preset
with a chain and the node won't error; it just sees an empty drivechain. The
profiles pin compatible versions of all three components together.

Adding a network means adding a file to `profiles/`. Precedence is:
environment → `bootstrap.env` → profile → built-in defaults.

---

## Running a pool

The pool step drives simplepool's own installer non-interactively. **It moves
money, so nothing has a default: it refuses to run until you set your own
addresses.**

The first decision is the **payout mode**, because the payout rail decides what
a miner's stratum username *is*:

| `POOL_MODE` | miners log in with | how they're paid | needs Thunder? |
| --- | --- | --- | --- |
| `solo` | a Bitcoin address | whoever finds the block gets the coinbase | no |
| `pplns-coinbase` | a Bitcoin address | split **directly in the block's coinbase** | no |
| `pps-classic` | a **Thunder** address | scheduled payouts over Thunder | **yes** |

`pplns-coinbase` is the simplest shared pool. It needs no hot wallet, no payout
worker and no sidechain. A minimal config for it:

```sh
PROFILE=betanet
POOL_MODE=pplns-coinbase
POOL_OPERATOR_ADDRESS=bc1q...        # YOUR address — receives the fee
POOL_FEE_BPS=100                     # 1%
POOL_BTC_ADDRESS=                    # must stay EMPTY in this mode
POOL_PAYOUT=0
POOL_UNITS="simplepool simplepool-dashboard"
COINBASE_RECIPIENT=bc1q...           # YOUR address
POOL_HOSTNAME=pool.example.com
POOL_COINBASE_TAG=/yourpool/         # your on-chain signature
```

`bootstrap.env.example` documents every other knob: TLS, extra stratum ports
for rented hashrate (`POOL_LISTENERS`), dashboard branding (`POOL_BRAND`) and
more.

**Upgrade the pool by re-running `./forknet-bootstrap.sh pool install`, never
`simplepoolctl upgrade`.** The upstream installer only knows `solo` and
`pps-classic`. This script re-asserts `pplns-coinbase` after each install,
while `simplepoolctl upgrade` would silently put the pool back on `solo`.

---

## After install — do these

1. **Back up the wallets off the server.** They cannot be regenerated:
   - `/home/forknet/.local/share/bip300301_enforcer/wallet/*/seed.json` (plaintext mnemonic)
   - `/root/forknet-credentials.txt`
   - the Thunder mnemonic, if you set one
2. **Firewall.** Only the bitcoin P2P port (8533 on alpha/betanet) and, if you
   run Thunder, 4009/udp need to be public. Add 3334/tcp (stratum) and 443
   (dashboard) for a pool. RPC, gRPC and the template port stay on localhost.
3. **Stop unattended-upgrades from restarting the stack.** On Ubuntu,
   `needrestart` restarts services on its own after library updates, and that
   includes bitcoind and your pool, unsupervised. Blacklist them:
   ```sh
   cat > /etc/needrestart/conf.d/10-forknet-never-autorestart.conf <<'EOF'
   $nrconf{blacklist_rc} = [
       qr(^bitcoind\.service$), qr(^bip300301-enforcer\.service$), qr(^thunder\.service$),
       qr(^simplepool\.service$), qr(^simplepool-dashboard\.service$), qr(^simplepool-payout\.service$),
   ];
   EOF
   perl -c /etc/needrestart/conf.d/10-forknet-never-autorestart.conf   # a syntax error here breaks apt
   ```
   Security updates still install. Restart the stack yourself, in a window
   you're watching (`needrestart -r l` lists what's pending).
4. **Under 32 GB of RAM? Add swap before syncing:**
   ```sh
   fallocate -l 32G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
   echo '/swapfile none swap sw,pri=10 0 0' >> /etc/fstab && sysctl -w vm.swappiness=10
   ```

---

## Knowing when it's ready

The sync has three finish lines, and only the last one means you can mine:

1. `initialblockdownload=false` — **ignore it.** These forks set a huge
   `maxtipage`, so the flag flips early. Watch `headers - blocks` instead.
2. bitcoind reaches the header tip — the enforcer then runs its own wallet scan.
3. **The enforcer finishes its initial sync.** The template port starts
   answering and the pool comes up within about a minute.

Two stalls you should expect on a fresh node. Both are already mitigated or
simple to fix:

- **Enforcer stuck with `Missing message with zmq sequence`:** bitcoind's ZMQ
  queue overflowed during the sync. The shipped config raises the high-water
  marks. If you still see it, restart bitcoind, then the enforcer.
- **Enforcer at the tip but "still syncing", ~75% of a core, no disk I/O:**
  it's spinning. Run `systemctl restart bip300301-enforcer`. Expect to do this
  once at the end of a fresh sync.

---

## Using an AI coding agent to install it

This repo includes a [`CLAUDE.md`](CLAUDE.md) with step-by-step instructions
for Claude Code or a similar agent: what to ask you, what to run and what to
check. Open the folder in your agent and ask it to *"set up a betanet pool on my
server"*. **Read each command before you approve it:** the scripts run as root.

---

## Layout

```
forknet-bootstrap.sh     entry point: config resolution + command routing
forknet                  stack control wrapper (installed to /usr/local/bin)
profiles/*.env           one file per network — repos, pins, ports, presets
lib/*.sh                 one file per component, plus preflight/deps/common
conf/*.tmpl              bitcoind config + systemd unit templates
bootstrap.env.example    copy to bootstrap.env — your answers for this host
docs/REFERENCE.md        full reference: every trap, snapshots, troubleshooting
```

The full list of traps (config filenames that differ per fork, the template
server flag that fails silently, Thunder's QUIC port and more) is in
**[docs/REFERENCE.md](docs/REFERENCE.md)**. Read it if anything misbehaves.

## Disclaimer

Experimental software for experimental networks. It runs as root, compiles
from source and, in pool mode, handles mining rewards. Review it before you
run it, and never reuse keys or addresses that hold real funds elsewhere.
Provided as-is, without warranty.
