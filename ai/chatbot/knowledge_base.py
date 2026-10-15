"""Lightweight retrieval over the Smart Vision application guide.

The guide lives in knowledge/smartvision_knowledge.md (one section per "## "
heading). This module splits it into sections and ranks them with BM25 plus a
small synonym table so paraphrased questions find the right section. It has no
third-party dependencies and is mirrored by lib/services/knowledge_base.dart in
the Flutter app (both read the JSON produced by scripts/build_knowledge_base.py).

The language model is NOT fine-tuned: retrieved sections are given to the LLM
as context (or returned directly when no LLM key is configured).
"""

from __future__ import annotations

import json
import math
import re
from functools import lru_cache
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[2]
SOURCE_MD = ROOT / "knowledge" / "smartvision_knowledge.md"
SOURCE_JSON = ROOT / "knowledge" / "smartvision_knowledge.json"

STOPWORDS = {
    "a", "an", "the", "is", "are", "was", "were", "be", "to", "of", "in", "on", "for", "and",
    "or", "it", "this", "that", "with", "as", "at", "by", "from", "do", "does", "did", "i",
    "my", "me", "we", "you", "your", "can", "could", "should", "would", "will", "what",
    "how", "why", "where", "when", "which", "there", "any", "some", "please", "tell",
    "about", "explain", "get", "use",
    "using", "into", "if", "so", "than", "then", "its", "has", "have", "am", "not", "s",
}

# Canonical term -> words that mean the same thing in user questions.
SYNONYMS: Dict[str, Sequence[str]] = {
    "image": ("photo", "picture", "pic", "pictures", "photos", "images", "still"),
    "video": ("clip", "movie", "footage", "recording", "videos"),
    "detect": ("detection", "detecting", "spot", "find", "locate"),
    "identity": ("who", "whom", "whose", "identify", "identified", "identification", "identities",
                 "recognise", "recognize", "recognition", "recognised", "recognized"),
    "camera": ("webcam", "cam", "lens"),
    "face": ("faces", "facial", "person", "people", "someone", "human"),
    "register": ("registration", "enroll", "enrol", "add", "save", "store", "enrolment"),
    "ocr": ("text", "read", "scan", "document", "characters", "words"),
    "translate": ("translation", "translating", "language", "languages", "hindi", "kannada"),
    "summarize": ("summary", "summarise", "summarizing", "shorten", "tldr", "brief"),
    "storage": ("space", "disk", "size", "memory", "bytes", "gb", "mb", "capacity", "consume"),
    "train": ("training", "trained", "epochs", "fit", "learning"),
    "validation": ("val", "valid", "validate"),
    "test": ("testing", "tested", "unseen"),
    "backend": ("server", "api", "computer", "pc", "laptop", "host", "uvicorn"),
    "internet": ("online", "offline", "network", "wifi", "connection", "data"),
    "disconnected": ("offline", "unreachable", "down", "failed", "cannot", "connect"),
    "upload": ("send", "choose", "pick", "select", "submit"),
    "reference": ("sample", "example", "target", "query"),
    "match": ("matching", "matches", "matched", "similar", "similarity", "same", "compare"),
    "timestamp": ("time", "moment", "when", "seconds", "position"),
    "settings": ("preferences", "options", "configure", "configuration", "change", "adjust"),
    "history": ("past", "previous", "saved", "records", "logs", "log"),
    "drowsiness": ("drowsy", "sleepy", "sleep", "tired", "fatigue", "eyes"),
    "chatbot": ("chat", "bot", "assistant", "conversation"),
    "voice": ("speak", "speech", "talk", "microphone", "mic", "say"),
    "unknown": ("unregistered", "stranger", "unrecognized", "unrecognised"),
    "precision": ("accuracy", "accurate"),
    "fail": ("failing", "failed", "broken", "error", "errors", "wrong", "problem", "issue", "not"),
    "working": ("works", "work"),
    "delete": ("remove", "erase", "forget"),
    "builders": ("team", "developers", "creators", "makers", "authors"),
    "live": ("realtime", "real", "streaming"),
}
_CANONICAL = {}
for canon, words in SYNONYMS.items():
    _CANONICAL[canon] = canon
    for word in words:
        _CANONICAL.setdefault(word, canon)

SCENE_PATTERNS = (
    "what do you see", "what can you see", "what is in", "describe the scene", "how many",
    "what objects", "what is visible", "any hazard", "is there a", "are there", "what's in",
    "what did it detect", "count the", "in the camera", "in the image", "in front of",
)


def _stem(word: str) -> str:
    for suffix in ("ations", "ation", "ings", "ing", "ies", "ers", "ed", "es", "s"):
        if word.endswith(suffix) and len(word) - len(suffix) >= 3:
            word = word[: -len(suffix)]
            if suffix == "ies":
                word += "y"
            break
    return word


def tokenize(text: str) -> List[str]:
    tokens = []
    for raw in re.findall(r"[a-z0-9]+", text.lower().replace("smartvision", "smart vision")):
        if raw in STOPWORDS:
            continue
        canon = _CANONICAL.get(raw)
        if canon is None:
            stemmed = _stem(raw)
            canon = _CANONICAL.get(stemmed, stemmed)
        tokens.append(canon)
    return tokens


def parse_markdown(text: str) -> List[Dict]:
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    sections = []
    for block in re.split(r"(?m)^## ", text)[1:]:
        lines = block.strip().splitlines()
        title = lines[0].strip()
        keywords = ""
        body_lines = []
        for line in lines[1:]:
            if line.lower().startswith("keywords:") and not keywords:
                keywords = line.split(":", 1)[1].strip()
            else:
                body_lines.append(line)
        body = "\n".join(body_lines).strip()
        slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
        sections.append({"id": slug, "title": title, "keywords": keywords, "body": body})
    return sections


class KnowledgeBase:
    def __init__(self, sections: List[Dict]):
        self.sections = sections
        self._docs = []
        self._titles = [set(tokenize(s["title"])) for s in sections]
        for s in sections:
            # Title and keywords are weighted by repetition.
            tokens = tokenize(s["title"]) * 3 + tokenize(s["keywords"]) * 2 + tokenize(s["body"])
            self._docs.append(tokens)
        self._avg_len = sum(len(d) for d in self._docs) / max(1, len(self._docs))
        self._df: Dict[str, int] = {}
        for doc in self._docs:
            for term in set(doc):
                self._df[term] = self._df.get(term, 0) + 1

    @classmethod
    def from_markdown(cls, path: Path = SOURCE_MD) -> "KnowledgeBase":
        return cls(parse_markdown(path.read_text(encoding="utf-8")))

    def _idf(self, term: str) -> float:
        n = len(self._docs)
        df = self._df.get(term, 0)
        return math.log(1 + (n - df + 0.5) / (df + 0.5))

    def search(self, query: str, k: int = 3, context: str = "") -> List[Tuple[float, Dict]]:
        terms = tokenize(query)
        # Short follow-ups ("and how do I translate it?") borrow context at half weight.
        context_terms = tokenize(context) if context and len(terms) <= 4 else []
        if not terms and not context_terms:
            return []
        k1, b = 1.5, 0.75
        query_set = set(terms)
        scored = []
        for doc, section, title in zip(self._docs, self.sections, self._titles):
            tf: Dict[str, int] = {}
            for t in doc:
                tf[t] = tf.get(t, 0) + 1
            score = 0.0
            for weight, query_terms in ((1.0, terms), (0.5, context_terms)):
                for term in set(query_terms):
                    f = tf.get(term, 0)
                    if not f:
                        continue
                    denom = f + k1 * (1 - b + b * len(doc) / self._avg_len)
                    score += weight * self._idf(term) * f * (k1 + 1) / denom
            if score > 0 and query_set and title:
                # Bonus when the question and the section title talk about the
                # same thing (covers both directions of the overlap).
                overlap = len(query_set & title)
                score += TITLE_BONUS * (overlap / len(query_set)) * (overlap / len(title))
            if score > 0:
                scored.append((score, section))
        scored.sort(key=lambda item: item[0], reverse=True)
        return scored[:k]


@lru_cache(maxsize=1)
def get_knowledge_base() -> KnowledgeBase:
    if SOURCE_MD.is_file():
        return KnowledgeBase.from_markdown(SOURCE_MD)
    data = json.loads(SOURCE_JSON.read_text(encoding="utf-8"))
    return KnowledgeBase(data["sections"])


MIN_SCORE = 2.5  # below this the question is not about the application
TITLE_BONUS = 6.0


def is_scene_question(question: str) -> bool:
    q = question.lower()
    return any(p in q for p in SCENE_PATTERNS)


def retrieve(question: str, history: Optional[List[Dict]] = None, k: int = 3) -> List[Tuple[float, Dict]]:
    context = ""
    if history:
        previous = [m["content"] for m in history if m.get("role") == "user"]
        if previous:
            context = previous[-1]
    return get_knowledge_base().search(question, k=k, context=context)


def is_application_question(question: str, hits: List[Tuple[float, Dict]], has_detections: bool = False) -> bool:
    if not hits or hits[0][0] < MIN_SCORE:
        return False
    if has_detections and is_scene_question(question):
        return False
    return True


def context_for_llm(hits: List[Tuple[float, Dict]], limit: int = 3) -> str:
    parts = [f"### {s['title']}\n{s['body']}" for _, s in hits[:limit]]
    return "SMART VISION APPLICATION GUIDE (retrieved sections):\n" + "\n\n".join(parts)


def compose_answer(question: str, hits: List[Tuple[float, Dict]]) -> str:
    """Grounded answer used when no LLM is configured: the best section, or a
    clarifying question when the request is ambiguous."""
    if not hits:
        return ("I don't have information about that in the Smart Vision guide. "
                "Could you rephrase or tell me which feature you mean?")
    top_score, top = hits[0]
    words = len(re.findall(r"[a-z0-9]+", question.lower()))
    if len(hits) > 1 and words <= 6:
        second_score, second = hits[1]
        if second_score >= 0.88 * top_score and second["id"] != top["id"]:
            return (f"Do you mean **{top['title']}** or **{second['title']}**? "
                    "Tell me which one and I'll give you the steps.")
    return f"{top['body']}\n\n_Source: Smart Vision guide – {top['title']}_"
