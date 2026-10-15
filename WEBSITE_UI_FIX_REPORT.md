# Smart Vision Website: UI Fix Report (October 2026)

**Scope:** website frontend only (Streamlit: `app.py`, `ui/`, `.streamlit/config.toml`, and the website-only 3D HUD component).

**Not modified:** the Flutter mobile app (`lib/`, `android/`, `app/`, `web/`), backend APIs (`ai_server.py`, `services/`), AI models, and detection logic.

## Root causes found

| Problem | Cause | Fix |
|---|---|---|
| Labels nearly invisible on the navy background | `.streamlit/config.toml` used the **light** base theme with `textColor = "#172033"`. Every built-in widget (field labels, slider values, dropdown text and menus, tooltips, tables, charts) was drawn in dark text. A second, legacy light stylesheet in `app.py` (`get_theme_css`) set white cards and `#172033` / `#64748B` text, and `ui/theme.py` partly overrode it. | The config now uses the dark base with your palette. `get_theme_css` was rewritten to use the palette variables. Inline `#64748b`, `#0f172a` and `#334155` text colours were replaced with the palette. |
| Rectangle around the logo | (1) A global CSS rule `img, video, canvas { border: 1px solid #E2E8F0; border-radius: 16px }` drew a light frame round the sidebar logo. (2) `logo.png` has an opaque navy background, which shows as a box on a lighter surface. The splash screen also added a rounded box and a rectangular drop shadow. | The border rule now applies only to images in the page content, not the sidebar. The logo is rendered as plain HTML with no border, shadow or background, and with `mix-blend-mode: lighten`, so its navy background merges into the sidebar while the artwork is unchanged. The splash adds a soft radial edge mask. **The original `logo.png` was not edited.** |
| Emoji icons | Emoji characters in navigation labels, siren controls, toasts, tabs, headings, buttons and status text | Replaced with Material Symbols. This is the icon font Streamlit already bundles and renders in widget labels (`:material/name:`), so one icon set is used everywhere. |

## Icon library

Material Symbols Rounded is used instead of Lucide.
- Streamlit widget labels (navigation radio, buttons, toggles, tabs, expanders, toasts) can only show emoji or Streamlit's bundled Material Symbols. Inline SVG (Lucide) cannot be placed inside those labels.
- Using Material Symbols everywhere keeps a single, consistent icon set at a fixed 20 px size.
- The only SVG icons are the two buttons inside the speech-player iframe, which cannot load the icon font.

## Palette

The palette is defined once as CSS variables in `ui/theme.py` and mirrored in `.streamlit/config.toml`:

| Role | Colour |
|---|---|
| Background | `#0B1228` |
| Sidebar and cards | `#111B36` |
| Primary text | `#F1F5F9` |
| Secondary text | `#B8C4D9` |
| Accent | `#38BDF8` |
| Success | `#34D399` |
| Borders | `#263B61` |

Measured contrast ratios (WCAG AA requires 4.5:1 for normal text):

| Pair | Ratio |
|---|---|
| Primary text on background | 16.9:1 |
| Primary text on cards | 15.5:1 |
| Secondary text on cards | 9.7:1 |
| Accent on cards | 7.9:1 |
| Success on cards | 8.9:1 |
| Disabled button text (`#8A99B8`) | 6.5:1 |
| Primary button text (`#0B1228` on `#38BDF8`) | 8.7:1 |

## Changes by area

**Sidebar**
- The logo has no frame and is centred, with "SMART VISION" and "REAL-TIME OBJECT DETECTION" below it.
- Workspace, Help and Alert & Siren Controls all use the same section heading. Alert & Siren Controls also has a divider line above it.
- Every navigation item spans the full width.
- Icons are aligned at 20 px.
- The active item is shown by its accent border, inset bar and bold label.
- "Model Info" now shows the loaded weights file and the installed Ultralytics version. Previously it showed the hard-coded text "YOLOv8 / 8.1.0".

**Top navigation:** icons replace emojis, and the selected tab has bold text and an accent-coloured icon.

**Live Detection (Dashboard)**
- **Header values are real.** Before, the header always showed "Active" and "1280 x 720".
  - System Status shows Waiting for input, Running, Stopped or Camera error.
  - FPS is measured from the last inference, or "—" when nothing has run.
  - Resolution is the actual image size, or "—".
- **Detection settings are now used.** IoU Threshold and Max Detections are passed to the model; before, they were displayed but ignored. Confidence works as before.
- **Start Detection / Stop Detection** now actually start and pause detection. Detection is on by default, which matches the old behaviour.
- **Capture** saves the current result image to `detections/capture_<time>.jpg`.
- **Record and Fullscreen** previously did nothing. They are now shown as disabled, with a tooltip explaining why. Fullscreen is still available from the image's own expand button.
- **Camera help:** a message explains what to do when the camera preview is black or blocked (browser permission, another app using the camera, localhost/https requirement, or switching to Upload Image). An image that cannot be read now shows an error instead of failing silently.
- **Recent Detections** shows "Confidence unavailable" instead of the previous invented 90% default.

**Other pages**
- **Empty boxes removed:** the opening-tag-only `card-box` wrappers no longer draw empty bars on Fast Video Review, Face Recognition, Drowsiness Monitor and Settings.
- **Settings:** the broken "** Email Alerts**" / "** Telegram Alerts**" headings now render correctly as bold text with icons.
- **Object Detection:** detected-object badges now use dark text on green for contrast.
- **Research Evaluation and AutoML:** dark text and light chips were changed to the palette.
- **Voice Assistant:** the light-themed cards, prompt buttons and recorder panel now use the dark palette. The speak and stop buttons use SVG icons.
- **Drowsiness Monitor:** the video overlay text "🟢 Awake" (OpenCV cannot draw emoji) is now "Awake".
- **Buttons:** primary buttons are a solid accent with dark text, secondary buttons are outlined, and disabled buttons are dashed and grey. Focus rings are visible. These styles also apply to buttons wrapped in a tooltip, which the old `.stButton > button` selectors missed.

## Files changed

- `.streamlit/config.toml`: dark theme with the palette, including the sidebar.
- `ui/theme.py`: palette variables, sidebar, navigation, logo, buttons and Live Detection component styles.
- `app.py`: legacy CSS rewritten, logo rendering, navigation icons, siren controls, Live Detection page, emoji removal, inline colours.
- `ui/components.py`: icon helpers instead of glyph characters.
- `ui/builders.py`: icons instead of emoji HTML entities, and palette colours.
- `ui/splash.py`: logo without the box or shadow.
- `core/ui_3d_component.py`: removed the "⚠" from a status string.

## Tests performed

| Test | Result |
|---|---|
| `streamlit run app.py`, every page opened from the navigation in Chromium | Pass, 13 pages |
| Streamlit AppTest render of all 13 pages | Pass, no exceptions |
| Live Detection flow: upload an image, see real status, FPS and resolution, Capture saves a file, Stop then Start | Pass |
| Emoji scan of the website source (`app.py`, `ui/`, website JS/HTML/CSS, 3D HUD) | 0 remaining |
| Automated contrast scan of the rendered text on all 13 pages | No real failures. The only flags are slider value labels, where the scanner measured against the slider thumb instead of the page background; the labels are readable in the screenshots. |
| Logo: sidebar and splash | No frame |
| Responsive: 1440 px, 820 px and 390 px (sidebar drawer) | Pass |
| Python tests | 102 passed, 18 failed — the same as before this change. The 13 face-model tests need a model download that is blocked in this environment, and 5 integration tests need a running API server. |

## Remaining issues

- **Model download warning banner:** the red "Failed to download pretrained weights…" banner seen in the test screenshots comes from this sandbox having no internet. It is not part of the UI changes.
- **AI-generated text:** chatbot and voice answers that the AI writes can still contain emoji. That is generated content from the shared backend (`ai/chatbot/smart_assistant.py`), not an interface icon, and the backend was out of scope.
- **Research Evaluation figures:** this page still shows the comparison figures hard-coded in `app.py` (marked "Mock Data" in the source). Only their colours were changed in this UI-only task.
