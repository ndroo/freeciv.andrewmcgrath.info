#!/bin/bash
# Shared timestamped logging helper for the turn-change pipeline.
#
# We had a report that on turn change the countdown timer sticks at 0:00 and
# the Chronicle takes hours to update. The existing per-script logs lack
# timestamps and don't share a single timeline, so reconstructing what
# actually happened is painful. This helper writes every pipeline event to
# one file with ISO-8601 (UTC, ms) prefixes so we can replay a transition.
#
# Source this from any script that participates in turn handling, then:
#
#   plog turn-watcher "detected save for turn 53"
#   started=$(plog_begin gazette "process turn 52")
#   ... do work ...
#   plog_end gazette "process turn 52" "$started"
#
# Output format (one line per event):
#   2026-04-29T12:34:56.789Z [stage] message

TURN_PIPELINE_LOG="${TURN_PIPELINE_LOG:-/data/saves/turn-pipeline.log}"

plog() {
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null)
  # BSD date (macOS) leaves "%3N" literal — fall back to seconds-only.
  case "$ts" in *3N*) ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) ;; esac
  printf '%s [%s] %s\n' "$ts" "$1" "$2" >> "$TURN_PIPELINE_LOG" 2>/dev/null || true
}

# Log a BEGIN event and echo the start epoch (seconds) on stdout. Capture it
# with: started=$(plog_begin stage "msg")
plog_begin() {
  plog "$1" "BEGIN $2"
  date +%s
}

# Pair with plog_begin: writes END line including elapsed seconds.
plog_end() {
  local stage="$1" msg="$2" started="$3"
  local now elapsed
  now=$(date +%s)
  elapsed=$((now - started))
  plog "$stage" "END $msg (${elapsed}s)"
}
