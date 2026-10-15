"""Background jobs for Fast Video Review reference search (used by ai_server.py).

Videos are streamed to disk by the API, processed in a worker thread, and the
mobile app polls the job for real progress and results. Matching frames are
written as JPEG thumbnails inside the job directory.
"""

from __future__ import annotations

import shutil
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Callable, Dict, Optional

import cv2

JOB_ROOT = Path(tempfile.gettempdir()) / "smartvision_reference_jobs"
JOB_TTL_SECONDS = 2 * 60 * 60
MAX_ACTIVE_JOBS = 2


class ReferenceSearchJobs:
    def __init__(self, engine_factory: Callable[[], object]):
        self._engine_factory = engine_factory
        self._engine = None
        self._engine_lock = threading.Lock()
        self._lock = threading.Lock()
        self._jobs: Dict[str, Dict] = {}
        JOB_ROOT.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------ helpers
    def engine(self):
        with self._engine_lock:
            if self._engine is None:
                self._engine = self._engine_factory()
            return self._engine

    def new_job_dir(self) -> Path:
        self.cleanup()
        job_id = uuid.uuid4().hex
        path = JOB_ROOT / job_id
        path.mkdir(parents=True, exist_ok=True)
        return path

    def active_count(self) -> int:
        with self._lock:
            return sum(1 for j in self._jobs.values() if j["status"] in ("queued", "running"))

    def cleanup(self) -> None:
        now = time.time()
        with self._lock:
            expired = [k for k, j in self._jobs.items()
                       if j["status"] not in ("queued", "running") and now - j["updated_at"] > JOB_TTL_SECONDS]
            for key in expired:
                job = self._jobs.pop(key)
                shutil.rmtree(job["dir"], ignore_errors=True)

    def get(self, job_id: str) -> Optional[Dict]:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return None
            public = {k: v for k, v in job.items() if k not in ("dir", "cancel", "video_path", "reference_path")}
            public["matches"] = [dict(m) for m in job["matches"]]
            return public

    def frame_path(self, job_id: str, index: int) -> Optional[Path]:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return None
            path = Path(job["dir"]) / f"match_{index:04d}.jpg"
        return path if path.is_file() else None

    def cancel(self, job_id: str) -> bool:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return False
            job["cancel"].set()
            return True

    # -------------------------------------------------------------- start
    def start(self, job_dir: Path, video_path: Path, reference_path: Optional[Path],
              reference_kind: Optional[str], options: Dict) -> str:
        job_id = job_dir.name
        now = time.time()
        job = {
            "job_id": job_id,
            "status": "queued",
            "progress": 0.0,
            "processed_frames": 0,
            "total_frames": 0,
            "matches": [],
            "error": None,
            "method": None,
            "reference": None,
            "target_category": None,
            "options": options,
            "video_name": options.get("video_name"),
            "reference_name": options.get("reference_name"),
            "duration_seconds": None,
            "fps": None,
            "created_at": now,
            "updated_at": now,
            "dir": str(job_dir),
            "video_path": str(video_path),
            "reference_path": str(reference_path) if reference_path else None,
            "cancel": threading.Event(),
        }
        with self._lock:
            self._jobs[job_id] = job
        thread = threading.Thread(
            target=self._run, args=(job_id, video_path, reference_path, reference_kind, options),
            name=f"reference-search-{job_id[:8]}", daemon=True,
        )
        thread.start()
        return job_id

    def _update(self, job_id: str, **fields) -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is not None:
                job.update(fields)
                job["updated_at"] = time.time()

    def _run(self, job_id, video_path, reference_path, reference_kind, options) -> None:
        self._update(job_id, status="running")
        job_dir = video_path.parent
        cancel_event = self._jobs[job_id]["cancel"]
        try:
            engine = self.engine()
            rotation = int(options.get("rotation", 0))
            references = []
            if reference_path is not None:
                if reference_kind == "video":
                    references = engine.prepare_reference_video(str(reference_path), rotation=rotation)
                else:
                    image = cv2.imread(str(reference_path))
                    if image is None:
                        raise ValueError("The reference image could not be decoded.")
                    references = [engine.prepare_reference(image)]

            category = (options.get("category") or "").strip().lower() or None
            if references and category is None and options.get("restrict_category", True):
                if any(r.is_person for r in references):
                    category = "person"
                else:
                    cats = [r.category for r in references if r.category]
                    category = max(set(cats), key=cats.count) if cats else None
            if not references and category is None:
                raise ValueError("Choose a reference image/video or an object category.")

            self._update(job_id, reference=[r.summary() for r in references], target_category=category)

            def write_frame(index, image):
                name = f"match_{index:04d}.jpg"
                cv2.imwrite(str(job_dir / name), image, [cv2.IMWRITE_JPEG_QUALITY, 85])
                return name

            def progress(value, frame, total):
                self._update(job_id, progress=round(value, 4), processed_frames=frame, total_frames=total)

            def on_match(match):
                with self._lock:
                    self._jobs[job_id]["matches"].append(match)

            result = engine.search(
                str(video_path),
                references,
                precision=options.get("precision", "strict"),
                sample_rate=int(options.get("sample_rate", 1)),
                confidence=float(options.get("confidence", 0.4)),
                rotation=rotation,
                target_category=category,
                frame_writer=write_frame,
                progress=progress,
                is_cancelled=cancel_event.is_set,
                on_match=on_match,
            )
            self._update(
                job_id,
                status="cancelled" if result.cancelled else "completed",
                method=result.method,
                processed_frames=result.processed_frames,
                total_frames=result.total_frames,
                sampled_frames=result.sampled_frames,
                fps=round(result.fps, 3),
                duration_seconds=round(result.duration_seconds, 3),
                progress=1.0 if not result.cancelled else self._jobs[job_id]["progress"],
            )
        except Exception as exc:  # reported to the client, never hidden
            self._update(job_id, status="failed", error=str(exc))
        finally:
            for path in (video_path, reference_path):
                try:
                    if path is not None:
                        Path(path).unlink(missing_ok=True)
                except OSError:
                    pass
