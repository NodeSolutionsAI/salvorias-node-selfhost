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
formatting, whole-number validation (no leading zeros such as `08`, which
bash arithmetic reads as invalid octal), the funding text (send 1 SAVDR to the node, the wallet line, no "cost nothing today" or reserve math) and the unfunded warning, the
box order (fund first, then register; the address and wallet line in step 1)
and the missing-step messages, the first check-in parsing (confirmed, already
qualified, failed, the fee-cap skip, and what stays pending), the failure
reasons (a "not EOA" refusal becomes "the node has no SAVDR yet", an
"insufficient funds" one "the node's SAVDR balance is too low for the fee",
ethers' wrapper is cut down to the node's message), the wait's progress lines
(the real wait loop on a fake clock: 25 failed reads with different error
text print 2 lines, not 25), the result lines with the explorer link and the
Active note, and the watch itself, with the real `timeout` and stand-in
systemctl and journalctl executables (it ends on a result; with stand-ins
that hang 30s it still ends within its 1-3s limit plus 2s; it never changes
the exit code; Ctrl-C ends the watch but not the install, also while a
journal read hangs), the `Service:` line of `status` for every `systemctl`
answer (missing unit, disabled, enabled, masked, static, empty) and the node
binary's curl options (progress bar only for a terminal, a stall check instead
of a short time limit), the URL and repo rules, `checksums.txt` parsing (empty file, missing entry,
`*name` entries, CRLF, conflicting entries), the ELF header check, and the
version-name pattern (no `..`, leading dot or dash, or slash), the
`openSlots` reader (a missing or malformed list stops the install; only `[]`
means no free license), the registration rule (the owner named AND a
license entry found, `boundSlot`), and the scrubbed environment the node
binary runs with (a stand-in binary prints what it received). Three more groups:
- `clean_text`, which every RPC error, chain error, binary output and journal
  line goes through before it is printed: control characters dropped, line
  breaks folded, the length capped. The sites are run for real with hostile
  text (`check_rpc`, `query_chain` for its error, its wrong-chain-id message,
  `read_readiness` and `read_binding` for the bound wallet, `show_journal`, the
  check-in outcome); the NFT-contract message is checked in the source.
- Ownership (run as root, so skipped on other users): `refuse_unowned_paths`
  with each of the five fixed paths present and no proof (refused, named,
  untouched), and with the state file or the account marker as proof (marker
  that is a link, has a second hard link, names another UID, or sits in a
  data directory the account owns: no proof). A `salvorias` account without
  its marker is refused by `require_owned_account` and `ensure_user`; with it,
  reused. `ensure_user` on a new account writes the marker itself, before any
  other directory exists, and puts the caller's INT handler back; the next
  install reuses the account. `switch_current` and `install_self_copy` leave a foreign file or
  link in `/usr/local` alone; `prune_versions` and `remove_strays` do not
  delete directories they cannot show are the installer's.
- The real `on_signal` and `undo_upgrade` with a slowed `switch_current`,
  interrupting the switch back: the run must still end on the old version.

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
tests/e2e-lima.sh --reuse-vm /path/to/e2e-bin # run in an existing selfhost-test VM
```

If a VM named `selfhost-test` already exists, the script stops without
touching it: it might be someone's work, and the suite changes system state in
it. `--reuse-vm` runs in it anyway. The script deletes only a VM it created
itself, never one it reused. `VM=name` picks another VM name.

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
  - `--wait-minutes 08`, `SALVORIAS_POLL_SECONDS=08` and
    `SALVORIAS_UPGRADE_WATCH_SECONDS=010` are refused as bad input (exit 2),
    not as a bash arithmetic error;
  - a shell script, and an ELF for another CPU, are refused as `--binary`
    before they run;
  - each of `/etc/salvorias`, `/var/lib/salvorias`, `/opt/salvorias`,
    `/usr/local/bin/salvorias-node` and `/usr/local/sbin/salvorias-selfhost`,
    made beforehand with no state file or marker, is refused by `install`
    with the path named, and is byte-for-byte unchanged afterwards;
    `uninstall` and `uninstall --purge-key` refuse to delete such a directory,
    and leave a foreign `/usr/local` link and file alone;
  - an existing `salvorias` login account is refused, and so are system
    accounts that share access: one with a supplementary group, one whose
    primary GID is not a system GID, and one whose group is another
    account's primary group. A clean system account that the installer did
    not create is refused too (no marker names its UID), with the account
    named and how to remove or rename it. Nothing is written;
  - the **no-license stop**, after which nothing is installed;
  - a **piped run** (`cat install.sh | bash -s --`) that reads its prompts
    from `/dev/tty`: a typed private key and a seed phrase are both rejected,
    then a valid address is accepted. The pty echoes what was typed, so the
    fake key is masked in the step header and the log before they are shown;
  - release downloads: a checksum that verifies, a CRLF `checksums.txt` with
    `*name` entries that verifies, and a tampered binary, an empty
    `checksums.txt` and a missing entry that are each refused.
    No progress bar or meter reaches captured output; run under a
    pseudo-terminal (`script`, stdin a pipe as in `curl | sudo bash`), the bar
    shows and the download is still verified;
- **The testnet contract as deployed** (no `nodeToSlot` getter):
  - `slot-info --node` against https://testnet.salvorias.net itself
    (read-only) succeeds;
  - a full install through a mock that is faithful to that contract: the
    pre-check passes, and the registration is found by the slot scan (the
    slot is checked in slot-info's JSON; the installer never prints it). The
    installer creates the `salvorias` account and writes its marker at install
    time. The kept-key reinstall after a plain uninstall reuses that account.
    Before the purge the test rewrites the state file to say the installer did
    not create the account (an install from before that record existed), and
    `uninstall --purge-key` keeps it (same UID) and says so;
  - the app putting another node on that license (`<state-dir>/replaced-by`):
    `nodeToOwner` still names the owner but no license points at the node.
    `status` says `Registered: NO`, and a reinstall with the kept key does not
    skip the registration: it waits, and finishes once the node is registered
    again. Its first check-in gets an "insufficient funds" refusal from the
    mock, shown as `the node's SAVDR balance is too low for the fee`.
- **No free slot** (a mock answering an empty `findOpenSlots` for two
  licenses): the install does not stop. It reaches the registration wait,
  the box carries the "All your licenses already have a node" notice and the
  testnet portal link, no slot number is printed, and a purge leaves the
  server clean. That install runs with stray node settings in its
  environment (`NFT_CONTRACT`, `CHECKIN_CONTRACT`, `RPC_URL`,
  `NODE_KEYS_FILE`, `SALVORIAS_NODE_VERSION`). Two control runs of the bare
  binary show those settings change its output; the installer's results do
  not change.
- **An install killed right after it created the account** (section 4d): a
  stand-in `install` records whether the account marker exists, then sends
  SIGKILL to the installer as `make_dirs` starts. The marker must already name
  the new account's UID, `/opt/salvorias` and `/etc/salvorias` must not exist
  yet, and the next install must reuse the account (not refuse it) and go on.
- **A licensed owner, simulated through `tests/mock-rpc.py`**
  (explained in the next section):
  - a piped install from a local release, run from a directory holding a
    file named `main` that carries the installer marker. bash names a piped
    script `main`; the test checks that file is not installed, and that
    `salvorias-selfhost` comes from the release's verified `install.sh`;
  - the boxes in order (STEP 1: FUND THE NODE, then STEP 2: REGISTER THIS
    NODE IN THE SALVORIAS APP), and the wait timing out (exit 3), with the
    funding text (1 SAVDR to the node, a little in the wallet). The owner
    funds the node during the wait but never registers it: the progress goes
    from `registered: no   funded: no` to `registered: no   funded: yes`, and
    the timeout names the missing registration. (Section 4c's timeout names
    both; section 4b's checks that an unchanging state prints one line, not
    one per poll.);
  - the one-node guard while the install waits;
  - Ctrl-C during `resume`, which names both missing steps;
  - `resume` while the owner "registers" the node mid-wait and funds it
    later. While it is registered but unfunded, the install keeps waiting,
    with no unit file, no `node.env` and no service. Then the service
    start is forced to fail (a drop-in with `ExecStartPre=/bin/false`): the
    install stays at stage `starting`. Then a daemon that starts and crashes
    3 seconds later, inside the post-start watch (the `broken/` binary run
    through a drop-in): the install still stays at `starting`. A last
    `resume` starts it, and reports the first check-in, which the mock
    refuses: `The first check-in failed: mock-rpc: transactions are disabled
    in this test.`, the retry line and the Active note, with exit 0;
  - the running service: active, enabled, no restarts, network gas mode, and
    `STARTUP_JITTER=0`: this run's journal shows no startup delay and a
    check-in attempt;
  - every file mode and owner, including the root-owned data directory that
    the service user cannot write to, the system user, `node.env`, and a unit
    file with `Type=exec` and no `ReadWritePaths`;
  - **a real check-in attempt**: the installed binary, run once as the
    service user with the service's `node.env` and `STARTUP_JITTER=0`, sends
    a check-in. The mock blocks it and decodes it: an EIP-1559 transaction on
    chain 7283 to NodeCheckIn's `checkIn`, gas limit 100000, with non-zero
    `maxFeePerGas` and `maxPriorityFeePerGas`;
  - the one-node guard once installed;
  - **one changing command at a time**: with the lock
    (`/run/salvorias-selfhost.lock`, 0600 root:root) held by another
    process, `install`, `uninstall --yes`, `resume`, `upgrade`,
    `upgrade --rollback` and `backup-key` each exit 4 and change nothing,
    while `status` still runs. A link at the lock path is refused and its
    target is untouched. During the Ctrl-C upgrade test below, an
    `uninstall --yes` started while the upgrade runs is refused the same way;
  - `status` before the service unit exists, and with the unit disabled: the
    `Service:` entry is one line (`inactive (not installed yet)`, `inactive
    (not enabled at boot)`), with no enabled-state text on a line of its own;
  - `status`, unfunded (`Funded: NO`, the zero-balance warning, no Active
    note) and funded (`Registered: yes`, `Funded: yes (1 SAVDR)`, the Active
    note);
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
    directory. It leaves a root-only marker naming the account the installer
    created (by UID), so the reinstall below still records the account as
    the installer's;
  - the account is made again by hand under the same name with another UID:
    the kept-key reinstall refuses it, and the key stays with the old UID;
  - planted links stop a reinstall, with the decoys untouched;
  - a reinstall that reuses the kept key while the node is registered but
    unfunded: only the funding box, `registered: yes   funded: no` until the
    owner funds it, then a first check-in that the mock refuses as the chain
    does ("the sender is not EOA"), shown as `the node has no SAVDR yet; send
    1 SAVDR to <node>`;
  - `uninstall --purge-key`, once with a wrong confirmation and once with the
    right one, which deletes the account the installer created;
  - `install --import-key`: a world-readable file, a link, a two-key file and
    a junk file are each refused, then a bare-hex key is imported and the
    wait is skipped because the node is already registered and funded. The
    mock takes this run's check-in without forwarding it and serves a
    receipt: `First check-in confirmed (tx 0x…).`, with the tx the mock took
    and its testnet.savscanner.io link;
  - `uninstall` while the service refuses to stop (a `RefuseManualStop=yes`
    drop-in): it fails and removes nothing. Then `uninstall` with the unit
    file deleted while the service is still loaded and running: the service
    is stopped and unloaded, and no boot link is left;
  - with a key kept by an uninstall: a different key is refused, and the
    same key in upper-case hex (different bytes) is accepted by address. The
    mock answers that the node already qualified this period: `This node
    already checked in for the current period; the next check-in is
    automatic.`;
  - a final purge with leftovers of an interrupted run planted (temp copies
    of `salvorias-selfhost` and the unit file, a staging directory), and with
    the account replaced by a hand-made one (another UID), which it keeps. It
    removes the leftovers and leaves a clean server, apart from that account;
    a fresh install then refuses the replacement account, since the purge
    removed the marker.
- **Leak checks:**
  - the installer itself never tried to send a transaction, and no send
    reached the chain (every attempt was refused, or taken without
    forwarding, by a mock);
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
  app. `<state-dir>/replaced-by` plays the app putting another node on that
  license afterwards. `<state-dir>/balance-wei` is the bound node's balance,
  and also that of the address in `<state-dir>/funded-node`, which plays the
  owner funding the node before registering it. `<state-dir>/qualified`
  makes `isNodeQualified` answer true.
- With `--fee-wei` it pins `eth_gasPrice` and `eth_maxPriorityFeePerGas`, so
  the non-zero fee paths run whatever the testnet fee is that day.
- It **never forwards `eth_sendRawTransaction` or `eth_sendTransaction`**,
  so nothing in the test can send a transaction. By default it refuses them
  (with the text of `<state-dir>/send-error` as the error, if that exists).
  A raw transaction is decoded and its type, chain, nonce, fee fields, gas
  limit, target and selector are logged (never the signature). While
  `<state-dir>/accept-sends` exists it answers the transaction's real hash
  instead (Keccak-256, in the mock itself) and serves a successful receipt
  for it, still without forwarding anything, so the daemon logs a confirmed
  check-in.
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
| `SALVORIAS_FIRST_CHECKIN_SECONDS` | First check-in watch (default 120; the unit tests use 0, 3, 30 and 60) |
