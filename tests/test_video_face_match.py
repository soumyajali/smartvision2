"""Fast Video Review must not label a different person as the reference person."""

from pathlib import Path

import cv2
import numpy as np
import pytest

from services.face_service import FACE_MATCH_THRESHOLD, FaceService
from services.video_face_match import best_match_in_frame, reference_face, threshold_for

DATA_DIR = Path(__file__).parent / "data"


@pytest.fixture(scope="module")
def face_service(tmp_path_factory):
    service = FaceService(faces_dir=str(tmp_path_factory.mktemp("faces")))
    if not service.is_available():
        pytest.skip("SFace/YuNet models are not available (first run needs internet to download them)")
    return service


def _video_frame(image, width=1280, height=720):
    """Place a photo in a dark 16:9 frame, like a video frame with letterboxing."""
    scale = min(width / image.shape[1], height / image.shape[0]) * 0.6
    small = cv2.resize(image, None, fx=scale, fy=scale)
    frame = np.zeros((height, width, 3), np.uint8)
    y, x = (height - small.shape[0]) // 2, (width - small.shape[1]) // 2
    frame[y:y + small.shape[0], x:x + small.shape[1]] = small
    return frame


def test_precision_thresholds_never_go_below_sface_tolerant_floor():
    assert threshold_for("Balanced (Standard)") == FACE_MATCH_THRESHOLD
    assert threshold_for("Strict (High Precision)") > FACE_MATCH_THRESHOLD
    assert 0.3 <= threshold_for("Tolerant (High Recall)") < FACE_MATCH_THRESHOLD


def test_reference_person_is_found_in_a_video_frame(face_service):
    _, reference, count = reference_face(face_service, cv2.imread(str(DATA_DIR / "face_registered.jpg")))
    assert reference is not None and count >= 1
    frame = _video_frame(cv2.imread(str(DATA_DIR / "face_registered.jpg")))
    match, faces_seen = best_match_in_frame(face_service, frame, reference, threshold_for("Balanced"))
    assert faces_seen >= 1
    assert match is not None and match.similarity >= FACE_MATCH_THRESHOLD


@pytest.mark.parametrize("mode", ["Strict", "Balanced", "Tolerant"])
def test_different_person_is_not_reported_as_the_reference(face_service, mode):
    _, reference, _ = reference_face(face_service, cv2.imread(str(DATA_DIR / "face_registered.jpg")))
    frame = _video_frame(cv2.imread(str(DATA_DIR / "face_unregistered.jpg")))
    match, faces_seen = best_match_in_frame(face_service, frame, reference, threshold_for(mode))
    assert faces_seen >= 1
    assert match is None


def test_only_the_reference_face_is_selected_when_several_people_are_in_the_frame(face_service):
    registered = cv2.imread(str(DATA_DIR / "face_registered.jpg"))
    other = cv2.imread(str(DATA_DIR / "face_unregistered.jpg"))
    _, reference, _ = reference_face(face_service, registered)
    h = 480
    left = cv2.resize(other, (int(other.shape[1] * h / other.shape[0]), h))
    right = cv2.resize(registered, (int(registered.shape[1] * h / registered.shape[0]), h))
    frame = np.hstack([left, right])
    match, faces_seen = best_match_in_frame(face_service, frame, reference, threshold_for("Balanced"))
    assert faces_seen >= 2
    assert match is not None
    assert match.box[0] >= left.shape[1] - 5  # the box is on the registered person (right half)


def test_frame_without_faces_reports_zero_faces(face_service):
    _, reference, _ = reference_face(face_service, cv2.imread(str(DATA_DIR / "face_registered.jpg")))
    match, faces_seen = best_match_in_frame(face_service, np.zeros((480, 640, 3), np.uint8), reference, 0.363)
    assert match is None and faces_seen == 0
