#!/usr/bin/env python3
"""Rebuild per-player dashboard JSON files from all save files.

Replaces generate_dashboard.sh which routinely took 9-24 minutes per run
because of nested jq invocations per player per turn.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from lib import dashboard


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--save-dir", type=Path, default=Path("/data/saves"),
        help="Directory containing lt-game-N.sav.gz files",
    )
    parser.add_argument(
        "--out-dir", type=Path, default=None,
        help="Output directory (default: <save-dir>/dashboard)",
    )
    args = parser.parse_args()

    out_dir = args.out_dir or (args.save_dir / "dashboard")
    saves = sorted(
        args.save_dir.glob("lt-game-*.sav.gz"),
        key=lambda p: int(p.stem.split("-")[-1].replace(".sav", "")),
    )
    if not saves:
        print(f"[dashboard] No saves found in {args.save_dir}", file=sys.stderr)
        return 1

    dashboards = dashboard.build_dashboards(saves)
    dashboard.write_all(dashboards, out_dir)
    print(f"[dashboard] Wrote {len(dashboards)} player dashboards to {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
