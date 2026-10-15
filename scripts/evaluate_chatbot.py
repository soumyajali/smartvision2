"""Evaluate the Vision Chatbot on Smart Vision application questions.

Runs the real SmartVisionAssistant (the same code the website and the
/chatbot/query endpoint use) with NO LLM key, so every answer comes from the
retrieval-grounded path or the built-in engine. Records the actual responses in
knowledge/chatbot_evaluation.md and knowledge/chatbot_evaluation.json.

    python scripts/evaluate_chatbot.py
"""

import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
os.environ.pop("OPENAI_API_KEY", None)
os.environ.pop("GEMINI_API_KEY", None)

from ai.chatbot.knowledge_base import get_knowledge_base, retrieve  # noqa: E402
from ai.chatbot.smart_assistant import SmartVisionAssistant  # noqa: E402

# (question, paraphrase, expected section id)
CASES = [
    ("What is Smart Vision?", "Can you give me an overview of this app?", "what-is-smart-vision"),
    ("How do I detect an object in an image?", "How can I find objects in a photo from my gallery?", "detect-objects-in-an-image"),
    ("How do I start live detection?", "How do I begin real-time scanning with the camera?", "start-live-camera-detection"),
    ("Why is my camera not working?", "The camera preview is black, what should I do?", "camera-not-working"),
    ("How do I upload a reference video?", "Where do I pick the sample clip to search with?", "upload-a-reference-video-or-image"),
    ("How does Fast Video Review find matching frames?", "What algorithm compares frames in video review?", "how-fast-video-review-finds-matching-frames"),
    ("Where can I see the matching timestamp?", "At what time in the clip was the match found?", "matching-timestamps-and-similarity-scores"),
    ("How do I register a face?", "How can I enroll a new person?", "register-a-face"),
    ("How does a registered face get identified?", "How does the app recognise who someone is?", "how-a-registered-face-is-identified"),
    ("What happens when an unknown face appears?", "What is shown for a stranger who is not registered?", "unknown-faces"),
    ("How do I extract text using OCR?", "How can I read the words in a document picture?", "extract-text-with-ocr"),
    ("How do I translate extracted text?", "Can I convert the scanned text into Hindi?", "translate-extracted-text"),
    ("How do I summarize extracted text?", "Can it shorten the recognised text into a brief?", "summarize-extracted-text"),
    ("How does the Drowsiness Monitor work?", "How does it know if I'm getting sleepy?", "drowsiness-monitor"),
    ("What does Research Evaluation show?", "Where can I see the model's evaluation metrics?", "research-evaluation"),
    ("What is the difference between precision and recall?", "Explain precision versus recall", "precision-recall-f1-and-map-explained"),
    ("How much storage does the application use?", "How much disk space do the datasets and models take?", "storage-used-by-the-application"),
    ("What is the training dataset?", "Which data is the model trained on?", "training-validation-and-test-datasets"),
    ("What is the validation dataset?", "What is the val split used for?", "training-validation-and-test-datasets"),
    ("What is the testing dataset?", "What is the test split?", "training-validation-and-test-datasets"),
    ("How do I check training status?", "Is a model being trained right now?", "check-training-status"),
    ("Why is detection failing on my phone?", "Nothing gets detected on my mobile, why?", "detection-failing-or-inaccurate-on-the-phone"),
    ("Why is the backend disconnected?", "The server shows offline, how do I connect it?", "backend-connection"),
    ("Which features require internet access?", "What works offline without the server?", "features-that-need-internet-or-the-backend"),
    ("How do I troubleshoot a failed video upload?", "My video won't upload to the server, help", "video-upload-failed"),
    ("How do I use AutoML & Dataset Pipeline?", "What is the AutoML page for?", "using-automl-dataset-pipeline"),
    ("What does the Vision Chatbot do?", "What can the chat assistant answer?", "vision-chatbot"),
    ("How do I use the Voice Assistant?", "Can I talk to the app with my voice?", "voice-assistant"),
    ("Where is detection history?", "Where are my previous scans saved?", "detection-history"),
    ("How do I change detection settings?", "How do I adjust the confidence threshold?", "detection-settings"),
]

TITLES = {s["id"]: s["title"] for s in get_knowledge_base().sections}

AMBIGUOUS = ["How do I upload a video?"]
GENERAL = ["hello", "what is 12 * 7?", "tell me a joke"]
FOLLOW_UP = [("How do I extract text using OCR?", "and how do I translate it?", "translate-extracted-text")]


def run():
    rows = []
    for question, paraphrase, expected in CASES:
        for kind, text in (("original", question), ("paraphrase", paraphrase)):
            assistant = SmartVisionAssistant()
            response = assistant.ask(text)
            hits = retrieve(text)
            top = hits[0][1]["id"] if hits else None
            rows.append({
                "kind": kind, "question": text, "expected_section": expected,
                "retrieved_section": top, "retrieval_correct": top == expected,
                "grounded": "Source: Smart Vision guide" in response and top == expected,
                "response": response,
            })
    extra = []
    for text in AMBIGUOUS:
        extra.append({"kind": "ambiguous", "question": text, "response": SmartVisionAssistant().ask(text)})
    for text in GENERAL:
        extra.append({"kind": "general", "question": text, "response": SmartVisionAssistant().ask(text)})
    for first, second, expected in FOLLOW_UP:
        assistant = SmartVisionAssistant()
        assistant.ask(first)
        response = assistant.ask(second)
        extra.append({"kind": "follow-up", "question": f"{first} → {second}", "expected_section": expected,
                      "response": response,
                      "grounded": f"– {TITLES[expected]}" in response})
    return rows, extra


def main():
    rows, extra = run()
    out_dir = ROOT / "knowledge"
    (out_dir / "chatbot_evaluation.json").write_text(json.dumps({"cases": rows, "extra": extra}, indent=1))
    ok = sum(r["grounded"] for r in rows)
    lines = [
        "# Vision Chatbot evaluation",
        "",
        "Generated by `python scripts/evaluate_chatbot.py`. The assistant ran **without any LLM key**,",
        "so every answer below is the actual output of the retrieval-grounded path",
        "(`ai/chatbot/knowledge_base.py`) or the built-in engine. With a Gemini/OpenAI key the",
        "same retrieved sections are passed to the LLM as context.",
        "",
        f"**Grounded in the expected guide section: {ok}/{len(rows)}** "
        f"(30 required questions + 30 paraphrases).",
        "",
        "| # | Kind | Question | Expected section | Retrieved | Grounded |",
        "|---|---|---|---|---|---|",
    ]
    for i, r in enumerate(rows, 1):
        lines.append(f"| {i} | {r['kind']} | {r['question']} | {r['expected_section']} | "
                     f"{r['retrieved_section']} | {'yes' if r['grounded'] else '**no**'} |")
    lines += ["", "## Other behaviour", ""]
    for e in extra:
        lines += [f"**{e['kind']}** — _{e['question']}_", "", "> " + e["response"].replace("\n", "\n> "), ""]
    lines += ["## Full responses", ""]
    for i, r in enumerate(rows, 1):
        lines += [f"### {i}. {r['question']}", "", "> " + r["response"].replace("\n", "\n> "), ""]
    (out_dir / "chatbot_evaluation.md").write_text("\n".join(lines))
    print(f"grounded {ok}/{len(rows)}")
    for e in extra:
        print(e["kind"], "|", e["question"], "|", e["response"][:140].replace("\n", " "))
    return 0 if ok == len(rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
