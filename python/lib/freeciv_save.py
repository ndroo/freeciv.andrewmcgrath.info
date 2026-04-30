"""Parser for freeciv 3.2 .sav.gz files.

The save is a gzipped INI-style text file. Three constructs:

  1. Section headers:        [game]   [player3]   [map]
  2. Scalar assignments:     turn=53     name="Andrew"     phase_done=TRUE
  3. Tables:                 diplstate={"current","closest", ...
                             "War","War",26,0
                             ...
                             }

Scalar values may be quoted strings, integers, booleans (TRUE/FALSE), or
comma-separated vectors of those (`"A","B","C"`). Table rows are CSV-with-
quoted-strings — quoted strings can contain commas (`"Aqueduct, River"`),
so a naive split(",") is wrong.

There is one historical wart: the [script] section uses `code=$$ ... $$` to
delimit a multi-line lua block. We recognize and skip past it without trying
to parse it as scalars/tables.

The parser keeps every value as a raw string. Convenience accessors
(`section.get_int`, `get_bool`, `get_str`, `get_vector`) coerce on demand,
because the cost of eagerly converting every numeric in a 3MB save adds up.
"""

from __future__ import annotations

import gzip
import re
from dataclasses import dataclass, field
from io import StringIO
from pathlib import Path

_SECTION_RE = re.compile(r"^\[([^\]]+)\]\s*$")
_TRUE_RE = re.compile(r"^TRUE$", re.IGNORECASE)
_FALSE_RE = re.compile(r"^FALSE$", re.IGNORECASE)


def _strip_quotes(s: str) -> str:
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s


def _parse_csv_row(line: str) -> list[str]:
    """Split a freeciv table row on commas, respecting quoted strings.

    The quoting rules are simple: `"..."` is a quoted string and may
    contain commas. There's no escaping of quotes inside quoted strings
    in freeciv saves (we haven't seen one in 53 turns of game data),
    so we treat `"` strictly as start-of-string / end-of-string.
    """
    out: list[str] = []
    buf: list[str] = []
    in_quotes = False
    for ch in line:
        if ch == '"':
            in_quotes = not in_quotes
            buf.append(ch)
        elif ch == "," and not in_quotes:
            out.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    out.append("".join(buf))
    return out


@dataclass
class Table:
    header: list[str]
    rows: list[list[str]]

    def col(self, name: str) -> list[str]:
        idx = self.header.index(name)
        return [r[idx] if idx < len(r) else "" for r in self.rows]


@dataclass
class Section:
    name: str
    scalars: dict[str, str] = field(default_factory=dict)
    tables: dict[str, Table] = field(default_factory=dict)

    # ----- accessors ---------------------------------------------------

    def get_str(self, key: str, default: str | None = None) -> str | None:
        v = self.scalars.get(key)
        if v is None:
            return default
        return _strip_quotes(v)

    def get_int(self, key: str, default: int | None = None) -> int | None:
        v = self.scalars.get(key)
        if v is None or v == "":
            return default
        try:
            return int(v)
        except ValueError:
            return default

    def get_bool(self, key: str, default: bool | None = None) -> bool | None:
        v = self.scalars.get(key)
        if v is None:
            return default
        if _TRUE_RE.match(v):
            return True
        if _FALSE_RE.match(v):
            return False
        return default

    def get_vector(self, key: str) -> list[str]:
        """Parse `"A","B","C"` style vectors. Returns [] for missing keys."""
        v = self.scalars.get(key)
        if v is None or v == "":
            return []
        return [_strip_quotes(x) for x in _parse_csv_row(v)]


@dataclass
class Save:
    sections: dict[str, Section] = field(default_factory=dict)

    @classmethod
    def load(cls, path: str | Path) -> "Save":
        with gzip.open(path, "rt", encoding="utf-8", errors="replace") as f:
            return cls.parse(f.read())

    @classmethod
    def parse(cls, text: str) -> "Save":
        save = cls()
        current: Section | None = None
        # Iterate via index so we can consume multi-line tables in one pass.
        lines = text.splitlines()
        i = 0
        n = len(lines)
        while i < n:
            line = lines[i]
            stripped = line.strip()

            if not stripped:
                i += 1
                continue

            # Section header
            m = _SECTION_RE.match(line)
            if m:
                current = Section(name=m.group(1))
                save.sections[current.name] = current
                i += 1
                continue

            if current is None:
                # Lines before the first section (rare). Drop them.
                i += 1
                continue

            # The [script] section uses `code=$$ ... $$` for multi-line lua.
            # Skip over the body so we don't try to parse it as INI.
            if current.name == "script" and stripped.startswith("code=$$"):
                # Find the closing $$ on a later line (or same line if both on
                # one line, which we haven't seen but support).
                rest = stripped[len("code=$$"):]
                if rest.endswith("$$"):
                    current.scalars["code"] = rest[:-2]
                    i += 1
                    continue
                body = [rest]
                i += 1
                while i < n and not lines[i].rstrip().endswith("$$"):
                    body.append(lines[i])
                    i += 1
                if i < n:
                    body.append(lines[i].rstrip()[:-2])
                    i += 1
                current.scalars["code"] = "\n".join(body)
                continue

            # Look for a `key=` assignment. Tables open with `key={...`.
            eq = line.find("=")
            if eq <= 0:
                i += 1
                continue
            key = line[:eq]
            value = line[eq + 1:]

            if value.startswith("{"):
                # Multi-line table. The header row follows the `{` on the
                # same line.
                header = _parse_csv_row(value[1:])
                header = [_strip_quotes(h) for h in header]
                rows: list[list[str]] = []
                i += 1
                while i < n:
                    row_line = lines[i]
                    if row_line.strip() == "}":
                        i += 1
                        break
                    rows.append(_parse_csv_row(row_line))
                    i += 1
                current.tables[key] = Table(header=header, rows=rows)
                continue

            current.scalars[key] = value
            i += 1

        return save

    # ----- convenience navigators -------------------------------------

    def players(self) -> list[Section]:
        """Return all `[playerN]` sections, ordered by N."""
        out = []
        for name, sect in self.sections.items():
            if name.startswith("player") and name[6:].isdigit():
                out.append((int(name[6:]), sect))
        out.sort(key=lambda x: x[0])
        return [s for _, s in out]

    def game(self) -> Section | None:
        return self.sections.get("game")

    @property
    def turn(self) -> int:
        g = self.game()
        return g.get_int("turn", 0) if g else 0

    @property
    def year(self) -> int:
        g = self.game()
        return g.get_int("year", 0) if g else 0
