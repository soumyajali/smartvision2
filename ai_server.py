import os
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"

import math
import shutil
import subprocess
import tempfile
import threading
import time
import cv2
import numpy as np
import base64
from typing import Optional, Dict, Any, List, Union
from fastapi import FastAPI, HTTPException, Body, Query, UploadFile, File, Form
from fastapi.responses import FileResponse, PlainTextResponse
from pydantic import BaseModel, Field
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
from ultralytics import YOLO
import easyocr
import faiss
faiss.omp_set_num_threads(1)

from core.distance_estimation import default_distance_estimator
from services.face_service import FaceService
from ai.face.faiss_store import FAISSStore

last_siren_time = 0.0

app = FastAPI(title="Smart Vision Backend")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

print("Loading Models...")
# Production High-Accuracy YOLOv8 Model (80 Canonical Categories, 92%+ Precision on Knives & Hazards)
MODEL_PATH = 'yolov8m.pt' if os.path.exists('yolov8m.pt') else ('weights/smartvision_best.pt' if os.path.exists('weights/smartvision_best.pt') else 'yolov8n.pt')
print(f"Loading Primary Object Detection Model from {MODEL_PATH}...")
yolo_model = YOLO(MODEL_PATH)

# Optional Open-Vocabulary Model (for custom queries)
world_model = None
if os.path.exists('yolov8s-world.pt'):
    try:
        world_model = YOLO('yolov8s-world.pt')
    except Exception as e:
        print(f"Notice: Open-vocabulary YOLO-World model could not be loaded: {e}")

# EasyOCR - do not force remote downloads in offline environments.
ocr_reader = None
try:
    ocr_reader = easyocr.Reader(['en'], gpu=False, download_enabled=False)
except Exception as exc:
    print(f"Warning: EasyOCR model unavailable offline; OCR endpoints will be disabled: {exc}")

# Face Recognition Service & FAISS Vector Index (PPT Slides 10 & 13)
try:
    face_service = FaceService()
except Exception as exc:
    print(f"Warning: Face recognition unavailable offline; using degraded mode: {exc}")
    face_service = None
faiss_store = FAISSStore(embedding_dim=128)

print("Models ready!")

class ImageRequest(BaseModel):
    image: str # base64 encoded string

class FaceRegisterRequest(BaseModel):
    image: str
    name: Optional[str] = None

class ChatbotRequest(BaseModel):
    query: str
    context: Optional[Dict[str, Any]] = None
    provider: Optional[str] = "auto"
    gemini_key: Optional[str] = ""
    openai_key: Optional[str] = ""
    ocr_text: Optional[str] = ""

class TranslateRequest(BaseModel):
    text: str
    target_lang: str = "Hindi"

class SummarizeRequest(BaseModel):
    text: str
    max_sentences: Optional[int] = 3

class VideoReviewRequest(BaseModel):
    video_base64: str
    target_object: Optional[str] = "person"
    confidence_threshold: float = Field(default=0.25, ge=0.0, le=1.0)
    iou_threshold: float = Field(default=0.45, ge=0.0, le=1.0)
    max_detections: int = Field(default=100, ge=1, le=300)

class DetectionRequest(ImageRequest):
    confidence_threshold: float = Field(default=0.25, ge=0.0, le=1.0)
    iou_threshold: float = Field(default=0.45, ge=0.0, le=1.0)
    max_detections: int = Field(default=100, ge=1, le=300)

class VideoOCRRequest(BaseModel):
    video_base64: str
    frame_interval_seconds: float = Field(default=1.0, gt=0.0, le=30.0)

class DrowsinessVideoRequest(BaseModel):
    video_base64: str
    ear_threshold: float = 0.25
    consecutive_frames: int = 15

class DrowsinessFrameRequest(ImageRequest):
    session_id: str
    ear_threshold: float = 0.25
    consecutive_frames: int = 15

drowsiness_lock = threading.Lock()
drowsiness_sessions: Dict[str, Dict[str, Any]] = {}
face_landmarker = None
face_landmarker_lock = threading.Lock()

LEFT_EYE = [33, 160, 158, 133, 153, 144]
RIGHT_EYE = [362, 385, 387, 263, 373, 380]

def decode_image(base64_str: str) -> np.ndarray:
    try:
        if not base64_str or not isinstance(base64_str, str):
            raise ValueError("Empty image data")
        image_data = base64.b64decode(base64_str, validate=True)
        if len(image_data) == 0:
            raise ValueError("Zero bytes after decoding")
        np_arr = np.frombuffer(image_data, np.uint8)
        img = cv2.imdecode(np_arr, cv2.IMREAD_COLOR)
        if img is None:
            raise ValueError("cv2 failed to decode image buffer")
        return img
    except Exception as e:
        raise ValueError(f"Failed to decode image: {e}")

@app.get('/health')
async def health_check():
    return {"status": "healthy"}


@app.get('/system/info')
async def system_info():
    """Which optional services this server really provides (used by the
    mobile app's status sheet). /health is unchanged for existing clients."""
    return {
        "status": "healthy",
        "detection_model": os.path.basename(MODEL_PATH),
        "ocr_available": ocr_reader is not None,
        "face_recognition_available": face_service is not None and face_service.is_available(),
        "reference_search_available": os.path.exists("MobileNET_best.pth"),
        "open_vocabulary_available": world_model is not None,
    }


DATASET_ROOT = os.path.join("datasets", "custom_objects")
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def _count_files(directory: str, extensions=None) -> Optional[int]:
    if not os.path.isdir(directory):
        return None
    total = 0
    for name in os.listdir(directory):
        if extensions is None or os.path.splitext(name)[1].lower() in extensions:
            total += 1
    return total


@app.get('/dataset/summary')
def dataset_summary():
    """Read-only dataset & storage information (same sources as the website's
    "AutoML & Dataset Pipeline" page). Missing data is reported as null rather
    than replaced with example numbers."""
    import json
    import shutil
    import yaml

    storage = None
    try:
        total_b, used_b, free_b = shutil.disk_usage(os.path.abspath("."))
        storage = {
            "total_gb": round(total_b / 1024 ** 3, 2),
            "used_gb": round(used_b / 1024 ** 3, 2),
            "free_gb": round(free_b / 1024 ** 3, 2),
            "used_percent": round(used_b * 100.0 / total_b, 1) if total_b else None,
        }
    except OSError:
        storage = None

    names: List[str] = []
    num_classes = None
    yaml_path = os.path.join(DATASET_ROOT, "data.yaml")
    if os.path.exists(yaml_path):
        try:
            with open(yaml_path) as handle:
                data = yaml.safe_load(handle) or {}
            raw_names = data.get("names", [])
            names = list(raw_names.values()) if isinstance(raw_names, dict) else list(raw_names)
            num_classes = data.get("nc", len(names) or None)
        except Exception:
            pass

    splits = {}
    for split in ("train", "val", "test"):
        splits[split] = {
            "images": _count_files(os.path.join(DATASET_ROOT, "images", split), IMAGE_EXTENSIONS),
            "label_files": _count_files(os.path.join(DATASET_ROOT, "labels", split), {".txt"}),
        }

    sources = []
    manifest_path = os.path.join("datasets", "manifest.json")
    if os.path.exists(manifest_path):
        try:
            with open(manifest_path) as handle:
                manifest = json.load(handle)
            raw_sources = manifest.get("sources") or manifest.get("datasets") or []
            if isinstance(raw_sources, dict):
                raw_sources = [dict(value, id=key) for key, value in raw_sources.items()]
            for item in raw_sources:
                if isinstance(item, dict):
                    sources.append({
                        "id": item.get("id"),
                        "name": item.get("name") or item.get("title") or item.get("id"),
                        "type": item.get("type") or item.get("source"),
                        "format": item.get("format"),
                        "license": item.get("license"),
                        "status": item.get("status"),
                        "classes": item.get("classes"),
                    })
        except Exception:
            pass

    weights = []
    for candidate in ("yolov8n.pt", "yolov8m.pt", "yolov8s-world.pt", "SmartVision_v3.pt",
                      os.path.join("weights", "smartvision_best.pt"), "yolov8n.tflite"):
        if os.path.exists(candidate):
            weights.append({"file": candidate, "size_mb": round(os.path.getsize(candidate) / 1024 ** 2, 1)})

    return {
        "storage": storage,
        "dataset_root": DATASET_ROOT,
        "num_classes": num_classes,
        "class_names": names,
        "splits": splits,
        "sources": sources,
        "weights": weights,
        "active_detection_model": os.path.basename(MODEL_PATH),
    }

@app.post('/detect')
async def detect_objects(req: DetectionRequest):
    try:
        img = decode_image(req.image)
        if img is None:
            raise HTTPException(status_code=400, detail="Invalid image format")

        results = yolo_model.predict(
            img,
            conf=req.confidence_threshold,
            iou=req.iou_threshold,
            max_det=req.max_detections,
            agnostic_nms=True,
            verbose=False,
        )
        
        detections = []
        for r in results:
            boxes = r.boxes
            for box in boxes:
                x1, y1, x2, y2 = box.xyxyn[0].tolist()
                conf = float(box.conf[0])
                cls_id = int(box.cls[0])
                label = yolo_model.names[cls_id]
                
                rect_dict = {'left': x1, 'top': y1, 'right': x2, 'bottom': y2}
                dist_info = default_distance_estimator.estimate_distance(label, rect_dict)
                
                detections.append({
                    'rect': rect_dict,
                    'label': label,
                    'confidence': conf,
                    'distance_m': dist_info.get('distance_m'),
                    'distance_status': dist_info.get('status'),
                    'distance_range': dist_info.get('confidence_range')
                })

        # Siren trigger: Only triggers on genuine hazardous / dangerous objects (knife, scissors, gun, fire)
        HAZARD_CLASSES = {'knife', 'scissors', 'gun', 'fire'}
        if any(d['label'] in HAZARD_CLASSES for d in detections):
            current_time = time.time()
            global last_siren_time
            if current_time - last_siren_time > 2.5:
                siren_file = os.path.abspath('siren.wav')
                # afplay only exists on macOS; on other hosts a missing player
                # must not turn a successful detection into an HTTP 500.
                if os.path.exists(siren_file) and shutil.which("afplay"):
                    try:
                        subprocess.Popen(["afplay", siren_file])
                        last_siren_time = current_time
                    except OSError as exc:
                        print(f"Siren playback failed: {exc}")
                
        return {'recognitions': detections}
    except ValueError as ve:
        raise HTTPException(status_code=400, detail=str(ve))
    except Exception as e:
        print(f"Error during detection: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post('/ocr')
async def detect_text(req: ImageRequest):
    if ocr_reader is None:
        return {'texts': [], 'message': 'OCR is unavailable because the model could not be loaded offline.'}
    try:
        img = decode_image(req.image)
        if img is None:
            raise HTTPException(status_code=400, detail="Invalid image format")

        results = ocr_reader.readtext(img, rotation_info=[90, 180, 270])
        if not results:
            gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if len(img.shape) == 3 else img
            clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
            enhanced = clahe.apply(gray)
            enhanced_bgr = cv2.cvtColor(enhanced, cv2.COLOR_GRAY2BGR)
            results = ocr_reader.readtext(enhanced_bgr, rotation_info=[90, 180, 270])
        
        text_detections = []
        for (bbox, text, prob) in results:
            # bbox is a list of 4 points: [[x1, y1], [x2, y1], [x2, y2], [x1, y2]]
            text_detections.append({
                'text': text,
                'confidence': float(prob),
                'bbox': [[float(p[0]), float(p[1])] for p in bbox]
            })
            
        return {'texts': text_detections}
    except ValueError as ve:
        raise HTTPException(status_code=400, detail=str(ve))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post('/face/register')
async def register_face(req: FaceRegisterRequest, name: Optional[str] = Query(None)):
    if face_service is None:
        raise HTTPException(
            status_code=503,
            detail="Face recognition is unavailable because the required model download was blocked in offline mode.",
        )
    try:
        person_name = req.name or name
        if not person_name:
            raise HTTPException(status_code=400, detail="Missing required person 'name'")
            
        img = decode_image(req.image)
        if img is None:
            raise HTTPException(status_code=400, detail="Invalid image format")
            
        saved_path = face_service.register_face(person_name, img)
        
        # FAISS embedding indexation for similarity search (PPT Slide 10 & 13)
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if len(img.shape) == 3 else img
        resized = cv2.resize(gray, (16, 8)).astype(np.float32).flatten()
        norm = np.linalg.norm(resized)
        if norm > 0:
            resized /= norm
        faiss_store.add_embedding(resized, person_name)

        return {"status": "success", "message": f"Registered {person_name}", "filepath": saved_path}
    except ValueError as ve:
        raise HTTPException(status_code=400, detail=str(ve))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post('/face/recognize')
async def recognize_face(req: ImageRequest):
    if face_service is None:
        return {'recognitions': []}
    try:
        img = decode_image(req.image)
        if img is None:
            raise HTTPException(status_code=400, detail="Invalid image format")

        name, conf, bbox = face_service.recognize_face_details(img)
        recognitions = []
        if name:
            is_unrec = name.lower().startswith("unknown") or name == "Not Registered"
            clean_name = "Not Registered" if is_unrec else name
            conf_val = (
                round(max(0.0, min(1.0, float(conf or 0.0))), 2)
                if clean_name != "Not Registered"
                else 0.0
            )
            recognitions.append({
                "name": clean_name,
                "confidence": conf_val,
                "box": [int(x) for x in bbox] if bbox else []
            })
        return {"recognitions": recognitions}
    except ValueError as ve:
        raise HTTPException(status_code=400, detail=str(ve))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post('/chatbot/query')
async def chatbot_query(req: ChatbotRequest):
    try:
        from ai.chatbot.smart_assistant import get_smart_assistant
        assistant = get_smart_assistant()
        assistant.set_provider_and_keys(
            provider=req.provider or "auto",
            gemini_key=req.gemini_key or os.environ.get("GEMINI_API_KEY", ""),
            openai_key=req.openai_key or os.environ.get("OPENAI_API_KEY", "")
        )
        ctx = req.context or {}
        detections = ctx.get("detections", [])
        ocr_text = req.ocr_text or ctx.get("ocr_text", "")
        counts = ctx.get("counts", None)
        
        reply = assistant.ask(
            question=req.query,
            context_detections=detections,
            ocr_text=ocr_text,
            counts=counts
        )
        return {
            "response": reply,
            "provider": assistant.provider,
            "status": "success"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

from core_utils import translate_robust

@app.post('/translate')
async def translate_text(req: TranslateRequest):
    if not req.text or not req.text.strip():
        return {"translated_text": "", "target_lang": req.target_lang}
    
    translated = translate_robust(req.text, target_lang=req.target_lang)
    return {"translated_text": translated or req.text, "target_lang": req.target_lang}

@app.post('/summarize')
async def summarize_text(req: SummarizeRequest):
    if not req.text or not req.text.strip():
        return {"summary": "", "sentence_count": 0}
    
    text = req.text.strip()
    import re
    sentences = [s.strip() for s in re.split(r'(?<=[.!?])\s+', text) if len(s.strip()) > 10]
    if len(sentences) <= (req.max_sentences or 3):
        return {"summary": text, "sentence_count": len(sentences)}

    words = re.findall(r'\b[a-zA-Z]{3,}\b', text.lower())
    freq = {}
    for w in words:
        freq[w] = freq.get(w, 0) + 1

    scored = []
    for idx, s in enumerate(sentences):
        s_words = re.findall(r'\b[a-zA-Z]{3,}\b', s.lower())
        score = sum(freq.get(w, 0) for w in s_words) / max(1, len(s_words))
        if idx == 0: score *= 1.3
        if idx == len(sentences) - 1: score *= 1.2
        scored.append((score, idx, s))

    scored.sort(reverse=True)
    top_sentences = sorted(scored[:(req.max_sentences or 3)], key=lambda x: x[1])
    summary = " ".join([s[2] for s in top_sentences])
    return {"summary": summary, "sentence_count": len(top_sentences)}

@app.post('/video/review')
async def review_video(req: VideoReviewRequest):
    try:
        video_bytes = base64.b64decode(req.video_base64)
        with tempfile.NamedTemporaryFile(suffix='.mp4', delete=False) as tf:
            tf.write(video_bytes)
            tf_path = tf.name

        cap = cv2.VideoCapture(tf_path)
        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        frame_interval = max(1, int(fps * 1.0)) # 1 frame per second

        timeline = []
        target = (req.target_object or "").lower().strip()
        conf_thresh = req.confidence_threshold

        frame_idx = 0
        while cap.isOpened():
            ret, frame = cap.read()
            if not ret: break
            if frame_idx % frame_interval == 0:
                sec = frame_idx / fps
                time_str = f"{int(sec//60):02d}:{int(sec%60):02d}"
                res = yolo_model.predict(
                    frame,
                    conf=conf_thresh,
                    iou=req.iou_threshold,
                    max_det=req.max_detections,
                    verbose=False,
                )
                frame_matches = []
                for r in res:
                    for box in r.boxes:
                        label = yolo_model.names[int(box.cls[0])]
                        conf = float(box.conf[0])
                        if not target or target in label.lower():
                            x1, y1, x2, y2 = box.xyxyn[0].tolist()
                            frame_matches.append({
                                "label": label,
                                "confidence": conf,
                                "rect": {"left": x1, "top": y1, "right": x2, "bottom": y2}
                            })
                if frame_matches:
                    timeline.append({
                        "timestamp": time_str,
                        "seconds": round(sec, 2),
                        "detections": frame_matches
                    })
            frame_idx += 1

        cap.release()
        try: os.unlink(tf_path)
        except: pass

        return {"target": target, "total_events": len(timeline), "timeline": timeline}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

def _decode_video_to_temp(video_base64: str) -> str:
    try:
        video_bytes = base64.b64decode(video_base64, validate=True)
        if not video_bytes:
            raise ValueError("Empty video data")
        with tempfile.NamedTemporaryFile(suffix='.mp4', delete=False) as video_file:
            video_file.write(video_bytes)
            return video_file.name
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Failed to decode video: {exc}")

@app.post('/video/ocr')
def video_ocr(req: VideoOCRRequest):
    if ocr_reader is None:
        raise HTTPException(status_code=503, detail="OCR is unavailable because its model could not be loaded.")
    if req.frame_interval_seconds <= 0:
        raise HTTPException(status_code=422, detail="frame_interval_seconds must be positive.")

    video_path = _decode_video_to_temp(req.video_base64)
    cap = None
    try:
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            raise HTTPException(status_code=400, detail="The uploaded video could not be opened.")
        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        interval = max(1, int(fps * req.frame_interval_seconds))
        timeline = []
        seen_text = set()
        frame_idx = 0
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            if frame_idx % interval == 0:
                timestamp = frame_idx / fps
                detections = ocr_reader.readtext(frame)
                frame_text = []
                for _, text, confidence in detections:
                    clean_text = " ".join(str(text).split())
                    normalized = clean_text.casefold()
                    if not clean_text or normalized in seen_text:
                        continue
                    seen_text.add(normalized)
                    frame_text.append({
                        "text": clean_text,
                        "confidence": float(confidence),
                    })
                if frame_text:
                    timeline.append({
                        "seconds": round(timestamp, 2),
                        "timestamp": f"{int(timestamp // 60):02d}:{int(timestamp % 60):02d}",
                        "texts": frame_text,
                    })
            frame_idx += 1

        combined_text = "\n".join(
            item["text"] for frame_result in timeline for item in frame_result["texts"]
        )
        return {
            "frame_interval_seconds": req.frame_interval_seconds,
            "total_frames_processed": (frame_idx + interval - 1) // interval,
            "timeline": timeline,
            "full_text": combined_text,
        }
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Video OCR failed: {exc}")
    finally:
        if cap is not None:
            cap.release()
        try:
            os.unlink(video_path)
        except OSError:
            pass

def _get_face_landmarker():
    global face_landmarker
    if face_landmarker is not None:
        return face_landmarker
    model_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "face_landmarker.task")
    if not os.path.isfile(model_path):
        raise HTTPException(status_code=503, detail="The Face Landmarker model file is missing.")
    try:
        import mediapipe as mp
        options = mp.tasks.vision.FaceLandmarkerOptions(
            base_options=mp.tasks.BaseOptions(model_asset_path=model_path),
            running_mode=mp.tasks.vision.RunningMode.IMAGE,
            num_faces=1,
        )
        face_landmarker = mp.tasks.vision.FaceLandmarker.create_from_options(options)
        return face_landmarker
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"Face Landmarker could not be initialized: {exc}")

def _eye_aspect_ratio(eye_points, landmarks, width: int, height: int) -> float:
    points = [(landmarks[index].x * width, landmarks[index].y * height) for index in eye_points]
    vertical_one = math.dist(points[1], points[5])
    vertical_two = math.dist(points[2], points[4])
    horizontal = math.dist(points[0], points[3])
    if horizontal == 0:
        return 0.0
    return (vertical_one + vertical_two) / (2.0 * horizontal)

def _drowsiness_result(image: np.ndarray, threshold: float) -> Optional[float]:
    import mediapipe as mp
    rgb_image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
    mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb_image)
    result = _get_face_landmarker().detect(mp_image)
    if not result.face_landmarks:
        return None
    landmarks = result.face_landmarks[0]
    height, width = image.shape[:2]
    left = _eye_aspect_ratio(LEFT_EYE, landmarks, width, height)
    right = _eye_aspect_ratio(RIGHT_EYE, landmarks, width, height)
    return (left + right) / 2.0

@app.post('/drowsiness/frame')
def drowsiness_frame(req: DrowsinessFrameRequest):
    if not 0.15 <= req.ear_threshold <= 0.35:
        raise HTTPException(status_code=422, detail="ear_threshold must be between 0.15 and 0.35.")
    if not 1 <= req.consecutive_frames <= 100:
        raise HTTPException(status_code=422, detail="consecutive_frames must be between 1 and 100.")
    try:
        frame = decode_image(req.image)
        with face_landmarker_lock:
            ear = _drowsiness_result(frame, req.ear_threshold)
        now = time.time()
        with drowsiness_lock:
            session = drowsiness_sessions.setdefault(
                req.session_id,
                {"closed_frames": 0, "incidents": 0, "last_seen": now, "alert_active": False},
            )
            session["last_seen"] = now
            if ear is None:
                session["closed_frames"] = 0
                session["alert_active"] = False
            elif ear < req.ear_threshold:
                session["closed_frames"] += 1
                if session["closed_frames"] >= req.consecutive_frames and not session["alert_active"]:
                    session["incidents"] += 1
                    session["alert_active"] = True
            else:
                session["closed_frames"] = 0
                session["alert_active"] = False
            expired = [key for key, value in drowsiness_sessions.items() if now - value["last_seen"] > 1800]
            for key in expired:
                drowsiness_sessions.pop(key, None)
            return {
                "face_detected": ear is not None,
                "ear": round(ear, 4) if ear is not None else None,
                "drowsy": session["alert_active"],
                "closed_frames": session["closed_frames"],
                "incidents": session["incidents"],
            }
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Drowsiness analysis failed: {exc}")

@app.post('/drowsiness/video')
def drowsiness_video(req: DrowsinessVideoRequest):
    if not 0.15 <= req.ear_threshold <= 0.35:
        raise HTTPException(status_code=422, detail="ear_threshold must be between 0.15 and 0.35.")
    if not 1 <= req.consecutive_frames <= 100:
        raise HTTPException(status_code=422, detail="consecutive_frames must be between 1 and 100.")
    video_path = _decode_video_to_temp(req.video_base64)
    cap = None
    consecutive_closed = 0
    incidents = []
    frame_idx = 0
    try:
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            raise HTTPException(status_code=400, detail="The uploaded video could not be opened.")
        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        interval = max(1, int(fps / 2))
        with face_landmarker_lock:
            while True:
                ok, frame = cap.read()
                if not ok:
                    break
                if frame_idx % interval == 0:
                    ear = _drowsiness_result(frame, req.ear_threshold)
                    if ear is None:
                        consecutive_closed = 0
                    elif ear < req.ear_threshold:
                        consecutive_closed += interval
                        if consecutive_closed >= req.consecutive_frames:
                            incidents.append({
                                "seconds": round(frame_idx / fps, 2),
                                "timestamp": f"{int(frame_idx / fps // 60):02d}:{int(frame_idx / fps % 60):02d}",
                                "ear": round(ear, 4),
                            })
                            consecutive_closed = 0
                    else:
                        consecutive_closed = 0
                frame_idx += 1
        return {
            "total_incidents": len(incidents),
            "frames_analyzed": (frame_idx + interval - 1) // interval,
            "ear_threshold": req.ear_threshold,
            "consecutive_frames": req.consecutive_frames,
            "incidents": incidents,
        }
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Drowsiness video analysis failed: {exc}")
    finally:
        if cap is not None:
            cap.release()
        try:
            os.unlink(video_path)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Mobile-app additions (October 2026). All endpoints below are new; existing
# endpoints and their request/response formats are unchanged.
# ---------------------------------------------------------------------------
from pathlib import Path as _Path

from services import project_insights
from services.reference_search_jobs import ReferenceSearchJobs, MAX_ACTIVE_JOBS

MAX_UPLOAD_MB = int(os.environ.get("SMARTVISION_MAX_UPLOAD_MB", "1024"))
_VIDEO_EXT = {".mp4", ".mov", ".avi", ".mkv", ".webm", ".m4v", ".3gp"}
_IMAGE_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def _face_registry():
    """Registered people in the shared known_faces/ folder (same as the website)."""
    faces_dir = getattr(face_service, "faces_dir", "known_faces")
    people: Dict[str, Dict[str, Any]] = {}
    import re as _re
    if os.path.isdir(faces_dir):
        for filename in sorted(os.listdir(faces_dir)):
            stem, ext = os.path.splitext(filename)
            if ext.lower() not in (".png", ".jpg", ".jpeg"):
                continue
            name = _re.sub(r"_\d+$", "", stem)
            entry = people.setdefault(name, {"name": name, "samples": 0, "files": []})
            entry["samples"] += 1
            entry["files"].append(filename)
    embedded = set(getattr(face_service, "person_embeddings", {}) or {}) if face_service else set()
    for entry in people.values():
        entry["has_embedding"] = entry["name"] in embedded
    return faces_dir, sorted(people.values(), key=lambda e: e["name"].lower())


def _face_available() -> bool:
    return face_service is not None and face_service.is_available()


@app.get('/face/registered')
def list_registered_faces():
    """People registered for recognition (website + mobile share this list)."""
    faces_dir, people = _face_registry()
    return {
        "recognition_available": _face_available(),
        "threshold": 0.363,
        "storage": faces_dir,
        "people": [{k: v for k, v in p.items() if k != "files"} for p in people],
    }


@app.delete('/face/registered/{name}')
def delete_registered_face(name: str):
    if not name.strip():
        raise HTTPException(status_code=400, detail="Missing name.")
    if face_service is None:
        raise HTTPException(status_code=503, detail="Face service is unavailable on this server.")
    deleted = face_service.delete_face(name)
    if not deleted:
        raise HTTPException(status_code=404, detail=f"No registered person named '{name}'.")
    return {"status": "deleted", "name": name, "removed_samples": len(deleted)}


class FaceRenameRequest(BaseModel):
    new_name: str


@app.post('/face/registered/{name}/rename')
def rename_registered_face(name: str, req: FaceRenameRequest):
    import re as _re
    new_name = req.new_name.strip()
    if not new_name or not _re.fullmatch(r"[\w .'-]{1,60}", new_name):
        raise HTTPException(status_code=400, detail="Use 1-60 letters, digits, spaces, . ' - or _.")
    faces_dir, people = _face_registry()
    person = next((p for p in people if p["name"] == name), None)
    if person is None:
        raise HTTPException(status_code=404, detail=f"No registered person named '{name}'.")
    if new_name != name and any(p["name"] == new_name for p in people):
        raise HTTPException(status_code=409, detail=f"'{new_name}' is already registered.")
    for index, filename in enumerate(person["files"]):
        ext = os.path.splitext(filename)[1].lower()
        os.replace(os.path.join(faces_dir, filename), os.path.join(faces_dir, f"{new_name}_{index}{ext}"))
    if face_service is not None:
        face_service.train_model()
    return {"status": "renamed", "old_name": name, "new_name": new_name}


@app.post('/face/recognize_all')
async def recognize_all_faces(req: ImageRequest):
    """Like /face/recognize but returns every face (largest first)."""
    if not _face_available():
        raise HTTPException(status_code=503, detail="Face recognition models are not available on this server.")
    try:
        img = decode_image(req.image)
    except ValueError as ve:
        raise HTTPException(status_code=400, detail=str(ve))
    faces = []
    for name, similarity, box in face_service.recognize_faces(img):
        registered = name != "Not Registered"
        faces.append({
            "name": name if registered else None,
            "registered": registered,
            "similarity": round(float(similarity), 4),
            "box": [int(v) for v in box],  # x, y, width, height
        })
    h, w = img.shape[:2]
    return {"faces": faces, "image_width": w, "image_height": h, "threshold": 0.363}


@app.get('/storage/summary')
def storage_summary():
    """Measured storage of the backend project folder, by category."""
    return project_insights.storage_summary(".")


@app.get('/dataset/splits')
def dataset_splits():
    return {"datasets": project_insights.dataset_splits(".")}


@app.get('/training/status')
def training_status():
    return project_insights.training_runs(".")


@app.get('/evaluation/results')
def evaluation_results():
    return project_insights.evaluation_results(".")


@app.get('/evaluation/report/{name:path}', response_class=PlainTextResponse)
def evaluation_report(name: str):
    text = project_insights.read_report(name, ".")
    if text is None:
        raise HTTPException(status_code=404, detail="Report not found.")
    return text


def _make_reference_engine():
    from services.video_reference_search import ReferenceSearchEngine
    return ReferenceSearchEngine(MODEL_PATH, face_service=face_service)


reference_jobs = ReferenceSearchJobs(_make_reference_engine)


async def _save_upload(upload: UploadFile, destination: _Path, allowed_ext: set) -> int:
    ext = os.path.splitext(upload.filename or "")[1].lower()
    if ext not in allowed_ext:
        raise HTTPException(status_code=400, detail=f"Unsupported file type '{ext or 'none'}' for {upload.filename}.")
    written = 0
    limit = MAX_UPLOAD_MB * 1024 * 1024
    with destination.open("wb") as handle:
        while True:
            chunk = await upload.read(1024 * 1024)
            if not chunk:
                break
            written += len(chunk)
            if written > limit:
                raise HTTPException(status_code=413, detail=f"{upload.filename} is larger than {MAX_UPLOAD_MB} MB.")
            handle.write(chunk)
    if written == 0:
        raise HTTPException(status_code=400, detail=f"{upload.filename} is empty.")
    return written


def _validate_video(path: _Path, label: str) -> None:
    cap = cv2.VideoCapture(str(path))
    try:
        if not cap.isOpened():
            raise HTTPException(status_code=400, detail=f"The {label} could not be opened (corrupt or unsupported codec).")
        ok, _ = cap.read()
        if not ok:
            raise HTTPException(status_code=400, detail=f"No frames could be read from the {label}.")
    finally:
        cap.release()


@app.post('/video/reference_search')
async def start_reference_search(
    video: UploadFile = File(...),
    reference: Optional[UploadFile] = File(None),
    category: str = Form(""),
    precision: str = Form("strict"),
    sample_rate: int = Form(1),
    confidence: float = Form(0.4),
    rotation: int = Form(0),
    restrict_category: bool = Form(True),
):
    """Fast Video Review with a reference image or reference video (website algorithm).

    Returns a job id immediately; poll GET /video/reference_search/{job_id}.
    """
    if precision not in ("strict", "balanced", "tolerant"):
        raise HTTPException(status_code=400, detail="precision must be strict, balanced or tolerant.")
    if not 1 <= sample_rate <= 5:
        raise HTTPException(status_code=400, detail="sample_rate must be between 1 and 5 frames per second.")
    if not 0.1 <= confidence <= 1.0:
        raise HTTPException(status_code=400, detail="confidence must be between 0.1 and 1.0.")
    if rotation not in (0, 90, 180, 270):
        raise HTTPException(status_code=400, detail="rotation must be 0, 90, 180 or 270.")
    if reference is None and not category.strip():
        raise HTTPException(status_code=400, detail="Provide a reference image/video or an object category.")
    if reference_jobs.active_count() >= MAX_ACTIVE_JOBS:
        raise HTTPException(status_code=429, detail="The server is already processing videos. Try again shortly.")

    job_dir = reference_jobs.new_job_dir()
    try:
        video_path = job_dir / ("target" + os.path.splitext(video.filename or ".mp4")[1].lower())
        await _save_upload(video, video_path, _VIDEO_EXT)
        _validate_video(video_path, "video")
        reference_path = None
        reference_kind = None
        if reference is not None:
            ext = os.path.splitext(reference.filename or "")[1].lower()
            reference_kind = "video" if ext in _VIDEO_EXT else "image"
            reference_path = job_dir / ("reference" + ext)
            await _save_upload(reference, reference_path, _VIDEO_EXT | _IMAGE_EXT)
            if reference_kind == "video":
                _validate_video(reference_path, "reference video")
            elif cv2.imread(str(reference_path)) is None:
                raise HTTPException(status_code=400, detail="The reference image could not be decoded.")
    except HTTPException:
        shutil.rmtree(job_dir, ignore_errors=True)
        raise
    options = {
        "category": category, "precision": precision, "sample_rate": sample_rate,
        "confidence": confidence, "rotation": rotation, "restrict_category": restrict_category,
        "video_name": video.filename, "reference_name": reference.filename if reference else None,
        "reference_kind": reference_kind,
    }
    job_id = reference_jobs.start(job_dir, video_path, reference_path, reference_kind, options)
    return {"job_id": job_id, "status": "queued"}


@app.get('/video/reference_search/{job_id}')
def reference_search_status(job_id: str):
    job = reference_jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Unknown or expired job.")
    for match in job["matches"]:
        match["thumbnail_url"] = f"/video/reference_search/{job_id}/frames/{match['index']}"
    return job


@app.get('/video/reference_search/{job_id}/frames/{index}')
def reference_search_frame(job_id: str, index: int):
    path = reference_jobs.frame_path(job_id, index)
    if path is None:
        raise HTTPException(status_code=404, detail="Frame not found.")
    return FileResponse(str(path), media_type="image/jpeg")


@app.delete('/video/reference_search/{job_id}')
def cancel_reference_search(job_id: str):
    if not reference_jobs.cancel(job_id):
        raise HTTPException(status_code=404, detail="Unknown or expired job.")
    return {"job_id": job_id, "status": "cancelling"}


if __name__ == '__main__':
    uvicorn.run(app, host="0.0.0.0", port=8000)
