"""Profilul de sănătate al pacientului: înălțimea, greutatea și afecțiunile (patient.schema.json).

Se salvează la POST / PATCH, se validează după schemă și se arată medicului în portal și pe fișa tipărită.
Motorul nu le folosește deocamdată.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from engine_helpers import real_kb
from fastapi.testclient import TestClient

from polygraph.api import main
from polygraph.share.view import CONDITION_LABELS, profile_view
from polygraph.store import Store

P = "/v1/patients/pat_demo"
H = {"X-Patient-Token": "demo-token"}
FIXTURES = Path(__file__).resolve().parents[2] / "contracts" / "fixtures"


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("PG_TODAY", "2026-11-14")
    monkeypatch.setenv("DEMO_MODE", "1")
    monkeypatch.delenv("PG_DOCTOR_CODE", raising=False)
    monkeypatch.setenv("PG_MEDIA_DIR", str(tmp_path / "media"))
    main.configure(store=Store(":memory:"), kb=real_kb())
    main.reset_demo()
    with TestClient(main.app, follow_redirects=False) as c:
        yield c
    main.configure(None, None)


def test_create_with_profile_and_without(client):
    body = {"name": "Ion", "birth_year": 1945, "height_cm": 172, "weight_kg": 80.5, "conditions": ["diabetes"]}
    created = client.post("/v1/patients", json=body)
    assert created.status_code == 201
    patient = created.json()["patient"]
    assert patient["height_cm"] == 172 and patient["weight_kg"] == 80.5 and patient["conditions"] == ["diabetes"]
    # profilul e opțional: onboarding-ul îl poate sări
    bare = client.post("/v1/patients", json={"name": "Ana", "birth_year": 1950}).json()["patient"]
    assert "height_cm" not in bare and "conditions" not in bare


def test_patch_profile_and_clear_it(client):
    r = client.patch(P, headers=H, json={"height_cm": 160, "weight_kg": 62, "conditions": ["hypertension", "falls"]})
    assert r.status_code == 200
    assert client.get(P, headers=H).json()["conditions"] == ["hypertension", "falls"]
    cleared = client.patch(P, headers=H, json={"height_cm": None, "weight_kg": None, "conditions": []}).json()
    assert cleared["height_cm"] is None and cleared["weight_kg"] is None and cleared["conditions"] == []


@pytest.mark.parametrize(
    "bad",
    [{"conditions": ["cancer"]}, {"conditions": ["diabetes", "diabetes"]}, {"height_cm": 40}, {"weight_kg": 400}],
)
def test_invalid_profile_is_rejected(client, bad):
    assert client.patch(P, headers=H, json=bad).status_code == 422


def test_labels_match_the_contract_fixture():
    fixture = json.loads((FIXTURES / "conditions.json").read_text(encoding="utf-8"))
    assert CONDITION_LABELS == {c["code"]: c["label"] for c in fixture["conditions"]}


def test_profile_line():
    view = profile_view({"height_cm": 165, "weight_kg": 68, "conditions": ["hypertension"], "conditions_note": "gută"})
    assert view["line"] == "1,65 m · 68 kg · IMC 25"
    assert view["conditions"] == ["Hipertensiune arterială", "gută"]
    assert profile_view({})["line"] == "" and profile_view({})["conditions"] == []


def test_portal_and_print_show_the_profile(client):
    client.patch(P, headers=H, json={"height_cm": 158, "weight_kg": 64, "conditions": ["atrial_fibrillation"]})
    assert client.post("/portal/login", data={"code": "medic-demo", "next": "/portal"}).status_code == 303
    page = client.get("/portal/patients/pat_demo").text
    assert "1,58 m · 64 kg" in page and "Fibrilație atrială" in page
    assert "Afecțiuni: Fibrilație atrială" in client.get("/portal/patients/pat_demo/print").text
