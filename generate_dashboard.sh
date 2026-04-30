#!/bin/bash
# =============================================================================
# Per-player dashboard JSON files. Thin wrapper around the python builder.
#
# The original implementation was 656 lines of bash with nested jq calls;
# it took 9-24 minutes per run. The python rewrite (lib/dashboard.py) does
# the same work in ~2 seconds. This wrapper exists for backwards-compat
# with the cron + start.sh callers.
#
# Usage:
#   ./generate_dashboard.sh                    # default save dir
#   ./generate_dashboard.sh /path/to/saves     # custom save directory
#   ./generate_dashboard.sh --rebuild          # accepted but ignored
#                                              # (always full rebuild now —
#                                              # it's fast enough)
# =============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib_log.sh"
_dash_started=$(date +%s)
plog dashboard "BEGIN run args=$* (pid=$$)"
trap '_rc=$?; plog dashboard "END run rc=${_rc} ($(( $(date +%s) - _dash_started ))s)"' EXIT

SAVE_DIR="/data/saves"
for arg in "$@"; do
  case "$arg" in
    --rebuild) ;;  # no-op — always a full rebuild now
    *) SAVE_DIR="$arg" ;;
  esac
done

PYTHON=$(command -v python3)
if [ -z "$PYTHON" ]; then
  echo "[dashboard] python3 not found in PATH" >&2
  exit 1
fi

exec "$PYTHON" "$SCRIPT_DIR/python/bin/build_dashboards.py" --save-dir "$SAVE_DIR"
