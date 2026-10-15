"""Read-only, measured project information for the AutoML & Dataset Pipeline and
Research Evaluation screens (served by ai_server.py).

Everything here is computed from files on the backend's disk. Nothing is
estimated: if something does not exist it is returned as ``None`` /
"not_configured" so the clients can show "Unavailable".
"""

from __future__ import annotations

import csv
import json
import os
import shutil
import time
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

import yaml

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tif", ".tiff"}
VIDEO_EXTENSIONS = {".mp4", ".mov", ".avi", ".mkv", ".webm", ".m4v"}
WEIGHT_EXTENSIONS = {".pt", ".pth", ".tflite", ".onnx", ".task", ".pkl", ".safetensors", ".bin"}
SKIP_DIRS = {".git", "venv", ".venv", "node_modules", "__pycache__", ".dart_tool", "build",
             ".idea", ".gradle", "Pods"}

# Category rules are evaluated in order; each file is counted once (first match).
STORAGE_CATEGORIES: List[Tuple[str, str, Tuple[str, ...]]] = [
    ("datasets", "Datasets", ("datasets/", "smart vision detection/", "classification/",
                              "dummy_classification_dataset/", "ai-chatbot/datasets/")),
    ("checkpoints", "Checkpoints & training artifacts", ("ai-chatbot/checkpoints/", "runs/")),
    ("uploads", "Uploaded / captured media", ("recordings/", "detections/", "known_faces/", "uploads/")),
    ("database", "Databases & indexes", ()),
    ("weights", "Model weights", ("weights/",)),
    ("reports", "Generated reports", ()),
]


def _iter_files(root: Path) -> Iterable[Path]:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        for name in filenames:
            yield Path(dirpath) / name


def _category_for(rel: str, path: Path) -> str:
    ext = path.suffix.lower()
    for key, _label, prefixes in STORAGE_CATEGORIES:
        if prefixes and any(rel.startswith(p) for p in prefixes):
            return key
    if ext in {".db", ".sqlite", ".sqlite3", ".faiss"} or rel == "face_metadata.json":
        return "database"
    if ext in WEIGHT_EXTENSIONS or rel.startswith("haarcascade"):
        return "weights"
    if ext == ".pdf" or rel.endswith(("_report.json", "_results.json")) or rel in (
            "TEST_REPORT.md", "Project_Report.md"):
        return "reports"
    if ext in VIDEO_EXTENSIONS:
        return "uploads"
    return "other"


def storage_summary(root: str = ".") -> Dict:
    """Measured storage by category (each file counted once)."""
    base = Path(root).resolve()
    labels = {key: label for key, label, _ in STORAGE_CATEGORIES}
    labels["other"] = "Source code & other project files"
    totals = {key: {"bytes": 0, "files": 0, "largest": []} for key in labels}
    total_bytes = 0
    total_files = 0
    for path in _iter_files(base):
        try:
            size = path.stat().st_size
        except OSError:
            continue
        rel = path.relative_to(base).as_posix()
        key = _category_for(rel, path)
        bucket = totals[key]
        bucket["bytes"] += size
        bucket["files"] += 1
        bucket["largest"].append((size, rel))
        total_bytes += size
        total_files += 1
    categories = []
    for key, bucket in totals.items():
        largest = sorted(bucket["largest"], reverse=True)[:5]
        categories.append({
            "key": key,
            "label": labels[key],
            "bytes": bucket["bytes"],
            "files": bucket["files"],
            "percent": round(bucket["bytes"] * 100.0 / total_bytes, 2) if total_bytes else 0.0,
            "largest_files": [{"path": p, "bytes": s} for s, p in largest],
        })
    categories.sort(key=lambda c: c["bytes"], reverse=True)

    disk = None
    try:
        usage = shutil.disk_usage(str(base))
        disk = {"total_bytes": usage.total, "used_bytes": usage.used, "free_bytes": usage.free}
    except OSError:
        disk = None
    return {
        "scope": "backend project folder",
        "root": str(base),
        "measured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "total_bytes": total_bytes,
        "total_files": total_files,
        "excluded_directories": sorted(SKIP_DIRS),
        "categories": categories,
        "backend_disk": disk,
    }


def _count_dir(path: Path, extensions) -> Tuple[Optional[int], int]:
    """Return (file count or None if the folder is missing, total bytes)."""
    if not path.is_dir():
        return None, 0
    count = 0
    size = 0
    for item in path.rglob("*"):
        if item.is_file() and item.suffix.lower() in extensions:
            count += 1
            try:
                size += item.stat().st_size
            except OSError:
                pass
    return count, size


def _count_annotations(label_dir: Path) -> Optional[int]:
    if not label_dir.is_dir():
        return None
    total = 0
    for item in label_dir.rglob("*.txt"):
        try:
            with item.open() as handle:
                total += sum(1 for line in handle if line.strip())
        except OSError:
            continue
    return total


def _labels_dir_for(images_dir: Path) -> Path:
    parts = list(images_dir.parts)
    if "images" in parts:
        idx = len(parts) - 1 - parts[::-1].index("images")
        parts[idx] = "labels"
        return Path(*parts)
    return images_dir.parent / "labels"


def _yolo_dataset(name: str, yaml_path: Path, root: Path) -> Dict:
    data = yaml.safe_load(yaml_path.read_text()) or {}
    names = data.get("names", [])
    if isinstance(names, dict):
        names = list(names.values())
    # Resolve the dataset base folder; absolute paths from another machine are
    # replaced by the YAML's own folder.
    declared = data.get("path")
    base = yaml_path.parent
    if declared and Path(declared).is_dir():
        base = Path(declared)
    splits = []
    for split, aliases in (("train", ("train",)), ("validation", ("val", "valid")), ("test", ("test",))):
        key = next((a for a in aliases if data.get(a)), None)
        if key is None:
            splits.append({"split": split, "status": "not_configured"})
            continue
        rel = data[key]
        images_dir = (base / rel) if not Path(rel).is_absolute() else Path(rel)
        labels_dir = _labels_dir_for(images_dir)
        images, image_bytes = _count_dir(images_dir, IMAGE_EXTENSIONS)
        labels, label_bytes = _count_dir(labels_dir, {".txt"})
        annotations = _count_annotations(labels_dir)
        status = "ok" if images is not None else ("labels_only" if labels is not None else "missing")
        splits.append({
            "split": split,
            "status": status,
            "images": images,
            "label_files": labels,
            "annotations": annotations,
            "bytes": image_bytes + label_bytes,
            "images_path": _rel(images_dir, root),
            "labels_path": _rel(labels_dir, root),
        })
    _add_percentages(splits)
    return {
        "name": name,
        "format": "YOLO (txt labels)",
        "config": _rel(yaml_path, root),
        "num_classes": data.get("nc", len(names) or None),
        "class_names": names,
        "splits": splits,
    }


def _classification_dataset(name: str, folder: Path, root: Path) -> Dict:
    splits = []
    classes = set()
    for split, aliases in (("train", ("train",)), ("validation", ("val", "valid", "validation")), ("test", ("test",))):
        split_dir = next((folder / a for a in aliases if (folder / a).is_dir()), None)
        if split_dir is None:
            splits.append({"split": split, "status": "not_configured"})
            continue
        images, size = _count_dir(split_dir, IMAGE_EXTENSIONS)
        for child in split_dir.iterdir():
            if child.is_dir():
                classes.add(child.name)
        splits.append({
            "split": split,
            "status": "ok",
            "images": images,
            "label_files": None,
            "annotations": images,  # one class label per image (folder name)
            "bytes": size,
            "images_path": _rel(split_dir, root),
        })
    _add_percentages(splits)
    return {
        "name": name,
        "format": "Image classification (class folders)",
        "config": _rel(folder, root),
        "num_classes": len(classes) or None,
        "class_names": sorted(classes),
        "splits": splits,
    }


def _add_percentages(splits: List[Dict]) -> None:
    def amount(s):
        if s.get("images") is not None:
            return s["images"]
        return s.get("label_files") or 0
    total = sum(amount(s) for s in splits if s.get("status") not in ("not_configured",))
    for s in splits:
        if s.get("status") == "not_configured":
            s["percent"] = None
        else:
            s["percent"] = round(amount(s) * 100.0 / total, 2) if total else None
    for s in splits:
        s["percent_basis"] = "images" if any(x.get("images") for x in splits) else "label files"


def _rel(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return str(path)


def dataset_splits(root: str = ".") -> List[Dict]:
    base = Path(root)
    datasets = []
    for name, rel in (("custom_objects", "datasets/custom_objects/data.yaml"),
                      ("smart vision detection", "smart vision detection/data.yaml")):
        path = base / rel
        if path.is_file():
            try:
                datasets.append(_yolo_dataset(name, path, base))
            except Exception as exc:
                datasets.append({"name": name, "config": rel, "error": str(exc), "splits": []})
    for name, rel in (("classification", "classification"),
                      ("dummy_classification_dataset", "dummy_classification_dataset")):
        if (base / rel).is_dir():
            datasets.append(_classification_dataset(name, base / rel, base))
    return datasets


def _read_results_csv(path: Path) -> Optional[Dict]:
    try:
        with path.open() as handle:
            rows = [{k.strip(): v.strip() for k, v in row.items()} for row in csv.DictReader(handle)]
    except OSError:
        return None
    if not rows:
        return None
    last = rows[-1]

    def num(key):
        try:
            return float(last[key])
        except (KeyError, ValueError):
            return None
    return {
        "epochs_completed": len(rows),
        "precision": num("metrics/precision(B)"),
        "recall": num("metrics/recall(B)"),
        "map50": num("metrics/mAP50(B)"),
        "map50_95": num("metrics/mAP50-95(B)"),
        "history": [
            {
                "epoch": int(float(r.get("epoch", i))) if r.get("epoch") else i,
                "map50": _maybe_float(r.get("metrics/mAP50(B)")),
                "precision": _maybe_float(r.get("metrics/precision(B)")),
                "recall": _maybe_float(r.get("metrics/recall(B)")),
            }
            for i, r in enumerate(rows, start=1)
        ],
    }


def _maybe_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def training_runs(root: str = ".") -> Dict:
    base = Path(root)
    runs = []
    runs_dir = base / "runs"
    if runs_dir.is_dir():
        for args_file in sorted(runs_dir.glob("*/*/args.yaml")):
            run_dir = args_file.parent
            try:
                args = yaml.safe_load(args_file.read_text()) or {}
            except Exception:
                args = {}
            results = _read_results_csv(run_dir / "results.csv") if (run_dir / "results.csv").is_file() else None
            weights = sorted(p.name for p in (run_dir / "weights").glob("*.pt")) if (run_dir / "weights").is_dir() else []
            epochs = args.get("epochs")
            if results and epochs and results["epochs_completed"] >= int(epochs) and weights:
                status = "completed"
            elif results:
                status = "incomplete"
            else:
                status = "no_results"
            runs.append({
                "run": _rel(run_dir, base),
                "task": args.get("task"),
                "model": args.get("model"),
                "dataset": args.get("data"),
                "epochs_configured": epochs,
                "image_size": args.get("imgsz"),
                "batch": args.get("batch"),
                "device": args.get("device"),
                "status": status,
                "results": results,
                "weights": weights,
                "last_modified": _mtime(run_dir),
            })
    lora = None
    metrics_file = base / "ai-chatbot/checkpoints/qwen_chatbot_lora/training_metrics.json"
    if metrics_file.is_file():
        try:
            data = json.loads(metrics_file.read_text())
            lora = {
                "base_model": data.get("base_model"),
                "steps_trained": data.get("steps_trained"),
                "final_train_loss": data.get("final_train_loss"),
                "val_loss": data.get("val_loss"),
                "val_perplexity": data.get("val_perplexity"),
                "history": data.get("training_history", []),
                "file": _rel(metrics_file, base),
                "last_modified": _mtime(metrics_file),
            }
        except Exception:
            lora = None
    artifacts = []
    for candidate in ("yolov8n.pt", "yolov8m.pt", "yolov8s-world.pt", "SmartVision_v3.pt",
                      "weights/smartvision_best.pt", "MobileNET_best.pth", "yolov8n.tflite",
                      "assets/models/yolov8n.tflite"):
        path = base / candidate
        if path.is_file():
            artifacts.append({"file": candidate, "bytes": path.stat().st_size, "last_modified": _mtime(path)})
    return {
        "active_job": None,
        "job_manager": "The backend has no training job manager; training is run with the "
                       "project scripts (ai/train.py, scripts/train_and_evaluate.py, notebooks).",
        "yolo_runs": runs,
        "chatbot_lora": lora,
        "artifacts": artifacts,
        "note": "Timestamps are file modification times on the backend disk.",
    }


def _mtime(path: Path) -> Optional[str]:
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(path.stat().st_mtime))
    except OSError:
        return None


def _prf(tp: int, fp: int, fn: int) -> Dict:
    precision = tp / (tp + fp) if tp + fp else None
    recall = tp / (tp + fn) if tp + fn else None
    f1 = (2 * precision * recall / (precision + recall)) if precision and recall else None
    return {"tp": tp, "fp": fp, "fn": fn,
            "precision": round(precision, 4) if precision is not None else None,
            "recall": round(recall, 4) if recall is not None else None,
            "f1": round(f1, 4) if f1 is not None else None}


def evaluation_results(root: str = ".") -> Dict:
    """Collects evaluation results that already exist in the project."""
    base = Path(root)
    sources = []

    def load(rel):
        path = base / rel
        if not path.is_file():
            return None
        try:
            data = json.loads(path.read_text())
        except Exception:
            return None
        sources.append({"file": rel, "last_modified": _mtime(path)})
        return data

    out: Dict = {"sources": sources}

    acc = load("tests/accuracy_conditions_report.json")
    if acc:
        scenarios = []
        tp = fp = fn = 0
        for r in acc.get("results", []):
            s_tp = len(r.get("correct_matches", []))
            s_fp = len(r.get("false_positives_fp", []))
            s_fn = len(r.get("missed_detections_fn", []))
            tp, fp, fn = tp + s_tp, fp + s_fp, fn + s_fn
            scenarios.append({
                "id": r.get("test_id"),
                "scenario": r.get("scenario"),
                "latency_ms": r.get("latency_ms"),
                "detections": r.get("total_detections"),
                "status": r.get("status"),
                **_prf(s_tp, s_fp, s_fn),
            })
        out["detection_accuracy"] = {
            "method": "Class-level matching of detected labels against expected labels per test "
                      "scenario (tests/test_accuracy_conditions.py). This is not box-level mAP.",
            "model": acc.get("summary", {}).get("model_tested"),
            "hardware": acc.get("summary", {}).get("hardware"),
            "date": acc.get("summary", {}).get("date"),
            "overall": _prf(tp, fp, fn),
            "scenarios": scenarios,
        }

    bench = load("tests/benchmark_results.json")
    if bench:
        out["latency_benchmark"] = {k: bench.get(k) for k in (
            "num_frames", "avg_fps", "avg_latency_ms", "median_latency_ms", "p95_latency_ms",
            "min_latency_ms", "max_latency_ms", "cpu_usage_pct", "target_met_10fps", "target_met_200ms")}
        out["latency_benchmark"]["device"] = bench.get("device")

    dist = load("tests/distance_validation_report.json")
    if dist:
        out["distance_estimation"] = dist.get("metrics")
        out["distance_estimation"]["measurements"] = len(dist.get("measurements", []))

    ocr = load("tests/ocr_test_results.json")
    if ocr:
        out["ocr"] = {
            "baseline_cer": ocr.get("image_ocr_baseline", {}).get("cer"),
            "baseline_wer": ocr.get("image_ocr_baseline", {}).get("wer"),
            "complex_cer": ocr.get("complex_text_accuracy", {}).get("cer"),
            "complex_wer": ocr.get("complex_text_accuracy", {}).get("wer"),
            "degradation_cer": ocr.get("degradation"),
        }

    chat = load("ai-chatbot/checkpoints/evaluation_report.json")
    if chat:
        details = chat.get("detailed_results", [])
        out["chatbot_model"] = {
            "model": chat.get("model_name"),
            "tests_passed": sum(1 for d in details if d.get("passed")),
            "tests_total": len(details),
            "tokens_per_second": chat.get("average_generation_speed_tok_sec"),
        }

    runs = training_runs(root)["yolo_runs"]
    with_map = [r for r in runs if r.get("results") and r["results"].get("map50") is not None]
    out["map"] = (
        {"available": True, "runs": [{"run": r["run"], **{k: r["results"][k] for k in (
            "precision", "recall", "map50", "map50_95", "epochs_completed")}} for r in with_map]}
        if with_map else
        {"available": False,
         "reason": "No YOLO validation results (runs/*/*/results.csv) exist in the project, so "
                   "mAP has not been computed."}
    )

    reports = []
    for rel in ("TEST_REPORT.md", "PIPELINE_GUIDE.md", "FEATURES_IMPLEMENTED.md",
                "runs/model_evaluation_report.md", "MOBILE_APP_REPAIR_REPORT.md"):
        if (base / rel).is_file():
            reports.append({"name": rel, "bytes": (base / rel).stat().st_size})
    out["reports"] = reports
    out["available"] = bool(sources) or bool(with_map)
    return out


ALLOWED_REPORTS = {"TEST_REPORT.md", "PIPELINE_GUIDE.md", "FEATURES_IMPLEMENTED.md",
                   "runs/model_evaluation_report.md", "MOBILE_APP_REPAIR_REPORT.md"}


def read_report(name: str, root: str = ".") -> Optional[str]:
    if name not in ALLOWED_REPORTS:
        return None
    path = Path(root) / name
    if not path.is_file():
        return None
    return path.read_text(errors="replace")
