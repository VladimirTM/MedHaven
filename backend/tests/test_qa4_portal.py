"""QA4 (14.4): portalul medicului — decizii secundare + control segmentat, „Schimbă”, QA-14, QA-16, IP LAN și accesibilitate."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

import pytest
from engine_helpers import real_kb
from fastapi.testclient import TestClient

from polygraph import net
from polygraph.api import main
from polygraph.store import Store

ROOT = Path(__file__).resolve().parents[2]
STATIC = ROOT / "backend" / "polygraph" / "share" / "static"
SHARE_JS = STATIC / "share.js"
SHARE_CSS = STATIC / "share.css"
H = {"X-Patient-Token": "demo-token"}
P = "/v1/patients/pat_demo"
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


def alerts(client) -> list[dict]:
    return client.get(f"{P}/analysis", headers=H).json()["alerts"]


def test_t_qa4_01_no_primary_decision_button_and_segmented_control_under_600px(doctor):
    """T-QA4-01: nicio decizie nu are stil primar; sub 600 px există un singur rând de opțiuni (role="radiogroup")."""
    html = doctor.get(PORTAL).text
    start = html.index('<form class="review-form"')
    form = html[start : html.index("</form>", start)]
    for cls in re.findall(r'<button\s+class="([^"]+)"', form):
        if "btn" in cls.split():
            assert "btn-secondary" in cls.split(), f"Buton primar găsit în review-form: {cls}"
    assert 'role="radiogroup"' in form
    assert form.count('role="radio"') == 3

    css = SHARE_CSS.read_text(encoding="utf-8")
    assert ".decisions { display: flex; gap: 0.5rem; flex-wrap: nowrap; }" in css
    assert "@media (max-width: 37.5rem)" in css
    assert "grid-template-columns: repeat(3, 1fr);" in css


def test_t_qa4_02_change_decision_updates_resolution_and_emits_changed_event(doctor):
    """T-QA4-02: Decizie → „Schimbă” → altă decizie: alerta are ultima rezoluție, Noutăți are două evenimente,
    al doilea cu „Medicul de familie a schimbat decizia”, iar aceeași decizie repetată e idempotentă."""
    aid = next(a["id"] for a in alerts(doctor) if a["severity"] == "major")

    r1 = doctor.post(f"{PORTAL}/alerts/{aid}/review", json={"decision": "keep", "note": "Continuăm monitorizarea."})
    assert r1.status_code == 200
    assert r1.json()["resolution"]["decision"] == "keep"

    # aceeași decizie + aceeași notă → idempotent (nu dublează evenimentul)
    r_dup = doctor.post(f"{PORTAL}/alerts/{aid}/review", json={"decision": "keep", "note": "Continuăm monitorizarea."})
    assert r_dup.status_code == 200
    events_after_first = [e for e in doctor.get(f"{P}/feed", headers=H).json() if e["alert_id"] == aid]
    assert len(events_after_first) == 1
    assert events_after_first[0]["title"].startswith("Medicul de familie a revizuit:")
    assert events_after_first[0]["body"] == "Decizie: Menține tratamentul. Continuăm monitorizarea."

    # pe pagină starea revizuită are butonul „Schimbă” și formularul ascuns cu decizia curentă preselectată
    html = doctor.get(PORTAL).text
    card = html[html.index(f'id="alert-{aid}"') : html.index("</article>", html.index(f'id="alert-{aid}"'))]
    assert "data-change-review" in card and "Schimbă" in card
    assert 'data-current-decision="keep"' in card
    assert 'aria-checked="true" data-decision="keep"' in card

    # schimbarea deciziei → ultima rezoluție pe alertă + al doilea eveniment „a schimbat decizia”
    r2 = doctor.post(
        f"{PORTAL}/alerts/{aid}/review",
        json={"decision": "change_at_visit", "note": "Înlocuim AINS-ul la consultație."},
    )
    assert r2.status_code == 200
    assert r2.json()["resolution"]["decision"] == "change_at_visit"
    assert r2.json()["resolution"]["note"] == "Înlocuim AINS-ul la consultație."

    after = next(a for a in alerts(doctor) if a["id"] == aid)
    assert after["resolution"]["decision"] == "change_at_visit"

    events = [e for e in doctor.get(f"{P}/feed", headers=H).json() if e["alert_id"] == aid]
    assert len(events) == 2
    newest, first = events[0], events[1]
    assert first["title"].startswith("Medicul de familie a revizuit:")
    assert newest["title"].startswith("Medicul de familie a schimbat decizia:")
    assert newest["body"] == "Decizie: Îl modifică la consultație. Înlocuim AINS-ul la consultație."


def test_t_qa4_03_enter_in_note_and_distinct_server_vs_network_errors():
    """T-QA4-03: Enter în notă nu trimite request și arată „Alegeți o decizie mai jos”;
    500 simulat → mesajul pentru server; eroare de rețea → mesajul pentru conexiune."""
    script = f"""
    const fs = require("fs");
    const code = fs.readFileSync({json.dumps(str(SHARE_JS))}, "utf8");

    const listeners = {{}};
    const document = {{
      querySelector: () => null,
      querySelectorAll: () => [],
      addEventListener: (type, fn) => {{ (listeners[type] = listeners[type] || []).push(fn); }},
      createElement: (tag) => ({{
        tagName: tag,
        className: "",
        textContent: "",
        children: [],
        attrs: {{}},
        setAttribute(k, v) {{ this.attrs[k] = v; }},
        appendChild(c) {{ this.children.push(c); }},
      }}),
      createTextNode: (t) => ({{ textContent: t }}),
    }};
    global.window = {{ matchMedia: () => ({{ matches: false }}) }};
    global.document = document;
    global.navigator = {{}};

    let fetchCalls = 0;
    let fetchMode = "ok";
    global.fetch = () => {{
      fetchCalls += 1;
      if (fetchMode === "server") return Promise.resolve({{ status: 500, ok: false }});
      if (fetchMode === "network") return Promise.reject(new TypeError("Failed to fetch"));
      return Promise.resolve({{ status: 200, ok: true, json: () => Promise.resolve({{}}) }});
    }};

    eval(code);

    function makeForm() {{
      const hint = {{ hidden: true }};
      const error = {{ hidden: true, textContent: "" }};
      const noteInput = {{
        value: "Notă test",
        closest: (sel) => sel === ".note-input" ? noteInput : (sel === ".review-form" ? form : null),
      }};
      const btn = {{ disabled: false, value: "keep", name: "decision", classList: {{ toggle: () => {{}} }} }};
      const wrap = {{ hidden: true, replaceChildren: () => {{}} }};
      const review = {{ querySelector: (sel) => sel === ".reviewed-wrap" ? wrap : form }};
      const form = {{
        action: "/portal/patients/pat_demo/alerts/al_1/review",
        dataset: {{}},
        hidden: false,
        closest: (sel) => sel === ".review-form" ? form : (sel === ".review" ? review : null),
        querySelector: (sel) => {{
          if (sel === ".note-hint") return hint;
          if (sel === ".review-error") return error;
          if (sel === "input[name=note]") return noteInput;
          return null;
        }},
        querySelectorAll: () => [btn],
      }};
      return {{ form, hint, error, noteInput, btn }};
    }}

    (async () => {{
      const {{ form, hint, error, noteInput, btn }} = makeForm();

      // 1. Enter în notă: preventDefault, fără fetch, hint vizibil
      let prevented = false;
      listeners.keydown.forEach((fn) => fn({{ key: "Enter", target: noteInput, preventDefault: () => {{ prevented = true; }} }}));
      const enterOk = prevented && fetchCalls === 0 && hint.hidden === false;

      // 2. Submit fără decizie selectată: fără fetch, hint vizibil
      hint.hidden = true;
      listeners.submit.forEach((fn) => fn({{ target: form, submitter: null, preventDefault: () => {{}} }}));
      const noDecisionOk = fetchCalls === 0 && hint.hidden === false;

      // 3. 500 server error
      fetchMode = "server";
      listeners.submit.forEach((fn) => fn({{ target: form, submitter: btn, preventDefault: () => {{}} }}));
      await new Promise((r) => setTimeout(r, 20));
      const serverError = error.textContent;

      // 4. Network error
      fetchMode = "network";
      listeners.submit.forEach((fn) => fn({{ target: form, submitter: btn, preventDefault: () => {{}} }}));
      await new Promise((r) => setTimeout(r, 20));
      const networkError = error.textContent;

      console.log(JSON.stringify({{ enterOk, noDecisionOk, fetchCalls, serverError, networkError }}));
      process.exit(0);
    }})();
    """
    proc = subprocess.run(["node", "-e", script], check=True, capture_output=True, text=True, timeout=10)
    out = json.loads(proc.stdout.strip())
    assert out["enterOk"] is True
    assert out["noDecisionOk"] is True
    assert out["fetchCalls"] == 2
    assert out["serverError"] == "Nu s-a putut salva. Încercați din nou."
    assert out["networkError"] == "Nu s-a putut salva. Verificați conexiunea."


def test_t_qa4_04_home_page_from_localhost_shows_lan_ip_and_copy_button(doctor, monkeypatch):
    """T-QA4-04: `/` cerut de pe 127.0.0.1 sau localhost arată IP-ul din rețea (local_ips), nu localhost, și butonul „Copiază”."""
    monkeypatch.setattr(net, "local_ips", lambda: ["192.168.1.42"])
    assert net.lan_base_url("http://127.0.0.1:8000/") == "http://192.168.1.42:8000"
    assert net.lan_base_url("http://localhost:8000/") == "http://192.168.1.42:8000"

    r = doctor.get("/", headers={"Host": "127.0.0.1:8000"})
    assert r.status_code == 200
    html = r.text
    assert "http://192.168.1.42:8000" in html
    assert "127.0.0.1" not in html and "localhost" not in html
    assert 'data-copy="http://192.168.1.42:8000"' in html and "Copiază" in html


def test_t_qa4_05_accessibility_h1_logout_avatars_and_44px_touch_targets(doctor):
    """T-QA4-05: h1 pe paginile de graf, „Ieșire” pe fișă și pe tipărire, culori stabile la avatar și ținte >= 44 px."""
    # h1 pe paginile de graf (portal și share)
    share = doctor.post(f"{P}/share", headers=H).json()["share_token"]
    for path in (f"{PORTAL}/graph", f"/share/{share}/graph", f"/share/{share}/graph?embed=1"):
        html = doctor.get(path).text
        assert "<h1" in html and "Graful terapeutic" in html

    # „Ieșire” și „‹ Pacienții mei” (back-link) / „← Înapoi la fișă” pe fișă și pe tipărire
    page_html = doctor.get(PORTAL).text
    assert 'action="/portal/logout"' in page_html and "Ieșire" in page_html and 'class="back-link" href="/portal"' in page_html and "Pacienții mei</a>" in page_html
    print_html = doctor.get(f"{PORTAL}/print").text
    assert 'action="/portal/logout"' in print_html and "Ieșire" in print_html and "← Înapoi la fișă" in print_html

    # avatarul are o culoare stabilă per pacient (data-tone="0..5")
    portal_html = doctor.get("/portal").text
    tones = re.findall(r'class="patient-avatar tone-(\d)" data-tone="(\d)"', portal_html)
    assert len(tones) >= 3
    assert len({t[0] for t in tones}) >= 2

    # țintele interactive au min-height >= 2.75rem (44 px) în share.css, fără reducere sub 44 px pe mobil
    css = SHARE_CSS.read_text(encoding="utf-8")
    assert "min-height: 2.25rem" not in css
    assert "@media (pointer: coarse)" in css
    assert ".info > summary.info-btn" in css and "width: 2.75rem;\n  height: 2.75rem;" in css
    assert "@media (max-width: 56.25rem)" in css
