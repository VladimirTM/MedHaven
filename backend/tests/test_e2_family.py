"""E2 (docs/PLAN.md 14.6): pagina familiei pe web.

T-E2-01 linkul de intrare (o singură dată, 10 minute) și sesiunea; T-E2-02 „Am luat” de pe web, idempotent, cu aceeași
cheie ca POST /doses; T-E2-03 aceleași momente ca programul și aceleași alerte ca /analysis, fără căi interne;
plus GET /doses (aplicația vede bifele de pe web), SSE și accesibilitatea de bază (h1, tab-uri).
"""

from __future__ import annotations

import re
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

import pytest
from engine_helpers import real_kb
from fastapi.testclient import TestClient

from polygraph.api import main
from polygraph.share.family import check_context, quantity, today_context
from polygraph.store import Store

P = "/v1/patients/pat_demo"
H = {"X-Patient-Token": "demo-token"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    today = datetime.now(main.TZ).date().isoformat()  # „Am luat” nu acceptă doze în viitor față de ceasul real
    monkeypatch.setenv("PG_TODAY", today)
    monkeypatch.setenv("DEMO_MODE", "1")
    monkeypatch.setenv("PG_MEDIA_DIR", str(tmp_path / "media"))
    main.configure(store=Store(":memory:"), kb=real_kb())
    main.reset_demo()
    with TestClient(main.app, follow_redirects=False) as c:
        yield c
    main.configure(None, None)


def _enter(client) -> None:
    url = client.post(f"{P}/web-link", headers=H).json()["url"]
    r = client.get(url[url.index("/acasa/") :])
    assert r.status_code == 303 and r.headers["location"] == "/acasa"


def test_link_works_once(client):
    r = client.post(f"{P}/web-link", headers=H)
    assert r.status_code == 201
    path = r.json()["url"][r.json()["url"].index("/acasa/") :]
    assert client.get(path).status_code == 303
    client.cookies.clear()
    again = client.get(path)
    assert again.status_code == 404 and "nu mai e valabil" in again.text


def test_link_expires(client):
    code = main.store().create_home_link("pat_demo", (datetime.now(UTC) - timedelta(seconds=1)).isoformat())
    assert client.get(f"/acasa/intra/{code}").status_code == 404


def test_no_session_shows_no_data(client):
    for path in ("/acasa", "/acasa/medicamente", "/acasa/verificat", "/acasa/ore", "/acasa/saptamana"):
        r = client.get(path)
        assert r.status_code == 200 and "Deschideți linkul din aplicație" in r.text
        assert "Sintrom" not in r.text and "Maria" not in r.text
    assert client.get("/acasa/events").status_code == 401
    assert client.post(f"{P}/web-link").status_code == 401


def test_tabs_have_h1_and_no_internal_paths(client):
    _enter(client)
    for path, title in (
        ("/acasa", "Azi"),
        ("/acasa/medicamente", "Medicamentele mele"),
        ("/acasa/verificat", "De verificat"),
        ("/acasa/ore", "Orele zilei"),
        ("/acasa/saptamana", "Calendar"),
    ):
        r = client.get(path)
        assert r.status_code == 200, path
        assert re.search(rf'<h1 class="page-title">{title}</h1>', r.text), path
        assert 'aria-current="page"' in r.text
        assert "kb/" not in r.text and "curated_ddi" not in r.text
        assert "style=" not in r.text  # CSP: style-src 'self', fără stiluri inline


def test_today_matches_schedule(client):
    _enter(client)
    sched = client.get(f"{P}/schedule", headers=H).json()
    html = client.get("/acasa").text
    for m in sched["moments"]:
        assert f'id="m-{m["time"].replace(":", "")}"' in html
    assert "Sintrom 4 mg" in html


def test_take_on_web_is_idempotent_and_shared(client):
    _enter(client)
    first = client.get(f"{P}/schedule", headers=H).json()["moments"][0]
    with ThreadPoolExecutor(4) as pool:
        codes = list(pool.map(lambda _: client.post("/acasa/doze", data={"moment": first["time"]}).status_code, range(4)))
    assert codes == [303] * 4
    doses = client.get(f"{P}/doses", headers=H).json()
    assert len(doses) == len(first["doses"]) and all(d["status"] == "taken" for d in doses)
    # aplicația trimite aceeași doză (ora ca UTC „Z”): aceeași cheie, nicio dublură
    for d in doses:
        client.post(f"{P}/doses", headers=H, json={"med_id": d["med_id"], "scheduled_at": d["scheduled_at"], "status": "taken"})
    assert len(client.get(f"{P}/doses", headers=H).json()) == len(first["doses"])
    assert "Luat la" in client.get("/acasa").text
    client.post("/acasa/doze", data={"moment": first["time"], "status": "pending"})
    assert all(d["status"] == "pending" for d in client.get(f"{P}/doses", headers=H).json())


def test_check_matches_analysis(client):
    _enter(client)
    analysis = client.get(f"{P}/analysis", headers=H).json()
    html = client.get("/acasa/verificat").text
    for a in analysis["alerts"]:
        assert (f'id="alert-{a["id"]}"' in html) == (a["severity"] != "minor"), a["id"]
    assert "De ce văd asta?" in html and "Ce puteți face" in html
    assert "Pacientul a fost sfătuit" not in html  # recomandarea e cea pentru familie, nu varianta pentru medic


def test_check_order_like_the_app(client):
    analysis = client.get(f"{P}/analysis", headers=H).json()
    ctx = check_context(analysis, main.store().list_meds("pat_demo"), main.today())
    assert all(a["severity"] in ("critical", "major") and a["kind"] != "food" for a in ctx["grave"])
    assert all(a["kind"] == "food" for a in ctx["food"])
    assert all(a["kind"] == "anticholinergic" for a in ctx["acb"])
    shown = ctx["grave"] + ctx["moderate"] + ctx["food"] + ctx["acb"]
    assert all(a["severity"] != "minor" for a in shown)


def test_meds_tab(client):
    _enter(client)
    html = client.get("/acasa/medicamente").text
    assert "Ce înseamnă mg?" in html and "Fără rețetă" in html and "1 dimineața" in html
    assert "opriți" not in html.lower().replace("nu opriți", "")


def test_quantity_words():
    assert quantity(1, "comprimate") == "1 comprimat"
    assert quantity(0.5, None) == "½ comprimat"
    assert quantity(1.5, None) == "1 ½ comprimate"
    assert quantity(2, "capsule moi") == "2 capsule"


def test_today_context_current_first():
    sched = {
        "date": "2026-11-14",
        "moments": [
            {"time": "08:00", "label": "La micul dejun", "doses": [{"med_id": "a", "qty": 1, "instruction": ""}]},
            {"time": "13:00", "label": "La prânz", "doses": [{"med_id": "a", "qty": 1, "instruction": ""}]},
            {"time": "19:00", "label": "La cină", "doses": [{"med_id": "a", "qty": 1, "instruction": ""}]},
        ],
    }
    now = datetime(2026, 11, 14, 13, 10, tzinfo=main.TZ)
    ctx = today_context(sched, [], [], now)
    assert ctx["moments"][0]["time"] == "13:00" and ctx["moments"][0]["current"]
    morning = next(m for m in ctx["moments"] if m["time"] == "08:00")
    assert morning["missed"] and morning["due"]
    dinner = next(m for m in ctx["moments"] if m["time"] == "19:00")
    assert not dinner["due"]


def test_events_signal_a_change(client, monkeypatch):
    monkeypatch.setattr(main, "LIVE_LIFETIME", 3.0)
    monkeypatch.setattr(main, "HOME_TICK", 0.1)
    _enter(client)
    first = client.get(f"{P}/schedule", headers=H).json()["moments"][0]
    import threading

    def later():
        import time

        time.sleep(0.5)
        body = {
            "med_id": first["doses"][0]["med_id"],
            "scheduled_at": main.dose_key(main.today(), first["time"]).isoformat(),
            "status": "taken",
        }
        main.save_dose("pat_demo", body["med_id"], main.dose_key(main.today(), first["time"]), body["scheduled_at"], "taken")

    threading.Thread(target=later).start()
    with client.stream("GET", "/acasa/events") as r:
        text = ""
        for chunk in r.iter_text():
            text += chunk
            if "event: changed" in text:
                break
    assert "event: changed" in text


def test_demo_link(client):
    r = client.get("/acasa/demo")
    assert r.status_code == 303
    assert "Maria" in client.get("/acasa").text
