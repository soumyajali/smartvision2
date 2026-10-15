# SmartVision Mobile App Repair Report (October 2026)

Branch: `mobile-repair` (base commit `845b9dc "Resolved errors"`, github.com/soumyajali/SmartVision).

> **Important:** the environment used for this work could not download the
> Flutter SDK, pub.dev packages, Google Maven or the Android SDK (network
> policy). `flutter pub get / analyze / test / build apk` were therefore
> **not run** and **no APK is included**. Everything that could be verified
> without the Flutter toolchain was verified (see section G). Run the commands in
> section H on your Mac to build the APK.

---

## A. Root-cause analysis

### Object detection failed in the installed APK (definitive cause)

`assets/models/yolov8n.tflite` has a **channels-first** input tensor:

| Tensor | Shape | Type |
|---|---|---|
| input | `[1, 3, 320, 320]` (NCHW) | float32 |
| output | `[1, 84, 2100]` (4 box + 80 class scores, channels-first) | float32, boxes normalised 0..1 |

The old `OnDeviceAiService.initialize()` only accepted channels-last input
(`input.shape[3] == 3`). It therefore threw
`Unsupported YOLOv8n input tensor: shape=[1, 3, 320, 320]` at start-up. The model
never loaded, so **every** image, live-camera and video detection failed.
The model itself works: running it in Python on the bundled samples finds cars,
cats, cups, people, scissors and knives.

### Secondary detection problems

1. **Live mode used `takePicture()` every 750 ms.** Each call captured a
   full-resolution JPEG (with shutter latency), then decoded and converted it
   pixel-by-pixel **on the UI thread**. The UI janked and detection reached at
   most about 1 frame per second.
2. **Boxes were misaligned.** The preview was scaled to *cover* the screen
   (`Transform.scale`, cropped), while the boxes were normalised to the
   uncropped photo. Images picked from the gallery were also drawn over the
   live preview instead of over the picked image.
3. **Any single frame error stopped detection permanently.**
4. **Camera lifecycle.** The camera was never released when the app went to
   the background, and was not re-initialised on resume (`initialize()`
   returned early), so the preview froze after switching apps. On first launch
   Android reports the permission as "denied" (not "undetermined"), so the
   camera screen showed "permission denied" instead of asking for permission.
5. **Inputs were stretched** to 320×320 instead of letterboxed as Ultralytics
   does. This affected accuracy on wide or tall images.

(Correction to an earlier message: EXIF rotation was **not** a bug. image 3.3.0
already applies JPEG orientation while decoding. `bakeOrientation` is kept as
a harmless safeguard.)

### Other mobile defects found

- **Drowsiness monitor:**
  - It used the **back** camera at 1 frame per second, with an alert after 15
    consecutive "closed" frames, so an alert needed about **15 seconds** of
    closed eyes. (The website uses EAR at video frame rate, about 0.5 s.)
  - It also used `takePicture`, with the shutter firing every second.
- **Navigation:**
  - Only five bottom tabs plus a partial drawer. Research Evaluation, AutoML
    and Voice Assistant had no mobile screens.
  - Every screen used `go`, so the Android back button exited the app from
    any page.
- **Duplicate app bars:** each screen had its own `AppBar` inside the shell
  `AppBar`.
- **History:** normalised (0..1) box coordinates were printed as pixel values
  ("X: 0, Y: 0"), and confidence was labelled "MATCH".
- **OCR screen:**
  - "Camera" competed with the shared camera stream.
  - The labels "EasyOCR" and "18 languages" were wrong: OCR is ML Kit, and 14
    languages are supported.
  - Edits to the extracted text were ignored by translate and summarise.
- **No backend connectivity:** the app never talked to the FastAPI server
  (README: "does not call the FastAPI backend"), so face identity, the
  server-side chatbot and dataset information were unreachable.

### Backend bug found while testing (affects the mobile API)

`POST /detect` ran `subprocess.Popen(["afplay", ...])` whenever a knife or
scissors was detected. `afplay` exists only on macOS, so on any other host the
request returned **HTTP 500** instead of the detections. This was reproduced
on the original code. It is fixed in `ai_server.py`; the siren is still played
when `afplay` is available.

---

## B. Implementation summary

**Inference pipeline** (`lib/services/yolo_codec.dart`, `on_device_ai_service.dart`)
- **Tensor layouts:** supports NCHW and NHWC float32 inputs and channels-first
  or channels-last YOLOv8 outputs, with normalised or pixel boxes. These are
  validated at load time, with clear errors.
- **Letterboxing** matches Ultralytics: aspect preserved, padding value 114.
  Boxes are mapped back to the original image (normalised 0..1).
- **NMS** is class-agnostic, matching `/detect` (`agnostic_nms=True`), and
  applies the confidence threshold, IoU and max-detections settings.
- **Background isolate:** decoding, pre-processing, inference and NMS run in a
  background isolate that shares the interpreter by address. If the isolate
  cannot start, inference falls back to the main isolate.
- **Live camera** uses the **image stream** (YUV420 on Android, BGRA on iOS)
  at `ResolutionPreset.medium`. Frames are rotated by the sensor orientation
  and letterboxed straight into the tensor. Only one frame is processed at a
  time; the rest are dropped.
- **Timings:** real pre-processing, inference and NMS times are measured
  per call. FPS is measured from completed inferences and is never invented.

**Camera** (`camera_service.dart`)
- **Ownership:** screens acquire and release the camera, so it is open only
  while a camera screen is visible.
- **Lifecycle:** the camera closes on pause and reopens on resume, and the
  stream listener survives camera switches.
- **Permissions:** permission is requested on first use; a permanently denied
  permission leads to an "Open settings" prompt.
- **Camera selector:** back, front and external cameras.

**Correct overlay** (`detection_overlay.dart` → `DetectionFrame`)
- The preview or still image is shown at its real aspect ratio, without
  cropping, and boxes are drawn in the same box.
- Front-camera boxes are mirrored.
- Hazard boxes (knife or scissors) are drawn in red. These are the same hazard
  classes as the backend.

**Dashboard (redesigned)**
- Header: "Smart Vision Dashboard" / "Real-time object detection and tracking".
- Real status pills, plus tiles for model, cameras, and detections saved today
  and in total.
- Live Detection panel:
  - camera preview and camera selector
  - **Start / Stop Detection** (website-style cyan → purple gradient)
  - **Upload** and **Capture**
  - measured status, FPS, resolution and inference time
  - loading, permission-denied, error and empty states
- Detection Summary: count, classes, confidence bars and processing time.
- Collapsible **Detection Settings**: confidence, IoU and max detections.
  They are validated, saved, used by live, image and video detection, and
  re-run the current image when changed.
- Recent Activity, read from SQLite.
- "All Features" grid.

**Navigation**
- The **drawer** has the logo, "SMART VISION / Real-Time Object Detection",
  the six main features, **MORE** (4) and **AI TOOLS** (2), plus the existing
  extra mobile tools. It scrolls, highlights the selected destination,
  auto-closes and shows the status lights.
- **Bottom bar:** Dashboard, Detect, OCR, History.
- **Android back:** returns to the Dashboard; on the Dashboard it exits.
- **Shared app bar** on every screen: menu, branding, page title, real
  **AI / API** status lights (tap for details) and a settings shortcut.

**Backend connectivity** (`core/config/api_config.dart`, `services/backend_service.dart`)
- One central configuration: the URL saved in the app, else
  `--dart-define=SMARTVISION_API_URL=...`, else (debug builds only)
  `http://10.0.2.2:8000` for the emulator, else not configured.
- Real `GET /health` polling every 20 s, with latency.
- Clear error hints: localhost on a phone, `--host 0.0.0.0`, firewall,
  timeouts.
- No keys are in the app. No silent fallback to fake results.

**Visual identity**
- Dark navy / midnight surfaces (website sidebar `#121A3D`).
- Cyan `#38BDF8` and blue `#3B82F6` highlights, restrained purple `#8B5CF6`.
- White text with blue-grey secondary text (`#B8C7E5`), green status colours.
- Thin blue borders, rounded cards, and the real `assets/logo.png`.

---

## C. Files changed

**New**
- `lib/services/yolo_codec.dart`: pure-Dart YOLO pre/post-processing (unit tested)
- `lib/models/camera_frame.dart`: sendable camera frame, YUV420 → NV21 for ML Kit
- `lib/services/backend_service.dart`, `lib/core/config/api_config.dart`
- `lib/services/alert_sound_service.dart` (+ `assets/sounds/siren.wav`, a copy of the website siren)
- `lib/services/voice_input_service.dart`, `lib/services/assistant_brain.dart`
- `lib/core/navigation/app_destinations.dart`
- `lib/widgets/sv_ui.dart`, `sv_app_bar.dart`, `detection_panels.dart`
- `lib/screens/research/research_evaluation_screen.dart`
- `lib/screens/automl/automl_screen.dart`
- `lib/screens/voice_assistant/voice_assistant_screen.dart`
- `test/yolo_codec_test.dart` (includes a real-model golden test in `test/fixtures/`), `test/assistant_brain_test.dart`
- `MOBILE_APP_REPAIR_REPORT.md`, `.env.example`, `MOBILE_REPAIR_CHANGES.diff` (full text diff of this repair against commit `845b9dc`)

**Rewritten**
- `lib/services/on_device_ai_service.dart`, `camera_service.dart`
- `lib/controllers/detection_controller.dart`
- `lib/widgets/main_layout_shell.dart`, `detection_overlay.dart`
- `lib/screens/home/home_screen.dart`, `camera_detection/…`, `face_recognition/…`, `drowsiness/…`
- `lib/main.dart`, `lib/app.dart`, `test/widget_test.dart`

**Modified**
- Screens: settings (backend server and siren), OCR, video review, chatbot, history, hazard alerts, find object, about, analytics
- Theme and colours, `models/detection_history.dart`, `models/detection_result.dart`, `services/database_service.dart`, `services/speech_service.dart`, `pubspec.yaml` (adds `assets/sounds/`; **no new packages**)

**Android**
- `MainActivity.kt`: speech-recognizer channel; the video-frame channel is kept.
- `AndroidManifest.xml`:
  - label "Smart Vision"
  - speech-intent `<queries>`
  - camera feature not required
  - removed the unused `RECORD_AUDIO` permission (the system speech dialog
    records the audio)

**Backend (backward compatible)**
- `ai_server.py`:
  - `afplay` crash fix
  - new `GET /system/info` and `GET /dataset/summary`
  - `/health` unchanged
- `ai/chatbot/smart_assistant.py`: removed the hard-coded "Camera Stream:
  1080p / 30 FPS" claim and the "I am actively monitoring the camera feed"
  claim. This changes wording only; the website and mobile app use the same
  text.

**Not touched:** the website UI (`app.py`), all models, weights, datasets,
notebooks, and the other folders (`app/`, `android_app/`).

---

## D. Feature parity (all 12 website destinations)

Every destination has its own route, drawer item and screen. "Verified"
means it was checked outside the phone; on-device behaviour is untested
(see G).

| # | Destination | Mobile implementation | Status |
|---|---|---|---|
| 1 | Dashboard | Redesigned: live panel, summary, settings, recent activity, feature grid | Implemented · device test blocked |
| 2 | Fast Video Review | Any of 80 classes, 1/2/5 fps sampling, progress/cancel, timestamps, presence %, tap-to-seek overlay, JSON export | Implemented · device test blocked. *Reference-image (face/appearance) search is website-only: it needs `face_recognition`/embedding models that are not bundled.* |
| 3 | OCR | ML Kit image/camera/video OCR, progress/cancel, copy, **separate** Translate (14 languages) and Summarize buttons, read aloud | Implemented · device test blocked |
| 4 | Face Recognition | On-device face detection; **Recognize / Register via the server** (`/face/recognize`, `/face/register`, YuNet+SFace); no identity guessing on the phone | Implemented · server face models could not be downloaded here |
| 5 | Object Detection | Live camera + photo + **video** detection with timeline | Implemented · pipeline verified against the real model |
| 6 | Drowsiness Monitor | Front-camera stream, ML Kit eye-open probability, time-based alert (default 1.0 s), siren + speech, video analysis | Implemented · device test blocked |
| 7 | Research Evaluation | **Real on-device benchmark** on the bundled samples, plus the website's static comparison figures, clearly labelled as reported (they are hard-coded and marked "Mock Data" in `app.py`) | Implemented · device test blocked |
| 8 | AutoML & Dataset Pipeline | Read-only, like the website: storage, splits, sources, weights and classes from `GET /dataset/summary` | Endpoint verified · app device test blocked |
| 9 | History | Existing SQLite history (fixed box/confidence display) | Implemented · device test blocked |
| 10 | Settings | Voice, detection thresholds (persisted), siren, translation language, **backend server URL + test**, storage, permissions | Implemented · device test blocked |
| 11 | Vision Chatbot | Server assistant (`/chatbot/query`) with the phone's detections as context; on-device answers when offline; shows which engine answered | Endpoint verified · app device test blocked |
| 12 | Voice Assistant | Android speech recognizer → same commands as the website (open pages, announcements on/off, reset) + feature/result questions + server fallback; answers spoken via TTS; typed input fallback | Implemented · device test blocked |

Extra mobile tools kept: Find My Item, Hazard Alerts, Analytics, About.

---

## E. Detection verification

**Pipeline:**
1. Flutter screen
2. `DetectionController`
3. `OnDeviceAiService`, running in the background isolate:
   - decode (or rotate the YUV frame)
   - letterbox
   - NCHW float tensor
   - TFLite `yolov8n.tflite`
   - `[1,84,2100]` output
   - agnostic NMS
   - normalised boxes
4. `DetectionFrame` overlay, at the same aspect ratio as the shown image

**Verified here (Python, same model file):**
- **Decoder port.** A line-by-line Python port of the Dart letterbox and
  decoder was run on 5 project images. It gave the same detections as an
  independent OpenCV letterbox + `cv2.dnn.NMSBoxes` reference. Boxes were
  rendered on `test_image.png` and line up with the cat, cup, person and table.
- **Rotation mapping.** The YUV420 rotation mapping (0/90/180/270, planar and
  semi-planar) reproduces the upright reference image. The mean error is
  0.024, the chroma-subsampling level.
- **Golden fixture.** `test/fixtures` stores the real model output for
  `test_image.png`. `test/yolo_codec_test.dart` checks that the Dart decoder
  reproduces it.

**Model limits (not bugs):**
- YOLOv8n at 320×320 is a small model: small or distant objects are often
  missed.
- On `office.jpg` it labels the knife as "scissors" (0.77). The server's
  `yolov8m.pt` correctly says "knife" (0.92).
- Better mobile accuracy needs a 640-input export, or a bigger or fine-tuned
  model. That is retraining or re-export, not a code fix.

---

## F. Website protection

**Website checks**
- **All 12 website pages render without exceptions.** Each was run
  headlessly with Streamlit `AppTest`, with every page selected in turn.
- **Browser check:** the Live Detection dashboard was loaded in Chromium and
  captured as a screenshot.

**Python test suites**
- Ran `test_backend`, `test_voice_interaction`, `test_distance_estimation`,
  `test_chatbot_and_assistant` and `test_face_service`.
- **Original code:** 32 passed / 13 failed.
- **Updated code:** 32 passed / 13 failed. The same 13 fail on both.
- All 13 failures are face-recognition tests. The YuNet/SFace model download
  (GitHub LFS) is blocked in this sandbox, so this is environmental.

**API contract**
- `/health` still returns exactly `{"status": "healthy"}`.
- `/detect` response format is unchanged. Hazard images now return 200
  instead of 500 on non-macOS hosts.

---

## G. Build and test results (actual)

| Command / check | Result |
|---|---|
| `flutter pub get`, `flutter analyze`, `flutter test`, `flutter build apk --debug/--release` | **Not run.** SDK, pub.dev and Android SDK hosts are blocked here |
| Dart syntax check of all 54 `lib/` + `test/` files (tree-sitter Dart grammar) | 0 syntax errors |
| Independent API review against package sources (Flutter 3.47, camera 0.10.6, tflite_flutter 0.12.1, image 3.3.0, go_router 12.1.3, ML Kit) | No compile errors found. Reported issues fixed: keep-alive, dispose race, mounted checks, isolate error handling, const lints |
| Backend endpoint smoke test (original vs updated) | `/health` and `/summarize` identical. `/detect` hazard images fixed (500 → 200). `/chatbot/query` 200. New `/system/info` and `/dataset/summary` 200 |

**Requested test list:**

| # | Test | Result |
|---|---|---|
| 1 | App launches | **Blocked** (no SDK/device) |
| 2 | Dashboard displays | **Blocked** |
| 3 | Drawer opens and scrolls | **Blocked** (widget test written: `test/widget_test.dart`) |
| 4 | All 12 destinations accounted for | **Pass** (static: routes, drawer entries, screens; unit test written) |
| 5 | Screens open | **Blocked** |
| 6 | Backend status accurate | Server side **Pass** (`/health`); app side **Blocked** |
| 7 | Gallery selection | **Blocked** |
| 8 | Camera capture | **Blocked** |
| 9 | Image detection returns real predictions | Model + decoding **Pass** (Python, same model); on device **Blocked** |
| 10 | Boxes align | Reference rendering **Pass**; on device **Blocked** |
| 11 | Live start/stop | **Blocked** |
| 12 | Video detection | **Blocked** |
| 13 | OCR | Backend EasyOCR test **Pass**; ML Kit on device **Blocked** |
| 14 | Translation / summarization | Summarize algorithm = backend `/summarize` (**Pass** server side); ML Kit translation **Blocked** |
| 15 | Face recognition | **Blocked** (server face models not downloadable here; on-device detection untested) |
| 16 | Drowsiness | **Blocked** |
| 17 | Research Evaluation | **Blocked** |
| 18 | AutoML & Dataset | Endpoint **Pass**; app **Blocked** |
| 19 | History / Settings | **Blocked** |
| 20 | Chatbot / Voice | Server chatbot + Python assistant tests **Pass**; app **Blocked** |
| 21 | Permission denial handled | **Blocked** (code paths implemented) |
| 22 | Backend disconnection handled | **Blocked** (code paths implemented) |
| 23 | Invalid files handled | Server **Pass** (400 on invalid image); app **Blocked** |
| 24 | Website still works | **Pass** |
| 25 | APK installs and launches | **Blocked** |

---

## H. Build, install and backend setup

**Build the APK (on your Mac):**

```bash
cd SmartVision                    # project root (pubspec.yaml is here)
flutter --version                 # needs Flutter 3.47+ / Dart 3.13+ (pubspec.lock)
flutter pub get
flutter analyze
flutter test
flutter build apk --debug         # build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release       # build/app/outputs/flutter-apk/app-release.apk
# optional: bake in the server URL
flutter build apk --release --dart-define=SMARTVISION_API_URL=http://192.168.1.20:8000
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

**Run the backend (optional, for face identity, server chatbot and AutoML):**

```bash
pip install -r requirements.txt
uvicorn ai_server:app --host 0.0.0.0 --port 8000
```

**Connect the phone to the backend:**
- Find the Mac's LAN IP (System Settings → Network) and allow incoming
  connections on port 8000 in the macOS firewall.
- In the app, go to **Settings → Backend Server**, enter
  `http://<LAN-IP>:8000` and tap **Save & test**.
- The Android emulator uses `http://10.0.2.2:8000`.

**First run on the phone:**
- The camera permission is requested when a camera screen opens.
- ML Kit translation downloads its language models once, so it needs
  internet the first time.
- Voice input uses the phone's speech service (may need Google app / internet).

---

## I. Remaining blockers and unverified items

1. **No APK and no Flutter build or test run here.** The toolchain hosts are
   blocked. Compile errors are still possible even after syntax and API review.
   Run `flutter analyze` first and send me the output if anything fails.
2. **All camera, ML Kit, TTS and speech behaviour is untested on a real
   phone.** Two things to check in particular:
   - Front-camera box mirroring.
   - Live FPS on your device (expect roughly 5–15 inferences/s for YOLOv8n
     320 on mid-range phones; this is an estimate, not measured).
3. **Face identity needs the backend** and its YuNet/SFace models. These
   download on first start from GitHub; that was blocked here.
4. **Website-only features:**
   - Reference-image video search.
   - Object tracking IDs.
   - Email/Telegram alerts (still marked "Mock" in the website itself).
   - Restricted-area analytics.
5. **Large files kept as-is.** The datasets (`datasets/`,
   `smart vision detection/`, `classification/`) and weights are included in
   the ZIP. Dataset *image* folders under `datasets/custom_objects/images/`
   are not in the repository (`.gitignore`), so `/dataset/summary` reports
   their counts as missing.
