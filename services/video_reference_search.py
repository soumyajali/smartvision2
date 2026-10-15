"""Fast Video Review — reference matching shared by the API (and usable by the website).

This module reproduces the matching workflow of the website's "Video Fast Review"
page (app.py, "Reference Image" mode) so the mobile app can use exactly the same
algorithm through the FastAPI backend:

1. Reference preparation (``prepare_reference``)
   * If the reference contains a face -> the target is that specific person and
     candidates are matched by face (``face_recognition`` encodings with the
     website's distance thresholds when the library is installed; otherwise the
     project's YuNet/SFace ``FaceService`` embeddings when its models are
     available).
   * Otherwise the YOLO detection with the highest confidence is cropped and its
     category becomes the default filter.
   * A MobileNetV2 feature embedding (``MobileNET_best.pth``, same transform as
     the website) and a 16x16 HSV colour histogram are computed for the crop.
2. Video scan (``search``)
   * Frames are read sequentially (the video is never loaded into memory) and
     sampled ``sample_rate`` times per second.
   * Each sampled frame is resized to 640x480 and tracked with YOLO
     (``model.track(persist=True)``, like the website).
   * Object matching: ``sim = 0.55 * cosine(MobileNet) + 0.45 * HSV-correlation``
     with ``sim >= min_obj_sim`` and ``colour >= 0.50`` (website thresholds).
   * Matches closer than 2 s to the previous match are merged (website rule).

A reference *video* is supported by sampling up to ``MAX_REFERENCE_FRAMES``
frames from it and preparing each as a reference image; a candidate matches if
it matches any of them (the best similarity is reported).
"""

from __future__ import annotations

import math
import os
import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional

import cv2
import numpy as np

PRECISION_MODES = {
    # website: Strict 100% Match / Balanced (Standard) / Tolerant (High Recall)
    "strict": {"max_face_dist": 0.48, "min_obj_sim": 0.72, "min_sface_sim": 0.42},
    "balanced": {"max_face_dist": 0.52, "min_obj_sim": 0.65, "min_sface_sim": 0.363},
    "tolerant": {"max_face_dist": 0.58, "min_obj_sim": 0.55, "min_sface_sim": 0.30},
}
MIN_COLOR_SIM = 0.50
MERGE_WINDOW_SECONDS = 2.0
MAX_REFERENCE_FRAMES = 5
FRAME_SIZE = (640, 480)

try:  # same optional dependency the website uses
    import face_recognition  # type: ignore

    FACE_RECOGNITION_AVAILABLE = True
except Exception:  # pragma: no cover - depends on dlib being installed
    face_recognition = None
    FACE_RECOGNITION_AVAILABLE = False


class _EmbeddingModel:
    """MobileNetV2 feature extractor identical to app.get_image_embedding."""

    def __init__(self, weights_path: str = "MobileNET_best.pth"):
        import torch
        import torch.nn as nn
        from torchvision import models, transforms

        self._torch = torch
        self._nn = nn
        model = models.mobilenet_v2(weights=None)
        num_classes = 25  # CLS_CLASS_NAMES in app.py
        model.classifier = nn.Sequential(
            nn.Dropout(0.3),
            nn.Linear(model.classifier[1].in_features, 1024),
            nn.ReLU(),
            nn.Dropout(0.5),
            nn.Linear(1024, num_classes),
        )
        if not os.path.exists(weights_path):
            raise FileNotFoundError(
                f"{weights_path} is required for reference matching (it provides the "
                "same MobileNetV2 features the website uses)."
            )
        state_dict = torch.load(weights_path, map_location="cpu")
        model.load_state_dict(state_dict, strict=False)
        model.eval()
        self.model = model
        self.transform = transforms.Compose([
            transforms.Resize((224, 224)),
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
        ])

    def embed(self, image_bgr: np.ndarray) -> np.ndarray:
        from PIL import Image

        img_rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
        tensor = self.transform(Image.fromarray(img_rgb)).unsqueeze(0)
        with self._torch.no_grad():
            features = self.model.features(tensor)
            features = self._nn.functional.adaptive_avg_pool2d(features, (1, 1))
            embedding = features.view(features.size(0), -1).squeeze().numpy()
        norm = np.linalg.norm(embedding)
        return embedding / norm if norm > 0 else embedding


def color_histogram(image_bgr: np.ndarray):
    """Identical to app.get_color_histogram."""
    if image_bgr is None or image_bgr.size == 0:
        return None
    hsv = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2HSV)
    hist = cv2.calcHist([hsv], [0, 1], None, [16, 16], [0, 180, 0, 256])
    cv2.normalize(hist, hist, 0, 1, cv2.NORM_MINMAX)
    return hist


def rotate_frame(frame: np.ndarray, rotation: int) -> np.ndarray:
    if rotation == 90:
        return cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)
    if rotation == 180:
        return cv2.rotate(frame, cv2.ROTATE_180)
    if rotation == 270:
        return cv2.rotate(frame, cv2.ROTATE_90_COUNTERCLOCKWISE)
    return frame


@dataclass
class Reference:
    is_person: bool = False
    face_encoding: Optional[np.ndarray] = None  # face_recognition encoding
    sface_embedding: Optional[np.ndarray] = None  # FaceService SFace embedding
    category: Optional[str] = None
    embedding: Optional[np.ndarray] = None
    hist: Optional[np.ndarray] = None
    box: Optional[List[int]] = None  # in the reference image
    source_seconds: Optional[float] = None  # for reference videos

    def summary(self) -> Dict:
        return {
            "type": "face" if self.is_person else ("object" if self.category else "appearance"),
            "category": self.category,
            "box": self.box,
            "source_seconds": self.source_seconds,
        }


@dataclass
class SearchResult:
    matches: List[Dict] = field(default_factory=list)
    processed_frames: int = 0
    sampled_frames: int = 0
    total_frames: int = 0
    fps: float = 0.0
    duration_seconds: float = 0.0
    method: str = ""
    target_category: Optional[str] = None
    cancelled: bool = False


class ReferenceSearchEngine:
    def __init__(self, model_path: str, face_service=None, weights_path: str = "MobileNET_best.pth"):
        from ultralytics import YOLO

        # A dedicated model per engine: track(persist=True) keeps tracker state
        # on the model object, so it must not be shared with /detect.
        self.det_model = YOLO(model_path)
        self.class_names = {int(k): str(v).lower() for k, v in self.det_model.names.items()}
        self.face_service = face_service
        self._embedder: Optional[_EmbeddingModel] = None
        self._weights_path = weights_path

    @property
    def embedder(self) -> _EmbeddingModel:
        if self._embedder is None:
            self._embedder = _EmbeddingModel(self._weights_path)
        return self._embedder

    @property
    def sface_available(self) -> bool:
        return bool(self.face_service is not None and self.face_service.is_available())

    def face_method(self) -> Optional[str]:
        if FACE_RECOGNITION_AVAILABLE:
            return "face_recognition"
        if self.sface_available:
            return "sface"
        return None

    # ------------------------------------------------------------------ refs
    def prepare_reference(self, image_bgr: np.ndarray, source_seconds: Optional[float] = None) -> Reference:
        if image_bgr is None or image_bgr.size == 0:
            raise ValueError("The reference image could not be decoded.")
        ref = Reference(source_seconds=source_seconds)
        crop = image_bgr

        # 1. Does the reference contain a face? (website: face_recognition)
        method = self.face_method()
        if method == "face_recognition":
            rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
            locations = face_recognition.face_locations(rgb) or face_recognition.face_locations(
                rgb, number_of_times_to_upsample=1
            )
            if locations:
                best = max(locations, key=lambda l: (l[2] - l[0]) * (l[1] - l[3]))
                encodings = face_recognition.face_encodings(rgb, [best])
                if encodings:
                    top, right, bottom, left = best
                    ref.is_person = True
                    ref.face_encoding = encodings[0]
                    ref.category = "person"
                    ref.box = [int(left), int(top), int(right), int(bottom)]
        elif method == "sface":
            candidates = self.face_service.extract_face_embeddings(image_bgr)
            if candidates:
                box, embedding = candidates[0]  # largest face first
                ref.is_person = True
                ref.sface_embedding = embedding
                ref.category = "person"
                ref.box = [int(v) for v in box]

        # 2. Not a face: crop the most confident YOLO detection.
        if not ref.is_person:
            results = self.det_model.predict(image_bgr, conf=0.25, verbose=False)
            if results and results[0].boxes is not None and len(results[0].boxes) > 0:
                boxes = results[0].boxes
                best_box = max(boxes, key=lambda b: float(b.conf[0]))
                x1, y1, x2, y2 = map(int, best_box.xyxy[0])
                ref.category = self.class_names.get(int(best_box.cls[0]))
                cropped = image_bgr[max(0, y1):max(0, y2), max(0, x1):max(0, x2)]
                if cropped.size > 0 and cropped.shape[0] > 10 and cropped.shape[1] > 10:
                    crop = cropped
                ref.box = [x1, y1, x2, y2]

        ref.embedding = self.embedder.embed(crop)
        ref.hist = color_histogram(crop)
        return ref

    def prepare_reference_video(self, path: str, rotation: int = 0) -> List[Reference]:
        cap = cv2.VideoCapture(path)
        if not cap.isOpened():
            raise ValueError("The reference video could not be opened.")
        try:
            fps = cap.get(cv2.CAP_PROP_FPS)
            fps = 30.0 if (not fps or math.isnan(fps) or fps <= 0) else fps
            total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
            if total <= 0:
                raise ValueError("The reference video has no readable frames.")
            count = min(MAX_REFERENCE_FRAMES, total)
            indices = sorted({int(round((i + 0.5) * total / count)) for i in range(count)})
            references: List[Reference] = []
            for index in indices:
                cap.set(cv2.CAP_PROP_POS_FRAMES, min(index, total - 1))
                ok, frame = cap.read()
                if not ok or frame is None:
                    continue
                frame = rotate_frame(frame, rotation)
                references.append(self.prepare_reference(frame, source_seconds=round(index / fps, 2)))
            if not references:
                raise ValueError("No frames could be read from the reference video.")
            return references
        finally:
            cap.release()

    # ---------------------------------------------------------------- search
    def search(
        self,
        video_path: str,
        references: List[Reference],
        precision: str = "strict",
        sample_rate: int = 1,
        confidence: float = 0.4,
        rotation: int = 0,
        target_category: Optional[str] = None,
        frame_writer: Optional[Callable[[int, np.ndarray], str]] = None,
        progress: Optional[Callable[[float, int, int], None]] = None,
        is_cancelled: Optional[Callable[[], bool]] = None,
        on_match: Optional[Callable[[Dict], None]] = None,
    ) -> SearchResult:
        params = PRECISION_MODES.get(precision, PRECISION_MODES["strict"])
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            raise ValueError("The video could not be opened. It may be corrupt or use an unsupported codec.")
        result = SearchResult(target_category=target_category)
        person_refs = [r for r in references if r.is_person]
        object_refs = [r for r in references if not r.is_person and r.embedding is not None]
        if references:
            if person_refs:
                result.method = (
                    "face (face_recognition, website thresholds)"
                    if FACE_RECOGNITION_AVAILABLE
                    else "face (YuNet/SFace cosine similarity)"
                )
            else:
                result.method = "appearance (MobileNetV2 features 55% + HSV colour histogram 45%)"
        else:
            result.method = "object category (YOLO detection)"

        try:
            fps = cap.get(cv2.CAP_PROP_FPS)
            fps = 30.0 if (not fps or math.isnan(fps) or fps <= 0) else fps
            total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
            total_frames = total_frames if total_frames > 0 else 1
            result.fps = fps
            result.total_frames = total_frames
            result.duration_seconds = total_frames / fps
            frame_skip = max(1, int(fps / max(1, sample_rate)))
            last_match_seconds: Optional[float] = None
            current_frame = 0

            while True:
                if is_cancelled and is_cancelled():
                    result.cancelled = True
                    break
                ok, frame = cap.read()
                if not ok:
                    break
                if current_frame % frame_skip != 0:
                    current_frame += 1
                    continue
                frame = rotate_frame(frame, rotation)
                timestamp = current_frame / fps
                result.sampled_frames += 1
                if progress:
                    progress(min(1.0, current_frame / total_frames), current_frame, total_frames)

                small = cv2.resize(frame, FRAME_SIZE)
                tracked = self.det_model.track(small, persist=True, conf=confidence, verbose=False)
                best = self._match_frame(frame, small, tracked, references, person_refs, object_refs,
                                         params, target_category)
                if best is not None:
                    if last_match_seconds is None or timestamp - last_match_seconds > MERGE_WINDOW_SECONDS:
                        x1, y1, x2, y2 = best["box"]
                        annotated = small.copy()
                        cv2.rectangle(annotated, (x1, y1), (x2, y2), (0, 255, 0), 2)
                        cv2.putText(annotated, best["label"], (x1, max(y1 - 10, 0)),
                                    cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 255, 0), 2)
                        index = len(result.matches)
                        thumbnail = frame_writer(index, annotated) if frame_writer else None
                        result.matches.append({
                            "index": index,
                            "seconds": round(timestamp, 3),
                            "timestamp": time.strftime('%M:%S', time.gmtime(timestamp)),
                            "frame_index": current_frame,
                            "similarity": round(float(best["sim"]), 4) if best["sim"] is not None else None,
                            "detection_confidence": round(float(best["conf"]), 4),
                            "label": best["label"],
                            "category": best["category"],
                            "box": [round(x1 / FRAME_SIZE[0], 4), round(y1 / FRAME_SIZE[1], 4),
                                    round(x2 / FRAME_SIZE[0], 4), round(y2 / FRAME_SIZE[1], 4)],
                            "thumbnail": thumbnail,
                        })
                        if on_match:
                            on_match(dict(result.matches[-1]))
                        last_match_seconds = timestamp
                current_frame += 1
            result.processed_frames = current_frame
            if progress and not result.cancelled:
                progress(1.0, current_frame, total_frames)
            return result
        finally:
            cap.release()

    def _match_frame(self, frame, small, tracked, references, person_refs, object_refs, params, target_category):
        candidates = []
        for res in tracked:
            if res.boxes is None:
                continue
            for box in res.boxes:
                category = self.class_names.get(int(box.cls[0]), "")
                if target_category and category != target_category:
                    continue
                x1, y1, x2, y2 = map(int, box.xyxy[0])
                conf = float(box.conf[0])
                if not references:
                    candidates.append({"box": (x1, y1, x2, y2), "sim": None, "conf": conf,
                                       "label": category.title(), "category": category})
                    continue
                if person_refs and category == "person":
                    sim = self._face_similarity(frame, (x1, y1, x2, y2), person_refs, params)
                    if sim is not None:
                        candidates.append({"box": (x1, y1, x2, y2), "sim": sim, "conf": conf,
                                           "label": f"Target Match ({sim * 100:.0f}%)", "category": category})
                elif object_refs:
                    roi = small[max(0, y1):max(0, y2), max(0, x1):max(0, x2)]
                    if roi.size == 0 or roi.shape[0] < 10 or roi.shape[1] < 10:
                        continue
                    roi_emb = self.embedder.embed(roi)
                    roi_hist = color_histogram(roi)
                    best_sim = None
                    for ref in object_refs:
                        deep_sim = max(0.0, min(1.0, float(np.dot(ref.embedding, roi_emb))))
                        color_sim = 0.0
                        if ref.hist is not None and roi_hist is not None:
                            color_sim = max(0.0, float(cv2.compareHist(ref.hist, roi_hist, cv2.HISTCMP_CORREL)))
                        sim = 0.55 * deep_sim + 0.45 * color_sim
                        if sim >= params["min_obj_sim"] and color_sim >= MIN_COLOR_SIM:
                            best_sim = sim if best_sim is None else max(best_sim, sim)
                    if best_sim is not None:
                        candidates.append({"box": (x1, y1, x2, y2), "sim": best_sim, "conf": conf,
                                           "label": f"{category.title()} ({best_sim * 100:.1f}%)",
                                           "category": category})
            if candidates and not references:
                break  # website keeps the first box in category mode
        if not candidates:
            return None
        if references:
            candidates.sort(key=lambda c: c["sim"], reverse=True)
        return candidates[0]

    def _face_similarity(self, frame, small_box, person_refs, params) -> Optional[float]:
        """Map the 640x480 person box back to the original frame and compare faces."""
        orig_h, orig_w = frame.shape[:2]
        sx, sy = orig_w / FRAME_SIZE[0], orig_h / FRAME_SIZE[1]
        x1, y1, x2, y2 = small_box
        ox1, oy1 = max(0, int(x1 * sx)), max(0, int(y1 * sy))
        ox2, oy2 = min(orig_w, int(x2 * sx)), min(orig_h, int(y2 * sy))
        person = frame[oy1:oy2, ox1:ox2]
        if person.size == 0 or person.shape[0] <= 15 or person.shape[1] <= 15:
            return None
        best = None
        if FACE_RECOGNITION_AVAILABLE:
            rgb = cv2.cvtColor(person, cv2.COLOR_BGR2RGB)
            upper = rgb[0:max(25, int(rgb.shape[0] * 0.65)), :]
            locations = face_recognition.face_locations(upper) or face_recognition.face_locations(rgb)
            if not locations and person.shape[0] < 180:
                locations = face_recognition.face_locations(rgb, number_of_times_to_upsample=1)
            if not locations:
                return None
            encodings = face_recognition.face_encodings(rgb, locations)
            for encoding in encodings:
                for ref in person_refs:
                    if ref.face_encoding is None:
                        continue
                    distance = float(face_recognition.face_distance([ref.face_encoding], encoding)[0])
                    if distance <= params["max_face_dist"]:
                        sim = max(0.0, 1.0 - distance)
                        best = sim if best is None else max(best, sim)
            return best
        if self.sface_available:
            for _, embedding in self.face_service.extract_face_embeddings(person):
                for ref in person_refs:
                    if ref.sface_embedding is None:
                        continue
                    sim = self.face_service.compare_face_embeddings(ref.sface_embedding, embedding)
                    if sim >= params["min_sface_sim"]:
                        best = sim if best is None else max(best, sim)
        return best
