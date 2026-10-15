"""Meet the Builders: shared profile config and card rendering (website)."""

import json
from pathlib import Path

from ui.builders import CONFIG, builder_card_html, load_builders

ALLOWED_FIELDS = {
    "id", "placeholder", "photo", "name", "mobile", "show_mobile", "about",
    "usn", "email", "role", "designation"
}


def test_config_has_only_the_allowed_profile_fields():
    data = json.loads(Path(CONFIG).read_text())
    assert "Smart Vision" in data["subtitle"]
    for builder in data["builders"]:
        assert set(builder) <= ALLOWED_FIELDS


def test_placeholders_never_show_invented_details():
    html = builder_card_html({"id": "x", "placeholder": True, "name": "", "mobile": "", "about": ""})
    assert "Profile pending" in html


def test_mobile_number_only_shown_when_approved():
    profile = {"id": "a", "placeholder": False, "name": "Test Person", "mobile": "+91 90000 00000",
               "show_mobile": False, "about": "About text"}
    assert "+91 90000 00000" not in builder_card_html(profile)
    profile["show_mobile"] = True
    html = builder_card_html(profile)
    assert "+91 90000 00000" in html and "Test Person" in html and "About text" in html
    assert "role" not in html.lower()


def test_loader_returns_profiles():
    assert len(load_builders()["builders"]) >= 1
