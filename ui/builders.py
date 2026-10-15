"""Meet the Builders page for the Streamlit website.

Profiles come from assets/builders/builders.json (shared with the Flutter app).
Renders 4 team members in a single horizontal row and the faculty guide under
"UNDER THE GUIDANCE OF", matching the sleek dark neon cybernetic design.
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
        return {
            "title": "Builders' Profile",
            "subtitle": "The team behind Smart Vision AI",
            "builders": [],
            "error": str(exc),
        }
    data.setdefault("title", "Builders' Profile")
    data.setdefault("subtitle", "The team behind Smart Vision AI")
    data.setdefault("builders", [])
    return data


# SVG Icons
MAIL_ICON = """<svg class="bp-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="20" height="16" x="2" y="4" rx="2"/><path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7"/></svg>"""
PHONE_ICON = """<svg class="bp-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"/></svg>"""
GRAD_CAP_ICON = """<svg class="bp-icon bp-icon-cap" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.42 10.922a1 1 0 0 0-.019-1.838L12.83 5.18a2 2 0 0 0-1.66 0L2.6 9.08a1 1 0 0 0 0 1.832l8.57 3.908a2 2 0 0 0 1.66 0z"/><path d="M22 10v6"/><path d="M6 12.5V16a6 3 0 0 0 12 0v-3.5"/></svg>"""


def _photo_html(photo: str, name: str) -> str:
    path = (PHOTOS / photo) if photo else None
    if path and path.is_file() and path.resolve().parent == PHOTOS.resolve():
        mime = mimetypes.guess_type(path.name)[0] or "image/jpeg"
        encoded = base64.b64encode(path.read_bytes()).decode()
        return f"<img class='bp-photo' src='data:{mime};base64,{encoded}' alt='{escape(name)}'/>"
    return (
        "<div class='bp-photo bp-photo-empty'>"
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='currentColor' width='44' height='44'>"
        "<path d='M12 12c2.7 0 4.8-2.1 4.8-4.8S14.7 2.4 12 2.4 7.2 4.5 7.2 7.2 9.3 12 12 12zm0 2.4"
        "c-3.2 0-9.6 1.6-9.6 4.8v1.2c0 .66.54 1.2 1.2 1.2h16.8c.66 0 1.2-.54 1.2-1.2v-1.2c0-3.2-6.4-4.8-9.6-4.8z'/>"
        "</svg></div>"
    )


def _clean(html_text: str) -> str:
    return "".join(line.strip() for line in html_text.splitlines() if line.strip())


def _student_card(b: dict) -> str:
    name = escape(b.get("name", "").strip())
    photo = _photo_html(b.get("photo", ""), name)
    usn = escape(b.get("usn", ""))
    email = escape(b.get("email", ""))
    mobile = escape(b.get("mobile", ""))

    badge_html = f"<div class='bp-usn-badge'>{usn}</div>" if usn else ""
    about = escape(b.get("about", ""))
    about_html = f"<div class='bp-about'>{about}</div>" if about else ""

    contact_rows = []
    if email:
        mail_target = f"mailto:{email}" if "@" in email else f"https://{email}"
        contact_rows.append(
            f"<a class='bp-contact-item' href='{mail_target}' target='_blank' rel='noopener'>"
            f"{MAIL_ICON}<span>{email}</span></a>"
        )
    show_mobile = b.get("show_mobile", True)
    if mobile and show_mobile:
        contact_rows.append(
            f"<a class='bp-contact-item' href='tel:{mobile.replace(' ', '')}'>"
            f"{PHONE_ICON}<span>{mobile}</span></a>"
        )

    contacts_html = "".join(contact_rows)

    return _clean(f"""
    <div class='bp-member-card'>
      <div class='bp-photo-glow'>
        {photo}
      </div>
      <div class='bp-member-name'>{name}</div>
      {badge_html}
      {about_html}
      <div class='bp-card-divider'></div>
      <div class='bp-contact-list'>
        {contacts_html}
      </div>
    </div>
    """)


# For test backwards compatibility
def builder_card_html(b: dict) -> str:
    if b.get("placeholder"):
        return "<div class='bp-member-card'>Profile pending</div>"
    return _student_card(b)


def _guide_card(b: dict) -> str:
    name = escape(b.get("name", "").strip())
    designation = escape(b.get("designation", "Assistant Professor"))
    email = escape(b.get("email", "anitharao@aiet.org.in"))

    # Extract initials, e.g. "Prof. Anitha Rao" -> "AR"
    parts = [p for p in name.replace("Prof.", "").replace("Dr.", "").strip().split() if p]
    initials = "".join(p[0].upper() for p in parts[:2]) if parts else "AR"

    photo_content = _photo_html(b.get("photo", ""), name)
    if not b.get("photo"):
        avatar_html = f"<div class='bp-guide-initials'>{initials}</div>"
    else:
        avatar_html = photo_content

    return _clean(f"""
    <div class='bp-guide-card'>
      <div class='bp-guide-avatar-glow'>
        {avatar_html}
      </div>
      <div class='bp-guide-info'>
        <div class='bp-guide-tag'>
          {GRAD_CAP_ICON}
          <span>FACULTY GUIDE</span>
        </div>
        <div class='bp-guide-name'>{name}</div>
        <div class='bp-guide-role'>{designation}</div>
        <div class='bp-guide-contact'>
          <a class='bp-contact-item' href='mailto:{email}' target='_blank' rel='noopener'>
            {MAIL_ICON}<span>{email}</span>
          </a>
        </div>
      </div>
    </div>
    """)


CSS = """
<style>
/* ── Builders Profile Showcase ─────────────────────────── */

.bp-wrapper {
  max-width: 1200px;
  margin: 0 auto;
  padding: 10px 10px 40px 10px;
  font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
}

.bp-main-header {
  text-align: center;
  margin-bottom: 30px;
}

.bp-main-title {
  font-family: 'Rajdhani', 'Orbitron', 'Inter', sans-serif;
  font-size: 38px;
  font-weight: 800;
  letter-spacing: 0.5px;
  color: #FFFFFF;
  margin-bottom: 6px;
}

.bp-main-subtitle {
  font-size: 14px;
  color: #94A3B8;
  letter-spacing: 0.3px;
  margin-bottom: 14px;
}

.bp-gradient-pill {
  width: 52px;
  height: 4px;
  border-radius: 9999px;
  background: linear-gradient(90deg, #38BDF8 0%, #818CF8 100%);
  margin: 0 auto;
}

/* ── Section Bars with horizontal divider lines ────────── */

.bp-section-bar {
  display: flex;
  align-items: center;
  margin-top: 24px;
  margin-bottom: 22px;
  width: 100%;
}

.bp-section-title {
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 2px;
  text-transform: uppercase;
  color: #60A5FA;
  white-space: nowrap;
}

.bp-count-badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  background: rgba(56, 189, 248, 0.15);
  color: #38BDF8;
  font-size: 11px;
  font-weight: 700;
  padding: 1px 8px;
  border-radius: 9999px;
  margin-left: 10px;
  border: 1px solid rgba(56, 189, 248, 0.35);
}

.bp-section-line {
  flex: 1;
  height: 1px;
  background: linear-gradient(90deg, rgba(56, 189, 248, 0.3) 0%, rgba(255, 255, 255, 0.06) 100%);
  margin-left: 16px;
}

/* ── 4-Column Student Grid ─────────────────────────────── */

.bp-students-row {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 18px;
  margin-bottom: 40px;
}

@media (max-width: 1024px) {
  .bp-students-row {
    grid-template-columns: repeat(2, 1fr);
    gap: 20px;
  }
}

@media (max-width: 580px) {
  .bp-students-row {
    grid-template-columns: 1fr;
    gap: 16px;
  }
}

/* ── Student Card ──────────────────────────────────────── */

.bp-member-card {
  background: linear-gradient(180deg, rgba(16, 26, 54, 0.92) 0%, rgba(10, 18, 38, 0.98) 100%);
  border: 1px solid rgba(56, 189, 248, 0.22);
  border-top: 1px solid rgba(56, 189, 248, 0.45);
  border-radius: 16px;
  padding: 26px 16px 22px 16px;
  text-align: center;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.45);
  transition: transform 0.25s ease, border-color 0.25s ease, box-shadow 0.25s ease;
  position: relative;
  display: flex;
  flex-direction: column;
  align-items: center;
}

.bp-member-card:hover {
  transform: translateY(-4px);
  border-color: rgba(56, 189, 248, 0.6);
  box-shadow: 0 14px 40px rgba(56, 189, 248, 0.2);
}

.bp-photo-glow {
  width: 96px;
  height: 96px;
  border-radius: 50%;
  padding: 3px;
  background: linear-gradient(135deg, #38BDF8 0%, #6366F1 50%, #A855F7 100%);
  margin-bottom: 16px;
  box-shadow: 0 0 20px rgba(56, 189, 248, 0.42);
  display: flex;
  align-items: center;
  justify-content: center;
}

.bp-photo {
  width: 100%;
  height: 100%;
  border-radius: 50%;
  object-fit: cover;
  object-position: center top;
  border: 2px solid #0B1228;
  display: block;
}

.bp-photo-empty {
  width: 100%;
  height: 100%;
  border-radius: 50%;
  border: 2px solid #0B1228;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #16234A;
  color: #B8C4D9;
}

.bp-member-name {
  font-family: 'Inter', sans-serif;
  font-size: 15px;
  font-weight: 700;
  color: #FFFFFF;
  margin-bottom: 8px;
  letter-spacing: 0.2px;
  white-space: nowrap;
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
}

.bp-usn-badge {
  display: inline-block;
  padding: 3px 12px;
  border-radius: 9999px;
  background: rgba(30, 58, 138, 0.45);
  border: 1px solid rgba(56, 189, 248, 0.35);
  color: #60A5FA;
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.6px;
  margin-bottom: 16px;
}

.bp-card-divider {
  width: 100%;
  height: 1px;
  background: rgba(255, 255, 255, 0.08);
  margin-bottom: 14px;
}

.bp-contact-list {
  width: 100%;
  display: flex;
  flex-direction: column;
  gap: 9px;
  text-align: left;
}

.bp-contact-item {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 11.5px;
  color: #94A3B8 !important;
  text-decoration: none !important;
  transition: color 0.2s ease;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.bp-contact-item:hover {
  color: #38BDF8 !important;
}

.bp-contact-item span {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.bp-icon {
  width: 14px;
  height: 14px;
  min-width: 14px;
  color: #38BDF8;
}

/* ── Faculty Guide Card (Centered wide card) ───────────── */

.bp-guide-center {
  display: flex;
  justify-content: center;
  width: 100%;
  margin-top: 10px;
}

.bp-guide-card {
  width: 100%;
  max-width: 540px;
  background: linear-gradient(180deg, rgba(16, 26, 54, 0.95) 0%, rgba(10, 18, 38, 0.98) 100%);
  border: 1px solid rgba(56, 189, 248, 0.28);
  border-top: 1px solid rgba(56, 189, 248, 0.55);
  border-radius: 18px;
  padding: 22px 30px;
  display: flex;
  align-items: center;
  gap: 24px;
  box-shadow: 0 10px 32px rgba(0, 0, 0, 0.45);
  transition: transform 0.25s ease, border-color 0.25s ease, box-shadow 0.25s ease;
}

.bp-guide-card:hover {
  transform: translateY(-3px);
  border-color: rgba(56, 189, 248, 0.7);
  box-shadow: 0 14px 44px rgba(56, 189, 248, 0.22);
}

.bp-guide-avatar-glow {
  width: 82px;
  height: 82px;
  min-width: 82px;
  border-radius: 50%;
  padding: 3px;
  background: linear-gradient(135deg, #38BDF8 0%, #6366F1 100%);
  box-shadow: 0 0 22px rgba(56, 189, 248, 0.45);
  display: flex;
  align-items: center;
  justify-content: center;
}

.bp-guide-initials {
  width: 100%;
  height: 100%;
  border-radius: 50%;
  background: #0E1A38;
  border: 2px solid #0B1228;
  display: flex;
  align-items: center;
  justify-content: center;
  font-family: 'Rajdhani', 'Inter', sans-serif;
  font-size: 26px;
  font-weight: 800;
  color: #FFFFFF;
  letter-spacing: 1px;
}

.bp-guide-info {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  text-align: left;
}

.bp-guide-tag {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 1.5px;
  text-transform: uppercase;
  color: #38BDF8;
  margin-bottom: 4px;
}

.bp-icon-cap {
  width: 14px;
  height: 14px;
  color: #38BDF8;
}

.bp-guide-name {
  font-family: 'Inter', sans-serif;
  font-size: 19px;
  font-weight: 700;
  color: #FFFFFF;
  margin-bottom: 2px;
}

.bp-guide-role {
  font-size: 13px;
  color: #94A3B8;
  margin-bottom: 10px;
}

.bp-guide-contact {
  display: flex;
  align-items: center;
}

</style>
"""


def render_builders_page():
    data = load_builders()

    if data.get("error"):
        st.error(f"Could not read {CONFIG.relative_to(ROOT)}: {data['error']}")
        return

    builders = data["builders"]
    if not builders:
        st.info("No builder profiles have been added yet.")
        return

    students = [b for b in builders if b.get("role") != "guide" and not b.get("placeholder", True)]
    guides = [b for b in builders if b.get("role") == "guide" and not b.get("placeholder", True)]

    # Page Header
    header_html = _clean(f"""
    <div class='bp-main-header'>
      <div class='bp-main-title'>{escape(data.get('title', "Builders' Profile"))}</div>
      <div class='bp-main-subtitle'>{escape(data.get('subtitle', "The team behind Smart Vision AI"))}</div>
      <div class='bp-gradient-pill'></div>
    </div>
    """)

    # Section 1: PROJECT TEAM
    team_bar_html = _clean(f"""
    <div class='bp-section-bar'>
      <span class='bp-section-title'>PROJECT TEAM</span>
      <span class='bp-count-badge'>{len(students)}</span>
      <div class='bp-section-line'></div>
    </div>
    """)

    # 4 Student Cards in 1 Row
    student_cards_html = "".join(_student_card(s) for s in students)
    students_grid_html = f"<div class='bp-students-row'>{student_cards_html}</div>"

    # Section 2: UNDER THE GUIDANCE OF
    guide_section_html = ""
    if guides:
        guide_bar_html = _clean("""
        <div class='bp-section-bar'>
          <span class='bp-section-title' style='color: #94A3B8;'>UNDER THE GUIDANCE OF</span>
          <div class='bp-section-line'></div>
        </div>
        """)
        guide_card_html = "".join(_guide_card(g) for g in guides)
        guide_section_html = _clean(f"""
        {guide_bar_html}
        <div class='bp-guide-center'>
          {guide_card_html}
        </div>
        """)

    full_html = _clean(f"""
    <div class='bp-wrapper'>
      {header_html}
      {team_bar_html}
      {students_grid_html}
      {guide_section_html}
    </div>
    """)

    st.markdown(CSS, unsafe_allow_html=True)
    st.markdown(full_html, unsafe_allow_html=True)
