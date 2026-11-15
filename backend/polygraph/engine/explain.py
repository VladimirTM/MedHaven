"""X4: explicația pe înțeles a unei alerte, reformulată de Gemini strict din câmpurile alertei.

Decizia (dacă există interacțiunea, severitatea, recomandarea) rămâne deterministă: LLM-ul primește doar textele
alertei deja calculate și le spune mai simplu. Orice răspuns care sună a sfat medical nou e respins și se întoarce
textul determinist (patient_text + recommendation)."""

from __future__ import annotations

import hashlib
import json
import os
import re
from typing import Any
from urllib.request import Request, urlopen

from dotenv import dotenv_values

from polygraph.deadline import within
from polygraph.kb import ROOT

CACHE = ROOT / "demo" / "llm_cache" / "explain"
DEADLINE = 6.0
# un răspuns care oprește, schimbă doze sau dă cifre nu ajunge la utilizator
FORBIDDEN = re.compile(r"\bopri|\bnu mai lua|\bîntrerup|\bintrerup|\bdoz[aăe]\b|\d+\s?(mg|mcg|µg|g|ml)\b", re.I)
FIELDS = ("title", "severity", "detail", "recommendation", "patient_text")


def fallback(alert: dict[str, Any]) -> str:
    return " ".join(t for t in (alert.get("patient_text"), alert.get("recommendation")) if t)


def explain(alert: dict[str, Any], brands: list[str]) -> dict[str, Any]:
    facts = {k: alert.get(k) for k in FIELDS} | {"medicamente": brands, "sursa": (alert.get("source") or {}).get("db")}
    key_hash = hashlib.sha256(json.dumps(facts, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    path = CACHE / f"{key_hash}.txt"
    try:
        return {"text": path.read_text(encoding="utf-8"), "ai": True}
    except OSError:
        pass

    config = dotenv_values(ROOT / ".env") | dotenv_values(ROOT / "backend" / ".env") | dict(os.environ)
    key = config.get("GEMINI_API_KEY")
    model = config.get("GEMINI_MODEL") or "gemini-3.1-flash-lite"
    if not key or not re.fullmatch(r"[\w.-]+", model):
        return {"text": fallback(alert), "ai": False}

    prompt = (
        "Ești asistentul unei aplicații pentru familia unui vârstnic. Explică în română, pe înțelesul oricui, "
        "în cel mult 4 propoziții scurte, alerta de mai jos. Folosește DOAR informațiile din JSON, nu adăuga fapte noi. "
        "Nu spune niciodată să oprească sau să schimbe un medicament și nu da doze sau cifre. "
        "Încheie cu ce să facă: să discute cu medicul de familie sau cu farmacistul. Fără markdown.\n\n"
        + json.dumps(facts, ensure_ascii=False)
    )
    payload = {"contents": [{"parts": [{"text": prompt}]}], "generationConfig": {"temperature": 0.2}}
    request = Request(
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "x-goog-api-key": key},
    )
    text = within(DEADLINE, lambda: _fetch(request), "gemini explain")
    if not text or FORBIDDEN.search(text):
        return {"text": fallback(alert), "ai": False}
    try:
        CACHE.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    except OSError:
        pass
    return {"text": text, "ai": True}


def _fetch(request: Request) -> str:
    with urlopen(request, timeout=DEADLINE) as response:
        body = json.load(response)
    parts = body["candidates"][0]["content"]["parts"]
    return "".join(p.get("text", "") for p in parts).strip()
