#!/usr/bin/env bash
# Unit tests for install.sh's pure helpers: wei formatting and comparison,
# the funding text, URL and repo validation, checksums.txt parsing and the
# ELF header check. The functions (and the regex variables they use) are
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
for var in URL_PORT_RE URL_PATH_RE LOCAL_HTTP_RE HTTPS_URL_RE REPO_RE; do
  body=$(extract_var "$var")
  [[ -n "$body" ]] || { echo "FAIL: could not extract $var from install.sh"; exit 1; }
  src+="$body"$'\n'
done
for fn in say strip_zeros wei_lt wei_to_savdr wei_times checkins_left is_uint json_str json_raw print_funding \
    is_local_http_url is_safe_url is_safe_repo checksum_for check_elf; do
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
check "reserve plus 90 check-ins" "$(wei_times 212500000000000 91)" "19337500000000000"
check "check-ins left" "$(checkins_left 1000000000000000000 212500000000000)" "4705"

echo "## funding text"
# The slot-info --node object returned by mainnet (max fee 2.125 gwei).
# shellcheck disable=SC2034
SLOT_JSON='{"chainId":7282,"node":"0x6c444c60Ede77B5cEd767467b676160c9F564E97","boundOwner":null,"boundSlot":null,"nodeBalanceWei":"0","checkInGasLimit":100000,"feeType":"eip1559","feePerGasWei":"2125000000","estimatedCheckInCostWei":"212500000000000"}'
out=$(print_funding)
printf '%s\n' "$out" | sed 's/^/    | /'
check_has "reserve, not a fee" "$out" "Keep at least 0.0002125 SAVDR on the node (the per-check-in reserve"
check_has "actual fees are lower" "$out" "actual fees are lower"
check_has "reserve at the cap" "$out" "reserve is at most 0.005 SAVDR"
check_has "90-day suggestion is reserve plus 90" "$out" "Suggested for about 90 days: 0.0193375 SAVDR"
check_has "suggestion explained" "$out" "the reserve"$'\n'"   plus 90 check-ins charged at the full reserve"
check_lacks "no claim that a check-in costs the reserve" "$out" "One check-in costs"
check_has "balance" "$out" "Current node balance: 0 SAVDR"

# shellcheck disable=SC2034
SLOT_JSON='{"nodeBalanceWei":"0","checkInGasLimit":100000,"feePerGasWei":"0","estimatedCheckInCostWei":"0"}'
out=$(print_funding)
check_has "zero fee explained" "$out" "network fee is 0 right now"
check_has "zero fee: cap reserve named" "$out" "reserves up to"

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

echo "unit-math: $fails failed"
[[ "$fails" -eq 0 ]]
