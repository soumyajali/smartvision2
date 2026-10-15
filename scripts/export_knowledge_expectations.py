"""Writes test/fixtures/knowledge_expectations.json: the Python retriever's
results for a fixed list of questions. test/knowledge_base_test.dart checks
that the Dart port (lib/services/knowledge_base.dart) returns the same
sections and scores. Re-run after editing knowledge/smartvision_knowledge.md
and scripts/build_knowledge_base.py."""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from ai.chatbot.knowledge_base import (  # noqa: E402
    KnowledgeBase, compose_answer, is_application_question, tokenize,
)

QUESTIONS = [
    ("What is Smart Vision?", ""),
    ("How do I register a face?", ""),
    ("How do I delete a registered person?", ""),
    ("How does reference matching work in Fast Video Review?", ""),
    ("Why is the server offline?", ""),
    ("How much storage do the datasets use?", ""),
    ("Who built this app?", ""),
    ("How do I translate text?", ""),
    ("And how do I summarize it?", "How do I extract text with OCR?"),
    ("settings", ""),
    ("video", ""),
    ("What is the capital of France?", ""),
]


def main() -> None:
    data = json.loads((ROOT / "assets/knowledge/smartvision_knowledge.json").read_text())
    kb = KnowledgeBase(data["sections"])
    cases = []
    for question, context in QUESTIONS:
        hits = kb.search(question, context=context)
        cases.append({
            "question": question,
            "context": context,
            "tokens": tokenize(question),
            "hits": [{"id": s["id"], "score": score} for score, s in hits],
            "application": is_application_question(question, hits),
            "answer": compose_answer(question, hits),
        })
    out = ROOT / "test/fixtures/knowledge_expectations.json"
    out.write_text(json.dumps({"version": data.get("version"), "cases": cases}, indent=1, ensure_ascii=False))
    print(f"wrote {out.relative_to(ROOT)} ({len(cases)} cases)")


if __name__ == "__main__":
    main()
