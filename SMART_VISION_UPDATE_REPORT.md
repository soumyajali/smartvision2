# Smart Vision – Update Report (October 2026, round 2)

This report covers the second update of the Smart Vision project: Flutter app
redesign and completion, Fast Video Review by reference, face registration,
Research Evaluation, AutoML & Dataset Pipeline, chatbot knowledge, label
clean-up, Meet the Builders, configuration, website protection and testing.
The first round (detection repair, navigation, backend connectivity) is
described in [MOBILE_APP_REPAIR_REPORT.md](MOBILE_APP_REPAIR_REPORT.md).

**Important:** the Flutter SDK, pub.dev, Google Maven and the Android SDK were
unreachable from the build environment. **No APK was built, and
`flutter analyze` / `flutter test` could not be run.** The Dart code was
checked with a full-grammar Dart parser (63 files, 0 syntax errors) and an
independent line-by-line review against the exact package sources. See
section 15 for the test table and section 16 for the commands to run locally.

---

## 1. Summary

| Area | Result |
|---|---|
| Dashboard and theme | Navy / cyan / purple theme. Status values are real; FPS, resolution and processing time are shown only when they were actually measured. |
| Navigation | Drawer with main features, **MORE**, **AI TOOLS** and mobile tools, plus a bottom bar (Dashboard, Detect, OCR, History). All 13 website destinations, including **Meet the Builders**, are reachable. |
| Fast Video Review | New **Reference (server)** mode. It uploads a target video and a reference image or video, runs the website's matching algorithm on the backend, and shows real matching frames with timestamp, frame number and similarity. Tapping a match seeks the video. |
| Face registration | Recognize / Register / People tabs. Registration uses real SFace embeddings and the shared `known_faces/` folder. People can be renamed or deleted. Labels are "Registered Person: Name" or "Unknown Face", never a forced match. |
| Research Evaluation | View-only. Shows only metrics computed by the project's evaluation scripts. mAP is reported as unavailable because no validation results exist. Includes JSON export and a report viewer. The website's mock figures were removed from the app. |
| AutoML & Dataset Pipeline | Storage, Datasets and Training tabs, all measured or read from real files. Phone, backend and cloud storage are kept separate, and cloud shows "Unavailable". Never trains. |
| Chatbot knowledge | Maintainable Markdown guide (36 sections), BM25 retrieval in Python and a matching Dart port. 60 of 60 evaluation questions retrieve the correct section. No fine-tuning is claimed. |
| Promotional labels | "AI ready", "Neural Detection & Intelligent Vision" and similar labels replaced with factual text. |
| Meet the Builders | Website page and Flutter screen driven by one config file. Fields are photo, name, approved mobile and about. **No role field.** Placeholder profiles only, until real details are supplied. |
| Configuration | Single `ApiConfig`. No keys in the app. The backend reads keys from its own environment. |
| Website | All 13 pages render (Streamlit AppTest). The existing API contract is unchanged; new endpoints were only added. |
| APK | **Blocked** (toolchain unavailable). |

## 2. Inspection findings (before this round)

- Fast Video Review in the app could only search by object category. The website's reference-image/video search was not available.
- The face screen could detect faces and register them, but could not list, rename or delete people. Live detection never showed identities.
- Research Evaluation in the app reproduced hard-coded website figures that `app.py` marks as "Mock Data".
- The AutoML page used one summary endpoint. Storage was not separated by category or location, and splits were not read from the dataset YAML files.
- The chatbot had no knowledge of the application's own features, so it could not explain how to use them.
- Several labels claimed capabilities ("AI ready", "Neural Detection") rather than describing state.
- There was no Meet the Builders page.
- The design screenshots mentioned in the request were **not attached** (only the text prompt was). The design follows the written description.

## 3. Dashboard

`lib/screens/home/home_screen.dart`:
- Uses the navy/cyan/purple tokens from `lib/core/constants/app_colors.dart`.
- The model pill now reads "Detection model loaded / error / Loading model…".
- Metrics come from `DetectionController` (`measuredFps`, last outcome timings and frame size), and each is hidden until a real value exists.

## 4. Navigation

- `lib/core/navigation/app_destinations.dart` defines 13 website destinations in sidebar order, including `Meet the Builders` (`/builders`, MORE section), plus 4 mobile tools.
- `lib/widgets/main_layout_shell.dart` builds the drawer sections (main, MORE, AI TOOLS, MOBILE TOOLS) and the bottom bar.
- `lib/app.dart` registers the `/builders` route.
- The voice assistant understands "open meet the builders", "open builders" and "open team".

## 5. Fast Video Review – reference search

**Backend** (new, backward compatible; existing endpoints are unchanged):

| Endpoint | Purpose |
|---|---|
| `POST /video/reference_search` | Multipart fields: `video`, optional `reference` (image or video), `category`, `precision` (strict/balanced/tolerant), `sample_rate` (frames per second), `confidence`, `rotation`, `restrict_category`. Upload is streamed to disk in 1 MB chunks. Returns `job_id`. Errors: 400 for a bad extension or corrupt file, 413 above `SMARTVISION_MAX_UPLOAD_MB` (default 1024), 429 when 2 jobs are already running. |
| `GET /video/reference_search/{id}` | Status, progress, processed/total frames, matches so far, method, and reference summary. |
| `GET /video/reference_search/{id}/frames/{n}` | JPEG of matching frame *n*. |
| `DELETE /video/reference_search/{id}` | Cancel. |

**Algorithm.** `services/video_reference_search.py` reuses the website's matching logic:
- The score is 0.55 × MobileNetV2 cosine similarity + 0.45 × HSV-histogram correlation.
- Thresholds are strict 0.72, balanced 0.65 and tolerant 0.55. The colour score must be at least 0.5.
- YOLO tracking is used, and nearby hits are merged within 2 s.
- Faces use `face_recognition` when installed, otherwise SFace.
- Job files are kept in the system temp folder `smartvision_reference_jobs/`. Uploaded media is deleted after processing, and finished jobs expire after 2 h.

**App.** `lib/screens/video_review/reference_search_panel.dart`, opened from the **Reference (server)** segment:
- **Inputs:** choose the video to search (with an in-app preview player) and a reference image or reference video. Options are precision, frames per second, detection confidence, orientation, and a category filter that defaults to on, as on the website.
- **During the search:** upload progress, then server progress (frame x of y, matches so far). The search can be cancelled, and leaving the screen also cancels the server job.
- **Results:** a list of matches with the real frame thumbnail, timestamp, frame number and similarity percentage. Tapping a match seeks the video to that moment. "No matching frames" explains what to change, and **New search** starts again.
- **Errors and offline:** errors are shown as they occur, and an offline notice links to Settings. Results are saved to History.

**Verified (Python, `tests/test_mobile_api.py`):**
- The test video is built from the project's sample images.
- The knife reference matched at 4.0 s (similarity 0.99), and the cat reference matched at 6.0 s.
- A bicycle reference gives a genuine no-match. Category "cup" matches at 6 s and 9 s.
- A corrupt video and a bad extension both return 400.
- The reference-video case matches only with `restrict_category=false`. With the filter on, YOLOv8m labels the rotated reference frames "scissors", so nothing matches. This is documented in the app's switch subtitle.

## 6. Face registration and recognition

**Backend:**
- New endpoints: `GET /face/registered`, `DELETE /face/registered/{name}`, `POST /face/registered/{name}/rename` (409 if the new name exists), and `POST /face/recognize_all` (503 when the face models are unavailable).
- Existing `POST /face/register` and `/face/recognize` are unchanged.

**Storage location:**
- Registered photos are stored in the backend project folder `known_faces/<Name>/`. This is the same registry the website uses.
- SFace embeddings are rebuilt from those photos when the server starts and after every register, rename or delete. The YuNet and SFace model files are cached in `~/.cache/SmartVision/face_models` (`%LOCALAPPDATA%` on Windows).
- Deleting a person removes the folder and retrains, so that name can no longer be returned.

**Matching rule:**
- A name is given only when the cosine similarity is at least **0.363** and at least **0.05** above the next person.
- Otherwise the face is **Unknown Face**.

**App:**
- `lib/services/face_identity_service.dart` is shared by every screen.
- `lib/screens/face_recognition/face_recognition_screen.dart` has three tabs:
  - **Recognize** shows boxes labelled "Registered Person: X" or "Unknown Face".
  - **Register** validates the name, requires exactly one face (checked with on-device ML Kit), confirms before adding to an existing name, and reports success only after the server confirms.
  - **People** lists registered people with Rename and Delete dialogs.
- **Global recognition:**
  - When a person is detected and the server is online, Object Detection sends a JPEG of the frame every 2.5 s (live) or of the still image.
  - The returned identities are drawn on the overlay and listed under the metrics.
  - Results older than 4 s are dropped.

## 7. Research Evaluation (view-only)

`GET /evaluation/results` (in `services/project_insights.py`) parses the existing report files and returns only what was actually computed:

| Metric | Source | Value |
|---|---|---|
| Detection precision / recall / F1 (overall) | `tests/accuracy_conditions_report.json` | P 0.4815, R 1.0, F1 0.65 (TP 26, FP 28, FN 0), YOLOv8m. Also 12 per-scenario rows. |
| Server latency | benchmark JSON | avg 189.7 ms, p95 197.4 ms, 5.27 FPS (25 frames) |
| Distance estimation | distance report | MAE 0.046 m, mean relative error 2.13 % (14 measurements) |
| OCR | OCR report | CER/WER for clean, complex and degraded text |
| Chatbot model | model test report | Qwen2.5-0.5B-Instruct, 3/5 tests passed |
| mAP | — | **Not available**: no YOLO validation `results.csv` exists in the project |

`GET /evaluation/report/{name}` serves the report files from an allowlist.

**App** (`research_evaluation_screen.dart` + `server_evaluation_section.dart`):
- Loading, empty, offline and error states.
- Per-scenario list, sources with file timestamps, a report viewer, and JSON export via the share sheet.
- An optional on-device benchmark that measures this phone.
- The mock comparison card was removed. Nothing on this page starts training.

## 8. AutoML & Dataset Pipeline (view-only)

`lib/screens/automl/automl_screen.dart` has three tabs and a Refresh button:

- **Storage:**
  - **Backend** (`GET /storage/summary`): measured bytes and file counts per category (model weights, datasets, checkpoints, uploads, database, reports, other), with each file counted once. Also shows the largest files, server disk free space and the measurement time.
  - **This phone:** only the app's own folders (documents, support, cache, temp, database) are measured. Whole-phone storage is not reported, because Android does not expose a reliable value to apps.
  - **Cloud:** "Unavailable", because no cloud account is connected.
- **Datasets** (`GET /dataset/splits`):
  - Every YOLO `data.yaml` and class-folder dataset in the project.
  - Train, validation and test splits with image count, label files, annotations, size, percentage, path and format.
  - Missing splits show **Not configured**. Splits with labels but no images show "Labels present, image folder not on the server".
- **Training** (`GET /training/status`):
  - Active job: none, because the backend has no training job manager.
  - The real `runs/*/*/args.yaml` runs, marked "no results.csv" where applicable.
  - The chatbot LoRA metrics file (3 steps, val loss 2.49) and the model artifacts.

## 9. Chatbot knowledge (retrieval, not fine-tuning)

- **Knowledge source:** `knowledge/smartvision_knowledge.md`, 36 sections. Each section has a `keywords:` line, and its text uses the exact UI labels.
- **Build step:** `python scripts/build_knowledge_base.py` writes `knowledge/smartvision_knowledge.json` and `assets/knowledge/smartvision_knowledge.json`, which is bundled in the app.
- **Retrieval:** `ai/chatbot/knowledge_base.py` and `lib/services/knowledge_base.dart` use the same method:
  - BM25 with synonym and stem normalisation and a title-overlap bonus.
  - A question counts as being about the application when its best score is at least 2.5.
  - A short question that matches two sections almost equally gets a clarifying question.
  - A follow-up question uses the previous question as context.
- **Server answers:** `smart_assistant.py` passes the retrieved sections to the LLM as grounding when an LLM key is configured. Otherwise it returns the section itself with a "Source:" line.
- **App answers:**
  - The Vision Chatbot uses the bundled guide when the server is offline or fails.
  - The Voice Assistant uses the guide for feature questions.
  - Questions about the current scene are always answered from real detections.
- **Evaluation:** `python scripts/evaluate_chatbot.py` writes `knowledge/chatbot_evaluation.md`. It records the actual response to each of the 30 required questions and 30 paraphrases.
  - **60/60** retrieved the expected section.
  - "How do I upload a video?" gets a clarifying question.
  - The follow-up "and how do I translate it?" resolves correctly.
- **Python/Dart agreement:** `scripts/export_knowledge_expectations.py` plus `test/knowledge_base_test.dart` check that the Dart port returns the same sections and scores as Python.
- **No fine-tuning:** the LLM was **not** fine-tuned for this. The existing LoRA files are an earlier experiment and are reported only as files in AutoML → Training.

## 10. Promotional labels removed

| Where | Before | After |
|---|---|---|
| Drawer pill | AI ready / AI loading | Model loaded / Model loading |
| Dashboard pill | On-device AI ready / error | Detection model loaded / error |
| App-bar status lights | AI · API | Model · Server |
| Splash subtitle | Real-Time Neural Detection & Intelligent Vision | Real-Time Object Detection |
| About text | "intelligent … sentinel … biometric" | Factual feature list |
| Analytics empty state | "neural analytics" | "analytics" |

Real AI features were not removed. No such labels were found on the website (the "Ready" default was removed in round 1).

## 11. Meet the Builders

- **One config for both front ends:** `assets/builders/builders.json` (documented in `assets/builders/README.md`), with photos in `assets/builders/photos/`.
- **Website:** `ui/builders.py` provides a responsive grid. The "👥 Meet the Builders" entry is in the sidebar's secondary group.
- **App:** `lib/screens/builders/builders_screen.dart` provides the reusable `BuilderCard` and the `BuildersConfig` model, in the drawer's MORE section.
- **Subtitle:** "The team behind Smart Vision".
- **Fields:** photo, name, mobile and about only. **There is no role field.** The mobile number is shown only when `show_mobile` is `true` and a number is supplied.
- **Placeholders:** no names, numbers, biographies or photos were invented. The three entries are placeholders, shown as "Profile pending". To publish real profiles, fill in the JSON and add the photos.

## 12. API configuration and secrets

- `lib/core/config/api_config.dart` holds the server URL. The order of precedence is: the URL saved in Settings, then `--dart-define=SMARTVISION_API_URL=…`, then the emulator default in debug builds only, otherwise not configured.
- There are no API keys anywhere in `lib/` or `android/`. The backend reads `OPENAI_API_KEY` and `GEMINI_API_KEY` from its own environment.
- Note: `.env` is tracked in the original repository and contains only the placeholder value `your-api-key...`. It was left unchanged, and `.env.example` documents the variables. Do not commit a real key to `.env`.

## 13. Website protection

- No existing page, endpoint or response shape was removed or changed. `/health` still returns exactly `{"status": "healthy"}`, and the extra data lives in `/system/info`.
- Website changes in this round:
  - The Meet the Builders page and its sidebar entry.
  - Knowledge retrieval inside the chatbot. Answers for non-application questions are unchanged.
- Regression (Streamlit AppTest): all 13 pages render without exceptions. The builders page was also screenshotted at desktop and phone widths in Chromium.
- No destructive git commands were used and no files were deleted. Work was done on the branch `mobile-repair`.

## 14. Files changed in this round

**New (backend/website):**
- `services/video_reference_search.py`, `services/reference_search_jobs.py`, `services/project_insights.py`
- `ai/chatbot/knowledge_base.py`, `ui/builders.py`
- `knowledge/` (guide, JSON, evaluation)
- `scripts/build_knowledge_base.py`, `scripts/evaluate_chatbot.py`, `scripts/export_knowledge_expectations.py`
- `tests/test_mobile_api.py`, `tests/test_knowledge_base.py`, `tests/test_builders.py`
- `assets/builders/…`, `assets/knowledge/…`

**Modified (backend/website):** `ai_server.py` (new endpoints only), `ai/chatbot/smart_assistant.py`, `app.py` (builders page), `README.md`.

**New (Flutter):**
- `lib/screens/video_review/reference_search_panel.dart`
- `lib/screens/research/server_evaluation_section.dart`
- `lib/screens/builders/builders_screen.dart`
- `lib/services/knowledge_base.dart`, `lib/services/face_identity_service.dart`, `lib/services/frame_encoder.dart`
- `test/knowledge_base_test.dart`, `test/builders_test.dart`, `test/face_identity_test.dart`, `test/fixtures/knowledge_expectations.json`

**Modified (Flutter):**
- Screens: `video_fast_review_screen.dart`, `research_evaluation_screen.dart`, `automl_screen.dart`, `face_recognition_screen.dart`, `vision_chatbot_screen.dart`, `voice_assistant_screen.dart`, `home_screen.dart`, `splash_screen.dart`, `about_screen.dart`, `analytics_screen.dart`
- Services and controllers: `assistant_brain.dart`, `backend_service.dart`, `yolo_codec.dart`, `detection_controller.dart`
- Models and widgets: `detection_result.dart`, `detection_overlay.dart`, `detection_panels.dart`, `main_layout_shell.dart`, `sv_app_bar.dart`
- App setup: `app_destinations.dart`, `app.dart`, `main.dart`, `pubspec.yaml` (asset folders), `test/widget_test.dart`

The full diff against the original commit (both rounds) is in `MOBILE_REPAIR_CHANGES.diff`.

## 15. Test results (actual)

| # | Test | Result | Notes |
|---|---|---|---|
| 1 | `flutter pub get` | **Blocked** | pub.dev unreachable |
| 2 | `flutter analyze` | **Blocked** | no Flutter SDK. Replaced by a tree-sitter Dart parse (63 files, 0 errors) and an independent review against package sources (8 defects found and fixed) |
| 3 | `flutter test` | **Blocked** | no Flutter SDK. Tests were written: widget/navigation, knowledge base (Python/Dart agreement), builders, face identity, assistant, YOLO codec |
| 4 | `flutter build apk` | **Blocked** | no Flutter SDK, Android SDK or Google Maven |
| 5 | Install and run on a phone | **Blocked** | no APK and no device |
| 6 | Python: reference search, face registry API, storage/dataset/training/evaluation endpoints (`tests/test_mobile_api.py`) | **Pass** | 12/12 |
| 7 | Python: knowledge base, chatbot, voice (`tests/test_knowledge_base.py`, `test_chatbot*`) | **Pass** | 38/38 in the final run |
| 8 | Python: builders page (`tests/test_builders.py`) | **Pass** | 4/4 |
| 9 | Chatbot evaluation, 30 questions + 30 paraphrases | **Pass** | 60/60 grounded; responses recorded in `knowledge/chatbot_evaluation.md` |
| 10 | Full Python suite, server not running | 102 pass / 18 fail / 1 skip | 13 failures are face tests that must download YuNet/SFace (GitHub blocked here), the same failures as the unmodified project. 5 are integration tests that need a running server |
| 11 | Integration tests with `uvicorn ai_server:app` running | 4 pass / 1 **Fail** / 1 skip | `test_ocr_endpoint` exceeded the test's 15 s read timeout on this CPU-only sandbox. The server did return 200 OK afterwards |
| 12 | Live face identity (register → recognise → delete with real models) | **Blocked** | face model download blocked. Logic tested with monkeypatched storage |
| 13 | Website regression, all 13 pages (Streamlit AppTest) | **Pass** | no exceptions |
| 14 | Website builders page layout, desktop and phone (Chromium screenshots) | **Pass** | |
| 15 | Secrets scan of `lib/` and `android/` | **Pass** | no keys |

## 16. Remaining limitations and how to finish locally

- **Build the app on a machine with Flutter 3.47+ and the Android SDK:**
  ```bash
  flutter pub get
  flutter analyze
  flutter test
  flutter build apk --release   # optional: --dart-define=SMARTVISION_API_URL=http://<LAN-IP>:8000
  ```
  Please report any analyzer message. The code has not been compiled.
- **Face identity needs the backend and its model files.** On first start the server downloads YuNet and SFace, which needs internet.
- **Reference search runs on the server.** Videos are uploaded over the LAN, up to 1 GB by default.
- **Fill in the real builder details** in `assets/builders/builders.json`. Set `show_mobile: true` only with the builder's approval.
- **mAP stays "not available"** until a YOLO validation run (`results.csv`) is produced.
- **Design screenshots** were not received. Send them if the visual design should match them more closely.

## 17. Deliverable

`SmartVision_Updated_Project.zip` contains the complete updated project:
- All files tracked by git plus every new file, excluding `.git` and ignored build or cache folders.
- Model weights, datasets and assets are included. Nothing that was in the original project was removed.

Because the file is large, it is delivered as described in the delivery note that comes with it.
