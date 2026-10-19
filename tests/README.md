# Tests

## shellcheck

```bash
tests/shellcheck.sh
```

This runs `shellcheck -x` on `install.sh` and `tests/*.sh`. CI
(`.github/workflows/shellcheck.yml`) runs the same check on every push.

## Unit tests

```bash
bash tests/unit-math.sh      # needs bash 4.4+; the e2e suite also runs it in the VM
```

These extract the pure helpers from `install.sh` and test them: wei
formatting, the funding text (reserve wording and the 90-day suggestion), the
URL and repo rules, `checksums.txt` parsing (empty file, missing entry,
`*name` entries, CRLF, conflicting entries), the ELF header check, and the
version-name pattern (no `..`, leading dot or dash, or slash). One more test
runs the real `on_signal` and `undo_upgrade` with a slowed `switch_current`
and interrupts the switch back: the run must still end on the old version.

## End-to-end, in a disposable VM

`install.sh` changes system state: users, `/etc`, `/opt` and systemd units.
So the end-to-end test runs as root inside a throwaway Ubuntu 24.04 VM with
real systemd, using [Lima](https://lima-vm.io).

### 1. Build the three binaries the test needs

From `node-checkin` in `salvorias-distributor`, on the branch under test
(salvorias-node 0.0.9 or later: the installer needs `key-address`):

```bash
OUT=/path/to/e2e-bin
mkdir -p "$OUT/next" "$OUT/broken"
# The build under test (pick the VM's architecture: arm64 on Apple Silicon).
bun build ./cli.js --compile --target=bun-linux-arm64 --outfile "$OUT/salvorias-node-linux-arm64"
# A second build that reports a different version, for the upgrade test.
bun build ./cli.js --compile --target=bun-linux-arm64 \
  --define 'process.env.SALVORIAS_NODE_VERSION="0.0.10"' \
  --outfile "$OUT/next/salvorias-node-linux-arm64"
```

And from this repo, a real executable that passes the version check but fails
as a daemon, for the upgrade-rollback test (the installer refuses anything
that is not an ELF executable for the server's CPU, so a shell script cannot
stand in for it):

```bash
bun build ./tests/broken-node.js --compile --target=bun-linux-arm64 \
  --outfile "$OUT/broken/salvorias-node-linux-arm64"
```

For an x86_64 VM, use `--target=bun-linux-x64` with the file name
`salvorias-node-linux-x64`, and pass `--arch x86_64` in step 2.

### 2. Run

```bash
tests/e2e-lima.sh /path/to/e2e-bin            # creates, tests, deletes the VM
tests/e2e-lima.sh --keep-vm /path/to/e2e-bin  # keep the VM for debugging
```

The transcript goes to `e2e-transcript.txt`. It ends with
`RESULT: N passed, 0 failed`, and the script exits non-zero on any failure.
Delete a kept VM with `limactl delete -f selfhost-test`.

### What it covers

`tests/e2e-in-vm.sh` runs these steps in order. Each step checks exit codes,
messages, files, owners and modes.

- **Testnet, with a random owner wallet that holds no license:**
  - the unit tests, help and version;
  - a non-root run is refused;
  - unknown and misplaced flags are refused;
  - a private key passed as `--owner` is refused and never echoed (checked
    on the raw output; the transcript shows the step with the value masked);
  - a wrong chain is refused;
  - RPC URLs: plain http to a remote host, `http://localhost:1@evil.example/`
    and a URL with a quote are refused;
  - a release repo with a newline or `%` is refused;
  - an upgrade watch under 10 seconds is refused;
  - a shell script, and an ELF for another CPU, are refused as `--binary`
    before they run;
  - an existing `salvorias` login account is refused, and so are system
    accounts that share access: one with a supplementary group, one whose
    primary GID is not a system GID, and one whose group is another
    account's primary group. A clean system account passes. Nothing is
    written;
  - the **no-license stop**, after which nothing is installed;
  - a **piped run** (`cat install.sh | bash -s --`) that reads its prompts
    from `/dev/tty`: a typed private key and a seed phrase are both rejected,
    then a valid address is accepted. The pty echoes what was typed, so the
    fake key is masked in the step header and the log before they are shown;
  - release downloads: a checksum that verifies, a CRLF `checksums.txt` with
    `*name` entries that verifies, and a tampered binary, an empty
    `checksums.txt` and a missing entry that are each refused.
- **The testnet contract as deployed** (no `nodeToSlot` getter):
  - `slot-info --node` against https://testnet.salvorias.net itself
    (read-only) succeeds;
  - a full install through a mock that is faithful to that contract: the
    pre-check passes, and the registration is found by the slot scan.
- **A licensed owner, simulated through `tests/mock-rpc.py`**
  (explained in the next section):
  - a piped install from a local release, run from a directory holding a
    file named `main` that carries the installer marker. bash names a piped
    script `main`; the test checks that file is not installed, and that
    `salvorias-selfhost` comes from the release's verified `install.sh`;
  - the registration wait timing out (exit 3), with the reserve funding text;
  - the one-node guard while the install waits;
  - Ctrl-C during `resume`;
  - `resume` while the owner "registers" the node mid-wait, with the service
    start forced to fail (a drop-in with `ExecStartPre=/bin/false`): the
    install stays at stage `starting`. Then a daemon that starts and crashes
    3 seconds later, inside the post-start watch (the `broken/` binary run
    through a drop-in): the install still stays at `starting`. A last
    `resume` starts it;
  - the running service: active, enabled, no restarts, network gas mode;
  - every file mode and owner, including the root-owned data directory that
    the service user cannot write to, the system user, `node.env`, and a unit
    file with `Type=exec` and no `ReadWritePaths`;
  - **a real check-in attempt**: the installed binary, run once as the
    service user with the service's `node.env` and `STARTUP_JITTER=0`, sends
    a check-in. The mock blocks it and decodes it: an EIP-1559 transaction on
    chain 7283 to NodeCheckIn's `checkIn`, gas limit 100000, with non-zero
    `maxFeePerGas` and `maxPriorityFeePerGas`;
  - the one-node guard once installed;
  - `status`, unfunded and funded;
  - `backup-key`: to a fresh path in a new root-only directory (0600
    root:root, no temp file left), and refused into a symlinked directory,
    a directory another user owns and a world-writable one;
  - **planted links**: `node-key.txt`, then `node-address.txt`, replaced by a
    link to a decoy file. `backup-key` and `uninstall --purge-key` each
    refuse, and the decoys keep their owner, mode, size, link count and hash.
    A second hard link to the key is refused too, with the `find -samefile`
    hint;
  - **upgrade rollback** with a binary that passes the version check but
    fails as a daemon (and no "unit file changed on disk" warning: an
    unchanged unit file is not rewritten);
  - an upgrade with random bytes, and with an ELF for another CPU (both
    refused before they run);
  - Ctrl-C during the upgrade watch, which switches back;
  - an upgrade from a release (checksum verified, `salvorias-selfhost`
    refreshed); the same binary (no-op); the same binary with the service
    stopped (restarted, not "nothing to do"); `upgrade --rollback`;
  - **migration from the old layout** (salvorias-owned 0700 data directory,
    `ReadWritePaths` in the unit): refused while a planted link is in the
    directory, then migrated by `upgrade`;
  - `uninstall` without a terminal (refused), and `uninstall --yes`, which
    keeps the key and removes a staging directory left in the data
    directory;
  - planted links stop a reinstall, with the decoys untouched;
  - a reinstall that reuses the kept key;
  - `uninstall --purge-key`, once with a wrong confirmation and once with the
    right one;
  - `install --import-key`: a world-readable file, a link, a two-key file and
    a junk file are each refused, then a bare-hex key is imported and the
    registration wait is skipped because the node is already bound;
  - `uninstall` while the service refuses to stop (a `RefuseManualStop=yes`
    drop-in): it fails and removes nothing. Then `uninstall` with the unit
    file deleted while the service is still loaded and running: the service
    is stopped and unloaded, and no boot link is left;
  - with a key kept by an uninstall: a different key is refused, and the
    same key in upper-case hex (different bytes) is accepted by address;
  - a final purge with leftovers of an interrupted run planted (temp copies
    of `salvorias-selfhost` and the unit file, a staging directory), which
    removes them and leaves a clean server.
- **Leak checks:**
  - the installer itself never tried to send a transaction, and no send
    reached the chain (every attempt was refused by a mock);
  - no node key appears in any captured output or journal line, and the
    fake typed key appears in no captured log;
  - no "unit file changed on disk" warning appears in any captured output.

### The mock RPC (test-only)

There is no licensed test wallet, so the post-registration path cannot run
against the chain directly. `tests/mock-rpc.py` is a small JSON-RPC proxy:
- It forwards every call to the real testnet RPC.
- It answers the license count, open slots, node binding (`nodeToOwner`, and
  the `nodeAddressOf` slot scan) and node balance for the test's owner wallet
  itself. The binding appears when the test writes the node address to
  `<state-dir>/bound-node`, which plays the owner registering the node in the
  app.
- With `--fee-wei` it pins `eth_gasPrice` and `eth_maxPriorityFeePerGas`, so
  the non-zero fee paths run whatever the testnet fee is that day.
- It **refuses `eth_sendRawTransaction` and `eth_sendTransaction`**, so
  nothing in the test can send a transaction. A refused raw transaction is
  decoded and its type, chain, nonce, fee fields, gas limit, target and
  selector are logged (never the signature).
- With `--emulate-node-to-slot` it also answers `nodeToSlot`.
  - The mainnet NodeCheckIn implementation has that getter. The testnet
    deployment (`0x51F6…1fF27`) does not; there salvorias-node 0.0.9+ finds
    the slot by scanning `nodeAddressOf` instead.
  - The main scenarios use the flag, so the installer's flow runs the way it
    does on mainnet. A second mock, without the flag, is faithful to the
    testnet contract as deployed.

The installer has no test-only code path. The test points it at the mock
with the ordinary `--rpc-url http://127.0.0.1:8545`, since plain http is
allowed for `http://127.0.0.1` and `http://localhost` only. The check-in
attempt runs the installed binary directly instead of through the installer.

### Test-only and offline overrides used here

| Override | Purpose |
| --- | --- |
| `--binary PATH` | Local node binary instead of a release download |
| `--self PATH` | File to install as `salvorias-selfhost` |
| `SALVORIAS_RELEASE_BASE_URL` | Local `python3 -m http.server` releases, including tampered and malformed ones |
| `SALVORIAS_POLL_SECONDS` | Faster registration polling |
| `SALVORIAS_UPGRADE_WATCH_SECONDS` | Upgrade watch window (default 30, minimum 10) |
