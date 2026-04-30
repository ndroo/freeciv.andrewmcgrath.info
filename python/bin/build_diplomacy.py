#!/usr/bin/env python3
"""Rebuild diplomacy.json from all save files.

Replaces the bash `build_diplomacy()` that hung prod for 51 minutes on
2026-04-29 (and is the original reason for this whole rewrite).
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from lib import diplomacy


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--save-dir", type=Path, default=Path("/data/saves"),
        help="Directory containing lt-game-N.sav.gz files",
    )
    parser.add_argument(
        "--out", type=Path, default=None,
        help="Output path (default: <save-dir>/diplomacy.json)",
    )
    args = parser.parse_args()

    out_path = args.out or (args.save_dir / "diplomacy.json")
    saves = sorted(
        args.save_dir.glob("lt-game-*.sav.gz"),
        key=lambda p: int(p.stem.split("-")[-1].replace(".sav", "")),
    )
    if not saves:
        print(f"[diplomacy] No saves found in {args.save_dir}", file=sys.stderr)
        return 1
    data = diplomacy.build(saves)
    diplomacy.write(data, out_path)
    print(
        f"[diplomacy] Wrote {len(data['current'])} active relationships, "
        f"{len(data['events'])} historical events, "
        f"{len(data['combat_pairs'])} combat pairs to {out_path}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
