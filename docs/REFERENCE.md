# forknet-bootstrap — full reference

Bootstraps **bitcoind + bip300301_enforcer + Thunder + simplepool** on a fresh
Ubuntu host, one component at a time, on whichever forknet you pick.

Two things are configurable that used to be hard-wired:

* **Which network.** A *profile* names the bitcoin fork to build, the config
  filename that fork compiles in, its ports, the enforcer preset and the
  snapshot. `drynet3` is what runs in production; `alphanet` is
  `ecash-com/bitcoin @ alphanet-bridge`; `l2l-forknet` is LayerTwo-Labs'
  `bitcoin-patched`.
* **Which component.** `bitcoin`, `enforcer`, `thunder` and `pool` install
  independently, in that order, and each splits into `build` / `configure` /
  `start` / `verify`. Nothing forces you to do all four in one sitting.

The drynet3 values were derived from the running production node
on 2026-08-04 and are unchanged. Every non-obvious setting
carries a comment explaining what breaks without it — most of them cost real
debugging time to find the first time.

**No secrets in this directory.** The RPC password is generated on the target
host and written to `/root/forknet-credentials.txt` (0600). Nothing is copied
from an existing node: a shared RPC password means one compromised node is all
of them. `bootstrap.env` is gitignored.

---

## What you need

| | |
| --- | --- |
| OS | Ubuntu 24.04 (22.04 works) |
| Disk | **~950 GB free.** The datadir reaches ~878 GB. This is the constraint that bites — check before anything else. |
| RAM | 16 GB+ (`dbcache=2000` alone wants ~2 GB, and the UTXO cache grows well past it) |
| Cores | 4+; the two Rust builds take 20–40 min on 4 cores, ~10 on 16 |
| Time | 1–2 h to a running node, then **hours** of background history sync |

---

## Quick start

```sh
scp -r forknet-bootstrap root@NEW_SERVER:/root/
ssh root@NEW_SERVER
cd /root/forknet-bootstrap

./forknet-bootstrap.sh config          # what am I about to install?
./forknet-bootstrap.sh all             # preflight, deps, then all three node components
```

Or one component at a time, which is the point of this layout:

```sh
./forknet-bootstrap.sh preflight       # OS, disk, RAM, ports
./forknet-bootstrap.sh deps            # apt packages, service user, rust

./forknet-bootstrap.sh bitcoin         # build -> configure -> snapshot -> start
./forknet-bootstrap.sh enforcer        # build -> configure -> start
./forknet-bootstrap.sh thunder         # build -> configure -> start
./forknet-bootstrap.sh pool            # install -> configure -> start   (optional)

./forknet-bootstrap.sh verify
forknet status
```

Every component takes a sub-step, so you can stop after the compile, or fix a
config and reinstall the unit without rebuilding anything:

```sh
./forknet-bootstrap.sh bitcoin build
./forknet-bootstrap.sh enforcer configure
./forknet-bootstrap.sh thunder verify
FORCE=1 ./forknet-bootstrap.sh bitcoin configure     # overwrite an existing config
```

Order still matters — the enforcer needs bitcoind's RPC and ZMQ at startup,
Thunder needs the enforcer's gRPC, and the pool needs the enforcer's block
template server. The steps check and tell you when something upstream is down.

---

## Profiles

```sh
./forknet-bootstrap.sh profiles
./forknet-bootstrap.sh --profile alphanet config
./forknet-bootstrap.sh --profile alphanet bitcoin build
```

or set `PROFILE=alphanet` in `bootstrap.env` once.

| | `drynet3` | `alphanet` | `l2l-forknet` |
| --- | --- | --- | --- |
| bitcoin repo | `ecash-com/bitcoin` | `ecash-com/bitcoin` | `LayerTwo-Labs/bitcoin-patched` |
| branch | `drynet3` | `alphanet-bridge` | `forknet-31` |
| **config filename** | `drivechain-ecash.conf` | `ecash.conf` | `drivechain-forknet.conf` |
| RPC / P2P | 8332 / 8333 | **8532 / 8533** | 8332 / 8333 |
| network magic | `f9beb4d9` | `eca5a104` | `f9beb4d9` |
| fork height | 957,600 | 963,648 | — |
| peers | `addnode` (no DNS seed) | DNS seeds | — |
| enforcer preset | `drynet3` (v0.3.4 pin) | `alphanet` (master) | set it yourself |
| snapshot | published, 9.5 GB | none published | none |
| status | **production** | untested here | **unverified** |

Three things that table is trying to make impossible to get wrong:

**The bitcoind config filename is compiled into the binary and it is different
on every fork.** A config file under any other name is read by nothing, and
bitcoind comes up on stock defaults — which looks like a broken node rather
than a misnamed file. `bitcoin build` greps the binary it just produced for the
profile's filename and warns when they disagree.

**Enforcer presets are not versions of each other, and upstream removes them.**
`drynet3` exists in v0.3.4 and *not* on master, which now carries `drynet4` and
`alphanet` instead. That is why the drynet3 profile pins a commit rather than
tracking a branch, and why `enforcer build` asks the binary whether it knows
the preset before installing a unit that uses it.

**A snapshot only loads at a height the branch has an `m_assumeutxo_data` entry
for.** The published drynet3 file is at 957,600; `alphanet-bridge`'s table
stops at 935,000, so that file is not loadable there — which is why the
alphanet profile ships no snapshot URL rather than the wrong one.

Adding a fourth network is a new file in `profiles/`. Override a single value
without editing a profile by putting it in `bootstrap.env` or the environment:

```sh
BITCOIN_REF=drynet4-bridge BITCOIN_PIN= BTC_CONF_NAME=ecash.conf \
  ./forknet-bootstrap.sh bitcoin build
```

Precedence is environment → `bootstrap.env` → profile → built-in defaults.
`./forknet-bootstrap.sh config` prints the result of all four,
`./forknet-bootstrap.sh render /tmp/x` writes the config and unit files it
would install without touching the host.

---

## What gets installed

```
/home/forknet/
├── forknet-software/
│   ├── bitcoin/                 per profile: ecash-com or LayerTwo-Labs
│   ├── bip300301_enforcer/      LayerTwo-Labs
│   ├── thunder-rust/            LayerTwo-Labs
│   └── simplepool/              LayerTwo-Labs  (only with the pool step)
├── drynet3/                     bitcoind datadir  (~878 GB; named per profile)
│   ├── drivechain-ecash.conf    name comes from the profile — see above
│   └── rpcauth.conf             0600, pulled in via includeconf
├── thunder-data/                named per profile
├── .local/share/bip300301_enforcer/
│   └── <preset>/seed.json       wallet mnemonic, plaintext, 0600
└── utxo-957600.dat              assumeutxo snapshot (deletable after load)

/etc/systemd/system/{bitcoind,bip300301-enforcer,thunder}.service
/etc/systemd/system/simplepool{,-dashboard,-payout}.service    (pool step)
/etc/forknet/env                 resolved profile, read by the wrapper
/usr/local/bin/forknet           stack control wrapper
/root/forknet-credentials.txt    0600 — BACK THIS UP
/root/simplepool-install.sh      the pool installer, kept out of the checkout
```

The three node components are **version-coupled** through the BIP300 gRPC
surface and the forknet magic bytes, so a profile pins them together.
`PIN_VERSIONS=0` tracks branch tips instead; expect to debug the combination
yourself.

### Repository layout

```
forknet-bootstrap.sh     dispatcher: config resolution + command routing
forknet                  stack control wrapper, installed to /usr/local/bin
profiles/*.env           one file per network — repos, branches, ports, presets
lib/common.sh            output, templating, credentials, git, systemd helpers
lib/{preflight,deps}.sh  host-level steps
lib/{bitcoin,enforcer,thunder,pool}.sh   one file per component
conf/*.tmpl              config + unit templates
bootstrap.env.example    copy to bootstrap.env for this host's answers
```

---

## The mining pool

`pool` is the only optional component, and the only one that does not build
anything itself: simplepool ships its own installer, which is authoritative for
how the pool is laid out (build, schema, three systemd units, nginx, TLS). The
step fetches that installer at a known ref and drives it non-interactively with
values derived from the profile, so a pool install lands on the same network as
everything else and can be reproduced.

It moves money, so nothing has a safe default and the step refuses to run until
`bootstrap.env` says:

```sh
POOL_MODE=pps-classic
POOL_OPERATOR_ADDRESS=bc1q...     # takes the fee cut
POOL_FEE_BPS=100                  # 1%
POOL_BTC_ADDRESS=bc1q...          # pps-classic: where the mined reward lands
POOL_THUNDER_ADDRESS=3MA4...      # pps-classic: Thunder reserve
POOL_HOSTNAME=pool.example.com
```

`POOL_BITCOIND_URL` defaults to the **enforcer's** template server
(`http://127.0.0.1:8122`) and the step refuses to install if you point it at
bitcoind — see trap 7. `pool verify` re-reads that setting out of the installed
`proxy.conf` rather than trusting the value it was given.

`POOL_DATA_DIR` moves `shares.db` off the checkout. The installer hard-codes
`$ROOT/data/shares.db`, so this is a symlink plus a `ReadWritePaths` drop-in on
each unit: the systemd sandbox runs `ProtectHome=read-only` and resolves the
symlink, so granting the link is not enough.

Re-running `./forknet-bootstrap.sh pool install` is how the pool is upgraded —
the installer is idempotent and saves its answers to `/etc/simplepool/install.env`.

---

## The traps

These are the things that cost hours the first time. Each is already handled by
the scripts — this section is so you recognise the symptom if you ever deviate.

**1. The bitcoind config filename is per-fork.** `drivechain-ecash.conf` on
drynet3, `ecash.conf` on alphanet-bridge, `drivechain-forknet.conf` on
LayerTwo-Labs' forknet-31. A file under the wrong name is silently ignored and
bitcoind starts with defaults, which looks like a broken node.

**2. `includeconf` is resolved relative to the datadir.** It must be a bare
filename. An absolute path is rejected. (And `-conf` *replaces* the config file
rather than adding to it — a different trap in the same family.)

**3. `rpcauth` and `rpcuser`/`rpcpassword` are mutually exclusive.** Set both
and bitcoind refuses to start.

**4. `maxtipage` must be huge.** Every one of these networks forks mainnet at a
height whose timestamps look ancient to a fresh node. Without it bitcoind
decides it is not synced and refuses to serve `getblocktemplate`.

**5. `txindex=1` before the first sync.** The enforcer needs it. Enabling it
afterwards forces a full reindex.

**6. The enforcer needs the right `--network-preset`.** Otherwise it derives
parameters from the node's reported chain — which is `main`, because these are
*all* mainnet forks — and then disagrees with every peer about magic bytes.
Presets are also removed upstream: `drynet3` is gone from master.

**7. `--enable-block-template-server` is what opens `--serve-rpc-addr`.** Set
the address without the flag and *nothing listens*, with no error logged
anywhere. A pool then silently falls back to plain bitcoind templates, whose
coinbases carry no BIP300/301 commitments — so no sidechain can ever be
merge-mined, and every other view looks healthy while it happens. It also
requires `--enable-mempool`.

**8. Thunder needs `--network forknet`.** The magic bytes are `85 18 95 XX`
where `XX` is `00` regtest, `01` signet, `02` forknet. Run signet against a
forknet peer and it logs `received incorrect magic: 85189501` and never syncs —
which reads like a peering or version problem, not a one-word config error.
Note that `forknet` names the *sidechain* network: two different mainchain
forks both running Thunder on `forknet` share magic and will try to peer with
each other. `THUNDER_NETWORK_MAGIC` separates them.

**9. Thunder P2P is QUIC over UDP.** `ss -tln` lists TCP only and will never
show port 4009. Use `ss -uln`. A node that looks unbound usually isn't.

**10. Start order is bitcoind → enforcer → thunder → pool.** systemd's `Wants=`
propagates stop but does not order start, which is why `forknet start` exists.

**11. Never SIGKILL bitcoind.** A clean shutdown flushes the UTXO cache; a kill
mid-flush costs hours of chainstate rebuild on an 878 GB datadir. The unit sets
`TimeoutStopSec=900` and `SendSIGKILL=no`. In practice shutdown takes a few
seconds.

**12. Build Rust with `--release`.** A debug enforcer cannot keep up with
mempool sync and a debug Thunder misses BMM windows. The scripts always do.

**13. `connect-peer` takes `IP:PORT`, never a hostname**, and returns 0 as soon
as the address is *recorded* — that is not confirmation it connected. Verify
with `list-peers`.

**14. Thunder's CLI is kebab-case.** `get-blockcount`, `list-peers`,
`connect-peer` — not `getblockcount`.

**15. An empty flag is not an absent flag.** `--coinbase-recipient` with
nothing after it stops the enforcer from starting. Optional flags in the unit
templates are whole-line placeholders that get *removed* when unset, because a
blank line inside a backslash-continued `ExecStart=` truncates the command and
systemd starts the daemon with half its arguments.

---

## The assumeutxo snapshot

Without it the node syncs from genesis: days rather than hours. With it you get
a usable chainstate in ~30 min, and history back-fills in the background.

For drynet3 it is downloaded automatically — nothing to configure:

```
https://data.drivechain.dev/drynet3/utxo-957600.dat     9,498,111,432 bytes
```

Verified byte-for-byte against the copy running in production on 2026-08-04:
identical length, and head/middle/tail 1 MiB ranges all hash the same. There is
no published checksum, so the script checks the exact byte count after download
and refuses a truncated file. Downloads resume with `-C -` if the connection
drops.

To copy from a node you already run instead — which is the only option on a
profile with no published snapshot:

```sh
SNAPSHOT_FROM=root@YOUR_OTHER_NODE:/home/forknet/utxo-957600.dat \
  ./forknet-bootstrap.sh bitcoin snapshot
```

The snapshot height must match an `m_assumeutxo_data` entry compiled into the
branch you built; a snapshot from another network is rejected. **bitcoind is
unresponsive for 10–30 min while loading**; that is normal, not a hang. Once
`getblockcount` returns a height above the fork the node is usable even though
background sync continues for hours. The `.dat` is deletable once loaded.

---

## Verifying

```sh
./forknet-bootstrap.sh verify        # every installed component
./forknet-bootstrap.sh enforcer verify   # just one
```

A healthy drynet3 node:

```
    bitcoind                   active
    height                     977816
    chain                      main (ibd=false)

    bip300301-enforcer         active
    gRPC chain tip             977816
    getblocktemplate           listening on 127.0.0.1:8122

    thunder                    active
    height                     4
    p2p (UDP 4009)             bound
    peers                      [{"address":"46.62.185.224:4009","status":"Connected"}]
```

`chain` really does read `main` — these are mainnet forks, and
`ChainType::MAIN` is correct.

---

## Troubleshooting

**bitcoind won't start.** `tail -100 /home/forknet/drynet3/debug.log` — it logs
there, not to the journal. Usual causes: both `rpcauth` and `rpcuser` set, or a
config file under the wrong name for this fork (trap 1). `configure` warns when
it finds another fork's config lying in the datadir.

**Enforcer restarting.** `journalctl -u bip300301-enforcer -n 50 --no-pager | grep -a error`
— the `-a` is required, the log contains binary bytes and grep stops at the
first one without it. Usual cause: bitcoind not up yet, or wrong RPC password.

**Enforcer refuses the preset.** `error: invalid value '<preset>' for
'--network-preset'` means the pinned build predates or postdates it. Check
`--help` on the built binary; `enforcer build` does this for you.

**Port 8122 not listening.** Either `--enable-block-template-server` is missing,
or the initial mempool sync hasn't finished. Confirm with:
```sh
journalctl -u bip300301-enforcer | grep -a 'Listening for JSON-RPC'
```

**Thunder stuck at 0 blocks with a connected peer.** Almost always
`--network`. Check for `received incorrect magic` in the journal. A clean
`thunder-data` plus the right network is the fix; deleting the datadir is safe
as long as you still have the mnemonic.

**Thunder height not advancing.** Expected when nobody is BMM-mining. A
sidechain only advances when a mainchain block commits to it, and those
commitments only exist if the miner used an enforcer template (trap 7).

**Wrong template source.** Blocks with a single OP_RETURN carry only the segwit
commitment — no sidechain commitments:
```sh
bitcoin-cli -datadir=/home/forknet/drynet3 getblock $(bitcoin-cli -datadir=/home/forknet/drynet3 getbestblockhash) 2 \
  | jq -r '.tx[0].vout[] | "\(.value) \(.scriptPubKey.type)"'
```

---

## After bootstrap

1. **Back up `/root/forknet-credentials.txt`** off the machine.
2. **Back up the enforcer wallet mnemonic** —
   `/home/forknet/.local/share/bip300301_enforcer/<preset>/seed.json`,
   plaintext. There can be more than one wallet directory if the preset changed
   between runs; confirm which one holds funds before trusting a backup.
   `verify` lists them.
3. **Firewall.** Only the bitcoin P2P port (8333, or 8533 on alphanet) and
   4009/udp need to be public. The RPC port, 50051 and 8122 are bound to
   localhost by these configs — keep it that way. The pool adds 3334/tcp for
   stratum and 443 for the dashboard.
4. Attaching a pool by hand? Point `bitcoind_url` at the **enforcer**
   (`:8122`), never bitcoind (`:8332`). See trap 7.
