# Instructions for an AI agent installing forknet-bootstrap

You are helping a person stand up a forknet node, and possibly a mining pool,
on a server they control. Read `README.md` first, then `docs/REFERENCE.md` for
the traps. Everything below is operational guidance on top of those files.

## Ground rules

- **The scripts run as root and install system services.** Before each step,
  show the person the command and what it will do, and let them approve it.
- **Never invent, reuse or copy addresses.** Every Bitcoin address in
  `bootstrap.env` (`POOL_OPERATOR_ADDRESS`, `COINBASE_RECIPIENT`, …) must come
  from the person, from a wallet they control. If they don't have one, stop and
  say so.
- **Never print, commit or send wallet material** (`seed.json`, mnemonics,
  `/root/forknet-credentials.txt`). Tell the person where the files are and
  have them copy the files off the server themselves.
- Don't edit files under `/home/forknet/forknet-software/`, and don't hand-edit
  generated configs. Change `bootstrap.env` and re-run the relevant
  `configure` step (with `FORCE=1`) so the setting survives the next run.
- Prefer running on the person's machine and working on the server over SSH.
  Don't install agents, cron jobs or monitoring daemons on the server unless
  they ask for them.

## Step 1 — ask these questions first

1. **SSH access**: host, user (root, or a sudo user such as `ubuntu`), and key.
2. **Network**: `betanet` (the current one) unless they say otherwise.
3. **Node only, or node + pool?**
4. For a pool:
   - payout mode: recommend **`pplns-coinbase`** (no Thunder, no hot wallet).
     Use `pps-classic` only if they will also run Thunder and pay miners in it.
   - their **fee address** and **fee** (`POOL_FEE_BPS`, 100 = 1%)
   - a **domain** pointed at the server, if they want the HTTPS dashboard
   - a **coinbase tag**, e.g. `/theirpool/`
5. Whether to deploy **Thunder** (not needed for a pplns-coinbase pool).

## Step 2 — check the server

```sh
lsb_release -a; nproc; free -g; df -h /; swapon --show
```

- Under ~950 GB free disk: **stop**, the chain will not fit.
- Under 32 GB RAM: add the 32 GB swapfile from the README **before** syncing.
  The enforcer grows to ~18 GB while it syncs, and a small box will hit the OOM killer.
- Keep `DBCACHE_MB` at **4000** or less. More doesn't speed up the sync (it is
  peer-bound) and it fights the enforcer for memory.

## Step 3 — copy the repo and write bootstrap.env

```sh
scp -r forknet-bootstrap USER@HOST:/tmp/ && ssh USER@HOST 'sudo mv /tmp/forknet-bootstrap /root/'
ssh USER@HOST 'sudo cp /root/forknet-bootstrap/bootstrap.env.example /root/forknet-bootstrap/bootstrap.env'
```

Fill in `bootstrap.env` from the person's answers. For a betanet
pplns-coinbase pool, the essentials are:

```sh
PROFILE=betanet
DBCACHE_MB=4000
COINBASE_RECIPIENT=<their address>
POOL_MODE=pplns-coinbase
POOL_OPERATOR_ADDRESS=<their address>
POOL_FEE_BPS=<their fee>
POOL_BTC_ADDRESS=                     # MUST be empty in pplns-coinbase
POOL_THUNDER_ADDRESS=
POOL_PAYOUT=0
POOL_UNITS="simplepool simplepool-dashboard"
POOL_BITCOIND_URL=http://127.0.0.1:8122   # the ENFORCER, never bitcoind
POOL_COINBASE_TAG=/theirpool/
POOL_HOSTNAME=<their domain>
POOL_DATA_DIR=/home/forknet/pool
POOL_TLS=1                            # only once DNS points at the server
POOL_TLS_EMAIL=<their email>
```

Then run `sudo ./forknet-bootstrap.sh config` and go through the output with
the person before installing anything.

## Step 4 — install, in order

```sh
cd /root/forknet-bootstrap
sudo ./forknet-bootstrap.sh preflight
sudo ./forknet-bootstrap.sh deps
sudo ./forknet-bootstrap.sh bitcoin
sudo ./forknet-bootstrap.sh enforcer
sudo ./forknet-bootstrap.sh thunder      # only if they want Thunder
sudo ./forknet-bootstrap.sh pool         # only for a pool
```

The Rust builds are long (20–40 min). Run them in `tmux`/`nohup` or in the
background so a dropped SSH session doesn't kill them.

Then apply the **needrestart blacklist** from the README, and verify it with
`perl -c`. If it is left out, the next unattended upgrade will restart bitcoind
and the pool with nobody watching.

## Step 5 — watch the sync (hours)

Use **block heights** to judge progress, never elapsed time or CPU:

```sh
forknet status
sudo -u forknet /home/forknet/forknet-software/bitcoin/build/bin/bitcoin-cli \
  -datadir=/home/forknet/betanet getblockchaininfo | jq '{blocks,headers}'
journalctl -u bip300301-enforcer -n 30 --no-pager | grep -a -iE 'error|height'
```

- Ignore `initialblockdownload`: it turns false long before the node is
  synced on these forks. Use `headers - blocks`.
- The pool service fails and retries every 60 s until the enforcer can serve
  templates. **That's expected during the sync**, not a fault.
- `Missing message with zmq sequence`, repeating → restart bitcoind, then the
  enforcer.
- Enforcer at the tip but the pool still says "enforcer is still syncing",
  with no disk I/O and no new `include height` log lines → run
  `systemctl restart bip300301-enforcer`. Expect this once at the end.
- An open port 8122 does **not** mean templates work. The error can be inside
  the JSON-RPC response body.

## Step 6 — verify and hand over

```sh
sudo ./forknet-bootstrap.sh verify
sudo ./forknet-bootstrap.sh pool verify
```

- The pool's `pool_mode` in `proxy.conf` must match `bootstrap.env`.
  `/etc/simplepool/install.env` saying `MODE=solo` is **normal** for
  pplns-coinbase.
- On the dashboard, "templates carry sidechain commitments … 1 OP_RETURN" going
  red and green is normal. It reflects sidechain activity, not a
  misconfiguration, as long as the message says `enforcer` and not `bitcoind`.

Finish by telling the person:
1. where their backups are, and that they must copy them off the server:
   `/home/forknet/.local/share/bip300301_enforcer/wallet/*/seed.json`
   and `/root/forknet-credentials.txt`
2. the stratum URL (`stratum+tcp://<domain>:3334`) and that miners log in with
   **their own Bitcoin address** as the username (pplns-coinbase/solo)
3. the dashboard URL and the admin password the installer printed
4. to upgrade the pool **only** with `./forknet-bootstrap.sh pool install`,
   never `simplepoolctl upgrade`.
