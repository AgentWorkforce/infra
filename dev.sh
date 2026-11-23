#!/usr/bin/env bash
# One local entry point; paths resolve from this file, never from $PWD.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${DEV_PYTHON:-python3}" "$ROOT/scripts/dev/dev.py" "$@"
