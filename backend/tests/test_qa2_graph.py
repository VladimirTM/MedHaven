"""QA2: graful comun între aplicație și portal (T-QA2-01..07, Q3-12)."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest
from engine_helpers import TODAY, demo, real_kb

from polygraph.engine.analyze import analyze
from polygraph.engine.texts_ro import ro_name
from polygraph.share.view import med_row

ROOT = Path(__file__).resolve().parents[2]
PORTAL_CORE = ROOT / "backend" / "polygraph" / "share" / "static" / "graph-core.js"
APP_CORE = ROOT / "app" / "PolyGraph" / "Graph" / "graph-core.js"
PORTAL_JS = ROOT / "backend" / "polygraph" / "share" / "static" / "graph.js"
APP_HTML = ROOT / "app" / "PolyGraph" / "Graph" / "graph.html"
CYTOSCAPE = ROOT / "backend" / "polygraph" / "share" / "static" / "cytoscape.min.js"


@pytest.fixture(scope="module")
def kb():
    return real_kb()


@pytest.fixture(scope="module")
def demo_analysis(kb):
    patient, meds = demo()
    return analyze(patient, meds, TODAY, kb)


def test_t_qa2_01_graph_core_is_byte_identical_between_backend_and_app():
    assert PORTAL_CORE.read_bytes() == APP_CORE.read_bytes()
    assert b"pgRadialPositions" in PORTAL_CORE.read_bytes()
    assert b"window.pgMount" in PORTAL_CORE.read_bytes()
    assert 'src="graph-core.js"' in APP_HTML.read_text(encoding="utf-8")


def test_t_qa2_02_food_and_substance_labels_are_in_romanian(demo_analysis):
    nodes = {n["data"]["id"]: n["data"] for n in demo_analysis["graph"]["nodes"]}
    # QA-04: cheia alimentului „vitamin_k” nu se taie după ultimul „_”
    assert "f:k" not in nodes
    assert nodes["f:vitamin_k"]["label"] == "alimente bogate în vitamina K"
    # QA-05: nicio substanță în engleză în graf sau pe fișă
    sub_labels = {n["label"] for n in nodes.values() if n["type"] == "substance"}
    assert "carbonat de calciu" in sub_labels
    assert "calcium carbonate" not in sub_labels
    _, meds = demo()
    dcis = [med_row(m)["dci"] for m in meds]
    assert "carbonat de calciu, colecalciferol" in dcis
    assert not any("calcium" in d or "cholecalciferol" in d for d in dcis)
    assert ro_name("magnesium oxide", "MAGNESII OXIDUM") == "oxid de magneziu"
    assert ro_name("potassium chloride", "KALII CHLORIDUM") == "clorură de potasiu"


def _eval_mount(graph: dict, *, dark: bool = False) -> dict:
    """Rulează graph-core.js + cytoscape.min.js în Node (headless) și întoarce stilul și încadrarea inițială."""
    probe = r"""
const fs = require("fs");
const cytoscape = require(process.argv[1]);
global.window = { cytoscape };
global.cytoscape = cytoscape;
require(process.argv[2]);
const graph = JSON.parse(fs.readFileSync(0, "utf8"));
const alerts = [];
const meds = [];
const mounted = window.pgMount(null, graph, {
  dark: process.argv[3] === "1",
  width: 390,
  height: 640,
  onAlert: (id) => alerts.push(id),
  onMed: (id) => meds.push(id),
});
const cy = mounted.cy;
const takes = cy.edges('[type = "takes"]').first();
const mod = cy.edges('[type = "interacts"][severity = "moderate"]').first();
const maj = cy.edges('[alert_id = "al_ddi_med_01_med_02"]').first();
const prod = cy.nodes('[id = "med_05"]').first();
const atc = cy.nodes('[type = "atc_class"]').first();
const sub = cy.nodes('[id = "s:B01AA07"]').first();
const amlo = cy.nodes('[id = "med_04"]').first();
const s1 = cy.nodes('[id = "s:B01AA07"]').first().position();
const s2 = cy.nodes('[id = "s:M01AE01"]').first().position();
const mid = { x: (s1.x + s2.x) / 2, y: (s1.y + s2.y) / 2 };
const pan = cy.pan(), z = cy.zoom();
const screenMid = { x: mid.x * z + pan.x, y: mid.y * z + pan.y };
maj.emit("tap");
cy.nodes('[id = "med_01"]').first().emit("tap");
const zoomInitial = cy.zoom();
mounted.reset(false);
const zoomAfterReset = cy.zoom();
console.log(JSON.stringify({
  takesColor: takes.style("line-color"),
  takesOpacity: Number(takes.style("line-opacity") ?? takes.style("opacity")),
  prodBorder: prod.style("border-color"),
  modWidth: parseFloat(mod.style("width")),
  modOpacity: parseFloat(mod.style("opacity")),
  majWidth: parseFloat(maj.style("width")),
  atcDisplay: atc.style("display"),
  subLabel: sub.style("label"),
  amloLabel: amlo.style("label"),
  productSides: cy.nodes('[type = "product"]').map((n) => n.data("lside")),
  legend: mounted.legend.map((i) => [i.num, i.id, i.label, i.products, i.classes]),
  zoomInitial,
  zoomAfterReset,
  screenMid,
  alerts,
  meds,
}));
cy.destroy();
process.exit(0);
"""
    proc = subprocess.run(
        ["node", "-e", probe, str(CYTOSCAPE), str(PORTAL_CORE), "1" if dark else "0"],
        input=json.dumps(graph),
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(proc.stdout)


def test_t_qa2_03_04_06_palette_tap_and_worst_alert_focus(demo_analysis):
    light = _eval_mount(demo_analysis["graph"], dark=False)
    dark = _eval_mount(demo_analysis["graph"], dark=True)

    # T-QA2-03: muchiile neutre nu cad pe griul opac implicit rgb(153,153,153), iar bordura nu e neagră în dark mode
    assert light["takesColor"] != "rgb(153,153,153)" and dark["takesColor"] != "rgb(153,153,153)"
    assert dark["prodBorder"] not in ("rgb(0,0,0)", "#000000")

    # T-QA2-04: tap pe muchia Sintrom–Nurofen trimite aceeași alertă; tap pe produs trimite id-ul medicamentului
    assert light["alerts"] == ["al_ddi_med_01_med_02"]
    assert light["meds"] == ["med_01"]
    assert 'open("alert", id)' in PORTAL_JS.read_text(encoding="utf-8")
    assert "post('alert', id)" in APP_HTML.read_text(encoding="utf-8")

    # T-QA2-06 / Q3-12: ce e grav se vede primul, centrat la deschidere, fără etichete de clasă peste medicamente
    assert light["modWidth"] == 1.5 and light["modOpacity"] == pytest.approx(0.4)
    assert light["majWidth"] == 4
    assert light["atcDisplay"] == "none"
    assert light["zoomInitial"] > light["zoomAfterReset"]
    assert 120 <= light["screenMid"]["x"] <= 270 and 200 <= light["screenMid"]["y"] <= 440


def test_t_qa2_07_substances_are_numbered_circles_with_a_legend(demo_analysis):
    """Numele substanțelor și ale claselor nu mai stau în desen (se suprapuneau cu ale medicamentelor): substanța e
    un cerc cu numărul ei, iar legenda (pgLegend) dă numărul, numele, medicamentul și clasa."""
    light = _eval_mount(demo_analysis["graph"], dark=False)
    # în desen: numărul substanței și numele medicamentului fără concentrație
    assert light["subLabel"] == "1"
    assert light["amloLabel"] == "Amlodipină Actavis"
    # fiecare nume de medicament are un loc ales (pgPlaceLabels)
    assert all(side in ("top", "bottom", "left", "right") for side in light["productSides"])
    # legenda: numerele urmează ordinea substanțelor din graph.nodes, cu medicamentul și clasa
    first = light["legend"][0]
    assert first == [1, "s:B01AA07", "acenocumarol", ["Sintrom 4 mg"], ["antagoniști ai vitaminei K"]]
    subs = [n["data"]["id"] for n in demo_analysis["graph"]["nodes"] if n["data"]["type"] == "substance"]
    assert [item[1] for item in light["legend"]] == subs
    assert [item[0] for item in light["legend"]] == list(range(1, len(subs) + 1))


def test_t_qa2_07_legend_numbers_match_the_app_on_the_contract_example():
    """Aceleași numere ca GraphLegendTests din aplicație, pe contracts/examples/graph.demo.json."""
    graph = json.loads((ROOT / "contracts" / "examples" / "graph.demo.json").read_text(encoding="utf-8"))
    probe = r"""
const fs = require("fs");
global.window = {};
require(process.argv[1]);
const graph = JSON.parse(fs.readFileSync(0, "utf8"));
console.log(JSON.stringify(window.pgLegend(graph)));
"""
    proc = subprocess.run(
        ["node", "-e", probe, str(PORTAL_CORE)], input=json.dumps(graph), text=True, capture_output=True, check=True
    )
    legend = json.loads(proc.stdout)
    assert [i["num"] for i in legend] == list(range(1, 10))
    assert legend[0]["id"] == "s:B01AA07" and legend[0]["products"] == ["Sintrom 4 mg"]
    calcium = [i for i in legend if i["products"] == ["Calcium + Vitamin D"]]
    assert [(i["num"], i["id"]) for i in calcium] == [(6, "s:A12AA04"), (7, "s:A11CC05")]
