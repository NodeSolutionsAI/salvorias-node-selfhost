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
#
# Usage: see usage() below, or run with --help.
# The marker on line 2 lets the self-copy step recognise a genuine copy.

set -euo pipefail

INSTALLER_VERSION="0.1.0"

# ─── Configuration (environment overrides) ────────────────────────────────

SALVORIAS_RELEASE_REPO="${SALVORIAS_RELEASE_REPO:-NodeSolutionsAI/salvorias-node-selfhost}"
# Full base URL that holds the release assets (binaries, install.sh,
# checksums.txt). Empty means GitHub Releases for SALVORIAS_RELEASE_REPO, at the
# tag given by --version, or the latest release when no --version is given.
SALVORIAS_RELEASE_BASE_URL="${SALVORIAS_RELEASE_BASE_URL:-}"
SALVORIAS_WAIT_MINUTES="${SALVORIAS_WAIT_MINUTES:-30}"
SALVORIAS_POLL_SECONDS="${SALVORIAS_POLL_SECONDS:-15}"
SALVORIAS_UPGRADE_WATCH_SECONDS="${SALVORIAS_UPGRADE_WATCH_SECONDS:-30}"

# ─── Fixed layout ──────────────────────────────────────────────────────────
# Not overridable: the systemd unit, node.env and the docs all name these.

SERVICE_USER="salvorias"
OPT_DIR="/opt/salvorias"
BIN_ROOT="$OPT_DIR/bin"
CURRENT_LINK="$BIN_ROOT/current"
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

# Self-host wallets are not fee-exempt, so the daemon must pay the live
# network fee. The cap stops it from paying through a fee spike.
GAS_PRICE_MODE="network"
MAX_GAS_PRICE_GWEI=50
DAYS_TO_FUND=90
PROBE_NODE_ADDRESS="0x0000000000000000000000000000000000000001"

EXIT_ERROR=1
EXIT_USAGE=2
EXIT_STOPPED=3

# ─── Output helpers ────────────────────────────────────────────────────────

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit "$EXIT_ERROR"; }
usage_error() { printf 'ERROR: %s\n' "$*" >&2; printf 'Run with --help for usage.\n' >&2; exit "$EXIT_USAGE"; }
# A precondition outside this server is not met (no license, no free slot,
# not registered yet). Nothing is broken; the user has something to do.
stop() { printf '\nSTOPPED: %s\n' "$*" >&2; exit "$EXIT_STOPPED"; }
banner() { printf '\n=== %s ===\n' "$*"; }
rule() { printf '%s\n' "========================================================================"; }

usage() {
  cat <<EOF
Salvorias self-host node installer v$INSTALLER_VERSION

Runs ONE Salvorias check-in node on this server for your node license.
Needs root (sudo), Linux with systemd. Tested on Ubuntu 22.04+ and Debian 12+.

USAGE
  sudo bash install.sh [command] [options]
  curl -fsSL <install.sh url> | sudo bash -s -- [command] [options]
  sudo salvorias-selfhost <command> [options]     (after install)

COMMANDS
  install          Set up the node (default command)
  resume           Continue an install that was waiting for registration
  status           Service state, version, slot binding, balance, recent logs
  upgrade          Install a newer node binary; rolls back if it fails to run
  backup-key       Copy the node key to a root-only file for offline storage
  uninstall        Remove the service, binary and config (keeps the key)

INSTALL OPTIONS
  --owner 0x...            License owner's PUBLIC wallet address (else prompted)
  --network NAME           mainnet (default) or testnet
  --rpc-url URL            Use a different RPC endpoint for that network
  --version vX             Node release tag to install (default: latest)
  --wait-minutes N         How long to wait for registration (default: $SALVORIAS_WAIT_MINUTES)
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
  backup-key [--out PATH]          (default: /root/salvorias-node-key-backup-<time>.txt)
  uninstall  [--yes] [--purge-key] (--purge-key also deletes the node key, after
                                    a typed confirmation)
  -h, --help                       Show this help
  --version                        Show the installer version (as the only argument)

ENVIRONMENT
  SALVORIAS_RELEASE_BASE_URL   Base URL holding the release assets and checksums.txt
  SALVORIAS_WAIT_MINUTES       Default for --wait-minutes
  SALVORIAS_POLL_SECONDS       Registration poll interval (default 15)

EXIT CODES
  0 ok   1 error   2 bad usage or input   3 stopped: something to do outside
  this server (no license, no free slot, not registered yet)   130 interrupted
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
      ;;
    testnet)
      NET_RPC_URL="https://testnet.salvorias.net"
      NET_CHAIN_ID=7283
      NET_CHECKIN="0x51F6122C6014866Bd9443E21b05033b195A1fF27"
      NET_NFT="0xa1CF5786c6ceC9E8D0BbACEdF2cc98dAe4614363"
      NET_TREASURY="0x7e8ecebF965dE86fDE7Ebc7F3020813d656CF723"
      ;;
    *)
      usage_error "Unknown network '$1'. Use mainnet or testnet."
      ;;
  esac
  NETWORK="$1"
}

# ─── Small validators and arithmetic ──────────────────────────────────────

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
lower() { printf '%s' "${1,,}"; }

# Plain http is only accepted for a local endpoint (a test mock or a local
# node). Anything leaving the machine must be https.
require_safe_url() {
  case "$1" in
    https://*) ;;
    http://127.0.0.1:*|http://127.0.0.1/*|http://localhost:*|http://localhost/*) ;;
    *) usage_error "$2 must be an https:// URL (plain http is only allowed for localhost): $1" ;;
  esac
  [[ "$1" != *[[:space:]]* ]] || usage_error "$2 contains whitespace: $1"
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

# wei_times W N: W * N. Exact in shell arithmetic while W has at most 16
# digits (any realistic check-in cost); beyond that an approximation is fine
# because the result is only ever displayed.
wei_times() {
  local w
  w=$(strip_zeros "$1")
  if (( ${#w} <= 16 )); then
    printf '%s' "$(( w * $2 ))"
  else
    awk -v w="$w" -v n="$2" 'BEGIN { printf "%.0f", w * n }'
  fi
}

# Approximate whole check-ins a balance pays for. Display only.
checkins_left() {
  awk -v b="$1" -v c="$2" 'BEGIN { if (c > 0) printf "%d", b / c; else printf "unlimited at the current fee of 0" }'
}

# ─── Invocation hints ──────────────────────────────────────────────────────

RUNNING_FILE=""

detect_running_file() {
  local src="${BASH_SOURCE[0]:-}"
  if [[ -n "$src" && -f "$src" ]]; then
    RUNNING_FILE="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
  fi
}

# How the user should run a later command, given how this run was started.
cmd_hint() {
  if [[ -x "$SELF_PATH" ]]; then
    printf 'sudo salvorias-selfhost %s' "$1"
  elif [[ -n "$RUNNING_FILE" ]]; then
    printf 'sudo bash %s %s' "$RUNNING_FILE" "$1"
  else
    printf 'curl -fsSL https://github.com/%s/releases/latest/download/install.sh | sudo bash -s -- %s' "$SALVORIAS_RELEASE_REPO" "$1"
  fi
}

# ─── Cleanup and signals ───────────────────────────────────────────────────

TMP_DIR=""
INTERRUPT_HINT=""

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi
}

on_signal() {
  printf '\n\nInterrupted.\n' >&2
  if [[ -n "$INTERRUPT_HINT" ]]; then printf '%s\n' "$INTERRUPT_HINT" >&2; fi
  exit 130
}

make_tmp_dir() {
  if [[ -z "$TMP_DIR" ]]; then
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/salvorias-install.XXXXXX")
  fi
}

# ─── Preflight ─────────────────────────────────────────────────────────────

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    printf 'ERROR: This needs root. Rerun it with sudo, for example:\n  %s\n' "$(cmd_hint "${COMMAND}")" >&2
    exit "$EXIT_ERROR"
  fi
}

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
  for tool in curl sha256sum systemctl journalctl useradd install awk sed grep mktemp timeout; do
    command -v "$tool" >/dev/null 2>&1 || die "Required command '$tool' was not found. Install it, then rerun."
  done
}

# Confirms outbound HTTPS to the RPC works and that it serves the expected
# chain, before anything is downloaded or written.
check_rpc() {
  local body hex rc=0
  require_safe_url "$RPC_URL" "--rpc-url"
  body=$(curl -fsS --max-time 20 -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$RPC_URL" 2>&1) || rc=$?
  if (( rc == 22 )); then
    # Reached the server, which answered with an HTTP error: not a firewall issue.
    die "The Salvorias RPC at $RPC_URL answered with an error ($body). It may be down for maintenance; try again later."
  elif (( rc != 0 )); then
    die "Cannot reach the Salvorias RPC at $RPC_URL ($body). Check that this server allows outbound HTTPS (port 443)."
  fi
  hex=$(printf '%s' "$body" | sed -n 's/.*"result" *: *"\(0x[0-9a-fA-F]\{1,15\}\)".*/\1/p')
  [[ -n "$hex" ]] || die "The RPC at $RPC_URL did not return a chain id. Response: ${body:0:200}"
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
  if ! curl -fsSL --retry 3 --max-time 60 -o "$TMP_DIR/checksums.txt" "$base/checksums.txt"; then
    die "Could not download $base/checksums.txt. Check the release exists (--version) and that this server can reach it."
  fi
  CHECKSUMS_FILE="$TMP_DIR/checksums.txt"
}

# download_verified ASSET DEST: downloads a release asset and checks it
# against checksums.txt. Any mismatch or missing entry aborts the run.
download_verified() {
  local asset="$1" dest="$2" base expected actual
  fetch_checksums
  base=$(release_base_url)
  expected=$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1; exit }' "$CHECKSUMS_FILE")
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "checksums.txt at $base has no entry for $asset. Refusing to install an unverified file."
  say "Downloading $asset ..."
  if ! curl -fsSL --retry 3 --max-time 300 -o "$dest" "$base/$asset"; then
    rm -f "$dest"
    die "Could not download $base/$asset."
  fi
  actual=$(sha256sum "$dest" | awk '{ print $1 }')
  if [[ "$(lower "$expected")" != "$(lower "$actual")" ]]; then
    rm -f "$dest"
    die "Checksum mismatch for $asset (expected $expected, got $actual). The download is corrupt or has been tampered with. Nothing was installed from it."
  fi
  say "Checksum verified: $asset"
}

# ─── Node binary ───────────────────────────────────────────────────────────

STAGED_BIN=""
STAGED_VERSION=""

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
    download_verified "salvorias-node-$ASSET_ARCH" "$STAGED_BIN"
    chmod 0755 "$STAGED_BIN"
  fi

  local out rc=0
  out=$("$STAGED_BIN" version </dev/null 2>&1) || rc=$?
  if (( rc != 0 )); then
    die "The node binary does not run on this server (exit $rc: ${out:0:200}). Check it matches this CPU ($ASSET_ARCH). If ${TMPDIR:-/tmp} is mounted noexec, rerun with TMPDIR set to a directory that allows execution."
  fi
  STAGED_VERSION=$(printf '%s\n' "$out" | sed -n 's/^salvorias-node v\([0-9A-Za-z._+-]\{1,64\}\)$/\1/p' | head -n 1)
  [[ -n "$STAGED_VERSION" ]] || die "Unexpected output from 'salvorias-node version': ${out:0:200}"
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
  ln -sfn "$1" "$BIN_ROOT/.current.new"
  mv -Tf "$BIN_ROOT/.current.new" "$CURRENT_LINK"
  ln -sfn "$CURRENT_LINK/salvorias-node" "$PATH_LINK"
}

current_version_name() {
  readlink "$CURRENT_LINK" 2>/dev/null || true
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
      warn "Could not fetch a verified install.sh for $SELF_PATH ($(tr '\n' ' ' <"$TMP_DIR/self.err" | cut -c1-200)). Later commands: download install.sh and run it with sudo bash."
      return 0
    fi
  else
    return 0
  fi

  if [[ "$(sed -n 2p "$src")" != "$SELF_MARKER" ]] || ! bash -n "$src" 2>/dev/null; then
    warn "$src does not look like this installer; not installing it as $SELF_PATH."
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

# ─── slot-info ─────────────────────────────────────────────────────────────

SLOT_JSON=""

# run_slot_info BIN [NODE]: read-only chain query. Sets SLOT_JSON and
# returns the binary's exit code (0 ok, 1 RPC error, 2 bad input).
run_slot_info() {
  local bin="$1" node="${2:-}" rc=0
  local args=(slot-info --rpc-url "$RPC_URL" --contract "$NET_CHECKIN" --owner "$OWNER")
  if [[ -n "$node" ]]; then args+=(--node "$node"); fi
  SLOT_JSON=$(timeout 120 "$bin" "${args[@]}" </dev/null 2>/dev/null) || rc=$?
  return "$rc"
}

# slot-info prints one flat JSON object (JSON.stringify of known fields), so
# these extractors cover it without adding a jq dependency.
json_str() { printf '%s' "$SLOT_JSON" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
json_raw() { printf '%s' "$SLOT_JSON" | sed -n "s/.*\"$1\":\([^,}\"]*\).*/\1/p"; }
json_list() { printf '%s' "$SLOT_JSON" | sed -n "s/.*\"$1\":\[\([^]]*\)\].*/\1/p"; }

# Runs slot-info and stops with a clear message on failure.
query_chain() {
  local rc=0
  run_slot_info "$1" "${2:-}" || rc=$?
  case "$rc" in
    0) ;;
    2) usage_error "The chain query rejected the input: $(json_str error)" ;;
    *) die "Could not read the chain at $RPC_URL: $(json_str error). Try again in a few minutes." ;;
  esac
  local chain
  chain=$(json_raw chainId)
  [[ "$chain" == "$NET_CHAIN_ID" ]] || die "Chain query answered from chain '$chain', expected $NET_CHAIN_ID."
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

write_state() {
  local tmp
  tmp=$(mktemp "$ETC_DIR/.selfhost.conf.XXXXXX")
  cat >"$tmp" <<EOF
# Written by the Salvorias self-host installer. The node daemon does not read
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
  is_address "$owner" || die "$STATE_FILE has no valid OWNER_ADDRESS."
  is_address "$node" || die "$STATE_FILE has no valid NODE_ADDRESS."
  OWNER="$owner"
  NODE_ADDRESS="$node"
}

# ─── One node per server ───────────────────────────────────────────────────

guard_single_node() {
  if [[ -f "$STATE_FILE" ]] && grep -q '^STAGE=awaiting-registration$' "$STATE_FILE"; then
    printf 'ERROR: An install on this server is already waiting for the node to be registered.\n' >&2
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

ensure_user() {
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    local nologin
    nologin=$(command -v nologin || printf '/usr/sbin/nologin')
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell "$nologin" "$SERVICE_USER"
    say "Created system user: $SERVICE_USER"
  fi
}

make_dirs() {
  install -d -m 0755 -o root -g root "$OPT_DIR" "$BIN_ROOT"
  install -d -m 0750 -o root -g "$SERVICE_USER" "$ETC_DIR"
  install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DATA_DIR"
  # install -d does not always reset an existing directory, so pin it.
  chown "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
  chmod 0700 "$DATA_DIR"
}

# ─── Node key ──────────────────────────────────────────────────────────────

NODE_ADDRESS=""
KEY_SOURCE=""   # generated, imported, reused

# derive_address BIN KEYFILE: sets DERIVED_ADDRESS to the key's address.
# The binary has no single-purpose "address of this key file" command, so this
# uses `list`, which derives each address locally and makes only read calls.
# `list` never prints keys (a bad row prints "(invalid key)"), and it reads the
# file named by KEYS_FILE (its --keys-file flag sets a different variable).
DERIVED_ADDRESS=""
derive_address() {
  local out
  DERIVED_ADDRESS=""
  out=$(KEYS_FILE="$2" RPC_URL="$RPC_URL" CHECKIN_CONTRACT="$NET_CHECKIN" NFT_CONTRACT="$NET_NFT" \
    TREASURY_CONTRACT="$NET_TREASURY" timeout 120 "$1" list </dev/null 2>/dev/null) || return 1
  DERIVED_ADDRESS=$(printf '%s\n' "$out" | grep -E '^ *1 +0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}' | head -n 1 || true)
  is_address "$DERIVED_ADDRESS"
}

# Checks an --import-key file without ever printing its contents.
validate_import_file() {
  local f="$1" mode size line
  [[ -f "$f" ]] || usage_error "--import-key file not found (or not a regular file): $f"
  [[ "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" != "$KEY_FILE" ]] || usage_error "--import-key cannot be the installed key file itself."
  mode=$(stat -L -c '%a' "$f")
  if (( (8#$mode & 8#044) != 0 )); then
    usage_error "--import-key file $f is readable by other users (mode $mode). A node key must be private: run 'sudo chmod 600 $f' and try again."
  fi
  size=$(stat -L -c '%s' "$f")
  (( size >= 64 && size <= 67 )) || usage_error "--import-key file must contain exactly one node key (64 hex characters, optional 0x, optional trailing newline). Nothing else is allowed."
  line=""
  IFS= read -r line <"$f" || true
  # Exactly one key: the line plus at most one newline accounts for every byte.
  if [[ ! "$line" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] || (( size != ${#line} && size != ${#line} + 1 )); then
    line=""
    usage_error "--import-key file must contain exactly one node key (64 hex characters, optional 0x, optional trailing newline). Nothing else is allowed."
  fi
  line=""
}

# Writes the imported key, normalised to one 0x-prefixed line, as the
# salvorias user's 0600 key file. noclobber makes the write fail rather than
# replace a file that appeared in the meantime.
install_imported_key() {
  local line
  IFS= read -r line <"$1" || true
  line="${line#0x}"
  ( umask 077; set -o noclobber; printf '0x%s\n' "${line,,}" >"$KEY_FILE" ) || { line=""; die "Could not write $KEY_FILE."; }
  line=""
  chown "$SERVICE_USER:$SERVICE_USER" "$KEY_FILE"
  chmod 0600 "$KEY_FILE"
}

write_address_file() {
  printf '%s\n' "$NODE_ADDRESS" >"$ADDRESS_FILE"
  chown "$SERVICE_USER:$SERVICE_USER" "$ADDRESS_FILE"
  chmod 0644 "$ADDRESS_FILE"
}

# Works out which key this install will use, and its address, before anything
# is installed: an imported key, a key kept by an earlier uninstall, or (if
# neither) a key generated later by ensure_node_key.
plan_node_key() {
  if [[ -n "$OPT_IMPORT_KEY" ]]; then
    validate_import_file "$OPT_IMPORT_KEY"
    if [[ -e "$KEY_FILE" ]] && ! cmp -s "$OPT_IMPORT_KEY" "$KEY_FILE"; then
      die "A different node key already exists at $KEY_FILE (kept by an earlier uninstall). Back it up with care, then remove it with '$(cmd_hint 'uninstall --purge-key')' before importing another key."
    fi
    derive_address "$STAGED_BIN" "$OPT_IMPORT_KEY" || die "Could not read the node address from the --import-key file. Check the file and the RPC, then try again."
    NODE_ADDRESS="$DERIVED_ADDRESS"
    KEY_SOURCE="imported"
    say "Imported key belongs to node $NODE_ADDRESS"
  elif [[ -e "$KEY_FILE" ]]; then
    local kept=""
    if [[ -f "$ADDRESS_FILE" ]]; then kept=$(head -n 1 "$ADDRESS_FILE"); fi
    is_address "$kept" || die "A node key exists at $KEY_FILE but its address record ($ADDRESS_FILE) is missing. Move the key somewhere safe (or use --import-key with it), then rerun."
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
      local addr rc=0
      addr=$("$PATH_LINK" keygen --out "$KEY_FILE" </dev/null) || rc=$?
      (( rc == 0 )) || die "Node key generation failed (exit $rc)."
      chown "$SERVICE_USER:$SERVICE_USER" "$KEY_FILE"
      chmod 0600 "$KEY_FILE"
      is_address "$addr" || die "keygen returned an unexpected address."
      NODE_ADDRESS="$addr"
      write_address_file
      say "Generated a new node key on this server: $KEY_FILE"
      ;;
    imported)
      if [[ ! -e "$KEY_FILE" ]]; then install_imported_key "$OPT_IMPORT_KEY"; fi
      write_address_file
      say "Installed the imported node key: $KEY_FILE"
      ;;
    reused)
      chown "$SERVICE_USER:$SERVICE_USER" "$KEY_FILE"
      chmod 0600 "$KEY_FILE"
      ;;
  esac
}

# ─── Registration and funding ──────────────────────────────────────────────

# Sets BOUND_STATE (unbound, owner, other) and BOUND_SLOT from SLOT_JSON.
BOUND_STATE=""
BOUND_SLOT=""
BOUND_OTHER=""
read_binding() {
  local bound
  bound=$(json_str boundOwner)
  BOUND_SLOT=$(json_raw boundSlot)
  if [[ -z "$bound" ]]; then
    BOUND_STATE="unbound"
  elif [[ "$(lower "$bound")" == "$(lower "$OWNER")" ]]; then
    BOUND_STATE="owner"
  else
    BOUND_STATE="other"
    BOUND_OTHER="$bound"
  fi
}

# Prints the funding lines from a slot-info --node result.
print_funding() {
  local cost balance gas_limit cap_cost
  cost=$(json_str estimatedCheckInCostWei)
  balance=$(json_str nodeBalanceWei)
  gas_limit=$(json_raw checkInGasLimit)
  is_uint "$cost" || cost=0
  is_uint "$balance" || balance=0
  is_uint "$gas_limit" || gas_limit=100000
  cap_cost=$(( gas_limit * MAX_GAS_PRICE_GWEI * 1000000000 ))

  say "   Send SAVDR to the NODE address above (not to your license wallet)."
  say "   The node pays the network fee for each daily check-in."
  if [[ "$(strip_zeros "$cost")" == "0" ]]; then
    say "   The network fee is 0 right now, so check-ins cost nothing today."
    say "   Fees can rise (this node pays at most $(wei_to_savdr "$cap_cost") SAVDR per check-in),"
    say "   so keep some SAVDR on the node."
  else
    say "   One check-in costs about $(wei_to_savdr "$cost") SAVDR at today's fee"
    say "   (at most $(wei_to_savdr "$cap_cost") SAVDR at the $MAX_GAS_PRICE_GWEI gwei cap)."
    say "   Suggested: at least $(wei_to_savdr "$(wei_times "$cost" "$DAYS_TO_FUND")") SAVDR for about $DAYS_TO_FUND days of daily check-ins."
  fi
  say "   Current node balance: $(wei_to_savdr "$balance") SAVDR"
}

print_registration_box() {
  local slots="$1"
  say ""
  rule
  say " STEP 1: REGISTER THIS NODE IN THE SALVORIAS APP"
  rule
  say ""
  say "   Node address:"
  say ""
  say "     $NODE_ADDRESS"
  say ""
  say "   Free slot(s) on your license: ${slots//,/, }"
  say ""
  say "   Open the Salvorias app > Licenses > Self Setup, paste this node"
  say "   address, choose a free slot, confirm with your passcode."
  say ""
  rule
  say " STEP 2: FUND THE NODE"
  rule
  print_funding
  rule
  say ""
}

# Polls until the node is bound to the owner. Ctrl-C or a timeout leaves the
# install resumable: the key and state file are already written.
wait_for_binding() {
  local minutes="$1" deadline now rc
  deadline=$(( $(date +%s) + minutes * 60 ))
  INTERRUPT_HINT="Your node key is saved. Once the node is registered in the app, continue with:
  $(cmd_hint resume)"
  say "Waiting for the registration to appear on-chain (checking every ${SALVORIAS_POLL_SECONDS}s, up to $minutes min)."
  say "You can press Ctrl-C and continue later with: $(cmd_hint resume)"
  while :; do
    rc=0
    run_slot_info "$PATH_LINK" "$NODE_ADDRESS" || rc=$?
    if (( rc == 0 )); then
      read_binding
      case "$BOUND_STATE" in
        owner)
          say "Registered: node $NODE_ADDRESS is bound to $OWNER (slot $BOUND_SLOT)."
          INTERRUPT_HINT=""
          return 0
          ;;
        other)
          die "Node $NODE_ADDRESS was registered to a different wallet ($BOUND_OTHER), not $OWNER. Clear that slot in the app for wallet $BOUND_OTHER, then run: $(cmd_hint uninstall) and install again with the right owner."
          ;;
      esac
      say "  $(date +%H:%M:%S)  not registered yet"
    else
      say "  $(date +%H:%M:%S)  could not read the chain ($(json_str error)); will retry"
    fi
    now=$(date +%s)
    if (( now >= deadline )); then
      INTERRUPT_HINT=""
      stop "The node was not registered within $minutes minutes. Your node key is saved. Register it in the app (Licenses > Self Setup, node address $NODE_ADDRESS), then run: $(cmd_hint resume)"
    fi
    sleep "$SALVORIAS_POLL_SECONDS"
  done
}

# ─── Service ───────────────────────────────────────────────────────────────

write_env_file() {
  local tmp
  tmp=$(mktemp "$ETC_DIR/.node.env.XXXXXX")
  cat >"$tmp" <<EOF
# Salvorias node daemon settings, written by the self-host installer.
# Restart after editing: sudo systemctl restart salvorias-node
CHECKIN_CONTRACT=$NET_CHECKIN
RPC_URL=$RPC_URL
TREASURY_CONTRACT=$NET_TREASURY
EXPECTED_CHAIN_ID=$NET_CHAIN_ID
NODE_KEYS_FILE=$KEY_FILE
# Self-hosted node wallets are not fee-exempt: pay the live network fee,
# never more than MAX_GAS_PRICE_GWEI per unit of gas.
GAS_PRICE_MODE=$GAS_PRICE_MODE
MAX_GAS_PRICE_GWEI=$MAX_GAS_PRICE_GWEI
EOF
  chown root:"$SERVICE_USER" "$tmp"
  chmod 0640 "$tmp"
  mv -f "$tmp" "$ENV_FILE"
}

write_unit_file() {
  local tmp
  tmp=$(mktemp "/etc/systemd/system/.salvorias-node.service.XXXXXX")
  cat >"$tmp" <<EOF
# Installed by the Salvorias self-host installer.
[Unit]
Description=Salvorias check-in node (self-hosted)
Documentation=https://github.com/$SALVORIAS_RELEASE_REPO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
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
ReadWritePaths=$DATA_DIR
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
  mv -f "$tmp" "$UNIT_FILE"
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

show_journal() {
  journalctl -u "$UNIT_NAME" -n "${1:-20}" --no-pager 2>/dev/null || say "(no journal entries)"
}

# ─── install ───────────────────────────────────────────────────────────────

cmd_install() {
  require_root
  check_platform
  ensure_tools
  guard_single_node

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
  local nft licenses slots
  nft=$(json_str nftContract)
  if [[ "$(lower "$nft")" != "$(lower "$NET_NFT")" ]]; then
    die "NodeCheckIn on $NETWORK counts licenses on NFT contract $nft, but this installer expects $NET_NFT. Refusing to continue: the installer may be out of date."
  fi
  licenses=$(json_raw licenseBalance)
  slots=$(json_list openSlots)
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
  if [[ "$BOUND_STATE" == "owner" ]]; then
    say "Node $NODE_ADDRESS is already registered to this wallet (slot $BOUND_SLOT); no new registration needed."
  elif [[ -z "$slots" ]]; then
    stop "All $licenses license slot(s) for $OWNER are already in use (for example by Save Hosting). Self-hosting only uses a FREE slot. Free one in the app (Licenses), then run this again. Nothing was installed."
  else
    say "Free slot(s): ${slots//,/, }"
  fi

  # The funding box and the registration wait both depend on slot-info
  # --node. For a new key, prove that query works on this network before
  # anything is written, using an address that can never be a node.
  if [[ -z "$NODE_ADDRESS" ]]; then
    local rc=0
    run_slot_info "$STAGED_BIN" "$PROBE_NODE_ADDRESS" || rc=$?
    if (( rc != 0 )); then
      die "Could not read node registration data from NodeCheckIn on $NETWORK ($(json_str error)). This must work to detect your registration. Nothing was installed. If this persists, report it with your network name."
    fi
  fi

  banner "Setting up this server"
  ensure_user
  make_dirs
  place_binary
  switch_current "$PLACED_NAME"
  say "Installed salvorias-node $STAGED_VERSION at $BIN_ROOT/$PLACED_NAME (linked from $PATH_LINK)"
  ensure_node_key
  write_state awaiting-registration
  install_self_copy

  if [[ "$BOUND_STATE" != "owner" ]]; then
    query_chain "$PATH_LINK" "$NODE_ADDRESS"
    read_binding
  fi
  if [[ "$BOUND_STATE" == "owner" ]]; then
    say ""
    rule
    say " FUND THE NODE"
    rule
    say "   Node address: $NODE_ADDRESS"
    print_funding
    rule
  else
    print_registration_box "$slots"
    wait_for_binding "$OPT_WAIT_MINUTES"
  fi
  finalize_install
}

finalize_install() {
  banner "Starting the node service"
  write_env_file
  write_unit_file
  systemctl daemon-reload
  systemctl enable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  write_state installed

  local healthy=1
  service_stays_up 10 || healthy=0

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
  say "  Slot:      ${BOUND_SLOT:-unknown}"
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
  if is_uint "$balance" && is_uint "$cost" && wei_lt "$balance" "$cost"; then
    say ""
    warn "The node balance is below the cost of one check-in ($(wei_to_savdr "$cost") SAVDR). It cannot check in until you send SAVDR to $NODE_ADDRESS."
  fi
  say ""
  say "Next:"
  say "  sudo salvorias-selfhost status       service, binding, balance, recent logs"
  say "  sudo salvorias-selfhost backup-key   copy the node key for offline storage (do this now)"
  say "  sudo salvorias-selfhost upgrade      install a newer node release"
  say "  sudo salvorias-selfhost uninstall    remove the node from this server"
  say "  sudo journalctl -u salvorias-node -f follow the node's log"
  if [[ ! -x "$SELF_PATH" ]]; then
    say "  ($SELF_PATH could not be installed; use instead: $(cmd_hint '<command>'))"
  fi

  if (( healthy == 0 )); then
    say ""
    say "Recent log:"
    show_journal 20
    die "The node service is not staying up. Read the log above, then check: $(cmd_hint status)"
  fi
}

# ─── resume ────────────────────────────────────────────────────────────────

cmd_resume() {
  require_root
  check_platform
  ensure_tools
  load_state
  if [[ "$ST_STAGE" == "installed" ]]; then
    say "This node is already installed and running. Check it with: $(cmd_hint status)"
    return 0
  fi
  [[ "$ST_STAGE" == "awaiting-registration" ]] || die "Unknown install stage '$ST_STAGE' in $STATE_FILE."
  [[ -f "$KEY_FILE" ]] || die "The node key $KEY_FILE is missing, so this install cannot continue. Start over: $(cmd_hint uninstall), then install again."
  [[ -x "$PATH_LINK" ]] || die "The node binary $PATH_LINK is missing. Start over: $(cmd_hint uninstall), then install again."
  if [[ ! -x "$SELF_PATH" || -n "$OPT_SELF" ]]; then install_self_copy; fi

  banner "Resuming the Salvorias node install"
  say "Network: $NETWORK (chain $NET_CHAIN_ID)"
  check_rpc
  query_chain "$PATH_LINK" "$NODE_ADDRESS"
  read_binding
  if [[ "$BOUND_STATE" != "owner" ]]; then
    print_registration_box "$(json_list openSlots)"
    wait_for_binding "$OPT_WAIT_MINUTES"
  fi
  finalize_install
}

# ─── status ────────────────────────────────────────────────────────────────

cmd_status() {
  require_root
  load_state
  banner "Salvorias node status"
  say "  Network:   $NETWORK (chain $NET_CHAIN_ID, $RPC_URL)"
  say "  Install:   $ST_STAGE"
  say "  Service:   $(systemctl is-active "$UNIT_NAME" 2>/dev/null || true), $(systemctl is-enabled "$UNIT_NAME" 2>/dev/null || printf 'not installed') at boot"
  say "  Version:   $("$PATH_LINK" version </dev/null 2>/dev/null || printf 'binary missing') ($(current_version_name))"
  say "  Node:      $NODE_ADDRESS"
  say "  Owner:     $OWNER"

  if run_slot_info "$PATH_LINK" "$NODE_ADDRESS"; then
    read_binding
    case "$BOUND_STATE" in
      owner) say "  Binding:   registered to the owner, slot $BOUND_SLOT" ;;
      other) say "  Binding:   REGISTERED TO A DIFFERENT WALLET ($BOUND_OTHER)" ;;
      *) say "  Binding:   NOT REGISTERED (app > Licenses > Self Setup, paste the node address)" ;;
    esac
    local balance cost
    balance=$(json_str nodeBalanceWei)
    cost=$(json_str estimatedCheckInCostWei)
    if is_uint "$balance" && is_uint "$cost"; then
      say "  Balance:   $(wei_to_savdr "$balance") SAVDR"
      say "  Per check-in: about $(wei_to_savdr "$cost") SAVDR at today's fee"
      say "  Check-ins left: about $(checkins_left "$balance" "$cost")"
      if wei_lt "$balance" "$cost"; then
        warn "Balance is below one check-in. Send SAVDR to $NODE_ADDRESS."
      fi
    fi
  else
    say "  Chain:     could not read the chain ($(json_str error))"
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

  banner "Upgrading the Salvorias node"
  stage_binary
  local previous
  previous=$(current_version_name)
  if [[ -n "$previous" && -f "$BIN_ROOT/$previous/salvorias-node" ]] \
      && [[ "$(file_sha "$STAGED_BIN")" == "$(file_sha "$BIN_ROOT/$previous/salvorias-node")" ]]; then
    install_self_copy
    say "Already running this binary ($previous). Nothing to do."
    return 0
  fi

  place_binary
  say "Switching from ${previous:-none} to $PLACED_NAME and restarting..."
  switch_current "$PLACED_NAME"
  systemctl restart "$UNIT_NAME" || true

  if service_stays_up "$SALVORIAS_UPGRADE_WATCH_SECONDS"; then
    say "The service stayed up for ${SALVORIAS_UPGRADE_WATCH_SECONDS}s on $PLACED_NAME."
    prune_versions "$PLACED_NAME" "$previous"
    install_self_copy
    banner "Upgrade complete: $PLACED_NAME"
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
  switch_current "$previous"
  systemctl restart "$UNIT_NAME" || true
  if (( PLACED_EXISTED == 0 )); then rm -rf "${BIN_ROOT:?}/$PLACED_NAME"; fi
  if service_stays_up 10; then
    die "Upgrade to $PLACED_NAME failed: the service did not stay up. Rolled back to $previous, which is running again."
  fi
  die "Upgrade to $PLACED_NAME failed and $previous is not staying up either. Check: $(cmd_hint status)"
}

# Keeps the current and previous version directories, removes the rest.
prune_versions() {
  local dir name
  for dir in "$BIN_ROOT"/*; do
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    name=$(basename "$dir")
    if [[ "$name" != "$1" && "$name" != "$2" ]]; then
      rm -rf "${BIN_ROOT:?}/$name"
    fi
  done
}

# ─── backup-key ────────────────────────────────────────────────────────────

cmd_backup_key() {
  require_root
  [[ -f "$KEY_FILE" ]] || die "No node key found at $KEY_FILE."
  local out="${OPT_OUT:-/root/salvorias-node-key-backup-$(date +%Y%m%d-%H%M%S).txt}"
  [[ ! -e "$out" ]] || die "$out already exists. Choose another path with --out."
  [[ -d "$(dirname "$out")" ]] || die "Directory $(dirname "$out") does not exist."
  ( umask 077; set -o noclobber; cat -- "$KEY_FILE" >"$out" ) || die "Could not write $out."
  chown root:root "$out"
  chmod 0600 "$out"
  local addr=""
  if [[ -f "$ADDRESS_FILE" ]]; then addr=$(head -n 1 "$ADDRESS_FILE"); fi

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
  if [[ -f "$ADDRESS_FILE" ]]; then addr=$(head -n 1 "$ADDRESS_FILE"); fi
  if [[ -f "$STATE_FILE" ]]; then
    local recorded
    recorded=$(sed -n 's/^NODE_ADDRESS=//p' "$STATE_FILE" | head -n 1)
    if is_address "$recorded"; then addr="$recorded"; fi
  fi
  if [[ ! -e "$STATE_FILE" && ! -e "$ENV_FILE" && ! -e "$UNIT_FILE" && ! -e "$OPT_DIR" && ! -e "$KEY_FILE" && ! -e "$SELF_PATH" ]]; then
    say "Nothing to uninstall: no Salvorias self-host node found on this server."
    return 0
  fi

  banner "Uninstall the Salvorias node"
  say "This removes: the $UNIT_NAME service, $OPT_DIR, $PATH_LINK, $ETC_DIR and $SELF_PATH."
  if (( OPT_PURGE_KEY == 1 )); then
    say "It also DELETES the node key $KEY_FILE (--purge-key)."
  else
    say "It keeps the node key $KEY_FILE (a later install reuses it)."
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

  if [[ -f "$UNIT_FILE" ]]; then
    systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
    systemctl reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true
    say "Removed the service."
  fi
  if [[ -L "$PATH_LINK" ]]; then rm -f "$PATH_LINK"; fi
  rm -rf "$OPT_DIR" "$ETC_DIR"
  say "Removed $OPT_DIR, $PATH_LINK and $ETC_DIR."

  if (( OPT_PURGE_KEY == 1 )); then
    if [[ -e "$KEY_FILE" ]]; then
      shred -u "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"
    fi
    rm -rf "$DATA_DIR"
    if id -u "$SERVICE_USER" >/dev/null 2>&1; then userdel "$SERVICE_USER" >/dev/null 2>&1 || true; fi
    say "Deleted the node key, $DATA_DIR and the $SERVICE_USER user."
  elif [[ -e "$KEY_FILE" ]]; then
    say "Kept the node key at $KEY_FILE (and the $SERVICE_USER user that owns it)."
  fi

  say ""
  if [[ -n "$addr" ]]; then
    say "If node $addr was registered to a license slot, that slot still points at it on-chain."
  else
    say "If the node was registered to a license slot, that slot still points at it on-chain."
  fi
  say "To use the slot for another node, clear it in the Salvorias app (Licenses)."

  # Last, so the steps above can still be retried with it if anything failed.
  if [[ -e "$SELF_PATH" ]]; then
    rm -f "$SELF_PATH"
    say "Removed $SELF_PATH."
  fi
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
    upgrade) allowed=" --binary --version --self " ;;
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
  if ! is_uint "$OPT_WAIT_MINUTES" || (( OPT_WAIT_MINUTES < 1 )); then
    usage_error "--wait-minutes must be a whole number of minutes (1 or more)."
  fi
  if ! is_uint "$SALVORIAS_POLL_SECONDS" || (( SALVORIAS_POLL_SECONDS < 1 )); then
    usage_error "SALVORIAS_POLL_SECONDS must be a whole number of seconds (1 or more)."
  fi
  is_uint "$SALVORIAS_UPGRADE_WATCH_SECONDS" || usage_error "SALVORIAS_UPGRADE_WATCH_SECONDS must be a whole number of seconds."
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
  trap on_signal INT TERM
  parse_args "$@"
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
