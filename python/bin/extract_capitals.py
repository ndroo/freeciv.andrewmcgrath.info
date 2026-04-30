#!/usr/bin/env python3
"""Extract per-player capital city + terrain from a freeciv save.

Output (JSON to stdout):
  {
    "regions": [
      {
        "nation": "Australian",
        "leader": "andrew",
        "capital": "Sydney",
        "x": 12, "y": 34,
        "terrain": "Plains",
        "climate": "temperate"
      },
      ...
    ]
  }

Usage:
  python3 extract_capitals.py /data/saves/save-latest.sav.gz
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

# Allow running as a script from python/bin/.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.freeciv_save import Save, _strip_quotes  # noqa: E402


# Map terrain character → (display name, climate bucket).
# Climate bucket is what the AI keys on for plausible per-region weather.
TERRAIN_TABLE: dict[str, tuple[str, str]] = {
    " ": ("Ocean", "maritime"),
    ":": ("Deep Ocean", "maritime"),
    "g": ("Grassland", "temperate"),
    "p": ("Plains", "temperate"),
    "f": ("Forest", "temperate-wet"),
    "h": ("Hills", "temperate"),
    "m": ("Mountains", "alpine"),
    "d": ("Desert", "arid"),
    "j": ("Jungle", "tropical"),
    "s": ("Swamp", "tropical-wet"),
    "t": ("Tundra", "subarctic"),
    "a": ("Arctic", "polar"),
    "+": ("Lake", "temperate"),
}


def _terrain_at(save: Save, x: int, y: int) -> tuple[str, str]:
    """Look up the terrain character at (x, y) in [map] and decode it.

    Map rows are stored as t0000=\"...\" through t<ymax>=\"...\". The first
    occurrence per row is the terrain layer.
    """
    map_section = save.sections.get("map")
    if map_section is None:
        return ("Unknown", "unknown")
    key = f"t{y:04d}"
    row = map_section.scalars.get(key, "")
    row = _strip_quotes(row)
    if not row or x >= len(row):
        return ("Unknown", "unknown")
    ch = row[x]
    return TERRAIN_TABLE.get(ch, (f"?({ch})", "unknown"))


def _find_capital(player) -> tuple[str, int, int] | None:
    """Find the city with the Palace improvement.

    Falls back to the founder city (smallest turn_founded) if no improvement
    info is available — every civ in Freeciv starts with a Palace, so the
    founder is the capital unless it's been moved (rare in this campaign).
    """
    table = player.tables.get("c")
    if table is None:
        return None
    h = table.header
    # Required columns
    idx_name = h.index("name") if "name" in h else None
    idx_x = h.index("x") if "x" in h else None
    idx_y = h.index("y") if "y" in h else None
    if idx_name is None or idx_x is None or idx_y is None:
        return None
    idx_orig = h.index("original") if "original" in h else None
    idx_imp = h.index("improvements") if "improvements" in h else None
    idx_founded = h.index("turn_founded") if "turn_founded" in h else None

    candidate = None
    earliest = None
    for row in table.rows:
        try:
            x = int(row[idx_x])
            y = int(row[idx_y])
        except (ValueError, IndexError):
            continue
        name = _strip_quotes(row[idx_name]) if idx_name < len(row) else ""

        # Strongest signal: improvements bitmask names a Palace.
        # The bitmask is a string like "10101..." indexed against an
        # improvement vector held in the [savefile] section. Parsing
        # that is overkill for this extractor — instead we use the
        # "original" flag (founder city) as a stand-in. Freeciv 3.2
        # places the Palace in the city marked original=TRUE.
        if idx_orig is not None and idx_orig < len(row):
            orig = row[idx_orig].strip().upper() == "TRUE"
            if orig:
                return (name, x, y)

        # Track earliest-founded city as a fallback.
        if idx_founded is not None and idx_founded < len(row):
            try:
                f = int(row[idx_founded])
            except ValueError:
                f = 1_000_000
            if earliest is None or f < earliest[0]:
                earliest = (f, name, x, y)

        if candidate is None:
            candidate = (name, x, y)

    if earliest is not None:
        _, name, x, y = earliest
        return (name, x, y)
    return candidate


def main():
    if len(sys.argv) < 2:
        print("Usage: extract_capitals.py <save.sav.gz>", file=sys.stderr)
        sys.exit(2)
    save = Save.load(sys.argv[1])

    regions = []
    for p in save.players():
        if p.get_bool("is_alive") is False:
            continue
        leader = p.get_str("name", "") or ""
        nation = p.get_str("nation", "") or ""
        leader = _strip_quotes(leader)
        nation = _strip_quotes(nation)
        cap = _find_capital(p)
        if cap is None:
            continue
        capital, x, y = cap
        terrain, climate = _terrain_at(save, x, y)
        regions.append({
            "nation": nation,
            "leader": leader,
            "capital": capital,
            "x": x,
            "y": y,
            "terrain": terrain,
            "climate": climate,
        })

    json.dump({"regions": regions}, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
