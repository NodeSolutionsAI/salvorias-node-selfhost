#!/usr/bin/env bash
# Lints every shell script in the repo. Same check as the CI workflow.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck is required" >&2; exit 1; }
shellcheck -x install.sh tests/*.sh
echo "shellcheck: clean"
