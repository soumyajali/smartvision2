# SmartVision_Website_UI_Fixed.zip: contents

This archive contains the Smart Vision **website**: the Streamlit app, its UI
modules, theme, backend helpers that the website imports, website assets,
knowledge files and tests, with the UI fixes described in
`WEBSITE_UI_FIX_REPORT.md`.

It does not contain:

- **The Flutter mobile app** (`lib/`, `android/`, `app/`, `web/`, `macos/`,
  `pubspec.*`). It was not changed by this fix.
- **Training datasets** (`datasets/`, `classification/`,
  `smart vision detection/`, `dummy_classification_dataset/`) and training code.
- **Large YOLO weights.** They are unchanged; copy them from your existing
  project folder into the same place: `yolov8m.pt`, `yolov8n.pt`,
  `SmartVision_v3.pt`, `yolov8s-world.pt`, `weights/smartvision_best.pt`,
  `MobileNET_best_dummy.pth`, `yolov8n.tflite`.
  `MobileNET_best.pth`, which the website needs at start-up, is included.
  If no YOLO weights are present, Ultralytics downloads `yolov8n.pt` on
  first run, which needs internet.

To apply the fix to your existing project, copy these files over your project
folder; they replace only the website files. The UI changes themselves are in:
`.streamlit/config.toml`, `app.py`, `ui/theme.py`, `ui/components.py`,
`ui/builders.py`, `ui/splash.py` and `core/ui_3d_component.py`.

Run the website with:

    pip install -r requirements.txt
    streamlit run app.py
