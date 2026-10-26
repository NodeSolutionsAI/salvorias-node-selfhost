# Salvorias self-host node installer

Run your own Salvorias check-in node on your own Linux server, for a node
license you hold.

One script, `install.sh`, sets up **one node per server**. It:
- downloads and verifies the node binary;
- creates the node's wallet key on your server;
- waits while you fund the node and register it in the Salvorias app;
- runs the node as a locked-down systemd service, and reports its first
  check-in.

After install, you manage the node with `sudo salvorias-selfhost <command>`.

This is for people comfortable on a Linux command line. If you would rather
not run a server, use Save Hosting in the Salvorias app instead.

## What you need

- A Linux server with **systemd**, and root access (`sudo`).
  - Tested end to end (the full `tests/e2e-lima.sh` suite, in a fresh VM with
    real systemd) on Ubuntu 24.04, Ubuntu 22.04 and Debian 12, each on aarch64
    (arm64). The suite has not been run on x86_64 (amd64) or on other
    distributions or releases. Other systemd distributions get a warning but
    usually work.
  - CPU: x86_64 (amd64) or aarch64 (arm64). The installer picks the matching
    release binary, but only the arm64 path has been run end to end.
  - About 200 MB of memory for the node. Outbound HTTPS (port 443). No
    inbound ports are needed.
- The **public wallet address** that holds your Salvorias node license. It is
  shown in the Salvorias app.
- A **node license** in that wallet. If every license you hold already has a
  node (for example on Save Hosting), you can still install: when you register,
  the app tells you which node this one replaces, and asks you to confirm
  before moving a node off Save Hosting.
- Some **SAVDR**, the network's fee token, in two places:
  - **Your wallet** (the one that holds the license): registering your node is
    a transaction from your wallet, and the chain only accepts transactions
    from wallets that hold some SAVDR. Keep at least 0.01 SAVDR in it.
  - **The node address**: send 1 SAVDR to it. The node pays a tiny fee each
    time it checks in (about 0.00006 SAVDR at today's rates), so 1 SAVDR will
    last a while.

## Safety: what this installer will and will not do

- It **never asks for your private key or seed phrase**. It only needs your
  public wallet address. If you paste something that looks like a private key
  or a recovery phrase, it refuses it and warns you.
- It creates a **new wallet just for the node**. That node key is created on
  your server, stays on your server, and is never printed.
- It **never sends a transaction**. Registering the node is something you do
  yourself in the app, confirmed with your passcode.
- It **verifies every download** against the release's `checksums.txt`, and
  aborts if anything does not match. Every download and RPC request is
  pinned to HTTPS, redirects included, and a node binary must be a Linux
  executable for this server's CPU before it is ever run.
- Root never follows a link the node service could have planted: the data
  directory belongs to root, and every file root touches there must be a
  regular file.
- It refuses to set up a second node on a server that already has one.
- It takes over nothing it cannot show it made. If `/etc/salvorias`,
  `/var/lib/salvorias`, `/opt/salvorias`, `/usr/local/bin/salvorias-node` or
  `/usr/local/sbin/salvorias-selfhost` already exists and was not created by
  this installer, the install stops and names the path. The same goes for an
  existing `salvorias` account. Uninstall deletes only what the installer
  created.

## Install

Download the script, read it if you like, then run it:

```bash
curl --proto '=https' --proto-redir '=https' -fsSLO https://github.com/NodeSolutionsAI/salvorias-node-selfhost/releases/latest/download/install.sh
sudo bash install.sh
```

or in one line:

```bash
curl --proto '=https' --proto-redir '=https' -fsSL https://github.com/NodeSolutionsAI/salvorias-node-selfhost/releases/latest/download/install.sh | sudo bash
```

The default network is **mainnet**. To try it on testnet first, add
`--network testnet`, for example `sudo bash install.sh --network testnet` or
`... | sudo bash -s -- --network testnet`.

### What happens

1. **Checks** the server: root, Linux, systemd, CPU type, and that it can
   reach the Salvorias RPC. It also confirms the RPC is on the right chain.
2. **Downloads** the node binary for your CPU and verifies its checksum.
3. **Asks for your license wallet address** (or takes `--owner 0x...`).
4. **Checks your license on-chain.**
   - If the wallet holds no license, it stops. Nothing has been installed
     yet.
   - If every license already has a node, it carries on. The registration
     step says so, and the app asks you to confirm which node is replaced.
5. **Sets up the server.** It creates:
   - a `salvorias` system user;
   - the directories;
   - the node key;
   - `salvorias-selfhost`, the command you use to manage the node later.
6. **Shows two steps**, funding first:
   - **STEP 1: FUND THE NODE** shows your node address. Send 1 SAVDR to it
     (the node pays a tiny fee for each daily check-in, so 1 SAVDR will last
     a while), and keep a little SAVDR in your wallet (0.01 is plenty) to send
     the registration. An address with no SAVDR cannot check in at all, even
     when fees are zero.
   - **STEP 2: REGISTER THIS NODE IN THE SALVORIAS APP**:

   > Open https://app.salvorias.com/licenses/self-host (or Salvorias app >
   > Licenses > Self Setup), paste the node address from step 1 and confirm
   > with your passcode.

   On testnet the link is https://app.dev.salvorias.com/licenses/self-host.
   You never choose which license the node goes on: the app picks. It uses a
   license with no node first. If there is none, it replaces the node that has
   gone longest without a check-in (2 days or more) and tells you so. If every
   node is active, it warns you and, once you confirm, moves a node off Save
   Hosting to make room. When every license already has a node, the box adds:

   > All your licenses already have a node. When you register, the app tells
   > you which node this replaces, and asks you to confirm before moving a
   > node off Save Hosting.

   With a node that is already registered (a key kept on this server, or one
   you import), only the funding box is shown, and nothing at all once the
   node holds SAVDR.
7. **Waits until the node is both funded and registered** on-chain. It checks
   every 15 seconds, for up to 30 minutes by default (`--wait-minutes N`), and
   prints a line such as `12:06:12  registered: no   funded: yes` when that
   changes (and once a minute otherwise). The service is not started until
   both are done.
   - Ctrl-C is safe. It says which step is still missing; your node key is
     kept, and you continue later with `sudo salvorias-selfhost resume`.
8. **Starts the node** as the `salvorias-node` systemd service, enabled at
   boot. The node checks in right away (`STARTUP_JITTER=0` in `node.env`).
   - If the service cannot be started, the install is not marked finished:
     fix the problem it shows, then run `sudo salvorias-selfhost resume`.
9. **Watches for the first check-in** for up to 2 minutes (each journal
   read is cut off at the time left), then prints one of:
   - `First check-in confirmed (tx 0x…).`, with a link to the transaction on
     savscanner.io (testnet.savscanner.io on testnet);
   - `This node already checked in for the current period; the next check-in
     is automatic.`;
   - `The first check-in failed: <reason>.` The node keeps retrying on its
     own schedule; `sudo salvorias-selfhost status` shows the details. A
     node with no SAVDR shows as "the node has no SAVDR yet; send 1 SAVDR to
     <address>", and one with too little for the fee as "the node's SAVDR
     balance is too low for the fee; send more SAVDR to <address>";
   - `No check-in result yet; run sudo salvorias-selfhost status in a few
     minutes.`

   Then: "It can take up to 30 minutes for your license to show Active in
   the Salvorias app after the first check-in. Check back then."

   Ctrl-C ends this watch only: the node keeps running and the install is
   finished. A failed first check-in is a warning, never an install error.
   A summary follows. It warns if the balance is below what the chain
   requires to accept a check-in.

### Non-interactive install

```bash
sudo bash install.sh --owner 0xYourLicenseWalletAddress --wait-minutes 60
```

## Managing the node

| Command | What it does |
| --- | --- |
| `sudo salvorias-selfhost status` | Service state, version, node address, `Registered:` and `Funded:` (with the balance, and a warning while it is 0), the note on when the license shows Active, last 20 log lines |
| `sudo salvorias-selfhost resume` | Continue an install that was waiting for funding and registration, or whose service did not start |
| `sudo salvorias-selfhost upgrade [--version vX]` | Download and verify a newer node release, switch to it, restart. If the service is not running steadily after 30 seconds, or you press Ctrl-C while it watches, it switches back to the previous version. Also updates `salvorias-selfhost` itself. With the binary already current, it restarts a stopped service, and it brings an install made by an older installer to the current file layout. |
| `sudo salvorias-selfhost upgrade --rollback` | Switch back to the version kept by the last upgrade, restart and watch it. Run it again to go forward. |
| `sudo salvorias-selfhost backup-key [--out PATH]` | Copy the node key to a root-only file (mode 0600) for offline storage. It never prints the key. |
| `sudo salvorias-selfhost uninstall [--yes] [--purge-key]` | Remove the service, binary and config. The node key is **kept** unless you pass `--purge-key` and type the confirmation. `--purge-key` also deletes the `salvorias` user, but only if the installer created it. |
| `sudo journalctl -u salvorias-node -f` | Follow the node's log |

Only one command that changes the server runs at a time. Each takes a lock
(`/run/salvorias-selfhost.lock`); a second one started meanwhile stops with
exit code 4 and changes nothing. `status` only reads, so it runs any time.

After `uninstall`, your license keeps pointing at the node. To move the node
to another server, back up its key here with `backup-key`, then install there
with `--import-key` and that file: no new registration is needed (see
[Moving the node to a new server](#moving-the-node-to-a-new-server)). If you
register a different node instead, the app may replace this node or, if all
your licenses are busy, a Save Hosting node, after asking you.

### Funding

SAVDR is the network's fee token, and it is needed in two places.

- **Your wallet**: registering your node is a transaction from your wallet,
  and the chain only accepts transactions from wallets that hold some SAVDR.
  Keep at least 0.01 SAVDR in it.
- **The node address** (not your license wallet): send 1 SAVDR to it. The node
  pays a tiny fee each time it checks in (about 0.00006 SAVDR at today's
  rates), so 1 SAVDR will last a while.

On Salvorias an address that has never held SAVDR does not exist on chain, so
a node with a zero balance can never check in, even when the network fee is 0.
The installer waits for the node to hold SAVDR before it starts the service.
`status` shows the node balance and warns while it is 0. The node never pays
more than 50 gwei per unit of gas (see Configuration below).

### Back up the node key

Run `sudo salvorias-selfhost backup-key` once the node is running.
1. Copy the file it writes to offline storage you trust, such as an
   encrypted USB drive or a password manager.
2. Delete it from the server with `sudo shred -u <file>`.

Anyone with the key controls the node wallet and the SAVDR on it.

### Moving the node to a new server

1. On the old server:
   - run `sudo salvorias-selfhost backup-key` and copy the file somewhere safe;
   - then run `sudo salvorias-selfhost uninstall --yes`.

   Run the same key on only one server at a time.
2. Copy the backup file to the new server, and make it private with
   `chmod 600 <file>`.
3. On the new server, run:

   ```bash
   sudo bash install.sh --import-key /path/to/backup.txt
   ```

   The installer reads the node address from the key, and you do not need to
   register again: the node is already registered to your wallet. If the
   node still holds SAVDR, it then starts the service; otherwise it asks you
   to fund the node first.
4. Delete the copy you imported (`sudo shred -u <file>`), as the summary
   reminds you.

`--import-key` accepts a file holding exactly one key: 64 hex characters,
with or without `0x`, optionally followed by a newline. It refuses a file
that other users can read, and a symbolic link. The file is read once, into
a root-only copy that everything else works from. If an earlier uninstall
kept a key on this server, importing the same key (in any accepted format)
is fine; a different key is refused.

## Files on the server

| Path | Owner, mode | Contents |
| --- | --- | --- |
| `/opt/salvorias/bin/<version>/salvorias-node` | root, 0755 | Node binaries (the current and previous versions are kept) |
| `/opt/salvorias/bin/current` | symlink | Points at the running version |
| `/opt/salvorias/bin/previous` | symlink | The version `upgrade --rollback` switches to |
| `/usr/local/bin/salvorias-node` | symlink | `-> /opt/salvorias/bin/current/salvorias-node` |
| `/usr/local/sbin/salvorias-selfhost` | root, 0755 | This installer, for later commands |
| `/etc/salvorias/` | root:salvorias, 0750 | Configuration |
| `/etc/salvorias/node.env` | root:salvorias, 0640 | Daemon settings (no secrets) |
| `/etc/salvorias/selfhost.conf` | root:salvorias, 0640 | What the installer set up (network, owner, node address) |
| `/var/lib/salvorias/` | root:salvorias, 0750 | Node data. The service can read it, not change it |
| `/var/lib/salvorias/node-key.txt` | salvorias, 0600 | **The node's private key** |
| `/var/lib/salvorias/node-address.txt` | root, 0644 | The node's public address |
| `/var/lib/salvorias/installer-account.txt` | root, 0600 | Marks the `salvorias` account (by UID) as one this installer created. It stays after an uninstall that keeps the key, so a reinstall can reuse the account |
| `/etc/systemd/system/salvorias-node.service` | root, 0644 | The service |

The service runs as the unprivileged `salvorias` user and is sandboxed:
- `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp` and `NoNewPrivileges`;
- it cannot write anywhere on disk (it logs to the journal), including its
  own key directory;
- memory is capped at 200 MB.

It logs to journald as `salvorias-node`.

### The `salvorias` account and the fixed paths

The installer creates the `salvorias` account itself and reuses it only when
it can show it made that account: the `installer-account.txt` file above names
the account's UID. This is what lets a reinstall after an `uninstall` that
kept the key go on, and it is why `uninstall --purge-key` deletes the account
only when the recorded UID still matches.

A `salvorias` account the installer did not create is refused, even if it
looks like a clean system account: the node key is shared with the account's
group, so the installer will not hand it to an account it does not own. The
message names the account. If nothing else uses it, remove it
(`sudo userdel salvorias`) or rename it (`sudo usermod -l NEWNAME salvorias`
and `sudo groupmod -n NEWNAME salvorias`), then run the installer again.

The same rule covers the five fixed paths in the table above. If one of them
already exists, and neither the installer's state file nor the account marker
shows the installer made it, the install stops before it changes anything and
names the path. Copy anything you need from it, move it aside (`sudo mv <path>
<path>.old`) or remove it, then run the installer again. `uninstall` never
deletes `/etc/salvorias`, `/opt/salvorias` or (with `--purge-key`)
`/var/lib/salvorias` unless the same proof is there, and it never removes a
`/usr/local` entry that is not the installer's own link or file.

## Configuration

`/etc/salvorias/node.env` holds the daemon settings. Restart after editing:
`sudo systemctl restart salvorias-node`.

| Setting | Value |
| --- | --- |
| `CHECKIN_CONTRACT`, `TREASURY_CONTRACT`, `EXPECTED_CHAIN_ID`, `RPC_URL` | Set for the chosen network |
| `NODE_KEYS_FILE` | `/var/lib/salvorias/node-key.txt` |
| `STARTUP_JITTER` | `0`: the first check-in runs as soon as the service starts. The daemon's default random delay (up to 300 seconds) is for spreading out a hosted fleet. |
| `GAS_PRICE_MODE` | `network`. Required: self-hosted node wallets are not fee-exempt. |
| `MAX_GAS_PRICE_GWEI` | `50`. The most the node pays per unit of gas. Raise it if check-ins stall during a long fee spike. |

### Networks

| | mainnet (default) | testnet |
| --- | --- | --- |
| RPC | `https://salvorias.net` | `https://testnet.salvorias.net` |
| Chain ID | 7282 | 7283 |
| NodeCheckIn | `0x88ac542c7B8a2952f704B0ed24CFC17F64527D8D` | `0x51F6122C6014866Bd9443E21b05033b195A1fF27` |
| License NFT | `0xc01E4070A3BBBe79b03bB4b11479C5D39aFE1E87` | `0xa1CF5786c6ceC9E8D0BbACEdF2cc98dAe4614363` |
| Treasury | `0xDEfad8fE8Af1ef0B8d0D00251A80391c9Ed04243` | `0x7e8ecebF965dE86fDE7Ebc7F3020813d656CF723` |
| Explorer | https://savscanner.io | https://testnet.savscanner.io |

`--rpc-url` points the installer and the node at a different RPC endpoint for
the same network. It must be `https://` with a plain host name and path (no
`user@`, quotes, spaces or `%`); plain `http://` is only accepted for exactly
`http://127.0.0.1` or `http://localhost`, with an optional port and path. The installer checks the chain ID before it does anything else.

## All options

```
install (default)  --owner 0x...  --network mainnet|testnet  --rpc-url URL
                   --version vX  --wait-minutes N  --import-key PATH
                   --binary PATH  --self PATH
resume             --wait-minutes N
status
upgrade            --version vX  --binary PATH  --self PATH
upgrade            --rollback
backup-key         --out PATH
uninstall          --yes  --purge-key
-h, --help         --version (installer version, as the only argument)
```

- `--binary PATH` uses a local node binary instead of downloading one. It is
  for offline installs and testing. The binary is **not** checksum-verified;
  the installer prints its sha256 so you can compare it yourself. It must
  still be a Linux executable for this server's CPU.
- `--self PATH` installs that file as `salvorias-selfhost` instead of the
  running script or a release download. It is for offline installs and
  testing.

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `SALVORIAS_RELEASE_BASE_URL` | GitHub Releases (`.../releases/download/<tag>`, or `.../releases/latest/download`) | Where the binaries, `install.sh` and `checksums.txt` are downloaded from |
| `SALVORIAS_WAIT_MINUTES` | 30 | Default for `--wait-minutes` |
| `SALVORIAS_POLL_SECONDS` | 15 | Funding and registration poll interval |
| `SALVORIAS_UPGRADE_WATCH_SECONDS` | 30 | How long `upgrade` watches the new version before keeping it (at least 10) |
| `SALVORIAS_FIRST_CHECKIN_SECONDS` | 120 | How long `install` and `resume` watch for the first check-in's result (0 to 3600; 0 skips the watch) |
| `SALVORIAS_RELEASE_REPO` | `NodeSolutionsAI/salvorias-node-selfhost` | GitHub `owner/name` for release downloads (letters, digits, `.`, `_`, `-`) |

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | OK |
| 1 | Error |
| 2 | Bad usage or input |
| 3 | Stopped: something to do outside the server (no license, not funded or registered yet) |
| 4 | Another `salvorias-selfhost` command is running on this server |
| 130 | Interrupted |

## Troubleshooting

- **"... already exists, and nothing shows that this installer created it"**
  or **"An account named 'salvorias' ... did not create it"**: something on
  this server already uses one of the installer's fixed names. The installer
  stops without changing it. See [The `salvorias` account and the fixed
  paths](#the-salvorias-account-and-the-fixed-paths) for what to do.
- **"holds no Salvorias node license"**: you entered a wallet other than
  the one holding the license. Use the address shown in the app.
- **"All your licenses already have a node"**: not an error. Register the
  node anyway; the app tells you which node it replaces, and asks you to
  confirm before moving a node off Save Hosting. If that node is on Save
  Hosting, your Save Hosting billing does not change by itself: contact
  support to reduce it.
- **The wait timed out**: nothing is lost. The message says what is still
  missing: fund the node (send 1 SAVDR to the node address), register it in
  the app, or both. Then run `sudo salvorias-selfhost resume`.
- **"The first check-in failed"**: the node keeps running and retries on its
  own schedule. Run `sudo salvorias-selfhost status` for the log lines. "The
  node has no SAVDR yet" means the funds have not reached the node address;
  "the node's SAVDR balance is too low for the fee" means it holds some, but
  not enough: send more.
- **The license does not show Active yet**: it can take up to 30 minutes
  after the first check-in. Check back then.
- **The service keeps restarting**: run `sudo salvorias-selfhost status` and
  read the log lines. The node exits if its key is not registered on-chain.
- **"This node will not check in until it holds some SAVDR"**: send 1 SAVDR
  to the node address. A node with a zero balance cannot check in, even when
  the network fee is 0.

## Releases (maintainers)

A release on `NodeSolutionsAI/salvorias-node-selfhost` must contain these
assets:

- `salvorias-node-linux-x64` and `salvorias-node-linux-arm64`, built from
  `node-checkin` with
  `bun build ./cli.js --compile --target=bun-linux-x64|bun-linux-arm64`
  (the installer needs `key-address`, so salvorias-node 0.0.9 or later)
- `install.sh` (this file, unchanged)
- `checksums.txt` in `sha256sum` format, covering **all three files above**:
  `sha256sum salvorias-node-linux-x64 salvorias-node-linux-arm64 install.sh > checksums.txt`

The installer refuses any asset that has no entry in `checksums.txt`, or two
entries that disagree. Both `sha256sum` line forms (`hash  name` and
`hash *name`) and CRLF line endings are accepted.

## Testing

- `tests/shellcheck.sh` lints every script. CI runs the same check.
- `tests/e2e-lima.sh` runs the full end-to-end suite in a disposable Ubuntu
  24.04 VM. See [tests/README.md](tests/README.md).
