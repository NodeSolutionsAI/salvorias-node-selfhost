# Tests

## shellcheck

```bash
tests/shellcheck.sh
```

This runs `shellcheck -x` on `install.sh` and `tests/*.sh`. CI
(`.github/workflows/shellcheck.yml`) runs the same check on every push.

## End-to-end, in a disposable VM

`install.sh` changes system state: users, `/etc`, `/opt` and systemd units.
So the end-to-end test runs as root inside a throwaway Ubuntu 24.04 VM with
real systemd, using [Lima](https://lima-vm.io).

### 1. Build the two binaries the test needs

From `node-checkin` in `salvorias-distributor`, on the branch under test:

```bash
OUT=/path/to/e2e-bin
mkdir -p "$OUT/next"
# The build under test (pick the VM's architecture: arm64 on Apple Silicon).
bun build ./cli.js --compile --target=bun-linux-arm64 --outfile "$OUT/salvorias-node-linux-arm64"
# A second build that reports a different version, for the upgrade test.
bun build ./cli.js --compile --target=bun-linux-arm64 \
  --define 'process.env.SALVORIAS_NODE_VERSION="0.0.10"' \
  --outfile "$OUT/next/salvorias-node-linux-arm64"
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
  - help and version;
  - a non-root run is refused;
  - unknown and misplaced flags are refused;
  - a private key passed as `--owner` is refused and never echoed;
  - a wrong chain is refused;
  - a plain-http RPC is refused;
  - the **no-license stop**, after which nothing is installed;
  - a **piped run** (`cat install.sh | bash -s --`) that reads its prompts
    from `/dev/tty`: a typed private key and a seed phrase are both rejected,
    then a valid address is accepted;
  - a release download whose checksum verifies;
  - a **tampered release** that is refused.
- **A licensed owner, simulated through `tests/mock-rpc.py`**
  (explained in the next section):
  - a piped install from a local release, which also installs
    `salvorias-selfhost` from the release's verified `install.sh`;
  - the registration wait timing out (exit 3);
  - the one-node guard while the install waits;
  - Ctrl-C during `resume`;
  - `resume` while the owner "registers" the node mid-wait;
  - the running service: active, enabled, no restarts, network gas mode;
  - every file mode and owner, the system user, and the contents of
    `node.env` and the unit file;
  - the one-node guard once installed;
  - `status`, unfunded and funded;
  - `backup-key`;
  - **upgrade rollback** with a binary that passes the version check but
    fails as a daemon;
  - an upgrade with a binary that does not run (refused before switching);
  - an upgrade from a release (checksum verified, `salvorias-selfhost`
    refreshed);
  - an upgrade to the same binary (no-op);
  - `uninstall` without a terminal (refused), and `uninstall --yes`, which
    keeps the key;
  - a reinstall that reuses the kept key;
  - `uninstall --purge-key`, once with a wrong confirmation and once with the
    right one;
  - `install --import-key`: a world-readable file, a two-key file and a junk
    file are each refused, then a bare-hex key is imported and the
    registration wait is skipped because the node is already bound;
  - a final purge, which leaves a clean server.
- **Leak checks:**
  - no transaction was attempted (the mock's log);
  - the node key appears in no captured output and no journal line.

### The mock RPC (test-only)

There is no licensed test wallet, so the post-registration path cannot run
against the chain directly. `tests/mock-rpc.py` is a small JSON-RPC proxy:
- It forwards every call to the real testnet RPC.
- It answers the license count, open slots, node binding and node balance
  for the test's owner wallet itself. The binding appears when the test
  writes the node address to `<state-dir>/bound-node`, which plays the owner
  registering the node in the app.
- It **refuses `eth_sendRawTransaction` and `eth_sendTransaction`**, so
  nothing in the test can send a transaction.

The installer has no test-only code path. The test points it at the mock
with the ordinary `--rpc-url http://127.0.0.1:8545`, since plain http is
allowed for localhost only.

### Test-only and offline overrides used here

| Override | Purpose |
| --- | --- |
| `--binary PATH` | Local node binary instead of a release download |
| `--self PATH` | File to install as `salvorias-selfhost` |
| `SALVORIAS_RELEASE_BASE_URL` | Local `python3 -m http.server` releases, including a tampered one |
| `SALVORIAS_POLL_SECONDS` | Faster registration polling |
| `SALVORIAS_UPGRADE_WATCH_SECONDS` | Upgrade watch window (default 30) |
