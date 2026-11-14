"""QA5.1 (14.5): portalul se actualizează singur. GET /portal/events (SSE din feed_events), filtrat pe medicul autentificat,
și paginile care știu să-și înlocuiască fragmentele (live.js)."""

from __future__ import annotations

import json
import re
import threading
import time
from pathlib import Path

import pytest
from engine_helpers import real_kb
from fastapi.testclient import TestClient

from polygraph.api import main
from polygraph.store import Store

ROOT = Path(__file__).resolve().parents[2]
STATIC = ROOT / "backend" / "polygraph" / "share" / "static"
DEMO = json.loads((ROOT / "contracts" / "fixtures" / "demo_patient.json").read_text(encoding="utf-8"))
NUROFEN = next(m for m in DEMO["meds"] if m["product"]["brand"] == "Nurofen")
H = {"X-Patient-Token": "demo-token"}
P = "/v1/patients/pat_demo"
PORTAL = "/portal/patients/pat_demo"


@pytest.fixture(scope="module")
def kb():
    return real_kb()


@pytest.fixture
def doctor(kb, monkeypatch):
    monkeypatch.setenv("PG_TODAY", "2026-11-14")
    monkeypatch.setenv("DEMO_MODE", "1")
    monkeypatch.delenv("PG_DOCTOR_CODE", raising=False)
    monkeypatch.setattr(main, "LIVE_LIFETIME", 4.0)
    monkeypatch.setattr(main, "LIVE_TICK", 0.1)
    main.configure(store=Store(":memory:"), kb=kb)
    main.reset_demo(live_scan=True)  # fără Sintrom și Nurofen, ca în scenariu: familia le scanează pe scenă
    with TestClient(main.app) as c:
        assert c.post("/portal/login", data={"code": "medic-demo"}, follow_redirects=False).status_code == 303
        yield c
    main.configure(None, None)


def read_events(client, url: str, until=None) -> list[tuple[str, dict, float]]:
    """(numele, datele, momentul primirii) pentru fiecare eveniment cu date, până la `until` sau la LIVE_LIFETIME."""
    out, name = [], None
    with client.stream("GET", url) as r:
        assert r.status_code == 200
        assert r.headers["content-type"].startswith("text/event-stream")
        for line in r.iter_lines():
            if line.startswith("event: "):
                name = line.removeprefix("event: ")
            elif line.startswith("data: "):
                out.append((name, json.loads(line.removeprefix("data: ")), time.monotonic()))
                if until and until(out[-1]):
                    break
    return out


def pending_on_card(html: str, pid: str) -> int:
    """Cifra din „N de revizuit” de pe cardul pacientului, din fragmentul `live-patients`."""
    fragment = html[html.index('id="live-patients"') :]
    card = fragment[fragment.index(f'id="patient-{pid}"') :]
    return int(re.search(r"(\d+) de revizuit", card[: card.index('class="chevron"')]).group(1))


def later(delay: float, action) -> threading.Thread:
    def run():
        time.sleep(delay)
        action()

    t = threading.Thread(target=run)
    t.start()
    return t


def test_t_qa5_01_med_added_via_api_reaches_portal_in_under_5s(doctor):
    """T-QA5-01: Nurofen adăugat prin POST /meds ajunge ca eveniment în fluxul portalului în < 5 s, iar lista pe care
    pagina o cere apoi are deja cardul Mariei cu alerta nouă (fragmentul pe care live.js îl înlocuiește)."""
    sent = {}
    before = pending_on_card(doctor.get("/portal").text, "pat_demo")

    def add():
        sent["at"] = time.monotonic()
        assert doctor.post(f"{P}/meds", headers=H, json=NUROFEN).status_code == 201

    worker = later(0.3, add)
    events = read_events(doctor, "/portal/events", until=lambda e: e[1]["patient_id"] == "pat_demo")
    worker.join()
    name, data, at = events[-1]
    assert (name, data["patient_id"], data["type"]) == ("feed", "pat_demo", "alert_new")
    assert at - sent["at"] < 5

    assert pending_on_card(doctor.get("/portal").text, "pat_demo") == before + 1


def test_t_qa5_01_other_doctors_events_do_not_arrive(doctor):
    """Un eveniment al pacientului altui medic nu ajunge în fluxul medicului demo; cel al Mariei, da."""
    s = main.store()
    s.create_patient({"id": "pat_other", "name": "Elisabeta", "birth_year": 1940, "anchors": DEMO["patient"]["anchors"]})
    s.upsert_doctor("doc_other", "dr. Alt Medic", "alt-cod")
    s.link_patient("doc_other", "pat_other")

    def event(pid: str, eid: str) -> dict:
        return {"id": eid, "at": "2026-11-14T20:00:00+02:00", "type": "alert_new", "severity": "major", "title": "t",
                "body": "b", "med_ids": [], "alert_id": None, "checkin_id": None}  # fmt: skip

    def write():
        s.add_event("pat_other", event("pat_other", "ev_other"))
        time.sleep(0.3)
        s.add_event("pat_demo", event("pat_demo", "ev_demo"))

    worker = later(0.2, write)
    events = read_events(doctor, "/portal/events", until=lambda e: e[1]["patient_id"] == "pat_demo")
    worker.join()
    assert [e[1]["patient_id"] for e in events] == ["pat_demo"]


def test_stream_requires_the_doctor_and_filters_the_open_patient(doctor):
    """Fără sesiune: 401; pacient care nu e în listă: 404; pe fișa lui Ion nu ajung evenimentele Mariei."""
    anon = TestClient(main.app)
    assert anon.get("/portal/events").status_code == 401
    assert doctor.get("/portal/events?patient=pat_nobody").status_code == 404

    worker = later(0.2, lambda: doctor.post(f"{P}/meds", headers=H, json=NUROFEN))
    events = read_events(doctor, "/portal/events?patient=pat_demo_ion")
    worker.join()
    assert events == []


def test_decision_on_another_tab_reaches_this_page(doctor):
    """O decizie luată pe alt tab (aceeași sesiune) ajunge ca eveniment pe fișa deschisă aici."""
    alerts = doctor.get(f"{P}/analysis", headers=H).json()["alerts"]
    aid = next(a["id"] for a in alerts if a["severity"] == "major" and a["kind"] != "food")
    review = f"{PORTAL}/alerts/{aid}/review"
    worker = later(0.2, lambda: doctor.post(review, json={"decision": "change_at_visit", "note": ""}))
    events = read_events(doctor, "/portal/events?patient=pat_demo", until=lambda e: True)
    worker.join()
    assert events[0][1] == {"patient_id": "pat_demo", "type": "doctor_reviewed", "alert_id": aid}


def test_stream_resumes_from_last_event_id_and_signals_a_reset(doctor):
    """Reconectarea cu Last-Event-ID primește ce s-a scris între timp; un cursor mai mare decât tabela (după
    /demo/reset) primește `reset`, ca pagina să se reîmprospăteze oricum."""
    cursor = main.store().last_event_cursor()
    doctor.post(f"{P}/meds", headers=H, json=NUROFEN)
    with doctor.stream("GET", "/portal/events", headers={"Last-Event-ID": str(cursor)}) as r:
        lines = []
        for line in r.iter_lines():
            lines.append(line)
            if line.startswith("data: "):
                break
    assert "event: feed" in lines and lines[0] == f"id: {cursor}"

    events = read_events(doctor, f"/portal/events?after={cursor + 1000}", until=lambda e: True)
    assert events[0][0] == "reset"


def test_pages_carry_the_live_cursor_and_the_replaceable_fragments(doctor):
    """Lista și fișa au adresa fluxului (cu cursorul luat înaintea datelor), fragmentele cu id și live.js."""
    cursor = main.store().last_event_cursor()
    portal = doctor.get("/portal").text
    assert f'data-live="/portal/events?after={cursor}"' in portal
    for part in ("live-lead", "live-stats", "live-patients"):
        assert re.search(rf'id="{part}" data-live-part', portal), part
    assert 'id="patient-pat_demo"' in portal

    page = doctor.get(PORTAL).text
    assert f'data-live="/portal/events?patient=pat_demo&amp;after={cursor}"' in page
    for part in ("live-summary", "live-grave", "live-meds", "live-schedule", "live-checkins", "live-other"):
        assert re.search(rf'id="{part}" data-live-part', page), part
    for html in (portal, page):
        assert '<script src="/static/share/live.js" defer></script>' in html
        assert "Nu am putut actualiza." in html and "Încearcă din nou" in html  # textul din StaleBanner (Q3F4)


def test_live_js_falls_back_to_polling_and_respects_reduced_motion():
    js = (STATIC / "live.js").read_text(encoding="utf-8")
    assert "new EventSource(" in js and "POLL_MS = 5000" in js and "startPolling" in js
    assert "prefers-reduced-motion: reduce" in js
    css = (STATIC / "share.css").read_text(encoding="utf-8")
    assert ".live-stale" in css and "is-live-updated" in css
    # fragmentele înlocuite aduc formularul cu `hidden` pe alertele revizuite; `display: grid` nu trebuie să-l anuleze
    assert ".review-form[hidden] { display: none; }" in css
