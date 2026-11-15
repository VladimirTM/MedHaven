"""QA3 (14.3): textele comune între aplicație și portalul medicului, posologia, sursele fără căi interne și stările goale."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
from engine_helpers import real_kb
from fastapi.testclient import TestClient

from polygraph.api import main
from polygraph.engine.texts_ro import SEVERITY_RO, ddi_title
from polygraph.share.view import DECISION_LABEL_FAMILY, med_row, plain_posology
from polygraph.store import Store

ROOT = Path(__file__).resolve().parents[2]
ALERT_SECTIONS_SWIFT = ROOT / "app" / "PolyGraph" / "Alerts" / "AlertSections.swift"
POSOLOGY_FIXTURE = ROOT / "contracts" / "fixtures" / "posology_words.json"
PORTAL = "/portal/patients/pat_demo"
CODE = "medic-demo"


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
        r = c.post("/portal/login", data={"code": CODE, "next": "/portal"}, follow_redirects=False)
        assert r.status_code == 303
        yield c
    main.configure(None, None)


def test_t_qa3_01_decision_labels_match_swift_alert_sections():
    """T-QA3-01: DECISION_LABEL_FAMILY din backend coincide exact cu DoctorDecision.label din AlertSections.swift."""
    swift = ALERT_SECTIONS_SWIFT.read_text(encoding="utf-8")
    enum_block = swift[swift.index("extension DoctorDecision") : swift.index("struct NewAlerts")]
    swift_labels = dict(re.findall(r'case \.(\w+):\s*"([^"]+)"', enum_block))
    expected_map = {
        "keep": swift_labels["keep"],
        "change_at_visit": swift_labels["changeAtVisit"],
        "refer_specialist": swift_labels["referSpecialist"],
    }
    assert DECISION_LABEL_FAMILY == expected_map
    assert DECISION_LABEL_FAMILY == {
        "keep": "Menține tratamentul",
        "change_at_visit": "Îl modifică la consultație",
        "refer_specialist": "Trimite la specialist",
    }


def test_t_qa3_02_posology_words_fixture_and_print_posology():
    """T-QA3-02: posology_words.json trece pe plain_posology, iar tipărirea arată „1 dimineața, 1 seara (1-0-1)”."""
    cases = json.loads(POSOLOGY_FIXTURE.read_text(encoding="utf-8"))["cases"]
    assert len(cases) >= 6
    for case in cases:
        assert plain_posology(case["raw"], as_needed=case["as_needed"]) == case["words"], case

    row = med_row(
        {
            "id": "med_test",
            "product": {"brand_name": "Concor 5 mg"},
            "substances": [{"inn": "bisoprolol", "atc": "C07AB07"}],
            "dosage": {"raw": "1-0-1"},
            "start_date": "2026-10-01",
        }
    )
    assert row["how"] == "1 dimineața, 1 seara"
    assert row["print_posology"] == "1 dimineața, 1 seara (1-0-1)"


def test_t_qa3_03_portal_recommendations_address_doctor_and_ddi_titles_use_label_words(doctor):
    """T-QA3-03: pe fișa Mariei în portal nicio recomandare nu începe cu „Discutați cu medicul de familie”,
    iar titlurile DDI folosesc cuvântul etichetei (critică / gravă / moderată / minoră), fără „importantă”."""
    assert SEVERITY_RO == {
        "critical": "critică",
        "major": "gravă",
        "moderate": "moderată",
        "minor": "minoră",
        "info": "informativă",
    }
    assert ddi_title("major", "Sintrom", "Nurofen") == "Sintrom și Nurofen: interacțiune gravă"
    assert ddi_title("critical", "Sintrom", "Klacid") == "Sintrom și Klacid: interacțiune critică"

    for path in (PORTAL, f"{PORTAL}/print"):
        html = doctor.get(path).text
        assert "Discutați cu medicul de familie" not in html
        assert "interacțiune importantă" not in html
        assert "combinație de evitat" not in html
    page_html = doctor.get(PORTAL).text
    assert "Pacientul a fost sfătuit să discute cu dumneavoastră" in page_html
    assert "Pacientul a fost sfătuit să discute cu medicul cardiolog" in page_html


def test_t_qa3_04_empty_patient_shows_empty_states_and_hides_graph(doctor):
    """T-QA3-04: pacient fără medicamente: fiecare secțiune are mesajul ei, iar graful e ascuns."""
    created = doctor.post("/v1/patients", json={"name": "Vasile", "birth_year": 1948}).json()
    pid, token = created["id"], created["patient_token"]
    share = doctor.post(f"/v1/patients/{pid}/share", headers={"X-Patient-Token": token}).json()["share_token"]
    doctor.get(f"/share/{share}", follow_redirects=False)

    html = doctor.get(f"/portal/patients/{pid}").text
    assert "Familia n-a adăugat încă medicamente." in html
    assert "Nu sunt doze în program astăzi." in html
    assert "Niciun check-in în ultimele 7 zile." in html
    assert "Nicio alertă gravă." in html
    assert 'id="h-graph"' not in html
    assert 'id="graph"' not in html
    assert "cytoscape.min.js" not in html

    print_html = doctor.get(f"/portal/patients/{pid}/print").text
    assert "Familia n-a adăugat încă medicamente." in print_html


def test_t_qa3_05_sources_have_no_internal_kb_paths_and_unlinked_patient_shows_not_in_list(doctor):
    """T-QA3-05: HTML-ul fișei și al tipăririi nu conține `kb/`; pacientul care nu e în listă primește 404 dedicat."""
    for path in (PORTAL, f"{PORTAL}/print"):
        html = doctor.get(path).text
        assert "kb/" not in html
        assert "Lista verificată MedHaven (din DDInter 2.0)" in html

    created = doctor.post("/v1/patients", json={"name": "Străin", "birth_year": 1950}).json()
    pid = created["id"]
    r = doctor.get(f"/portal/patients/{pid}")
    assert r.status_code == 404
    assert "Pacientul nu e în lista dumneavoastră" in r.text
    assert "Linkul a expirat" not in r.text
