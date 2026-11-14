"""QA1 (docs/PLAN.md, 14.1): robustețea backend-ului.

T-QA1-01 bugetul solverului (QA-02); T-QA1-02 alerta `unverified` (QA-03); T-QA1-03 decizia medicului idempotentă
(QA-07); T-QA1-04 valorile neplauzibile (QA-08, QA-09); T-QA1-06 limita la nume (QA-11); T-QA1-07 Post/Redirect/Get
la login (QA-15). T-QA1-05 (QA-10) e în test_q3f3.py. Testele cu kb-ul real se sar dacă kb/kb.sqlite nu e construit (CI).
"""

from __future__ import annotations

import copy
import json
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

import pytest
import validate as contracts
from engine_helpers import FIX, real_kb
from fastapi.testclient import TestClient

from polygraph.api import main
from polygraph.schedule import solver
from polygraph.store import Store

P = "/v1/patients/pat_demo"
H = {"X-Patient-Token": "demo-token"}
PORTAL = "/portal/patients/pat_demo"
CODE = "medic-demo"
EXPECTED_SCHEDULE = json.loads((FIX / "expected_schedule.json").read_text(encoding="utf-8"))


@pytest.fixture
def client(tmp_path, monkeypatch):
    kb = real_kb()
    monkeypatch.setenv("PG_TODAY", "2026-11-14")
    monkeypatch.setenv("DEMO_MODE", "1")
    monkeypatch.setenv("GEMINI_API_KEY", "")
    monkeypatch.delenv("PG_DOCTOR_CODE", raising=False)
    monkeypatch.setenv("PG_MEDIA_DIR", str(tmp_path / "media"))
    main.configure(store=Store(":memory:"), kb=kb)
    main.reset_demo()
    with TestClient(main.app, follow_redirects=False) as c:
        yield c
    main.configure(None, None)


def demo_med(client, n: int = 0) -> dict:
    return copy.deepcopy(client.get(f"{P}/meds", headers=H).json()[n])


def _is_error(response) -> bool:
    body = response.json()
    return set(body) == {"detail"} and isinstance(body["detail"], str) and body["detail"].strip() != ""


# ---------------------------------------------------------------- T-QA1-01 · QA-02


def test_forty_meds_get_analysis_and_schedule_under_a_second(client):
    meds = client.get(f"{P}/meds", headers=H).json()
    k = 0
    while len(client.get(f"{P}/meds", headers=H).json()) < 40:
        m = copy.deepcopy(meds[k % len(meds)])
        m["id"] = f"med_copy_{k:02d}"
        assert client.post(f"{P}/meds", headers=H, json=m).status_code == 201
        k += 1
    for path in ("analysis", "schedule"):
        t0 = time.perf_counter()
        r = client.get(f"{P}/{path}", headers=H)
        assert r.status_code == 200
        assert time.perf_counter() - t0 < 1.0, path
    body = client.get(f"{P}/schedule", headers=H).json()
    assert not contracts.schema_errors("schedule", body)
    assert len(body["moments"]) <= 5


def test_maria_schedule_does_not_touch_the_budget(client):
    body = client.get(f"{P}/schedule", headers=H).json()
    assert body["solver"]["version"] == solver.VERSION

    def shape(moments):  # orele și dozele; textele exacte sunt verificate de test_schedule_golden.py
        return [(m["time"], sorted(d["med_id"] for d in m["doses"])) for m in moments]

    assert shape(body["moments"]) == shape(EXPECTED_SCHEDULE["moments"])


def test_budget_hit_without_a_solution_falls_back_to_greedy(client, monkeypatch, caplog):
    monkeypatch.setattr(solver, "BUDGET_NODES", 1)  # nicio frunză atinsă: programul vine din greedy
    body = client.get(f"{P}/schedule", headers=H).json()
    assert body["solver"]["version"].endswith("+budget")
    assert not contracts.schema_errors("schedule", body)
    placed = sorted(d["med_id"] for m in body["moments"] for d in m["doses"])
    expected = sorted(d["med_id"] for m in EXPECTED_SCHEDULE["moments"] for d in m["doses"])
    assert placed == expected  # nicio doză pierdută
    assert "buget atins" in caplog.text


# ---------------------------------------------------------------- T-QA1-02 · QA-03


@pytest.mark.parametrize("substances", [[], [{"inn": "nonexistentium", "dci": "nonexistentium", "atc": None, "strength_mg": 5}]])
def test_med_without_known_substance_gets_an_unverified_alert(client, substances):
    m = demo_med(client)
    m.update(id="med_qa1", substances=substances)
    m["product"]["brand"] = "Necunoscutin"
    assert client.post(f"{P}/meds", headers=H, json=m).status_code == 201
    body = client.get(f"{P}/analysis", headers=H).json()
    assert not contracts.schema_errors("analysis", body)
    alert = next(a for a in body["alerts"] if a["kind"] == "unverified")
    assert alert["med_ids"] == ["med_qa1"] and alert["severity"] == "moderate" and alert["source"]["db"] == "app"
    assert alert["title"].startswith("Nu am putut verifica Necunoscutin")
    assert "Interacțiunile lui nu sunt incluse" in alert["detail"]
    # fișa medicului de familie îl arată, nu „nicio alertă”
    assert client.post("/portal/login", data={"code": CODE}).status_code == 303
    page = client.get(PORTAL).text
    assert "Nu am putut verifica Necunoscutin" in page


def test_demo_patient_has_no_unverified_alert(client):
    assert not [a for a in client.get(f"{P}/analysis", headers=H).json()["alerts"] if a["kind"] == "unverified"]


# ---------------------------------------------------------------- T-QA1-03 · QA-07


def _feed_reviews(client) -> list[dict]:
    return [e for e in client.get(f"{P}/feed", headers=H).json() if e["type"] == "doctor_reviewed"]


def test_same_decision_ten_times_in_parallel_is_one_event(client):
    assert client.post("/portal/login", data={"code": CODE}).status_code == 303
    aid = next(a["id"] for a in client.get(f"{P}/analysis", headers=H).json()["alerts"] if a["severity"] == "major")
    before = len(_feed_reviews(client))

    def review(_):
        return client.post(f"{PORTAL}/alerts/{aid}/review", json={"decision": "keep", "note": "Discutăm joi."})

    with ThreadPoolExecutor(10) as pool:
        codes = [r.status_code for r in pool.map(review, range(10))]
    assert codes == [200] * 10
    assert len(_feed_reviews(client)) == before + 1
    # o decizie diferită e o schimbare: al doilea eveniment, iar alerta are ultima rezoluție
    r = client.post(f"{PORTAL}/alerts/{aid}/review", json={"decision": "change_at_visit", "note": "Discutăm joi."})
    assert r.status_code == 200 and r.json()["resolution"]["decision"] == "change_at_visit"
    assert len(_feed_reviews(client)) == before + 2


# ---------------------------------------------------------------- T-QA1-04 · QA-08, QA-09


def test_end_date_before_start_date_is_rejected(client):
    m = demo_med(client)
    m.update(id="med_qa1", start_date="2026-11-10", end_date="2026-11-01")
    r = client.post(f"{P}/meds", headers=H, json=m)
    assert r.status_code == 422 and _is_error(r) and "sfârșit" in r.json()["detail"]
    r = client.patch(f"{P}/meds/{demo_med(client)['id']}", headers=H, json={"start_date": "2026-11-10", "end_date": "2026-11-01"})
    assert r.status_code == 422 and _is_error(r)


def test_more_than_ten_units_per_moment_is_rejected(client):
    m = demo_med(client)
    m["id"] = "med_qa1"
    m["dosage"]["pattern"]["morning"] = 100
    r = client.post(f"{P}/meds", headers=H, json=m)
    assert r.status_code == 422 and _is_error(r) and "10" in r.json()["detail"]


def test_empty_posology_stays_allowed(client):
    # „Posologie necompletată” din aplicație: o cutie scanată nu spune cum se ia, familia completează după
    m = demo_med(client)
    m["id"] = "med_qa1"
    m["dosage"].update(pattern={"morning": 0, "noon": 0, "evening": 0, "bedtime": 0}, as_needed=False)
    assert client.post(f"{P}/meds", headers=H, json=m).status_code == 201


def test_dose_more_than_a_day_ahead_is_rejected(client):
    mid = demo_med(client)["id"]
    far = (datetime.now(UTC) + timedelta(days=3)).replace(microsecond=0).isoformat()
    r = client.post(f"{P}/doses", headers=H, json={"med_id": mid, "scheduled_at": far, "status": "taken"})
    assert r.status_code == 422 and _is_error(r)
    r = client.post(f"{P}/doses", headers=H, json={"med_id": mid, "scheduled_at": "2030-01-01T08:00:00+02:00", "status": "taken"})
    assert r.status_code == 422
    soon = (datetime.now(UTC) + timedelta(hours=2)).replace(microsecond=0).isoformat()
    assert client.post(f"{P}/doses", headers=H, json={"med_id": mid, "scheduled_at": soon, "status": "taken"}).status_code == 200


def test_what_if_with_only_spaces_is_rejected(client):
    r = client.post(f"{P}/what-if", headers=H, json={"query": "   "})
    assert r.status_code == 422 and _is_error(r)


# ---------------------------------------------------------------- T-QA1-06 · QA-11


def test_patient_name_is_limited_to_80_characters(client):
    ok = client.post("/v1/patients", json={"name": "A" * 80, "birth_year": 1948})
    assert ok.status_code == 201
    r = client.post("/v1/patients", json={"name": "A" * 81, "birth_year": 1948})
    assert r.status_code == 422 and _is_error(r)
    r = client.post("/v1/patients", json={"name": "Ion", "birth_year": 1948, "caregiver_name": "B" * 81})
    assert r.status_code == 422
    r = client.patch(f"{P}", headers=H, json={"name": "A" * 81})
    assert r.status_code == 422


# ---------------------------------------------------------------- T-QA1-07 · QA-15


def test_wrong_code_redirects_and_refresh_does_not_resubmit(client):
    r = client.post("/portal/login", data={"code": "gresit", "next": PORTAL})
    assert r.status_code == 303 and r.headers["location"].startswith("/portal?eroare=1")
    page = client.get(r.headers["location"])  # refresh-ul = același GET
    assert page.status_code == 200 and "nu e corect" in page.text
    assert f'value="{PORTAL}"' in page.text  # ținta se păstrează pentru următoarea încercare
    assert "nu e corect" not in client.get("/portal").text
