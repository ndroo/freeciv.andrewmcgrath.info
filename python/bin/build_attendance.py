#!/usr/bin/env python3
"""Rebuild attendance.json from all save files in the save directory.

Replaces the bash `build_attendance()` function in generate_status_json.sh,
which forked `jq` per-player-per-turn and could take many minutes.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from lib import attendance


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--save-dir", type=Path, default=Path("/data/saves"),
        help="Directory containing lt-game-N.sav.gz files",
    )
    parser.add_argument(
        "--out", type=Path, default=None,
        help="Output path (default: <save-dir>/attendance.json)",
    )
    args = parser.parse_args()

    out_path = args.out or (args.save_dir / "attendance.json")
    saves = sorted(
        args.save_dir.glob("lt-game-*.sav.gz"),
        key=lambda p: int(p.stem.split("-")[-1].replace(".sav", "")),
    )
    if not saves:
        print(f"[attendance] No saves found in {args.save_dir}", file=sys.stderr)
        return 1
    data = attendance.build(saves)
    attendance.write(data, out_path)
    print(f"[attendance] Wrote {len(data)} players to {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
