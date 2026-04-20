#!/bin/bash
# =============================================================================
# Local preview: generate status page from test data and serve it
#
# Usage:
#   ./local_preview.sh              # use test_data/
#   ./local_preview.sh --pull       # pull latest saves from prod first
#   ./local_preview.sh --port 9090  # custom port (default 8080)
#
# Opens http://localhost:8080 with the full status page rendered from real data.
# =============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=8080
PULL=false

for arg in "$@"; do
  case "$arg" in
    --pull) PULL=true ;;
    --port) shift; PORT="${1:-8080}" ;;
    --port=*) PORT="${arg#--port=}" ;;
  esac
done

# Setup temp environment
PREVIEW_DIR=$(mktemp -d /tmp/freeciv-preview-XXXXXX)
trap "rm -rf $PREVIEW_DIR" EXIT

SAVE_DIR="$PREVIEW_DIR/saves"
WEBROOT="$PREVIEW_DIR/www"
DB_PATH="$PREVIEW_DIR/freeciv.sqlite"
LOGFILE="$PREVIEW_DIR/server.log"

mkdir -p "$SAVE_DIR" "$WEBROOT"

# Pull fresh saves from prod if requested
if [ "$PULL" = "true" ]; then
  echo "Pulling save files from prod..."
  REMOTE_FILES=$(fly ssh console --app freeciv-longturn -C "sh -c 'ls /data/saves/lt-game-*.sav.gz'" 2>/dev/null | grep -v '^Connecting' | tr -d '\r')
  for f in $REMOTE_FILES; do
    fname=$(basename "$f")
    echo "  $fname"
    fly ssh console --app freeciv-longturn -C "sh -c 'cat $f'" > "$SAVE_DIR/$fname" 2>/dev/null
  done
  # Pull support files
  fly ssh console --app freeciv-longturn -C "sh -c 'cat /data/saves/turn_start_epoch'" > "$SAVE_DIR/turn_start_epoch" 2>/dev/null || true
  fly ssh console --app freeciv-longturn -C "sh -c 'cat /data/saves/server.log'" > "$LOGFILE" 2>/dev/null || true
  fly ssh console --app freeciv-longturn -C "sh -c 'sqlite3 /data/saves/freeciv.sqlite .dump'" > "$PREVIEW_DIR/fcdb_dump.sql" 2>/dev/null || true
  if [ -s "$PREVIEW_DIR/fcdb_dump.sql" ]; then
    sqlite3 "$DB_PATH" < "$PREVIEW_DIR/fcdb_dump.sql"
  fi
  echo "Pulled $(ls "$SAVE_DIR"/lt-game-*.sav.gz 2>/dev/null | wc -l | tr -d ' ') save files"
else
  echo "Using test_data/ (run with --pull to fetch from prod)"
  cp "$SCRIPT_DIR/test_data"/lt-game-*.sav.gz "$SAVE_DIR/"
  cp "$SCRIPT_DIR/test_data/turn_start_epoch" "$SAVE_DIR/" 2>/dev/null || true
  cp "$SCRIPT_DIR/test_data/server.log" "$LOGFILE" 2>/dev/null || true
  if [ -f "$SCRIPT_DIR/test_data/fcdb_auth.sql" ]; then
    sqlite3 "$DB_PATH" < "$SCRIPT_DIR/test_data/fcdb_auth.sql"
  fi
fi

# Copy web assets
cp "$SCRIPT_DIR/www/"* "$WEBROOT/" 2>/dev/null || true

# Load .env if present
if [ -f "$SCRIPT_DIR/.env" ]; then
  export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi

# Generate all JSON
echo ""
echo "Generating status data..."
SAVE_DIR="$SAVE_DIR" \
  WEBROOT="$WEBROOT" \
  DB_PATH="$DB_PATH" \
  LOGFILE="$LOGFILE" \
  SERVER_HOST="freeciv.andrewmcgrath.info" \
  /opt/homebrew/bin/bash "$SCRIPT_DIR/generate_status_json.sh" --no-live --rebuild-history --rebuild-attendance 2>&1

# Generate gazette if API key available
if [ -n "${OPENAI_API_KEY:-}" ]; then
  echo ""
  echo "Generating gazette..."
  SAVE_DIR="$SAVE_DIR" \
    WEBROOT="$WEBROOT" \
    OPENAI_API_KEY="$OPENAI_API_KEY" \
    /opt/homebrew/bin/bash "$SCRIPT_DIR/generate_gazette.sh" --rebuild 2>&1
else
  echo ""
  echo "Skipping gazette (no OPENAI_API_KEY in .env)"
fi

echo ""
echo "Generated files:"
ls -la "$WEBROOT"/*.json 2>/dev/null | awk '{print "  " $NF " (" $5 " bytes)"}'
echo ""

# Serve
echo "Serving at http://localhost:$PORT"
echo "Press Ctrl+C to stop"
echo ""
cd "$WEBROOT"
python3 -m http.server "$PORT"
