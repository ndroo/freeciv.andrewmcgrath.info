"""Shared pytest fixtures.

The 53 lt-game-N.sav.gz files in tests/fixtures/ are real game saves pulled
from prod on 2026-04-29 (game in turn 53). They form the test corpus for
parser correctness and the diplomacy/attendance/dashboard benchmarks.
"""

from pathlib import Path

import pytest

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def fixture_dir() -> Path:
    return FIXTURES


@pytest.fixture
def latest_save(fixture_dir: Path) -> Path:
    """The newest save (turn 53)."""
    return fixture_dir / "lt-game-53.sav.gz"


@pytest.fixture
def all_saves(fixture_dir: Path) -> list[Path]:
    """All 53 save files, ordered by turn number."""
    files = sorted(
        fixture_dir.glob("lt-game-*.sav.gz"),
        key=lambda p: int(p.stem.split("-")[2].split(".")[0]),
    )
    return files
