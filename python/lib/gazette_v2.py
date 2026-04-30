"""Validator for gazette.json v2 entries.

Runs structural checks only — content quality and section-kind correctness
are intentionally NOT validated (the renderer falls back to a generic
template for unknown kinds, so the AI can experiment freely).

Use:
    from lib.gazette_v2 import validate
    issues = validate(entry_dict)
    if issues:
        raise ValueError(issues)
"""

from __future__ import annotations

import re
from typing import Iterable

INLINE_IMG_RE = re.compile(r"\{\{img:([a-z0-9_-]+)\}\}", re.IGNORECASE)
MAX_IMAGES = 6
MIN_PAGES = 1
MAX_PAGES = 4


def _walk_strings(node) -> Iterable[str]:
    """Yield every string descendant of `node` so we can scan for {{img:id}}
    tokens without caring which section field hosts them."""
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from _walk_strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from _walk_strings(v)


def validate(entry: dict) -> list[str]:
    """Return a list of human-readable issue strings. Empty list = OK."""
    issues: list[str] = []

    if entry.get("schema_version") != 2:
        issues.append("schema_version != 2")
    if not entry.get("headline"):
        issues.append("missing headline")

    pages = entry.get("pages")
    if not isinstance(pages, list) or not pages:
        issues.append("pages must be a non-empty array")
        return issues
    if len(pages) > MAX_PAGES:
        issues.append(f"{len(pages)} pages (max {MAX_PAGES})")

    for i, page in enumerate(pages):
        if not isinstance(page, dict):
            issues.append(f"page[{i}] not an object")
            continue
        sections = page.get("sections")
        if not isinstance(sections, list):
            issues.append(f"page[{i}] has no sections array")
            continue
        for j, section in enumerate(sections):
            if not isinstance(section, dict):
                issues.append(f"page[{i}].sections[{j}] not an object")
                continue
            if not isinstance(section.get("kind"), str):
                issues.append(f"page[{i}].sections[{j}] missing 'kind'")

    images = entry.get("images") or []
    if not isinstance(images, list):
        issues.append("images must be an array")
        images = []
    if len(images) > MAX_IMAGES:
        issues.append(f"{len(images)} images (max {MAX_IMAGES})")
    image_ids: set[str] = set()
    for k, im in enumerate(images):
        if not isinstance(im, dict):
            issues.append(f"images[{k}] not an object")
            continue
        if not isinstance(im.get("id"), str):
            issues.append(f"images[{k}] missing 'id'")
            continue
        image_ids.add(im["id"])

    # All lead_image_id refs and inline {{img:id}} tokens must resolve.
    referenced_ids: set[str] = set()
    for s in _walk_strings(entry):
        for m in INLINE_IMG_RE.finditer(s):
            referenced_ids.add(m.group(1))
    for page in pages:
        for section in page.get("sections", []) if isinstance(page, dict) else []:
            if isinstance(section, dict):
                lid = section.get("lead_image_id")
                if isinstance(lid, str):
                    referenced_ids.add(lid)
                if section.get("kind") == "image":
                    iid = section.get("image_id")
                    if isinstance(iid, str):
                        referenced_ids.add(iid)
    unresolved = referenced_ids - image_ids
    if unresolved:
        issues.append("unresolved image refs: " + ", ".join(sorted(unresolved)))

    return issues
