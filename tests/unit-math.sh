#!/usr/bin/env bash
# Unit tests for install.sh's pure helpers: wei formatting, comparison and
# the funding text. The functions are extracted from install.sh by name, so
# main never runs and nothing on the system is touched.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Prints one top-level function from install.sh (one-liners included).
extract() {
  awk -v n="$1" '
    index($0, n "() {") == 1 { p = 1; print; if ($0 ~ /}$/ && $0 !~ /\{$/) exit; next }
    p { print; if ($0 ~ /^}/) exit }' install.sh
}

src=""
for fn in say strip_zeros wei_lt wei_to_savdr wei_times checkins_left is_uint json_str json_raw print_funding; do
  body=$(extract "$fn")
  [[ -n "$body" ]] || { echo "FAIL: could not extract $fn from install.sh"; exit 1; }
  src+="$body"$'\n'
done
eval "$src"
# Read by the functions eval'd above, which shellcheck cannot see.
# shellcheck disable=SC2034
MAX_GAS_PRICE_GWEI=50
# shellcheck disable=SC2034
DAYS_TO_FUND=90

fails=0
check() {
  if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}
check_true() { if "${@:2}"; then echo "PASS: $1"; else echo "FAIL: $1"; fails=$((fails + 1)); fi; }
check_false() { if "${@:2}"; then echo "FAIL: $1"; fails=$((fails + 1)); else echo "PASS: $1"; fi; }
check_has() {
  if [[ "$2" == *"$3"* ]]; then echo "PASS: $1"; else echo "FAIL: $1: '$3' not in output"; fails=$((fails + 1)); fi
}

check "0 wei" "$(wei_to_savdr 0)" "0"
check "leading zeros" "$(wei_to_savdr 000)" "0"
check "1 wei" "$(wei_to_savdr 1)" "0.000000000000000001"
check "1 SAVDR" "$(wei_to_savdr 1000000000000000000)" "1"
check "mainnet check-in cost" "$(wei_to_savdr 212500000000000)" "0.0002125"
check "above 64-bit" "$(wei_to_savdr 123456789000000000000)" "123.456789"
check_true "5 < 10" wei_lt 5 10
check_false "10 < 5" wei_lt 10 5
check_false "10 < 10" wei_lt 10 10
check_true "compare above 64-bit" wei_lt 99999999999999999999 100000000000000000000
check_false "leading zeros ignored" wei_lt 0010 9
check "90 check-ins" "$(wei_times 212500000000000 90)" "19125000000000000"
check "check-ins left" "$(checkins_left 1000000000000000000 212500000000000)" "4705"

# The slot-info --node object returned by mainnet (fee 2.125 gwei).
# shellcheck disable=SC2034
SLOT_JSON='{"chainId":7282,"node":"0x6c444c60Ede77B5cEd767467b676160c9F564E97","boundOwner":null,"boundSlot":null,"nodeBalanceWei":"0","checkInGasLimit":100000,"feeType":"eip1559","feePerGasWei":"2125000000","estimatedCheckInCostWei":"212500000000000"}'
out=$(print_funding)
printf '%s\n' "$out" | sed 's/^/    | /'
check_has "per check-in cost" "$out" "about 0.0002125 SAVDR at today's fee"
check_has "gas cap cost" "$out" "at most 0.005 SAVDR at the 50 gwei cap"
check_has "90-day suggestion" "$out" "at least 0.019125 SAVDR for about 90 days"
check_has "balance" "$out" "Current node balance: 0 SAVDR"

# shellcheck disable=SC2034
SLOT_JSON='{"nodeBalanceWei":"0","checkInGasLimit":100000,"feePerGasWei":"0","estimatedCheckInCostWei":"0"}'
out=$(print_funding)
check_has "zero fee explained" "$out" "network fee is 0 right now"

echo "unit-math: $fails failed"
[[ "$fails" -eq 0 ]]
