"""E0 (docs/PLAN.md 14.6): editarea unui medicament nu mai dă 422.

T-E0-02: `PATCH /meds/{mid}` combină obiectele de nivel doi (product, dosage, prescriber) cu cele salvate;
un câmp trimis explicit cu null se salvează ca null; mesajele 422 numesc câmpul ca în aplicație.
"""

from __future__ import annotations

import pytest
from engine_helpers import real_kb
from fastapi.testclient import TestClient

from polygraph.api import main
from polygraph.api.errors import _sentence
from polygraph.store import Store

P = "/v1/patients/pat_demo"
H = {"X-Patient-Token": "demo-token"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("PG_TODAY", "2026-11-14")
    monkeypatch.setenv("DEMO_MODE", "1")
    monkeypatch.setenv("PG_MEDIA_DIR", str(tmp_path / "media"))
    main.configure(store=Store(":memory:"), kb=real_kb())
    main.reset_demo()
    with TestClient(main.app, follow_redirects=False) as c:
        yield c


def _med(client, mid):
    return next(m for m in client.get(f"{P}/meds", headers=H).json() if m["id"] == mid)


def test_partial_dosage_keeps_raw(client):
    """Nurofen (fără rețetă): aplicația trimite dosage fără `raw` și prescriber fără câmpuri."""
    body = {
        "dosage": {
            "as_needed": True,
            "pattern": {"morning": 0, "noon": 0, "evening": 1, "bedtime": 0},
            "with_food": "after_meal",
        },
        "prescriber": {},
    }
    r = client.patch(f"{P}/meds/med_02", headers=H, json=body)
    assert r.status_code == 200, r.text
    med = _med(client, "med_02")
    assert med["dosage"]["raw"] == "1-0-1, după masă"
    assert med["dosage"]["as_needed"] is True and med["dosage"]["pattern"]["evening"] == 1
    assert med["prescriber"] == {"name": None, "specialty": None}


def test_partial_prescriber_keeps_specialty(client):
    """Sintrom are doar specialitatea (cardiologie); numele medicului adăugat nu o șterge."""
    r = client.patch(f"{P}/meds/med_01", headers=H, json={"prescriber": {"name": "dr. Ionescu"}})
    assert r.status_code == 200, r.text
    assert _med(client, "med_01")["prescriber"] == {"name": "dr. Ionescu", "specialty": "cardiologie"}


def test_explicit_null_is_saved(client):
    r = client.patch(f"{P}/meds/med_02", headers=H, json={"dosage": {"raw": None}})
    assert r.status_code == 200, r.text
    assert _med(client, "med_02")["dosage"]["raw"] is None


def test_product_merge_and_substances_replaced(client):
    before = _med(client, "med_02")
    subs = [{**before["substances"][0], "strength_mg": 200.0}]
    r = client.patch(f"{P}/meds/med_02", headers=H, json={"product": {"strength_text": "200 mg"}, "substances": subs})
    assert r.status_code == 200, r.text
    med = _med(client, "med_02")
    assert med["product"]["brand"] == before["product"]["brand"] and med["product"]["strength_text"] == "200 mg"
    assert med["substances"] == subs


def test_patch_422_names_the_field(client):
    r = client.patch(f"{P}/meds/med_02", headers=H, json={"dosage": {"with_food": "cu ciocolată"}})
    assert r.status_code == 422
    assert r.json()["detail"] == "Câmpul „legătura cu masa” are o valoare nepermisă."


@pytest.mark.parametrize(
    ("field", "kind", "text"),
    [
        ("dosage/raw", "lipsește", "Lipsește textul de pe rețetă."),
        ("prescriber/name", "lipsește", "Lipsește numele medicului."),
        ("substances/0/atc", "lipsește", "Lipsește codul ATC al substanței."),
        ("substances", "are tipul greșit", "Câmpul „substanțele active” are tipul greșit."),
        ("product/expiry", "nu are formatul așteptat", "Câmpul „data expirării” nu are formatul așteptat."),
        ("live_scan", "e în afara intervalului permis", "Câmpul «live_scan» e în afara intervalului permis."),
        (None, "nu e JSON valid", "Corpul cererii nu e JSON valid."),
    ],
)
def test_messages(field, kind, text):
    assert _sentence(field, kind) == text
