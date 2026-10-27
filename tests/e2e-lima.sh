#!/usr/bin/env bash
# Runs tests/e2e-in-vm.sh inside a disposable Lima Ubuntu 24.04 VM.
#
# Usage: tests/e2e-lima.sh [--keep-vm] [--reuse-vm] [--arch aarch64|x86_64] <bin-dir>
#   <bin-dir> holds salvorias-node-linux-<arch> (the build under test),
#   next/salvorias-node-linux-<arch> (a build reporting a different version,
#   used for the upgrade test) and broken/salvorias-node-linux-<arch>
#   (tests/broken-node.js, built). See tests/README.md for how to build them.
#
# The VM is created fresh and deleted afterwards unless --keep-vm is given.
# If a VM with that name already exists the run stops: it might be someone's
# work, and the suite changes system state in it. --reuse-vm runs in the
# existing VM instead; a VM this run did not create is never deleted.
# The transcript is written to e2e-transcript.txt in the current directory.

set -euo pipefail

VM="${VM:-selfhost-test}"
TEMPLATE="${TEMPLATE:-template://ubuntu-24.04}"
KEEP_VM=0
REUSE_VM=0
CREATED_VM=0
STAGE=""
VM_ARCH=""
BIN_DIR=""

usage() {
  cat <<USAGE
Usage: $0 [--keep-vm] [--reuse-vm] [--arch aarch64|x86_64] <bin-dir>
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-vm) KEEP_VM=1 ;;
    --reuse-vm) REUSE_VM=1 ;;
    --arch) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; VM_ARCH="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) BIN_DIR="$1" ;;
  esac
  shift
done
[[ -n "$BIN_DIR" && -d "$BIN_DIR" ]] || { usage >&2; exit 2; }
command -v limactl >/dev/null 2>&1 || { echo "limactl is required (brew install lima)" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Removes the staging directory, and the VM, but only one this run created.
# shellcheck disable=SC2317,SC2329  # called via trap (0.9 says SC2317, 0.10+ SC2329)
cleanup() {
  if [[ -n "$STAGE" ]]; then rm -rf "$STAGE"; fi
  if (( CREATED_VM == 1 && KEEP_VM == 0 )); then limactl delete -f "$VM" || true; fi
}
trap cleanup EXIT

if limactl list -q 2>/dev/null | grep -qx "$VM"; then
  if (( REUSE_VM == 0 )); then
    echo "A VM named $VM already exists. This suite changes system state inside the VM, and it may not be a throwaway." >&2
    echo "Nothing was started or deleted. Delete it yourself (limactl delete -f $VM), pick another name (VM=name), or pass --reuse-vm to run in it." >&2
    exit 1
  fi
  echo "Reusing the existing VM $VM (--reuse-vm). It will not be deleted."
else
  start_args=(--name="$VM" --tty=false)
  if [[ -n "$VM_ARCH" ]]; then start_args+=(--arch "$VM_ARCH"); fi
  # Set before the start: a start that fails half-way can leave a VM behind,
  # and it is this run's to remove.
  CREATED_VM=1
  limactl start "${start_args[@]}" "$TEMPLATE"
fi

case "$(limactl shell "$VM" uname -m)" in
  x86_64) ASSET="salvorias-node-linux-x64" ;;
  aarch64) ASSET="salvorias-node-linux-arm64" ;;
  *) echo "unexpected VM architecture" >&2; exit 1 ;;
esac
for f in "$ASSET" "next/$ASSET" "broken/$ASSET"; do
  [[ -f "$BIN_DIR/$f" ]] || { echo "need $BIN_DIR/$f" >&2; exit 1; }
done

STAGE="$(mktemp -d)"
mkdir -p "$STAGE/selfhost-e2e/tests" "$STAGE/selfhost-e2e/bin/next" "$STAGE/selfhost-e2e/bin/broken"
cp "$REPO/install.sh" "$STAGE/selfhost-e2e/"
cp "$REPO/tests/e2e-in-vm.sh" "$REPO/tests/unit-math.sh" "$REPO/tests/mock-rpc.py" "$STAGE/selfhost-e2e/tests/"
cp "$BIN_DIR/$ASSET" "$STAGE/selfhost-e2e/bin/"
cp "$BIN_DIR/next/$ASSET" "$STAGE/selfhost-e2e/bin/next/"
cp "$BIN_DIR/broken/$ASSET" "$STAGE/selfhost-e2e/bin/broken/"

limactl shell "$VM" sudo rm -rf /tmp/selfhost-e2e
limactl copy -r "$STAGE/selfhost-e2e" "$VM:/tmp/selfhost-e2e"

rc=0
limactl shell "$VM" sudo bash /tmp/selfhost-e2e/tests/e2e-in-vm.sh 2>&1 | tee e2e-transcript.txt || rc=$?

exit "$rc"
