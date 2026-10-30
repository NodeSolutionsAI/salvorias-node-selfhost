#!/usr/bin/env bash
# salvorias-selfhost-installer
#
# Salvorias self-host node installer.
#
# Sets up ONE Salvorias check-in node on this Linux server for an individual
# license holder: downloads and verifies the node binary, generates (or
# imports) the node key on this server, waits for the owner to register the
# node in the Salvorias app, then runs it as a hardened systemd service.
#
# Safety rules this script keeps:
#   - It never asks for, accepts or reads the owner's private key or seed
#     phrase. It only needs the owner's PUBLIC wallet address.
#   - It never prints the node's private key.
#   - It never sends a transaction. Every chain call is a read.
#   - One node per server. A second install is refused.
#   - It takes over nothing it cannot show it made. The fixed paths (/etc,
#     /var/lib and /opt/salvorias, /usr/local/bin/salvorias-node and
#     /usr/local/sbin/salvorias-selfhost) and the salvorias account are used
#     only with proof: the installer's state file, or the marker it leaves for
#     the account it created. Uninstall deletes only what that proof covers.
#   - Text that comes from outside (RPC errors, chain data, the node's
#     journal) goes through clean_text before it is printed.
#   - Root never follows a link it does not own. The data directory is
#     root:salvorias 0750, so the service account cannot add or swap entries
#     there, and every file root touches in it must be a regular, unlinked
#     file. Every download and RPC request is pinned to https, redirects too.
#
# Usage: see usage() below, or run with --help.
# The marker on line 2 lets the self-copy step recognise a genuine copy.

set -euo pipefail

INSTALLER_VERSION="0.1.2"

# ─── Configuration (environment overrides) ────────────────────────────────

SALVORIAS_RELEASE_REPO="${SALVORIAS_RELEASE_REPO:-NodeSolutionsAI/salvorias-node-selfhost}"
# Full base URL that holds the release assets (binaries, install.sh,
# checksums.txt). Empty means GitHub Releases for SALVORIAS_RELEASE_REPO, at the
# tag given by --version, or the latest release when no --version is given.
SALVORIAS_RELEASE_BASE_URL="${SALVORIAS_RELEASE_BASE_URL:-}"
SALVORIAS_WAIT_MINUTES="${SALVORIAS_WAIT_MINUTES:-30}"
SALVORIAS_POLL_SECONDS="${SALVORIAS_POLL_SECONDS:-15}"
SALVORIAS_UPGRADE_WATCH_SECONDS="${SALVORIAS_UPGRADE_WATCH_SECONDS:-30}"
# How long the install watches the journal for the first check-in's outcome.
# 0 skips the watch.
SALVORIAS_FIRST_CHECKIN_SECONDS="${SALVORIAS_FIRST_CHECKIN_SECONDS:-120}"
MIN_UPGRADE_WATCH_SECONDS=10

# ─── Fixed layout ──────────────────────────────────────────────────────────
# Not overridable: the systemd unit, node.env and the docs all name these.

SERVICE_USER="salvorias"
OPT_DIR="/opt/salvorias"
BIN_ROOT="$OPT_DIR/bin"
CURRENT_LINK="$BIN_ROOT/current"
# Names the version kept for `upgrade --rollback`; set by each upgrade.
PREVIOUS_LINK="$BIN_ROOT/previous"
PATH_LINK="/usr/local/bin/salvorias-node"
ETC_DIR="/etc/salvorias"
ENV_FILE="$ETC_DIR/node.env"
STATE_FILE="$ETC_DIR/selfhost.conf"
DATA_DIR="/var/lib/salvorias"
KEY_FILE="$DATA_DIR/node-key.txt"
ADDRESS_FILE="$DATA_DIR/node-address.txt"
UNIT_NAME="salvorias-node.service"
UNIT_FILE="/etc/systemd/system/$UNIT_NAME"
SELF_PATH="/usr/local/sbin/salvorias-selfhost"
SELF_MARKER="# salvorias-selfhost-installer"
# Held by every command that changes the server (all but status), so two runs
# can never interleave. In /run itself (root:root 0755), not the world-writable
# /run/lock, so no other account can create, replace or link this path first.
LOCK_FILE="/run/salvorias-selfhost.lock"
# Written into DATA_DIR as soon as an install has created the service account,
# and again by an uninstall that keeps the key, so a later install still knows
# that this installer created the account (and the directories beside it).
ACCOUNT_MARKER="$DATA_DIR/installer-account.txt"
# First line of the state file. With the marker above it is how the installer
# tells its own files from ones that merely have the same fixed name.
STATE_FILE_HEADER="# Written by the Salvorias self-host installer. The node daemon does not read"

# Self-host wallets are not fee-exempt, so the daemon must pay the live
# network fee. The cap stops it from paying through a fee spike.
GAS_PRICE_MODE="network"
MAX_GAS_PRICE_GWEI=50
PROBE_NODE_ADDRESS="0x0000000000000000000000000000000000000001"

EXIT_ERROR=1
EXIT_USAGE=2
EXIT_STOPPED=3
EXIT_LOCKED=4

# ─── Output helpers ────────────────────────────────────────────────────────

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit "$EXIT_ERROR"; }
usage_error() { printf 'ERROR: %s\n' "$*" >&2; printf 'Run with --help for usage.\n' >&2; exit "$EXIT_USAGE"; }
# A precondition outside this server is not met (no license, not registered
# yet). Nothing is broken; the user has something to do.
stop() { printf '\nSTOPPED: %s\n' "$*" >&2; exit "$EXIT_STOPPED"; }
banner() { printf '\n=== %s ===\n' "$*"; }
rule() { printf '%s\n' "========================================================================"; }

# clean_text [-n MAX] TEXT: TEXT that came from outside this script (an RPC
# server, chain data, the node's journal, a download tool) made safe to put in
# a message. Control characters (escape sequences, carriage returns that could
# overwrite the line) are dropped, line breaks and tabs become a space, runs
# of spaces collapse, and at most MAX characters (default 200) are kept. The
# result is one line, printed without a trailing newline.
clean_text() {
  local max=200 s
  if [[ $# -ge 2 && "$1" == -n && "$2" =~ ^[0-9]+$ ]]; then max="$2"; shift 2; fi
  s="$*"
  # Bounds the work below on an oversized response.
  s="${s:0:4096}"
  s="${s//[[:space:]]/ }"
  s="${s//[^[:print:]]/}"
  while [[ "$s" == *"  "* ]]; do s="${s//  / }"; done
  s="${s# }"
  s="${s:0:max}"
  s="${s% }"
  printf '%s' "$s"
}

usage() {
  cat <<EOF
Salvorias self-host node installer v$INSTALLER_VERSION

Runs ONE Salvorias check-in node on this server for your node license.
Needs root (sudo), Linux with systemd. Tested on Ubuntu 22.04+ and Debian 12+.

USAGE
  sudo bash install.sh [command] [options]
  curl --proto '=https' --proto-redir '=https' -fsSL <install.sh url> | sudo bash -s -- [command] [options]
  sudo salvorias-selfhost <command> [options]     (after install)

COMMANDS
  install          Set up the node (default command)
  resume           Continue an install that was waiting for funding and registration
  status           Service state, version, registration, balance, recent logs
  upgrade          Install a newer node binary; rolls back if it fails to run.
                   Also restarts a stopped service and repairs file ownership
  backup-key       Copy the node key to a root-only file for offline storage
  uninstall        Remove the service, binary and config (keeps the key)

INSTALL OPTIONS
  --owner 0x...            License owner's PUBLIC wallet address (else prompted)
  --network NAME           mainnet (default) or testnet
  --rpc-url URL            Use a different RPC endpoint for that network
  --version vX             Node release tag to install (default: latest)
  --wait-minutes N         How long to wait for funding and registration (default: $SALVORIAS_WAIT_MINUTES)
  --import-key PATH        Use an existing node key (from backup-key) instead
                           of generating a new one. For moving a node to a new
                           server. The file must not be group/world readable.
  --binary PATH            Use a local salvorias-node binary instead of
                           downloading (offline/testing; not checksum-verified)
  --self PATH              Install this file as salvorias-selfhost instead of
                           the running script or a release download
                           (offline/testing)

OTHER OPTIONS
  resume     [--wait-minutes N]
  upgrade    [--version vX] [--binary PATH] [--self PATH]
  upgrade    --rollback            Switch back to the previous kept version
  backup-key [--out PATH]          (default: /root/salvorias-node-key-backup-<time>.txt)
  uninstall  [--yes] [--purge-key] (--purge-key also deletes the node key, after
                                    a typed confirmation)
  -h, --help                       Show this help
  --version                        Show the installer version (as the only argument)

ENVIRONMENT
  SALVORIAS_RELEASE_BASE_URL   Base URL holding the release assets and checksums.txt
  SALVORIAS_WAIT_MINUTES       Default for --wait-minutes
  SALVORIAS_POLL_SECONDS       Funding and registration poll interval (default 15)
  SALVORIAS_UPGRADE_WATCH_SECONDS  How long upgrade watches the new version
                               before keeping it (default 30, minimum 10)
  SALVORIAS_FIRST_CHECKIN_SECONDS  How long install watches for the first
                               check-in's result (default 120, 0 skips it)

EXIT CODES
  0 ok   1 error   2 bad usage or input   3 stopped: something to do outside
  this server (no license, not funded or registered yet)   4 another salvorias-selfhost
  command is running   130 interrupted
EOF
}

# ─── Networks ──────────────────────────────────────────────────────────────

# Sets NET_* for a built-in network.
set_network() {
  case "$1" in
    mainnet)
      NET_RPC_URL="https://salvorias.net"
      NET_CHAIN_ID=7282
      NET_CHECKIN="0x88ac542c7B8a2952f704B0ed24CFC17F64527D8D"
      NET_NFT="0xc01E4070A3BBBe79b03bB4b11479C5D39aFE1E87"
      NET_TREASURY="0xDEfad8fE8Af1ef0B8d0D00251A80391c9Ed04243"
      NET_APP_URL="https://app.salvorias.com"
      NET_EXPLORER_URL="https://savscanner.io"
      ;;
    testnet)
      NET_RPC_URL="https://testnet.salvorias.net"
      NET_CHAIN_ID=7283
      NET_CHECKIN="0x51F6122C6014866Bd9443E21b05033b195A1fF27"
      NET_NFT="0xa1CF5786c6ceC9E8D0BbACEdF2cc98dAe4614363"
      NET_TREASURY="0x7e8ecebF965dE86fDE7Ebc7F3020813d656CF723"
      # The dev portal is the one built for chain 7283 (its bundle points at
      # testnet.salvorias.net); the production portal only knows mainnet.
      NET_APP_URL="https://app.dev.salvorias.com"
      NET_EXPLORER_URL="https://testnet.savscanner.io"
      ;;
    *)
      usage_error "Unknown network '$1'. Use mainnet or testnet."
      ;;
  esac
  NETWORK="$1"
}

# ─── Small validators and arithmetic ──────────────────────────────────────

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
# No leading zeros: bash arithmetic reads 08 as invalid octal, so a value
# that passed here would still fail later in (( )).
is_uint() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }
lower() { printf '%s' "${1,,}"; }

# Plain http is only accepted for a local endpoint (a test mock or a local
# node). Anything leaving the machine must be https. URLs are also written to
# node.env and selfhost.conf, so they are held to a plain character set: no
# userinfo (user@host), spaces, quotes, %, $ or backslashes.
URL_PORT_RE='(:[0-9]{1,5})?'
URL_PATH_RE='(/[A-Za-z0-9._~/-]*)?([?][A-Za-z0-9._~=&-]*)?'
LOCAL_HTTP_RE="^http://(127[.]0[.]0[.]1|localhost)${URL_PORT_RE}${URL_PATH_RE}\$"
HTTPS_URL_RE="^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?${URL_PORT_RE}${URL_PATH_RE}\$"
is_local_http_url() { [[ "$1" =~ $LOCAL_HTTP_RE ]]; }
is_safe_url() { [[ "$1" =~ $HTTPS_URL_RE ]] || is_local_http_url "$1"; }
require_safe_url() {
  is_safe_url "$1" || usage_error "$2 must be an https:// URL with a plain host name and path (plain http is only allowed for http://127.0.0.1 or http://localhost): $1"
}

# GitHub owner/name, used in download URLs and in the unit file.
REPO_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
is_safe_repo() { [[ "$1" =~ $REPO_RE ]]; }

# Last check before a value is written to node.env, selfhost.conf or the unit
# file. Every value is validated where it comes from; this makes sure that a
# newline, quote, %, $ or backslash can never reach those files regardless.
PLAIN_VALUE_RE='^[A-Za-z0-9._:/?=&~-]+$'
assert_plain_values() {
  local v
  for v in "$@"; do
    [[ "$v" =~ $PLAIN_VALUE_RE ]] || die "Refusing to write an unexpected value into the service configuration: '${v:0:80}'."
  done
}

# Wei amounts can exceed 64-bit shell arithmetic, so they are handled as
# decimal strings wherever exactness matters.
strip_zeros() {
  local v="${1#"${1%%[!0]*}"}"
  printf '%s' "${v:-0}"
}

# wei_lt A B: true when A < B.
wei_lt() {
  local a b
  a=$(strip_zeros "$1")
  b=$(strip_zeros "$2")
  if (( ${#a} != ${#b} )); then
    (( ${#a} < ${#b} ))
  else
    [[ "$a" < "$b" ]]
  fi
}

# Formats a wei amount as SAVDR (18 decimals), trimming trailing zeros.
wei_to_savdr() {
  local w int frac
  w=$(strip_zeros "$1")
  while (( ${#w} < 19 )); do w="0$w"; done
  int="${w:0:${#w}-18}"
  frac="${w: -18}"
  while [[ "$frac" == *0 ]]; do frac="${frac%0}"; done
  if [[ -n "$frac" ]]; then printf '%s.%s' "$int" "$frac"; else printf '%s' "$int"; fi
}

# ─── Release file checks ───────────────────────────────────────────────────

# checksum_for ASSET FILE: prints the sha256 that checksums.txt lists for
# ASSET, in lower case. Accepts sha256sum's text ("hash  name") and binary
# ("hash *name") lines, and CRLF line endings. Fails when there is no entry
# or when two entries for ASSET disagree.
checksum_for() {
  local found
  found=$(awk -v f="$1" '{ sub(/\r$/, "") } NF == 2 && ($2 == f || $2 == "*" f) { print tolower($1) }' "$2" | sort -u)
  [[ "$found" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$found"
}

# check_elf FILE: true when FILE starts with the header of a 64-bit
# little-endian ELF executable for this server's CPU (ASSET_ARCH). Runs
# before any node binary is executed. Sets ELF_PROBLEM when it fails.
ELF_PROBLEM=""
check_elf() {
  local hdr want
  hdr=$(head -c 20 -- "$1" 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
  case "$ASSET_ARCH" in
    linux-x64) want="3e00" ;;     # e_machine EM_X86_64, little-endian
    linux-arm64) want="b700" ;;   # e_machine EM_AARCH64
    *) want="" ;;
  esac
  if [[ "${hdr:0:8}" != "7f454c46" ]]; then
    ELF_PROBLEM="it is not a Linux executable (no ELF header)"
  elif [[ "${hdr:8:4}" != "0201" ]]; then
    ELF_PROBLEM="it is not a 64-bit little-endian executable"
  elif [[ "${hdr:36:4}" != "$want" ]]; then
    ELF_PROBLEM="it is built for another CPU (ELF machine 0x${hdr:38:2}${hdr:36:2}), not $ASSET_ARCH"
  else
    ELF_PROBLEM=""
    return 0
  fi
  return 1
}

# ─── Invocation hints ──────────────────────────────────────────────────────

RUNNING_FILE=""

# Set only when bash is running this installer from a file (sudo bash
# install.sh, or the installed salvorias-selfhost). For a piped run (curl |
# sudo bash) bash reports a pseudo source name such as "main", and a file of
# that name in the current directory must never be taken for this script. The
# bottom of the BASH_SOURCE stack equals $0 only for a script file.
detect_running_file() {
  local n="${#BASH_SOURCE[@]}" src=""
  if (( n > 0 )); then src="${BASH_SOURCE[n-1]}"; fi
  if [[ -n "$src" && "$src" == "$0" && -f "$src" ]]; then
    RUNNING_FILE="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
  fi
}

# How the user should run a later command, given how this run was started.
# cmd_hint COMMAND [self-gone]: with "self-gone", leaves out salvorias-selfhost
# (for text printed just before an uninstall removes it).
cmd_hint() {
  if [[ -x "$SELF_PATH" && "${2:-}" != "self-gone" ]]; then
    printf 'sudo salvorias-selfhost %s' "$1"
  elif [[ -n "$RUNNING_FILE" && ( "${2:-}" != "self-gone" || "$RUNNING_FILE" != "$SELF_PATH" ) ]]; then
    printf 'sudo bash %s %s' "$RUNNING_FILE" "$1"
  else
    printf "curl --proto '=https' --proto-redir '=https' -fsSL https://github.com/%s/releases/latest/download/install.sh | sudo bash -s -- %s" "$SALVORIAS_RELEASE_REPO" "$1"
  fi
}

# ─── Cleanup and signals ───────────────────────────────────────────────────

TMP_DIR=""
DATA_STAGE=""
INTERRUPT_HINT=""
# Set while an upgrade (or rollback) is being watched: the version to switch
# back to if the run is interrupted, and the directory that run placed.
UPGRADE_ROLLBACK_TO=""
UPGRADE_PLACED=""
UPGRADE_PLACED_NEW=0

# Staged key copies are shredded, not just unlinked.
cleanup() {
  local d
  if [[ -n "$BACKUP_TMP" && -f "$BACKUP_TMP" && ! -L "$BACKUP_TMP" ]]; then
    shred -u -- "$BACKUP_TMP" 2>/dev/null || rm -f -- "$BACKUP_TMP"
  fi
  for d in "$TMP_DIR" "$DATA_STAGE"; do
    if [[ -n "$d" && -d "$d" && ! -L "$d" ]]; then
      find "$d" -type f \( -name 'key-*' -o -name 'node-key.txt' \) -exec shred -u {} + 2>/dev/null || true
      rm -rf "$d"
    fi
  done
}

on_signal() {
  trap '' INT TERM HUP
  printf '\n\nInterrupted.\n' >&2
  if [[ -n "$UPGRADE_ROLLBACK_TO" ]]; then
    printf 'Switching back to %s ...\n' "$UPGRADE_ROLLBACK_TO" >&2
    undo_upgrade
    if service_stays_up 6; then
      printf 'Switched back to %s, which is running.\n' "$(current_version_name)" >&2
    else
      printf 'Switched back to %s, but the service is not staying up. Check: %s\n' "$(current_version_name)" "$(cmd_hint status)" >&2
    fi
  fi
  if [[ -n "$INTERRUPT_HINT" ]]; then printf '%s\n' "$INTERRUPT_HINT" >&2; fi
  exit 130
}

# A fresh root-owned 0700 directory (mktemp -d) for downloads and key copies.
make_tmp_dir() {
  if [[ -z "$TMP_DIR" ]]; then
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/salvorias-install.XXXXXX")
    # Absolute, because node_run runs the binary from / (a relative TMPDIR
    # would otherwise point somewhere else there).
    if [[ "$TMP_DIR" != /* ]]; then TMP_DIR="$PWD/$TMP_DIR"; fi
  fi
}

# Root-only staging directory inside DATA_DIR, for files that are then
# renamed into place there (a rename stays on one file system and never
# follows a link at the destination). DATA_DIR must already be secured.
make_data_stage() {
  if [[ -z "$DATA_STAGE" ]]; then
    DATA_STAGE=$(mktemp -d "$DATA_DIR/.stage.XXXXXX")
  fi
}

# Every request is pinned to https, after redirects too (GitHub release URLs
# redirect to a CDN), so a redirect can never downgrade to plain http. The
# one exception, an explicit local http URL, may not redirect at all.
# The URL must be the last argument.
curl_safe() {
  local url="${*: -1}"
  if is_local_http_url "$url"; then
    curl --proto '=http' --max-redirs 0 "$@"
  else
    curl --proto '=https' --proto-redir '=https' "$@"
  fi
}

# ─── Preflight ─────────────────────────────────────────────────────────────

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    printf 'ERROR: This needs root. Rerun it with sudo, for example:\n  %s\n' "$(cmd_hint "${COMMAND}")" >&2
    exit "$EXIT_ERROR"
  fi
}

# Takes the exclusive lock that every changing command holds until it exits
# (the kernel drops it with the last open descriptor, also on a crash or a
# signal). Without it two installs could both pass guard_single_node before
# either writes its state. The path is refused if it is a link, and the open
# file must be a root-owned regular file with no other link, so root never
# writes through anything another account put there. The file is left in
# place: /run is cleared at boot, and deleting a lock file that another run
# may already have opened would let two runs hold locks on different files.
take_lock() {
  command -v flock >/dev/null 2>&1 || die "flock is required (package util-linux)."
  [[ ! -L "$LOCK_FILE" ]] || die "$LOCK_FILE is a symbolic link. Refusing to open it. Inspect it, remove it if it is not yours, then rerun."
  [[ ! -e "$LOCK_FILE" || -f "$LOCK_FILE" ]] || die "$LOCK_FILE is not a regular file. Refusing to use it as the lock. Inspect it, remove it if it is not yours, then rerun."
  exec {LOCK_FD}<>"$LOCK_FILE" || die "Could not open the lock file $LOCK_FILE."
  local fd_path="/proc/$$/fd/$LOCK_FD" shape
  shape=$(stat -L -c '%F:%u:%h' -- "$fd_path") || die "Could not inspect the lock file $LOCK_FILE."
  [[ "$shape" == "regular file:0:1" || "$shape" == "regular empty file:0:1" ]] \
    || die "$LOCK_FILE is not a root-owned regular file with a single link ($shape). Refusing to use it as the lock. Inspect it, remove it if it is not yours, then rerun."
  chmod 0600 -- "$fd_path"
  if ! flock -n "$LOCK_FD"; then
    printf 'ERROR: Another salvorias-selfhost command is running on this server (it holds %s). Wait for it to finish, then rerun. Nothing was changed.\n' "$LOCK_FILE" >&2
    exit "$EXIT_LOCKED"
  fi
}

LOCK_FD=""
ASSET_ARCH=""

check_platform() {
  [[ "$(uname -s)" == "Linux" ]] || die "This installer only supports Linux (found $(uname -s))."
  if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    die "systemd is required and is not running on this server. Use a standard Ubuntu 22.04+ or Debian 12+ install (not a container without systemd)."
  fi

  case "$(uname -m)" in
    x86_64|amd64) ASSET_ARCH="linux-x64" ;;
    aarch64|arm64) ASSET_ARCH="linux-arm64" ;;
    *) die "Unsupported CPU architecture $(uname -m). Supported: x86_64, aarch64." ;;
  esac

  local os_id="" os_version="" os_name=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    os_id=$(. /etc/os-release && printf '%s' "${ID:-}")
    # shellcheck disable=SC1091
    os_version=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
    # shellcheck disable=SC1091
    os_name=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-}")
  fi
  local major="${os_version%%.*}"
  local supported=0
  case "$os_id" in
    ubuntu) is_uint "$major" && (( major >= 22 )) && supported=1 ;;
    debian) is_uint "$major" && (( major >= 12 )) && supported=1 ;;
  esac
  if (( supported == 0 )); then
    warn "${os_name:-This OS} is not a tested system (tested: Ubuntu 22.04+, Debian 12+). Continuing; report problems with your OS details."
  fi
}

ensure_tools() {
  if ! command -v curl >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || die "curl is required. Install curl and ca-certificates, then rerun."
    say "Installing curl and ca-certificates (apt)..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates </dev/null >/dev/null
  fi
  local tool
  for tool in curl sha256sum systemctl journalctl useradd getent install awk sed grep mktemp timeout od head find stat dd shred cmp; do
    command -v "$tool" >/dev/null 2>&1 || die "Required command '$tool' was not found. Install it, then rerun."
  done
}

# Confirms outbound HTTPS to the RPC works and that it serves the expected
# chain, before anything is downloaded or written.
check_rpc() {
  local body hex rc=0
  require_safe_url "$RPC_URL" "--rpc-url"
  body=$(curl_safe -fsS --max-time 20 -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$RPC_URL" 2>&1) || rc=$?
  if (( rc == 22 )); then
    # Reached the server, which answered with an HTTP error: not a firewall issue.
    die "The Salvorias RPC at $RPC_URL answered with an error ($(clean_text "$body")). It may be down for maintenance; try again later."
  elif (( rc != 0 )); then
    die "Cannot reach the Salvorias RPC at $RPC_URL ($(clean_text "$body")). Check that this server allows outbound HTTPS (port 443)."
  fi
  hex=$(printf '%s' "$body" | sed -n 's/.*"result" *: *"\(0x[0-9a-fA-F]\{1,15\}\)".*/\1/p')
  [[ -n "$hex" ]] || die "The RPC at $RPC_URL did not return a chain id. Response: $(clean_text "$body")"
  if (( hex != NET_CHAIN_ID )); then
    die "The RPC at $RPC_URL is chain $((hex)), but $NETWORK is chain $NET_CHAIN_ID. Use the right --network or --rpc-url."
  fi
  say "RPC ok: $RPC_URL (chain $NET_CHAIN_ID, $NETWORK)"
}

# ─── Release downloads ─────────────────────────────────────────────────────

release_base_url() {
  if [[ -n "$SALVORIAS_RELEASE_BASE_URL" ]]; then
    printf '%s' "${SALVORIAS_RELEASE_BASE_URL%/}"
  elif [[ -n "$OPT_VERSION" ]]; then
    printf 'https://github.com/%s/releases/download/%s' "$SALVORIAS_RELEASE_REPO" "$OPT_VERSION"
  else
    printf 'https://github.com/%s/releases/latest/download' "$SALVORIAS_RELEASE_REPO"
  fi
}

CHECKSUMS_FILE=""

# Downloads checksums.txt once per run.
fetch_checksums() {
  [[ -n "$CHECKSUMS_FILE" ]] && return 0
  local base
  base=$(release_base_url)
  require_safe_url "$base" "SALVORIAS_RELEASE_BASE_URL"
  make_tmp_dir
  if ! curl_safe -fsSL --retry 3 --max-time 60 -o "$TMP_DIR/checksums.txt" "$base/checksums.txt"; then
    die "Could not download $base/checksums.txt. Check the release exists (--version) and that this server can reach it."
  fi
  CHECKSUMS_FILE="$TMP_DIR/checksums.txt"
}

# set_binary_curl_opts SHOW: sets CURL_DL_OPTS, the curl options for the node
# binary download (about 110 MB), the one download where a slow link is
# realistic. SHOW is "yes" when stderr is a terminal.
#  - Progress: curl's own bar, on stderr, only for a person watching. Without
#    -s curl would draw its meter into logs and CI output too, so every other
#    case keeps -s (and -S keeps the errors).
#  - Time limits: a fixed short --max-time killed healthy but slow downloads
#    (at 0.4 MB/s the file needs about 5 minutes). Instead it gives up when the
#    speed stays under 1 KB/s for 2 minutes, with a generous hour as the
#    overall cap per attempt. A stall is a timeout, so --retry covers it.
set_binary_curl_opts() {
  CURL_DL_OPTS=(--retry 3 --speed-limit 1024 --speed-time 120 --max-time 3600)
  if [[ "$1" == yes ]]; then
    CURL_DL_OPTS+=(-fSL --progress-bar)
  else
    CURL_DL_OPTS+=(-fsSL)
  fi
}

# download_verified ASSET DEST [binary]: downloads a release asset and checks
# it against checksums.txt. Any mismatch or missing entry aborts the run. The
# optional third word "binary" selects the long-download behaviour above;
# every other file keeps the short quiet download.
download_verified() {
  local asset="$1" dest="$2" kind="${3:-}" base expected actual show=no
  fetch_checksums
  base=$(release_base_url)
  expected=$(checksum_for "$asset" "$CHECKSUMS_FILE") \
    || die "checksums.txt at $base has no single valid entry for $asset. Refusing to install an unverified file."
  say "Downloading $asset ..."
  if [[ "$kind" == binary ]]; then
    if [[ -t 2 ]]; then show=yes; fi
    set_binary_curl_opts "$show"
  else
    CURL_DL_OPTS=(-fsSL --retry 3 --max-time 300)
  fi
  if ! curl_safe "${CURL_DL_OPTS[@]}" -o "$dest" "$base/$asset"; then
    # The bar leaves the cursor mid-line; put the error on its own line.
    if [[ "$show" == yes ]]; then printf '\n' >&2; fi
    rm -f "$dest"
    die "Could not download $base/$asset."
  fi
  actual=$(sha256sum "$dest" | awk '{ print $1 }')
  if [[ "$expected" != "$(lower "$actual")" ]]; then
    rm -f "$dest"
    die "Checksum mismatch for $asset (expected $expected, got $actual). The download is corrupt or has been tampered with. Nothing was installed from it."
  fi
  say "Checksum verified: $asset"
}

# ─── Node binary ───────────────────────────────────────────────────────────

STAGED_BIN=""
STAGED_VERSION=""
# The version becomes a directory name under /opt/salvorias/bin, so it must
# start with a letter or digit: never ".", "..", a dot file or an option.
VERSION_LINE_SED='s/^salvorias-node v\([0-9A-Za-z][0-9A-Za-z._+-]\{0,63\}\)$/\1/p'

# Puts a runnable, verified binary in the temp dir and reads its version.
stage_binary() {
  make_tmp_dir
  STAGED_BIN="$TMP_DIR/salvorias-node"
  if [[ -n "$OPT_BINARY" ]]; then
    [[ -f "$OPT_BINARY" ]] || usage_error "--binary file not found: $OPT_BINARY"
    install -m 0755 "$OPT_BINARY" "$STAGED_BIN"
    say "Using local binary $OPT_BINARY"
    say "  sha256 $(sha256sum "$STAGED_BIN" | awk '{ print $1 }') (not checked against a release; compare it yourself)"
  else
    download_verified "salvorias-node-$ASSET_ARCH" "$STAGED_BIN" binary
    chmod 0755 "$STAGED_BIN"
  fi
  check_elf "$STAGED_BIN" || die "The node binary cannot be used on this server: $ELF_PROBLEM. Nothing was changed."

  local out rc=0
  out=$(node_run 60 "$STAGED_BIN" version </dev/null 2>&1) || rc=$?
  if (( rc != 0 )); then
    die "The node binary does not run on this server (exit $rc: $(clean_text "$out")). Check it matches this CPU ($ASSET_ARCH). If ${TMPDIR:-/tmp} is mounted noexec, rerun with TMPDIR set to a directory that allows execution."
  fi
  STAGED_VERSION=$(printf '%s\n' "$out" | sed -n "$VERSION_LINE_SED" | head -n 1)
  [[ -n "$STAGED_VERSION" ]] || die "Unexpected output from 'salvorias-node version': $(clean_text "$out")"
  say "Node binary version: $STAGED_VERSION"
}

file_sha() { sha256sum "$1" | awk '{ print $1 }'; }

PLACED_NAME=""
PLACED_EXISTED=0

# Copies the staged binary to /opt/salvorias/bin/<version>/. A different
# binary that reports the same version gets its own directory, so an
# existing (possibly running) version is never overwritten in place.
place_binary() {
  local sha name
  sha=$(file_sha "$STAGED_BIN")
  name="$STAGED_VERSION"
  case "$name" in
    current|previous) die "The node binary reports the version '$name', which is reserved here." ;;
    .*|*/*) die "The node binary reports the version '$name', which cannot be used as a directory name." ;;
  esac
  if [[ -e "$BIN_ROOT/$name/salvorias-node" && "$(file_sha "$BIN_ROOT/$name/salvorias-node")" != "$sha" ]]; then
    name="$STAGED_VERSION-${sha:0:12}"
  fi
  PLACED_EXISTED=0
  if [[ -e "$BIN_ROOT/$name/salvorias-node" ]]; then PLACED_EXISTED=1; fi
  install -d -m 0755 -o root -g root "$BIN_ROOT/$name"
  if (( PLACED_EXISTED == 0 )); then
    install -m 0755 -o root -g root "$STAGED_BIN" "$BIN_ROOT/$name/.salvorias-node.new"
    mv -f "$BIN_ROOT/$name/.salvorias-node.new" "$BIN_ROOT/$name/salvorias-node"
  fi
  PLACED_NAME="$name"
}

# Atomically points /opt/salvorias/bin/current at a version directory.
switch_current() {
  if [[ -e "$PATH_LINK" || -L "$PATH_LINK" ]] && ! path_link_is_ours; then
    die "$PATH_LINK is not the link this installer makes (to $CURRENT_LINK/salvorias-node). Refusing to replace it. Move it aside ('sudo mv $PATH_LINK $PATH_LINK.old'), then rerun."
  fi
  ln -sfn "$1" "$BIN_ROOT/.current.new"
  mv -Tf "$BIN_ROOT/.current.new" "$CURRENT_LINK"
  ln -sfn "$CURRENT_LINK/salvorias-node" "$PATH_LINK"
}

current_version_name() {
  readlink "$CURRENT_LINK" 2>/dev/null || true
}

set_previous_link() {
  [[ -n "$1" ]] || return 0
  ln -sfn "$1" "$BIN_ROOT/.previous.new"
  mv -Tf "$BIN_ROOT/.previous.new" "$PREVIOUS_LINK"
}

# The version `upgrade --rollback` switches to. Installs from before the
# previous link existed keep exactly one other version directory; use it.
previous_version_name() {
  local p dir cur others=()
  p=$(readlink "$PREVIOUS_LINK" 2>/dev/null || true)
  if [[ -z "$p" ]]; then
    cur=$(current_version_name)
    for dir in "$BIN_ROOT"/*; do
      [[ -d "$dir" && ! -L "$dir" && "$(basename "$dir")" != "$cur" ]] && others+=("$(basename "$dir")")
    done
    if (( ${#others[@]} == 1 )); then p="${others[0]}"; fi
  fi
  printf '%s' "$p"
}

# ─── Installer self-copy ───────────────────────────────────────────────────

# Installs a copy of this installer as /usr/local/sbin/salvorias-selfhost so
# later commands work even after a `curl | sudo bash` install. Source, in
# order: --self PATH; the file this run was started from; install.sh from the
# release, verified against checksums.txt. A failure here never blocks the
# node itself, so it warns rather than aborts.
install_self_copy() {
  local src="" tmp
  make_tmp_dir
  if [[ -n "$OPT_SELF" ]]; then
    [[ -f "$OPT_SELF" ]] || usage_error "--self file not found: $OPT_SELF"
    src="$OPT_SELF"
  elif [[ -n "$RUNNING_FILE" && "$RUNNING_FILE" != "$SELF_PATH" ]]; then
    src="$RUNNING_FILE"
  elif [[ -n "$RUNNING_FILE" && -z "$OPT_BINARY" ]] || [[ -z "$RUNNING_FILE" ]]; then
    if ( download_verified "install.sh" "$TMP_DIR/install.sh" ) >/dev/null 2>"$TMP_DIR/self.err"; then
      src="$TMP_DIR/install.sh"
    else
      warn "Could not fetch a verified install.sh for $SELF_PATH ($(clean_text "$(head -c 4096 "$TMP_DIR/self.err")")). Later commands: download install.sh and run it with sudo bash."
      return 0
    fi
  else
    return 0
  fi

  if [[ "$(sed -n 2p "$src")" != "$SELF_MARKER" ]] || ! bash -n "$src" 2>/dev/null; then
    warn "$src does not look like this installer; not installing it as $SELF_PATH."
    return 0
  fi
  if [[ -e "$SELF_PATH" || -L "$SELF_PATH" ]] && ! self_file_is_ours; then
    warn "$SELF_PATH exists and is not a copy of this installer; leaving it alone. Later commands: use the installer you downloaded (sudo bash install.sh <command>)."
    return 0
  fi
  if [[ -f "$SELF_PATH" ]] && cmp -s "$src" "$SELF_PATH"; then
    return 0
  fi
  install -d -m 0755 /usr/local/sbin
  tmp=$(mktemp /usr/local/sbin/.salvorias-selfhost.XXXXXX)
  cat "$src" >"$tmp"
  chown root:root "$tmp"
  chmod 0755 "$tmp"
  # Rename rather than overwrite: a running copy keeps reading its own inode.
  mv -f "$tmp" "$SELF_PATH"
  say "Installed management command: $SELF_PATH"
}

# ─── Running the node binary ───────────────────────────────────────────────

# The node binary takes its settings from the environment (RPC_URL,
# CHECKIN_CONTRACT, NFT_CONTRACT, NODE_KEYS_FILE, NODE_PRIVATE_KEY(S),
# SALVORIAS_NODE_VERSION, ...), and a Bun executable may also load a .env
# file from its working directory. The installer passes everything it means
# on the command line, so it runs the binary with an empty environment (PATH
# and HOME only), from /: nothing set in the caller's shell or cwd can change
# what a query reports. The service itself gets its settings from node.env.
NODE_RUN_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# node_run SECONDS BIN ARGS...: BIN and every path in ARGS must be absolute.
node_run() {
  local secs="$1" bin="$2"
  shift 2
  ( cd / && exec timeout "$secs" env -i PATH="$NODE_RUN_PATH" HOME=/root "$bin" "$@" )
}

# ─── slot-info ─────────────────────────────────────────────────────────────

SLOT_JSON=""

# run_slot_info BIN [NODE]: read-only chain query. Sets SLOT_JSON and
# returns the binary's exit code (0 ok, 1 RPC error, 2 bad input).
run_slot_info() {
  local bin="$1" node="${2:-}" rc=0
  local args=(slot-info --rpc-url "$RPC_URL" --contract "$NET_CHECKIN" --owner "$OWNER")
  if [[ -n "$node" ]]; then args+=(--node "$node"); fi
  SLOT_JSON=$(node_run 120 "$bin" "${args[@]}" </dev/null 2>/dev/null) || rc=$?
  return "$rc"
}

# slot-info prints one flat JSON object (JSON.stringify of known fields), so
# these extractors cover it without adding a jq dependency.
json_str() { printf '%s' "$SLOT_JSON" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
json_raw() { printf '%s' "$SLOT_JSON" | sed -n "s/.*\"$1\":\([^,}\"]*\).*/\1/p"; }
# json_list KEY prints a list of whole numbers, comma-separated ("" for []).
# It fails when KEY is missing or is not such a list, so a missing key is
# never mistaken for an empty list.
json_list() {
  local re="[{,]\"$1\":\\[([^]]*)\\]" items
  [[ "$SLOT_JSON" =~ $re ]] || return 1
  items="${BASH_REMATCH[1]}"
  [[ -z "$items" || "$items" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
  printf '%s' "$items"
}

# Sets OPEN_SLOTS from SLOT_JSON's openSlots, or stops: without a readable
# list the installer cannot tell whether a license is free.
OPEN_SLOTS=""
read_open_slots() {
  OPEN_SLOTS=$(json_list openSlots) \
    || die "The chain query returned no readable list of free licenses, so the installer cannot tell whether one is free. Check that the node binary is current, then try again."
}

# Runs slot-info and stops with a clear message on failure.
query_chain() {
  local rc=0
  run_slot_info "$1" "${2:-}" || rc=$?
  case "$rc" in
    0) ;;
    2) usage_error "The chain query rejected the input: $(clean_text "$(json_str error)")" ;;
    *) die "Could not read the chain at $RPC_URL: $(clean_text "$(json_str error)"). Try again in a few minutes." ;;
  esac
  local chain
  chain=$(json_raw chainId)
  [[ "$chain" == "$NET_CHAIN_ID" ]] || die "Chain query answered from chain '$(clean_text "$chain")', expected $NET_CHAIN_ID."
}

# ─── Owner address input ───────────────────────────────────────────────────

have_tty() { (exec </dev/tty) 2>/dev/null; }

# Classifies what the user typed. Returns: address, private-key, seed, invalid.
classify_owner_input() {
  local s="$1" words
  if [[ "$s" =~ [0-9a-fA-F]{64} ]]; then printf 'private-key'; return; fi
  # Counted through a pipe: a here-string can be spooled to a temp file.
  words=$(printf '%s' "$s" | wc -w)
  if (( words >= 12 )); then printf 'seed'; return; fi
  if is_address "$s"; then printf 'address'; return; fi
  printf 'invalid'
}

secret_warning() {
  local kind="$1" via_flag="$2"
  {
    printf '\n'
    rule
    if [[ "$kind" == "private-key" ]]; then
      printf ' STOP: that looks like a PRIVATE KEY, not a wallet address.\n'
    else
      printf ' STOP: that looks like a SEED / RECOVERY PHRASE, not a wallet address.\n'
    fi
    rule
    printf ' This installer never needs your private key or seed phrase, and it\n'
    printf ' did not save or send what you entered. Never give them to anyone or\n'
    printf ' paste them into any tool.\n\n'
    printf ' What is needed is your PUBLIC wallet address: 0x followed by 40\n'
    printf ' characters, as shown in the Salvorias app.\n'
    if [[ "$via_flag" == "flag" ]]; then
      printf '\n It was passed on the command line, so it is probably in your shell\n'
      printf ' history. Remove it (for bash: history -c, and edit ~/.bash_history).\n'
    fi
    printf ' If you have pasted it anywhere else, move your funds to a new wallet.\n'
    rule
  } >&2
}

OWNER=""

read_owner() {
  local input kind attempts=0
  if [[ -n "$OPT_OWNER" ]]; then
    input="$OPT_OWNER"
    OPT_OWNER=""
    kind=$(classify_owner_input "$input")
    case "$kind" in
      address) OWNER="$input"; return 0 ;;
      private-key|seed) input=""; secret_warning "$kind" flag; exit "$EXIT_USAGE" ;;
      *) usage_error "--owner must be a wallet address: 0x followed by 40 hex characters." ;;
    esac
  fi

  have_tty || usage_error "No terminal to ask for the owner address. Pass it with --owner 0x..."
  say ""
  say "Enter the PUBLIC wallet address that holds your Salvorias node license"
  say "(0x followed by 40 characters; it is shown in the Salvorias app)."
  say "Never enter a private key or seed phrase here."
  while (( attempts < 3 )); do
    attempts=$((attempts + 1))
    printf 'Owner wallet address: ' >/dev/tty
    input=""
    IFS= read -r input </dev/tty || true
    input="${input//[[:space:]]/ }"
    input="${input#"${input%%[! ]*}"}"
    input="${input%"${input##*[! ]}"}"
    kind=$(classify_owner_input "$input")
    case "$kind" in
      address) OWNER="$input"; return 0 ;;
      private-key|seed) input=""; secret_warning "$kind" prompt ;;
      *) input=""; say "That is not a wallet address. It should look like 0x1234...abcd (42 characters)." ;;
    esac
  done
  usage_error "No valid owner address entered."
}

# ─── State file ────────────────────────────────────────────────────────────
# /etc/salvorias/selfhost.conf records what this installer set up. It is
# parsed as KEY=VALUE lines (never sourced) and holds no secrets.

ST_STAGE=""
# yes when this installer created the salvorias account, else no. Only then
# may `uninstall --purge-key` delete it.
ACCOUNT_CREATED=""
# The UID of that account when it was created, so a purge never deletes a
# different account that was later made with the same name.
ACCOUNT_UID=""

write_state() {
  local tmp
  assert_plain_values "$1" "$NETWORK" "$RPC_URL" "$NET_CHAIN_ID" "$NET_CHECKIN" "$NET_NFT" "$NET_TREASURY" "$OWNER" "$NODE_ADDRESS"
  tmp=$(mktemp "$ETC_DIR/.selfhost.conf.XXXXXX")
  cat >"$tmp" <<EOF
$STATE_FILE_HEADER
# this file; it reads node.env. Do not edit.
INSTALLER_VERSION=$INSTALLER_VERSION
STAGE=$1
NETWORK=$NETWORK
RPC_URL=$RPC_URL
CHAIN_ID=$NET_CHAIN_ID
CHECKIN_CONTRACT=$NET_CHECKIN
NFT_CONTRACT=$NET_NFT
TREASURY_CONTRACT=$NET_TREASURY
OWNER_ADDRESS=$OWNER
NODE_ADDRESS=$NODE_ADDRESS
ACCOUNT_CREATED=${ACCOUNT_CREATED:-no}
ACCOUNT_UID=${ACCOUNT_UID}
EOF
  chown root:"$SERVICE_USER" "$tmp"
  chmod 0640 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
  ST_STAGE="$1"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "No Salvorias self-host node found on this server ($STATE_FILE is missing). Install one first: $(cmd_hint install)"
  local line key value network="" rpc="" chain="" checkin="" nft="" treasury="" owner="" node=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    case "$key" in
      STAGE) ST_STAGE="$value" ;;
      NETWORK) network="$value" ;;
      RPC_URL) rpc="$value" ;;
      CHAIN_ID) chain="$value" ;;
      CHECKIN_CONTRACT) checkin="$value" ;;
      NFT_CONTRACT) nft="$value" ;;
      TREASURY_CONTRACT) treasury="$value" ;;
      OWNER_ADDRESS) owner="$value" ;;
      NODE_ADDRESS) node="$value" ;;
      ACCOUNT_CREATED) [[ "$value" == "yes" ]] && ACCOUNT_CREATED=yes ;;
      ACCOUNT_UID) is_uint "$value" && ACCOUNT_UID="$value" ;;
    esac
  done <"$STATE_FILE"

  set_network "$network"
  # The recorded values win over the built-ins, so status and upgrade
  # describe what is actually configured on this server.
  is_uint "$chain" && NET_CHAIN_ID="$chain"
  is_address "$checkin" && NET_CHECKIN="$checkin"
  is_address "$nft" && NET_NFT="$nft"
  is_address "$treasury" && NET_TREASURY="$treasury"
  RPC_URL="${rpc:-$NET_RPC_URL}"
  is_safe_url "$RPC_URL" || die "$STATE_FILE has an RPC_URL that is not a plain https (or local http) URL."
  is_address "$owner" || die "$STATE_FILE has no valid OWNER_ADDRESS."
  is_address "$node" || die "$STATE_FILE has no valid NODE_ADDRESS."
  OWNER="$owner"
  NODE_ADDRESS="$node"
}

# ─── One node per server ───────────────────────────────────────────────────

guard_single_node() {
  if [[ -f "$STATE_FILE" ]] && grep -qE '^STAGE=(awaiting-registration|starting)$' "$STATE_FILE"; then
    printf 'ERROR: An install on this server has not finished (it is waiting for the node to be registered, or for the service to start).\n' >&2
    printf '  Continue it:   %s\n' "$(cmd_hint resume)" >&2
    printf '  Start over:    %s   (then install again)\n' "$(cmd_hint uninstall)" >&2
    exit "$EXIT_ERROR"
  fi
  if [[ -e "$ENV_FILE" || -e "$UNIT_FILE" || -e "$STATE_FILE" ]]; then
    printf 'ERROR: A Salvorias node is already installed on this server. Only one node per server is supported.\n' >&2
    printf '  Check it:      %s\n' "$(cmd_hint status)" >&2
    printf '  New binary:    %s\n' "$(cmd_hint upgrade)" >&2
    printf '  Remove it:     %s\n' "$(cmd_hint uninstall)" >&2
    exit "$EXIT_ERROR"
  fi
}

# ─── System user and directories ───────────────────────────────────────────

# The service runs as salvorias, which can read the node key (and its group
# can read the data directory and node.env). An account of that name that
# this installer did not create could be a login account, belong to other
# groups, or share its group with other accounts, so an existing one is used
# only if it looks exactly like the account `useradd --system --user-group`
# makes below: a system UID, its own system group as its only group, and no
# other account in that group. Read-only.
check_existing_user() {
  local entry group_entry uid_min gid_min shell groups others problems=()
  local -a pw gr
  entry=$(getent passwd "$SERVICE_USER") || return 0
  IFS=: read -r -a pw <<<"$entry"
  uid_min=$(awk '$1 == "UID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null || true)
  is_uint "$uid_min" || uid_min=1000
  gid_min=$(awk '$1 == "GID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null || true)
  is_uint "$gid_min" || gid_min=1000
  if ! is_uint "${pw[2]:-}" || (( pw[2] == 0 || pw[2] >= uid_min )); then
    problems+=("UID ${pw[2]:-?} is not a system UID (1 to $((uid_min - 1)))")
  fi
  if ! is_uint "${pw[3]:-}" || (( pw[3] == 0 || pw[3] >= gid_min )); then
    problems+=("its primary GID ${pw[3]:-?} is not a system GID (1 to $((gid_min - 1)))")
  fi
  if group_entry=$(getent group "$SERVICE_USER"); then
    IFS=: read -r -a gr <<<"$group_entry"
    [[ "${gr[2]:-}" == "${pw[3]:-}" ]] || problems+=("its primary group is not '$SERVICE_USER'")
    [[ -z "${gr[3]:-}" ]] || problems+=("the '$SERVICE_USER' group has other members (${gr[3]})")
  else
    problems+=("there is no group named '$SERVICE_USER'")
  fi
  groups=$(id -Gn -- "$SERVICE_USER" 2>/dev/null || true)
  if [[ "$groups" != "$SERVICE_USER" ]]; then
    problems+=("it belongs to other groups (${groups:-unknown}); it must be in '$SERVICE_USER' only")
  fi
  # Accounts whose primary group is this GID share the group without being
  # listed as members, so the group entry alone does not show them.
  if is_uint "${pw[3]:-}"; then
    others=$(awk -F: -v g="${pw[3]}" -v u="$SERVICE_USER" '$4 == g && $1 != u { printf "%s ", $1 }' /etc/passwd 2>/dev/null || true)
    [[ -z "$others" ]] || problems+=("other accounts have the '$SERVICE_USER' group as their primary group (${others% })")
  fi
  shell="${pw[6]:-}"
  case "$shell" in
    /usr/sbin/nologin|/sbin/nologin|/bin/false|/usr/bin/false) ;;
    *) problems+=("its shell '$shell' allows logins") ;;
  esac
  if [[ "${pw[5]:-}" != "/nonexistent" && -e "${pw[5]:-}" ]]; then
    problems+=("it has a real home directory (${pw[5]})")
  fi
  if (( ${#problems[@]} > 0 )); then
    local joined
    joined=$(printf '%s; ' "${problems[@]}")
    die "An account named '$SERVICE_USER' already exists, but it is not a locked-down system account: ${joined%; }. Refusing to run the node service as it. If this installer did not create it, rename or remove it, then rerun."
  fi
}

# Creates the service account, or reuses one that this installer made for an
# earlier install (account_marker_matches). An account of that name that the
# installer did not make is refused, not adopted: the node key is handed to
# its group, so a login or shared account would get at the key. ACCOUNT_CREATED
# is therefore always yes after an install; the state file still records it,
# and installs from before this rule may say no, which a purge honours.
#
# A new account gets its marker as the very next step, before make_dirs or
# anything else, so a run stopped at any later point leaves proof that the
# account is ours and the next install resumes. The marker lives in DATA_DIR,
# which needs the new group, so DATA_DIR is made here (the same call make_dirs
# would make) just before it. Interrupt signals are held across useradd and the
# marker, then acted on once it exists. What is left is a kill the process
# cannot catch (SIGKILL, power loss) in that few-millisecond span; the
# refusal message tells that user how to recover.
ensure_user() {
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    local nologin saved held=""
    nologin=$(command -v nologin || printf '/usr/sbin/nologin')
    saved=$(trap -p INT TERM HUP)
    trap 'held=1' INT TERM HUP
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell "$nologin" "$SERVICE_USER"
    # From here a failure must stop the run with the way out, not leave an
    # account that the next install refuses. A DATA_DIR this made is removed
    # again, or the next install would refuse it as unproven; the userdel the
    # message asks for is then all it needs.
    local made_dir=0 err
    if [[ ! -e "$DATA_DIR" && ! -L "$DATA_DIR" ]]; then
      made_dir=1
      if ! err=$(install -d -m 0750 -o root -g "$SERVICE_USER" "$DATA_DIR" 2>&1); then
        die_account_marker "could not create $DATA_DIR: $(clean_text "$err")" "$(undo_new_data_dir)"
      fi
    fi
    if ! write_account_marker; then
      if (( made_dir == 1 )); then die_account_marker "$MARKER_ERROR" "$(undo_new_data_dir)"; fi
      die_account_marker "$MARKER_ERROR"
    fi
    trap - INT TERM HUP
    eval "$saved"
    if [[ -n "$held" ]]; then kill -s INT "$$"; fi
    ACCOUNT_CREATED=yes
    ACCOUNT_UID=$(id -u "$SERVICE_USER")
    say "Created system user: $SERVICE_USER"
  elif account_marker_matches; then
    ACCOUNT_CREATED=yes
    ACCOUNT_UID=$(id -u "$SERVICE_USER")
    say "Using the system user $SERVICE_USER that this installer created for an earlier install."
  else
    refuse_foreign_account
  fi
}

# Stops an install on a `salvorias` account the installer cannot show it made.
refuse_foreign_account() {
  die "An account named '$SERVICE_USER' (UID $(id -u "$SERVICE_USER" 2>/dev/null || printf '?')) already exists, but this installer did not create it: $ACCOUNT_MARKER, which the installer leaves for an account it made, is missing or names another UID. Refusing to run the node service, and to share the node key, with an account it does not own. If nothing else uses the account, remove it ('sudo userdel $SERVICE_USER'), or rename it ('sudo usermod -l NEWNAME $SERVICE_USER' and 'sudo groupmod -n NEWNAME $SERVICE_USER'), then rerun. Nothing was changed. If an earlier run of this installer was killed in the instant after it created the account, the account is its own but unproven: the same 'sudo userdel $SERVICE_USER' (it removes the group too), then rerun, recovers it."
}

# Read-only form of the same rule, for the start of an install.
require_owned_account() {
  id -u "$SERVICE_USER" >/dev/null 2>&1 || return 0
  account_marker_matches || refuse_foreign_account
}

# True when ACCOUNT_MARKER says the current salvorias account (same UID) was
# created by this installer. It is trusted only as a single-link root-owned
# file in a root-owned DATA_DIR, where the service account cannot write. The
# UID ties it to that account: one deleted and made again by hand does not
# match.
account_marker_matches() {
  local uid
  uid=$(id -u "$SERVICE_USER" 2>/dev/null) || return 1
  [[ -d "$DATA_DIR" && ! -L "$DATA_DIR" && "$(stat -c '%u' -- "$DATA_DIR")" == 0 ]] || return 1
  [[ -f "$ACCOUNT_MARKER" && ! -L "$ACCOUNT_MARKER" && "$(stat -c '%u:%h' -- "$ACCOUNT_MARKER")" == "0:1" ]] || return 1
  [[ "$(head -c 100 -- "$ACCOUNT_MARKER" | head -n 1)" == "UID=$uid" ]]
}

# Leaves ACCOUNT_MARKER for the account this installer created: for a new
# account (ensure_user), and when an uninstall keeps the key (and so the
# account) but removes the state file. Written in a staging name and renamed,
# so it never follows a link, and so a write that fails part-way (a full disk)
# never leaves a marker behind: the staging file is renamed only once it is
# complete, and is removed otherwise.
#
# Returns 0 with nothing written when there is nothing to prove yet: no such
# account, or a DATA_DIR that is not root-owned (an older layout, which
# make_dirs fixes before the install writes the marker again). Returns 1, with
# MARKER_ERROR saying why, when the write failed or the marker does not read
# back as valid; the caller decides whether that stops the run.
MARKER_ERROR=""
write_account_marker() {
  local uid tmp err
  MARKER_ERROR=""
  uid=$(id -u "$SERVICE_USER" 2>/dev/null) || return 0
  [[ -d "$DATA_DIR" && ! -L "$DATA_DIR" && "$(stat -c '%u' -- "$DATA_DIR")" == 0 ]] || return 0
  if ! tmp=$(mktemp "$DATA_DIR/.stage.XXXXXX" 2>&1); then
    MARKER_ERROR="could not create a file in $DATA_DIR: $(clean_text "$tmp")"
    return 1
  fi
  if ! err=$({ printf 'UID=%s\n' "$uid" >"$tmp" && chmod 0600 "$tmp" && mv -fT -- "$tmp" "$ACCOUNT_MARKER"; } 2>&1); then
    MARKER_ERROR=$(clean_text "${err:-the write failed}")
    remove_marker_file "$tmp" "the unfinished marker"
    return 1
  fi
  # A marker that does not prove the account is worse than none: it would
  # keep DATA_DIR from being removed again, and the next install refuses
  # that. It is the file just renamed into a root-owned DATA_DIR, so ours.
  if ! account_marker_matches; then
    MARKER_ERROR="it was written but does not read back as UID=$uid"
    remove_marker_file "$ACCOUNT_MARKER" "the marker that did not read back"
    return 1
  fi
}

# remove_marker_file PATH WHAT: removes a file write_account_marker made. rm
# removes a link itself and never follows it. When it cannot, the path is
# named so the operator can remove it by hand.
remove_marker_file() {
  if [[ ! -e "$1" && ! -L "$1" ]] || rm -f -- "$1" 2>/dev/null; then return 0; fi
  warn "Could not remove $2, $1. Remove it with 'sudo rm -f $1'."
}

# After a failed marker write for a new account: removes the DATA_DIR that
# ensure_user has just made (rmdir, so only while it is empty) and prints
# nothing. When it cannot, prints the extra step for die_account_marker.
undo_new_data_dir() {
  if [[ ! -e "$DATA_DIR" && ! -L "$DATA_DIR" ]] || rmdir -- "$DATA_DIR" 2>/dev/null; then return 0; fi
  printf "This run also made %s and could not remove it again: remove it with 'sudo rm -r %s' before you rerun, or the next install will refuse it." "$DATA_DIR" "$DATA_DIR"
}

# Stops an install whose new account could not get its marker. Carrying on
# would leave an account the next install cannot prove is its own, and so
# refuses. Always this run's account: one reused from an earlier install has a
# valid marker, which the install never rewrites.
# die_account_marker WHY [EXTRA]: EXTRA is one more recovery step.
die_account_marker() {
  die "Could not write $ACCOUNT_MARKER, the record that this installer created the '$SERVICE_USER' account ($1). Stopping here: without it the next install could not prove the account is its own and would refuse it. The disk may be full or $DATA_DIR read-only (check with 'df -h $DATA_DIR' and 'findmnt -T $DATA_DIR'). Free space or fix that, then remove the account this run created with 'sudo userdel $SERVICE_USER' (it removes the group too), and rerun.${2:+ $2}"
}

# The uninstall that keeps the key removes the state file, so from then on
# only ACCOUNT_MARKER shows the next install that the kept account (and key)
# are this installer's. Writes it, then checks that it really proves the
# account: write_account_marker writes nothing when DATA_DIR is missing or not
# root-owned, which no release leaves behind but a hand-edited server can.
# Anything short of proof gets a warning with the fix, not a stop: the
# uninstall itself is done by then.
record_kept_account() {
  local why=""
  if ! write_account_marker; then
    why=$MARKER_ERROR
  elif ! account_marker_matches; then
    why="$DATA_DIR is missing or not owned by root, so the marker was not written"
  fi
  if [[ -z "$why" ]]; then return 0; fi
  # The fix writes the marker as write_account_marker does, so that nothing
  # placed at the marker path is written through: the directory is made
  # root-only first (from then on only root can put anything in it), the
  # content goes into a new file mktemp creates exclusively (root, 0600), and
  # mv -T renames that over whatever is at the marker path, replacing a link
  # rather than following it.
  local uid
  uid=$(id -u "$SERVICE_USER" 2>/dev/null || printf '?')
  warn "Could not write $ACCOUNT_MARKER, the record that this installer created the '$SERVICE_USER' account ($why). Without it a later install will refuse the account and the kept key. Free space on the disk if it is full, then write it with: sudo install -d -m 0750 -o root -g $SERVICE_USER $DATA_DIR && t=\$(sudo mktemp $DATA_DIR/.stage.XXXXXX) && echo 'UID=$uid' | sudo tee \"\$t\" >/dev/null && sudo mv -fT \"\$t\" $ACCOUNT_MARKER"
}

# True when the state file is one this installer wrote: a root-owned regular
# file, in a real directory, that starts with the installer's header and has
# a STAGE line.
state_file_is_ours() {
  [[ -d "$ETC_DIR" && ! -L "$ETC_DIR" && -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 1
  [[ "$(stat -c '%u' -- "$STATE_FILE")" == 0 ]] || return 1
  [[ "$(head -c 300 -- "$STATE_FILE" | head -n 1)" == "$STATE_FILE_HEADER" ]] || return 1
  grep -q '^STAGE=' "$STATE_FILE"
}

# True when something other than the mere existence of the fixed paths shows
# that this installer set them up: its state file, or the account marker whose
# UID is the salvorias account's. Existence alone proves nothing: /etc/salvorias
# or /usr/local/bin/salvorias-node could be anyone's.
installer_proof() {
  state_file_is_ours || account_marker_matches
}

# Stops an install that would take over a fixed path it cannot show it made:
# it would chown and chmod a directory, replace a link or file, and a later
# uninstall would delete it. Nothing is changed.
refuse_unowned_paths() {
  local p
  installer_proof && return 0
  for p in "$ETC_DIR" "$DATA_DIR" "$OPT_DIR" "$PATH_LINK" "$SELF_PATH"; do
    if [[ -e "$p" || -L "$p" ]]; then
      die "$p already exists, and nothing shows that this installer created it (no installer state file in $ETC_DIR, and no installer marker for the $SERVICE_USER account in $DATA_DIR). Refusing to take it over: the installer would change its owner and mode, or replace or delete it. Nothing was changed. If it is yours, copy anything you need from it (a node key, for one), move it aside ('sudo mv $p $p.old') or remove it, then rerun."
    fi
  done
}

# PATH_LINK as switch_current makes it. Anything else at that path is not ours
# to replace or delete.
path_link_is_ours() {
  [[ -L "$PATH_LINK" && "$(readlink -- "$PATH_LINK")" == "$CURRENT_LINK/salvorias-node" ]]
}

# SELF_PATH as install_self_copy makes it: a regular file whose second line is
# the installer's marker.
self_file_is_ours() {
  [[ -f "$SELF_PATH" && ! -L "$SELF_PATH" && "$(head -c 300 -- "$SELF_PATH" | sed -n 2p)" == "$SELF_MARKER" ]]
}

make_dirs() {
  install -d -m 0755 -o root -g root "$OPT_DIR" "$BIN_ROOT"
  install -d -m 0750 -o root -g "$SERVICE_USER" "$ETC_DIR"
  if [[ ! -e "$DATA_DIR" && ! -L "$DATA_DIR" ]]; then
    install -d -m 0750 -o root -g "$SERVICE_USER" "$DATA_DIR"
  fi
  secure_data_dir
}

# DATA_DIR is root:salvorias 0750: the service can read its key but cannot
# create, rename or replace anything in the directory, so a link planted by
# a compromised service can never redirect root's later chown, write, read or
# shred. Installs from before this layout had it salvorias-owned 0700; this
# migrates them. The directory is locked FIRST and inspected second: in that
# order nothing can be planted between the check and the use. Locking an
# existing directory is safe because it is checked to be a real directory in
# root-owned /var/lib, where the service cannot swap it.
secure_data_dir() {
  if [[ ! -e "$DATA_DIR" && ! -L "$DATA_DIR" ]]; then return 0; fi
  [[ -d "$DATA_DIR" && ! -L "$DATA_DIR" ]] \
    || die "$DATA_DIR is not a plain directory (it may be a symbolic link). Refusing to use it. Inspect it, and remove it if it is not yours."
  getent group "$SERVICE_USER" >/dev/null \
    || die "$DATA_DIR exists but the '$SERVICE_USER' group does not. Refusing to guess who should own it. Inspect it, move the key somewhere safe if it is yours, then rerun."
  chown -h "root:$SERVICE_USER" "$DATA_DIR"
  chmod 0750 "$DATA_DIR"
  local odd
  odd=$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 \( -type l -o \( ! -type f ! -type d \) \) -printf '%f ' 2>/dev/null)
  if [[ -n "$odd" ]]; then
    die "$DATA_DIR contains a symbolic link or special file (${odd% }). It may have been planted by a compromised node service. Refusing to touch anything in it. Inspect it (do not follow the link), remove it, then rerun."
  fi
  local f
  for f in "$KEY_FILE" "$ADDRESS_FILE"; do
    if [[ -e "$f" || -L "$f" ]]; then require_data_file "$f"; fi
  done
}

# Every root operation on a file in DATA_DIR (chown, chmod, read, write,
# compare, copy, shred) is preceded by this check.
require_data_file() {
  if [[ -L "$1" || ! -f "$1" ]]; then
    die "$1 is not a regular file (it may be a symbolic link). Refusing to touch it or follow it. Inspect it, and remove it if it is not yours."
  fi
  local links
  links=$(stat -c '%h' -- "$1")
  if [[ "$links" != 1 ]]; then
    die "$1 has another hard link (link count $links): some other path on this server is the same file, so writing, moving or shredding it here would affect that path too. Refusing to touch it. Find the other link with 'sudo find / -xdev -samefile $1', inspect it, remove the extra link if it is not yours, then rerun."
  fi
}

# place_data_file STAGED DEST OWNER MODE: sets the owner and mode on a file in
# the root-only staging directory, then renames it to DEST.
place_data_file() {
  chown -h "$3" "$1"
  chmod "$4" "$1"
  mv -fT -- "$1" "$2"
}

# ─── Node key ──────────────────────────────────────────────────────────────

NODE_ADDRESS=""
KEY_SOURCE=""   # generated, imported, reused

# derive_address BIN KEYFILE: sets DERIVED_ADDRESS to the address of the one
# key in KEYFILE. `salvorias-node key-address` makes no RPC call, never prints
# the key, and exits 2 for a group/world-accessible file, zero keys or more
# than one.
DERIVED_ADDRESS=""
derive_address() {
  local out
  DERIVED_ADDRESS=""
  out=$(node_run 60 "$1" key-address --keys-file "$2" </dev/null 2>/dev/null) || return 1
  is_address "$out" || return 1
  DERIVED_ADDRESS="$out"
}

same_address() { [[ "$(lower "$1")" == "$(lower "$2")" ]]; }

KEY_FORMAT_MSG="--import-key file must contain exactly one node key (64 hex characters, optional 0x, optional trailing newline). Nothing else is allowed."

# Reads the --import-key file exactly ONCE, into a root-only staging copy in
# the fresh 0700 temp dir, and does every later step (validation, address,
# install) from that copy, so the source cannot be swapped between the check
# and the use. The checks are made on the path (lstat); the copy is read
# from a descriptor whose file is compared (fstat, before and after the read)
# with what was checked, so a link, another file or a mode change slipped in
# after the checks is refused. The read runs under a timeout, so a FIFO
# swapped in cannot hang the install. The contents are never printed.
IMPORT_STAGED=""
stage_import_key() {
  local f="$1" mode size line checked opened
  [[ ! -L "$f" ]] || usage_error "--import-key $f is a symbolic link. Pass the key file itself."
  [[ -f "$f" ]] || usage_error "--import-key file not found (or not a regular file): $f"
  [[ "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" != "$KEY_FILE" ]] || usage_error "--import-key cannot be the installed key file itself."
  # device:inode:type+mode (raw hex):owner
  checked=$(stat -c '%d:%i:%f:%u' -- "$f")
  mode=$(stat -c '%a' -- "$f")
  if (( (8#$mode & 8#044) != 0 )); then
    usage_error "--import-key file $f is readable by other users (mode $mode). A node key must be private: run 'sudo chmod 600 $f' and try again."
  fi
  make_tmp_dir
  IMPORT_STAGED="$TMP_DIR/key-import"
  # stat -L on /proc/self/fd/3 is an fstat of the descriptor the copy is
  # read from (the stat process inherits it).
  # shellcheck disable=SC2016
  opened=$(umask 077; timeout 10 bash -c '
      exec 3<"$1" || exit 1
      stat -L -c "%d:%i:%f:%u" /proc/self/fd/3 || exit 1
      dd of="$2" bs=4096 count=1 status=none <&3 || exit 1
      stat -L -c "%d:%i:%f:%u" /proc/self/fd/3' _ "$f" "$IMPORT_STAGED" 2>/dev/null) \
    || usage_error "Could not read the --import-key file $f (it must be a regular file, not a link)."
  if [[ "$opened" != "$checked"$'\n'"$checked" ]]; then
    usage_error "The --import-key file $f changed while it was being read (a different file, a link, or a new owner or mode). Nothing was installed. Check the file, then try again."
  fi
  if [[ -L "$IMPORT_STAGED" || ! -f "$IMPORT_STAGED" || "$(stat -c '%u:%a:%h' -- "$IMPORT_STAGED")" != "0:600:1" ]]; then
    die "The staged copy of the --import-key file is not a private root-owned file. Nothing was installed."
  fi
  size=$(stat -c '%s' -- "$IMPORT_STAGED")
  (( size >= 64 && size <= 67 )) || usage_error "$KEY_FORMAT_MSG"
  line=""
  IFS= read -r line <"$IMPORT_STAGED" || true
  # Exactly one key: the line plus at most one newline accounts for every byte.
  if [[ ! "$line" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] || (( size != ${#line} && size != ${#line} + 1 )); then
    line=""
    usage_error "$KEY_FORMAT_MSG"
  fi
  line=""
  derive_address "$STAGED_BIN" "$IMPORT_STAGED" \
    || die "Could not read a node address from the --import-key file. The node binary must support 'key-address' (salvorias-node 0.0.9 or later)."
}

# Installs the staged import, normalised to one 0x-prefixed lower-case line
# (the keygen format), as the salvorias user's 0600 key file.
install_imported_key() {
  local line staged
  [[ ! -e "$KEY_FILE" && ! -L "$KEY_FILE" ]] || die "$KEY_FILE appeared during the install. Refusing to replace it."
  make_data_stage
  staged="$DATA_STAGE/node-key.txt"
  IFS= read -r line <"$IMPORT_STAGED" || true
  line="${line#0x}"
  ( umask 077; set -o noclobber; printf '0x%s\n' "${line,,}" >"$staged" ) || { line=""; die "Could not stage the node key."; }
  line=""
  if ! { derive_address "$PATH_LINK" "$staged" && same_address "$DERIVED_ADDRESS" "$NODE_ADDRESS"; }; then
    die "The normalised key does not match the imported one. Nothing was installed."
  fi
  place_data_file "$staged" "$KEY_FILE" "$SERVICE_USER:$SERVICE_USER" 0600
}

# The address record is root's (root:root 0644): the service never needs to
# change it, and status and uninstall read it.
write_address_file() {
  if [[ -e "$ADDRESS_FILE" || -L "$ADDRESS_FILE" ]]; then require_data_file "$ADDRESS_FILE"; fi
  make_data_stage
  printf '%s\n' "$NODE_ADDRESS" >"$DATA_STAGE/node-address.txt"
  place_data_file "$DATA_STAGE/node-address.txt" "$ADDRESS_FILE" root:root 0644
}

# Works out which key this install will use, and its address, before anything
# is installed: an imported key, a key kept by an earlier uninstall, or (if
# neither) a key generated later by ensure_node_key.
# A kept key's address is derived from the key itself; the address record
# is rewritten from it later.
plan_node_key() {
  local kept=""
  secure_data_dir
  if [[ -e "$KEY_FILE" ]]; then
    derive_address "$STAGED_BIN" "$KEY_FILE" \
      || die "A node key exists at $KEY_FILE but could not be read as exactly one node key (the node binary must support 'key-address', salvorias-node 0.0.9 or later). Move it somewhere safe, then rerun."
    kept="$DERIVED_ADDRESS"
  fi
  if [[ -n "$OPT_IMPORT_KEY" ]]; then
    stage_import_key "$OPT_IMPORT_KEY"
    NODE_ADDRESS="$DERIVED_ADDRESS"
    if [[ -n "$kept" ]] && ! same_address "$kept" "$NODE_ADDRESS"; then
      die "A different node key ($kept) already exists at $KEY_FILE (kept by an earlier uninstall). Back it up with care, then remove it with '$(cmd_hint 'uninstall --purge-key')' before importing another key."
    fi
    say "Imported key belongs to node $NODE_ADDRESS"
    if [[ -n "$kept" ]]; then
      KEY_SOURCE="reused"
      say "That is the same key as the one kept at $KEY_FILE; keeping that file."
    else
      KEY_SOURCE="imported"
    fi
  elif [[ -n "$kept" ]]; then
    NODE_ADDRESS="$kept"
    KEY_SOURCE="reused"
    say "Found the node key kept by an earlier uninstall: $NODE_ADDRESS (reusing it)"
  else
    KEY_SOURCE="generated"
  fi
}

ensure_node_key() {
  case "$KEY_SOURCE" in
    generated)
      local addr rc=0 staged
      [[ ! -e "$KEY_FILE" && ! -L "$KEY_FILE" ]] || die "$KEY_FILE appeared during the install. Refusing to replace it."
      make_data_stage
      staged="$DATA_STAGE/node-key.txt"
      addr=$(node_run 60 "$PATH_LINK" keygen --out "$staged" </dev/null) || rc=$?
      (( rc == 0 )) || die "Node key generation failed (exit $rc)."
      is_address "$addr" || die "keygen returned an unexpected address."
      if ! { derive_address "$PATH_LINK" "$staged" && same_address "$DERIVED_ADDRESS" "$addr"; }; then
        die "The generated key does not match the address keygen reported. Nothing was installed."
      fi
      place_data_file "$staged" "$KEY_FILE" "$SERVICE_USER:$SERVICE_USER" 0600
      NODE_ADDRESS="$addr"
      write_address_file
      say "Generated a new node key on this server: $KEY_FILE"
      ;;
    imported)
      install_imported_key
      write_address_file
      say "Installed the imported node key: $KEY_FILE"
      ;;
    reused)
      require_data_file "$KEY_FILE"
      chown -h "$SERVICE_USER:$SERVICE_USER" "$KEY_FILE"
      chmod 0600 "$KEY_FILE"
      write_address_file
      ;;
  esac
}

# ─── Registration and funding ──────────────────────────────────────────────

# Sets BOUND_STATE from SLOT_JSON:
#   owner     registered: one of OWNER's licenses points at this node
#   replaced  the chain still names OWNER for this node, but none of OWNER's
#             licenses points at it any more (the app put another node there)
#   other     the chain names a different wallet for this node
#   unbound   no wallet at all
# boundOwner alone is the contract's reverse mapping (nodeToOwner), which can
# outlive the license entry it came from. slot-info fills boundSlot only once
# the owner's license entry itself is found pointing at the node, so
# "registered" needs both. The slot number is not kept: nothing shown to the
# user names a slot.
BOUND_STATE=""
BOUND_OTHER=""
read_binding() {
  local bound
  bound=$(json_str boundOwner)
  if [[ -z "$bound" ]]; then
    BOUND_STATE="unbound"
  elif [[ "$(lower "$bound")" == "$(lower "$OWNER")" ]]; then
    if is_uint "$(json_raw boundSlot)"; then
      BOUND_STATE="owner"
    else
      BOUND_STATE="replaced"
    fi
  else
    BOUND_STATE="other"
    # Printed in several messages, so cleaned once, here.
    BOUND_OTHER=$(clean_text "$bound")
  fi
}

# Prints the funding lines from a slot-info --node result. The fee itself is
# not the point: on Salvorias an address that has never held SAVDR does not
# exist on chain, so its transactions are refused ("the sender is not EOA")
# even when the network fee is 0. A node with a zero balance can never check in.
print_funding() {
  local balance
  balance=$(json_str nodeBalanceWei)
  is_uint "$balance" || balance=0

  say "   Send 1 SAVDR to the NODE address above. The node pays a tiny fee for each"
  say "   daily check-in, so 1 SAVDR will last a while. An address with no SAVDR"
  say "   cannot check in at all, even when fees are zero."
  say "   Your wallet also needs a little SAVDR (0.01 is plenty) to send the"
  say "   registration."
  say "   Current node balance: $(wei_to_savdr "$balance") SAVDR"
}

# warn_if_unfunded BALANCE COST: BALANCE is the node's balance in wei and COST
# slot-info's per-check-in reserve. A zero balance warns whatever the fee is
# (see print_funding). A non-zero balance below the reserve is also refused by
# the chain, so that still warns.
warn_if_unfunded() {
  local balance="$1" cost="$2"
  is_uint "$balance" || return 0
  if [[ "$(strip_zeros "$balance")" == "0" ]]; then
    say ""
    warn "This node will not check in until it holds some SAVDR. Send 1 SAVDR to $NODE_ADDRESS."
  elif is_uint "$cost" && wei_lt "$balance" "$cost"; then
    say ""
    warn "The node balance is below the per-check-in reserve ($(wei_to_savdr "$cost") SAVDR at today's fee). The chain will not accept a check-in until you send more SAVDR to $NODE_ADDRESS."
  fi
}

# True when a wei amount from slot-info is above zero. Any SAVDR at all is
# enough to stop waiting: the chain then knows the address (see
# print_funding), and warn_if_unfunded still flags a balance below the fee.
has_balance() { is_uint "$1" && [[ "$(strip_zeros "$1")" != "0" ]]; }

print_node_address() {
  say ""
  say "   Node address:"
  say ""
  say "     $NODE_ADDRESS"
  say ""
}

# print_setup_boxes OPEN_SLOTS: OPEN_SLOTS is slot-info's openSlots list.
# Funding comes first: an address that has never held SAVDR does not exist
# on chain, so the node cannot check in until it is funded, whatever the app
# shows. Slot numbers are never shown: the app picks the slot itself. The list
# only decides whether to say that registering will replace an existing node.
print_setup_boxes() {
  local slots="$1"
  say ""
  rule
  say " STEP 1: FUND THE NODE"
  rule
  print_node_address
  print_funding
  say ""
  rule
  say " STEP 2: REGISTER THIS NODE IN THE SALVORIAS APP"
  rule
  say ""
  say "   Open $NET_APP_URL/licenses/self-host"
  say "   (or Salvorias app > Licenses > Self Setup), paste the node address"
  say "   from step 1 and confirm with your passcode."
  if [[ -z "$slots" ]]; then
    say ""
    say "   All your licenses already have a node. When you register, the app"
    say "   tells you which node this replaces, and asks you to confirm before"
    say "   moving a node off Save Hosting."
  fi
  say ""
  rule
  say ""
}

# For a node that is already registered (a kept or imported key) but holds
# no SAVDR: funding is the only step left.
print_funding_box() {
  say ""
  rule
  say " FUND THE NODE"
  rule
  say "   Node address: $NODE_ADDRESS"
  print_funding
  rule
  say ""
}

# Sets NODE_REGISTERED and NODE_FUNDED (yes or no) from SLOT_JSON. A node
# registered to another wallet stops the install: waiting cannot fix that.
read_readiness() {
  read_binding
  if [[ "$BOUND_STATE" == "other" ]]; then
    die "Node $NODE_ADDRESS was registered to a different wallet ($BOUND_OTHER), not $OWNER. Remove it from that wallet's licenses in the app (signed in with $BOUND_OTHER), then run: $(cmd_hint uninstall) and install again with the right owner."
  fi
  NODE_REGISTERED=no
  if [[ "$BOUND_STATE" == "owner" ]]; then NODE_REGISTERED=yes; fi
  NODE_FUNDED=no
  if has_balance "$(json_str nodeBalanceWei)"; then NODE_FUNDED=yes; fi
}
NODE_REGISTERED=""
NODE_FUNDED=""

# missing_steps REGISTERED FUNDED: names what is still to do, for the Ctrl-C
# and timeout messages. Empty values mean the chain has not been read yet.
missing_steps() {
  local fund="send 1 SAVDR to $NODE_ADDRESS"
  local reg="register it in the app (Licenses > Self Setup, node address $NODE_ADDRESS)"
  case "$1/$2" in
    no/no) printf 'The node is not funded and not registered yet: %s, and %s.' "$fund" "$reg" ;;
    yes/no) printf 'The node is registered but not funded yet: %s.' "$fund" ;;
    no/yes) printf 'The node is funded but not registered yet: %s.' "$reg" ;;
    *) printf 'The chain could not be read, so funding and registration are unconfirmed. Make sure the node is funded (%s) and registered (%s).' "$fund" "$reg" ;;
  esac
}

# Polls until the node is BOTH registered to the owner and funded: starting
# the service earlier only produces failed check-ins. Prints a progress line
# when the state changes, and otherwise once a minute. The state is the pair
# of answers (or "unreadable"), never the line's text: an RPC error's wording
# can differ on every poll and must not print a line each time. Ctrl-C or a
# timeout leaves the install resumable: the key and state file are already
# written.
wait_until_ready() {
  local minutes="$1" deadline now rc line state last_state="" last_print=0
  deadline=$(( $(date +%s) + minutes * 60 ))
  NODE_REGISTERED=""
  NODE_FUNDED=""
  INTERRUPT_HINT="Your node key is saved. Once the node is funded and registered, continue with:
  $(cmd_hint resume)"
  say "Waiting until the node is funded and registered on-chain (checking every ${SALVORIAS_POLL_SECONDS}s, up to $minutes min)."
  say "You can press Ctrl-C and continue later with: $(cmd_hint resume)"
  while :; do
    rc=0
    run_slot_info "$PATH_LINK" "$NODE_ADDRESS" || rc=$?
    now=$(date +%s)
    if (( rc == 0 )); then
      read_readiness
      if [[ "$NODE_REGISTERED" == yes && "$NODE_FUNDED" == yes ]]; then
        INTERRUPT_HINT=""
        say "Registered: node $NODE_ADDRESS is bound to $OWNER."
        say "Funded: the node holds $(wei_to_savdr "$(json_str nodeBalanceWei)") SAVDR."
        return 0
      fi
      state="$NODE_REGISTERED/$NODE_FUNDED"
      line="registered: $NODE_REGISTERED   funded: $NODE_FUNDED"
      INTERRUPT_HINT="Your node key is saved. $(missing_steps "$NODE_REGISTERED" "$NODE_FUNDED") Then continue with:
  $(cmd_hint resume)"
    else
      state="unreadable"
      line="could not read the chain ($(clean_text "$(json_str error)")); will retry"
    fi
    if [[ "$state" != "$last_state" ]] || (( now - last_print >= 60 )); then
      say "  $(date +%H:%M:%S)  $line"
      if [[ "$state" != "$last_state" ]]; then
        case "$state" in
          yes/no) say "            Registered. Now send 1 SAVDR to $NODE_ADDRESS; the install goes on once it arrives." ;;
          no/yes) say "            Funded. Now register the node in the app (step 2); the install goes on once the registration is on-chain." ;;
        esac
      fi
      last_state="$state"
      last_print=$now
    fi
    if (( now >= deadline )); then
      INTERRUPT_HINT=""
      stop "Waited $minutes min. $(missing_steps "$NODE_REGISTERED" "$NODE_FUNDED") Your node key is saved. Then run: $(cmd_hint resume)"
    fi
    sleep "$SALVORIAS_POLL_SECONDS"
  done
}

# ─── Service ───────────────────────────────────────────────────────────────

write_env_file() {
  local tmp
  assert_plain_values "$NET_CHECKIN" "$RPC_URL" "$NET_TREASURY" "$NET_CHAIN_ID" "$KEY_FILE" "$GAS_PRICE_MODE" "$MAX_GAS_PRICE_GWEI"
  tmp=$(mktemp "$ETC_DIR/.node.env.XXXXXX")
  cat >"$tmp" <<EOF
# Salvorias node daemon settings, written by the self-host installer.
# Restart after editing: sudo systemctl restart salvorias-node
CHECKIN_CONTRACT=$NET_CHECKIN
RPC_URL=$RPC_URL
TREASURY_CONTRACT=$NET_TREASURY
EXPECTED_CHAIN_ID=$NET_CHAIN_ID
NODE_KEYS_FILE=$KEY_FILE
# Check in as soon as the service starts. The daemon's default random delay
# (up to 300s) spreads a hosted fleet's restarts; a single self-hosted node
# has nothing to spread, and the installer watches for the first result.
STARTUP_JITTER=0
# Self-hosted node wallets are not fee-exempt: pay the live network fee,
# never more than MAX_GAS_PRICE_GWEI per unit of gas.
GAS_PRICE_MODE=$GAS_PRICE_MODE
MAX_GAS_PRICE_GWEI=$MAX_GAS_PRICE_GWEI
EOF
  chown root:"$SERVICE_USER" "$tmp"
  chmod 0640 "$tmp"
  mv -f "$tmp" "$ENV_FILE"
}

# Writes the unit file, but replaces the installed one only if the content
# differs: rewriting an identical file still changes it on disk, and systemd
# then warns that the loaded unit is stale. Sets UNIT_CHANGED; the caller runs
# daemon-reload when it is 1.
UNIT_CHANGED=0
write_unit_file() {
  local tmp
  UNIT_CHANGED=0
  is_safe_repo "$SALVORIAS_RELEASE_REPO" || die "SALVORIAS_RELEASE_REPO is not a GitHub owner/name."
  assert_plain_values "$SERVICE_USER" "$ENV_FILE" "$PATH_LINK"
  tmp=$(mktemp "/etc/systemd/system/.salvorias-node.service.XXXXXX")
  cat >"$tmp" <<EOF
# Installed by the Salvorias self-host installer.
[Unit]
Description=Salvorias check-in node (self-hosted)
Documentation=https://github.com/$SALVORIAS_RELEASE_REPO
After=network-online.target
Wants=network-online.target

[Service]
# exec: a binary that cannot be started fails the start itself.
Type=exec
User=$SERVICE_USER
Group=$SERVICE_USER
EnvironmentFile=$ENV_FILE
ExecStart=$PATH_LINK start
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal
SyslogIdentifier=salvorias-node
UMask=0077
MemoryMax=200M

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
# No ReadWritePaths: the daemon writes no files (it logs to the journal), so
# the whole file system stays read-only to it, its key directory included.
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$tmp"
  if [[ -f "$UNIT_FILE" && ! -L "$UNIT_FILE" ]] && cmp -s "$tmp" "$UNIT_FILE" \
      && [[ "$(stat -c '%a %u:%g' -- "$UNIT_FILE")" == "644 0:0" ]]; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$UNIT_FILE"
  UNIT_CHANGED=1
}

# service_stays_up SECONDS: true if the service is active for the whole
# window without systemd restarting it.
service_stays_up() {
  local secs="$1" restarts elapsed=0
  sleep 2
  restarts=$(systemctl show -p NRestarts --value "$UNIT_NAME" 2>/dev/null || printf '0')
  while (( elapsed < secs )); do
    systemctl is-active --quiet "$UNIT_NAME" || return 1
    [[ "$(systemctl show -p NRestarts --value "$UNIT_NAME" 2>/dev/null || printf '0')" == "$restarts" ]] || return 1
    sleep 2
    elapsed=$((elapsed + 2))
  done
  systemctl is-active --quiet "$UNIT_NAME"
}

# The journal holds the node's output, which includes text from the RPC server,
# so every line goes through clean_text before it reaches the terminal.
show_journal() {
  local line rc=0
  journalctl -u "$UNIT_NAME" -n "${1:-20}" --no-pager 2>/dev/null | while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$(clean_text -n 400 "$line")"
  done || rc=$?
  (( rc == 0 )) || say "(no journal entries)"
}

# ─── First check-in ────────────────────────────────────────────────────────

ACTIVE_NOTE="It can take up to 30 minutes for your license to show Active in the Salvorias app after the first check-in. Check back then."

# Reads the daemon's journal lines (as `journalctl -o cat` prints them) on
# stdin and prints the first check-in's outcome, or nothing while there is
# none yet:
#   confirmed HASH   "TX Hash: 0x…" followed by "Confirmed block …"
#   done             already qualified for this period, or checked in too
#                    recently: nothing to send
#   failed REASON    "… check-in failed: REASON"
#   skipped LINE     the fee-cap skip line, without the log prefix
# Only these phrases of checkin-multi-agent.js are parsed. "check-in failed"
# and "Confirmed block" are also what the hosting node-agent parses, so they
# are kept stable; the others are the daemon's fixed status lines. Anything
# else (a failed cycle, an RPC outage) stays pending and ends in the timeout
# line, which points at status.
first_checkin_outcome() {
  local line msg hash=""
  local prefix_re='^\[[^]]*\] \[[A-Z ]*\] *(.*)$'
  local hash_re='TX Hash: (0x[0-9a-fA-F]{64})([^0-9a-fA-F]|$)'
  local done_re='Status: [1-9][0-9]* already qualified, 0 need check-in'
  local failed_re='check-in failed: (.*)$'
  while IFS= read -r line; do
    msg="$line"
    if [[ "$line" =~ $prefix_re ]]; then msg="${BASH_REMATCH[1]}"; fi
    msg="${msg#"${msg%%[![:space:]]*}"}"
    if [[ "$msg" =~ $hash_re ]]; then
      hash="${BASH_REMATCH[1]}"
    elif [[ -n "$hash" && "$msg" == "Confirmed block "[0-9]* ]]; then
      printf 'confirmed %s\n' "$hash"
      return 0
    elif [[ "$msg" =~ $done_re || "$msg" == *"All nodes checked in for this period."* || "$msg" == *"checked in too recently. OK."* ]]; then
      printf 'done\n'
      return 0
    elif [[ "$msg" =~ $failed_re ]]; then
      printf 'failed %s\n' "$(clean_text "${BASH_REMATCH[1]}")"
      return 0
    elif [[ "$msg" == *" skipped this cycle: "* ]]; then
      printf 'skipped %s\n' "$(clean_text "$msg")"
      return 0
    fi
  done
  return 0
}

# checkin_failure_reason RAW: a short reason from the daemon's error text.
# An address that never held SAVDR is refused as "not EOA". "Insufficient
# funds" means the node holds some SAVDR, but less than the fee needs (the
# install only starts the service once the balance is above zero), so it gets
# its own wording. Otherwise ethers' wrapper ("could not coalesce error (error={ … "message": "…" },
# payload=…)") is cut down to the node's own message. The text comes from an
# RPC server, so it goes through clean_text.
checkin_failure_reason() {
  local raw="$1" re='"message": ?"([^"]*)"'
  if [[ "${raw,,}" == *"not eoa"* ]]; then
    printf 'the node has no SAVDR yet; send 1 SAVDR to %s' "$NODE_ADDRESS"
    return 0
  fi
  if [[ "${raw,,}" == *insufficient* ]]; then
    printf "the node's SAVDR balance is too low for the fee; send more SAVDR to %s" "$NODE_ADDRESS"
    return 0
  fi
  if [[ "$raw" =~ $re ]]; then
    raw="${BASH_REMATCH[1]}"
  else
    raw="${raw%% (*}"
  fi
  raw=$(clean_text "$raw")
  while [[ "$raw" == *[.\ ] ]]; do raw="${raw%?}"; done
  printf '%s' "${raw:-no reason given}"
}

# Prints the result line for an outcome from first_checkin_outcome (empty:
# none within the watch).
print_first_checkin() {
  local kind="${1%% *}" rest="${1#* }"
  case "$kind" in
    confirmed)
      say "First check-in confirmed (tx $rest)."
      say "  $NET_EXPLORER_URL/tx/$rest"
      ;;
    done)
      say "This node already checked in for the current period; the next check-in is automatic."
      ;;
    failed|skipped)
      if [[ "$kind" == failed ]]; then rest=$(checkin_failure_reason "$rest"); else rest=$(clean_text "$rest"); rest="${rest%.}"; fi
      say "The first check-in failed: $rest."
      say "The node keeps retrying on its own schedule. Run $(cmd_hint status) for details."
      ;;
    *)
      say "No check-in result yet; run $(cmd_hint status) in a few minutes."
      ;;
  esac
}

# Watches the running service's journal for the first check-in's outcome, for
# up to SALVORIAS_FIRST_CHECKIN_SECONDS. Reads only this service run's entries
# (its InvocationID), so lines of an earlier install never count, and follows
# a restart to the new run. Advisory only: whatever the outcome, the install
# has succeeded and its exit code does not change. Ctrl-C ends the watch, not
# the install; each journal read is a snapshot, never a follow.
# Bounded: systemctl, journalctl and the pause between reads each get at most
# the time left (at least 1s, which is the most the watch can overrun). They
# run under `timeout --foreground` so they stay in the terminal's process
# group: a plain `timeout` moves them out of it, and a Ctrl-C would then wait
# for the command to finish or time out. --foreground signals only the
# command itself, not processes it starts, which fits here: both are single
# processes, with their pagers turned off.
FIRST_CHECKIN_SKIP=0
watch_first_checkin() {
  local secs="$SALVORIAS_FIRST_CHECKIN_SECONDS" deadline left inv outcome=""
  (( secs > 0 )) || return 0
  say ""
  say "Watching for the first check-in (up to ${secs}s; Ctrl-C skips the wait, the node keeps running)..."
  FIRST_CHECKIN_SKIP=0
  trap 'FIRST_CHECKIN_SKIP=1' INT
  deadline=$(( $(date +%s) + secs ))
  while (( FIRST_CHECKIN_SKIP == 0 )); do
    left=$(( deadline - $(date +%s) ))
    (( left > 0 )) || break
    inv=$(timeout --foreground "$left" systemctl show --no-pager -p InvocationID --value "$UNIT_NAME" 2>/dev/null) || inv=""
    left=$(( deadline - $(date +%s) ))
    if (( left > 0 )) && [[ "$inv" =~ ^[0-9a-f]{32}$ ]]; then
      outcome=$(timeout --foreground "$left" journalctl "_SYSTEMD_INVOCATION_ID=$inv" -o cat --no-pager 2>/dev/null | first_checkin_outcome) || true
    fi
    [[ -z "$outcome" ]] || break
    left=$(( deadline - $(date +%s) ))
    (( left > 0 )) || break
    sleep "$(( left < 2 ? left : 2 ))" || true
  done
  trap on_signal INT
  if (( FIRST_CHECKIN_SKIP == 1 )) && [[ -z "$outcome" ]]; then
    say ""
    say "Stopped watching. The node keeps running; check its first check-in with: $(cmd_hint status)"
  else
    print_first_checkin "$outcome"
  fi
  say "$ACTIVE_NOTE"
}

# ─── install ───────────────────────────────────────────────────────────────

cmd_install() {
  require_root
  check_platform
  ensure_tools
  guard_single_node
  check_existing_user
  require_owned_account
  refuse_unowned_paths

  set_network "$OPT_NETWORK"
  RPC_URL="${OPT_RPC_URL:-$NET_RPC_URL}"

  banner "Salvorias self-host node installer v$INSTALLER_VERSION"
  say "Network: $NETWORK (chain $NET_CHAIN_ID)"
  check_rpc
  stage_binary
  read_owner
  plan_node_key

  # Read the license before anything is written, so a wrong wallet leaves
  # this server untouched.
  query_chain "$STAGED_BIN" "$NODE_ADDRESS"
  OWNER=$(json_str owner)
  is_address "$OWNER" || die "Chain query returned no owner address."
  local nft licenses
  nft=$(json_str nftContract)
  if [[ "$(lower "$nft")" != "$(lower "$NET_NFT")" ]]; then
    die "NodeCheckIn on $NETWORK counts licenses on NFT contract $(clean_text "$nft"), but this installer expects $NET_NFT. Refusing to continue: the installer may be out of date."
  fi
  licenses=$(json_raw licenseBalance)
  read_open_slots
  is_uint "$licenses" || die "Chain query returned no license balance."

  BOUND_STATE="unbound"
  if [[ -n "$NODE_ADDRESS" ]]; then read_binding; fi
  if [[ "$BOUND_STATE" == "other" ]]; then
    stop "Node $NODE_ADDRESS is registered to wallet $BOUND_OTHER, not $OWNER. Check the owner address. Nothing was installed."
  fi

  say "Owner wallet: $OWNER"
  say "Licenses held: $licenses"
  if (( licenses == 0 )); then
    stop "Wallet $OWNER holds no Salvorias node license on $NETWORK. Check that you entered the wallet that owns your license (the one in your Salvorias app). Nothing was installed."
  fi
  # With every license already holding a node the install still goes ahead:
  # the app chooses which node the registration replaces, and asks the owner
  # to confirm before it moves a node off Save Hosting (print_setup_boxes
  # says so).
  if [[ "$BOUND_STATE" == "owner" ]]; then
    say "Node $NODE_ADDRESS is already registered to this wallet; no new registration needed."
  elif [[ "$BOUND_STATE" == "replaced" ]]; then
    say "Node $NODE_ADDRESS was registered to this wallet before, but another node has since taken its place. Register it again in the app (shown below)."
  fi

  # The funding box and the registration wait both depend on slot-info
  # --node. For a new key, prove that query works on this network before
  # anything is written, using an address that can never be a node.
  if [[ -z "$NODE_ADDRESS" ]]; then
    local rc=0
    run_slot_info "$STAGED_BIN" "$PROBE_NODE_ADDRESS" || rc=$?
    if (( rc != 0 )); then
      die "Could not read node registration data from NodeCheckIn on $NETWORK ($(clean_text "$(json_str error)")). This must work to detect your registration. Nothing was installed. If this persists, report it with your network name."
    fi
  fi

  banner "Setting up this server"
  # Again, now that the questions are answered and just before the first write.
  require_owned_account
  refuse_unowned_paths
  ensure_user
  make_dirs
  # ensure_user wrote the marker for a new account before any of this. This
  # call covers a DATA_DIR that existed but was not root-owned then (an older
  # layout), which make_dirs has just fixed. A marker that already proves the
  # account is left as it is: rewriting it would only add a way to lose it
  # (a write that does not read back is removed). With no valid marker, a
  # failed write stops the install as in ensure_user; the account is then
  # always this run's, since a reused one is reused only on a valid marker.
  if [[ "$ACCOUNT_CREATED" == yes ]]; then
    account_marker_matches || write_account_marker || die_account_marker "$MARKER_ERROR"
  fi
  place_binary
  switch_current "$PLACED_NAME"
  say "Installed salvorias-node $STAGED_VERSION at $BIN_ROOT/$PLACED_NAME (linked from $PATH_LINK)"
  ensure_node_key
  write_state awaiting-registration
  install_self_copy

  query_chain "$PATH_LINK" "$NODE_ADDRESS"
  await_funded_and_registered
  finalize_install
}

# From a fresh slot-info --node result in SLOT_JSON: goes on at once when the
# node is already registered and funded (a kept or imported key), otherwise
# shows what is left to do and waits for it.
await_funded_and_registered() {
  read_readiness
  if [[ "$NODE_REGISTERED" == yes && "$NODE_FUNDED" == yes ]]; then
    say "Node $NODE_ADDRESS is registered and holds $(wei_to_savdr "$(json_str nodeBalanceWei)") SAVDR."
    return 0
  fi
  if [[ "$NODE_REGISTERED" == yes ]]; then
    print_funding_box
  else
    print_setup_boxes "$OPEN_SLOTS"
  fi
  wait_until_ready "$OPT_WAIT_MINUTES"
}

finalize_install() {
  banner "Starting the node service"
  write_env_file
  write_unit_file
  # "starting" until the service has started AND stayed up through the
  # watch below, so a failed start or an early crash stays resumable instead
  # of being recorded as installed.
  write_state starting
  systemctl daemon-reload
  # enable and start separately: `enable --now` exits 0 even when the start
  # job fails (seen on systemd 255), while `start` waits for the job and
  # reports its result.
  local err=""
  if ! err=$(systemctl enable "$UNIT_NAME" 2>&1 >/dev/null) || ! err=$(systemctl start "$UNIT_NAME" 2>&1 >/dev/null); then
    say ""
    say "Recent log:"
    show_journal 20
    die "The node service could not be started ($(clean_text -n 300 "$err")). The key and settings are saved, and systemd keeps retrying the service. Fix the problem shown above, then run: $(cmd_hint resume)"
  fi
  if ! service_stays_up 10; then
    say ""
    say "Recent log:"
    show_journal 20
    die "The node service started but did not stay up (it stopped or was restarted within 10 seconds). The key and settings are saved, systemd keeps retrying the service, and the install is not marked finished. Fix the problem shown above, then run: $(cmd_hint resume)"
  fi
  write_state installed
  watch_first_checkin

  # Fresh balance and fee for the summary.
  local balance="" cost=""
  if run_slot_info "$PATH_LINK" "$NODE_ADDRESS"; then
    balance=$(json_str nodeBalanceWei)
    cost=$(json_str estimatedCheckInCostWei)
    read_binding
  fi

  banner "Salvorias node installed"
  say "  Network:   $NETWORK (chain $NET_CHAIN_ID)"
  say "  Node:      $NODE_ADDRESS"
  say "  Owner:     $OWNER"
  say "  Version:   $(current_version_name)"
  say "  Service:   $(systemctl is-active "$UNIT_NAME" 2>/dev/null || true) ($UNIT_NAME, enabled at boot)"
  say "  Key file:  $KEY_FILE"
  if is_uint "$balance"; then
    say "  Balance:   $(wei_to_savdr "$balance") SAVDR"
  fi
  if [[ -n "$OPT_IMPORT_KEY" ]]; then
    say ""
    say "The imported key is now installed. Delete the copy you imported from:"
    say "  sudo shred -u $OPT_IMPORT_KEY"
  fi
  warn_if_unfunded "$balance" "$cost"
  say ""
  say "Next:"
  say "  sudo salvorias-selfhost status       service, registration, funding, recent logs"
  say "  sudo salvorias-selfhost backup-key   copy the node key for offline storage (do this now)"
  say "  sudo salvorias-selfhost upgrade      install a newer node release"
  say "  sudo salvorias-selfhost uninstall    remove the node from this server"
  say "  sudo journalctl -u salvorias-node -f follow the node's log"
  if [[ ! -x "$SELF_PATH" ]]; then
    say "  ($SELF_PATH could not be installed; use instead: $(cmd_hint '<command>'))"
  fi
}

# ─── resume ────────────────────────────────────────────────────────────────

cmd_resume() {
  require_root
  check_platform
  ensure_tools
  load_state
  if [[ "$ST_STAGE" == "installed" ]]; then
    say "This node is already installed. Check it with: $(cmd_hint status)"
    say "If the service is not running, restart and repair it with: $(cmd_hint upgrade)"
    return 0
  fi
  [[ "$ST_STAGE" == "awaiting-registration" || "$ST_STAGE" == "starting" ]] || die "Unknown install stage '$ST_STAGE' in $STATE_FILE."
  check_existing_user
  secure_data_dir
  [[ -e "$KEY_FILE" ]] || die "The node key $KEY_FILE is missing, so this install cannot continue. Start over: $(cmd_hint uninstall), then install again."
  require_data_file "$KEY_FILE"
  [[ -x "$PATH_LINK" ]] || die "The node binary $PATH_LINK is missing. Start over: $(cmd_hint uninstall), then install again."
  if [[ ! -x "$SELF_PATH" || -n "$OPT_SELF" ]]; then install_self_copy; fi

  banner "Resuming the Salvorias node install"
  say "Network: $NETWORK (chain $NET_CHAIN_ID)"
  check_rpc
  query_chain "$PATH_LINK" "$NODE_ADDRESS"
  read_binding
  if [[ "$BOUND_STATE" != "owner" ]]; then read_open_slots; fi
  await_funded_and_registered
  finalize_install
}

# ─── status ────────────────────────────────────────────────────────────────

# service_state_text ACTIVE ENABLED: the service state as one line of plain
# words, from the output of `systemctl is-active` and `systemctl is-enabled`
# (either may be empty or have several lines; only the first word is used).
service_state_text() {
  local active enabled boot
  read -r active _ <<<"$1" || true
  read -r enabled _ <<<"$2" || true
  [[ "$active" =~ ^[a-z-]+$ ]] || active="unknown"
  case "$enabled" in
    enabled|enabled-runtime) boot="enabled at boot" ;;
    disabled) boot="not enabled at boot" ;;
    masked|masked-runtime) boot="masked, it will not start" ;;
    static|indirect|generated|alias|transient) boot="no boot setting" ;;
    ""|not-found) boot="not installed yet" ;;
    *) boot="boot setting unknown" ;;
  esac
  printf '%s (%s)' "$active" "$boot"
}

cmd_status() {
  require_root
  load_state
  banner "Salvorias node status"
  say "  Network:   $NETWORK (chain $NET_CHAIN_ID, $RPC_URL)"
  say "  Install:   $ST_STAGE"
  # No `|| printf` fallback on is-enabled: it exits non-zero for every state
  # except enabled, yet still prints the state (not-found, disabled, masked).
  say "  Service:   $(service_state_text "$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)" "$(systemctl is-enabled "$UNIT_NAME" 2>/dev/null || true)")"
  say "  Version:   $(node_run 30 "$PATH_LINK" version </dev/null 2>/dev/null || printf 'binary missing') ($(current_version_name))"
  say "  Node:      $NODE_ADDRESS"
  say "  Owner:     $OWNER"

  if run_slot_info "$PATH_LINK" "$NODE_ADDRESS"; then
    read_binding
    case "$BOUND_STATE" in
      owner) say "  Registered: yes (to the owner)" ;;
      replaced) say "  Registered: NO: another node has taken its place (app > Licenses > Self Setup, paste the node address to register it again)" ;;
      other) say "  Registered: NO: registered to a DIFFERENT WALLET ($BOUND_OTHER)" ;;
      *) say "  Registered: NO (app > Licenses > Self Setup, paste the node address)" ;;
    esac
    local balance cost
    balance=$(json_str nodeBalanceWei)
    cost=$(json_str estimatedCheckInCostWei)
    if ! is_uint "$balance"; then
      say "  Funded:     unknown (the chain query returned no balance)"
    elif has_balance "$balance"; then
      say "  Funded:     yes ($(wei_to_savdr "$balance") SAVDR)"
    else
      say "  Funded:     NO (0 SAVDR; send 1 SAVDR to the node address)"
    fi
    if is_uint "$balance"; then warn_if_unfunded "$balance" "$cost"; fi
    if [[ "$BOUND_STATE" == owner ]] && has_balance "$balance"; then
      say ""
      say "$ACTIVE_NOTE"
    fi
  else
    say "  Chain:     could not read the chain ($(clean_text "$(json_str error)"))"
  fi

  say ""
  say "Last 20 log lines:"
  show_journal 20
}

# ─── upgrade ───────────────────────────────────────────────────────────────

cmd_upgrade() {
  require_root
  check_platform
  ensure_tools
  load_state
  [[ "$ST_STAGE" == "installed" ]] || die "The install has not finished (stage: $ST_STAGE). Finish it first: $(cmd_hint resume)"
  [[ -f "$UNIT_FILE" ]] || die "The service $UNIT_NAME is not installed."
  check_existing_user
  if (( OPT_ROLLBACK == 1 )); then
    upgrade_rollback
    return 0
  fi

  banner "Upgrading the Salvorias node"
  repair_layout
  stage_binary
  local previous
  previous=$(current_version_name)
  if [[ -n "$previous" && -f "$BIN_ROOT/$previous/salvorias-node" ]] \
      && [[ "$(file_sha "$STAGED_BIN")" == "$(file_sha "$BIN_ROOT/$previous/salvorias-node")" ]]; then
    install_self_copy
    if (( UNIT_CHANGED == 0 )) && systemctl is-active --quiet "$UNIT_NAME"; then
      say "Already running this binary ($previous). Nothing to do."
      return 0
    fi
    if (( UNIT_CHANGED == 1 )); then
      say "Already on this binary ($previous). Restarting the service to apply the updated unit file..."
    else
      say "Already on this binary ($previous), but the service is not running. Restarting it..."
    fi
    systemctl restart "$UNIT_NAME" || true
    if service_stays_up 10; then
      say "The service is running on $previous."
      return 0
    fi
    say ""
    say "Recent log:"
    show_journal 15
    die "The service does not stay up on $previous. Read the log above, then check: $(cmd_hint status)"
  fi

  place_binary
  say "Switching from ${previous:-none} to $PLACED_NAME and restarting..."
  # From here until the watch ends, an interrupt switches back (on_signal).
  UPGRADE_ROLLBACK_TO="$previous"
  UPGRADE_PLACED="$PLACED_NAME"
  UPGRADE_PLACED_NEW=$(( PLACED_EXISTED == 0 ? 1 : 0 ))
  switch_current "$PLACED_NAME"
  systemctl restart "$UNIT_NAME" || true

  if service_stays_up "$SALVORIAS_UPGRADE_WATCH_SECONDS"; then
    UPGRADE_ROLLBACK_TO=""
    say "The service stayed up for ${SALVORIAS_UPGRADE_WATCH_SECONDS}s on $PLACED_NAME."
    set_previous_link "$previous"
    prune_versions "$PLACED_NAME" "$previous"
    install_self_copy
    banner "Upgrade complete: $PLACED_NAME"
    say "To switch back to $previous later: $(cmd_hint 'upgrade --rollback')"
    return 0
  fi

  say ""
  say "Log from the failed start:"
  show_journal 15
  if [[ -z "$previous" ]]; then
    die "The new binary did not stay up and there is no previous version to roll back to."
  fi
  say ""
  say "Rolling back to $previous ..."
  undo_upgrade
  if service_stays_up 10; then
    die "Upgrade to $PLACED_NAME failed: the service did not stay up. Rolled back to $previous, which is running again."
  fi
  die "Upgrade to $PLACED_NAME failed and $previous is not staying up either. Check: $(cmd_hint status)"
}

# Switches back to UPGRADE_ROLLBACK_TO and removes the directory the
# interrupted or failed upgrade placed, if it created one.
# UPGRADE_ROLLBACK_TO is cleared only once the switch back has happened: an
# interrupt that lands while this runs makes on_signal call it again, and
# every step is safe to repeat. Cleared any earlier, that interrupt would
# find nothing to switch back to and leave the failed version current.
undo_upgrade() {
  local to="$UPGRADE_ROLLBACK_TO"
  [[ -n "$to" ]] || return 0
  switch_current "$to"
  UPGRADE_ROLLBACK_TO=""
  systemctl restart "$UNIT_NAME" || true
  if (( UPGRADE_PLACED_NEW == 1 )) && [[ -n "$UPGRADE_PLACED" && "$UPGRADE_PLACED" != "$to" ]]; then
    rm -rf "${BIN_ROOT:?}/$UPGRADE_PLACED"
  fi
}

# Brings an install made by an earlier installer version to the current
# layout: the root-owned data directory and address record, and the unit
# file without ReadWritePaths. Safe to repeat. Sets UNIT_CHANGED.
repair_layout() {
  secure_data_dir
  [[ -e "$KEY_FILE" ]] || die "The node key $KEY_FILE is missing."
  require_data_file "$KEY_FILE"
  write_address_file
  write_unit_file
  if (( UNIT_CHANGED == 1 )); then
    systemctl daemon-reload
    say "Updated $UNIT_FILE to the current layout."
  fi
}

# upgrade --rollback: switches to the version kept by the last upgrade,
# watches it like an upgrade, and switches forward again if it fails. The two
# versions trade places, so a second --rollback goes forward again.
upgrade_rollback() {
  local current previous
  banner "Rolling back the Salvorias node"
  repair_layout
  current=$(current_version_name)
  previous=$(previous_version_name)
  if [[ -z "$previous" || "$previous" == "$current" || "$previous" == */* || -L "$BIN_ROOT/$previous" \
      || ! -x "$BIN_ROOT/$previous/salvorias-node" ]]; then
    die "There is no previous version kept on this server to roll back to."
  fi
  check_elf "$BIN_ROOT/$previous/salvorias-node" || die "The kept version $previous cannot be used: $ELF_PROBLEM."
  say "Switching from $current to $previous and restarting..."
  UPGRADE_ROLLBACK_TO="$current"
  UPGRADE_PLACED=""
  UPGRADE_PLACED_NEW=0
  switch_current "$previous"
  systemctl restart "$UNIT_NAME" || true
  if service_stays_up "$SALVORIAS_UPGRADE_WATCH_SECONDS"; then
    UPGRADE_ROLLBACK_TO=""
    set_previous_link "$current"
    banner "Rolled back to $previous"
    say "To go forward to $current again: $(cmd_hint 'upgrade --rollback')"
    return 0
  fi
  say ""
  say "Log from the failed start:"
  show_journal 15
  say ""
  say "Switching back to $current ..."
  undo_upgrade
  if service_stays_up 10; then
    die "Rollback to $previous failed: the service did not stay up. Switched back to $current, which is running again."
  fi
  die "Rollback to $previous failed and $current is not staying up either. Check: $(cmd_hint status)"
}

# Keeps the current and previous version directories, removes the rest, but
# only directories shaped like the ones place_binary makes (the binary, and
# the temp name it is copied under). Anything else in there is not ours to
# delete recursively.
prune_versions() {
  local dir name other
  for dir in "$BIN_ROOT"/*; do
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    name=$(basename "$dir")
    if [[ "$name" != "$1" && "$name" != "$2" ]]; then
      other=$(find "$dir" -mindepth 1 -maxdepth 1 ! -name salvorias-node ! -name .salvorias-node.new -print -quit 2>/dev/null)
      if [[ -n "$other" ]]; then
        warn "Leaving $dir in place: it holds files this installer did not put there."
        continue
      fi
      rm -rf "${BIN_ROOT:?}/$name"
    fi
  done
}

# ─── backup-key ────────────────────────────────────────────────────────────

# check_backup_dir DIR: the backup is written as root, so DIR and every
# directory above it must be root's alone. A directory another user can
# write to (or a sticky one, for DIR itself) would let them choose or swap
# what the path points at. Ancestors may be sticky and world-writable (like
# /tmp): there no one else can rename a root-owned entry.
check_backup_dir() {
  local dir real info mode owner
  real=$(cd -P -- "$1" 2>/dev/null && pwd -P) || die "Cannot resolve the directory $1."
  dir="$real"
  while :; do
    info=$(stat -c '%a %u' -- "$dir") || die "Cannot inspect $dir."
    mode="${info% *}"
    owner="${info#* }"
    if [[ "$owner" != 0 ]]; then
      die "$dir is not owned by root. Refusing to write the node key backup under it. Use a root-only directory such as /root."
    fi
    if [[ "$dir" == "$real" ]]; then
      if (( (8#$mode & 8#1022) != 0 )); then
        die "$dir (mode $mode) can be written by users other than root. Refusing to write the node key backup into it. Use a root-only directory such as /root."
      fi
    elif (( (8#$mode & 8#022) != 0 && (8#$mode & 8#1000) == 0 )); then
      die "$dir (mode $mode) can be written by users other than root. Refusing to write the node key backup under it. Use a root-only directory such as /root."
    fi
    [[ "$dir" != "/" ]] || break
    dir=$(dirname -- "$dir")
  done
}

# The key is copied once into the root-only temp dir, checked there, and the
# backup is written from that checked copy.
BACKUP_TMP=""
cmd_backup_key() {
  require_root
  secure_data_dir
  [[ -e "$KEY_FILE" || -L "$KEY_FILE" ]] || die "No node key found at $KEY_FILE."
  require_data_file "$KEY_FILE"
  local out="${OPT_OUT:-/root/salvorias-node-key-backup-$(date +%Y%m%d-%H%M%S).txt}"
  local out_dir out_name
  out_dir=$(dirname -- "$out")
  out_name=$(basename -- "$out")
  case "$out" in */) die "--out must name a file, not a directory: $out" ;; esac
  case "$out_name" in .|..) die "--out must name a file: $out" ;; esac
  [[ ! -e "$out" && ! -L "$out" ]] || die "$out already exists. Choose another path with --out."
  [[ ! -L "$out_dir" ]] || die "$out_dir is a symbolic link. Refusing to write the key through it. Pass a path in a real directory."
  [[ -d "$out_dir" ]] || die "Directory $out_dir does not exist."
  check_backup_dir "$out_dir"
  make_tmp_dir
  local staged="$TMP_DIR/key-backup" addr=""
  ( umask 077; head -c 4096 -- "$KEY_FILE" >"$staged" ) || die "Could not read $KEY_FILE."
  if [[ -x "$PATH_LINK" ]]; then
    derive_address "$PATH_LINK" "$staged" || die "$KEY_FILE does not hold exactly one valid node key. Nothing was written."
    addr="$DERIVED_ADDRESS"
  else
    warn "The node binary is not installed, so the key file could not be checked before copying."
  fi
  # The temp file is created (O_EXCL) and fully set up inside the checked
  # directory, then renamed into place; nothing touches $out by name after
  # that, so no later step can follow a link someone put there.
  BACKUP_TMP=$(umask 077; mktemp -- "$out_dir/.salvorias-key-backup.XXXXXX") || die "Could not create a file in $out_dir."
  if ! { cat -- "$staged" >"$BACKUP_TMP" && chown root:root -- "$BACKUP_TMP" && chmod 0600 -- "$BACKUP_TMP"; }; then
    die "Could not write the backup in $out_dir."
  fi
  [[ ! -e "$out" && ! -L "$out" ]] || die "$out appeared while the backup was being written. Nothing was written there."
  mv -T -- "$BACKUP_TMP" "$out" || die "Could not move the backup to $out."
  BACKUP_TMP=""

  banner "Node key backed up"
  say "  File:  $out (mode 0600, root only)"
  if [[ -n "$addr" ]]; then say "  Node:  $addr"; fi
  say ""
  say "Anyone with this file controls the node wallet and the SAVDR on it."
  say "  1. Copy it to offline storage you trust (an encrypted USB drive or a"
  say "     password manager), for example: scp it to your computer, then move it."
  say "  2. Delete it from this server: sudo shred -u $out"
  say "To move the node to a new server later, install there with:"
  say "  --import-key <path to this file>"
}

# ─── uninstall ─────────────────────────────────────────────────────────────

confirm_typed() {
  local expected="$1" prompt="$2" answer=""
  have_tty || return 1
  printf '%s' "$prompt" >/dev/tty
  IFS= read -r answer </dev/tty || true
  [[ "$answer" == "$expected" ]]
}

cmd_uninstall() {
  require_root
  local addr=""
  # Whether the fixed paths below are shown to be this installer's. Decided
  # first, from the state file and the marker as they are now: the state file
  # is removed part-way through.
  local proven=no self_ours=0
  if installer_proof; then proven=yes; fi
  if self_file_is_ours; then self_ours=1; fi
  # Only read from a directory the service cannot change (the current layout).
  if [[ -d "$DATA_DIR" && ! -L "$DATA_DIR" && "$(stat -c '%u' -- "$DATA_DIR")" == 0 \
      && -f "$ADDRESS_FILE" && ! -L "$ADDRESS_FILE" ]]; then
    addr=$(head -c 100 -- "$ADDRESS_FILE" | head -n 1)
    is_address "$addr" || addr=""
  fi
  # Read now: the state file is removed before the account is considered.
  # A state file from before ACCOUNT_CREATED was recorded counts as "no":
  # those installers set no account comment that could tell their account
  # apart from one made by hand, so the account is kept.
  local account_created=no account_why="this installer did not create it"
  if state_file_is_ours; then
    local recorded
    recorded=$(sed -n 's/^NODE_ADDRESS=//p' "$STATE_FILE" | head -n 1)
    if is_address "$recorded"; then addr="$recorded"; fi
    recorded=$(sed -n 's/^ACCOUNT_CREATED=//p' "$STATE_FILE" | head -n 1)
    local recorded_uid current_uid
    recorded_uid=$(sed -n 's/^ACCOUNT_UID=//p' "$STATE_FILE" | head -n 1)
    current_uid=$(id -u "$SERVICE_USER" 2>/dev/null || true)
    if [[ "$recorded" == "yes" ]] && is_uint "$recorded_uid" && [[ "$recorded_uid" == "$current_uid" ]]; then
      account_created=yes
    elif [[ "$recorded" == "yes" ]]; then
      account_why="it is not the account this installer created (its UID does not match the recorded one)"
    elif [[ -z "$recorded" ]]; then
      account_why="this install predates the installer's record of who created it"
    fi
  elif account_marker_matches; then
    account_created=yes
  fi
  # Uninstall deletes $ETC_DIR and $OPT_DIR recursively, and the data
  # directory with --purge-key. It does that only to directories this
  # installer is shown to have made: a server that happens to have a directory
  # of that name gets a refusal and keeps it.
  if [[ "$proven" == no ]]; then
    local foreign="" p
    for p in "$ETC_DIR" "$OPT_DIR"; do
      if [[ -e "$p" || -L "$p" ]]; then foreign+="$p "; fi
    done
    if (( OPT_PURGE_KEY == 1 )) && [[ -e "$DATA_DIR" || -L "$DATA_DIR" ]]; then foreign+="$DATA_DIR "; fi
    if [[ -n "$foreign" ]]; then
      die "${foreign% } exists, and nothing shows that this installer created it (no installer state file in $ETC_DIR, and no installer marker for the $SERVICE_USER account in $DATA_DIR). Refusing to delete it. Nothing was changed. If it is yours, inspect it and remove it by hand. If it is left over from an interrupted install, copy the node key out first (it would be $KEY_FILE), then remove it by hand."
    fi
  fi

  local unit_load unit_existed=0 strays
  unit_load=$(systemctl show -p LoadState --value "$UNIT_NAME" 2>/dev/null || true)
  if [[ -e "$UNIT_FILE" || -L "$UNIT_FILE" ]]; then unit_existed=1; fi
  strays=$(stray_files "$proven")
  # A key in a data directory that is not shown to be ours is not this
  # node's to report or delete.
  local key_here=0
  if [[ "$proven" == yes && ( -e "$KEY_FILE" || -L "$KEY_FILE" ) ]]; then key_here=1; fi
  if [[ ! -e "$STATE_FILE" && ! -e "$ENV_FILE" && ! -e "$UNIT_FILE" && ! -e "$OPT_DIR" && "$key_here" == 0 && "$self_ours" == 0 \
      && "$unit_load" != "loaded" && -z "$strays" ]]; then
    say "Nothing to uninstall: no Salvorias self-host node found on this server."
    return 0
  fi

  banner "Uninstall the Salvorias node"
  say "This removes: the $UNIT_NAME service, $OPT_DIR, $PATH_LINK, $ETC_DIR and $SELF_PATH."
  if (( OPT_PURGE_KEY == 1 )); then
    say "It also DELETES the node key $KEY_FILE (--purge-key)."
    if [[ "$account_created" == "yes" ]] && id -u "$SERVICE_USER" >/dev/null 2>&1; then
      say "It also deletes the $SERVICE_USER system user, which this installer created."
    elif id -u "$SERVICE_USER" >/dev/null 2>&1; then
      say "It keeps the $SERVICE_USER system user: $account_why."
    fi
  else
    say "It keeps the node key $KEY_FILE (a later install reuses it)."
  fi

  # Checked before any question or change: purging shreds the key as root,
  # so it must be a regular file in a directory the service cannot change.
  if (( OPT_PURGE_KEY == 1 )); then
    secure_data_dir
    if [[ -e "$KEY_FILE" || -L "$KEY_FILE" ]]; then require_data_file "$KEY_FILE"; fi
  fi

  # Ask every question before changing anything, so a "no" leaves the
  # server exactly as it was.
  if (( OPT_YES == 0 || OPT_PURGE_KEY == 1 )) && ! have_tty; then
    usage_error "No terminal for the confirmation. Pass --yes to uninstall without asking (--purge-key always needs a terminal)."
  fi
  if (( OPT_YES == 0 )); then
    confirm_typed "uninstall" "Type 'uninstall' to continue: " || { say "Cancelled. Nothing was changed."; exit "$EXIT_ERROR"; }
  fi
  if (( OPT_PURGE_KEY == 1 )) && [[ -e "$KEY_FILE" ]]; then
    say ""
    say "Deleting the node key cannot be undone. Without a backup, node ${addr:-(unknown)}"
    say "and any SAVDR on it are lost for good. Back it up first with: $(cmd_hint backup-key)"
    confirm_typed "delete node key" "Type 'delete node key' to delete it: " \
      || { say "Cancelled. Nothing was changed."; exit "$EXIT_ERROR"; }
  fi

  # Stopped whether or not the unit file is still there: a unit whose file
  # was deleted stays loaded (and running) until it is stopped and systemd
  # is reloaded. Nothing else is removed unless the service really stopped.
  local state wants="/etc/systemd/system/multi-user.target.wants/$UNIT_NAME" incomplete=0 err
  systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || true
  state=$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)
  case "$state" in
    active|activating|deactivating|reloading|refreshing)
      die "The $UNIT_NAME service is still running (state: $state) after 'systemctl stop'. Nothing was removed. Stop it with 'sudo systemctl stop $UNIT_NAME', check 'sudo systemctl status $UNIT_NAME', then run the uninstall again." ;;
  esac
  systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
  # disable cannot find the unit once its file is gone, so remove the boot
  # link it left behind directly.
  if [[ -L "$wants" ]]; then rm -f -- "$wants"; fi
  rm -f -- "$UNIT_FILE"
  systemctl daemon-reload
  systemctl reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true
  if [[ -e "$UNIT_FILE" || -L "$wants" ]]; then
    warn "Could not remove $UNIT_FILE or $wants."
    incomplete=1
  elif (( unit_existed == 1 )) || [[ "$unit_load" == "loaded" ]]; then
    say "Stopped and removed the service."
  fi
  # Only the link switch_current makes: anything else at that path is not ours.
  if path_link_is_ours; then
    rm -f -- "$PATH_LINK"
    say "Removed $OPT_DIR, $PATH_LINK and $ETC_DIR."
  elif [[ -e "$PATH_LINK" || -L "$PATH_LINK" ]]; then
    say "Removed $OPT_DIR and $ETC_DIR. Left $PATH_LINK alone: it is not the link this installer makes."
  else
    say "Removed $OPT_DIR, $PATH_LINK and $ETC_DIR."
  fi
  rm -rf -- "$OPT_DIR" "$ETC_DIR"
  remove_strays "$proven"

  if (( OPT_PURGE_KEY == 1 )); then
    if [[ -e "$KEY_FILE" ]]; then
      require_data_file "$KEY_FILE"
      shred -u "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"
    fi
    # rm -r removes links without following them.
    rm -rf "$DATA_DIR"
    say "Deleted the node key and $DATA_DIR."
    if id -u "$SERVICE_USER" >/dev/null 2>&1 && [[ "$account_created" == "yes" ]]; then
      if err=$(userdel "$SERVICE_USER" 2>&1); then
        say "Deleted the $SERVICE_USER user."
      else
        warn "Could not delete the $SERVICE_USER user (userdel: $(clean_text "$err")). A process may still be running as it: check with 'ps -u $SERVICE_USER', then run 'sudo userdel $SERVICE_USER'."
        incomplete=1
      fi
    elif id -u "$SERVICE_USER" >/dev/null 2>&1; then
      say "Kept the $SERVICE_USER user: $account_why. If nothing else uses it, remove it with 'sudo userdel $SERVICE_USER'."
    fi
  elif [[ -e "$KEY_FILE" ]]; then
    say "Kept the node key at $KEY_FILE (and the $SERVICE_USER user that owns it)."
  fi
  # The state file is gone now; the marker carries "this installer created
  # the account" to the next install, which reuses the kept key and account.
  if (( OPT_PURGE_KEY == 0 )) && [[ "$account_created" == "yes" ]]; then
    record_kept_account
  fi

  # The license is not freed by an uninstall, and the app counts this node as
  # active for 2 days after its last check-in. Registering a new node right
  # away can therefore move a Save Hosting node instead (after a warning), so
  # the reminder points at moving the key rather than at a new registration.
  say ""
  if [[ -n "$addr" ]]; then
    say "If node $addr was registered to one of your licenses, that license keeps pointing at it."
  else
    say "If the node was registered to one of your licenses, that license keeps pointing at it."
  fi
  if [[ -e "$KEY_FILE" ]]; then
    local hint_mode=""
    if (( incomplete == 0 )); then hint_mode="self-gone"; fi
    say "To move this node to another server, copy its key here with:"
    say "  $(cmd_hint backup-key "$hint_mode")"
    say "then install there with --import-key and that file. No new registration is needed."
  fi
  say "If you register a different node instead, the app may replace this node or, if all"
  say "your licenses are busy, a Save Hosting node, after asking you."

  # Last, so the steps above can still be retried with it if anything failed.
  if (( incomplete == 1 )); then
    die "The uninstall did not finish: see the warnings above. Fix them, then run: $(cmd_hint uninstall)"
  fi
  if (( self_ours == 1 )); then
    rm -f -- "$SELF_PATH"
    say "Removed $SELF_PATH."
  elif [[ -e "$SELF_PATH" || -L "$SELF_PATH" ]]; then
    say "Left $SELF_PATH alone: it is not a copy of this installer."
  fi
}

# Files an interrupted run can leave behind: the temp copies made next to
# salvorias-selfhost and the unit file before they are renamed into place,
# and staging directories in DATA_DIR (which can hold a key copy). The data
# directory's are listed only when it is shown to be ours (stray_files yes).
stray_files() {
  local f
  for f in /usr/local/sbin/.salvorias-selfhost.* /etc/systemd/system/.salvorias-node.service.*; do
    if [[ -e "$f" || -L "$f" ]]; then printf '%s\n' "$f"; fi
  done
  if [[ "${1:-no}" == yes ]]; then
    for f in "$DATA_DIR"/.stage.*; do
      if [[ -e "$f" || -L "$f" ]]; then printf '%s\n' "$f"; fi
    done
  fi
}

# Removes those leftovers (remove_strays yes|no: whether DATA_DIR is shown to
# be ours). rm never follows a link. Key copies in a staging directory are
# shredded first, but only inside a real root-owned directory in a root-owned
# DATA_DIR: there the service account cannot swap a file for a link between
# the find and the shred. The temp copies beside the unit file and
# salvorias-selfhost are files; a directory of that name is not ours.
remove_strays() {
  local f n=0 data_ok=0
  if [[ -d "$DATA_DIR" && ! -L "$DATA_DIR" && "$(stat -c '%u' -- "$DATA_DIR")" == 0 ]]; then data_ok=1; fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ "$f" == "$DATA_DIR"/* ]]; then
      (( data_ok == 1 )) || continue
      if [[ -d "$f" && ! -L "$f" && "$(stat -c '%u' -- "$f")" == 0 ]]; then
        find "$f" -xdev -type f -links 1 \( -name 'key-*' -o -name 'node-key.txt' \) -exec shred -u {} + 2>/dev/null || true
      fi
      rm -rf -- "$f"
    elif [[ -d "$f" && ! -L "$f" ]]; then
      continue
    else
      rm -f -- "$f"
    fi
    n=$((n + 1))
  done < <(stray_files "${1:-no}")
  if (( n > 0 )); then say "Removed $n file(s) left by an interrupted run."; fi
}

# ─── Argument parsing ──────────────────────────────────────────────────────

COMMAND="install"
OPT_NETWORK="mainnet"
OPT_RPC_URL=""
OPT_OWNER=""
OPT_BINARY=""
OPT_SELF=""
OPT_VERSION=""
OPT_WAIT_MINUTES="$SALVORIAS_WAIT_MINUTES"
OPT_IMPORT_KEY=""
OPT_OUT=""
OPT_PURGE_KEY=0
OPT_YES=0
OPT_ROLLBACK=0
SEEN_FLAGS=()

need_value() {
  if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then usage_error "$1 needs a value."; fi
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      install|resume|status|upgrade|backup-key|uninstall) COMMAND="$1"; shift ;;
      help) usage; exit 0 ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    SEEN_FLAGS+=("$1")
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --network) need_value "$@"; OPT_NETWORK="$2"; shift ;;
      --rpc-url) need_value "$@"; OPT_RPC_URL="$2"; shift ;;
      --owner) need_value "$@"; OPT_OWNER="$2"; shift ;;
      --binary) need_value "$@"; OPT_BINARY="$2"; shift ;;
      --self) need_value "$@"; OPT_SELF="$2"; shift ;;
      --version) need_value "$@"; OPT_VERSION="$2"; shift ;;
      --wait-minutes) need_value "$@"; OPT_WAIT_MINUTES="$2"; shift ;;
      --import-key) need_value "$@"; OPT_IMPORT_KEY="$2"; shift ;;
      --out) need_value "$@"; OPT_OUT="$2"; shift ;;
      --purge-key) OPT_PURGE_KEY=1 ;;
      --rollback) OPT_ROLLBACK=1 ;;
      --yes|-y) OPT_YES=1 ;;
      *) usage_error "Unknown argument: $1" ;;
    esac
    shift
  done

  local allowed flag
  case "$COMMAND" in
    install) allowed=" --network --rpc-url --owner --binary --self --version --wait-minutes --import-key " ;;
    resume) allowed=" --wait-minutes --self " ;;
    status) allowed=" " ;;
    upgrade) allowed=" --binary --version --self --rollback " ;;
    backup-key) allowed=" --out " ;;
    uninstall) allowed=" --purge-key --yes -y " ;;
  esac
  for flag in "${SEEN_FLAGS[@]}"; do
    [[ "$allowed" == *" $flag "* ]] || usage_error "$flag does not apply to '$COMMAND'."
  done

  if [[ -n "$OPT_VERSION" && ! "$OPT_VERSION" =~ ^v?[0-9A-Za-z._-]{1,64}$ ]]; then
    usage_error "--version must be a release tag such as v0.1.0."
  fi
  if [[ -n "$OPT_BINARY" && -n "$OPT_VERSION" ]]; then
    usage_error "Use either --binary or --version, not both."
  fi
  if (( OPT_ROLLBACK == 1 )) && [[ -n "$OPT_BINARY$OPT_VERSION$OPT_SELF" ]]; then
    usage_error "--rollback switches to the kept previous version; it takes no --binary, --version or --self."
  fi
  is_safe_repo "$SALVORIAS_RELEASE_REPO" || usage_error "SALVORIAS_RELEASE_REPO must be a GitHub owner/name (letters, digits, . _ -): $SALVORIAS_RELEASE_REPO"
  if [[ -n "$SALVORIAS_RELEASE_BASE_URL" ]]; then require_safe_url "$SALVORIAS_RELEASE_BASE_URL" "SALVORIAS_RELEASE_BASE_URL"; fi
  if [[ -n "$OPT_RPC_URL" ]]; then require_safe_url "$OPT_RPC_URL" "--rpc-url"; fi
  if ! is_uint "$OPT_WAIT_MINUTES" || (( OPT_WAIT_MINUTES < 1 )); then
    usage_error "--wait-minutes must be a whole number of minutes (1 or more)."
  fi
  if ! is_uint "$SALVORIAS_POLL_SECONDS" || (( SALVORIAS_POLL_SECONDS < 1 )); then
    usage_error "SALVORIAS_POLL_SECONDS must be a whole number of seconds (1 or more)."
  fi
  if ! is_uint "$SALVORIAS_UPGRADE_WATCH_SECONDS" || (( SALVORIAS_UPGRADE_WATCH_SECONDS < MIN_UPGRADE_WATCH_SECONDS )); then
    usage_error "SALVORIAS_UPGRADE_WATCH_SECONDS must be a whole number of seconds, at least $MIN_UPGRADE_WATCH_SECONDS (a shorter watch cannot tell a working upgrade from a crashing one)."
  fi
  if ! is_uint "$SALVORIAS_FIRST_CHECKIN_SECONDS" || (( SALVORIAS_FIRST_CHECKIN_SECONDS > 3600 )); then
    usage_error "SALVORIAS_FIRST_CHECKIN_SECONDS must be a whole number of seconds, 0 to 3600 (0 skips the watch)."
  fi
}

main() {
  # `install.sh --version` alone prints the installer version; with a value
  # it is the install command's release tag.
  if [[ $# -eq 1 && "$1" == "--version" ]]; then
    say "salvorias self-host installer v$INSTALLER_VERSION"
    exit 0
  fi
  umask 077
  detect_running_file
  trap cleanup EXIT
  trap on_signal INT TERM HUP
  parse_args "$@"
  # status only reads, so it still works while another command runs.
  if [[ "$COMMAND" != "status" ]]; then
    require_root
    take_lock
  fi
  case "$COMMAND" in
    install) cmd_install ;;
    resume) cmd_resume ;;
    status) cmd_status ;;
    upgrade) cmd_upgrade ;;
    backup-key) cmd_backup_key ;;
    uninstall) cmd_uninstall ;;
  esac
}

# Everything runs from main, on the last line, so a `curl | bash` run has read
# the whole script before any command can consume stdin.
main "$@"
