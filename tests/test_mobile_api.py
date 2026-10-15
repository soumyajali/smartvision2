"""Tests for the backend endpoints added for the mobile app (October 2026).

Run from the project root:  python -m pytest tests/test_mobile_api.py -q
They build small synthetic videos from the project's own sample images, so no
external media is needed. Face-recognition identity tests require the
YuNet/SFace models (downloaded by services/face_service.py on first start) and
are skipped when those models are unavailable.
"""

import os
import shutil
import time
from pathlib import Path

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

import ai_server
from services import project_insights

client = TestClient(ai_server.app)
ROOT = Path(__file__).resolve().parent.parent

# Scene layout of the synthetic target video (10 fps, 10 s):
SEGMENTS = [
    ("assets/samples/classroom.jpg", 0.0, 3.0),
    ("assets/samples/office.jpg", 3.0, 5.0),   # knife
    ("test_image.png", 5.0, 8.0),              # cat, cup, person
    ("assets/samples/danger.png", 8.0, 10.0),  # scissors, cup
]


def _fit(img):
    h, w = img.shape[:2]
    s = min(640 / w, 480 / h)
    r = cv2.resize(img, (int(w * s), int(h * s)))
    canvas = np.zeros((480, 640, 3), np.uint8)
    y, x = (480 - r.shape[0]) // 2, (640 - r.shape[1]) // 2
    canvas[y:y + r.shape[0], x:x + r.shape[1]] = r
    return canvas


@pytest.fixture(scope="module")
def media(tmp_path_factory):
    d = tmp_path_factory.mktemp("media")
    writer = cv2.VideoWriter(str(d / "target.mp4"), cv2.VideoWriter_fourcc(*"mp4v"), 10, (640, 480))
    for path, start, end in SEGMENTS:
        frame = _fit(cv2.imread(str(ROOT / path)))
        for _ in range(int(round((end - start) * 10))):
            writer.write(frame)
    writer.release()
    test_image = cv2.imread(str(ROOT / "test_image.png"))
    cv2.imwrite(str(d / "ref_cat.jpg"), test_image[191:839, 200:684])
    office = cv2.imread(str(ROOT / "assets/samples/office.jpg"))
    cv2.imwrite(str(d / "ref_knife.jpg"), office)
    writer = cv2.VideoWriter(str(d / "ref_knife.mp4"), cv2.VideoWriter_fourcc(*"mp4v"), 10, (447, 447))
    for i in range(20):
        m = cv2.getRotationMatrix2D((223, 223), i * 0.5, 1.0 + i * 0.005)
        writer.write(cv2.warpAffine(office, m, (447, 447)))
    writer.release()
    bike = sorted((ROOT / "classification/test/bicycle").glob("*.jpg"))[0]
    shutil.copy(bike, d / "ref_bicycle.jpg")
    (d / "corrupt.mp4").write_bytes(b"not a video" * 100)
    return d


def _search(media, reference=None, video="target.mp4", **data):
    files = {"video": (video, (media / video).read_bytes(), "video/mp4")}
    if reference:
        files["reference"] = (reference, (media / reference).read_bytes(), "application/octet-stream")
    form = {"precision": "strict", "sample_rate": "2", "confidence": "0.4"}
    form.update({k: str(v) for k, v in data.items()})
    response = client.post("/video/reference_search", files=files, data=form)
    if response.status_code != 200:
        return response, None
    job_id = response.json()["job_id"]
    for _ in range(1200):
        job = client.get(f"/video/reference_search/{job_id}").json()
        if job["status"] in ("completed", "failed", "cancelled"):
            return response, job
        time.sleep(0.25)
    pytest.fail("reference search did not finish")


def _in_segment(seconds, image):
    seg = next(s for s in SEGMENTS if s[0] == image)
    return seg[1] <= seconds < seg[2]


def test_reference_image_finds_matching_scene_with_timestamp(media):
    _, job = _search(media, "ref_knife.jpg")
    assert job["status"] == "completed", job["error"]
    assert job["matches"], "expected the knife scene to be found"
    first = job["matches"][0]
    assert _in_segment(first["seconds"], "assets/samples/office.jpg")
    assert first["frame_index"] == round(first["seconds"] * 10)
    assert 0.72 <= first["similarity"] <= 1.0  # strict threshold from the website
    frame = client.get(first["thumbnail_url"])
    assert frame.status_code == 200 and frame.headers["content-type"] == "image/jpeg"


def test_reference_crop_matches_other_scene(media):
    _, job = _search(media, "ref_cat.jpg")
    assert job["status"] == "completed"
    assert job["matches"] and all(_in_segment(m["seconds"], "test_image.png") for m in job["matches"])


def test_reference_video_is_supported(media):
    _, job = _search(media, "ref_knife.mp4", restrict_category="false")
    assert job["status"] == "completed", job["error"]
    assert len(job["reference"]) >= 1
    assert job["matches"] and _in_segment(job["matches"][0]["seconds"], "assets/samples/office.jpg")


def test_absent_object_returns_genuine_no_match(media):
    _, job = _search(media, "ref_bicycle.jpg")
    assert job["status"] == "completed"
    assert job["matches"] == []


def test_corrupt_video_and_bad_type_are_rejected(media):
    response, _ = _search(media, "ref_cat.jpg", video="corrupt.mp4")
    assert response.status_code == 400
    bad = client.post("/video/reference_search", files={"video": ("a.txt", b"abc", "text/plain")},
                      data={"category": "cup"})
    assert bad.status_code == 400


def test_storage_summary_matches_files_on_disk():
    summary = client.get("/storage/summary").json()
    expected_bytes = 0
    expected_files = 0
    for path in project_insights._iter_files(ROOT):
        expected_bytes += path.stat().st_size
        expected_files += 1
    assert summary["total_files"] == expected_files
    assert summary["total_bytes"] == expected_bytes
    assert sum(c["bytes"] for c in summary["categories"]) == summary["total_bytes"]
    assert sum(c["files"] for c in summary["categories"]) == summary["total_files"]


def test_dataset_split_counts_match_folders():
    data = client.get("/dataset/splits").json()["datasets"]
    svd = next(d for d in data if d["name"] == "smart vision detection")
    train = next(s for s in svd["splits"] if s["split"] == "train")
    images = [p for p in (ROOT / "smart vision detection/train/images").iterdir()
              if p.suffix.lower() in project_insights.IMAGE_EXTENSIONS]
    assert train["images"] == len(images)
    test_split = next(s for s in svd["splits"] if s["split"] == "test")
    assert test_split["status"] == "not_configured"  # data.yaml defines no test split


def test_training_status_reports_real_runs_without_starting_training():
    status = client.get("/training/status").json()
    assert status["active_job"] is None
    for run in status["yolo_runs"]:
        assert run["status"] in ("completed", "incomplete", "no_results")


def test_evaluation_results_are_computed_from_reports():
    results = client.get("/evaluation/results").json()
    overall = results["detection_accuracy"]["overall"]
    tp, fp = overall["tp"], overall["fp"]
    assert overall["precision"] == round(tp / (tp + fp), 4)
    assert results["map"]["available"] in (True, False)
    if not results["map"]["available"]:
        assert "not been computed" in results["map"]["reason"]


def test_face_registry_rename_and_delete(tmp_path, monkeypatch):
    if ai_server.face_service is None:
        pytest.skip("face service not constructed")
    faces = tmp_path / "faces"
    faces.mkdir()
    for name in ("Asha_0.jpg", "Asha_1.jpg", "Ravi_0.jpg"):
        cv2.imwrite(str(faces / name), np.zeros((20, 20, 3), np.uint8))
    monkeypatch.setattr(ai_server.face_service, "faces_dir", str(faces))
    people = client.get("/face/registered").json()["people"]
    assert [(p["name"], p["samples"]) for p in people] == [("Asha", 2), ("Ravi", 1)]
    assert client.post("/face/registered/Asha/rename", json={"new_name": "Ravi"}).status_code == 409
    assert client.post("/face/registered/Asha/rename", json={"new_name": "Asha K"}).status_code == 200
    assert client.delete("/face/registered/Ravi").status_code == 200
    names = [p["name"] for p in client.get("/face/registered").json()["people"]]
    assert names == ["Asha K"]
    assert client.delete("/face/registered/Ravi").status_code == 404


def test_recognize_all_requires_models():
    if ai_server.face_service is not None and ai_server.face_service.is_available():
        pytest.skip("models available; covered by tests/test_face_service.py")
    ok, buf = cv2.imencode(".jpg", np.zeros((64, 64, 3), np.uint8))
    import base64
    response = client.post("/face/recognize_all", json={"image": base64.b64encode(buf).decode()})
    assert response.status_code == 503


def test_existing_health_contract_unchanged():
    assert client.get("/health").json() == {"status": "healthy"}
