"""E1 (docs/PLAN.md 14.6): orele zilei se pot schimba după onboarding.

T-E1-01: ordinea orelor validată (422), programul calculat cu orele noi, programul Mariei neschimbat cu orele inițiale.
T-E1-02: dozele de azi deja bifate se mută la orele noi și rămân bifate; dozele de ieri nu se ating.
Și pagina web /acasa/ore (aceeași funcție ca PATCH /patients).
"""

from __future__ import annotations

import json
from datetime import date

import pytest
from engine_helpers import FIX, real_kb
from fastapi.testclient import TestClient

from polygraph.api import main
from polygraph.schedule.move import anchors_in_order, changed_anchors, moved_doses
from polygraph.store import Store

P = "/v1/patients/pat_demo"
H = {"X-Patient-Token": "demo-token"}
DAY = "2026-11-14"
ANCHORS = {"wake": "07:00", "breakfast": "08:00", "lunch": "13:00", "dinner": "19:00", "bed": "22:30"}
LATE_DINNER = {**ANCHORS, "dinner": "20:00"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("PG_TODAY", DAY)
    monkeypatch.setenv("DEMO_MODE", "1")
    monkeypatch.setenv("PG_MEDIA_DIR", str(tmp_path / "media"))
    main.configure(store=Store(":memory:"), kb=real_kb())
    main.reset_demo()
    with TestClient(main.app, follow_redirects=False) as c:
        yield c
    main.configure(None, None)


def _take(client, med_id, clock, day=DAY, status="taken"):
    body = {"med_id": med_id, "scheduled_at": f"{day}T{clock}:00+02:00", "status": status}
    assert client.post(f"{P}/doses", headers=H, json=body).status_code == 200


def _doses_on(day):
    return [d for d in main.store().list_doses("pat_demo") if d["scheduled_at"].startswith(day) or day in d["scheduled_at"]]


def test_order_is_validated(client):
    bad = {**ANCHORS, "lunch": "07:30"}
    r = client.patch(P, headers=H, json={"anchors": bad})
    assert r.status_code == 422
    assert "ordinea zilei" in r.json()["detail"]
    assert client.get(P, headers=H).json()["anchors"] == ANCHORS


def test_schedule_follows_new_anchors(client):
    expected = json.loads((FIX / "expected_schedule.json").read_text(encoding="utf-8"))
    before = client.get(f"{P}/schedule", headers=H, params={"date": DAY}).json()
    assert [m["time"] for m in before["moments"]] == [m["time"] for m in expected["moments"]]
    assert client.patch(P, headers=H, json={"anchors": LATE_DINNER}).status_code == 200
    after = client.get(f"{P}/schedule", headers=H, params={"date": DAY}).json()
    assert "20:00" in [m["time"] for m in after["moments"]] and "19:00" not in [m["time"] for m in after["moments"]]


def test_doses_today_move_and_stay_taken(client):
    _take(client, "med_05", "07:00")  # Euthyrox, dimineața: ora nu se schimbă
    _take(client, "med_01", "19:00")  # Sintrom, la cină
    _take(client, "med_01", "19:00", day="2026-11-13")  # ieri: nu se atinge
    assert client.patch(P, headers=H, json={"anchors": LATE_DINNER}).status_code == 200
    r = client.get(f"{P}/doses", headers=H, params={"date": DAY})
    today = {(d["med_id"], d["scheduled_at"]): d["status"] for d in r.json()}
    assert ("med_01", "2026-11-14T18:00:00Z") in today  # 20:00 la București = 18:00 UTC
    assert today[("med_01", "2026-11-14T18:00:00Z")] == "taken"
    assert any(mid == "med_05" for mid, _ in today)
    assert all(at != "2026-11-14T19:00:00+02:00" for _, at in today)
    yesterday = client.get(f"{P}/doses", headers=H, params={"date": "2026-11-13"}).json()
    assert any(d["med_id"] == "med_01" and d["scheduled_at"] == "2026-11-13T19:00:00+02:00" for d in yesterday)


def test_same_anchors_move_nothing(client):
    _take(client, "med_01", "19:00")
    before = main.store().list_doses("pat_demo")
    assert client.patch(P, headers=H, json={"anchors": ANCHORS}).status_code == 200
    assert main.store().list_doses("pat_demo") == before


def test_moved_doses_keeps_occurrence():
    """Nurofen de două ori pe zi: a doua apariție (seara) se mută la a doua apariție din programul nou."""
    old = {"moments": [{"time": "08:00", "doses": [{"med_id": "n"}]}, {"time": "19:00", "doses": [{"med_id": "n"}]}]}
    new = {"moments": [{"time": "08:00", "doses": [{"med_id": "n"}]}, {"time": "20:00", "doses": [{"med_id": "n"}]}]}
    doses = [
        {"med_id": "n", "scheduled_at": "2026-11-14T08:00:00+02:00", "status": "taken"},
        {"med_id": "n", "scheduled_at": "2026-11-14T19:00:00+02:00", "status": "taken"},
    ]
    moves = moved_doses(doses, date(2026, 11, 14), old, new)
    assert len(moves) == 1 and moves[0][2]["scheduled_at"] == "2026-11-14T18:00:00Z"


def test_helpers():
    assert anchors_in_order(ANCHORS) and not anchors_in_order({**ANCHORS, "bed": "18:00"})
    assert changed_anchors(ANCHORS, LATE_DINNER) == ["cina 19:00 → 20:00"]


def test_web_hours_page(client):
    r = client.get("/acasa/demo")
    assert r.status_code == 303
    page = client.get("/acasa/ore")
    assert page.status_code == 200 and "Orele zilei" in page.text and 'type="time"' in page.text
    saved = client.post("/acasa/ore", data=LATE_DINNER)
    assert saved.status_code == 303 and saved.headers["location"] == "/acasa/ore?salvat=1"
    assert client.get(P, headers=H).json()["anchors"]["dinner"] == "20:00"
    bad = client.post("/acasa/ore", data={**ANCHORS, "lunch": "06:00"})
    assert bad.status_code == 303 and "eroare=" in bad.headers["location"]
    assert "ordinea zilei" in client.get(bad.headers["location"]).text
