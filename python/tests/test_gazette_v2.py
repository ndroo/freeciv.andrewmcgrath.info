"""Tests for the v2 gazette schema validator (lib/gazette_v2.py)."""

import json
from pathlib import Path

from lib.gazette_v2 import validate, MAX_IMAGES, MAX_PAGES

FIXTURE = Path(__file__).parent / "fixtures" / "gazette-v2-sample.json"


def test_sample_fixture_validates_clean():
    entry = json.loads(FIXTURE.read_text())
    assert validate(entry) == []


def test_missing_schema_version_flagged():
    entry = json.loads(FIXTURE.read_text())
    del entry["schema_version"]
    assert "schema_version != 2" in validate(entry)


def test_missing_headline_flagged():
    entry = json.loads(FIXTURE.read_text())
    entry["headline"] = ""
    assert "missing headline" in validate(entry)


def test_no_pages_rejected():
    entry = {"schema_version": 2, "headline": "x", "pages": []}
    issues = validate(entry)
    assert any("non-empty array" in i for i in issues)


def test_too_many_pages_flagged():
    entry = json.loads(FIXTURE.read_text())
    base_page = entry["pages"][0]
    entry["pages"] = [base_page] * (MAX_PAGES + 1)
    issues = validate(entry)
    assert any(f"pages (max {MAX_PAGES})" in i for i in issues)


def test_too_many_images_flagged():
    entry = json.loads(FIXTURE.read_text())
    entry["images"] = [{"id": f"im{i}", "prompt": "x", "caption": "y", "credit": "z"}
                       for i in range(MAX_IMAGES + 1)]
    issues = validate(entry)
    assert any(f"images (max {MAX_IMAGES})" in i for i in issues)


def test_unresolved_lead_image_id_flagged():
    entry = json.loads(FIXTURE.read_text())
    entry["pages"][0]["sections"][0]["lead_image_id"] = "imdoesnotexist"
    issues = validate(entry)
    assert any("imdoesnotexist" in i for i in issues)


def test_unresolved_inline_token_flagged():
    entry = json.loads(FIXTURE.read_text())
    entry["pages"][0]["sections"][0]["content"] = "<p>hi {{img:imghost}} bye</p>"
    issues = validate(entry)
    assert any("imghost" in i for i in issues)


def test_unknown_section_kind_passes():
    """Renderer falls back to a generic template for unknown kinds, so
    the validator should not reject them."""
    entry = json.loads(FIXTURE.read_text())
    entry["pages"][0]["sections"].append(
        {"kind": "experimental_dream_dispatch", "title": "x", "content": "y"})
    assert validate(entry) == []


def test_section_without_kind_flagged():
    entry = json.loads(FIXTURE.read_text())
    entry["pages"][0]["sections"][0].pop("kind")
    issues = validate(entry)
    assert any("missing 'kind'" in i for i in issues)


def test_standalone_image_id_must_resolve():
    entry = json.loads(FIXTURE.read_text())
    entry["pages"][0]["sections"].append({"kind": "image", "image_id": "ghost", "size": "full"})
    issues = validate(entry)
    assert any("ghost" in i for i in issues)
