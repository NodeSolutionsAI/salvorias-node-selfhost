#!/usr/bin/env bash
# Unit tests for install.sh's pure helpers: wei formatting and comparison,
# the cleaning of text from outside (RPC errors, chain data, the journal), the
# proof of ownership that gates the fixed paths and the salvorias account,
# the funding text and box order, the first check-in parsing and watch, URL
# and repo validation, checksums.txt parsing, the ELF
# header check, the version-name pattern and an interrupt during the
# upgrade's switch back. The functions (and the regex variables they use) are
# extracted from install.sh by name, so main never runs and nothing on the
# system is touched.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Prints one top-level function from install.sh (one-liners included).
extract() {
  awk -v n="$1" '
    index($0, n "() {") == 1 { p = 1; print; if ($0 ~ /}$/ && $0 !~ /\{$/) exit; next }
    p { print; if ($0 ~ /^}/) exit }' install.sh
}
# Prints one top-level NAME=value assignment from install.sh.
extract_var() { grep -m 1 "^$1=" install.sh; }

src=""
for var in URL_PORT_RE URL_PATH_RE LOCAL_HTTP_RE HTTPS_URL_RE REPO_RE VERSION_LINE_SED NODE_RUN_PATH ACTIVE_NOTE; do
  body=$(extract_var "$var")
  [[ -n "$body" ]] || { echo "FAIL: could not extract $var from install.sh"; exit 1; }
  src+="$body"$'\n'
done
for fn in clean_text say lower strip_zeros wei_lt warn wei_to_savdr is_uint json_str json_raw json_list \
    read_binding print_funding warn_if_unfunded is_local_http_url is_safe_url is_safe_repo checksum_for check_elf node_run \
    rule has_balance print_node_address print_setup_boxes print_funding_box missing_steps \
    first_checkin_outcome checkin_failure_reason print_first_checkin; do
  body=$(extract "$fn")
  [[ -n "$body" ]] || { echo "FAIL: could not extract $fn from install.sh"; exit 1; }
  src+="$body"$'\n'
done
eval "$src"

fails=0
check() {
  if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}
check_true() { if "${@:2}"; then echo "PASS: $1"; else echo "FAIL: $1"; fails=$((fails + 1)); fi; }
check_false() { if "${@:2}"; then echo "FAIL: $1"; fails=$((fails + 1)); else echo "PASS: $1"; fi; }
check_has() {
  if [[ "$2" == *"$3"* ]]; then echo "PASS: $1"; else echo "FAIL: $1: '$3' not in output"; fails=$((fails + 1)); fi
}
check_lacks() {
  if [[ "$2" == *"$3"* ]]; then echo "FAIL: $1: '$3' should not be in output"; fails=$((fails + 1)); else echo "PASS: $1"; fi
}

echo "## wei arithmetic"
check "0 wei" "$(wei_to_savdr 0)" "0"
check "leading zeros" "$(wei_to_savdr 000)" "0"
check "1 wei" "$(wei_to_savdr 1)" "0.000000000000000001"
check "1 SAVDR" "$(wei_to_savdr 1000000000000000000)" "1"
check "mainnet check-in reserve" "$(wei_to_savdr 212500000000000)" "0.0002125"
check "above 64-bit" "$(wei_to_savdr 123456789000000000000)" "123.456789"
check_true "5 < 10" wei_lt 5 10
check_false "10 < 5" wei_lt 10 5
check_false "10 < 10" wei_lt 10 10
check_true "compare above 64-bit" wei_lt 99999999999999999999 100000000000000000000
check_false "leading zeros ignored" wei_lt 0010 9

echo "## whole numbers (they go into bash arithmetic, where 08 is invalid octal)"
check_true "0 is a whole number" is_uint 0
check_true "8 is a whole number" is_uint 8
check_true "10 is a whole number" is_uint 10
check_true "a 30-digit wei amount is a whole number" is_uint 123456789012345678901234567890
check_false "08 is refused" is_uint 08
check_false "010 is refused" is_uint 010
check_false "00 is refused" is_uint 00
check_false "empty is refused" is_uint ""
check_false "-1 is refused" is_uint -1
check_false "1a is refused" is_uint 1a
check_false "' 1' is refused" is_uint " 1"
# Every value is_uint accepts must work in arithmetic, which 08 did not:
# 0 to 120, with and without a leading zero.
bad=""
for n in $(seq 0 120); do
  for v in "$n" "0$n"; do
    if is_uint "$v" && ! (bash -c "(( $v >= 0 ))") 2>/dev/null; then bad+="$v "; fi
  done
done
check "accepted values all work in arithmetic" "$bad" ""

echo "## funding text"
# The slot-info --node object returned by mainnet (max fee 2.125 gwei).
# shellcheck disable=SC2034
SLOT_JSON='{"chainId":7282,"node":"0x6c444c60Ede77B5cEd767467b676160c9F564E97","boundOwner":null,"boundSlot":null,"nodeBalanceWei":"0","checkInGasLimit":100000,"feeType":"eip1559","feePerGasWei":"2125000000","estimatedCheckInCostWei":"212500000000000"}'
out=$(print_funding)
printf '%s\n' "$out" | sed 's/^/    | /'
# The same text whatever the fee: the old wording called a zero fee free.
FUND_WANT_1="Send 1 SAVDR to the NODE address above. The node pays a tiny fee for each"
FUND_WANT_2="daily check-in, so 1 SAVDR will last a while. An address with no SAVDR"
FUND_WANT_3="cannot check in at all, even when fees are zero."
FUND_WANT_4="Your wallet also needs a little SAVDR (0.01 is plenty) to send the"
check_has "send 1 SAVDR to the node" "$out" "$FUND_WANT_1"
check_has "1 SAVDR will last a while" "$out" "$FUND_WANT_2"
check_has "an unfunded address cannot check in" "$out" "$FUND_WANT_3"
check_has "the wallet needs a little SAVDR" "$out" "$FUND_WANT_4"
check_has "balance" "$out" "Current node balance: 0 SAVDR"
check_lacks "no per-check-in reserve" "$out" "reserve"
check_lacks "no 90-day suggestion" "$out" "90"
check_lacks "no cap math" "$out" "gwei"

# shellcheck disable=SC2034
SLOT_JSON='{"nodeBalanceWei":"1500000000000000000","checkInGasLimit":100000,"feePerGasWei":"0","estimatedCheckInCostWei":"0"}'
out=$(print_funding)
check_lacks "fee 0: 'cost nothing today' is gone" "$out" "cost nothing"
check_lacks "fee 0: no 'network fee is 0 right now'" "$out" "network fee is 0 right now"
check_has "fee 0: send 1 SAVDR" "$out" "$FUND_WANT_1"
check_has "fee 0: unfunded cannot check in" "$out" "$FUND_WANT_3"
check_has "fee 0: wallet line" "$out" "$FUND_WANT_4"
check_has "balance is shown in SAVDR" "$out" "Current node balance: 1.5 SAVDR"
check_lacks "the install script no longer says 'cost nothing today'" "$(cat install.sh)" "cost nothing today"
check_lacks "the install script makes no claim about years" "$(cat install.sh)" "for years"
check_lacks "the README makes no claim about years" "$(cat README.md)" "for years"

echo "## the unfunded warning"
NODE_ADDRESS="0x6c444c60Ede77B5cEd767467b676160c9F564E97"
WARN_WANT="This node will not check in until it holds some SAVDR. Send 1 SAVDR to $NODE_ADDRESS."
check_has "zero balance, fee 0: warns" "$(warn_if_unfunded 0 0 2>&1)" "$WARN_WANT"
check_has "zero balance, fee non-zero: warns" "$(warn_if_unfunded 0 212500000000000 2>&1)" "$WARN_WANT"
check_has "zero balance, cost unreadable: warns" "$(warn_if_unfunded 0 "" 2>&1)" "$WARN_WANT"
check "1 SAVDR, fee 0: silent" "$(warn_if_unfunded 1000000000000000000 0 2>&1)" ""
check "1 SAVDR, non-zero fee: silent" "$(warn_if_unfunded 1000000000000000000 212500000000000 2>&1)" ""
check_has "below the reserve: still warns" "$(warn_if_unfunded 100 212500000000000 2>&1)" "below the per-check-in reserve (0.0002125 SAVDR"
check_lacks "below the reserve is not the zero warning" "$(warn_if_unfunded 100 212500000000000 2>&1)" "$WARN_WANT"
check "balance unreadable: silent" "$(warn_if_unfunded "" 0 2>&1)" ""

echo "## URL rules"
for u in https://salvorias.net https://testnet.salvorias.net https://rpc.example.com:8443/v1/abc-123 \
    https://github.com/NodeSolutionsAI/salvorias-node-selfhost/releases/download/v0.1.0 \
    "https://rpc.example.com/?key=abc&x=1" http://127.0.0.1:8545 http://127.0.0.1 http://localhost/rpc http://localhost:8000; do
  check_true "accepted: $u" is_safe_url "$u"
done
for u in http://example.com http://localhost:1@evil.example/ http://localhost@evil.example/ \
    http://localhost.evil.example/ http://127.0.0.1.evil.example/ https://user@salvorias.net/ \
    https://user:pw@salvorias.net/ "https://salvorias.net/a%0a" "https://salvorias.net/\"x" \
    "https://salvorias.net/\$(id)" "https://salvorias.net/a b" $'https://salvorias.net/\nX=1' \
    "https://salvorias.net/a\\b" ftp://salvorias.net "" "https://" "https://-bad.example"; do
  check_false "rejected: $(printf '%q' "$u")" is_safe_url "$u"
done
check_true "local http recognised" is_local_http_url http://127.0.0.1:8545
check_false "https is not local http" is_local_http_url https://127.0.0.1:8545

echo "## release repo"
check_true "default repo" is_safe_repo NodeSolutionsAI/salvorias-node-selfhost
check_true "dots and underscores" is_safe_repo my_org.x/repo-1.2
for r in "a/b/c" "a b/c" "a/b%n" $'a/b\nX' "a/" "/b" "a/b'" "a/\$b"; do
  check_false "repo rejected: $(printf '%q' "$r")" is_safe_repo "$r"
done

echo "## checksums.txt parsing"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
H1="$(printf 'a%.0s' {1..64})"
H2="$(printf 'b%.0s' {1..64})"
: >"$T/empty"
check_false "empty checksums.txt" checksum_for salvorias-node-linux-x64 "$T/empty"
printf '%s  install.sh\n' "$H1" >"$T/missing"
check_false "missing entry" checksum_for salvorias-node-linux-x64 "$T/missing"
printf '%s *salvorias-node-linux-x64\n' "$H1" >"$T/star"
check "binary-mode *name entry" "$(checksum_for salvorias-node-linux-x64 "$T/star")" "$H1"
printf '%s  install.sh\r\n%s  salvorias-node-linux-x64\r\n' "$H2" "$H1" >"$T/crlf"
check "CRLF line endings" "$(checksum_for salvorias-node-linux-x64 "$T/crlf")" "$H1"
check "CRLF, other entry" "$(checksum_for install.sh "$T/crlf")" "$H2"
printf '%s  salvorias-node-linux-x64\n' "${H1^^}" >"$T/upper"
check "upper-case hash normalised" "$(checksum_for salvorias-node-linux-x64 "$T/upper")" "$H1"
printf '%s  salvorias-node-linux-x64\n%s  salvorias-node-linux-x64\n' "$H1" "$H2" >"$T/conflict"
check_false "two different entries for one file" checksum_for salvorias-node-linux-x64 "$T/conflict"
printf '%s  salvorias-node-linux-x64\n%s *salvorias-node-linux-x64\n' "$H1" "$H1" >"$T/dup"
check "the same entry twice" "$(checksum_for salvorias-node-linux-x64 "$T/dup")" "$H1"
printf '%s  salvorias-node-linux-x64.sig\n%s  old/salvorias-node-linux-x64\n' "$H1" "$H2" >"$T/near"
check_false "near-miss names do not match" checksum_for salvorias-node-linux-x64 "$T/near"
printf 'nothex  salvorias-node-linux-x64\n' >"$T/junk"
check_false "a non-hash value" checksum_for salvorias-node-linux-x64 "$T/junk"

echo "## ELF header check"
# 20-byte headers: magic, class 2 (64-bit), data 1 (LE), then e_machine at 18.
elf() { printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000%b' "$1"; }
elf '\267\000' >"$T/arm64"
elf '\076\000' >"$T/x64"
printf '\177ELF\001\001\001\000\000\000\000\000\000\000\000\000\002\000\050\000' >"$T/arm32"
printf '#!/bin/sh\necho salvorias-node v1\n' >"$T/script"
: >"$T/empty-bin"
# shellcheck disable=SC2034
ASSET_ARCH=linux-arm64
check_true "arm64 ELF on arm64" check_elf "$T/arm64"
check_false "x86-64 ELF on arm64" check_elf "$T/x64"
check_has "wrong CPU named" "$ELF_PROBLEM" "another CPU"
check_false "32-bit ELF" check_elf "$T/arm32"
check_false "shell script" check_elf "$T/script"
check_has "script explained" "$ELF_PROBLEM" "no ELF header"
check_false "empty file" check_elf "$T/empty-bin"
# shellcheck disable=SC2034
ASSET_ARCH=linux-x64
check_true "x86-64 ELF on x86-64" check_elf "$T/x64"
check_false "arm64 ELF on x86-64" check_elf "$T/arm64"

echo "## version names (they become directories under /opt/salvorias/bin)"
version_of() { printf '%s\n' "$1" | sed -n "$VERSION_LINE_SED" | head -n 1; }
check "a release version" "$(version_of 'salvorias-node v0.0.9')" "0.0.9"
check "a build suffix" "$(version_of 'salvorias-node v0.0.10-broken')" "0.0.10-broken"
check "'..' is not a version" "$(version_of 'salvorias-node v..')" ""
check "a leading dot is not a version" "$(version_of 'salvorias-node v.hidden')" ""
check "a leading dash is not a version" "$(version_of 'salvorias-node v-rf')" ""
check "a slash is not a version" "$(version_of 'salvorias-node v0/../x')" ""

echo "## slot-info's openSlots list: a missing key is not an empty list"
SLOT_JSON='{"chainId":7283,"licenseBalance":2,"openSlots":[0,1]}'
check "two free" "$(json_list openSlots)" "0,1"
check_true "a list reads" eval 'json_list openSlots >/dev/null'
SLOT_JSON='{"chainId":7283,"licenseBalance":2,"openSlots":[]}'
check "none free" "$(json_list openSlots)" ""
check_true "an empty list reads (no free license is not an error)" eval 'json_list openSlots >/dev/null'
SLOT_JSON='{"chainId":7283,"licenseBalance":2}'
check_false "a missing openSlots fails" json_list openSlots
SLOT_JSON='{"chainId":7283,"licenseBalance":2,"xopenSlots":[]}'
check_false "another key ending in openSlots does not count" json_list openSlots
SLOT_JSON='{"chainId":7283,"openSlots":["0"]}'
check_false "a list of strings fails" json_list openSlots
SLOT_JSON='{"chainId":7283,"openSlots":null}'
check_false "null fails" json_list openSlots
SLOT_JSON='{"chainId":7283,"openSlots":[0,,1]}'
check_false "a malformed list fails" json_list openSlots
SLOT_JSON='{"error":"RPC down"}'
check_false "an error object fails" json_list openSlots
# read_open_slots must stop on a missing list rather than go on as if every
# license had a node. Run in a child shell with the real function and a
# stand-in die that exits as the installer's does.
open_slots_of() {
  local json="$1"
  # The quoted lines are the child shell's own code.
  # shellcheck disable=SC2016
  { printf '%s\n' 'set -euo pipefail' 'die() { printf "DIE: %s\n" "$*"; exit 1; }'
    extract json_list
    extract read_open_slots
    printf 'SLOT_JSON=%q\n' "$json"
    printf '%s\n' 'read_open_slots' 'printf "OPEN=[%s]\n" "$OPEN_SLOTS"'
  } | bash
}
open_rc=0
open_out=$(open_slots_of '{"chainId":7283,"licenseBalance":2}') || open_rc=$?
check "a missing openSlots stops the install" "$open_rc" "1"
check_has "with a clear message" "$open_out" "DIE: The chain query returned no readable list of free licenses"
check_lacks "and never reaches the no-free-license path" "$open_out" "OPEN="
check "an empty list goes on, as no free license" "$(open_slots_of '{"openSlots":[]}')" "OPEN=[]"
check "a list goes on" "$(open_slots_of '{"openSlots":[1]}')" "OPEN=[1]"

echo "## registered means bound to a license entry, not only named by nodeToOwner"
# Read by read_binding.
# shellcheck disable=SC2034
OWNER="0x00000000000000000000000000000000000000Aa"
OTHER="0x00000000000000000000000000000000000000bB"
# SLOT_JSON and BOUND_OTHER are read and set by read_binding.
# shellcheck disable=SC2034
binding_of() { SLOT_JSON="$1"; BOUND_STATE=""; BOUND_OTHER=""; read_binding; printf '%s' "$BOUND_STATE"; }
check "owner (any case) and slot 0: registered" "$(binding_of '{"boundOwner":"0x00000000000000000000000000000000000000aA","boundSlot":0,"boundSlotSource":"getter"}')" "owner"
check "owner and slot 3: registered" "$(binding_of '{"boundOwner":"'"$OWNER"'","boundSlot":3,"boundSlotSource":"scan"}')" "owner"
check "owner, slot null: replaced, not registered" "$(binding_of '{"boundOwner":"'"$OWNER"'","boundSlot":null,"boundSlotSource":null}')" "replaced"
check "owner, no boundSlot key: not registered" "$(binding_of '{"boundOwner":"'"$OWNER"'"}')" "replaced"
check "no owner: unbound" "$(binding_of '{"boundOwner":null,"boundSlot":null}')" "unbound"
check "another wallet: other" "$(binding_of '{"boundOwner":"'"$OTHER"'","boundSlot":null}')" "other"

echo "## the node binary runs with a scrubbed environment"
# A stand-in binary that prints its environment and working directory. The
# quoted $(pwd) is the stand-in's own code, expanded when it runs.
# shellcheck disable=SC2016
printf '#!/bin/sh\nenv\necho "CWD=$(pwd)"\n' >"$T/env-node"
chmod 0755 "$T/env-node"
scrubbed=$(cd "$T" && NFT_CONTRACT=0x000000000000000000000000000000000000dEaD CHECKIN_CONTRACT=junk \
  RPC_URL=http://junk NODE_KEYS_FILE=/junk SALVORIAS_NODE_VERSION=6.6.6 node_run 10 "$T/env-node")
check_lacks "NFT_CONTRACT is not passed on" "$scrubbed" "NFT_CONTRACT"
check_lacks "CHECKIN_CONTRACT is not passed on" "$scrubbed" "CHECKIN_CONTRACT"
check_lacks "RPC_URL is not passed on" "$scrubbed" "RPC_URL"
check_lacks "NODE_KEYS_FILE is not passed on" "$scrubbed" "NODE_KEYS_FILE"
check_lacks "SALVORIAS_NODE_VERSION is not passed on" "$scrubbed" "SALVORIAS_NODE_VERSION"
check_has "PATH is set" "$scrubbed" "PATH=$NODE_RUN_PATH"
check_has "HOME is set" "$scrubbed" "HOME=/root"
check_has "it runs from /, away from any .env in the caller's directory" "$scrubbed" "CWD=/"
# sh itself adds PWD (and some shells SHLVL and _); nothing else may appear.
check "nothing else is passed" "$(printf '%s\n' "$scrubbed" | grep -cv '^\(PATH\|HOME\|PWD\|OLDPWD\|SHLVL\|_\|CWD\)=' || true)" "0"

echo "## an interrupt during the upgrade's switch back"
# The real on_signal and undo_upgrade, with a switch_current slowed down so
# the interrupt lands inside it. The handler must still switch back: the run
# has to end on old-good, never on the failed version.
# The quoted lines are the test script's own code, expanded when it runs.
# shellcheck disable=SC2016
{
  printf '%s\n' 'set -euo pipefail' "OUTF=$T/sig.out" 'CUR=new-broken' \
    'switch_current() { sleep 2; CUR="$1"; }' 'systemctl() { :; }' 'service_stays_up() { return 0; }' \
    'current_version_name() { printf "%s" "$CUR"; }' 'cmd_hint() { printf x; }' \
    'BIN_ROOT=/nonexistent UNIT_NAME=u INTERRUPT_HINT=""' \
    'UPGRADE_ROLLBACK_TO=old-good UPGRADE_PLACED=new-broken UPGRADE_PLACED_NEW=0'
  extract on_signal
  extract undo_upgrade
  printf '%s\n' 'trap '"'"'printf "%s\n" "$CUR" >"$OUTF"'"'"' EXIT' 'trap on_signal INT TERM HUP' 'undo_upgrade'
} >"$T/sig.sh"
bash "$T/sig.sh" 2>/dev/null &
sig_pid=$!
sleep 1
kill -TERM "$sig_pid"
sig_rc=0
wait "$sig_pid" || sig_rc=$?
check "interrupted undo exits 130" "$sig_rc" 130
check "an interrupt inside the switch back still ends on the old version" "$(cat "$T/sig.out" 2>/dev/null)" "old-good"

echo "## funding comes before registration, and both are waited for"
check_true "1 wei is a balance" has_balance 1
check_true "1 SAVDR is a balance" has_balance 1000000000000000000
check_false "0 is no balance" has_balance 0
check_false "000 is no balance" has_balance 000
check_false "an unreadable balance is no balance" has_balance ""
check_false "a malformed balance is no balance" has_balance 1e18
# Read by print_setup_boxes and print_funding.
# shellcheck disable=SC2034
NET_APP_URL="https://app.dev.salvorias.com"
# shellcheck disable=SC2034
SLOT_JSON='{"nodeBalanceWei":"0","openSlots":[0]}'
boxes=$(print_setup_boxes "0")
printf '%s\n' "$boxes" | sed 's/^/    | /'
line_of() { printf '%s\n' "$1" | grep -nF -- "$2" | head -n 1 | cut -d: -f1; }
fund_at=$(line_of "$boxes" "STEP 1: FUND THE NODE")
reg_at=$(line_of "$boxes" "STEP 2: REGISTER THIS NODE IN THE SALVORIAS APP")
check_true "box 1 is funding, box 2 is registration" test -n "$fund_at" -a -n "$reg_at" -a "${fund_at:-0}" -lt "${reg_at:-0}"
check_lacks "no box registers first" "$boxes" "STEP 1: REGISTER"
check_true "the node address is shown in step 1" test "$(line_of "$boxes" "$NODE_ADDRESS")" -lt "${reg_at:-0}"
check_true "the wallet line is in step 1" test "$(line_of "$boxes" "$FUND_WANT_4")" -lt "${reg_at:-0}"
check_true "the app link is in step 2" test "$(line_of "$boxes" "Open https://app.dev.salvorias.com/licenses/self-host")" -gt "${reg_at:-0}"
check_has "step 2 points back at the address" "$boxes" "paste the node address"$'\n'"   from step 1 and confirm with your passcode."
check_lacks "a free license: no replace notice" "$boxes" "All your licenses already have a node"
check_has "no free license: the replace notice" "$(print_setup_boxes "")" "All your licenses already have a node"
check_has "registered, unfunded: a funding box" "$(print_funding_box)" " FUND THE NODE"
check_lacks "registered, unfunded: no registration step" "$(print_funding_box)" "REGISTER"
check_has "neither: both named" "$(missing_steps no no)" "not funded and not registered yet: send 1 SAVDR to $NODE_ADDRESS, and register it in the app"
check_has "unfunded: funding named" "$(missing_steps yes no)" "registered but not funded yet: send 1 SAVDR to $NODE_ADDRESS."
check_lacks "unfunded: registration not asked for" "$(missing_steps yes no)" "register it"
check_has "unregistered: registration named" "$(missing_steps no yes)" "funded but not registered yet: register it in the app"
check_lacks "unregistered: funding not asked for" "$(missing_steps no yes)" "send 1 SAVDR"
check_has "never read: says the chain was not read" "$(missing_steps "" "")" "could not be read"

echo "## the wait's progress lines follow the state, not the error text"
# The real wait_until_ready with a fake clock (each `date +%s` moves it 3s
# on) and a chain that fails 25 polls in a row, with different error text
# each time, then answers "not registered, not funded" until the 2-minute
# timeout. Expected: the error line at the start and once a minute later
# (2 lines, not 25), then one line for the new state, then the stop.
# The quoted lines are the child shell's own code.
# shellcheck disable=SC2016
{ printf '%s\n' 'set -euo pipefail' "CLOCK_FILE=$T/clock" "NODE_ADDRESS=$NODE_ADDRESS" "OWNER=$OWNER" \
    'SALVORIAS_POLL_SECONDS=3 INTERRUPT_HINT="" POLLS=0 SLOT_JSON="" PATH_LINK=/nonexistent' 'printf "1000\n" >"$CLOCK_FILE"' \
    'date() { if [[ "${1:-}" == +%s ]]; then local c; c=$(( $(<"$CLOCK_FILE") + 3 )); printf "%s\n" "$c" >"$CLOCK_FILE"; printf "%s\n" "$c"; else printf "00:00:00\n"; fi; }' \
    'sleep() { :; }' 'say() { printf "%s\n" "$*"; }' 'cmd_hint() { printf "sudo salvorias-selfhost %s" "$1"; }' \
    'stop() { printf "STOP: %s\n" "$*"; exit 3; }' 'die() { printf "DIE: %s\n" "$*"; exit 1; }' \
    'run_slot_info() { POLLS=$((POLLS + 1)); if (( POLLS <= 25 )); then SLOT_JSON="{\"error\":\"request timed out after ${POLLS}017 ms\"}"; return 1; fi; SLOT_JSON="{\"boundOwner\":null,\"boundSlot\":null,\"nodeBalanceWei\":\"0\"}"; }'
  for f in clean_text lower is_uint strip_zeros wei_to_savdr json_str json_raw has_balance read_binding read_readiness missing_steps wait_until_ready; do extract "$f"; done
  printf '%s\n' 'wait_until_ready 2'
} >"$T/wait.sh"
wait_rc=0
wait_out=$(bash "$T/wait.sh" 2>&1) || wait_rc=$?
printf '%s\n' "$wait_out" | sed 's/^/    | /'
check "the wait times out with exit 3" "$wait_rc" "3"
check "25 failed reads with changing text: 2 lines (the first, and one a minute later)" \
  "$(printf '%s\n' "$wait_out" | grep -c 'could not read the chain' || true)" "2"
check "the new state prints once" "$(printf '%s\n' "$wait_out" | grep -c 'registered: no   funded: no$' || true)" "1"
check_has "the stop names both missing steps" "$wait_out" "STOP: Waited 2 min. The node is not funded and not registered yet"

echo "## the first check-in, read from the daemon's journal"
H="0x$(printf 'ab%.0s' {1..32})"
P='[2026-10-22T12:06:12.123Z] [INFO ] '
E='[2026-10-22T12:06:13.456Z] [ERROR] '
W='[2026-10-22T12:06:13.456Z] [WARN ] '
outcome_of() { printf '%s\n' "$@" | first_checkin_outcome; }
START=("${P}Startup Jitter:   0s" "${P}── Cycle #1 ──" "${P}  ── Node Operator Check-Ins ──")
check "confirmed" "$(outcome_of "${START[@]}" "${P}  Status: 0 already qualified, 1 need check-in" \
  "${P}  [1/1] checkIn(10295) from $NODE_ADDRESS..." "${P}    TX Hash: $H" "${P}    Confirmed block 4242 (gas: 51234)")" "confirmed $H"
check "TX Hash alone is still pending" "$(outcome_of "${START[@]}" "${P}    TX Hash: $H")" ""
check "'0 already qualified, 1 need check-in' is still pending" "$(outcome_of "${P}  Status: 0 already qualified, 1 need check-in")" ""
check "already qualified" "$(outcome_of "${START[@]}" "${P}  Status: 1 already qualified, 0 need check-in" "${P}  All nodes checked in for this period.")" "done"
check "all checked in" "$(outcome_of "${P}  All nodes checked in for this period.")" "done"
check "checked in too recently" "$(outcome_of "${P}    $NODE_ADDRESS checked in too recently. OK.")" "done"
check "failed before a hash" "$(outcome_of "${P}  [1/1] checkIn(1) from $NODE_ADDRESS..." "${E}    $NODE_ADDRESS check-in failed: boom (code=X)")" "failed boom (code=X)"
check "failed after a hash (the tx reverted)" "$(outcome_of "${P}    TX Hash: $H" "${E}    $NODE_ADDRESS check-in failed: transaction execution reverted")" "failed transaction execution reverted"
check "the fee-cap skip, without the log prefix" \
  "$(outcome_of "${W}    Node $NODE_ADDRESS skipped this cycle: network gas price 60 gwei is above MAX_GAS_PRICE_GWEI 50 gwei. No tx sent.")" \
  "skipped Node $NODE_ADDRESS skipped this cycle: network gas price 60 gwei is above MAX_GAS_PRICE_GWEI 50 gwei. No tx sent."
check "a low-balance warning is not an outcome" "$(outcome_of "${W}    Node $NODE_ADDRESS low balance: has 0 SAVDR, needs 0.0001 SAVDR. Fund this address.")" ""
check "a failed cycle is not parsed (not a stable phrase)" "$(outcome_of "${E}  Cycle failed: could not detect network")" ""
check "Confirmed block without a TX Hash is not a check-in" "$(outcome_of "${P}    Confirmed block 1")" ""
check "a short hash is not taken" "$(outcome_of "${P}    TX Hash: 0xabc" "${P}    Confirmed block 1")" ""
check "lines without the log prefix still parse" "$(outcome_of "    TX Hash: $H" "    Confirmed block 7")" "confirmed $H"
check "the first outcome wins" "$(outcome_of "${P}  All nodes checked in for this period." "${E}    x check-in failed: later")" "done"
check "an empty journal is pending" "$(printf '' | first_checkin_outcome)" ""

echo "## the failure reason"
NOSAVDR="the node has no SAVDR yet; send 1 SAVDR to $NODE_ADDRESS"
LOWSAVDR="the node's SAVDR balance is too low for the fee; send more SAVDR to $NODE_ADDRESS"
check "'not EOA' means no SAVDR" "$(checkin_failure_reason 'could not coalesce error (error={ "code": -32000, "message": "invalid transaction: the sender is not EOA" }, payload={ "id": 9 }, code=UNKNOWN_ERROR, version=6.16.0)')" "$NOSAVDR"
check "'insufficient funds' means a balance too low for the fee" "$(checkin_failure_reason 'insufficient funds for intrinsic transaction cost (transaction="0x02", info={ }, code=INSUFFICIENT_FUNDS, version=6.16.0)')" "$LOWSAVDR"
check_lacks "'insufficient funds' is not called 'no SAVDR'" "$(checkin_failure_reason 'insufficient funds for gas * price + value')" "no SAVDR"
check "'Insufficient' in any case" "$(checkin_failure_reason 'INSUFFICIENT FUNDS')" "$LOWSAVDR"
check "'Not EOA' in any case" "$(checkin_failure_reason 'sender Not EOA')" "$NOSAVDR"
check "ethers' wrapper is cut to the node's message" "$(checkin_failure_reason 'could not coalesce error (error={ "code": -32000, "message": "mock-rpc: transactions are disabled in this test" }, payload={ "id": 9, "jsonrpc": "2.0", "method": "eth_sendRawTransaction", "params": [ "0x02f8" ] }, code=UNKNOWN_ERROR, version=6.16.0)')" "mock-rpc: transactions are disabled in this test"
check "other errors lose ethers' detail list" "$(checkin_failure_reason 'execution reverted: "CheckInClosed()" (action="estimateGas", data="0x", reason=null)')" 'execution reverted: "CheckInClosed()"'
check "control characters dropped" "$(checkin_failure_reason $'bad\033[31m thing\r')" "bad[31m thing"
check "at most 200 characters" "$(checkin_failure_reason "$(printf 'x%.0s' {1..300})" | wc -c | tr -d ' ')" "200"
check "a trailing period is dropped (the line adds its own)" "$(checkin_failure_reason 'timeout.')" "timeout"
check "an empty reason" "$(checkin_failure_reason '')" "no reason given"

echo "## the first check-in result line"
# Read by print_first_checkin and the watch.
# shellcheck disable=SC2034
NET_EXPLORER_URL="https://testnet.savscanner.io"
cmd_hint() { printf 'sudo salvorias-selfhost %s' "$1"; }
check "confirmed, with the explorer link" "$(print_first_checkin "confirmed $H")" "First check-in confirmed (tx $H).
  https://testnet.savscanner.io/tx/$H"
check "already done" "$(print_first_checkin "done")" "This node already checked in for the current period; the next check-in is automatic."
check "failed, no SAVDR" "$(print_first_checkin 'failed invalid transaction: the sender is not EOA')" "The first check-in failed: $NOSAVDR.
The node keeps retrying on its own schedule. Run sudo salvorias-selfhost status for details."
check "the fee-cap skip line as is" "$(print_first_checkin "skipped Node $NODE_ADDRESS skipped this cycle: network gas price 60 gwei is above MAX_GAS_PRICE_GWEI 50 gwei. No tx sent." | head -n 1)" \
  "The first check-in failed: Node $NODE_ADDRESS skipped this cycle: network gas price 60 gwei is above MAX_GAS_PRICE_GWEI 50 gwei. No tx sent."
check "no result in time" "$(print_first_checkin "")" "No check-in result yet; run sudo salvorias-selfhost status in a few minutes."
check "the Active note" "$ACTIVE_NOTE" "It can take up to 30 minutes for your license to show Active in the Salvorias app after the first check-in. Check back then."

echo "## text from outside is cleaned before it is printed"
has_ctrl() { [[ "$1" == *[[:cntrl:]]* ]]; }
check "plain text is unchanged" "$(clean_text 'RPC down')" "RPC down"
check "escape sequences lose their ESC byte" "$(clean_text $'ok\033[2Jgone')" "ok[2Jgone"
check "a carriage return cannot overwrite the line" "$(clean_text $'real text\rFAKE')" "real text FAKE"
check "line breaks and tabs fold to one line" "$(clean_text $'a\nb\tc\r\nd')" "a b c d"
check "runs of spaces collapse and the ends are trimmed" "$(clean_text $'  a   b \n ')" "a b"
check "BEL, backspace and DEL are dropped" "$(clean_text $'a\ab\bc\177d')" "abcd"
check "the default cap is 200 characters" "$(clean_text "$(printf 'x%.0s' {1..300})" | wc -c | tr -d ' ')" "200"
check "-n sets the cap" "$(clean_text -n 5 'hello world')" "hello"
check "a cut never leaves a trailing space" "$(clean_text -n 6 'hello world')" "hello"
check "empty in, empty out" "$(clean_text '')" ""
check "-n alone is text, not an option" "$(clean_text -n)" "-n"
check "-n without a number is text" "$(clean_text -n abc)" "-n abc"
big=$(head -c 300000 /dev/zero | tr '\0' 'y')
check "an oversized response is cut" "$(clean_text "$big" | wc -c | tr -d ' ')" "200"
check_false "the result has no control character" has_ctrl "$(clean_text $'a\033b\rc\nd')"

# Each site that prints external text, run for real in a child shell with the
# external call replaced by a stand-in that answers with hostile text.
# The quoted lines are the child shell's own code.
HOSTILE=$'boom\033[2J\r\nFAKE: install ok'
# The chain query prints JSON.stringify output, which has no raw line breaks.
HOSTILE_JSON=$'boom\033[2J\rFAKE: install ok'
site_run() {
  # shellcheck disable=SC2016
  { printf '%s\n' 'set -euo pipefail' 'die() { printf "DIE: %s\n" "$*"; exit 1; }' 'usage_error() { printf "USAGE: %s\n" "$*"; exit 2; }' \
      'RPC_URL=https://rpc.example NET_CHAIN_ID=7283 NETWORK=testnet UNIT_NAME=u'
    printf '%s\n' 'require_safe_url() { :; }'
    for f in clean_text json_str json_raw say "$@"; do extract "$f"; done
    cat
  } | bash 2>&1 || true
}
out=$(site_run check_rpc <<EOF
curl_safe() { printf '%s' $(printf '%q' "$HOSTILE"); return 22; }
check_rpc
EOF
)
check_has "check_rpc: an HTTP error body is shown" "$out" "answered with an error (boom[2J FAKE: install ok)"
check_true "check_rpc: nothing but the one DIE line (no raw line break)" test "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1
check_false "check_rpc: no control character in the message" has_ctrl "$out"
out=$(site_run check_rpc <<EOF
curl_safe() { printf '%s' $(printf '%q' "$HOSTILE"); return 0; }
check_rpc
EOF
)
check_has "check_rpc: a reply with no chain id is shown cleaned" "$out" "did not return a chain id. Response: boom[2J FAKE: install ok"
out=$(site_run check_rpc <<EOF
curl_safe() { printf '%s' $(printf '%q' "$HOSTILE"); return 7; }
check_rpc
EOF
)
check_has "check_rpc: a connection error is shown cleaned" "$out" "Cannot reach the Salvorias RPC at https://rpc.example (boom[2J FAKE: install ok)"
out=$(site_run query_chain <<EOF
run_slot_info() { SLOT_JSON='{"error":"'$(printf '%q' "$HOSTILE_JSON")'"}'; return 1; }
query_chain /bin/true
EOF
)
check_has "query_chain: a chain error is shown cleaned" "$out" "DIE: Could not read the chain at https://rpc.example: boom[2J FAKE: install ok. Try again"
out=$(site_run query_chain <<EOF
run_slot_info() { SLOT_JSON='{"error":"'$(printf '%q' "$HOSTILE_JSON")'"}'; return 2; }
query_chain /bin/true
EOF
)
check_has "query_chain: a rejected input is shown cleaned" "$out" "USAGE: The chain query rejected the input: boom[2J FAKE: install ok"
check_false "query_chain: no control character in the message" has_ctrl "$out"
out=$(site_run show_journal <<EOF
journalctl() { printf 'Oct 26 host node[1]: %s\n' $(printf '%q' "$HOSTILE_JSON"); printf 'second line\n'; }
show_journal 5
EOF
)
check "show_journal: each journal entry is one clean line" "$out" "Oct 26 host node[1]: boom[2J FAKE: install ok
second line"
out=$(site_run show_journal <<EOF
journalctl() { return 1; }
show_journal 5
EOF
)
check "show_journal: a failing journalctl says there is no journal" "$out" "(no journal entries)"
out=$(site_run show_journal <<EOF
journalctl() { printf 'no newline at the end'; }
show_journal 5
EOF
)
check "show_journal: a last line without a newline is kept" "$out" "no newline at the end"
check "the check-in outcome is cleaned too" "$(outcome_of "[2026-10-22T12:06:13.456Z] [ERROR]     $NODE_ADDRESS check-in failed: boom"$'\033[2J')" "failed boom[2J"
check "a fee-cap skip line is cleaned" "$(outcome_of $'    Node x skipped this cycle: a\033[2J b')" "skipped Node x skipped this cycle: a[2J b"
check "print_first_checkin cleans a skip line it is handed" "$(print_first_checkin $'skipped bad\033[2J\rline' | head -n 1)" "The first check-in failed: bad[2J line."
install_text=$(cat install.sh)
raw_json_errors=$(grep -c 'json_str error' install.sh || true)
# shellcheck disable=SC2016
clean_json_errors=$(grep -c 'clean_text "$(json_str error)"' install.sh || true)
check "every json_str error is printed through clean_text" "$raw_json_errors" "$clean_json_errors"
# shellcheck disable=SC2016
check_lacks "no message prints an RPC response cut with \${body:0:N} instead" "$install_text" '${body:0:'
# shellcheck disable=SC2016
check_lacks "no message prints the node binary's output cut with \${out:0:N} instead" "$install_text" '${out:0:'

# Chain data other than error text: the chain id, the bound wallet and the NFT
# contract all come from the RPC and are printed in messages.
out=$(site_run query_chain <<EOF
run_slot_info() { SLOT_JSON='{"chainId":'$(printf '%q' "$HOSTILE_JSON")'}'; return 0; }
query_chain /bin/true
EOF
)
check_has "query_chain: a wrong chain id is shown cleaned" "$out" "DIE: Chain query answered from chain 'boom[2J FAKE: install ok', expected 7283."
check_false "query_chain: no control character in the wrong-chain message" has_ctrl "$out"
out=$(site_run read_readiness read_binding lower is_uint has_balance <<EOF
cmd_hint() { printf 'hint'; }
NODE_ADDRESS=0xnode OWNER=0x1
SLOT_JSON='{"boundOwner":"'$(printf '%q' "$HOSTILE_JSON")'","boundSlot":null}'
read_readiness
EOF
)
check_has "read_readiness: a wallet the node is bound to is shown cleaned" "$out" "registered to a different wallet (boom[2J FAKE: install ok), not 0x1"
check_has "read_readiness: and in the instruction that follows" "$out" "(signed in with boom[2J FAKE: install ok)"
check_false "read_readiness: no control character in the message" has_ctrl "$out"
# shellcheck disable=SC2034
SLOT_JSON='{"boundOwner":"'"$HOSTILE_JSON"'"}'
BOUND_OTHER=""; read_binding
check_false "read_binding: BOUND_OTHER (printed by install, status and resume) has no control character" has_ctrl "$BOUND_OTHER"
check "read_binding: BOUND_OTHER holds the cleaned text" "$BOUND_OTHER" "boom[2J FAKE: install ok"
# The NFT contract is printed by a check inside cmd_install, which cannot run
# here, so the source is checked instead.
# shellcheck disable=SC2016
check_has "the NFT contract in the mismatch message goes through clean_text" "$install_text" 'NFT contract $(clean_text "$nft"), but'
# shellcheck disable=SC2016
check_lacks "and is not printed raw" "$install_text" 'NFT contract $nft'
# shellcheck disable=SC2016
check_lacks "the chain id is not printed raw" "$install_text" "chain '\$chain'"
# shellcheck disable=SC2016
check "BOUND_OTHER is only ever assigned cleaned" "$(grep -c 'BOUND_OTHER=' install.sh)" "$(grep -c 'BOUND_OTHER=$(clean_text\|^BOUND_OTHER=""' install.sh)"

echo "## the fixed paths and the salvorias account are taken only with proof of ownership"
# The quoted snippets handed to own_try are the child shell's own code.
# shellcheck disable=SC2016
if [[ "$(id -u)" -ne 0 ]]; then
  echo "SKIP: needs root (the proof is a root-owned file); the e2e suite runs these as root"
else
  OWN_USER=nobody
  OWN_UID=$(id -u "$OWN_USER")
  eval "$(extract_var STATE_FILE_HEADER)"
  cp install.sh "$T/valid-self.sh"
  mkdir -p "$T/own"
  own_new() { local d="$T/own/$1"; rm -rf "$d"; mkdir -p "$d/usr/bin" "$d/usr/sbin"; printf '%s' "$d"; }
  own_marker() { mkdir -p "$1/var/salvorias"; printf 'UID=%s\n' "$2" >"$1/var/salvorias/installer-account.txt"; chmod 0600 "$1/var/salvorias/installer-account.txt"; }
  own_state() { mkdir -p "$1/etc/salvorias"; printf '%s\n# this file; it reads node.env. Do not edit.\nSTAGE=installed\n' "$STATE_FILE_HEADER" >"$1/etc/salvorias/selfhost.conf"; }
  own_foreign_all() {
    mkdir -p "$1/etc/salvorias" "$1/var/salvorias" "$1/opt/salvorias"
    ln -sfn /nonexistent "$1/usr/bin/salvorias-node"
    printf 'not ours\n' >"$1/usr/sbin/salvorias-selfhost"
  }
  # own_try ROOT [USER] <<< code: the real functions run in a child shell, on
  # a layout under ROOT, as the account USER (default nobody). Prints the
  # output and "rc=N".
  own_try() {
    local r="$1" acct="${2:-$OWN_USER}" out rc=0
    # shellcheck disable=SC2016
    out=$({
      printf '%s\n' 'set -euo pipefail' 'die() { printf "DIE: %s\n" "$*"; exit 1; }' "R=$r" \
        'ETC_DIR=$R/etc/salvorias' 'STATE_FILE=$ETC_DIR/selfhost.conf' 'DATA_DIR=$R/var/salvorias' \
        'ACCOUNT_MARKER=$DATA_DIR/installer-account.txt' 'OPT_DIR=$R/opt/salvorias' 'BIN_ROOT=$OPT_DIR/bin' \
        'CURRENT_LINK=$BIN_ROOT/current' 'PATH_LINK=$R/usr/bin/salvorias-node' 'SELF_PATH=$R/usr/sbin/salvorias-selfhost' \
        "SERVICE_USER=$acct" 'ACCOUNT_CREATED="" ACCOUNT_UID="" OPT_SELF="" RUNNING_FILE="" OPT_BINARY=""'
      extract_var STATE_FILE_HEADER
      extract_var SELF_MARKER
      for f in say warn state_file_is_ours account_marker_matches write_account_marker installer_proof refuse_unowned_paths refuse_foreign_account \
          require_owned_account ensure_user path_link_is_ours self_file_is_ours switch_current prune_versions stray_files remove_strays; do
        extract "$f"
      done
      cat
    } | bash 2>&1) || rc=$?
    printf '%s\nrc=%s' "$out" "$rc"
  }

  r=$(own_new clean)
  out=$(own_try "$r" <<<'refuse_unowned_paths; echo passed')
  check "nothing at the fixed paths: the install may go on" "$out" "passed
rc=0"

  for spec in ETC_DIR:etc/salvorias DATA_DIR:var/salvorias OPT_DIR:opt/salvorias PATH_LINK:usr/bin/salvorias-node SELF_PATH:usr/sbin/salvorias-selfhost; do
    r=$(own_new "foreign-${spec%%:*}")
    case "${spec%%:*}" in
      ETC_DIR|DATA_DIR|OPT_DIR) mkdir -p "$r/${spec#*:}"; printf 'keep\n' >"$r/${spec#*:}/precious" ;;
      PATH_LINK) ln -s /nonexistent "$r/${spec#*:}" ;;
      SELF_PATH) printf 'precious\n' >"$r/${spec#*:}" ;;
    esac
    out=$(own_try "$r" <<<'refuse_unowned_paths; echo passed')
    check_has "${spec%%:*} with no proof: refused, and the path is named" "$out" "DIE: $r/${spec#*:} already exists, and nothing shows that this installer created it"
    check_has "${spec%%:*}: the message says how to go on" "$out" "move it aside"
    check_lacks "${spec%%:*}: the install does not go on" "$out" "passed"
    check_true "${spec%%:*}: the path is untouched" bash -c '[[ -e "$1" || -L "$1" ]]' _ "$r/${spec#*:}"
  done
  check "a refused directory keeps its contents" "$(cat "$T/own/foreign-ETC_DIR/etc/salvorias/precious")" "keep"

  r=$(own_new marker-ok); own_foreign_all "$r"; own_marker "$r" "$OWN_UID"
  out=$(own_try "$r" <<<'refuse_unowned_paths; echo passed')
  check "the marker for this account's UID proves all five paths (a kept-key reinstall)" "$out" "passed
rc=0"
  r=$(own_new marker-other-uid); own_foreign_all "$r"; own_marker "$r" "$((OWN_UID + 1))"
  out=$(own_try "$r" <<<'refuse_unowned_paths; echo passed')
  check_has "a marker naming another UID proves nothing" "$out" "DIE: $r/etc/salvorias already exists"
  r=$(own_new marker-no-account); own_foreign_all "$r"; own_marker "$r" "$OWN_UID"
  out=$(own_try "$r" no-such-account-r12 <<<'refuse_unowned_paths; echo passed')
  check_has "a marker with no such account proves nothing" "$out" "DIE: $r/etc/salvorias already exists"
  r=$(own_new marker-symlink); own_foreign_all "$r"; printf 'UID=%s\n' "$OWN_UID" >"$r/marker-target"; ln -s "$r/marker-target" "$r/var/salvorias/installer-account.txt"
  out=$(own_try "$r" <<<'refuse_unowned_paths; echo passed')
  check_has "a marker that is a link proves nothing" "$out" "DIE: $r/etc/salvorias already exists"
  r=$(own_new marker-hardlink); own_foreign_all "$r"; own_marker "$r" "$OWN_UID"; ln "$r/var/salvorias/installer-account.txt" "$r/second-link"
  out=$(own_try "$r" <<<'refuse_unowned_paths; echo passed')
  check_has "a marker with a second hard link proves nothing" "$out" "DIE: $r/etc/salvorias already exists"
  r=$(own_new marker-datadir-user); own_foreign_all "$r"; own_marker "$r" "$OWN_UID"; chown "$OWN_USER" "$r/var/salvorias"
  out=$(own_try "$r" <<<'refuse_unowned_paths; echo passed')
  check_has "a marker in a data directory the account owns proves nothing" "$out" "DIE: $r/etc/salvorias already exists"

  r=$(own_new state-ok); own_foreign_all "$r"; own_state "$r"
  out=$(own_try "$r" <<<'refuse_unowned_paths; echo passed')
  check "the installer's state file proves the paths too" "$out" "passed
rc=0"
  r=$(own_new state-noheader); own_foreign_all "$r"; printf 'STAGE=installed\n' >"$r/etc/salvorias/selfhost.conf"
  out=$(own_try "$r" <<<'refuse_unowned_paths; echo passed')
  check_has "a file named selfhost.conf without the installer's header proves nothing" "$out" "DIE: $r/etc/salvorias already exists"
  r=$(own_new state-link); own_foreign_all "$r"; own_state "$r"; mv "$r/etc/salvorias/selfhost.conf" "$r/state-real"; ln -s "$r/state-real" "$r/etc/salvorias/selfhost.conf"
  out=$(own_try "$r" <<<'refuse_unowned_paths; echo passed')
  check_has "a state file that is a link proves nothing" "$out" "DIE: $r/etc/salvorias already exists"
  r=$(own_new state-user); own_foreign_all "$r"; own_state "$r"; chown "$OWN_USER" "$r/etc/salvorias/selfhost.conf"
  out=$(own_try "$r" <<<'refuse_unowned_paths; echo passed')
  check_has "a state file another account owns proves nothing" "$out" "DIE: $r/etc/salvorias already exists"

  echo "# the salvorias account"
  r=$(own_new acct-foreign)
  out=$(own_try "$r" <<<'require_owned_account; echo passed')
  check_has "an existing account with no marker is refused" "$out" "DIE: An account named 'nobody' (UID $OWN_UID) already exists, but this installer did not create it"
  check_has "the refusal says how to resolve it" "$out" "sudo userdel nobody"
  check_has "and how to recover from a run killed just after it made the account" "$out" "killed in the instant after it created the account"
  check_lacks "the install does not go on" "$out" "passed"
  out=$(own_try "$r" <<<'ensure_user; echo "created=$ACCOUNT_CREATED"')
  check_has "ensure_user refuses it too" "$out" "DIE: An account named 'nobody'"
  check_lacks "ensure_user does not adopt it" "$out" "created=yes"
  check_lacks "ensure_user no longer says it uses an existing account" "$out" "Using the existing system user"
  r=$(own_new acct-marked); own_marker "$r" "$OWN_UID"
  out=$(own_try "$r" <<<'require_owned_account; ensure_user; echo "created=$ACCOUNT_CREATED uid=$ACCOUNT_UID"')
  check_has "an account with this installer's marker is reused" "$out" "Using the system user nobody that this installer created for an earlier install."
  check_has "and recorded as the installer's, with its UID" "$out" "created=yes uid=$OWN_UID"
  r=$(own_new acct-marker-other); own_marker "$r" "$((OWN_UID + 1))"
  out=$(own_try "$r" <<<'require_owned_account; echo passed')
  check_has "an account made again under the same name (another UID) is refused" "$out" "DIE: An account named 'nobody'"
  # A new account: the marker is written by ensure_user itself, before
  # make_dirs or any other step has made a directory, so a run stopped right
  # after the account exists is still recognised by the next install.
  NEW_ACCT=e2eunitnew
  if id -u "$NEW_ACCT" >/dev/null 2>&1; then userdel "$NEW_ACCT"; fi
  r=$(own_new acct-new)
  out=$(own_try "$r" "$NEW_ACCT" <<<'ensure_user
echo "created=$ACCOUNT_CREATED"
if account_marker_matches; then echo marker-ok; else echo marker-missing; fi
for d in "$ETC_DIR" "$OPT_DIR" "$BIN_ROOT"; do if [[ -e "$d" ]]; then echo "dir-made:$d"; fi; done
echo "data=$(stat -c "%a %U:%G" "$DATA_DIR")"')
  new_uid=$(id -u "$NEW_ACCT" 2>/dev/null || echo none)
  check_has "ensure_user creates the account" "$out" "Created system user: $NEW_ACCT"
  check_has "the marker is in place when ensure_user returns" "$out" "marker-ok"
  check "it names the new account's UID" "$(cat "$r/var/salvorias/installer-account.txt" 2>/dev/null)" "UID=$new_uid"
  check_lacks "and no other directory exists yet (make_dirs has not run)" "$out" "dir-made:"
  check_has "the data directory is root:account 750 from the start" "$out" "data=750 root:$NEW_ACCT"
  # The next install: the account exists, nothing else does, and it is not refused.
  out=$(own_try "$r" "$NEW_ACCT" <<<'refuse_unowned_paths; require_owned_account; ensure_user; echo "resumed=$ACCOUNT_CREATED"')
  check_has "after an interruption right there, the next install reuses the account" "$out" "resumed=yes"
  check_lacks "and is not refused" "$out" "DIE:"
  userdel "$NEW_ACCT" 2>/dev/null || true
  # An interrupt handler set by the caller survives ensure_user.
  r=$(own_new acct-new-trap)
  out=$(own_try "$r" "$NEW_ACCT" <<<'on_signal() { :; }; trap on_signal INT; ensure_user >/dev/null; trap -p INT')
  check_has "the caller's INT handler is back after ensure_user" "$out" "trap -- 'on_signal' SIGINT"
  userdel "$NEW_ACCT" 2>/dev/null || true
  r=$(own_new acct-none)
  out=$(own_try "$r" no-such-account-r12 <<<'require_owned_account; echo passed')
  check "no account yet: nothing to refuse" "$out" "passed
rc=0"

  echo "# the links and files in /usr/local"
  r=$(own_new usrlocal); mkdir -p "$r/opt/salvorias/bin"
  out=$(own_try "$r" <<<'switch_current v1; echo "link=$(readlink "$PATH_LINK") cur=$(readlink "$CURRENT_LINK")"')
  check "no link yet: switch_current makes it" "$out" "link=$r/opt/salvorias/bin/current/salvorias-node cur=v1
rc=0"
  out=$(own_try "$r" <<<'switch_current v2; echo "link=$(readlink "$PATH_LINK") cur=$(readlink "$CURRENT_LINK")"')
  check "its own link is moved on" "$out" "link=$r/opt/salvorias/bin/current/salvorias-node cur=v2
rc=0"
  rm -f "$r/usr/bin/salvorias-node"; printf 'someone elses binary\n' >"$r/usr/bin/salvorias-node"
  out=$(own_try "$r" <<<'switch_current v3; echo passed')
  check_has "a regular file at the path is not replaced" "$out" "DIE: $r/usr/bin/salvorias-node is not the link this installer makes"
  check "and keeps its content" "$(cat "$r/usr/bin/salvorias-node")" "someone elses binary"
  check "the current link did not move either" "$(readlink "$r/opt/salvorias/bin/current")" "v2"
  rm -f "$r/usr/bin/salvorias-node"; ln -s /usr/bin/true "$r/usr/bin/salvorias-node"
  out=$(own_try "$r" <<<'switch_current v3; echo passed')
  check_has "a link to somewhere else is not replaced" "$out" "DIE: $r/usr/bin/salvorias-node is not the link this installer makes"
  check "and still points there" "$(readlink "$r/usr/bin/salvorias-node")" "/usr/bin/true"
  r=$(own_new selffile)
  printf '#!/usr/bin/env bash\n# salvorias-selfhost-installer\necho hi\n' >"$r/usr/sbin/salvorias-selfhost"
  out=$(own_try "$r" <<<'self_file_is_ours && echo ours || echo not-ours')
  check_has "a file with the installer's marker on line 2 is ours" "$out" "ours"
  printf '#!/bin/sh\necho hi\n' >"$r/usr/sbin/salvorias-selfhost"
  out=$(own_try "$r" <<<'self_file_is_ours && echo ours || echo not-ours')
  check_has "a file without it is not" "$out" "not-ours"
  rm -f "$r/usr/sbin/salvorias-selfhost"; head -c 2000 /dev/urandom >"$r/usr/sbin/salvorias-selfhost"
  out=$(own_try "$r" <<<'self_file_is_ours && echo ours || echo not-ours')
  check_has "binary junk is not" "$out" "not-ours"
  rm -f "$r/usr/sbin/salvorias-selfhost"; ln -s "$T/valid-self.sh" "$r/usr/sbin/salvorias-selfhost"
  out=$(own_try "$r" <<<'self_file_is_ours && echo ours || echo not-ours')
  check_has "a link to a genuine copy is not (only the file itself is)" "$out" "not-ours"
  rm -f "$r/usr/sbin/salvorias-selfhost"; printf 'someone elses tool\n' >"$r/usr/sbin/salvorias-selfhost"
  out=$(own_try "$r" <<<"OPT_SELF=$T/valid-self.sh; make_tmp_dir() { :; }; TMP_DIR=$r; $(extract install_self_copy)
install_self_copy; echo done")
  check_has "install_self_copy leaves a foreign file at the path alone" "$out" "exists and is not a copy of this installer; leaving it alone"
  check "and its content is unchanged" "$(cat "$r/usr/sbin/salvorias-selfhost")" "someone elses tool"

  echo "# what uninstall and upgrade delete"
  r=$(own_new prune)
  mkdir -p "$r/opt/salvorias/bin/"{keep-cur,keep-prev,old-ok,old-temp,old-odd}
  touch "$r/opt/salvorias/bin/old-ok/salvorias-node" "$r/opt/salvorias/bin/old-temp/.salvorias-node.new" "$r/opt/salvorias/bin/old-odd/notes.txt" "$r/opt/salvorias/bin/old-odd/salvorias-node"
  ln -s keep-cur "$r/opt/salvorias/bin/current"
  out=$(own_try "$r" <<<'prune_versions keep-cur keep-prev; echo done')
  check_true "an old version directory is pruned" test ! -e "$r/opt/salvorias/bin/old-ok"
  check_true "so is the temp name place_binary leaves" test ! -e "$r/opt/salvorias/bin/old-temp"
  check_true "a directory with something else in it is not recursively deleted" test -e "$r/opt/salvorias/bin/old-odd/notes.txt"
  check_has "and the run says so" "$out" "Leaving $r/opt/salvorias/bin/old-odd in place"
  check_true "the current and previous versions stay" test -d "$r/opt/salvorias/bin/keep-cur" -a -d "$r/opt/salvorias/bin/keep-prev"
  check_true "the current link stays" test -L "$r/opt/salvorias/bin/current"

  r=$(own_new strays); mkdir -p "$r/var/salvorias/.stage.abc"; printf 'x\n' >"$r/var/salvorias/.stage.abc/node-key.txt"
  out=$(own_try "$r" <<<'stray_files no; echo ---; stray_files yes')
  check_lacks "a staging directory in a data directory not shown to be ours is not listed" "${out%%---*}" ".stage.abc"
  check_has "one in a data directory shown to be ours is" "${out##*---}" "$r/var/salvorias/.stage.abc"
  out=$(own_try "$r" <<<'remove_strays no; echo done')
  check_true "remove_strays no leaves it alone" test -e "$r/var/salvorias/.stage.abc/node-key.txt"
  out=$(own_try "$r" <<<'remove_strays yes; echo done')
  check_true "remove_strays yes removes it" test ! -e "$r/var/salvorias/.stage.abc"
  check_has "and reports it" "$out" "Removed 1 file(s) left by an interrupted run"
fi

echo "## the first check-in watch: bounded, Ctrl-C safe, never fails the install"
# The real watch_first_checkin, and the real timeout, with stand-in systemctl
# and journalctl executables first on PATH. The journal is a file the test
# writes; STUB_SYSTEMCTL_SLEEP and STUB_JOURNAL_SLEEP make a stand-in hang
# that long before answering.
mkdir -p "$T/wbin"
# The quoted bodies are the stand-ins' own code.
# shellcheck disable=SC2016
# A hang is the stand-in itself sleeping (exec), as a hung systemctl or
# journalctl would: one process, which `timeout --foreground` stops.
printf '#!/bin/sh\n[ "${STUB_SYSTEMCTL_SLEEP:-0}" = 0 ] || exec sleep "$STUB_SYSTEMCTL_SLEEP"\necho 0123456789abcdef0123456789abcdef\n' >"$T/wbin/systemctl"
# shellcheck disable=SC2016
printf '#!/bin/sh\n[ "${STUB_JOURNAL_SLEEP:-0}" = 0 ] || exec sleep "$STUB_JOURNAL_SLEEP"\n[ "$1" = _SYSTEMD_INVOCATION_ID=0123456789abcdef0123456789abcdef ] && cat "$JOURNAL"\n' >"$T/wbin/journalctl"
chmod 0755 "$T/wbin/systemctl" "$T/wbin/journalctl"
watch_script() {
  local secs="$1" journal="$2" systemctl_sleep="${3:-0}" journal_sleep="${4:-0}"
  # The quoted lines are the child shell's own code.
  # shellcheck disable=SC2016
  { printf '%s\n' 'set -euo pipefail' "export PATH=$T/wbin:\$PATH" "export STUB_SYSTEMCTL_SLEEP=$systemctl_sleep STUB_JOURNAL_SLEEP=$journal_sleep JOURNAL=$journal" \
      "SALVORIAS_FIRST_CHECKIN_SECONDS=$secs" \
      "NODE_ADDRESS=$NODE_ADDRESS" 'NET_EXPLORER_URL=https://testnet.savscanner.io' 'UNIT_NAME=u' \
      'say() { printf "%s\n" "$*"; }' 'cmd_hint() { printf "sudo salvorias-selfhost %s" "$1"; }' \
      'on_signal() { echo ON_SIGNAL; exit 130; }' 'trap on_signal INT'
    extract_var ACTIVE_NOTE
    for f in clean_text first_checkin_outcome checkin_failure_reason print_first_checkin watch_first_checkin; do extract "$f"; done
    printf '%s\n' 'watch_first_checkin' 'echo "AFTER rc=$?"' 'trap -p INT'
  } >"$T/watch.sh"
}
printf '%s\n' "${P}── Cycle #1 ──" "${P}    TX Hash: $H" "${P}    Confirmed block 9 (gas: 1)" >"$T/journal-ok"
watch_script 30 "$T/journal-ok"
w_out=$(bash "$T/watch.sh" 2>&1)
check_has "a result ends the watch" "$w_out" "First check-in confirmed (tx $H)."
check_has "then the Active note" "$w_out" "$ACTIVE_NOTE"
check_has "the install goes on" "$w_out" "AFTER rc=0"
check_has "Ctrl-C goes back to the installer's handler afterwards" "$w_out" "on_signal"
printf '%s\n' "${P}── Cycle #1 ──" "${E}    $NODE_ADDRESS check-in failed: insufficient funds for gas" >"$T/journal-fail"
watch_script 30 "$T/journal-fail"
w_out=$(bash "$T/watch.sh" 2>&1)
check_has "a failed check-in is reported" "$w_out" "The first check-in failed: $LOWSAVDR."
check_has "a failed check-in does not fail the install" "$w_out" "AFTER rc=0"
printf '%s\n' "${P}── Cycle #1 ──" >"$T/journal-pending"
watch_script 3 "$T/journal-pending"
w_start=$(date +%s)
w_out=$(bash "$T/watch.sh" 2>&1)
w_secs=$(( $(date +%s) - w_start ))
check_has "no result: the timeout line" "$w_out" "No check-in result yet; run sudo salvorias-selfhost status in a few minutes."
check_has "no result: the install goes on" "$w_out" "AFTER rc=0"
check_true "the watch is bounded (3s asked, took ${w_secs}s)" test "$w_secs" -le 8
# systemctl and journalctl that hang far past the limit: each gets at most
# the time left, so the watch still ends within the limit plus a second or two.
for limit in 1 3; do
  watch_script "$limit" "$T/journal-ok" 30 30
  w_start=$(date +%s)
  w_out=$(bash "$T/watch.sh" 2>&1)
  w_secs=$(( $(date +%s) - w_start ))
  check_true "hanging systemctl and journalctl: a ${limit}s watch ends within the limit (took ${w_secs}s)" test "$w_secs" -le $((limit + 2))
  check_has "hanging systemctl and journalctl (${limit}s): the timeout line" "$w_out" "No check-in result yet"
  check_has "hanging systemctl and journalctl (${limit}s): the install goes on" "$w_out" "AFTER rc=0"
done
# Only journalctl hangs: systemctl answers at once, the journal read is cut.
watch_script 2 "$T/journal-ok" 0 30
w_start=$(date +%s)
w_out=$(bash "$T/watch.sh" 2>&1)
w_secs=$(( $(date +%s) - w_start ))
check_true "a hanging journalctl alone: a 2s watch ends within the limit (took ${w_secs}s)" test "$w_secs" -le 4
check_has "a hanging journalctl alone: the timeout line" "$w_out" "No check-in result yet"
watch_script 0 "$T/journal-ok"
check "0 skips the watch" "$(bash "$T/watch.sh" 2>&1 | head -n 1)" "AFTER rc=0"
# Ctrl-C: SIGINT to the whole process group, the way a terminal sends it. A
# background job of a non-interactive shell starts with SIGINT ignored, which
# a trap cannot undo, so python3 resets it and makes a new group first.
watch_script 60 "$T/journal-pending"
python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.setpgid(0, 0); os.execvp(sys.argv[1], sys.argv[1:])' \
  bash "$T/watch.sh" >"$T/watch-int.out" 2>&1 &
w_pid=$!
sleep 2
w_start=$(date +%s)
kill -INT -- "-$w_pid" 2>/dev/null || true
w_rc=0
wait "$w_pid" || w_rc=$?
w_secs=$(( $(date +%s) - w_start ))
w_out=$(cat "$T/watch-int.out")
check "Ctrl-C during the watch: exit 0" "$w_rc" "0"
check_has "Ctrl-C ends the watch, not the install" "$w_out" "AFTER rc=0"
check_has "Ctrl-C says the node keeps running" "$w_out" "Stopped watching. The node keeps running"
check_lacks "Ctrl-C during the watch does not run the installer's interrupt handler" "$w_out" "ON_SIGNAL"
check_true "Ctrl-C ends the watch promptly (${w_secs}s)" test "$w_secs" -le 5
# Ctrl-C while journalctl hangs inside `timeout --foreground`: the stand-in
# gets the signal too, so the watch ends at once, not when the read times out.
watch_script 60 "$T/journal-pending" 0 50
python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.setpgid(0, 0); os.execvp(sys.argv[1], sys.argv[1:])' \
  bash "$T/watch.sh" >"$T/watch-int2.out" 2>&1 &
w_pid=$!
sleep 2
w_start=$(date +%s)
kill -INT -- "-$w_pid" 2>/dev/null || true
w_rc=0
wait "$w_pid" || w_rc=$?
w_secs=$(( $(date +%s) - w_start ))
check "Ctrl-C during a hanging read: exit 0" "$w_rc" "0"
check_has "Ctrl-C during a hanging read ends the watch, not the install" "$(cat "$T/watch-int2.out")" "AFTER rc=0"
check_true "Ctrl-C during a hanging read ends the watch promptly (${w_secs}s)" test "$w_secs" -le 5

echo "unit-math: $fails failed"
[[ "$fails" -eq 0 ]]
