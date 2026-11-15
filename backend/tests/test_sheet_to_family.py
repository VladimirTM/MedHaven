"""Fișa trimisă familiei: medicul de familie trimite din portal o copie fixă a fișei de consultație, pe care familia o
vede pe pagina web („Fișa de la medic”) și în Noutăți (evenimentul `doctor_reviewed` din contract, fără alertă)."""

from __future__ import annotations

import re
from datetime import datetime

import pytest
import validate as contracts
from engine_helpers import real_kb
from fastapi.testclient import TestClient

from polygraph.api import main
from polygraph.store import Store

P = "/v1/patients/pat_demo"
H = {"X-Patient-Token": "demo-token"}
PORTAL = "/portal/patients/pat_demo"
NOTE = "Revenim la control peste o lună, cu analizele."


@pytest.fixture(scope="module")
def kb():
    return real_kb()


@pytest.fixture
def client(kb, tmp_path, monkeypatch):
    monkeypatch.setenv("PG_TODAY", datetime.now(main.TZ).date().isoformat())
    monkeypatch.setenv("DEMO_MODE", "1")
    monkeypatch.setenv("PG_MEDIA_DIR", str(tmp_path / "media"))
    monkeypatch.delenv("PG_DOCTOR_CODE", raising=False)
    main.configure(store=Store(":memory:"), kb=kb)
    main.reset_demo()
    with TestClient(main.app, follow_redirects=False) as c:
        yield c
    main.configure(None, None)


def login(client) -> None:
    assert client.post("/portal/login", data={"code": "medic-demo", "next": "/portal"}).status_code == 303


def enter_family(client) -> None:
    url = client.post(f"{P}/web-link", headers=H).json()["url"]
    assert client.get(url[url.index("/acasa/") :]).status_code == 303


def first_grave(client) -> dict:
    alerts = client.get(f"{P}/analysis", headers=H).json()["alerts"]
    return next(a for a in alerts if a["severity"] in ("critical", "major"))


def sheet_events(client) -> list[dict]:
    return [e for e in client.get(f"{P}/feed", headers=H).json() if e["id"].startswith("ev_sheet_")]


def test_print_page_offers_sending_with_an_optional_note(client):
    login(client)
    html = client.get(f"{PORTAL}/print").text
    assert 'action="/portal/patients/pat_demo/send-sheet"' in html
    assert 'name="note"' in html and "Trimite familiei" in html
    # panoul nu ajunge pe hârtie
    assert re.search(r'<section class="send-sheet screen-only"', html)


def test_send_redirects_back_with_status_and_adds_one_feed_event(client):
    login(client)
    r = client.post(f"{PORTAL}/send-sheet", data={"note": f"  {NOTE}  "})
    assert r.status_code == 303 and r.headers["location"].startswith(f"{PORTAL}/print?trimisa=1")
    assert "✓ Trimisă familiei azi" in client.get(r.headers["location"]).text
    [event] = sheet_events(client)
    assert not contracts.schema_errors("feed_event", event), event
    assert event["type"] == "doctor_reviewed" and event["alert_id"] is None and event["severity"] is None
    assert event["title"] == "Dr. Elena Popa a trimis fișa de la consultație"
    assert NOTE in event["body"] and "Deschide pe web" in event["body"]


def test_same_sheet_twice_is_sent_once(client):
    login(client)
    for _ in range(3):
        client.post(f"{PORTAL}/send-sheet", data={"note": NOTE})
    assert len(sheet_events(client)) == 1
    assert len(main.store().list_sheets("pat_demo")) == 1
    client.post(f"{PORTAL}/send-sheet", data={"note": "Alt mesaj."})
    assert len(main.store().list_sheets("pat_demo")) == 2


def test_family_sees_banner_and_sheet_with_decisions_in_their_words(client):
    login(client)
    alert = first_grave(client)
    r = client.post(f"{PORTAL}/alerts/{alert['id']}/review", json={"decision": "change_at_visit", "note": "Vorbim joi."})
    assert r.status_code == 200
    client.post(f"{PORTAL}/send-sheet", data={"note": NOTE})
    enter_family(client)
    today = client.get("/acasa").text
    assert 'href="/acasa/fisa"' in today and "Trimisă de dr. Elena Popa azi" in today
    html = client.get("/acasa/fisa").text
    assert "<h1" in html and NOTE in html
    assert alert["title"] in html and "Îl modifică la consultație" in html and "Vorbim joi." in html
    # eticheta pentru familie, nu cea a medicului; posologia în cuvinte, nu schema „1-0-1”
    assert "Modific la consultație" not in html
    # fiecare alertă din fișă (decisă sau încă de discutat) are explicația și sursa
    grave = [a for a in client.get(f"{P}/analysis", headers=H).json()["alerts"] if a["severity"] in ("critical", "major")]
    pending = [a for a in grave if a["id"] != alert["id"]]
    assert 'id="h-pending"' in html and f'<span class="count">{len(pending)}</span>' in html
    assert html.count("De ce văd asta?") == len(grave)
    for a in grave:
        assert a["title"] in html and a["detail"] in html
    # substanța activă și data de început, la „i” pe fiecare medicament
    assert "Substanța activă" in html and "Ia din" in html
    assert not re.search(r"\b\d+-\d+-\d+\b", html)
    meds = client.get(f"{P}/meds", headers=H).json()
    assert all(m["brand"] in html for m in meds if m.get("brand"))
    # subsolul comun al paginii familiei are avertismentul „Nu opriți…”; conținutul fișei nu
    body = html[: html.index('<footer class="family-foot">')].lower()
    body = body.replace("nimic de aici nu înseamnă „opriți medicamentul”", "")  # avertismentul, ca pe „de verificat”
    for banned in ("opriți", "nu mai luați"):
        assert banned not in body


def test_sheet_is_a_fixed_copy(client):
    login(client)
    client.post(f"{PORTAL}/send-sheet", data={"note": NOTE})
    before = main.store().list_sheets("pat_demo")[0]
    first = client.get(f"{P}/meds", headers=H).json()[0]["id"]
    assert client.delete(f"{P}/meds/{first}", headers=H).status_code == 204
    assert main.store().list_sheets("pat_demo")[0] == before


def test_older_sheets_stay_reachable_and_unknown_id_shows_empty_state(client):
    login(client)
    client.post(f"{PORTAL}/send-sheet", data={"note": "Prima."})
    client.post(f"{PORTAL}/send-sheet", data={"note": "A doua."})
    enter_family(client)
    latest = client.get("/acasa/fisa").text
    assert "A doua." in latest
    old_id = main.store().list_sheets("pat_demo")[1]["id"]
    assert f"/acasa/fisa?id={old_id}" in latest
    old = client.get(f"/acasa/fisa?id={old_id}").text
    assert "Prima." in old and "nu e cea mai nouă" in old
    assert "nu a trimis încă nicio fișă" in client.get("/acasa/fisa?id=sh_altcineva").text


def test_family_without_a_sheet(client):
    enter_family(client)
    assert 'href="/acasa/fisa"' not in client.get("/acasa").text
    assert "nu a trimis încă nicio fișă" in client.get("/acasa/fisa").text


def test_only_the_patients_doctor_can_send(client):
    r = client.post(f"{PORTAL}/send-sheet", data={"note": NOTE})
    assert r.status_code == 200 and 'name="code"' in r.text  # formularul de autentificare
    login(client)
    other = client.post("/portal/patients/pat_altcineva/send-sheet", data={"note": NOTE})
    assert other.status_code == 404
    assert main.store().list_sheets("pat_demo") == []


def test_family_page_needs_a_session(client):
    r = client.get("/acasa/fisa")
    assert r.status_code == 200 and "Fișa de la medicul de familie" not in r.text
