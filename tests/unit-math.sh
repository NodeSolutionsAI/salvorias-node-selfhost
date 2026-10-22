#!/usr/bin/env bash
# Unit tests for install.sh's pure helpers: wei formatting and comparison,
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
for fn in say lower strip_zeros wei_lt warn wei_to_savdr is_uint json_str json_raw json_list \
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
check "'not EOA' means no SAVDR" "$(checkin_failure_reason 'could not coalesce error (error={ "code": -32000, "message": "invalid transaction: the sender is not EOA" }, payload={ "id": 9 }, code=UNKNOWN_ERROR, version=6.16.0)')" "$NOSAVDR"
check "'insufficient funds' means no SAVDR" "$(checkin_failure_reason 'insufficient funds for intrinsic transaction cost (transaction="0x02", info={ }, code=INSUFFICIENT_FUNDS, version=6.16.0)')" "$NOSAVDR"
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

echo "## the first check-in watch: bounded, Ctrl-C safe, never fails the install"
# The real watch_first_checkin with systemctl, journalctl and timeout stood
# in for; the journal is a file the test writes.
watch_script() {
  local secs="$1" journal="$2"
  # The quoted lines are the child shell's own code.
  # shellcheck disable=SC2016
  { printf '%s\n' 'set -euo pipefail' "SALVORIAS_FIRST_CHECKIN_SECONDS=$secs" "JOURNAL=$journal" \
      "NODE_ADDRESS=$NODE_ADDRESS" 'NET_EXPLORER_URL=https://testnet.savscanner.io' 'UNIT_NAME=u' \
      'say() { printf "%s\n" "$*"; }' 'cmd_hint() { printf "sudo salvorias-selfhost %s" "$1"; }' \
      'systemctl() { printf "0123456789abcdef0123456789abcdef\n"; }' \
      'journalctl() { [[ "$1" == _SYSTEMD_INVOCATION_ID=0123456789abcdef0123456789abcdef ]] && cat "$JOURNAL"; }' \
      'timeout() { shift; "$@"; }' 'on_signal() { echo ON_SIGNAL; exit 130; }' 'trap on_signal INT'
    extract_var ACTIVE_NOTE
    for f in first_checkin_outcome checkin_failure_reason print_first_checkin watch_first_checkin; do extract "$f"; done
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
check_has "a failed check-in is reported" "$w_out" "The first check-in failed: $NOSAVDR."
check_has "a failed check-in does not fail the install" "$w_out" "AFTER rc=0"
printf '%s\n' "${P}── Cycle #1 ──" >"$T/journal-pending"
watch_script 3 "$T/journal-pending"
w_start=$(date +%s)
w_out=$(bash "$T/watch.sh" 2>&1)
w_secs=$(( $(date +%s) - w_start ))
check_has "no result: the timeout line" "$w_out" "No check-in result yet; run sudo salvorias-selfhost status in a few minutes."
check_has "no result: the install goes on" "$w_out" "AFTER rc=0"
check_true "the watch is bounded (3s asked, took ${w_secs}s)" test "$w_secs" -le 8
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

echo "unit-math: $fails failed"
[[ "$fails" -eq 0 ]]
