#!/usr/bin/env bash
# End-to-end test of install.sh, run as root INSIDE a disposable Ubuntu VM
# with systemd. Driven from the host by tests/e2e-lima.sh; see tests/README.md.
#
# It changes the VM's system state (users, /etc, /opt, systemd units), so
# never run it on a real server.
#
# Layout it expects under E2E_DIR (default: the parent of this script):
#   install.sh
#   tests/mock-rpc.py
#   bin/salvorias-node-linux-<arch>        current release binary
#   bin/next/salvorias-node-linux-<arch>   a newer build (reports another version)
#
# What it needs from outside: HTTPS to https://testnet.salvorias.net.
# It sends no transactions: the "licensed" scenarios go through
# tests/mock-rpc.py, which refuses every transaction-sending method.

set -euo pipefail

E2E_DIR="${E2E_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TESTNET_RPC="${TESTNET_RPC:-https://testnet.salvorias.net}"
TESTNET_CHECKIN="0x51F6122C6014866Bd9443E21b05033b195A1fF27"
TESTNET_NFT="0xa1CF5786c6ceC9E8D0BbACEdF2cc98dAe4614363"

INSTALL="$E2E_DIR/install.sh"
SELF="/usr/local/sbin/salvorias-selfhost"
case "$(uname -m)" in
  x86_64) ARCH="linux-x64" ;;
  aarch64) ARCH="linux-arm64" ;;
  *) echo "unsupported arch" >&2; exit 1 ;;
esac
BIN="$E2E_DIR/bin/salvorias-node-$ARCH"
BIN_NEXT="$E2E_DIR/bin/next/salvorias-node-$ARCH"

WORK="$(mktemp -d /root/selfhost-e2e.XXXXXX)"
OUT="$WORK/logs"
MOCK_STATE="$WORK/mock"
MOCK_RPC="http://127.0.0.1:8545"
mkdir -p "$OUT" "$MOCK_STATE"

PASS=0
FAIL=0
RC=0
PIDS=()
STEP=0

[[ "$(id -u)" -eq 0 ]] || { echo "run as root inside the test VM" >&2; exit 1; }
[[ -f "$BIN" && -f "$BIN_NEXT" ]] || { echo "missing $BIN or $BIN_NEXT" >&2; exit 1; }
chmod 0755 "$BIN" "$BIN_NEXT"

cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

section() { printf '\n\n######## %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; }

# run NAME CMD...: runs CMD, keeps its output in $OUT/NAME.log, shows it, sets RC.
run() {
  local name="$1"
  shift
  STEP=$((STEP + 1))
  printf '\n--- [%02d] $ %s\n' "$STEP" "$*"
  set +e
  "$@" >"$OUT/$name.log" 2>&1
  RC=$?
  set -e
  sed 's/^/    | /' "$OUT/$name.log"
  printf '    (exit %s)\n' "$RC"
}

expect_rc() { if [[ "$RC" == "$1" ]]; then pass "$2 (exit $RC)"; else fail "$2 (expected exit $1, got $RC)"; fi; }
expect_log() { if grep -qE -- "$2" "$OUT/$1.log"; then pass "$3"; else fail "$3 (no /$2/ in $1.log)"; fi; }
expect_no_log() { if grep -qE -- "$2" "$OUT/$1.log"; then fail "$3 (found /$2/ in $1.log)"; else pass "$3"; fi; }
expect_true() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
expect_stat() {
  local got
  got=$(stat -c '%a %U:%G' "$1" 2>/dev/null || echo missing)
  if [[ "$got" == "$2" ]]; then pass "$1 is $2"; else fail "$1 is '$got', expected '$2'"; fi
}
nothing_installed() {
  [[ ! -e /etc/salvorias && ! -e /opt/salvorias && ! -e /var/lib/salvorias && ! -e "$SELF" \
    && ! -e /etc/systemd/system/salvorias-node.service ]] && ! id -u salvorias >/dev/null 2>&1
}
service_user_ok() {
  [[ "$(getent passwd salvorias | cut -d: -f6,7)" == "/nonexistent:/usr/sbin/nologin" && "$(id -u salvorias)" -lt 1000 ]]
}
# Checks the key file's shape without printing it.
key_file_ok() {
  [[ "$(grep -cE '^0x[0-9a-f]{64}$' /var/lib/salvorias/node-key.txt)" == 1 && "$(wc -l </var/lib/salvorias/node-key.txt)" == 1 ]]
}
# Feeds lines to the installer's /dev/tty prompts through a pseudo-terminal.
with_tty() {
  local input="$1"
  shift
  printf '%s' "$input" | script -qec "$*" /dev/null
}
# Starts a command in its own process group with default SIGINT handling, so
# `kill -INT -- -PID` reaches it the way Ctrl-C does: as a signal to the whole
# foreground group (the installer and whatever it is running). Background jobs
# of a non-interactive shell otherwise start with SIGINT ignored, which a trap
# cannot undo. `exec` matters: backgrounding a function forks a subshell, and
# without it $! would name that subshell instead of the installer's group.
spawn_sigint_able() {
  exec python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.setpgid(0, 0); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
}

OWNER="0x$(openssl rand -hex 20)"
FAKE_SECRET="$(openssl rand -hex 32)"   # random, never used as a key anywhere
SEED_WORDS="abandon ability able about above absent absorb abstract absurd abuse access accident"
echo "E2E work dir: $WORK"
echo "Test owner (random, holds no license on testnet): $OWNER"
"$BIN" version
"$BIN_NEXT" version

# ─── Local release servers ────────────────────────────────────────────────
# 8000: good release with the current binary; 8001: the next binary plus a
# marked install.sh (to prove upgrade refreshes salvorias-selfhost);
# 8002: a release whose checksum does not match.
make_release() {
  local dir="$1" bin="$2"
  mkdir -p "$dir"
  cp "$bin" "$dir/salvorias-node-$ARCH"
  cp "$INSTALL" "$dir/install.sh"
  (cd "$dir" && sha256sum "salvorias-node-$ARCH" install.sh >checksums.txt)
}
make_release "$WORK/rel-good" "$BIN"
make_release "$WORK/rel-next" "$BIN_NEXT"
printf '# e2e: refreshed copy marker\n' >>"$WORK/rel-next/install.sh"
(cd "$WORK/rel-next" && sha256sum "salvorias-node-$ARCH" install.sh >checksums.txt)
make_release "$WORK/rel-bad" "$BIN"
printf 'tampered' >>"$WORK/rel-bad/salvorias-node-$ARCH"
for spec in 8000:rel-good 8001:rel-next 8002:rel-bad; do
  python3 -m http.server "${spec%%:*}" --bind 127.0.0.1 --directory "$WORK/${spec#*:}" >/dev/null 2>&1 &
  PIDS+=($!)
done

python3 "$E2E_DIR/tests/mock-rpc.py" --listen 127.0.0.1:8545 --upstream "$TESTNET_RPC" \
  --checkin "$TESTNET_CHECKIN" --nft "$TESTNET_NFT" --owner "$OWNER" \
  --licenses 2 --open-slots 0,1 --bound-slot 1 --state-dir "$MOCK_STATE" --emulate-node-to-slot &
PIDS+=($!)
# Same licensed owner, but faithful to the testnet contract (no nodeToSlot).
python3 "$E2E_DIR/tests/mock-rpc.py" --listen 127.0.0.1:8549 --upstream "$TESTNET_RPC" \
  --checkin "$TESTNET_CHECKIN" --nft "$TESTNET_NFT" --owner "$OWNER" \
  --licenses 2 --open-slots 0,1 --bound-slot 1 --state-dir "$WORK/mock-faithful" &
PIDS+=($!)
sleep 2

# ─── 1. Usage, preflight and input checks (real testnet) ──────────────────

section "0. unit tests for the wei and funding helpers"
run unit bash "$E2E_DIR/tests/unit-math.sh"
expect_rc 0 "tests/unit-math.sh"

section "1. usage and input validation"
run help bash "$INSTALL" --help
expect_rc 0 "--help"
run version bash "$INSTALL" --version
expect_rc 0 "--version"
expect_log version 'installer v[0-9]' "--version prints the installer version"
run not-root runuser -u nobody -- bash "$INSTALL" --network testnet
expect_rc 1 "non-root run is refused"
expect_log not-root 'Rerun it with sudo' "non-root message says to use sudo"
run bad-flag bash "$INSTALL" --frobnicate
expect_rc 2 "unknown flag"
run wrong-cmd-flag bash "$INSTALL" status --owner "$OWNER"
expect_rc 2 "flag that does not apply to the command"
run privkey-flag bash "$INSTALL" --network testnet --binary "$BIN" --owner "0x$FAKE_SECRET"
expect_rc 2 "a private key passed as --owner is rejected"
expect_log privkey-flag 'looks like a PRIVATE KEY' "private-key warning shown"
expect_no_log privkey-flag "$FAKE_SECRET" "the rejected secret is not echoed back"
run wrong-chain bash "$INSTALL" --network mainnet --rpc-url "$TESTNET_RPC" --binary "$BIN" --owner "$OWNER"
expect_rc 1 "mainnet with a testnet RPC is refused"
expect_log wrong-chain 'is chain 7283, but mainnet is chain 7282' "chain id mismatch explained"
run http-rpc bash "$INSTALL" --network testnet --rpc-url http://example.com --binary "$BIN" --owner "$OWNER"
expect_rc 2 "plain-http non-local RPC is refused"

section "2. no license: stop before installing anything (real testnet, random owner)"
run no-license bash "$INSTALL" --network testnet --binary "$BIN" --owner "$OWNER"
expect_rc 3 "random owner stops with exit 3"
expect_log no-license 'holds no Salvorias node license on testnet' "no-license message"
expect_true "nothing installed after the no-license stop" nothing_installed

section "3. interactive prompt while piped (curl | sudo bash), secrets rejected"
run prompt-piped with_tty "0x$FAKE_SECRET
$SEED_WORDS
$OWNER
" "cat $INSTALL | bash -s -- --network testnet --binary $BIN"
# The pty echoes what was typed; mask that echo so the transcript stays clean.
sed -i "s/$FAKE_SECRET/<typed-fake-key-echo>/g" "$OUT/prompt-piped.log"
expect_rc 3 "piped run with prompts reaches the no-license stop"
expect_log prompt-piped 'looks like a PRIVATE KEY' "typed private key rejected"
expect_log prompt-piped 'SEED / RECOVERY PHRASE' "typed seed phrase rejected"
expect_log prompt-piped 'holds no Salvorias node license' "valid address accepted after rejections"
expect_true "nothing installed after the piped run" nothing_installed

section "4. release download path: checksum verified / mismatch aborts"
run download-ok env SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8000 bash "$INSTALL" --network testnet --owner "$OWNER"
expect_rc 3 "downloaded binary verified, then no-license stop"
expect_log download-ok 'Checksum verified: salvorias-node-' "checksum verified message"
run download-bad env SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8002 bash "$INSTALL" --network testnet --owner "$OWNER"
expect_rc 1 "tampered binary is refused"
expect_log download-bad 'Checksum mismatch' "mismatch message"
expect_true "nothing installed after the mismatch" nothing_installed

# ─── 5. Licensed owner via the mock RPC ───────────────────────────────────

section "4b. licensed owner on the real testnet contract (no nodeToSlot getter): clean stop"
run testnet-contract bash "$INSTALL" --network testnet --rpc-url http://127.0.0.1:8549 --binary "$BIN" --owner "$OWNER"
expect_rc 1 "stops when slot-info --node cannot be read"
expect_log testnet-contract 'Could not read node registration data' "explains what failed"
expect_true "nothing installed (stopped before keygen)" nothing_installed

section "5. piped install from the release, registration wait times out (mock RPC)"
run piped-timeout bash -c "cat $INSTALL | SALVORIAS_POLL_SECONDS=10 SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8000 bash -s -- --network testnet --rpc-url $MOCK_RPC --owner $OWNER --wait-minutes 1"
expect_rc 3 "registration wait times out with exit 3"
expect_log piped-timeout 'REGISTER THIS NODE IN THE SALVORIAS APP' "registration box printed"
expect_log piped-timeout 'Free slot\(s\) on your license: 0, 1' "free slots listed"
expect_log piped-timeout 'Licenses > Self Setup, paste this node' "app instruction printed"
expect_log piped-timeout 'Suggested: at least .* SAVDR for about 90 days|network fee is 0' "funding guidance printed"
expect_log piped-timeout 'sudo salvorias-selfhost resume' "timeout points to salvorias-selfhost resume"
expect_true "salvorias-selfhost installed from the verified release copy" cmp -s "$SELF" "$WORK/rel-good/install.sh"
expect_stat "$SELF" "755 root:root"
NODE="$(cat /var/lib/salvorias/node-address.txt)"
echo "Node address: $NODE"
expect_true "state is awaiting-registration" grep -q '^STAGE=awaiting-registration$' /etc/salvorias/selfhost.conf
expect_true "service not installed while unregistered" test ! -e /etc/systemd/system/salvorias-node.service

section "6. one node per server while waiting"
run second-while-waiting bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER"
expect_rc 1 "second install refused"
expect_log second-while-waiting 'already waiting for the node to be registered' "points to resume"

section "7. Ctrl-C during the wait is safe"
STEP=$((STEP + 1))
printf '\n--- [%02d] $ salvorias-selfhost resume (SIGINT after 8s)\n' "$STEP"
SALVORIAS_POLL_SECONDS=3 spawn_sigint_able "$SELF" resume --wait-minutes 5 >"$OUT/sigint.log" 2>&1 &
pid=$!
sleep 8
kill -INT -- "-$pid" 2>/dev/null || echo "    (resume had already exited before the signal)"
set +e; wait "$pid"; RC=$?; set -e
sed 's/^/    | /' "$OUT/sigint.log"; printf '    (exit %s)\n' "$RC"
expect_rc 130 "interrupted resume exits 130"
expect_log sigint 'Interrupted' "interrupt acknowledged"
expect_log sigint 'continue with:' "interrupt explains how to resume"
expect_true "still awaiting registration after Ctrl-C" grep -q '^STAGE=awaiting-registration$' /etc/salvorias/selfhost.conf

section "8. resume; the owner registers the node in the app while it waits"
MOCK_LINES_AT_START=$(wc -l <"$MOCK_STATE/mock-rpc.log")
STEP=$((STEP + 1))
printf '\n--- [%02d] $ salvorias-selfhost resume (binding appears after 8s)\n' "$STEP"
SALVORIAS_POLL_SECONDS=3 "$SELF" resume --wait-minutes 3 >"$OUT/resume.log" 2>&1 &
pid=$!
sleep 8
printf '%s\n' "$NODE" >"$MOCK_STATE/bound-node"
set +e; wait "$pid"; RC=$?; set -e
sed 's/^/    | /' "$OUT/resume.log"; printf '    (exit %s)\n' "$RC"
expect_rc 0 "resume completes"
expect_log resume 'not registered yet' "polled while unregistered"
expect_log resume "Registered: node $NODE is bound to" "binding detected"
expect_log resume 'Salvorias node installed' "summary printed"
expect_log resume 'sudo salvorias-selfhost status' "summary uses salvorias-selfhost forms"
# The node holds 0 SAVDR. With a non-zero fee that must warn; with the fee at
# 0 (testnet at the time of writing) a 0 balance pays for check-ins, so no
# warning is correct. tests/unit-math.sh covers the non-zero fee text.
if grep -q 'network fee is 0 right now' "$OUT/resume.log"; then
  expect_no_log resume 'below the cost of one check-in' "no low-balance warning while the fee is 0"
else
  expect_log resume 'below the cost of one check-in' "low-balance warning (node holds 0 SAVDR)"
fi

section "9. service, files, owners and modes"
sleep 5
systemctl --no-pager status salvorias-node.service | sed 's/^/    | /' || true
expect_true "service is active" systemctl is-active --quiet salvorias-node.service
expect_true "service is enabled" systemctl is-enabled --quiet salvorias-node.service
expect_true "no restarts" test "$(systemctl show -p NRestarts --value salvorias-node.service)" = 0
echo "MemoryCurrent: $(systemctl show -p MemoryCurrent --value salvorias-node.service) bytes (MemoryMax=200M)"
journalctl -u salvorias-node.service --no-pager -n 40 >"$OUT/journal.log" 2>&1 || true
sed 's/^/    | /' "$OUT/journal.log"
expect_log journal 'Gas Price Mode: +network' "daemon runs in network gas mode"
expect_log journal "$NODE → owner" "daemon sees its registration"
expect_stat /etc/salvorias "750 root:salvorias"
expect_stat /etc/salvorias/node.env "640 root:salvorias"
expect_stat /etc/salvorias/selfhost.conf "640 root:salvorias"
expect_stat /var/lib/salvorias "700 salvorias:salvorias"
expect_stat /var/lib/salvorias/node-key.txt "600 salvorias:salvorias"
expect_stat /opt/salvorias/bin/0.0.9/salvorias-node "755 root:root"
expect_stat /etc/systemd/system/salvorias-node.service "644 root:root"
expect_true "PATH symlink -> current" test "$(readlink /usr/local/bin/salvorias-node)" = /opt/salvorias/bin/current/salvorias-node
expect_true "current -> 0.0.9" test "$(readlink /opt/salvorias/bin/current)" = 0.0.9
getent passwd salvorias | sed 's/^/    passwd: /'
expect_true "salvorias is a nologin system user without a home" service_user_ok
expect_true "key file holds exactly one 0x key line" key_file_ok
echo "node.env:"; sed 's/^/    | /' /etc/salvorias/node.env
DAEMON_RPC="$(sed -n 's/^RPC_URL=//p' /etc/salvorias/node.env)"
for want in "GAS_PRICE_MODE=network" "MAX_GAS_PRICE_GWEI=50" "EXPECTED_CHAIN_ID=7283" \
    "NODE_KEYS_FILE=/var/lib/salvorias/node-key.txt" "CHECKIN_CONTRACT=$TESTNET_CHECKIN" \
    "TREASURY_CONTRACT=0x7e8ecebF965dE86fDE7Ebc7F3020813d656CF723"; do
  expect_true "node.env has $want" grep -qx "$want" /etc/salvorias/node.env
done
echo "unit file:"; sed 's/^/    | /' /etc/systemd/system/salvorias-node.service

section "10. one node per server once installed"
run second-installed bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER"
expect_rc 1 "second install refused"
expect_log second-installed 'Only one node per server' "one-node message"

section "11. status (unfunded, then funded through the mock)"
run status "$SELF" status
expect_rc 0 "status"
expect_log status 'registered to the owner, slot 1' "status shows the binding"
expect_log status 'Last 20 log lines' "status shows the journal"
printf '1000000000000000000\n' >"$MOCK_STATE/balance-wei"
run status-funded "$SELF" status
rm -f "$MOCK_STATE/balance-wei"
expect_rc 0 "status with a balance"
expect_log status-funded 'Balance: +1 SAVDR' "balance shown in SAVDR"
expect_log status-funded 'Check-ins left: about' "check-ins left estimate shown"

section "12. backup-key"
run backup "$SELF" backup-key --out /root/node-key-backup.txt
expect_rc 0 "backup-key"
expect_stat /root/node-key-backup.txt "600 root:root"
expect_true "backup matches the node key" cmp -s /root/node-key-backup.txt /var/lib/salvorias/node-key.txt
run backup-again "$SELF" backup-key --out /root/node-key-backup.txt
expect_rc 1 "backup-key refuses to overwrite"

section "13. upgrade rollback with a broken binary"
cat >/root/broken-node <<'EOF'
#!/bin/sh
# Passes the installer's version smoke test, then fails as a daemon.
if [ "$1" = version ]; then echo "salvorias-node v0.0.10-broken"; exit 0; fi
echo "broken build: refusing to start" >&2
exit 1
EOF
chmod 0755 /root/broken-node
run upgrade-broken "$SELF" upgrade --binary /root/broken-node
expect_rc 1 "broken upgrade fails"
expect_log upgrade-broken 'Rolling back to 0.0.9' "rolled back"
expect_log upgrade-broken 'Rolled back to 0.0.9, which is running again' "old version running again"
expect_true "current -> 0.0.9 after rollback" test "$(readlink /opt/salvorias/bin/current)" = 0.0.9
expect_true "broken version dir removed" test ! -e /opt/salvorias/bin/0.0.10-broken
expect_true "service active after rollback" systemctl is-active --quiet salvorias-node.service

head -c 4096 /dev/urandom >/root/garbage-node
run upgrade-garbage "$SELF" upgrade --binary /root/garbage-node
expect_rc 1 "a binary that does not run is refused before switching"
expect_log upgrade-garbage 'does not run on this server' "explains the binary does not run"
expect_true "current unchanged" test "$(readlink /opt/salvorias/bin/current)" = 0.0.9

section "14. upgrade from a release (checksum verified) refreshes salvorias-selfhost"
run upgrade-ok env SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8001 "$SELF" upgrade
expect_rc 0 "upgrade to the next build"
expect_log upgrade-ok 'Checksum verified' "release binary verified"
NEXT_VERSION="$("$BIN_NEXT" version | sed 's/^salvorias-node v//')"
expect_true "current -> $NEXT_VERSION" test "$(readlink /opt/salvorias/bin/current)" = "$NEXT_VERSION"
expect_true "previous version kept for rollback" test -x /opt/salvorias/bin/0.0.9/salvorias-node
expect_true "service active on the new version" systemctl is-active --quiet salvorias-node.service
expect_true "salvorias-selfhost refreshed from the release" cmp -s "$SELF" "$WORK/rel-next/install.sh"
run upgrade-same env SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8001 "$SELF" upgrade
expect_rc 0 "upgrade to the same binary"
expect_log upgrade-same 'Already running this binary' "no-op when already current"

section "15. uninstall (keeps the key), then reinstall reuses it"
run uninstall-notty setsid -w "$SELF" uninstall
expect_rc 2 "uninstall without a terminal and without --yes is refused"
run uninstall-keep "$SELF" uninstall --yes
expect_rc 0 "uninstall --yes"
expect_log uninstall-keep 'clear it in the Salvorias app' "slot reminder"
expect_true "service, config, binaries and salvorias-selfhost removed" \
  bash -c '[[ ! -e /etc/systemd/system/salvorias-node.service && ! -e /etc/salvorias && ! -e /opt/salvorias && ! -e /usr/local/bin/salvorias-node && ! -e /usr/local/sbin/salvorias-selfhost ]]'
expect_stat /var/lib/salvorias/node-key.txt "600 salvorias:salvorias"
expect_true "service is gone from systemd" bash -c '! systemctl cat salvorias-node.service >/dev/null 2>&1'
run reinstall-reuse bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER"
expect_rc 0 "reinstall with the kept key"
expect_log reinstall-reuse "kept by an earlier uninstall: $NODE" "kept key reused"
expect_log reinstall-reuse 'already registered to this wallet' "registration wait skipped"
expect_no_log reinstall-reuse 'REGISTER THIS NODE' "no registration box"
expect_true "salvorias-selfhost installed from the running file" cmp -s "$SELF" "$INSTALL"
expect_true "service active" systemctl is-active --quiet salvorias-node.service

section "16. uninstall --purge-key needs the typed confirmation"
run purge-wrong with_tty "uninstall
yes
" "$SELF uninstall --purge-key"
expect_rc 1 "wrong confirmation cancels"
expect_true "nothing changed after cancel" systemctl is-active --quiet salvorias-node.service
run purge with_tty "uninstall
delete node key
" "$SELF uninstall --purge-key"
expect_rc 0 "purge with the typed confirmation"
expect_true "nothing left after purge" nothing_installed

section "17. install --import-key (server migration)"
cp /root/node-key-backup.txt /root/import-open.txt
chmod 0644 /root/import-open.txt
run import-open bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER" --import-key /root/import-open.txt
expect_rc 2 "world-readable key file refused"
expect_log import-open 'readable by other users' "explains the permission problem"
( umask 077; cat /root/node-key-backup.txt /root/node-key-backup.txt >/root/import-two.txt )
run import-two bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER" --import-key /root/import-two.txt
expect_rc 2 "file with two keys refused"
( umask 077; printf 'not a key\n' >/root/import-junk.txt )
run import-junk bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER" --import-key /root/import-junk.txt
expect_rc 2 "junk file refused"
expect_true "nothing installed after refused imports" nothing_installed
# Bare hex, no 0x and no trailing newline, is accepted too.
( umask 077; tr -d '\n' </root/node-key-backup.txt | sed 's/^0x//' >/root/import-bare.txt )
run import bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER" --import-key /root/import-bare.txt --self "$WORK/rel-next/install.sh"
expect_rc 0 "import-key install"
expect_true "--self file installed as salvorias-selfhost" cmp -s "$SELF" "$WORK/rel-next/install.sh"
expect_log import "Imported key belongs to node $NODE" "derived address matches the original node"
expect_log import 'already registered to this wallet' "already bound: registration wait skipped"
expect_log import 'sudo shred -u /root/import-bare.txt' "advises deleting the source copy"
expect_true "imported key normalised to the keygen format" cmp -s /var/lib/salvorias/node-key.txt /root/node-key-backup.txt
expect_stat /var/lib/salvorias/node-key.txt "600 salvorias:salvorias"
expect_true "service active" systemctl is-active --quiet salvorias-node.service
journalctl -u salvorias-node.service --no-pager -n 400 >"$OUT/journal-final.log" 2>&1 || true

section "18. final purge"
run purge-final with_tty "uninstall
delete node key
" "$SELF uninstall --purge-key"
expect_rc 0 "final purge"
expect_true "server clean" nothing_installed

section "19. no transactions, no key in any output"
blocked=$(grep -c '^BLOCKED' "$MOCK_STATE/mock-rpc.log" || true)
mocked=$(grep -c '^MOCKED' "$MOCK_STATE/mock-rpc.log" || true)
echo "mock-rpc: $mocked mocked reads, $blocked transaction attempts blocked"
grep '^BLOCKED' "$MOCK_STATE/mock-rpc.log" | sort | uniq -c | sed 's/^/    /' || true
grep -a -iE 'check-in|transactions are disabled' "$OUT"/journal*.log | tail -5 | sed 's/^/    journal: /' || true
# The installer itself only reads. The daemon does try check-ins (the testnet
# fee is 0, so a 0 balance passes its balance check); every attempt went to the
# mock, which refuses to send. The daemon's only RPC was the mock:
expect_true "the daemon was configured with the mock as its only RPC" test "$DAEMON_RPC" = "$MOCK_RPC"
# Until section 8 the daemon had never run, so anything blocked then would
# have come from the installer itself.
before_daemon=$(head -n "$MOCK_LINES_AT_START" "$MOCK_STATE/mock-rpc.log" | grep -c '^BLOCKED' || true)
expect_true "the installer itself never tried to send a transaction" test "$before_daemon" = 0
KEYHEX="$(sed 's/^0x//' /root/node-key-backup.txt)"
if grep -rqiF -- "$KEYHEX" "$OUT"; then fail "node key appears in installer output"; else pass "node key appears in no installer output or journal"; fi
KEYHEX=""
shred -u /root/node-key-backup.txt /root/import-*.txt 2>/dev/null || true

printf '\n\nRESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
