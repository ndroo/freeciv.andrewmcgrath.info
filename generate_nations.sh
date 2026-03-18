#!/bin/bash
# Generates a static nations list page at /nations
# Run once at startup — nation list doesn't change

WEBROOT=/opt/freeciv/www
NATION_DIR=/usr/local/share/freeciv/nation
SERVER_HOST="${SERVER_HOST:-freeciv.andrewmcgrath.info}"
JOIN_FORM="https://docs.google.com/forms/d/e/1FAIpQLSdtCLEfuwF_o4Sgdc-UT1X7zRsqigJHeRKxAELmlJug0KHwlw/viewform?usp=dialog"

mkdir -p "$WEBROOT"

# Extract nation names from ruleset files
# Each .ruleset has a line like: name=_("Australian")
NATIONS=""
NATION_COUNT=0
for f in "$NATION_DIR"/*.ruleset; do
  [ ! -f "$f" ] && continue
  # Get the display name from the ruleset
  raw_name=$(grep '^name=' "$f" | head -1 | sed 's/name=_("//;s/")//' | sed 's/name="//;s/"//')
  # Get the filename as fallback
  file_name=$(basename "$f" .ruleset)

  # Skip barbarian/special nations
  case "$file_name" in barbarian|singlebarbarian|animals|pirate) continue ;; esac

  display_name="${raw_name:-$file_name}"
  NATIONS="${NATIONS}${display_name}\n"
  NATION_COUNT=$((NATION_COUNT + 1))
done

# Sort nations
SORTED_NATIONS=$(echo -e "$NATIONS" | sort -f | grep -v '^$')

# Group by first letter
CURRENT_LETTER=""
NATION_CARDS=""

while IFS= read -r nation; do
  [ -z "$nation" ] && continue
  first_letter=$(echo "$nation" | cut -c1 | tr '[:lower:]' '[:upper:]')

  if [ "$first_letter" != "$CURRENT_LETTER" ]; then
    [ -n "$CURRENT_LETTER" ] && NATION_CARDS="${NATION_CARDS}</div></div>"
    CURRENT_LETTER="$first_letter"
    NATION_CARDS="${NATION_CARDS}<div class=\"letter-group\" id=\"letter-${CURRENT_LETTER}\"><div class=\"letter-header\">${CURRENT_LETTER}</div><div class=\"nation-list\">"
  fi

  NATION_CARDS="${NATION_CARDS}<span class=\"nation-tag\">${nation}</span>"
done <<< "$SORTED_NATIONS"
[ -n "$CURRENT_LETTER" ] && NATION_CARDS="${NATION_CARDS}</div></div>"

# Build letter index
LETTER_INDEX=""
for letter in A B C D E F G H I J K L M N O P Q R S T U V W X Y Z; do
  if echo -e "$SORTED_NATIONS" | grep -qi "^${letter}"; then
    LETTER_INDEX="${LETTER_INDEX}<a href=\"#letter-${letter}\" class=\"letter-link\">${letter}</a>"
  else
    LETTER_INDEX="${LETTER_INDEX}<span class=\"letter-link dim\">${letter}</span>"
  fi
done

cat > "$WEBROOT/nations.html" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Available Nations — Freeciv Longturn</title>
  <style>
    :root {
      --bg: #0a0d14; --surface: #111621; --surface-2: #171d2b; --surface-3: #1e2538;
      --border: #252d42; --text: #b0bdd0; --text-dim: #5a6a82; --text-bright: #e4eaf2;
      --accent: #e94560; --accent-dim: rgba(233,69,96,0.12);
      --green: #22c55e; --green-dim: rgba(34,197,94,0.1);
    }
    * { margin:0; padding:0; box-sizing:border-box; }
    body { background:var(--bg); color:var(--text); font-family:Inter,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; line-height:1.6; -webkit-font-smoothing:antialiased; }
    a { color:var(--accent); text-decoration:none; } a:hover { text-decoration:underline; }

    nav { background:var(--surface); border-bottom:1px solid var(--border); padding:10px 0; position:sticky; top:0; z-index:50; }
    nav .inner { max-width:900px; margin:0 auto; padding:0 20px; display:flex; align-items:center; justify-content:space-between; }
    .brand { font-weight:800; font-size:15px; color:var(--text-bright); letter-spacing:-0.5px; }
    .brand span { color:var(--accent); }

    .hero { padding:40px 20px 32px; text-align:center; background:linear-gradient(180deg, var(--surface) 0%, var(--bg) 100%); border-bottom:1px solid var(--border); }
    .hero h1 { font-size:32px; font-weight:900; color:var(--text-bright); letter-spacing:-1px; }
    .hero .sub { color:var(--text-dim); font-size:14px; margin-top:6px; }
    .hero .count { display:inline-block; background:var(--accent-dim); color:var(--accent); padding:4px 14px; border-radius:20px; font-size:13px; font-weight:700; margin-top:12px; }

    .wrap { max-width:900px; margin:0 auto; padding:0 20px; }

    .search-box { margin:24px auto; max-width:400px; position:relative; }
    .search-box input { width:100%; background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:10px 16px 10px 40px; color:var(--text-bright); font-size:14px; outline:none; transition:border-color .15s; }
    .search-box input:focus { border-color:var(--accent); }
    .search-box input::placeholder { color:var(--text-dim); }
    .search-icon { position:absolute; left:14px; top:50%; transform:translateY(-50%); color:var(--text-dim); font-size:14px; }

    .letter-index { display:flex; flex-wrap:wrap; gap:4px; justify-content:center; margin:20px 0 28px; }
    .letter-link { display:inline-flex; align-items:center; justify-content:center; width:32px; height:32px; border-radius:6px; font-size:13px; font-weight:700; color:var(--text); background:var(--surface); border:1px solid var(--border); text-decoration:none; transition:all .15s; }
    .letter-link:hover { background:var(--accent); color:#fff; border-color:var(--accent); text-decoration:none; }
    .letter-link.dim { color:var(--text-dim); opacity:0.3; pointer-events:none; }

    .letter-group { margin-bottom:28px; }
    .letter-header { font-size:20px; font-weight:800; color:var(--accent); margin-bottom:10px; padding-bottom:6px; border-bottom:1px solid var(--border); }
    .nation-list { display:flex; flex-wrap:wrap; gap:6px; }
    .nation-tag { background:var(--surface); border:1px solid var(--border); padding:5px 12px; border-radius:6px; font-size:13px; color:var(--text-bright); font-weight:500; transition:all .15s; }
    .nation-tag:hover { border-color:var(--accent); background:var(--accent-dim); }
    .nation-tag.hidden { display:none; }

    .cta { text-align:center; padding:40px 20px; border-top:1px solid var(--border); margin-top:20px; }
    .cta a.btn { display:inline-block; background:var(--accent); color:#fff; padding:12px 32px; border-radius:8px; font-size:15px; font-weight:700; text-decoration:none; }
    .cta a.btn:hover { opacity:0.9; text-decoration:none; }
    .cta .note { color:var(--text-dim); font-size:12px; margin-top:10px; }

    footer { padding:20px; text-align:center; color:var(--text-dim); font-size:11px; opacity:.5; }

    @media(max-width:600px) {
      .hero h1 { font-size:24px; }
      .letter-link { width:28px; height:28px; font-size:11px; }
      .nation-tag { font-size:12px; padding:4px 10px; }
    }
  </style>
</head>
<body>

<nav>
  <div class="inner">
    <a href="/" style="text-decoration:none;"><div class="brand"><span>Freeciv</span> Longturn</div></a>
    <a href="${JOIN_FORM}" target="_blank" style="font-size:13px;font-weight:700;">Request to Join</a>
  </div>
</nav>

<div class="hero">
  <h1>Available Nations</h1>
  <div class="sub">Each player picks a unique nation &mdash; no duplicates allowed</div>
  <div class="count">${NATION_COUNT} nations available</div>
</div>

<div class="wrap">
  <div class="search-box">
    <span class="search-icon">&#x1F50D;</span>
    <input type="text" id="search" placeholder="Search nations..." autocomplete="off">
  </div>

  <div class="letter-index">
    ${LETTER_INDEX}
  </div>

  <div id="nations">
    ${NATION_CARDS}
  </div>

  <div id="no-results" style="display:none;text-align:center;padding:40px;color:var(--text-dim);">
    No nations match your search.
  </div>
</div>

<div class="cta">
  <a href="${JOIN_FORM}" target="_blank" class="btn">Request to Join</a>
  <div class="note">Pick your nation in the signup form &mdash; first come, first served</div>
</div>

<footer>Freeciv Longturn &middot; <a href="/" style="color:inherit;">${SERVER_HOST}</a></footer>

<script>
const search = document.getElementById('search');
const tags = document.querySelectorAll('.nation-tag');
const groups = document.querySelectorAll('.letter-group');
const noResults = document.getElementById('no-results');

search.addEventListener('input', function() {
  const q = this.value.toLowerCase().trim();
  let visible = 0;

  tags.forEach(tag => {
    const match = !q || tag.textContent.toLowerCase().includes(q);
    tag.classList.toggle('hidden', !match);
    if (match) visible++;
  });

  groups.forEach(g => {
    const hasVisible = g.querySelectorAll('.nation-tag:not(.hidden)').length > 0;
    g.style.display = hasVisible ? '' : 'none';
  });

  noResults.style.display = visible === 0 ? '' : 'none';
});
</script>
</body>
</html>
HTMLEOF

echo "[nations-page] Generated nations page with ${NATION_COUNT} nations"
