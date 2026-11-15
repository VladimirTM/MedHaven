"""E3 (calendarul și cutiuța) și E6 (mai mulți pacienți în același browser), docs/PLAN.md 14.6.

T-E3-01 grid-ul pe 7 zile = build_schedule pe fiecare zi; T-E3-02 bifa rămâne după refresh și se șterge când
programul zilei se schimbă; fără „Am luat” în calendar. E6: doi pacienți, comutarea și ieșirea doar a unuia.
"""

from __future__ import annotations

import json
from datetime import date, timedelta

import pytest
from engine_helpers import FIX, real_kb
from fastapi.testclient import TestClient

from polygraph.api import main
from polygraph.share.family import week_start
from polygraph.store import Store

P = "/v1/patients/pat_demo"
H = {"X-Patient-Token": "demo-token"}
DAY = "2026-11-14"
MED_09 = json.loads((FIX / "med_09_fromilid.json").read_text(encoding="utf-8"))


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("PG_TODAY", DAY)
    monkeypatch.setenv("DEMO_MODE", "1")
    monkeypatch.setenv("PG_MEDIA_DIR", str(tmp_path / "media"))
    main.configure(store=Store(":memory:"), kb=real_kb())
    main.reset_demo()
    with TestClient(main.app, follow_redirects=False) as c:
        assert c.get("/acasa/demo").status_code == 303
        yield c
    main.configure(None, None)


def test_week_cells_match_schedule(client):
    start = week_start(date.fromisoformat(DAY))
    patient = main.store().get_patient("pat_demo")
    meds = main.store().list_meds("pat_demo")
    html = client.get("/acasa/saptamana").text
    for i in range(7):
        sched = main.build_schedule(patient, meds, start + timedelta(days=i), main.kb())
        for m in sched["moments"]:
            assert m["label"] in html
    assert "Am luat" not in html
    filling = client.get("/acasa/saptamana?cutiuta=1").text
    assert (
        'role="switch" aria-checked="true"' in filling and "<dialog" in filling and "Am luat" in filling
    )  # doar în fraza explicativă
    assert "Compartiment pregătit" in filling


def test_pillbox_check_survives_and_resets_on_change(client):
    r = client.post("/acasa/cutiuta", data={"day": DAY, "label": "La cină", "prepared": 1})
    assert r.status_code == 303
    html = client.get("/acasa/saptamana?cutiuta=1").text
    assert "✓ Pregătit" in html
    # un medicament nou la cină schimbă conținutul compartimentului: bifa se șterge
    assert client.post(f"{P}/meds", headers=H, json=MED_09).status_code == 201
    html = client.get("/acasa/saptamana?cutiuta=1").text
    assert "Programul s-a schimbat" in html
    assert main.store().pillbox("pat_demo", DAY, DAY) == {}


def test_pillbox_uncheck(client):
    client.post("/acasa/cutiuta", data={"day": DAY, "label": "La cină", "prepared": 1})
    client.post("/acasa/cutiuta", data={"day": DAY, "label": "La cină", "prepared": 0})
    assert main.store().pillbox("pat_demo", DAY, DAY) == {}


def _link(pid: str, token: str) -> str:
    code = main.store().create_home_link(pid, "2999-01-01T00:00:00Z")
    return f"/acasa/intra/{code}"


def test_two_patients_switch_and_logout(client):
    ion = "pat_demo_ion"
    assert client.get(_link(ion, "")).status_code == 303
    html = client.get("/acasa").text
    assert "Ion" in html and "patient-switch" in html  # Ion e pacientul curent, Maria rămâne în listă
    assert client.post("/acasa/pacient", data={"pid": "pat_demo"}).status_code == 303
    assert '<span class="family-patient">Maria</span>' in client.get("/acasa").text
    # un pacient fără sesiune în acest browser nu poate fi ales
    client.post("/acasa/pacient", data={"pid": "pat_demo_ioana"})
    assert '<span class="family-patient">Maria</span>' in client.get("/acasa").text
    # ieșirea închide doar pacientul de pe ecran
    client.post("/acasa/iesire")
    assert '<span class="family-patient">Ion</span>' in client.get("/acasa").text
    client.post("/acasa/iesire")
    assert "Deschideți linkul din aplicație" in client.get("/acasa").text


def test_doses_and_pillbox_stay_per_patient(client):
    """T-E6-02: „Am luat” și cutiuța pe Ion nu ating Maria (și invers)."""
    ion = "pat_demo_ion"
    client.get(_link(ion, ""))  # Ion devine pacientul de pe ecran, Maria rămâne în sesiune
    patient = main.store().get_patient(ion)
    sched = main.build_schedule(patient, main.store().list_meds(ion), date.fromisoformat(DAY), main.kb())
    assert sched["moments"], "Ion are nevoie de cel puțin un moment în program"
    first = sched["moments"][0]
    maria_doses = main.store().list_doses("pat_demo")

    assert client.post("/acasa/doze", data={"moment": first["time"]}).status_code == 303
    client.post("/acasa/cutiuta", data={"day": DAY, "label": first["label"], "prepared": 1})

    ion_doses = main.store().list_doses(ion)
    assert {d["med_id"] for d in ion_doses if d["status"] == "taken"} == {d["med_id"] for d in first["doses"]}
    assert main.store().pillbox(ion, DAY, DAY) != {}
    assert main.store().list_doses("pat_demo") == maria_doses
    assert main.store().pillbox("pat_demo", DAY, DAY) == {}

    # înapoi la Maria: bifele lui Ion nu apar la ea
    assert client.post("/acasa/pacient", data={"pid": "pat_demo"}).status_code == 303
    assert "✓ Pregătit" not in client.get("/acasa/saptamana?cutiuta=1").text
