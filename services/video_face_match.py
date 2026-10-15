"""Find a reference person in video frames with the project's SFace face service.

Fast Video Review previously compared faces with dlib (`face_recognition`) and
accepted distances up to 0.55-0.60, which labels different people as the
target. This module uses the same YuNet + SFace models and cosine-similarity
threshold (0.363, OpenCV's published SFace threshold) as Face Registration, and
reports the measured similarity instead of an invented percentage.
"""

from dataclasses import dataclass
from typing import List, Optional, Tuple

import numpy as np

from services.face_service import FACE_MATCH_THRESHOLD

# Cosine similarity a face must reach to count as the reference person.
PRECISION_THRESHOLDS = {
    "strict": 0.45,                    # fewer false matches, may miss side/blurred faces
    "balanced": FACE_MATCH_THRESHOLD,  # 0.363, the validated SFace threshold
    "tolerant": 0.32,                  # more recall, look-alikes possible
}

# Faces smaller than this (pixels, shorter side) give unreliable embeddings.
MIN_FACE_SIDE = 24
# Detect on frames up to this size so small faces in HD video are still found.
VIDEO_DETECTION_DIMENSION = 960


@dataclass
class FaceMatch:
    box: Tuple[int, int, int, int]  # x1, y1, x2, y2 in the analysed frame
    similarity: float               # SFace cosine similarity to the reference


def threshold_for(precision_mode: str) -> float:
    mode = (precision_mode or "").lower()
    for key, value in PRECISION_THRESHOLDS.items():
        if mode.startswith(key):
            return value
    return PRECISION_THRESHOLDS["balanced"]


def _side(box) -> int:
    x1, y1, x2, y2 = box
    return min(x2 - x1, y2 - y1)


def reference_face(face_service, image) -> Tuple[Optional[Tuple[int, int, int, int]], Optional[np.ndarray], int]:
    """Return (box, embedding, faces_found) for the largest face in the reference image."""
    faces = face_service.extract_face_embeddings(image)
    if not faces:
        return None, None, 0
    box, embedding = max(faces, key=lambda item: (item[0][2] - item[0][0]) * (item[0][3] - item[0][1]))
    return box, embedding, len(faces)


def best_match_in_frame(face_service, frame, reference_embedding, threshold: float) -> Tuple[Optional[FaceMatch], int]:
    """Return the single best face in the frame if it reaches the threshold, and the number of faces seen."""
    faces = face_service.extract_face_embeddings(frame, max_detection_dimension=VIDEO_DETECTION_DIMENSION)
    best = None
    usable = 0
    for box, embedding in faces:
        if _side(box) < MIN_FACE_SIDE:
            continue
        usable += 1
        similarity = face_service.compare_face_embeddings(reference_embedding, embedding)
        if best is None or similarity > best.similarity:
            best = FaceMatch(box=tuple(int(v) for v in box), similarity=float(similarity))
    if best is not None and best.similarity >= threshold:
        return best, usable
    return None, usable
