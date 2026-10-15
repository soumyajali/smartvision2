"""Meet the Builders page for the Streamlit website.

Profiles come from assets/builders/builders.json (shared with the Flutter app).
Each card shows only: photo, name, approved mobile number, about.
"""

import base64
import json
import mimetypes
from html import escape
from pathlib import Path

import streamlit as st

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "assets" / "builders" / "builders.json"
PHOTOS = ROOT / "assets" / "builders" / "photos"


def load_builders():
    try:
        data = json.loads(CONFIG.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return {"title": "Meet the Builders", "subtitle": "The team behind Smart Vision",
                "builders": [], "error": str(exc)}
    data.setdefault("title", "Meet the Builders")
    data.setdefault("subtitle", "The team behind Smart Vision")
    data.setdefault("builders", [])
    return data


def _photo_html(photo: str, name: str) -> str:
    path = (PHOTOS / photo) if photo else None
    if path and path.is_file() and path.resolve().parent == PHOTOS.resolve():
        mime = mimetypes.guess_type(path.name)[0] or "image/jpeg"
        encoded = base64.b64encode(path.read_bytes()).decode()
        return f"<img class='builder-photo' src='data:{mime};base64,{encoded}' alt='{escape(name)}'/>"
    return ("<div class='builder-photo builder-photo-empty'>"
            "<span class='sv-icon' aria-hidden='true'>person</span></div>")


def builder_card_html(builder: dict) -> str:
    if builder.get("placeholder", True) or not (builder.get("name") or "").strip():
        return (
            "<div class='builder-card builder-placeholder'>"
            f"{_photo_html('', '')}"
            "<div class='builder-name'>Profile pending</div>"
            "<div class='builder-about'>Photo, name and details will be added when "
            "the builder provides them.</div></div>"
        )
    name = builder["name"].strip()
    parts = [f"<div class='builder-card'>{_photo_html(builder.get('photo', ''), name)}",
             f"<div class='builder-name'>{escape(name)}</div>"]
    mobile = (builder.get("mobile") or "").strip()
    if mobile and builder.get("show_mobile") is True:
        parts.append(f"<a class='builder-mobile' href='tel:{escape(mobile)}'><span class='sv-icon' aria-hidden='true'>call</span> {escape(mobile)}</a>")
    about = (builder.get("about") or "").strip()
    if about:
        parts.append(f"<div class='builder-about'>{escape(about)}</div>")
    parts.append("</div>")
    return "".join(parts)


CSS = """
<style>
.builders-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 18px; margin-top: 18px; }
.builder-card { background: #111B36; border: 1px solid #263B61;
  border-radius: 18px; padding: 22px 18px; text-align: center; color: #F1F5F9; box-shadow: 0 8px 24px rgba(0,0,0,0.25); }
.builder-card:hover { border-color: rgba(56,189,248,0.7); }
.builder-photo { width: 120px; height: 120px; border-radius: 50%; object-fit: cover; border: 2px solid #38BDF8;
  box-shadow: 0 0 18px rgba(139,92,246,0.35); margin: 0 auto 14px auto; display: block; }
.builder-photo-empty { display: flex; align-items: center; justify-content: center; color: #B8C4D9;
  background: #16234A; }
.builder-photo-empty .sv-icon { font-size: 56px; color: #B8C4D9; }
.builder-mobile .sv-icon { font-size: 18px; color: #38BDF8; }
.builder-name { font-size: 18px; font-weight: 700; margin-bottom: 6px; }
.builder-mobile { display: inline-block; color: #38BDF8 !important; text-decoration: none; font-size: 14px; margin-bottom: 10px; }
.builder-about { color: #B8C4D9; font-size: 14px; line-height: 1.5; }
.builder-placeholder { border-style: dashed; }
</style>
"""


def render_builders_page():
    data = load_builders()
    st.markdown(f"<div class='section-title'>{escape(data['title'])}</div>", unsafe_allow_html=True)
    st.markdown(f"<div class='sub-text'>{escape(data['subtitle'])}</div>", unsafe_allow_html=True)
    if data.get("error"):
        st.error(f"Could not read {CONFIG.relative_to(ROOT)}: {data['error']}")
        return
    builders = data["builders"]
    if not builders:
        st.info("No builder profiles have been added yet.")
        return
    cards = "".join(builder_card_html(b) for b in builders)
    st.markdown(CSS + f"<div class='builders-grid'>{cards}</div>", unsafe_allow_html=True)
