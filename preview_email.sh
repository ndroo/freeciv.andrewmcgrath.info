#!/bin/bash
# Local preview of the email gazette block — runs the same v2 extraction
# logic as turn_notify.sh and respond_to_editor.sh against local-data/
# and writes HTML files you can open in a browser. No SMTP needed.
#
# Usage:  ./preview_email.sh
# Output: /tmp/email-turn-notify.html
#         /tmp/email-editor-context.txt
set -e

SAVE_DIR="${SAVE_DIR:-./local-data}"
SERVER_HOST="${SERVER_HOST:-freeciv.andrewmcgrath.info}"
GAZETTE_JSON="$SAVE_DIR/gazette.json"
SAVE_DIR_ABS="$(cd "$SAVE_DIR" && pwd)"

if [ ! -f "$GAZETTE_JSON" ]; then
  echo "missing $GAZETTE_JSON — run \`make pull-jsons\` or \`make pull-prod\`"
  exit 1
fi

GAZETTE_ENTRY=$(jq -r '.[-1] // empty' "$GAZETTE_JSON")
if [ -z "$GAZETTE_ENTRY" ]; then
  echo "no entries in gazette.json"
  exit 1
fi

GZ_HEADLINE=$(echo "$GAZETTE_ENTRY" | jq -r '.headline // empty')
GZ_YEAR=$(echo "$GAZETTE_ENTRY" | jq -r '.year_display // empty')
GZ_TURN=$(echo "$GAZETTE_ENTRY" | jq -r '.turn // empty')
GZ_HAS_PAGES=$(echo "$GAZETTE_ENTRY" | jq -r 'if .pages then "yes" else "no" end')

if [ "$GZ_HAS_PAGES" != "yes" ]; then
  echo "latest entry isn't v2 (no .pages) — preview script targets v2 only"
  exit 1
fi

# Same logic as turn_notify.sh's v2 path.
GZ_FRONT=$(echo "$GAZETTE_ENTRY" | jq -r '
  [.pages[].sections[] | select(.kind == "lead")] | .[0] | .content // empty')
GZ_FRONT_BY=$(echo "$GAZETTE_ENTRY" | jq -r '
  [.pages[].sections[] | select(.kind == "lead")] | .[0] | .byline // empty')
GZ_LEAD_IMG_ID=$(echo "$GAZETTE_ENTRY" | jq -r '
  [.pages[].sections[] | select(.kind == "lead")] | .[0] | .lead_image_id // empty')
GZ_IMG=""
GZ_IMG_CREDIT=""
GZ_IMG_DESC=""
GZ_IMG_DATA=""    # data: URL when local file is found — avoids file:// blocks
if [ -n "$GZ_LEAD_IMG_ID" ]; then
  GZ_IMG=$(echo "$GAZETTE_ENTRY" | jq -r --arg id "$GZ_LEAD_IMG_ID" \
    '(.images // []) | map(select(.id == $id)) | .[0].file // empty')
  GZ_IMG_CREDIT=$(echo "$GAZETTE_ENTRY" | jq -r --arg id "$GZ_LEAD_IMG_ID" \
    '(.images // []) | map(select(.id == $id)) | .[0].credit // empty')
  GZ_IMG_DESC=$(echo "$GAZETTE_ENTRY" | jq -r --arg id "$GZ_LEAD_IMG_ID" \
    '(.images // []) | map(select(.id == $id)) | .[0].caption // empty' | sed 's/<[^>]*>//g')
  if [ -n "$GZ_IMG" ] && [ -f "$SAVE_DIR_ABS/$GZ_IMG" ]; then
    # Base64 + inline as data: URL so the preview is self-contained and
    # browsers don't block cross-origin file:// images. Adds ~1MB to
    # the HTML; fine for a one-off preview.
    GZ_IMG_DATA="data:image/png;base64,$(base64 < "$SAVE_DIR_ABS/$GZ_IMG" | tr -d '\n')"
  fi
fi

OUT=/tmp/email-turn-notify.html
cat > "$OUT" <<EOF
<!DOCTYPE html>
<html><head><meta charset='utf-8'><title>Turn Notify Email Preview — Turn ${GZ_TURN}</title>
<style>body{margin:0;padding:30px;background:#f0f0f0;font-family:Helvetica,Arial,sans-serif;}
.envelope{max-width:680px;margin:0 auto;background:#fff;padding:24px;border:1px solid #ccc;}
.from{font-size:12px;color:#666;margin-bottom:14px;border-bottom:1px solid #eee;padding-bottom:10px;}
</style></head><body>
<div class='envelope'>
<div class='from'><strong>To:</strong> you@example.com<br>
<strong>From:</strong> freeciv@andrewmcgrath.info<br>
<strong>Subject:</strong> Turn ${GZ_TURN} began — ${GZ_YEAR}</div>
<div style='background:#f5f0e6;border:none;padding:0;margin:0 0 24px 0;font-family:Georgia,Times New Roman,serif;color:#1a1a1a;'>
  <div style='text-align:center;padding:20px 24px 12px;border-bottom:4px double #1a1a1a;'>
    <div style='font-size:36px;font-weight:900;color:#1a1a1a;letter-spacing:2px;font-family:Georgia,serif;line-height:1;'>The Civ Chronicle</div>
    <div style='font-size:10px;color:#666;text-transform:uppercase;letter-spacing:4px;margin-top:6px;'>All the civilization that&rsquo;s fit to print</div>
  </div>
  <div style='display:flex;justify-content:space-between;font-size:10px;color:#666;text-transform:uppercase;letter-spacing:1px;padding:6px 24px;border-bottom:1px solid #ccc;'>
    <span>Turn ${GZ_TURN}</span><span>${GZ_YEAR}</span><span>Vol. I, No. ${GZ_TURN}</span>
  </div>
  <div style='font-size:24px;font-weight:900;color:#1a1a1a;line-height:1.2;letter-spacing:-0.5px;font-family:Georgia,serif;text-align:center;padding:18px 24px 6px;'>${GZ_HEADLINE}</div>
  <div style='font-size:11px;color:#666;text-align:center;font-style:italic;padding:0 24px 14px;border-bottom:1px solid #ccc;'>${GZ_FRONT_BY}</div>
  <div style='padding:14px 24px;font-size:13px;line-height:1.7;color:#2a2a2a;text-align:justify;overflow:hidden;'>$([ -n "$GZ_IMG_DATA" ] && echo "<div style='float:right;width:180px;margin:0 0 10px 14px;'><img src='${GZ_IMG_DATA}' alt='Chronicle illustration' width='180' style='width:180px;height:auto;border:1px solid #999;display:block;' /><div style='font-size:8px;color:#888;text-align:center;margin-top:4px;line-height:1.3;'><em>${GZ_IMG_DESC}</em><br>${GZ_IMG_CREDIT}</div></div>")${GZ_FRONT}</div>
  <div style='text-align:center;padding:12px 24px 18px;border-top:1px solid #ccc;'>
    <a href='https://${SERVER_HOST}/#gazette' style='display:inline-block;background:#1a1a1a;color:#f5f0e6;padding:10px 28px;font-size:13px;font-weight:700;text-decoration:none;font-family:Georgia,serif;'>Read the full issue &rarr;</a>
  </div>
  <div style='text-align:center;padding:8px;border-top:4px double #1a1a1a;font-size:9px;color:#888;text-transform:uppercase;letter-spacing:2px;'>The Civ Chronicle</div>
</div>
<p style='font-size:13px;color:#666;'>(rest of the email — rankings table, deadline, etc. — would render below this gazette block)</p>
</div></body></html>
EOF
echo "[preview-email] wrote $OUT (turn $GZ_TURN: $GZ_HEADLINE)"

# Editor reply email — uses GAZETTE_CONTEXT teaser. Show the first 600
# chars of what would be passed to the editor model so we can verify
# the v2 schema is being read correctly.
OUT2=/tmp/email-editor-context.txt
jq -r '
  def front:
    if .sections then (.sections.front_page.content // .sections.front_page // "")
    elif .pages then ([.pages[].sections[] | select(.kind == "lead")] | .[0].content // "")
    else "" end;
  [.[-2:][] | "Turn \(.turn) (\(.year_display)): \(.headline)\nFront page: \(front | gsub("<[^>]*>"; "") | .[0:300])"] | join("\n\n")
' "$GAZETTE_JSON" > "$OUT2"
echo "[preview-email] wrote $OUT2 (editor's gazette context teaser)"

echo
echo "Open:    file://$OUT"
echo "Inspect: cat $OUT2"
