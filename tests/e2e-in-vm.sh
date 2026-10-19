#!/usr/bin/env bash
# End-to-end test of install.sh, run as root INSIDE a disposable Ubuntu VM
# with systemd. Driven from the host by tests/e2e-lima.sh; see tests/README.md.
#
# It changes the VM's system state (users, /etc, /opt, systemd units), so
# never run it on a real server.
#
# Layout it expects under E2E_DIR (default: the parent of this script):
#   install.sh
#   tests/mock-rpc.py, tests/unit-math.sh
#   bin/salvorias-node-linux-<arch>          current release binary
#   bin/next/salvorias-node-linux-<arch>     a newer build (reports another version)
#   bin/broken/salvorias-node-linux-<arch>   tests/broken-node.js, built
#
# What it needs from outside: HTTPS to https://testnet.salvorias.net, for
# reads only. It sends no transactions: the "licensed" scenarios go through
# tests/mock-rpc.py, which refuses every transaction-sending method.

set -euo pipefail

E2E_DIR="${E2E_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TESTNET_RPC="${TESTNET_RPC:-https://testnet.salvorias.net}"
TESTNET_CHECKIN="0x51F6122C6014866Bd9443E21b05033b195A1fF27"
TESTNET_NFT="0xa1CF5786c6ceC9E8D0BbACEdF2cc98dAe4614363"
PROBE_NODE="0x0000000000000000000000000000000000000001"
MOCK_FEE_WEI=1000000000   # 1 gwei priority fee, pinned by the main mock

INSTALL="$E2E_DIR/install.sh"
SELF="/usr/local/sbin/salvorias-selfhost"
DATA=/var/lib/salvorias
case "$(uname -m)" in
  x86_64) ARCH="linux-x64"; OTHER_MACHINE='\267\000' ;;
  aarch64) ARCH="linux-arm64"; OTHER_MACHINE='\076\000' ;;
  *) echo "unsupported arch" >&2; exit 1 ;;
esac
BIN="$E2E_DIR/bin/salvorias-node-$ARCH"
BIN_NEXT="$E2E_DIR/bin/next/salvorias-node-$ARCH"
BIN_BROKEN="$E2E_DIR/bin/broken/salvorias-node-$ARCH"

WORK="$(mktemp -d /root/selfhost-e2e.XXXXXX)"
OUT="$WORK/logs"
MOCK_STATE="$WORK/mock"
FAITHFUL_STATE="$WORK/mock-faithful"
MOCK_RPC="http://127.0.0.1:8545"
FAITHFUL_RPC="http://127.0.0.1:8549"
mkdir -p "$OUT" "$MOCK_STATE" "$FAITHFUL_STATE"

PASS=0
FAIL=0
RC=0
MASK_HITS=0
PIDS=()
STEP=0
RUN_MASK=""

[[ "$(id -u)" -eq 0 ]] || { echo "run as root inside the test VM" >&2; exit 1; }
for b in "$BIN" "$BIN_NEXT" "$BIN_BROKEN"; do [[ -f "$b" ]] || { echo "missing $b" >&2; exit 1; }; done
chmod 0755 "$BIN" "$BIN_NEXT" "$BIN_BROKEN"

cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

section() { printf '\n\n######## %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; }

# run NAME CMD...: runs CMD, keeps its output in $OUT/NAME.log, shows it, sets
# RC. With RUN_MASK set, that string is replaced in the step header and in
# the log BEFORE either is shown, so it never reaches the transcript.
# MASK_HITS counts the occurrences in the raw log, before masking, for checks
# that the command itself never printed it.
run() {
  local name="$1" shown
  shift
  STEP=$((STEP + 1))
  shown="$*"
  if [[ -n "$RUN_MASK" ]]; then shown="${shown//"$RUN_MASK"/<masked>}"; fi
  printf '\n--- [%02d] $ %s\n' "$STEP" "$shown"
  set +e
  "$@" >"$OUT/$name.log" 2>&1
  RC=$?
  set -e
  MASK_HITS=0
  if [[ -n "$RUN_MASK" ]]; then
    MASK_HITS=$(grep -cF -- "$RUN_MASK" "$OUT/$name.log" || true)
    sed -i "s/$RUN_MASK/<masked>/g" "$OUT/$name.log"
  fi
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
  [[ ! -e /etc/salvorias && ! -e /opt/salvorias && ! -e "$DATA" && ! -e "$SELF" \
    && ! -e /etc/systemd/system/salvorias-node.service ]] && ! id -u salvorias >/dev/null 2>&1
}
service_user_ok() {
  [[ "$(getent passwd salvorias | cut -d: -f6,7)" == "/nonexistent:/usr/sbin/nologin" && "$(id -u salvorias)" -lt 1000 ]]
}
# Checks the key file's shape without printing it.
key_file_ok() {
  [[ "$(grep -cE '^0x[0-9a-f]{64}$' "$DATA/node-key.txt")" == 1 && "$(wc -l <"$DATA/node-key.txt")" == 1 ]]
}
data_layout_ok() {
  expect_stat "$DATA" "750 root:salvorias"
  expect_stat "$DATA/node-key.txt" "600 salvorias:salvorias"
  expect_stat "$DATA/node-address.txt" "644 root:root"
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
# Plays the owner registering the node in the app, once the installer has
# written the node address: STATE_DIR/bound-node is what the mock reads.
bind_when_ready() {
  local state_dir="$1" _
  for _ in $(seq 1 120); do
    if [[ -f "$DATA/node-address.txt" ]]; then
      sleep "$2"
      head -n 1 "$DATA/node-address.txt" >"$state_dir/bound-node"
      return 0
    fi
    sleep 1
  done
}

# ─── Decoys for the planted-link steps ────────────────────────────────────
# Stand-ins for /etc/profile and /dev/vda. A planted node-key.txt or
# node-address.txt link points at one of these; each refusal must leave them
# exactly as they were.
printf 'export E2E_DECOY=1\n' >/root/decoy-profile
chmod 0644 /root/decoy-profile
head -c 65536 /dev/urandom >/root/decoy-disk
chown root:disk /root/decoy-disk
chmod 0660 /root/decoy-disk
decoy_state() {
  stat -c '%n %a %U:%G %s %h' /root/decoy-profile /root/decoy-disk
  sha256sum /root/decoy-profile /root/decoy-disk
}
DECOY_BEFORE="$(decoy_state)"
decoys_unchanged() { [[ "$(decoy_state)" == "$DECOY_BEFORE" ]]; }
# plant NAME TARGET: replaces $DATA/NAME with a link to TARGET (keeps the file).
plant() { mv "$DATA/$1" "$WORK/saved-$1"; ln -s "$2" "$DATA/$1"; }
unplant() { rm -f "$DATA/$1"; mv "$WORK/saved-$1" "$DATA/$1"; }

OWNER="0x$(openssl rand -hex 20)"
FAKE_SECRET="$(openssl rand -hex 32)"   # random, never used as a key anywhere
SEED_WORDS="abandon ability able about above absent absorb abstract absurd abuse access accident"
echo "E2E work dir: $WORK"
echo "Test owner (random, holds no license on testnet): $OWNER"
"$BIN" version
"$BIN_NEXT" version
"$BIN_BROKEN" version

# ─── Local release servers ────────────────────────────────────────────────
# 8000 good release; 8001 the next binary plus a marked install.sh (proves
# upgrade refreshes salvorias-selfhost); 8002 a tampered binary; 8003 good,
# with a CRLF checksums.txt in sha256sum's binary (*name) form; 8004 an empty
# checksums.txt; 8005 a checksums.txt with no entry for the binary.
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
make_release "$WORK/rel-crlf" "$BIN"
(cd "$WORK/rel-crlf" && sha256sum -b "salvorias-node-$ARCH" install.sh | sed 's/$/\r/' >checksums.txt)
make_release "$WORK/rel-empty" "$BIN"
: >"$WORK/rel-empty/checksums.txt"
make_release "$WORK/rel-noentry" "$BIN"
(cd "$WORK/rel-noentry" && sha256sum install.sh >checksums.txt)
for spec in 8000:rel-good 8001:rel-next 8002:rel-bad 8003:rel-crlf 8004:rel-empty 8005:rel-noentry; do
  python3 -m http.server "${spec%%:*}" --bind 127.0.0.1 --directory "$WORK/${spec#*:}" >/dev/null 2>&1 &
  PIDS+=($!)
done
echo "rel-crlf checksums.txt:"; od -c "$WORK/rel-crlf/checksums.txt" | head -3 | sed 's/^/    /'

python3 "$E2E_DIR/tests/mock-rpc.py" --listen 127.0.0.1:8545 --upstream "$TESTNET_RPC" \
  --checkin "$TESTNET_CHECKIN" --nft "$TESTNET_NFT" --owner "$OWNER" \
  --licenses 2 --open-slots 0,1 --bound-slot 1 --state-dir "$MOCK_STATE" --emulate-node-to-slot \
  --fee-wei "$MOCK_FEE_WEI" &
PIDS+=($!)
# Same licensed owner, but faithful to the testnet contract (no nodeToSlot):
# slot-info has to find the slot by scanning nodeAddressOf.
python3 "$E2E_DIR/tests/mock-rpc.py" --listen 127.0.0.1:8549 --upstream "$TESTNET_RPC" \
  --checkin "$TESTNET_CHECKIN" --nft "$TESTNET_NFT" --owner "$OWNER" \
  --licenses 2 --open-slots 0,1 --bound-slot 1 --state-dir "$FAITHFUL_STATE" &
PIDS+=($!)
sleep 2

# ─── 1. Usage, preflight and input checks (real testnet) ──────────────────

section "0. unit tests for the pure helpers"
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
run rollback-binary bash "$INSTALL" upgrade --rollback --binary "$BIN"
expect_rc 2 "upgrade --rollback with --binary is refused"
RUN_MASK="$FAKE_SECRET"
run privkey-flag bash "$INSTALL" --network testnet --binary "$BIN" --owner "0x$FAKE_SECRET"
RUN_MASK=""
expect_rc 2 "a private key passed as --owner is rejected"
expect_log privkey-flag 'looks like a PRIVATE KEY' "private-key warning shown"
expect_true "the rejected secret is not echoed back (raw output)" test "$MASK_HITS" = 0
run wrong-chain bash "$INSTALL" --network mainnet --rpc-url "$TESTNET_RPC" --binary "$BIN" --owner "$OWNER"
expect_rc 1 "mainnet with a testnet RPC is refused"
expect_log wrong-chain 'is chain 7283, but mainnet is chain 7282' "chain id mismatch explained"
run http-rpc bash "$INSTALL" --network testnet --rpc-url http://example.com --binary "$BIN" --owner "$OWNER"
expect_rc 2 "plain-http non-local RPC is refused"
run userinfo-rpc bash "$INSTALL" --network testnet --rpc-url 'http://localhost:1@evil.example/' --binary "$BIN" --owner "$OWNER"
expect_rc 2 "http://localhost:1@evil.example/ is not taken for localhost"
run quote-rpc bash "$INSTALL" --network testnet --rpc-url 'https://testnet.salvorias.net/"x' --binary "$BIN" --owner "$OWNER"
expect_rc 2 "an RPC URL with a quote is refused"
run bad-repo env SALVORIAS_RELEASE_REPO=$'evil/x\nExecStartPre=/bin/sh' bash "$INSTALL" --network testnet --binary "$BIN" --owner "$OWNER"
expect_rc 2 "a release repo with a newline is refused"
run pct-repo env SALVORIAS_RELEASE_REPO='evil/%n' bash "$INSTALL" --network testnet --binary "$BIN" --owner "$OWNER"
expect_rc 2 "a release repo with % is refused"
run short-watch env SALVORIAS_UPGRADE_WATCH_SECONDS=5 bash "$INSTALL" status
expect_rc 2 "an upgrade watch under 10s is refused"
expect_log short-watch 'at least 10' "minimum watch explained"
# bash arithmetic reads 08 as invalid octal; it must be a usage error instead.
run octal-wait bash "$INSTALL" --network testnet --binary "$BIN" --owner "$OWNER" --wait-minutes 08
expect_rc 2 "--wait-minutes 08 is refused as bad input"
expect_log octal-wait 'must be a whole number of minutes' "leading zero explained"
expect_no_log octal-wait 'value too great for base' "no bash arithmetic error"
run octal-poll env SALVORIAS_POLL_SECONDS=08 bash "$INSTALL" status
expect_rc 2 "SALVORIAS_POLL_SECONDS=08 is refused as bad input"
expect_no_log octal-poll 'value too great for base' "no bash arithmetic error (poll)"
run octal-watch env SALVORIAS_UPGRADE_WATCH_SECONDS=010 bash "$INSTALL" status
expect_rc 2 "SALVORIAS_UPGRADE_WATCH_SECONDS=010 is refused as bad input"
printf '#!/bin/sh\necho "salvorias-node v9.9.9"\n' >/root/script-node
chmod 0755 /root/script-node
run elf-script bash "$INSTALL" --network testnet --binary /root/script-node --owner "$OWNER"
expect_rc 1 "a shell script as --binary is refused before it runs"
expect_log elf-script 'not a Linux executable' "ELF check explains"
{ printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000'; printf '%b' "$OTHER_MACHINE"; head -c 4096 /dev/urandom; } >/root/wrongarch-node
chmod 0755 /root/wrongarch-node
run elf-arch bash "$INSTALL" --network testnet --binary /root/wrongarch-node --owner "$OWNER"
expect_rc 1 "an ELF for another CPU is refused before it runs"
expect_log elf-arch 'built for another CPU' "wrong-CPU message"

useradd --create-home --shell /bin/bash salvorias
run login-user bash "$INSTALL" --network testnet --binary "$BIN" --owner "$OWNER"
expect_rc 1 "an existing login account named salvorias is refused"
expect_log login-user 'not a locked-down system account' "account problem explained"
expect_log login-user 'allows logins' "names the login shell"
expect_true "nothing written for the refused account" test ! -e /etc/salvorias -a ! -e "$DATA"
userdel -r salvorias 2>/dev/null
# System accounts that look locked down but share access with others.
useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin salvorias
usermod -aG adm salvorias
run user-extra-group bash "$INSTALL" --network testnet --binary "$BIN" --owner "$OWNER"
expect_rc 1 "a system salvorias account with a supplementary group is refused"
expect_log user-extra-group 'belongs to other groups \(salvorias adm\)' "names the extra group"
gpasswd -d salvorias adm >/dev/null
useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin -g salvorias salvorias-other
run user-shared-gid bash "$INSTALL" --network testnet --binary "$BIN" --owner "$OWNER"
expect_rc 1 "a second account with the salvorias primary group is refused"
expect_log user-shared-gid 'other accounts have the .salvorias. group as their primary group \(salvorias-other\)' "names the other account"
userdel salvorias-other
run user-clean bash "$INSTALL" --network testnet --binary "$BIN" --owner "$OWNER"
expect_rc 3 "a clean system salvorias account passes the account check (then the no-license stop)"
expect_no_log user-clean 'not a locked-down system account' "no account problem reported"
userdel salvorias
groupadd -g 1500 salvorias
useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin -g salvorias salvorias
run user-gid bash "$INSTALL" --network testnet --binary "$BIN" --owner "$OWNER"
expect_rc 1 "a salvorias account whose primary GID is not a system GID is refused"
expect_log user-gid 'primary GID 1500 is not a system GID' "names the GID"
userdel salvorias
groupdel salvorias 2>/dev/null || true
expect_true "nothing written for the refused accounts" test ! -e /etc/salvorias -a ! -e "$DATA"

section "2. no license: stop before installing anything (real testnet, random owner)"
run no-license bash "$INSTALL" --network testnet --binary "$BIN" --owner "$OWNER"
expect_rc 3 "random owner stops with exit 3"
expect_log no-license 'holds no Salvorias node license on testnet' "no-license message"
expect_true "nothing installed after the no-license stop" nothing_installed

section "3. interactive prompt while piped (curl | sudo bash), secrets rejected"
# The pty echoes what was typed. RUN_MASK replaces the fake key in the log
# before it is shown, so the transcript never holds it.
RUN_MASK="$FAKE_SECRET"
run prompt-piped with_tty "0x$FAKE_SECRET
$SEED_WORDS
$OWNER
" "cat $INSTALL | bash -s -- --network testnet --binary $BIN"
RUN_MASK=""
expect_rc 3 "piped run with prompts reaches the no-license stop"
expect_log prompt-piped 'looks like a PRIVATE KEY' "typed private key rejected"
expect_log prompt-piped 'SEED / RECOVERY PHRASE' "typed seed phrase rejected"
expect_log prompt-piped 'holds no Salvorias node license' "valid address accepted after rejections"
expect_true "nothing installed after the piped run" nothing_installed

section "4. release download path: checksum verified / refused"
run download-ok env SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8000 bash "$INSTALL" --network testnet --owner "$OWNER"
expect_rc 3 "downloaded binary verified, then no-license stop"
expect_log download-ok 'Checksum verified: salvorias-node-' "checksum verified message"
run download-crlf env SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8003 bash "$INSTALL" --network testnet --owner "$OWNER"
expect_rc 3 "CRLF checksums.txt with *name entries verifies"
expect_log download-crlf 'Checksum verified: salvorias-node-' "verified through the CRLF file"
run download-bad env SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8002 bash "$INSTALL" --network testnet --owner "$OWNER"
expect_rc 1 "tampered binary is refused"
expect_log download-bad 'Checksum mismatch' "mismatch message"
run download-empty env SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8004 bash "$INSTALL" --network testnet --owner "$OWNER"
expect_rc 1 "an empty checksums.txt is refused"
expect_log download-empty 'no single valid entry' "empty checksums explained"
run download-noentry env SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8005 bash "$INSTALL" --network testnet --owner "$OWNER"
expect_rc 1 "a checksums.txt without the binary's entry is refused"
expect_true "nothing installed after the refused downloads" nothing_installed

section "4b. the testnet contract as deployed (no nodeToSlot getter)"
run slot-info-testnet "$BIN" slot-info --rpc-url "$TESTNET_RPC" --contract "$TESTNET_CHECKIN" --owner "$OWNER" --node "$PROBE_NODE"
expect_rc 0 "slot-info --node works against https://testnet.salvorias.net (read-only)"
expect_log slot-info-testnet '"boundSlotSource":null' "reports boundSlotSource for an unbound node"
# This install also runs with a salvorias account made beforehand, outside
# the installer. check_existing_user accepts it; the purge below must keep it.
useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin salvorias
PRE_UID="$(id -u salvorias)"
bind_when_ready "$FAITHFUL_STATE" 4 &
run faithful env SALVORIAS_POLL_SECONDS=3 bash "$INSTALL" --network testnet --rpc-url "$FAITHFUL_RPC" --binary "$BIN" --owner "$OWNER" --wait-minutes 3
expect_rc 0 "a full install against the testnet contract shape completes"
expect_log faithful 'Using the existing system user salvorias. This installer did not create it' "the pre-made account is used, and named as not the installer's"
expect_true "state records the account as not created by the installer" grep -qx 'ACCOUNT_CREATED=no' /etc/salvorias/selfhost.conf
expect_no_log faithful 'Could not read node registration data' "the slot-info --node pre-check passes"
expect_log faithful 'Registered: node .* \(slot 1\)' "registration found through the slot scan"
FNODE="$(cat "$DATA/node-address.txt")"
run slot-info-scan "$BIN" slot-info --rpc-url "$FAITHFUL_RPC" --contract "$TESTNET_CHECKIN" --owner "$OWNER" --node "$FNODE"
expect_log slot-info-scan '"boundSlotSource":"scan"' "slot came from the scan"
run faithful-purge with_tty "uninstall
delete node key
" "$SELF uninstall --purge-key"
expect_rc 0 "purge after the faithful-contract install"
expect_log faithful-purge 'It keeps the salvorias system user: this installer did not create it' "purge says up front that it keeps the account"
expect_log faithful-purge 'Kept the salvorias user: this installer did not create it' "purge reports the account kept"
expect_no_log faithful-purge 'Deleted the salvorias user' "purge does not delete the pre-made account"
expect_true "the pre-made account still exists, same UID" test "$(id -u salvorias 2>/dev/null)" = "$PRE_UID"
expect_true "everything else removed" test ! -e /etc/salvorias -a ! -e /opt/salvorias -a ! -e "$DATA" -a ! -e "$SELF"
userdel salvorias
rm -f "$FAITHFUL_STATE/bound-node"
expect_true "server clean again" nothing_installed

# ─── 5. Licensed owner via the mock RPC ───────────────────────────────────

section "5. piped install from the release, with a file named main in the cwd; registration wait times out"
# bash names a piped script "main". A file of that name in the cwd, carrying
# the installer marker, must not be mistaken for the running script.
mkdir -p "$WORK/cwd"
{ head -n 2 "$INSTALL"; printf '# e2e: planted main, must never be installed\n'; } >"$WORK/cwd/main"
run piped-timeout bash -c "cd $WORK/cwd && cat $INSTALL | SALVORIAS_POLL_SECONDS=10 SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8000 bash -s -- --network testnet --rpc-url $MOCK_RPC --owner $OWNER --wait-minutes 1"
expect_rc 3 "registration wait times out with exit 3"
expect_log piped-timeout 'REGISTER THIS NODE IN THE SALVORIAS APP' "registration box printed"
expect_log piped-timeout 'Free slot\(s\) on your license: 0, 1' "free slots listed"
expect_log piped-timeout 'Licenses > Self Setup, paste this node' "app instruction printed"
expect_log piped-timeout 'Keep at least .* SAVDR on the node \(the per-check-in reserve' "funding text names the reserve"
expect_log piped-timeout 'Suggested for about 90 days: .* SAVDR' "90-day suggestion printed"
expect_log piped-timeout 'sudo salvorias-selfhost resume' "timeout points to salvorias-selfhost resume"
expect_true "salvorias-selfhost installed from the verified release copy" cmp -s "$SELF" "$WORK/rel-good/install.sh"
expect_true "the planted ./main was not installed" bash -c "! grep -q 'planted main' $SELF"
expect_stat "$SELF" "755 root:root"
data_layout_ok
NODE="$(cat "$DATA/node-address.txt")"
echo "Node address: $NODE"
expect_true "state is awaiting-registration" grep -q '^STAGE=awaiting-registration$' /etc/salvorias/selfhost.conf
expect_true "service not installed while unregistered" test ! -e /etc/systemd/system/salvorias-node.service
expect_log piped-timeout 'Created system user: salvorias' "the installer created the account"
expect_true "state records the account as created by the installer" grep -qx 'ACCOUNT_CREATED=yes' /etc/salvorias/selfhost.conf

section "6. one node per server while waiting"
run second-while-waiting bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER"
expect_rc 1 "second install refused"
expect_log second-while-waiting 'has not finished' "points to resume"

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

section "8. resume; the owner registers mid-wait; the first service start fails, a second resume starts it"
MOCK_LINES_AT_START=$(wc -l <"$MOCK_STATE/mock-rpc.log")
# A drop-in whose ExecStartPre fails makes `systemctl enable --now` fail.
mkdir -p /etc/systemd/system/salvorias-node.service.d
printf '[Service]\nExecStartPre=/bin/false\n' >/etc/systemd/system/salvorias-node.service.d/e2e-fail.conf
STEP=$((STEP + 1))
printf '\n--- [%02d] $ salvorias-selfhost resume (binding appears after 8s; start forced to fail)\n' "$STEP"
SALVORIAS_POLL_SECONDS=3 "$SELF" resume --wait-minutes 3 >"$OUT/resume-fail.log" 2>&1 &
pid=$!
sleep 8
printf '%s\n' "$NODE" >"$MOCK_STATE/bound-node"
set +e; wait "$pid"; RC=$?; set -e
sed 's/^/    | /' "$OUT/resume-fail.log"; printf '    (exit %s)\n' "$RC"
expect_rc 1 "resume reports the failed start"
expect_log resume-fail 'not registered yet' "polled while unregistered"
expect_log resume-fail "Registered: node $NODE is bound to" "binding detected"
expect_log resume-fail 'could not be started' "failed start explained"
expect_no_log resume-fail 'Salvorias node installed' "no installed summary after a failed start"
expect_true "stage is starting, not installed" grep -q '^STAGE=starting$' /etc/salvorias/selfhost.conf
expect_true "service is not active" bash -c '! systemctl is-active --quiet salvorias-node.service'
# Now the start succeeds, but the daemon (tests/broken-node.js, built) exits
# 3 seconds later, inside the installer's post-start watch. A copy outside
# /tmp and /root, which the unit's PrivateTmp and ProtectHome hide.
install -m 0755 "$BIN_BROKEN" /usr/local/lib/salvorias-e2e-broken-node
printf '[Service]\nExecStart=\nExecStart=/bin/sh -c "sleep 3; exec /usr/local/lib/salvorias-e2e-broken-node start"\n' \
  >/etc/systemd/system/salvorias-node.service.d/e2e-fail.conf
systemctl daemon-reload
systemctl stop salvorias-node.service 2>/dev/null || true
systemctl reset-failed salvorias-node.service 2>/dev/null || true
run resume-crash "$SELF" resume --wait-minutes 1
expect_rc 1 "resume reports a daemon that crashes during the watch"
expect_log resume-crash 'started but did not stay up' "crash during the watch explained"
expect_log resume-crash 'broken build: refusing to start' "the journal shown has the crash"
expect_no_log resume-crash 'Salvorias node installed' "no installed summary after the crash"
expect_true "stage is still starting after the crash, so resume can retry" grep -q '^STAGE=starting$' /etc/salvorias/selfhost.conf
rm -f /usr/local/lib/salvorias-e2e-broken-node
rm -rf /etc/systemd/system/salvorias-node.service.d
systemctl daemon-reload
# Clear the failed state, so a pending automatic restart cannot race the resume.
systemctl stop salvorias-node.service 2>/dev/null || true
systemctl reset-failed salvorias-node.service 2>/dev/null || true
run resume "$SELF" resume --wait-minutes 1
expect_rc 0 "second resume starts the service"
expect_log resume 'Salvorias node installed' "summary printed"
expect_log resume 'sudo salvorias-selfhost status' "summary uses salvorias-selfhost forms"
# The mock pins a 1 gwei fee and the node holds 0 SAVDR, so this must warn.
expect_log resume 'below the per-check-in reserve' "low-balance warning (node holds 0 SAVDR)"
expect_true "stage is installed" grep -q '^STAGE=installed$' /etc/salvorias/selfhost.conf

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
data_layout_ok
expect_stat /opt/salvorias/bin/0.0.9/salvorias-node "755 root:root"
expect_stat /etc/systemd/system/salvorias-node.service "644 root:root"
expect_true "PATH symlink -> current" test "$(readlink /usr/local/bin/salvorias-node)" = /opt/salvorias/bin/current/salvorias-node
expect_true "current -> 0.0.9" test "$(readlink /opt/salvorias/bin/current)" = 0.0.9
getent passwd salvorias | sed 's/^/    passwd: /'
expect_true "salvorias is a nologin system user without a home" service_user_ok
expect_true "key file holds exactly one 0x key line" key_file_ok
expect_true "the service user cannot create files in $DATA" bash -c "! runuser -u salvorias -- touch $DATA/e2e-probe 2>/dev/null"
expect_true "the service user can still read its key" runuser -u salvorias -- test -r "$DATA/node-key.txt"
echo "node.env:"; sed 's/^/    | /' /etc/salvorias/node.env
DAEMON_RPC="$(sed -n 's/^RPC_URL=//p' /etc/salvorias/node.env)"
for want in "GAS_PRICE_MODE=network" "MAX_GAS_PRICE_GWEI=50" "EXPECTED_CHAIN_ID=7283" \
    "NODE_KEYS_FILE=/var/lib/salvorias/node-key.txt" "CHECKIN_CONTRACT=$TESTNET_CHECKIN" \
    "TREASURY_CONTRACT=0x7e8ecebF965dE86fDE7Ebc7F3020813d656CF723"; do
  expect_true "node.env has $want" grep -qx "$want" /etc/salvorias/node.env
done
echo "unit file:"; sed 's/^/    | /' /etc/systemd/system/salvorias-node.service
expect_true "unit has no ReadWritePaths" bash -c "! grep -q '^ReadWritePaths' /etc/systemd/system/salvorias-node.service"
expect_true "unit is Type=exec" grep -qx 'Type=exec' /etc/systemd/system/salvorias-node.service

section "9b. the daemon attempts a real check-in; the mock receives and blocks it"
# The service waits up to STARTUP_JITTER (300s) before its first cycle, so
# this runs the installed binary directly, with the service's own node.env,
# as the service user, for one cycle and no jitter. The mock reports a
# 1 SAVDR balance so the daemon has no reason to hold back.
mapfile -t DAEMON_ENV < <(grep -E '^[A-Z_]+=' /etc/salvorias/node.env)
printf '1000000000000000000\n' >"$MOCK_STATE/balance-wei"
blocked_before=$(grep -c '^BLOCKED eth_sendRawTransaction' "$MOCK_STATE/mock-rpc.log" || true)
run checkin-once timeout 240 runuser -u salvorias -- env "${DAEMON_ENV[@]}" STARTUP_JITTER=0 RUN_ONCE=true /usr/local/bin/salvorias-node start
rm -f "$MOCK_STATE/balance-wei"
expect_true "the one-cycle run finished (no timeout)" test "$RC" != 124
expect_log checkin-once 'Gas Price Mode: +network' "network gas mode"
expect_log checkin-once "checkIn\([0-9]+\) from $NODE" "the daemon attempted a check-in"
expect_log checkin-once 'transactions are disabled in this test' "the daemon saw the mock's refusal"
blocked_after=$(grep -c '^BLOCKED eth_sendRawTransaction' "$MOCK_STATE/mock-rpc.log" || true)
TX_LINE="$(grep '^BLOCKED eth_sendRawTransaction' "$MOCK_STATE/mock-rpc.log" | tail -n 1)"
echo "    mock: $TX_LINE"
tx_field() { printf '%s\n' "$TX_LINE" | grep -oE "(^| )$1=[^ ]+" | head -n 1 | cut -d= -f2; }
expect_true "the mock received and blocked a raw transaction" test "$blocked_after" -gt "$blocked_before"
expect_true "chain id 7283" test "$(tx_field chainId)" = 7283
# Testnet blocks carry no base fee, so ethers (and slot-info's feeType) use a
# legacy gasPrice there; on an EIP-1559 chain it is maxFee plus priority fee.
# Either way the fee fields must be non-zero: a zero-fee check-in is what the
# hosted, fee-exempt fleet sends, and a self-hosted wallet must not.
case "$(tx_field type)" in
  0) expect_true "legacy tx: gasPrice is non-zero ($(tx_field gasPrice) wei)" test "$(tx_field gasPrice)" -gt 0 ;;
  2) expect_true "EIP-1559 tx: maxFeePerGas is non-zero" test "$(tx_field maxFeePerGas)" -gt 0
     expect_true "EIP-1559 tx: maxPriorityFeePerGas is non-zero" test "$(tx_field maxPriorityFeePerGas)" -gt 0 ;;
  *) fail "unexpected transaction type '$(tx_field type)'" ;;
esac
expect_true "gas limit 100000" test "$(tx_field gasLimit)" = 100000
expect_true "sent to NodeCheckIn" test "$(tx_field to)" = "${TESTNET_CHECKIN,,}"
expect_true "calls checkIn(uint256)" test "$(tx_field selector)" = 0xe95a644f

section "10. one node per server once installed"
run second-installed bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER"
expect_rc 1 "second install refused"
expect_log second-installed 'Only one node per server' "one-node message"

section "10b. one changing command at a time: a held lock stops install, uninstall and the rest"
LOCK=/run/salvorias-selfhost.lock
expect_stat "$LOCK" "600 root:root"
# A stand-in for a running salvorias-selfhost: a process holding the lock.
( exec 9<>"$LOCK"; flock 9; exec sleep 300 ) &
LOCK_HOLDER=$!
PIDS+=("$LOCK_HOLDER")
for _ in $(seq 1 50); do flock -n "$LOCK" true || break; sleep 0.1; done
expect_true "the lock is held by the stand-in" bash -c "! flock -n $LOCK true"
run locked-install bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER"
expect_rc 4 "install refused while the lock is held"
expect_log locked-install 'Another salvorias-selfhost command is running on this server' "install names the running command"
expect_no_log locked-install 'Only one node per server' "install stopped at the lock, before any other check"
run locked-uninstall "$SELF" uninstall --yes
expect_rc 4 "uninstall --yes refused while the lock is held"
expect_log locked-uninstall 'Another salvorias-selfhost command is running on this server' "uninstall names the running command"
expect_true "uninstall changed nothing: service active, config and unit file there" \
  bash -c 'systemctl is-active --quiet salvorias-node.service && test -f /etc/salvorias/node.env -a -f /etc/systemd/system/salvorias-node.service -a -x /usr/local/sbin/salvorias-selfhost'
run locked-resume "$SELF" resume
expect_rc 4 "resume refused while the lock is held"
run locked-upgrade "$SELF" upgrade --binary "$BIN_NEXT"
expect_rc 4 "upgrade refused while the lock is held"
run locked-rollback "$SELF" upgrade --rollback
expect_rc 4 "upgrade --rollback refused while the lock is held"
run locked-backup "$SELF" backup-key --out /root/locked-backup.txt
expect_rc 4 "backup-key refused while the lock is held"
expect_true "no backup written" test ! -e /root/locked-backup.txt
run locked-status "$SELF" status
expect_rc 0 "status still works while the lock is held (read-only)"
kill "$LOCK_HOLDER" 2>/dev/null || true
wait "$LOCK_HOLDER" 2>/dev/null || true
expect_true "the lock is free again" flock -n "$LOCK" true
expect_true "still at version 0.0.9" test "$(readlink /opt/salvorias/bin/current)" = 0.0.9
# A link at the lock path is refused, never opened.
mv "$LOCK" "$WORK/saved-lock"
ln -s /root/decoy-profile "$LOCK"
run lock-link "$SELF" backup-key --out /root/locked-backup.txt
expect_rc 1 "a link at the lock path is refused"
expect_log lock-link 'salvorias-selfhost.lock is a symbolic link' "the link is named"
expect_true "decoys unchanged by the refused lock link" decoys_unchanged
expect_true "no backup written through the refused lock" test ! -e /root/locked-backup.txt
rm -f "$LOCK"
mv "$WORK/saved-lock" "$LOCK"

section "11. status (unfunded, then funded through the mock)"
run status "$SELF" status
expect_rc 0 "status"
expect_log status 'registered to the owner, slot 1' "status shows the binding"
expect_log status 'Reserve per check-in: .* \(actual fees are lower\)' "status names the reserve"
expect_log status 'Last 20 log lines' "status shows the journal"
printf '1000000000000000000\n' >"$MOCK_STATE/balance-wei"
run status-funded "$SELF" status
rm -f "$MOCK_STATE/balance-wei"
expect_rc 0 "status with a balance"
expect_log status-funded 'Balance: +1 SAVDR' "balance shown in SAVDR"
expect_log status-funded 'Check-ins left: at least about' "check-ins left estimate shown"

section "12. backup-key"
run backup "$SELF" backup-key --out /root/node-key-backup.txt
expect_rc 0 "backup-key"
expect_log backup "Node:  $NODE" "backup names the node, derived from the key"
expect_stat /root/node-key-backup.txt "600 root:root"
expect_true "backup matches the node key" cmp -s /root/node-key-backup.txt "$DATA/node-key.txt"
run backup-again "$SELF" backup-key --out /root/node-key-backup.txt
expect_rc 1 "backup-key refuses to overwrite"
install -d -m 0700 /root/bk-fresh
run backup-fresh "$SELF" backup-key --out /root/bk-fresh/key.txt
expect_rc 0 "backup-key to a fresh path in a new root-only directory"
expect_stat /root/bk-fresh/key.txt "600 root:root"
expect_true "the fresh backup matches the node key" cmp -s /root/bk-fresh/key.txt "$DATA/node-key.txt"
expect_true "no temp file left beside it" test -z "$(find /root/bk-fresh -name '.salvorias-key-backup.*')"
ln -s /root/bk-fresh /root/bk-link
run backup-symdir "$SELF" backup-key --out /root/bk-link/key2.txt
expect_rc 1 "backup-key into a symlinked directory is refused"
expect_log backup-symdir 'is a symbolic link' "explains the link"
expect_true "nothing written through the link" test ! -e /root/bk-fresh/key2.txt
install -d -m 0700 -o nobody /root/bk-user
run backup-userdir "$SELF" backup-key --out /root/bk-user/key.txt
expect_rc 1 "backup-key into a directory another user owns is refused"
expect_log backup-userdir 'not owned by root' "explains the owner"
install -d -m 1777 /root/bk-open
run backup-opendir "$SELF" backup-key --out /root/bk-open/key.txt
expect_rc 1 "backup-key into a world-writable directory is refused"
expect_log backup-opendir 'can be written by users other than root' "explains the mode"
expect_true "nothing written in the refused directories" test -z "$(find /root/bk-user /root/bk-open -mindepth 1)"
shred -u /root/bk-fresh/key.txt
rm -rf /root/bk-fresh /root/bk-link /root/bk-user /root/bk-open

section "12b. links planted in $DATA: backup-key and purge refuse, targets untouched"
for spec in node-key.txt:/root/decoy-profile node-address.txt:/root/decoy-disk; do
  name="${spec%%:*}"; target="${spec#*:}"
  plant "$name" "$target"
  find "$DATA" -mindepth 1 -maxdepth 1 -printf '    %M %u:%g %f -> %l\n'
  run "backup-link-$name" "$SELF" backup-key --out "/root/should-not-exist-$name"
  expect_rc 1 "backup-key refuses with $name planted as a link"
  expect_log "backup-link-$name" 'symbolic link' "backup-key explains ($name)"
  expect_true "no backup written ($name)" test ! -e "/root/should-not-exist-$name"
  run "purge-link-$name" with_tty "uninstall
delete node key
" "$SELF uninstall --purge-key"
  expect_rc 1 "purge refuses with $name planted as a link"
  expect_log "purge-link-$name" 'symbolic link' "purge explains ($name)"
  expect_true "purge changed nothing: service still active ($name)" systemctl is-active --quiet salvorias-node.service
  expect_true "purge changed nothing: config still there ($name)" test -f /etc/salvorias/node.env
  expect_true "decoys unchanged: owner, mode, size, links and hash ($name)" decoys_unchanged
  unplant "$name"
done
ln "$DATA/node-key.txt" /root/e2e-key-hardlink
run backup-hardlink "$SELF" backup-key --out /root/should-not-exist-hardlink
expect_rc 1 "backup-key refuses a key with another hard link"
expect_log backup-hardlink 'has another hard link' "says another hard link exists"
expect_log backup-hardlink "find / -xdev -samefile $DATA/node-key.txt" "suggests how to find it"
rm -f /root/e2e-key-hardlink
data_layout_ok

section "13. upgrade rollback with a broken binary; binaries that are not for this server"
run upgrade-broken "$SELF" upgrade --binary "$BIN_BROKEN"
expect_rc 1 "broken upgrade fails"
expect_log upgrade-broken 'Rolling back to 0.0.9' "rolled back"
expect_log upgrade-broken 'Rolled back to 0.0.9, which is running again' "old version running again"
expect_true "current -> 0.0.9 after rollback" test "$(readlink /opt/salvorias/bin/current)" = 0.0.9
expect_true "broken version dir removed" test ! -e /opt/salvorias/bin/0.0.10-broken
expect_true "service active after rollback" systemctl is-active --quiet salvorias-node.service
expect_no_log upgrade-broken 'changed on disk' "no stale-unit warning: an unchanged unit file is not rewritten"

head -c 4096 /dev/urandom >/root/garbage-node
run upgrade-garbage "$SELF" upgrade --binary /root/garbage-node
expect_rc 1 "random bytes are refused before they run"
expect_log upgrade-garbage 'not a Linux executable' "explains it is not an executable"
run upgrade-wrongarch "$SELF" upgrade --binary /root/wrongarch-node
expect_rc 1 "an ELF for another CPU is refused before it runs"
expect_true "current unchanged" test "$(readlink /opt/salvorias/bin/current)" = 0.0.9

section "13b. Ctrl-C during the upgrade watch switches back"
STEP=$((STEP + 1))
printf '\n--- [%02d] $ salvorias-selfhost upgrade --binary next (60s watch, SIGINT after 12s)\n' "$STEP"
SALVORIAS_UPGRADE_WATCH_SECONDS=60 spawn_sigint_able "$SELF" upgrade --binary "$BIN_NEXT" >"$OUT/upgrade-sigint.log" 2>&1 &
pid=$!
sleep 12
# The upgrade is in its watch now, holding the lock: a real concurrent run.
run during-upgrade "$SELF" uninstall --yes
expect_rc 4 "uninstall refused while an upgrade is running"
expect_log during-upgrade 'Another salvorias-selfhost command is running' "names the running upgrade"
kill -INT -- "-$pid" 2>/dev/null || echo "    (upgrade had already exited before the signal)"
set +e; wait "$pid"; RC=$?; set -e
sed 's/^/    | /' "$OUT/upgrade-sigint.log"; printf '    (exit %s)\n' "$RC"
expect_rc 130 "interrupted upgrade exits 130"
expect_log upgrade-sigint 'Switching from 0.0.9 to 0.0.10' "the switch had happened"
expect_log upgrade-sigint 'Switched back to 0.0.9, which is running' "switched back on the interrupt"
expect_true "current -> 0.0.9 after the interrupt" test "$(readlink /opt/salvorias/bin/current)" = 0.0.9
expect_true "the interrupted version dir removed" test ! -e /opt/salvorias/bin/0.0.10
expect_true "service active after the interrupt" systemctl is-active --quiet salvorias-node.service

section "14. upgrade from a release; stopped service; upgrade --rollback"
run upgrade-ok env SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8001 "$SELF" upgrade
expect_rc 0 "upgrade to the next build"
expect_log upgrade-ok 'Checksum verified' "release binary verified"
NEXT_VERSION="$("$BIN_NEXT" version | sed 's/^salvorias-node v//')"
expect_true "current -> $NEXT_VERSION" test "$(readlink /opt/salvorias/bin/current)" = "$NEXT_VERSION"
expect_true "previous -> 0.0.9" test "$(readlink /opt/salvorias/bin/previous)" = 0.0.9
expect_true "previous version kept for rollback" test -x /opt/salvorias/bin/0.0.9/salvorias-node
expect_true "service active on the new version" systemctl is-active --quiet salvorias-node.service
expect_true "salvorias-selfhost refreshed from the release" cmp -s "$SELF" "$WORK/rel-next/install.sh"
run upgrade-same env SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8001 "$SELF" upgrade
expect_rc 0 "upgrade to the same binary"
expect_log upgrade-same 'Already running this binary' "no-op when already current and running"
expect_no_log upgrade-same 'Updated /etc/systemd/system' "the unchanged unit file is left alone"
systemctl stop salvorias-node.service
run upgrade-stopped env SALVORIAS_RELEASE_BASE_URL=http://127.0.0.1:8001 "$SELF" upgrade
expect_rc 0 "upgrade with the service stopped"
expect_log upgrade-stopped 'service is not running. Restarting it' "restarts instead of 'nothing to do'"
expect_no_log upgrade-stopped 'Nothing to do' "does not claim there is nothing to do"
expect_true "service active again" systemctl is-active --quiet salvorias-node.service
run rollback env SALVORIAS_UPGRADE_WATCH_SECONDS=10 "$SELF" upgrade --rollback
expect_rc 0 "upgrade --rollback"
expect_log rollback "Rolled back to 0.0.9" "rolled back to the kept version"
expect_true "current -> 0.0.9" test "$(readlink /opt/salvorias/bin/current)" = 0.0.9
expect_true "previous -> $NEXT_VERSION (a second --rollback goes forward)" test "$(readlink /opt/salvorias/bin/previous)" = "$NEXT_VERSION"
expect_true "service active after --rollback" systemctl is-active --quiet salvorias-node.service

section "14b. an install in the old layout (salvorias-owned 0700 data dir, ReadWritePaths) is migrated"
old_layout() {
  chown salvorias:salvorias "$DATA" "$DATA/node-address.txt"
  chmod 0700 "$DATA"
  grep -q '^ReadWritePaths' /etc/systemd/system/salvorias-node.service \
    || sed -i 's|^PrivateTmp=true$|PrivateTmp=true\nReadWritePaths=/var/lib/salvorias|' /etc/systemd/system/salvorias-node.service
  systemctl daemon-reload
}
old_layout
ln -s /root/decoy-profile "$DATA/stray-link"
run migrate-planted "$SELF" upgrade --binary "$BIN"
expect_rc 1 "a planted link in the old data dir stops the migration"
expect_log migrate-planted 'contains a symbolic link or special file \(stray-link\)' "names the planted entry"
expect_true "decoys unchanged after the refused migration" decoys_unchanged
rm -f "$DATA/stray-link"
old_layout
run migrate "$SELF" upgrade --binary "$BIN"
expect_rc 0 "upgrade migrates the old layout"
expect_log migrate 'Updated /etc/systemd/system/salvorias-node.service to the current layout' "unit file updated"
expect_log migrate 'Restarting the service to apply the updated unit file' "restarted to apply it"
data_layout_ok
expect_true "unit has no ReadWritePaths after the migration" bash -c "! grep -q '^ReadWritePaths' /etc/systemd/system/salvorias-node.service"
expect_true "service active after the migration" systemctl is-active --quiet salvorias-node.service

section "15. uninstall (keeps the key); planted links stop a reinstall; then reinstall reuses the key"
run uninstall-notty setsid -w "$SELF" uninstall
expect_rc 2 "uninstall without a terminal and without --yes is refused"
install -d -m 0700 "$DATA/.stage.e2ekeep"
printf 'e2e: not a key\n' >"$DATA/.stage.e2ekeep/node-key.txt"
run uninstall-keep "$SELF" uninstall --yes
expect_rc 0 "uninstall --yes"
expect_true "a staging directory left in $DATA is removed" test ! -e "$DATA/.stage.e2ekeep"
expect_log uninstall-keep 'clear it in the Salvorias app' "slot reminder"
expect_true "service, config, binaries and salvorias-selfhost removed" \
  bash -c '[[ ! -e /etc/systemd/system/salvorias-node.service && ! -e /etc/salvorias && ! -e /opt/salvorias && ! -e /usr/local/bin/salvorias-node && ! -e /usr/local/sbin/salvorias-selfhost ]]'
expect_stat "$DATA/node-key.txt" "600 salvorias:salvorias"
expect_true "service is gone from systemd" bash -c '! systemctl cat salvorias-node.service >/dev/null 2>&1'
expect_stat "$DATA/installer-account.txt" "600 root:root"
expect_true "the kept account is marked as the installer's, by UID" test "$(cat "$DATA/installer-account.txt")" = "UID=$(id -u salvorias)"
for spec in node-key.txt:/root/decoy-profile node-address.txt:/root/decoy-disk; do
  name="${spec%%:*}"; target="${spec#*:}"
  plant "$name" "$target"
  run "reinstall-link-$name" bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER"
  expect_rc 1 "reinstall refuses with $name planted as a link"
  expect_log "reinstall-link-$name" 'symbolic link' "reinstall explains ($name)"
  expect_true "nothing installed by the refused reinstall ($name)" test ! -e /etc/salvorias -a ! -e /opt/salvorias
  expect_true "decoys unchanged: owner, mode, size, links and hash ($name)" decoys_unchanged
  unplant "$name"
done
run reinstall-reuse bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER"
expect_rc 0 "reinstall with the kept key"
expect_log reinstall-reuse "kept by an earlier uninstall: $NODE" "kept key reused"
expect_log reinstall-reuse 'already registered to this wallet' "registration wait skipped"
expect_no_log reinstall-reuse 'REGISTER THIS NODE' "no registration box"
expect_log reinstall-reuse 'Using the system user salvorias that this installer created for an earlier install' "the kept account is known to be the installer's"
expect_true "state still records the account as created by the installer" grep -qx 'ACCOUNT_CREATED=yes' /etc/salvorias/selfhost.conf
expect_true "salvorias-selfhost installed from the running file" cmp -s "$SELF" "$INSTALL"
expect_true "service active" systemctl is-active --quiet salvorias-node.service
data_layout_ok

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
expect_log purge 'It also deletes the salvorias system user, which this installer created' "purge says up front it deletes the installer's account"
expect_log purge 'Deleted the salvorias user' "the installer-created account is deleted"
expect_true "nothing left after purge" nothing_installed

section "17. install --import-key (server migration)"
cp /root/node-key-backup.txt /root/import-open.txt
chmod 0644 /root/import-open.txt
run import-open bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER" --import-key /root/import-open.txt
expect_rc 2 "world-readable key file refused"
expect_log import-open 'readable by other users' "explains the permission problem"
ln -sfn /root/node-key-backup.txt /root/import-link.txt
run import-link bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER" --import-key /root/import-link.txt
expect_rc 2 "a link as --import-key is refused"
expect_log import-link 'is a symbolic link' "explains the link"
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
expect_true "imported key normalised to the keygen format" cmp -s "$DATA/node-key.txt" /root/node-key-backup.txt
data_layout_ok
expect_true "service active" systemctl is-active --quiet salvorias-node.service

section "17b. import with a key kept by an uninstall: same key in another format is fine, a different key is not"
mkdir -p /etc/systemd/system/salvorias-node.service.d
printf '[Unit]\nRefuseManualStop=yes\n' >/etc/systemd/system/salvorias-node.service.d/e2e-refuse.conf
systemctl daemon-reload
run uninstall-refused "$SELF" uninstall --yes
expect_rc 1 "uninstall fails when the service will not stop"
expect_log uninstall-refused 'is still running \(state: active\)' "says the service is still running"
expect_no_log uninstall-refused 'Removed' "reports nothing as removed"
expect_true "nothing removed: config, unit file and salvorias-selfhost still there" \
  test -f /etc/salvorias/node.env -a -f /etc/systemd/system/salvorias-node.service -a -x "$SELF"
expect_true "service still active" systemctl is-active --quiet salvorias-node.service
rm -rf /etc/systemd/system/salvorias-node.service.d
systemctl daemon-reload
# The unit file disappears while the service stays loaded and running.
mv /etc/systemd/system/salvorias-node.service "$WORK/saved-unit"
expect_true "service still active with its unit file gone" systemctl is-active --quiet salvorias-node.service
run uninstall-keep-2 "$SELF" uninstall --yes
expect_rc 0 "uninstall --yes with the unit file gone (keeps the key)"
expect_log uninstall-keep-2 'Stopped and removed the service' "reports the service removed"
expect_true "the loaded service was stopped" bash -c '! systemctl is-active --quiet salvorias-node.service'
expect_true "systemd no longer has the unit" test "$(systemctl show -p LoadState --value salvorias-node.service)" = not-found
expect_true "no boot link left" test ! -L /etc/systemd/system/multi-user.target.wants/salvorias-node.service
expect_true "no process runs as salvorias" bash -c '! pgrep -u salvorias >/dev/null'
rm -f "$WORK/saved-unit"
"$BIN" keygen --out /root/import-other.txt >/dev/null
run import-other bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER" --import-key /root/import-other.txt
expect_rc 1 "a different key is refused"
expect_log import-other 'A different node key' "explains the conflict"
expect_true "nothing installed by the refused import" test ! -e /etc/salvorias
( umask 077; sed 's/^0x//' /root/node-key-backup.txt | tr -d '\n' | tr 'a-f' 'A-F' | sed 's/^/0x/' >/root/import-upper.txt )
expect_true "the re-import file differs byte-for-byte from the kept key" bash -c "! cmp -s /root/import-upper.txt $DATA/node-key.txt"
run import-same bash "$INSTALL" --network testnet --rpc-url "$MOCK_RPC" --binary "$BIN" --owner "$OWNER" --import-key /root/import-upper.txt
expect_rc 0 "the same key in upper-case hex is accepted"
expect_log import-same 'same key as the one kept' "recognised as the same key by address"
expect_true "kept key file unchanged" cmp -s "$DATA/node-key.txt" /root/node-key-backup.txt
data_layout_ok
expect_true "service active" systemctl is-active --quiet salvorias-node.service
journalctl -u salvorias-node.service --no-pager -n 400 >"$OUT/journal-final.log" 2>&1 || true

section "18. final purge, with leftovers of an interrupted run"
printf 'e2e stray\n' >/usr/local/sbin/.salvorias-selfhost.e2eXYZ
printf 'e2e stray\n' >/etc/systemd/system/.salvorias-node.service.e2eXYZ
install -d -m 0700 "$DATA/.stage.e2eXYZ"
printf 'e2e: not a key\n' >"$DATA/.stage.e2eXYZ/node-key.txt"
# The installer's account is replaced by a hand-made one with the same name
# (different UID) before the purge: the recorded UID no longer matches, so
# the purge must keep the replacement.
systemctl stop salvorias-node.service
old_uid=$(id -u salvorias)
userdel salvorias
new_uid=$((old_uid - 1))
while getent passwd "$new_uid" >/dev/null || getent group "$new_uid" >/dev/null; do new_uid=$((new_uid - 1)); done
useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin -u "$new_uid" salvorias
expect_true "replacement account has a different UID" test "$(id -u salvorias)" != "$old_uid"
run purge-final with_tty "uninstall
delete node key
" "$SELF uninstall --purge-key"
expect_rc 0 "final purge"
expect_log purge-final 'Removed 3 file\(s\) left by an interrupted run' "leftovers reported"
expect_log purge-final 'Kept the salvorias user: it is not the account this installer created' "a replacement account with another UID is kept"
expect_no_log purge-final 'Deleted the salvorias user' "the replacement account is not deleted"
expect_true "replacement account still exists" test "$(id -u salvorias 2>/dev/null)" == "$new_uid"
userdel salvorias
expect_true "leftover temp files removed" \
  test ! -e /usr/local/sbin/.salvorias-selfhost.e2eXYZ -a ! -e /etc/systemd/system/.salvorias-node.service.e2eXYZ
expect_true "server clean" nothing_installed

section "19. no transactions, no key in any output"
blocked=$(grep -c '^BLOCKED' "$MOCK_STATE/mock-rpc.log" || true)
mocked=$(grep -c '^MOCKED' "$MOCK_STATE/mock-rpc.log" || true)
faithful_blocked=$(grep -c '^BLOCKED' "$FAITHFUL_STATE/mock-rpc.log" || true)
echo "mock-rpc: $mocked mocked reads, $blocked transaction attempts blocked (faithful mock: $faithful_blocked)"
grep '^BLOCKED' "$MOCK_STATE/mock-rpc.log" "$FAITHFUL_STATE/mock-rpc.log" | sort | uniq -c | sed 's/^/    /' || true
expect_true "the daemon was configured with the mock as its only RPC" test "$DAEMON_RPC" = "$MOCK_RPC"
# Until section 8 no daemon had ever used this mock, so anything blocked by
# then would have come from the installer itself.
before_daemon=$(head -n "$MOCK_LINES_AT_START" "$MOCK_STATE/mock-rpc.log" | grep -c '^BLOCKED' || true)
expect_true "the installer itself never tried to send a transaction" test "$before_daemon" = 0
# Read from the real testnet, not a mock: a node wallet that ever had a
# transaction mined would have a nonce above 0.
nonce_of() {
  curl --proto '=https' -fsS --max-time 20 -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionCount\",\"params\":[\"$1\",\"latest\"]}" "$TESTNET_RPC" \
    | sed -n 's/.*"result" *: *"\(0x[0-9a-fA-F]*\)".*/\1/p'
}
for n in "$NODE" "$FNODE"; do
  got="$(nonce_of "$n")"
  echo "    testnet nonce of $n: ${got:-unreadable}"
  expect_true "no transaction from $n ever reached testnet (nonce 0)" test "$got" = 0x0
done
if grep -rl 'changed on disk' "$OUT" >/dev/null; then
  fail "a stale-unit warning appears in: $(grep -rl 'changed on disk' "$OUT" | xargs -n1 basename | tr '\n' ' ')"
else
  pass "no 'unit file changed on disk' warning in any captured output"
fi
KEYHEX="$(sed 's/^0x//' /root/node-key-backup.txt)"
OTHERHEX="$(sed 's/^0x//' /root/import-other.txt)"
if grep -rqiF -e "$KEYHEX" -e "$OTHERHEX" "$OUT"; then fail "a node key appears in captured output"; else pass "no node key in any captured output or journal"; fi
if grep -rqiF -- "$FAKE_SECRET" "$OUT"; then fail "the fake typed key appears in a captured log"; else pass "the fake typed key appears in no captured log (masked before display)"; fi
KEYHEX=""
OTHERHEX=""
shred -u /root/node-key-backup.txt /root/import-*.txt 2>/dev/null || true
rm -f /root/import-link.txt

printf '\n\nRESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
