# Salvorias self-host node installer

Run your own Salvorias check-in node on your own Linux server, for a node
license you hold.

One script, `install.sh`, sets up **one node per server**. It:
- downloads and verifies the node binary;
- creates the node's wallet key on your server;
- waits while you register the node in the Salvorias app;
- runs the node as a locked-down systemd service.

After install, you manage the node with `sudo salvorias-selfhost <command>`.

This is for people comfortable on a Linux command line. If you would rather
not run a server, use Save Hosting in the Salvorias app instead.

## What you need

- A Linux server with **systemd**, and root access (`sudo`).
  - Tested on Ubuntu 22.04 and newer, and Debian 12 and newer. Other systemd
    distributions get a warning but usually work.
  - CPU: x86_64 (amd64) or aarch64 (arm64).
  - About 200 MB of memory for the node. Outbound HTTPS (port 443). No
    inbound ports are needed.
- The **public wallet address** that holds your Salvorias node license. It is
  shown in the Salvorias app.
- A **free license slot**: one with no node assigned (not used by Save Hosting).
- Some **SAVDR to send to the node**. A self-hosted node pays the network fee
  for its own daily check-in.

## Safety: what this installer will and will not do

- It **never asks for your private key or seed phrase**. It only needs your
  public wallet address. If you paste something that looks like a private key
  or a recovery phrase, it refuses it and warns you.
- It creates a **new wallet just for the node**. That node key is created on
  your server, stays on your server, and is never printed.
- It **never sends a transaction**. Registering the node is something you do
  yourself in the app, confirmed with your passcode.
- It **verifies every download** against the release's `checksums.txt`, and
  aborts if anything does not match.
- It refuses to set up a second node on a server that already has one.

## Install

Download the script, read it if you like, then run it:

```bash
curl -fsSLO https://github.com/NodeSolutionsAI/salvorias-node-selfhost/releases/latest/download/install.sh
sudo bash install.sh
```

or in one line:

```bash
curl -fsSL https://github.com/NodeSolutionsAI/salvorias-node-selfhost/releases/latest/download/install.sh | sudo bash
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
   - If the wallet holds no license, it stops.
   - If every slot is already in use, it stops: self-hosting only takes a
     free slot.
   - In both cases nothing has been installed yet.
5. **Sets up the server.** It creates:
   - a `salvorias` system user;
   - the directories;
   - the node key;
   - `salvorias-selfhost`, the command you use to manage the node later.
6. **Shows the registration box** with your node address and your free slots:

   > Open the Salvorias app > Licenses > Self Setup, paste this node address,
   > choose a free slot, confirm with your passcode.

   It also tells you how much SAVDR to send to the node address. That is the
   cost of one check-in at today's fee, plus a suggested amount for about 90
   days of daily check-ins.
7. **Waits for the registration** to appear on-chain. It checks every 15
   seconds, for up to 30 minutes by default (`--wait-minutes N`).
   - Ctrl-C is safe. Your node key is kept, and you continue later with
     `sudo salvorias-selfhost resume`.
8. **Starts the node** as the `salvorias-node` systemd service, enabled at
   boot, then prints a summary.
   - If the node has less SAVDR than one check-in costs, it warns you.

### Non-interactive install

```bash
sudo bash install.sh --owner 0xYourLicenseWalletAddress --wait-minutes 60
```

## Managing the node

| Command | What it does |
| --- | --- |
| `sudo salvorias-selfhost status` | Service state, version, node address, slot binding, balance, approximate check-ins left, last 20 log lines |
| `sudo salvorias-selfhost resume` | Continue an install that was waiting for registration |
| `sudo salvorias-selfhost upgrade [--version vX]` | Download and verify a newer node release, switch to it, restart. If the service is not running steadily after 30 seconds, it switches back to the previous version. Also updates `salvorias-selfhost` itself. |
| `sudo salvorias-selfhost backup-key [--out PATH]` | Copy the node key to a root-only file (mode 0600) for offline storage. It never prints the key. |
| `sudo salvorias-selfhost uninstall [--yes] [--purge-key]` | Remove the service, binary and config. The node key is **kept** unless you pass `--purge-key` and type the confirmation. |
| `sudo journalctl -u salvorias-node -f` | Follow the node's log |

After `uninstall`, your license slot still points at the node on-chain. To
use that slot for something else (for example Save Hosting), clear it in the
Salvorias app under Licenses.

### Funding

The node wallet pays the network fee for each check-in, so keep SAVDR on the
**node address** (not your license wallet). `status` shows the balance and
roughly how many check-ins it covers. The node never pays more than 50 gwei
per unit of gas (see Configuration below).

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
   register again: the node is already registered to your wallet. It then
   starts the service.
4. Delete the copy you imported (`sudo shred -u <file>`), as the summary
   reminds you.

`--import-key` accepts a file holding exactly one key: 64 hex characters,
with or without `0x`, optionally followed by a newline. It refuses a file
that other users can read.

## Files on the server

| Path | Owner, mode | Contents |
| --- | --- | --- |
| `/opt/salvorias/bin/<version>/salvorias-node` | root, 0755 | Node binaries (the current and previous versions are kept) |
| `/opt/salvorias/bin/current` | symlink | Points at the running version |
| `/usr/local/bin/salvorias-node` | symlink | `-> /opt/salvorias/bin/current/salvorias-node` |
| `/usr/local/sbin/salvorias-selfhost` | root, 0755 | This installer, for later commands |
| `/etc/salvorias/` | root:salvorias, 0750 | Configuration |
| `/etc/salvorias/node.env` | root:salvorias, 0640 | Daemon settings (no secrets) |
| `/etc/salvorias/selfhost.conf` | root:salvorias, 0640 | What the installer set up (network, owner, node address) |
| `/var/lib/salvorias/` | salvorias, 0700 | Node data |
| `/var/lib/salvorias/node-key.txt` | salvorias, 0600 | **The node's private key** |
| `/etc/systemd/system/salvorias-node.service` | root, 0644 | The service |

The service runs as the unprivileged `salvorias` user and is sandboxed:
- `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp` and `NoNewPrivileges`;
- it can only write to `/var/lib/salvorias`;
- memory is capped at 200 MB.

It logs to journald as `salvorias-node`.

## Configuration

`/etc/salvorias/node.env` holds the daemon settings. Restart after editing:
`sudo systemctl restart salvorias-node`.

| Setting | Value |
| --- | --- |
| `CHECKIN_CONTRACT`, `TREASURY_CONTRACT`, `EXPECTED_CHAIN_ID`, `RPC_URL` | Set for the chosen network |
| `NODE_KEYS_FILE` | `/var/lib/salvorias/node-key.txt` |
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

`--rpc-url` points the installer and the node at a different RPC endpoint for
the same network. It must be `https://`; plain `http://` is only accepted for
localhost. The installer checks the chain ID before it does anything else.

## All options

```
install (default)  --owner 0x...  --network mainnet|testnet  --rpc-url URL
                   --version vX  --wait-minutes N  --import-key PATH
                   --binary PATH  --self PATH
resume             --wait-minutes N
status
upgrade            --version vX  --binary PATH  --self PATH
backup-key         --out PATH
uninstall          --yes  --purge-key
-h, --help         --version (installer version, as the only argument)
```

- `--binary PATH` uses a local node binary instead of downloading one. It is
  for offline installs and testing. The binary is **not** checksum-verified;
  the installer prints its sha256 so you can compare it yourself.
- `--self PATH` installs that file as `salvorias-selfhost` instead of the
  running script or a release download. It is for offline installs and
  testing.

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `SALVORIAS_RELEASE_BASE_URL` | GitHub Releases (`.../releases/download/<tag>`, or `.../releases/latest/download`) | Where the binaries, `install.sh` and `checksums.txt` are downloaded from |
| `SALVORIAS_WAIT_MINUTES` | 30 | Default for `--wait-minutes` |
| `SALVORIAS_POLL_SECONDS` | 15 | Registration poll interval |
| `SALVORIAS_UPGRADE_WATCH_SECONDS` | 30 | How long `upgrade` watches the new version before keeping it |

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | OK |
| 1 | Error |
| 2 | Bad usage or input |
| 3 | Stopped: something to do outside the server (no license, no free slot, not registered yet) |
| 130 | Interrupted |

## Troubleshooting

- **"holds no Salvorias node license"**: you entered a wallet other than
  the one holding the license. Use the address shown in the app.
- **"All license slot(s) ... are already in use"**: every slot already has
  a node (for example Save Hosting). Free one in the app under Licenses, then
  run the installer again.
- **The registration wait timed out**: nothing is lost. Register the node in
  the app, then run `sudo salvorias-selfhost resume`.
- **The service keeps restarting**: run `sudo salvorias-selfhost status` and
  read the log lines. The node exits if its key is not registered on-chain.
- **Low balance warning**: send SAVDR to the node address.

## Releases (maintainers)

A release on `NodeSolutionsAI/salvorias-node-selfhost` must contain these
assets:

- `salvorias-node-linux-x64` and `salvorias-node-linux-arm64`, built from
  `node-checkin` with
  `bun build ./cli.js --compile --target=bun-linux-x64|bun-linux-arm64`
- `install.sh` (this file, unchanged)
- `checksums.txt` in `sha256sum` format, covering **all three files above**:
  `sha256sum salvorias-node-linux-x64 salvorias-node-linux-arm64 install.sh > checksums.txt`

The installer refuses any asset that has no entry in `checksums.txt`.

## Testing

- `tests/shellcheck.sh` lints every script. CI runs the same check.
- `tests/e2e-lima.sh` runs the full end-to-end suite in a disposable Ubuntu
  24.04 VM. See [tests/README.md](tests/README.md).
