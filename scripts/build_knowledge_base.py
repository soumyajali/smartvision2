"""Build the chatbot knowledge JSON from knowledge/smartvision_knowledge.md.

Writes:
  knowledge/smartvision_knowledge.json          (backend / website fallback)
  assets/knowledge/smartvision_knowledge.json   (bundled in the Flutter app)

Run after editing the guide:   python scripts/build_knowledge_base.py
"""

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from ai.chatbot.knowledge_base import SOURCE_MD, parse_markdown  # noqa: E402


def main() -> int:
    text = SOURCE_MD.read_text(encoding="utf-8")
    sections = parse_markdown(text)
    payload = {
        "version": hashlib.sha256(text.encode("utf-8")).hexdigest()[:12],
        "source": "knowledge/smartvision_knowledge.md",
        "sections": sections,
    }
    for target in (ROOT / "knowledge" / "smartvision_knowledge.json",
                   ROOT / "assets" / "knowledge" / "smartvision_knowledge.json"):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"wrote {target.relative_to(ROOT)} ({len(sections)} sections, version {payload['version']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
