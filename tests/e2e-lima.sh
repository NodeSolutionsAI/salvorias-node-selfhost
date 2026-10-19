#!/usr/bin/env bash
# Runs tests/e2e-in-vm.sh inside a disposable Lima Ubuntu 24.04 VM.
#
# Usage: tests/e2e-lima.sh [--keep-vm] [--arch aarch64|x86_64] <bin-dir>
#   <bin-dir> holds salvorias-node-linux-<arch> (the build under test) and
#   next/salvorias-node-linux-<arch> (a build reporting a different version,
#   used for the upgrade test). See tests/README.md for how to build both.
#
# The VM is created fresh and deleted afterwards unless --keep-vm is given.
# The transcript is written to e2e-transcript.txt in the current directory.

set -euo pipefail

VM="${VM:-selfhost-test}"
TEMPLATE="${TEMPLATE:-template://ubuntu-24.04}"
KEEP_VM=0
VM_ARCH=""
BIN_DIR=""

usage() {
  cat <<USAGE
Usage: $0 [--keep-vm] [--arch aarch64|x86_64] <bin-dir>
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-vm) KEEP_VM=1 ;;
    --arch) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; VM_ARCH="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) BIN_DIR="$1" ;;
  esac
  shift
done
[[ -n "$BIN_DIR" && -d "$BIN_DIR" ]] || { usage >&2; exit 2; }
command -v limactl >/dev/null 2>&1 || { echo "limactl is required (brew install lima)" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! limactl list -q 2>/dev/null | grep -qx "$VM"; then
  start_args=(--name="$VM" --tty=false)
  if [[ -n "$VM_ARCH" ]]; then start_args+=(--arch "$VM_ARCH"); fi
  limactl start "${start_args[@]}" "$TEMPLATE"
fi

case "$(limactl shell "$VM" uname -m)" in
  x86_64) ASSET="salvorias-node-linux-x64" ;;
  aarch64) ASSET="salvorias-node-linux-arm64" ;;
  *) echo "unexpected VM architecture" >&2; exit 1 ;;
esac
[[ -f "$BIN_DIR/$ASSET" && -f "$BIN_DIR/next/$ASSET" ]] || { echo "need $BIN_DIR/$ASSET and $BIN_DIR/next/$ASSET" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/selfhost-e2e/tests" "$STAGE/selfhost-e2e/bin/next"
cp "$REPO/install.sh" "$STAGE/selfhost-e2e/"
cp "$REPO/tests/e2e-in-vm.sh" "$REPO/tests/unit-math.sh" "$REPO/tests/mock-rpc.py" "$STAGE/selfhost-e2e/tests/"
cp "$BIN_DIR/$ASSET" "$STAGE/selfhost-e2e/bin/"
cp "$BIN_DIR/next/$ASSET" "$STAGE/selfhost-e2e/bin/next/"

limactl shell "$VM" sudo rm -rf /tmp/selfhost-e2e
limactl copy -r "$STAGE/selfhost-e2e" "$VM:/tmp/selfhost-e2e"

rc=0
limactl shell "$VM" sudo bash /tmp/selfhost-e2e/tests/e2e-in-vm.sh 2>&1 | tee e2e-transcript.txt || rc=$?

if (( KEEP_VM == 0 )); then
  limactl delete -f "$VM"
fi
exit "$rc"
