"""QA5.2 (14.5): „Dacă prescriu…” pe fișa din portal. Același what-if ca POST /what-if (X1), cu cardurile și textele fișei."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
from engine_helpers import real_kb
from fastapi.testclient import TestClient

from polygraph.api import main
from polygraph.engine.texts_ro import WHATIF_NONE_FOUND, unverified_detail, unverified_title
from polygraph.share.view import doctor_recommendation, new_alerts_text
from polygraph.store import Store

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = json.loads((ROOT / "contracts" / "fixtures" / "expected_alerts.json").read_text(encoding="utf-8"))
STATIC = ROOT / "backend" / "polygraph" / "share" / "static"
H = {"X-Patient-Token": "demo-token"}
PORTAL = "/portal/patients/pat_demo"
CARD = re.compile(r'<article class="alert sev-(\w+)[^"]*" id="whatif-([^"]+)" data-alert-id="([^"]+)">')


@pytest.fixture(scope="module")
def kb():
    return real_kb()


@pytest.fixture
def doctor(kb, monkeypatch):
    monkeypatch.setenv("PG_TODAY", "2026-11-14")
    monkeypatch.setenv("DEMO_MODE", "1")
    monkeypatch.delenv("PG_DOCTOR_CODE", raising=False)
    main.configure(store=Store(":memory:"), kb=kb)
    main.reset_demo()
    with TestClient(main.app) as c:
        assert c.post("/portal/login", data={"code": "medic-demo"}, follow_redirects=False).status_code == 303
        yield c
    main.configure(None, None)


def ask(client, query: str, pid: str = "pat_demo") -> str:
    r = client.post(f"/portal/patients/{pid}/what-if", data={"query": query})
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/html")
    return r.text


def state(html: str) -> str:
    return re.search(r'data-whatif-state="(\w+)"', html).group(1)


def test_t_qa5_02_fromilid_matches_what_if_and_the_2_10_scenario(doctor):
    """T-QA5-02: „Fromilid” în portal dă aceleași alerte (id-uri, severități, ordine) ca POST /what-if și ca
    expected_alerts.json pentru scenariul 2:10 (rețeta ORL, med_09)."""
    html = ask(doctor, "Fromilid")
    assert state(html) == "alerts"
    portal = [(aid, sev) for sev, _, aid in CARD.findall(html)]

    api = doctor.post("/v1/patients/pat_demo/what-if", headers=H, json={"query": "Fromilid"}).json()
    assert portal == [(a["id"], a["severity"]) for a in api["new_alerts"]]

    expected = [(a["id"].replace("med_09", "med_whatif"), a["severity"]) for a in EXPECTED["added_with_med_09"]]
    assert portal == expected
    # cele două conflicte din scenariu, primele
    assert portal[:2] == [("al_ddi_med_03_med_whatif", "critical"), ("al_ddi_med_01_med_whatif", "major")]


def test_cards_use_the_patient_page_texts_for_the_doctor_without_a_decision(doctor):
    """Aceleași carduri ca fișa: titlul, eticheta, sursa și recomandarea în varianta pentru medic (13.1); fără
    formularul de decizie (alerta e ipotetică) și cu id-uri care nu se ciocnesc cu alertele fișei."""
    html = ask(doctor, "Fromilid")
    api = doctor.post("/v1/patients/pat_demo/what-if", headers=H, json={"query": "Fromilid"}).json()
    for alert in api["new_alerts"]:
        start = html.index(f'id="whatif-{alert["id"]}"')
        card = html[start : html.index("</article>", start)]
        assert alert["title"] in card
        assert doctor_recommendation(alert) in card
    assert "Pacientul a fost sfătuit să discute cu medicul care a prescris Fromilid" in html
    assert "Discutați cu" not in html  # textul pentru familie nu ajunge la medic
    assert "review-form" not in html and 'id="alert-' not in html
    assert "<strong>Fromilid 250 mg</strong>" in html and "claritromicină" in html
    assert "2 alerte grave noi și 2 de discutat" in html


def test_states_none_unknown_and_empty(doctor):
    """Nimic găsit, medicament necunoscut (textele alertei `unverified`) și câmp gol."""
    none = ask(doctor, "Augmentin")
    assert state(none) == "none" and WHATIF_NONE_FOUND in none and "<article" not in none

    unknown = ask(doctor, "Xyzolid")
    assert state(unknown) == "unknown"
    assert unverified_title("Xyzolid") in unknown and unverified_detail("Xyzolid", []) in unknown
    assert len(CARD.findall(unknown)) == 1 and "de discutat" not in unknown

    assert state(ask(doctor, "   ")) == "empty"


def test_portal_what_if_is_for_the_signed_in_doctor_only_and_saves_nothing(doctor):
    anon = TestClient(main.app)
    assert anon.post(f"{PORTAL}/what-if", data={"query": "Fromilid"}).status_code == 401
    assert doctor.post("/portal/patients/pat_nobody/what-if", data={"query": "Fromilid"}).status_code == 404
    feed = doctor.get("/v1/patients/pat_demo/feed", headers=H).json()
    meds = doctor.get("/v1/patients/pat_demo/meds", headers=H).json()
    ask(doctor, "Fromilid")
    assert doctor.get("/v1/patients/pat_demo/feed", headers=H).json() == feed
    assert doctor.get("/v1/patients/pat_demo/meds", headers=H).json() == meds


def test_new_alerts_text_counts_like_the_app():
    """Aceleași perechi ca `NewAlerts.text` (AlertSections.swift): grave fără mâncare, moderate „de discutat”."""

    def a(severity: str, kind: str = "ddi") -> dict:
        return {"severity": severity, "kind": kind}

    assert new_alerts_text([]) is None
    assert new_alerts_text([a("minor"), a("major", "food")]) is None
    assert new_alerts_text([a("critical")]) == "O alertă gravă nouă"
    assert new_alerts_text([a("critical"), a("major"), a("moderate"), a("moderate")]) == "2 alerte grave noi și 2 de discutat"
    assert new_alerts_text([a("major"), a("moderate")]) == "O alertă gravă nouă și una de discutat"
    assert new_alerts_text([a("moderate")]) == "O alertă nouă de discutat"
    assert new_alerts_text([a("moderate")] * 3) == "3 alerte noi de discutat"
    assert new_alerts_text([a("major")] * 20) == "20 de alerte grave noi"


def test_page_has_the_field_states_and_accessible_targets(doctor):
    """Câmpul are etichetă, butonul „Verifică”, stările de încărcare și de eroare (rețea / server, QA-16) cu
    „Încearcă din nou”; ținte ≥ 44 px pe pointer: coarse, Dark și prefers-contrast ca restul portalului."""
    page = doctor.get(PORTAL).text
    assert '<label class="visually-hidden" for="whatif-query">Numele medicamentului</label>' in page
    assert 'id="whatif-query" name="query"' in page and ">Verifică</button>" in page
    assert 'aria-live="polite" data-whatif-result' in page
    assert "Se verifică…" in page
    assert "Nu s-a putut verifica. Verificați conexiunea." in page
    assert "Nu s-a putut verifica. Încercați din nou." in page
    assert page.count("data-whatif-retry>Încearcă din nou</button>") == 2
    assert '<script src="/static/share/whatif.js" defer></script>' in page

    css = (STATIC / "share.css").read_text(encoding="utf-8")
    coarse = css[css.index("@media (pointer: coarse) {") :]
    assert ".whatif-input, .whatif-form .btn, .whatif-error .btn" in coarse[: coarse.index("}")]
    contrast = css[css.rindex("@media (prefers-contrast: more) {") :]
    assert ".whatif-input { border: 2px solid var(--line); }" in contrast
    js = (STATIC / "whatif.js").read_text(encoding="utf-8")
    assert "prefers-reduced-motion: reduce" in js and '[data-whatif-error="network"]' in js
