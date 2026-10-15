"""Retrieval-grounding tests for the Vision Chatbot application knowledge."""

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from ai.chatbot import knowledge_base as kb  # noqa: E402
from ai.chatbot.smart_assistant import SmartVisionAssistant  # noqa: E402
from evaluate_chatbot import CASES  # noqa: E402


@pytest.mark.parametrize("question,paraphrase,expected", CASES)
def test_question_and_paraphrase_retrieve_expected_section(question, paraphrase, expected):
    for text in (question, paraphrase):
        hits = kb.retrieve(text)
        assert hits and hits[0][1]["id"] == expected, (text, [h[1]["id"] for h in hits])
        assert kb.is_application_question(text, hits)


def test_answers_without_llm_cite_the_guide(monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    answer = SmartVisionAssistant().ask("How do I register a face?")
    assert "Source: Smart Vision guide – Register a face" in answer


def test_general_and_scene_questions_are_not_forced_into_the_guide():
    for text in ("hello", "what is 12 * 7?", "tell me a joke"):
        assert not kb.is_application_question(text, kb.retrieve(text))
    hits = kb.retrieve("what do you see in the camera?")
    assert not kb.is_application_question("what do you see in the camera?", hits, has_detections=True)


def test_ambiguous_question_asks_for_clarification():
    answer = kb.compose_answer("How do I upload a video?", kb.retrieve("How do I upload a video?"))
    assert answer.startswith("Do you mean")


def test_flutter_asset_is_in_sync_with_markdown():
    data = json.loads((ROOT / "assets/knowledge/smartvision_knowledge.json").read_text())
    md_sections = kb.parse_markdown((ROOT / "knowledge/smartvision_knowledge.md").read_text())
    assert [s["id"] for s in data["sections"]] == [s["id"] for s in md_sections], \
        "run python scripts/build_knowledge_base.py"
    assert data["sections"] == md_sections
