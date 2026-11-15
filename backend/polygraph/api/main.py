"""Backend-ul real PolyGraph (FastAPI), din B2: pacienți, medicamente, analiză, what-if, căutare în kb.

Pornire: `make dev` (0.0.0.0:8000). Programul zilei și dozele vin din B4, check-in-urile și Noutățile din B5;
portalul medicului de familie (lista de pacienți, fișa, tipărirea, graful) din B6. Variabile de mediu:
- PG_KB: calea către kb.sqlite (implicit kb/kb.sqlite, `make kb`)
- PG_APP_DB: calea către app.sqlite (implicit backend/app.sqlite)
- PG_MEDIA_DIR: folderul fotografiilor scanate (implicit backend/media/)
- PG_TODAY: data „de azi” (ISO), pentru demo și teste; implicit data din Europe/Bucharest
- DEMO_MODE=1: creează pacientul demo (pat_demo, token demo-token), medicul demo din portal (cu doi pacienți în plus)
  și activează POST /demo/reset și POST /demo/missed-dose (B7)
- PG_DOCTOR_CODE: codul de acces al medicului demo în /portal (implicit medic-demo)
"""

from __future__ import annotations

import asyncio
import copy
import json
import logging
import os
import secrets
import sys
from contextlib import asynccontextmanager
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Annotated, Any, Literal
from urllib.parse import urlencode
from zoneinfo import ZoneInfo

from fastapi import FastAPI, File, Form, Header, HTTPException, Query, Request, Response, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, TypeAdapter, ValidationError

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "contracts"))

import validate as contracts  # noqa: E402  (contracts/validate.py: schemele JSON)

from polygraph.api.errors import request_message, schema_message  # noqa: E402
from polygraph.api.media import demo_photo_urls, get_photo, save_photo, save_pill_photo  # noqa: E402
from polygraph.demo.seed import seed_history, simulate_missed_dose  # noqa: E402
from polygraph.engine import analyze, new_alerts  # noqa: E402
from polygraph.engine.analyze import make_ctx  # noqa: E402
from polygraph.extract.display import display_brand, display_form, display_strength  # noqa: E402
from polygraph.extract.match import confirmed_product, scan  # noqa: E402
from polygraph.extract.ocr_match import OcrLine  # noqa: E402
from polygraph.kb import Kb, KbMissing, default_kb  # noqa: E402
from polygraph.net import lan_base_url  # noqa: E402
from polygraph.schedule import build_schedule  # noqa: E402
from polygraph.schedule.move import anchors_in_order, changed_anchors, move_today  # noqa: E402
from polygraph.share import STATIC_DIR, render  # noqa: E402
from polygraph.share.family import (  # noqa: E402
    cell_signature,
    check_context,
    dose_key,
    hours_context,
    meds_context,
    sent_when,
    sheet_banner,
    sheet_context,
    today_context,
    week_context,
    week_start,
)
from polygraph.share.view import (  # noqa: E402
    page_context,
    patient_card,
    portal_summary,
    review_event,
    sheet_event,
    sheet_snapshot,
    whatif_context,
)
from polygraph.store import MedIdTaken, Store  # noqa: E402
from polygraph.voice import can_i_take  # noqa: E402
from polygraph.voice.correlate import correlate, feed_event, reply_text  # noqa: E402
from polygraph.voice.understand import understand  # noqa: E402

FIX = ROOT / "contracts" / "fixtures"
DEMO = json.loads((FIX / "demo_patient.json").read_text(encoding="utf-8"))
DEMO_ID, DEMO_TOKEN = "pat_demo", "demo-token"
TZ = ZoneInfo("Europe/Bucharest")
LOG = logging.getLogger("uvicorn.error")
MED_FIELDS = (
    "product",
    "substances",
    "dosage",
    "prescriber",
    "start_date",
    "end_date",
    "photo_url",
    "pill_photo_url",
    "match",
    "source",
)


class App:
    """Dependențele procesului; testele le înlocuiesc cu `configure(...)`."""

    store: Store | None = None
    kb: Kb | None = None


deps = App()


def configure(store: Store | None = None, kb: Kb | None = None) -> None:
    deps.store, deps.kb = store, kb


def store() -> Store:
    if deps.store is None:
        deps.store = Store()
    return deps.store


def kb() -> Kb:
    return deps.kb if deps.kb is not None else default_kb()


def today() -> date:
    raw = os.environ.get("PG_TODAY")
    return date.fromisoformat(raw) if raw else datetime.now(TZ).date()


def now_iso() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def demo_mode() -> bool:
    return os.environ.get("DEMO_MODE") == "1"


DEMO_DOCTOR = ("doc_demo", "dr. Elena Popa")
# ceilalți doi pacienți din lista medicului demo, ca portalul să arate ca o listă reală (subseturi din regimul Mariei)
DEMO_EXTRA = (
    (
        {"id": "pat_demo_ion", "name": "Ion", "birth_year": 1944, "caregiver_name": "Mihai"},
        ("med_03", "med_04", "med_05", "med_07"),
    ),
    # nu „Ana”: așa o cheamă pe fiica Mariei din scenariu, iar lista medicului e proiectată pe ecran
    ({"id": "pat_demo_ioana", "name": "Ioana", "birth_year": 1952, "caregiver_name": None}, ("med_05", "med_06")),
)
LEGACY_DEMO_IDS = ("pat_demo_ana",)  # din app.sqlite-urile create înainte de redenumire


def reset_demo(live_scan: bool = False) -> None:
    s = store()
    s.delete_patient(DEMO_ID)
    patient = copy.deepcopy(DEMO["patient"])
    s.create_patient(patient, DEMO_TOKEN)
    meds = [m for m in DEMO["meds"] if not (live_scan and m["id"] in ("med_01", "med_02"))]
    s.replace_meds(DEMO_ID, copy.deepcopy(meds))
    try:
        catalog = kb()
        seed_history(s, DEMO_ID, patient, meds, lambda day: build_schedule(patient, meds, day, catalog), today())
    except KbMissing:
        LOG.warning("DEMO      kb.sqlite lipsește (make kb): pacientul demo pornește fără istoric de doze")
    doctor_id, doctor_name = DEMO_DOCTOR
    s.upsert_doctor(doctor_id, doctor_name, os.environ.get("PG_DOCTOR_CODE") or "medic-demo")
    s.link_patient(doctor_id, DEMO_ID)
    for legacy in LEGACY_DEMO_IDS:
        s.delete_patient(legacy)
    for extra, med_ids in DEMO_EXTRA:
        s.delete_patient(extra["id"])
        s.create_patient({**extra, "anchors": DEMO["patient"]["anchors"]})
        s.replace_meds(extra["id"], [copy.deepcopy(m) for m in DEMO["meds"] if m["id"] in med_ids])
        s.link_patient(doctor_id, extra["id"])


@asynccontextmanager
async def lifespan(_: FastAPI):
    if demo_mode() and store().get_patient(DEMO_ID) is None:
        reset_demo()
    yield


app = FastAPI(title="MedHaven", version="1.0.0", lifespan=lifespan)
app.mount("/static/share", StaticFiles(directory=STATIC_DIR), name="share-static")


def invalid(schema: str, body: Any) -> None:
    errors = sorted(contracts.validator(schema).iter_errors(body), key=lambda e: list(e.absolute_path))
    if errors:
        LOG.warning("422       %s: %s", schema, contracts.schema_errors(schema, body)[:10])
        raise HTTPException(422, schema_message(errors))


MAX_UNITS_PER_MOMENT = 10  # QA-09: peste atât pe un moment e aproape sigur o greșeală de citire sau de tastare
DOSE_FUTURE_LIMIT = timedelta(hours=24)


def plausible_med(med: dict[str, Any]) -> None:
    """QA-08, QA-09: ce trece de schemă, dar nu poate fi adevărat, primește 422 în loc să dispară în tăcere.
    Posologia 0-0-0-0 fără „la nevoie” rămâne permisă: e starea „Posologie necompletată” din aplicație
    (o cutie scanată nu spune niciodată cum se ia medicamentul), iar familia o completează după."""
    start, end = med.get("start_date"), med.get("end_date")
    if start and end and end < start:
        raise HTTPException(422, "Data de sfârșit e înaintea datei de început.")
    pattern = med["dosage"]["pattern"]
    if any(q > MAX_UNITS_PER_MOMENT for q in pattern.values()):
        raise HTTPException(422, f"Doza pe un moment al zilei nu poate depăși {MAX_UNITS_PER_MOMENT} unități.")


def auth(pid: str, token: str | None) -> dict[str, Any]:
    patient = store().get_patient(pid)
    if patient is None:
        raise HTTPException(404, "Pacientul nu există.")
    if not token or store().patient_id_for_token(token) != pid:
        raise HTTPException(401, "Lipsește sau e greșit X-Patient-Token.")
    return patient


# ---------------------------------------------------------------- sistem


@app.get("/", response_class=HTMLResponse)
def root(request: Request) -> HTMLResponse:
    # pagina de prezentare; QR-ul din `make demo` deschis cu camera telefonului ajunge tot aici,
    # deci adresa de pus în aplicație rămâne pe pagină (secțiunea „Conectați aplicația”)
    return page("home.html", base=lan_base_url(str(request.base_url)))


@app.get("/health")
def health() -> dict[str, Any]:
    return {"ok": True, "mode": "backend"}


# ---------------------------------------------------------------- pacienți


# înălțimea, greutatea și afecțiunile (patient.schema.json); deocamdată doar se arată medicului, motorul nu le folosește
PROFILE_FIELDS = ("height_cm", "weight_kg", "conditions", "conditions_note")


@app.post("/v1/patients", status_code=201)
def create_patient(body: dict[str, Any]) -> dict[str, Any]:
    invalid("patient_create", body)
    patient = {
        "id": f"pat_{secrets.token_hex(4)}",
        "name": body["name"],
        "birth_year": body["birth_year"],
        "caregiver_name": body.get("caregiver_name"),
        "anchors": body.get("anchors") or DEMO["patient"]["anchors"],
    }
    # profilul de sănătate e opțional: în onboarding se poate sări
    patient.update({k: body[k] for k in PROFILE_FIELDS if k in body})
    token = store().create_patient(patient)
    return {"id": patient["id"], "patient_token": token, "patient": patient}


@app.get("/v1/patients/{pid}")
def get_patient(pid: str, x_patient_token: str | None = Header(None)) -> dict[str, Any]:
    return auth(pid, x_patient_token)


@app.patch("/v1/patients/{pid}")
def update_patient(pid: str, body: dict[str, Any], x_patient_token: str | None = Header(None)) -> dict[str, Any]:
    patient = auth(pid, x_patient_token)
    extra = set(body) - {"name", "birth_year", "caregiver_name", "anchors", *PROFILE_FIELDS}
    if extra:
        raise HTTPException(422, f"Câmpuri necunoscute: {sorted(extra)}")
    return save_patient(pid, patient, {**patient, **body})


def save_patient(pid: str, old: dict[str, Any], patient: dict[str, Any]) -> dict[str, Any]:
    """PATCH /patients și pagina „Orele zilei” de pe web (E1). Orele schimbate mută și dozele de azi deja bifate."""
    invalid("patient", patient)
    if not anchors_in_order(patient["anchors"]):
        raise HTTPException(422, "Orele trebuie să fie în ordinea zilei: trezirea, micul dejun, prânzul, cina, culcarea.")
    if patient["anchors"] == old["anchors"]:
        store().update_patient(pid, patient)
        return patient
    meds = store().list_meds(pid)
    try:
        catalog = kb()
    except KbMissing:
        store().update_patient(pid, patient)
        return patient
    moved = move_today(store(), pid, today(), old, patient, lambda p, day: build_schedule(p, meds, day, catalog))
    LOG.info(
        "PROGRAM   orele zilei schimbate (%s), %d doze de azi mutate",
        ", ".join(changed_anchors(old["anchors"], patient["anchors"])),
        moved,
    )
    return patient


# ---------------------------------------------------------------- medicamente


class ScanLine(BaseModel):
    text: str = Field(max_length=1024)
    height: float = Field(default=0, ge=0, le=1)


OCR_LINES = TypeAdapter(list[ScanLine])
MAX_SCAN_IMAGE = 5 * 1024 * 1024


@app.post("/v1/patients/{pid}/scan")
def scan_med(
    pid: str,
    kind: Literal["box", "prescription"] = Form(),
    ocr_lines: str | None = Form(None),
    datamatrix: str | None = Form(None, max_length=256),
    image: Annotated[UploadFile | None, File()] = None,
    x_patient_token: str | None = Header(None),
) -> dict[str, Any]:
    auth(pid, x_patient_token)
    try:
        data = OCR_LINES.validate_json(ocr_lines) if ocr_lines else []
    except ValidationError:
        raise HTTPException(422, "ocr_lines trebuie să conțină liniile OCR în format JSON.") from None
    if len(data) > 256:
        raise HTTPException(422, "Sunt prea multe linii OCR.")
    picture = image.file.read(MAX_SCAN_IMAGE + 1) if image else b""
    if len(picture) > MAX_SCAN_IMAGE:
        raise HTTPException(413, "Imaginea depășește 5 MB.")
    mime = (image.content_type or "image/jpeg") if image else "image/jpeg"
    photo_url = save_photo(picture) if picture else None
    result = scan(kb(), store(), kind, [OcrLine(line.text, line.height) for line in data], picture, mime, datamatrix)
    for candidate in result["candidates"]:
        candidate["photo_url"] = photo_url
        # cutiile din demo/photos/gtins.csv primesc pozele pregătite (cutia și pastila), și când telefonul
        # recunoaște cutia doar din cod, fără poză (gtin_cache)
        box, pill = demo_photo_urls(candidate["product"].get("gtin"))
        if box:
            candidate["photo_url"] = box
        if pill:
            candidate["pill_photo_url"] = pill
    return result


@app.get("/media/{name}")
def media(name: str) -> Response:
    return get_photo(name)


@app.get("/v1/patients/{pid}/meds")
def list_meds(pid: str, x_patient_token: str | None = Header(None)) -> list[dict[str, Any]]:
    auth(pid, x_patient_token)
    return store().list_meds(pid)


@app.post("/v1/patients/{pid}/meds", status_code=201)
def add_med(pid: str, body: dict[str, Any], response: Response, x_patient_token: str | None = Header(None)) -> dict[str, Any]:
    patient = auth(pid, x_patient_token)
    invalid("medication_item", body)
    plausible_med(body)
    med = copy.deepcopy(body)
    saved = store().get_med(pid, med["id"])
    if saved is not None:
        return replayed_med(saved, med, response)
    catalog_product = None
    if med["product"].get("gtin"):
        try:
            catalog = kb()
            catalog_id = confirmed_product(catalog, med)
            if catalog_id is not None:
                catalog_product = (catalog.version, catalog_id)
        except KbMissing:
            pass
    before = alerts_or_none(pid, patient)
    try:
        store().add_med(pid, med, catalog_product)
    except MedIdTaken as taken:  # Q3-11: o cerere identică a ajuns între timp (dublă apăsare, reîncercare)
        return replayed_med(taken.saved, med, response)
    announce_new_alerts(pid, patient, before, med)
    return med


def replayed_med(saved: dict[str, Any], med: dict[str, Any], response: Response) -> dict[str, Any]:
    """QA-10: aceeași cerere reluată nu dublează medicamentul și nu repetă alertele din Noutăți."""
    if saved != med:
        raise HTTPException(409, "Există deja un medicament cu acest id.")
    response.status_code = 200
    return saved


def alerts_or_none(pid: str, patient: dict[str, Any]) -> list[dict[str, Any]] | None:
    try:
        return run_analysis(pid, patient, store().list_meds(pid))["alerts"]
    except KbMissing:
        return None


def joined_names(names: list[str]) -> str:
    """„Sintrom”, „Sintrom și Nurofen”, „Sintrom, Nurofen și Aspenter”."""
    if len(names) <= 1:
        return "".join(names)
    return ", ".join(names[:-1]) + " și " + names[-1]


def new_alert_body(alert: dict[str, Any], brands: dict[str, str], med: dict[str, Any]) -> str:
    """Textul din Noutăți pentru o alertă apărută la salvarea lui `med`: ce medicamente sunt implicate, fără să
    repete numele celui nou („Paduden SR, după ce s-a adăugat Paduden SR”), apoi recomandarea."""
    added = med["product"]["brand"]
    others = [brands.get(m, m) for m in alert["med_ids"] if m != med["id"]]
    if med["id"] not in alert["med_ids"]:
        # alerta ține de alte medicamente (de ex. scorul anticolinergic), dar a apărut odată cu cel nou
        lead = f"{joined_names(others)}. A apărut după ce s-a adăugat {added}."
    elif others:
        lead = f"{added}, adăugat acum, împreună cu {joined_names(others)}."
    else:
        lead = f"Privește {added}, adăugat acum."
    return f"{lead} {alert['recommendation']}"


def announce_new_alerts(pid: str, patient: dict[str, Any], before: list[dict[str, Any]] | None, med: dict[str, Any]) -> None:
    """Alertele grave apărute la un medicament nou ajung în Noutăți (pe telefonul aparținătorului) și în log."""
    after = alerts_or_none(pid, patient)
    if before is None or after is None:
        return
    brands = {m["id"]: m["product"]["brand"] for m in store().list_meds(pid)}
    at = datetime.now(TZ).replace(microsecond=0).isoformat()
    for alert in new_alerts(before, after):
        if alert["severity"] not in ("critical", "major") or alert["kind"] == "food":
            continue
        names = " + ".join(brands.get(m, m) for m in alert["med_ids"])
        LOG.info("ALERTĂ    nouă %-8s %s (%s) · sursa: %s", alert["severity"], alert["title"], names, alert["source"]["db"])
        store().add_event(
            pid,
            {
                "id": f"ev_alert_{secrets.token_hex(4)}",
                "at": at,
                "type": "alert_new",
                "severity": alert["severity"],
                "title": f"Alertă nouă: {alert['title']}",
                "body": new_alert_body(alert, brands, med),
                "med_ids": alert["med_ids"],
                "alert_id": alert["id"],
                "checkin_id": None,
            },
        )


MERGED_MED_OBJECTS = ("product", "dosage", "prescriber")


def merged_med(med: dict[str, Any], body: dict[str, Any]) -> dict[str, Any]:
    """E0: obiectele de nivel doi (product, dosage, prescriber) se combină cu cele salvate, ca un PATCH parțial
    să nu șteargă `dosage.raw` sau numele medicului; `substances` și câmpurile simple se înlocuiesc întregi.
    Un câmp trimis explicit cu null rămâne null."""
    out = {**med}
    for key, value in body.items():
        if key in MERGED_MED_OBJECTS and isinstance(value, dict) and isinstance(med.get(key), dict):
            out[key] = {**med[key], **value}
        else:
            out[key] = value
    return out


@app.patch("/v1/patients/{pid}/meds/{mid}")
def update_med(pid: str, mid: str, body: dict[str, Any], x_patient_token: str | None = Header(None)) -> dict[str, Any]:
    auth(pid, x_patient_token)
    med = store().get_med(pid, mid)
    if med is None:
        raise HTTPException(404, "Medicamentul nu există.")
    extra = set(body) - set(MED_FIELDS)
    if extra:
        raise HTTPException(422, f"Câmpuri care nu se pot edita: {sorted(extra)}")
    med = merged_med(med, copy.deepcopy(body))
    invalid("medication_item", med)
    plausible_med(med)
    store().update_med(pid, med)
    return med


MAX_PILL_PHOTO = 5 * 1024 * 1024


@app.post("/v1/patients/{pid}/meds/{mid}/pill-photo")
def upload_pill_photo(
    pid: str,
    mid: str,
    image: Annotated[UploadFile | None, File()] = None,
    x_patient_token: str | None = Header(None),
) -> dict[str, Any]:
    """E5: poza unei pastile, făcută de familie. Nu se recunoaște și nu schimbă analiza; doar se arată lângă cutie."""
    auth(pid, x_patient_token)
    med = store().get_med(pid, mid)
    if med is None:
        raise HTTPException(404, "Medicamentul nu există.")
    if image is None:
        raise HTTPException(422, "Lipsește poza pastilei.")
    picture = image.file.read(MAX_PILL_PHOTO + 1)
    if len(picture) > MAX_PILL_PHOTO:
        raise HTTPException(422, "Poza pastilei depășește 5 MB.")
    try:
        med["pill_photo_url"] = save_pill_photo(picture)
    except ValueError:
        raise HTTPException(422, "Poza pastilei trebuie să fie JPEG.") from None
    store().update_med(pid, med)
    return med


@app.delete("/v1/patients/{pid}/meds/{mid}/pill-photo")
def delete_pill_photo(pid: str, mid: str, x_patient_token: str | None = Header(None)) -> dict[str, Any]:
    auth(pid, x_patient_token)
    med = store().get_med(pid, mid)
    if med is None:
        raise HTTPException(404, "Medicamentul nu există.")
    med["pill_photo_url"] = None
    store().update_med(pid, med)
    return med


@app.delete("/v1/patients/{pid}/meds/{mid}", status_code=204)
def delete_med(pid: str, mid: str, x_patient_token: str | None = Header(None)) -> Response:
    auth(pid, x_patient_token)
    if not store().delete_med(pid, mid):
        raise HTTPException(404, "Medicamentul nu există.")
    return Response(status_code=204)


# ---------------------------------------------------------------- analiză


def run_analysis(pid: str, patient: dict[str, Any], meds: list[dict[str, Any]]) -> dict[str, Any]:
    result = analyze(patient, meds, today(), kb=kb(), checkins=store().list_checkins(pid))
    states = store().alert_states(pid)
    for a in result["alerts"]:
        if a["id"] in states:
            a.update(states[a["id"]])
    return result


@app.get("/v1/patients/{pid}/analysis")
def analysis(pid: str, x_patient_token: str | None = Header(None)) -> dict[str, Any]:
    patient = auth(pid, x_patient_token)
    result = run_analysis(pid, patient, store().list_meds(pid))
    return {**result, "analyzed_at": now_iso()}


def med_from_kb(hit: dict[str, Any], mid: str) -> dict[str, Any]:
    """Un MedicationItem minim din rezultatul căutării în kb (pentru what-if pe text)."""
    return {
        "id": mid,
        "source": "manual",
        "product": {
            "brand": hit["brand"],
            "strength_text": hit["strength_text"],
            "form": hit["form"],
            "gtin": None,
            "pack_size": None,
            "expiry": None,
            "batch": None,
        },
        "substances": hit["substances"],
        "dosage": {
            "raw": "",
            "pattern": {"morning": 0, "noon": 0, "evening": 0, "bedtime": 0},
            "as_needed": True,
            "with_food": "any",
        },
        "prescriber": {"name": None, "specialty": None},
        "start_date": today().isoformat(),
        "end_date": None,
        "photo_url": None,
        "match": {"method": "exact_brand", "confidence": 0.9, "needs_review": False},
    }


@app.post("/v1/patients/{pid}/what-if")
def what_if(pid: str, body: dict[str, Any], x_patient_token: str | None = Header(None)) -> dict[str, Any]:
    patient = auth(pid, x_patient_token)
    invalid("what_if_request", body)
    if "query" in body and not body["query"].strip():
        raise HTTPException(422, "Scrieți numele medicamentului.")
    return run_what_if(pid, patient, body)


def run_what_if(pid: str, patient: dict[str, Any], body: dict[str, Any]) -> dict[str, Any]:
    """Răspunsul /what-if, comun aplicației (POST /what-if) și portalului („Dacă prescriu…”, QA5.2)."""
    meds = store().list_meds(pid)
    taken = {m["id"] for m in meds}
    if "med" in body:
        matched = copy.deepcopy(body["med"])
        if matched["id"] in taken:
            matched["id"] = "med_whatif"
    else:
        # A-6: același produs ca la „Pot să iau…?” din check-in (oral, o singură substanță), nu primul din căutare
        hit = can_i_take.pick_product(kb(), body["query"])
        if hit is None:
            return {"matched": None, "new_alerts": []}
        matched = med_from_kb(hit, "med_whatif")
    before = run_analysis(pid, patient, meds)["alerts"]
    after = run_analysis(pid, patient, [*meds, matched])["alerts"]
    return {"matched": matched, "new_alerts": new_alerts(before, after)}


# ---------------------------------------------------------------- ziua (B4)


@app.get("/v1/patients/{pid}/schedule")
def schedule(pid: str, day: Annotated[date | None, Query(alias="date")] = None, x_patient_token: str | None = Header(None)):
    patient = auth(pid, x_patient_token)
    return build_schedule(patient, store().list_meds(pid), day or today(), kb())


@app.get("/v1/patients/{pid}/doses")
def list_doses(
    pid: str, day: Annotated[date | None, Query(alias="date")] = None, x_patient_token: str | None = Header(None)
) -> list[dict[str, Any]]:
    """E2: dozele dintr-o zi (Europe/Bucharest), ca aplicația să vadă și bifele de pe pagina familiei."""
    auth(pid, x_patient_token)
    want = day or today()
    return [d for d in store().list_doses(pid) if _instant(d["scheduled_at"]).astimezone(TZ).date() == want]


@app.post("/v1/patients/{pid}/doses")
def record_dose(pid: str, body: dict[str, Any], x_patient_token: str | None = Header(None)) -> dict[str, Any]:
    auth(pid, x_patient_token)
    invalid("dose", body)
    if store().get_med(pid, body["med_id"]) is None:
        raise HTTPException(404, "Medicamentul nu există.")
    try:
        at = datetime.fromisoformat(body["scheduled_at"].replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(422, "scheduled_at nu e o dată validă.") from None
    if at.tzinfo is None:
        at = at.replace(tzinfo=TZ)
    return save_dose(pid, body["med_id"], at, body["scheduled_at"], body["status"])


def save_dose(pid: str, med_id: str, at: datetime, scheduled_at: str, status: str) -> dict[str, Any]:
    """POST /doses din aplicație și „Am luat” de pe pagina familiei (E2): aceeași cheie de idempotență."""
    if at - datetime.now(UTC) > DOSE_FUTURE_LIMIT:
        raise HTTPException(422, "Doza nu poate fi înregistrată cu mai mult de o zi înainte.")
    # cheia de idempotență nu depinde de fusul în care telefonul a scris ora
    key = at.astimezone(UTC).isoformat()
    dose = {"med_id": med_id, "scheduled_at": scheduled_at, "status": status, "recorded_at": now_iso()}
    store().record_dose(pid, key, dose)
    return dose


# ---------------------------------------------------------------- check-in și Noutăți (B5)


@app.post("/v1/patients/{pid}/checkins", status_code=201)
async def create_checkin(pid: str, request: Request, x_patient_token: str | None = Header(None)) -> dict[str, Any]:
    patient = auth(pid, x_patient_token)
    if not request.headers.get("content-type", "").startswith("application/json"):
        # Rezerva cu Whisper (B5, punctul 6) intră doar dacă recunoașterea vocală iOS pică testul de la pregătire.
        raise HTTPException(415, "Trimiteți textul transcris pe telefon (JSON: {text}).")
    try:
        body = await request.json()
    except ValueError:
        raise HTTPException(422, "Corpul nu e JSON valid.") from None
    text = body.get("text") if isinstance(body, dict) else None
    if not isinstance(text, str) or not text.strip() or len(text) > 2000:
        raise HTTPException(422, "Lipsește textul (cel mult 2000 de caractere).")
    text = text.strip()
    meds = store().list_meds(pid)
    u = understand(text, meds, kb())
    alerts = run_analysis(pid, patient, meds)["alerts"]
    correlations, escalate = correlate(make_ctx(patient, meds, today(), kb()), alerts, u.symptoms)
    x1 = None
    if u.intent == "can_i_take" and u.drug_query and u.drug_query["source"] == "catalog":
        x1 = can_i_take.answer(
            u.drug_query,
            meds,
            kb(),
            lambda regimen: run_analysis(pid, patient, regimen)["alerts"],
            today().isoformat(),
            patient.get("caregiver_name"),
        )
    checkin = {
        "id": f"ci_{secrets.token_hex(4)}",
        "at": datetime.now(TZ).replace(microsecond=0).isoformat(),
        "transcript": text,
        "intent": u.intent,
        "symptoms": [{"code": s.code, "label": s.label, "severity": s.severity} for s in u.symptoms],
        "correlations": correlations,
        "escalate": escalate,
        "reply_text": reply_text(u, correlations, escalate, patient.get("caregiver_name"), x1.text if x1 else None),
    }
    store().add_checkin(pid, checkin)
    if x1:
        # o întrebare nu e un simptom: escalate rămâne false, dar grav și „fără date” ajung în Noutăți
        event = can_i_take.feed_event(patient, checkin, x1) if x1.to_feed else None
        sent = event is not None and not _asked_today(pid, event)
        if sent:
            store().add_event(pid, event)
        LOG.info(
            "POT SĂ IAU %-11s → %-10s severitate %-8s · %s",
            x1.brand,
            x1.case,
            x1.severity or "–",
            "trimis în Noutăți" if sent else "deja în Noutăți azi" if x1.to_feed else "fără Noutăți",
        )
    labels = ", ".join(s.label for s in u.symptoms) or "fără simptome"
    via = "gemini" if u.used_llm else "sinonime"
    if escalate:
        red = {s.code for s in u.symptoms if s.red_flag}
        event = feed_event(patient, checkin, alerts, meds, red)
        store().add_event(pid, event)
        LOG.info("CHECK-IN  escaladat (%s): %s → %s", via, labels, event["body"])
    else:
        LOG.info("CHECK-IN  %s (%s), fără escaladare", labels, via)
    return checkin


def _asked_today(pid: str, event: dict[str, Any]) -> bool:
    """A-7: aceeași întrebare X1 (același titlu, deci același brand, și același răspuns) în aceeași zi e deja în Noutăți."""
    day = _instant(event["at"]).astimezone(TZ).date()
    return any(
        e["type"] == "checkin"
        and e["title"] == event["title"]
        and e["body"] == event["body"]
        and _instant(e["at"]).astimezone(TZ).date() == day
        for e in store().list_events(pid)
    )


@app.get("/v1/patients/{pid}/feed")
def feed(pid: str, since: str | None = None, x_patient_token: str | None = Header(None)) -> list[dict[str, Any]]:
    auth(pid, x_patient_token)
    events = store().list_events(pid)
    if since:
        try:
            cut = _instant(since)
        except ValueError:
            raise HTTPException(422, "since nu e o dată ISO 8601.") from None
        # inclusiv: `at` are rezoluție de o secundă, iar aplicația deduplică pe id (Q3-10)
        events = [e for e in events if _instant(e["at"]) >= cut]
    return list(reversed(events))


def _instant(raw: str) -> datetime:
    at = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    return at if at.tzinfo else at.replace(tzinfo=TZ)


# ---------------------------------------------------------------- portalul medicului de familie (B6)

SHARE_TTL = timedelta(hours=72)
SESSION_TTL = timedelta(hours=12)
SESSION_COOKIE = "pg_doctor"
# paginile au date medicale: nu se indexează, nu se cache-uiesc, nu trimit Referer mai departe (tokenul e în URL)
PAGE_HEADERS = {
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Robots-Tag": "noindex, nofollow",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; "
    "connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
}


@app.post("/v1/patients/{pid}/share", status_code=201)
def create_share(pid: str, request: Request, x_patient_token: str | None = Header(None)) -> dict[str, Any]:
    auth(pid, x_patient_token)
    token = secrets.token_urlsafe(16)
    expires = (datetime.now(UTC) + SHARE_TTL).replace(microsecond=0)
    expires_at = expires.isoformat().replace("+00:00", "Z")
    store().create_share(token, pid, expires_at)
    base = str(request.base_url).rstrip("/")
    return {"share_token": token, "url": f"{base}/share/{token}", "expires_at": expires_at}


def share_patient(token: str) -> str | None:
    entry = store().share(token)
    if entry is None or _instant(entry[1]) <= datetime.now(UTC):
        return None
    return entry[0]


def page(template: str, status: int = 200, **ctx: Any) -> HTMLResponse:
    return HTMLResponse(render(template, **ctx), status_code=status, headers=PAGE_HEADERS)


def expired_page(*, not_in_list: bool = False) -> HTMLResponse:
    return page("expired.html", status=404, not_in_list=not_in_list)


def current_doctor(request: Request) -> dict[str, Any] | None:
    token = request.cookies.get(SESSION_COOKIE)
    entry = store().session_doctor(token) if token else None
    if entry is None or _instant(entry[1]) <= datetime.now(UTC):
        return None
    return entry[0]


def doctor_patient(request: Request, pid: str) -> dict[str, Any] | None:
    """Medicul autentificat, doar dacă pacientul e în lista lui; altfel None (rutele răspund 404, fără să spună de ce)."""
    doctor = current_doctor(request)
    return doctor if doctor and store().doctor_has_patient(doctor["id"], pid) else None


def login_page(next_url: str, error: str | None = None, status: int = 200) -> HTMLResponse:
    return page("login.html", status=status, next=next_url, error=error, adding=next_url.startswith("/share/"))


def safe_next(raw: str | None) -> str:
    # doar căi locale, ca formularul de autentificare să nu poată trimite medicul pe alt site
    if raw and raw.startswith(("/portal", "/share/")) and "//" not in raw and "\\" not in raw:
        return raw
    return "/portal"


def patient_context(pid: str) -> dict[str, Any]:
    s = store()
    patient = s.get_patient(pid)
    meds = s.list_meds(pid)
    catalog = kb()
    return page_context(
        patient,
        meds,
        run_analysis(pid, patient, meds),
        s.list_checkins(pid),
        s.list_doses(pid),
        lambda day: build_schedule(patient, meds, day, catalog),
        today(),
        datetime.now(TZ),
        s.list_events(pid),
    )


@app.get("/share/{token}", response_class=HTMLResponse)
def share_link(token: str, request: Request) -> Response:
    pid = share_patient(token)
    if pid is None:
        return expired_page()
    doctor = current_doctor(request)
    if doctor is None:
        return login_page(f"/share/{token}")
    store().link_patient(doctor["id"], pid)
    return RedirectResponse(f"/portal/patients/{pid}", status_code=303)


@app.get("/share/{token}/graph", response_class=HTMLResponse)
def share_graph(token: str, embed: Annotated[int, Query(ge=0, le=1)] = 0) -> HTMLResponse:
    pid = share_patient(token)
    if pid is None:
        return expired_page()
    patient = store().get_patient(pid)
    graph = run_analysis(pid, patient, store().list_meds(pid))["graph"]
    return page("graph.html", patient=patient, graph=graph, embed=bool(embed), back=None)


@app.get("/portal", response_class=HTMLResponse)
def portal(request: Request, eroare: int = 0, next: str | None = None) -> HTMLResponse:
    doctor = current_doctor(request)
    if doctor is None:
        # QA-15: după un cod greșit, POST /portal/login trimite aici, cu mesajul și ținta în query
        return login_page(safe_next(next), "Codul de acces nu e corect." if eroare else None)
    s = store()
    # cursorul se ia înaintea datelor: un eveniment scris între timp ajunge oricum la pagină (QA5.1)
    live = f"/portal/events?after={s.last_event_cursor()}"
    cards = []
    for pid in s.doctor_patient_ids(doctor["id"]):
        patient = s.get_patient(pid)
        meds = s.list_meds(pid)
        checkins = s.list_checkins(pid)
        cards.append(patient_card(patient, meds, run_analysis(pid, patient, meds), checkins, today()))
    cards.sort(key=lambda c: c["sort"])
    return page("portal.html", doctor=doctor, cards=cards, live=live, **portal_summary(cards, today()))


@app.post("/portal/login", response_class=HTMLResponse)
def portal_login(code: Annotated[str, Form(max_length=200)] = "", next: Annotated[str, Form()] = "/portal") -> Response:
    target = safe_next(next)
    doctor = store().doctor_by_code(code) if code.strip() else None
    if doctor is None:
        # QA-15: Post/Redirect/Get, ca refresh-ul paginii cu eroarea să nu retrimită formularul
        return RedirectResponse(f"/portal?{urlencode({'eroare': 1, 'next': target})}", status_code=303)
    expires = (datetime.now(UTC) + SESSION_TTL).replace(microsecond=0)
    token = store().create_session(doctor["id"], expires.isoformat().replace("+00:00", "Z"))
    response = RedirectResponse(target, status_code=303)
    response.set_cookie(SESSION_COOKIE, token, max_age=int(SESSION_TTL.total_seconds()), httponly=True, samesite="lax", path="/")
    return response


@app.post("/portal/logout")
def portal_logout(request: Request) -> Response:
    token = request.cookies.get(SESSION_COOKIE)
    if token:
        store().delete_session(token)
    response = RedirectResponse("/portal", status_code=303)
    response.delete_cookie(SESSION_COOKIE, path="/")
    return response


@app.get("/portal/patients/{pid}", response_class=HTMLResponse)
def portal_patient(pid: str, request: Request) -> HTMLResponse:
    if doctor_patient(request, pid) is None:
        return expired_page(not_in_list=True) if current_doctor(request) else login_page(f"/portal/patients/{pid}")
    live = f"/portal/events?{urlencode({'patient': pid, 'after': store().last_event_cursor()})}"
    return page("page.html", base=f"/portal/patients/{pid}", live=live, **patient_context(pid))


@app.get("/portal/patients/{pid}/print", response_class=HTMLResponse)
def portal_print(pid: str, request: Request, trimisa: int = 0) -> HTMLResponse:
    if doctor_patient(request, pid) is None:
        return expired_page(not_in_list=True) if current_doctor(request) else login_page(f"/portal/patients/{pid}/print")
    sheets = store().list_sheets(pid)
    last_sent = sent_when(sheets[0]["sent_at"], today()) if sheets else None
    return page("print.html", base=f"/portal/patients/{pid}", sent=bool(trimisa), last_sent=last_sent, **patient_context(pid))


@app.post("/portal/patients/{pid}/send-sheet")
def portal_send_sheet(pid: str, request: Request, note: Annotated[str, Form(max_length=1000)] = "") -> Response:
    """Trimite familiei o copie fixă a fișei de consultație: pagina familiei („Fișa de la medic”) și Noutăți în
    aplicație. Rută internă a portalului (formular, Post/Redirect/Get), nu face parte din API-ul aplicației."""
    doctor = doctor_patient(request, pid)
    if doctor is None:
        return expired_page(not_in_list=True) if current_doctor(request) else login_page(f"/portal/patients/{pid}/print")
    at = datetime.now(TZ).replace(microsecond=0).isoformat()
    sheet = sheet_snapshot(patient_context(pid), doctor["name"], note.strip(), at, secrets.token_hex(4))
    _, added = store().send_sheet(pid, sheet, sheet_event(sheet))
    LOG.info("FIȘĂ      %s, trimisă familiei%s", pid, "" if added else " (aceeași ca ultima, nimic nou)")
    return RedirectResponse(f"/portal/patients/{pid}/print?trimisa=1#trimite", status_code=303)


@app.get("/portal/patients/{pid}/graph", response_class=HTMLResponse)
def portal_graph(pid: str, request: Request) -> HTMLResponse:
    if doctor_patient(request, pid) is None:
        return expired_page(not_in_list=True) if current_doctor(request) else login_page(f"/portal/patients/{pid}/graph")
    patient = store().get_patient(pid)
    graph = run_analysis(pid, patient, store().list_meds(pid))["graph"]
    return page("graph.html", patient=patient, graph=graph, embed=False, back=f"/portal/patients/{pid}")


class ReviewBody(BaseModel):
    model_config = {"extra": "forbid"}
    decision: Literal["keep", "change_at_visit", "refer_specialist"]
    note: str = Field(default="", max_length=1000)


@app.post("/portal/patients/{pid}/alerts/{alert_id}/review")
def review_alert(pid: str, alert_id: str, body: ReviewBody, request: Request) -> dict[str, Any]:
    if current_doctor(request) is None:
        raise HTTPException(401, "Autentificați-vă în portal.")
    if doctor_patient(request, pid) is None:
        raise HTTPException(404, "Pacientul nu e în lista dumneavoastră.")
    patient = store().get_patient(pid)
    alerts = run_analysis(pid, patient, store().list_meds(pid))["alerts"]
    alert = next((a for a in alerts if a["id"] == alert_id), None)
    if alert is None:
        raise HTTPException(404, "Alerta nu există.")
    # ora locală, ca în check-in-uri: Noutățile se ordonează după acest câmp
    at = datetime.now(TZ).replace(microsecond=0).isoformat()
    note = body.note.strip()
    prev = alert.get("resolution") if alert.get("status") == "reviewed_by_doctor" else None
    changed = prev is not None and (prev.get("decision") != body.decision or (prev.get("note") or "") != note)
    resolution = {"by": "doctor", "decision": body.decision, "note": note, "at": at}
    event = review_event(alert, body.decision, note, at, secrets.token_hex(4), changed=changed)
    resolution, _ = store().review_alert(pid, alert_id, resolution, event)  # QA-07: aceeași decizie = un singur eveniment
    return {**alert, "status": "reviewed_by_doctor", "resolution": resolution}


@app.post("/portal/patients/{pid}/what-if", response_class=HTMLResponse)
def portal_what_if(pid: str, request: Request, query: Annotated[str, Form(max_length=200)] = "") -> HTMLResponse:
    """„Dacă prescriu…” pe fișă (QA5.2): același what-if ca în aplicație, întors ca fragment HTML cu cardurile fișei.
    Rută internă a portalului, nu face parte din API-ul aplicației."""
    if current_doctor(request) is None:
        raise HTTPException(401, "Autentificați-vă în portal.")
    if doctor_patient(request, pid) is None:
        raise HTTPException(404, "Pacientul nu e în lista dumneavoastră.")
    query = query.strip()
    if not query:
        return page("whatif.html", state="empty")
    patient = store().get_patient(pid)
    result = run_what_if(pid, patient, {"query": query})
    unknown = result["matched"] is None
    if unknown:
        # necunoscut în catalog: motorul îl vede ca pe un medicament fără substanțe și dă alerta lui `unverified`
        stub = med_from_kb({"brand": query, "strength_text": None, "form": None, "substances": []}, "med_whatif")
        result = run_what_if(pid, patient, {"med": stub})
    return page("whatif.html", **whatif_context(result, store().list_meds(pid), today(), unknown=unknown))


# ---------------------------------------------------------------- portalul în timp real (QA5.1)

LIVE_TICK = 0.5  # cât de des se uită fluxul în feed_events (s)
LIVE_PING = 15.0  # un comentariu gol din când în când, ca nimic de pe drum să nu închidă conexiunea
LIVE_LIFETIME = 60.0  # apoi fluxul se închide, iar EventSource se reconectează singur, cu Last-Event-ID


def sse(name: str, cursor: int, data: dict[str, Any]) -> str:
    return f"event: {name}\nid: {cursor}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


async def live_stream(request: Request, doctor_id: str, patient: str | None, cursor: int):
    """Evenimentele noi din feed_events pentru pacienții medicului (sau doar pentru fișa deschisă). Pagina nu primește
    conținutul, doar semnalul: își cere singură fragmentele, prin aceeași rută care o randează."""
    s = store()
    loop = asyncio.get_running_loop()
    began = pinged = loop.time()
    # fără `data`, mesajul nu ajunge la pagină, dar fixează Last-Event-ID pentru reconectare
    yield f"id: {cursor}\nretry: 3000\n\n"
    while loop.time() - began < LIVE_LIFETIME:
        if await request.is_disconnected() or current_doctor(request) is None:
            return
        head = s.last_event_cursor()
        if head < cursor:
            # /demo/reset a șters evenimentele, iar rowid-urile o iau de la capăt: pagina se reîmprospătează oricum
            cursor = head
            yield sse("reset", cursor, {})
        pids = [patient] if patient else s.doctor_patient_ids(doctor_id)
        for rowid, pid, event in s.events_after(cursor, pids):
            if rowid > head:
                break
            yield sse("feed", rowid, {"patient_id": pid, "type": event["type"], "alert_id": event.get("alert_id")})
        cursor = head
        if loop.time() - pinged >= LIVE_PING:
            pinged = loop.time()
            yield ": ping\n\n"
        await asyncio.sleep(LIVE_TICK)


@app.get("/portal/events")
async def portal_events(
    request: Request,
    after: Annotated[int | None, Query(ge=0)] = None,
    patient: str | None = None,
    last_event_id: Annotated[str | None, Header()] = None,
) -> StreamingResponse:
    """Server-Sent Events pentru lista și fișa din portal; rută internă a portalului, nu face parte din API-ul aplicației."""
    doctor = current_doctor(request)
    if doctor is None:
        raise HTTPException(401, "Autentificați-vă în portal.")
    if patient is not None and not store().doctor_has_patient(doctor["id"], patient):
        raise HTTPException(404, "Pacientul nu e în lista dumneavoastră.")
    if last_event_id and last_event_id.isdecimal():
        cursor = int(last_event_id)
    else:
        cursor = after if after is not None else store().last_event_cursor()
    headers = {"Cache-Control": "no-store", "X-Accel-Buffering": "no", "X-Content-Type-Options": "nosniff"}
    return StreamingResponse(live_stream(request, doctor["id"], patient, cursor), media_type="text/event-stream", headers=headers)


# ---------------------------------------------------------------- pagina familiei pe web (E2)

HOME_LINK_TTL = timedelta(minutes=10)
HOME_SESSION_TTL = timedelta(days=30)
HOME_COOKIE = "pg_home"
HOME_MAX_PATIENTS = 6
HOME_TABS = (
    ("today", "/acasa", "Azi"),
    ("meds", "/acasa/medicamente", "Medicamentele mele"),
    ("check", "/acasa/verificat", "De verificat"),
    ("week", "/acasa/saptamana", "Calendar"),
    ("hours", "/acasa/ore", "Orele zilei"),
)


@app.post("/v1/patients/{pid}/web-link", status_code=201)
def create_web_link(pid: str, request: Request, x_patient_token: str | None = Header(None)) -> dict[str, Any]:
    """Linkul de intrare în pagina familiei: cod de unică folosință, valabil 10 minute (arătat ca QR în aplicație)."""
    auth(pid, x_patient_token)
    expires = (datetime.now(UTC) + HOME_LINK_TTL).replace(microsecond=0)
    expires_at = expires.isoformat().replace("+00:00", "Z")
    code = store().create_home_link(pid, expires_at)
    base = lan_base_url(str(request.base_url)).rstrip("/")
    return {"url": f"{base}/acasa/intra/{code}", "expires_at": expires_at}


HOME_CURRENT = "pg_home_pid"  # E6: pacientul ales, când browserul ține mai mulți


def home_tokens(request: Request) -> list[str]:
    """Sesiunile din cookie (E6: una pentru fiecare pacient deschis în acest browser), separate prin punct."""
    raw = request.cookies.get(HOME_COOKIE) or ""
    return [t for t in raw.split(".") if t][:HOME_MAX_PATIENTS]


def home_patients(request: Request) -> list[tuple[str, dict[str, Any]]]:
    """(token, pacient) pentru sesiunile valabile, în ordinea intrării; un pacient apare o singură dată."""
    out, seen = [], set()
    for token in home_tokens(request):
        entry = store().home_session(token)
        if entry is None or _instant(entry[1]) <= datetime.now(UTC) or entry[0] in seen:
            continue
        patient = store().get_patient(entry[0])
        if patient is not None:
            seen.add(entry[0])
            out.append((token, patient))
    return out


def home_patient(request: Request) -> dict[str, Any] | None:
    patients = home_patients(request)
    if not patients:
        return None
    wanted = request.cookies.get(HOME_CURRENT)
    return next((p for _, p in patients if p["id"] == wanted), patients[0][1])


def home_page(template: str, patient: dict[str, Any], tab: str, request: Request | None = None, **ctx: Any) -> HTMLResponse:
    others = [p for _, p in home_patients(request)] if request is not None else [patient]
    return page(template, patient=patient, tab=tab, tabs=HOME_TABS, patients=others, **ctx)


def set_home_cookies(response: Response, tokens: list[str], current: str | None) -> None:
    age = int(HOME_SESSION_TTL.total_seconds())
    if tokens:
        response.set_cookie(HOME_COOKIE, ".".join(tokens), max_age=age, httponly=True, samesite="lax", path="/acasa")
    else:
        response.delete_cookie(HOME_COOKIE, path="/acasa")
    if current:
        response.set_cookie(HOME_CURRENT, current, max_age=age, httponly=True, samesite="lax", path="/acasa")
    else:
        response.delete_cookie(HOME_CURRENT, path="/acasa")


def home_enter_page(status: int = 200, *, used: bool = False) -> HTMLResponse:
    return page("family_enter.html", status=status, used=used)


@app.get("/acasa/intra/{code}", response_class=HTMLResponse)
def home_enter(code: str, request: Request) -> Response:
    entry = store().use_home_link(code)
    if entry is None or _instant(entry[1]) <= datetime.now(UTC):
        return home_enter_page(404, used=True)
    pid = entry[0]
    expires = (datetime.now(UTC) + HOME_SESSION_TTL).replace(microsecond=0)
    token = store().create_home_session(pid, expires.isoformat().replace("+00:00", "Z"))
    # E6: pacienții deschiși deja rămân; sesiunea veche a aceluiași pacient e înlocuită de cea nouă
    kept = [t for t, p in home_patients(request) if p["id"] != pid]
    response = RedirectResponse("/acasa", status_code=303)
    set_home_cookies(response, [*kept, token][-HOME_MAX_PATIENTS:], pid)
    return response


@app.get("/acasa/demo")
def home_demo(request: Request) -> Response:
    """Doar cu DEMO_MODE=1: intrarea directă în pagina familiei pentru pacientul demo (linkul din `make demo`)."""
    if not demo_mode() or store().get_patient(DEMO_ID) is None:
        return home_enter_page(404, used=True)
    code = store().create_home_link(DEMO_ID, (datetime.now(UTC) + HOME_LINK_TTL).replace(microsecond=0).isoformat())
    return home_enter(code, request)


@app.post("/acasa/pacient")
def home_switch(request: Request, pid: Annotated[str, Form(max_length=64)]) -> Response:
    """E6: alt pacient din același browser (Maria și Ion); doar dintre cei cu sesiune valabilă."""
    patients = home_patients(request)
    response = RedirectResponse("/acasa", status_code=303)
    if any(p["id"] == pid for _, p in patients):
        set_home_cookies(response, [t for t, _ in patients], pid)
    return response


@app.post("/acasa/iesire")
def home_logout(request: Request) -> Response:
    """Iese doar pacientul de pe ecran; ceilalți pacienți deschiși în acest browser rămân (E6)."""
    patients = home_patients(request)
    current = home_patient(request)
    kept = []
    for token, patient in patients:
        if current is not None and patient["id"] == current["id"]:
            store().delete_home_session(token)
        else:
            kept.append((token, patient))
    response = RedirectResponse("/acasa", status_code=303)
    set_home_cookies(response, [t for t, _ in kept], kept[0][1]["id"] if kept else None)
    return response


@app.get("/acasa", response_class=HTMLResponse)
def home_today(request: Request) -> HTMLResponse:
    patient = home_patient(request)
    if patient is None:
        return home_enter_page()
    pid = patient["id"]
    meds = store().list_meds(pid)
    sched = build_schedule(patient, meds, today(), kb())
    return home_page(
        "family_today.html",
        patient,
        "today",
        request,
        sheet_banner=sheet_banner(store().list_sheets(pid), today()),
        **today_context(sched, meds, store().list_doses(pid), datetime.now(TZ)),
    )


@app.get("/acasa/fisa", response_class=HTMLResponse)
def home_sheet(request: Request, sheet_id: Annotated[str | None, Query(alias="id", max_length=64)] = None) -> HTMLResponse:
    """Fișa trimisă de medicul de familie din portal (implicit cea mai nouă; `id` pentru una mai veche)."""
    patient = home_patient(request)
    if patient is None:
        return home_enter_page()
    ctx = sheet_context(store().list_sheets(patient["id"]), sheet_id, today())
    return home_page("family_sheet.html", patient, "sheet", request, **(ctx or {"sheet": None}))


@app.post("/acasa/doze")
def home_dose(
    request: Request,
    moment: Annotated[str, Form(pattern=r"^\d{2}:\d{2}$")],
    status: Annotated[Literal["taken", "skipped", "pending"], Form()] = "taken",
) -> Response:
    """„Am luat” / „Am sărit” / „Anulează” pentru tot momentul, ca în modul senior; Post/Redirect/Get."""
    patient = home_patient(request)
    if patient is None:
        return RedirectResponse("/acasa", status_code=303)
    pid = patient["id"]
    meds = store().list_meds(pid)
    day = today()
    sched = build_schedule(patient, meds, day, kb())
    found = next((m for m in sched["moments"] if m["time"] == moment), None)
    if found is None:
        raise HTTPException(404, "Momentul nu mai e în programul de azi. Reîncărcați pagina.")
    at = dose_key(day, moment)
    scheduled_at = at.isoformat().replace("+00:00", "Z")
    for d in found["doses"]:
        save_dose(pid, d["med_id"], at, scheduled_at, status)
    LOG.info(
        "DOZE      %s de pe web: %s (%d doze)",
        {"taken": "Am luat", "skipped": "Am sărit", "pending": "anulat"}[status],
        moment,
        len(found["doses"]),
    )
    return RedirectResponse(f"/acasa#m-{moment.replace(':', '')}", status_code=303)


@app.get("/acasa/medicamente", response_class=HTMLResponse)
def home_meds(request: Request) -> HTMLResponse:
    patient = home_patient(request)
    if patient is None:
        return home_enter_page()
    return home_page("family_meds.html", patient, "meds", request, **meds_context(store().list_meds(patient["id"]), today()))


@app.get("/acasa/verificat", response_class=HTMLResponse)
def home_check(request: Request) -> HTMLResponse:
    patient = home_patient(request)
    if patient is None:
        return home_enter_page()
    pid = patient["id"]
    meds = store().list_meds(pid)
    return home_page(
        "family_check.html", patient, "check", request, **check_context(run_analysis(pid, patient, meds), meds, today())
    )


@app.get("/acasa/saptamana", response_class=HTMLResponse)
def home_week(request: Request, de: date | None = None, cutiuta: int = 0) -> HTMLResponse:
    """E3: săptămâna ca o cutiuță de medicamente (luni–duminică × momentele zilei); „Pregătesc cutiuța” cu cutiuta=1."""
    patient = home_patient(request)
    if patient is None:
        return home_enter_page()
    pid = patient["id"]
    meds = store().list_meds(pid)
    catalog = kb()
    start = week_start(de or today())
    schedules = [build_schedule(patient, meds, start + timedelta(days=i), catalog) for i in range(7)]
    saved = store().pillbox(pid, start.isoformat(), (start + timedelta(days=6)).isoformat())
    ctx = week_context(start, schedules, meds, saved, today())
    for day, label in ctx["stale"]:
        store().set_pillbox(pid, day, label, None)  # conținutul s-a schimbat după bifă: se verifică din nou
    return home_page("family_week.html", patient, "week", request, filling=bool(cutiuta), **ctx)


@app.post("/acasa/cutiuta")
def home_pillbox(
    request: Request,
    day: Annotated[date, Form()],
    label: Annotated[str, Form(max_length=80)],
    prepared: Annotated[int, Form(ge=0, le=1)] = 1,
) -> Response:
    """Bifează / debifează un compartiment, cu semnătura conținutului de acum (programul acelei zile)."""
    patient = home_patient(request)
    if patient is None:
        return RedirectResponse("/acasa", status_code=303)
    pid = patient["id"]
    sched = build_schedule(patient, store().list_meds(pid), day, kb())
    moment = next((m for m in sched["moments"] if m["label"] == label), None)
    if moment is None:
        raise HTTPException(404, "Momentul nu mai e în programul acelei zile. Reîncărcați pagina.")
    store().set_pillbox(pid, day.isoformat(), label, cell_signature(moment) if prepared else None, now_iso())
    start = week_start(day)
    return RedirectResponse(f"/acasa/saptamana?{urlencode({'de': start.isoformat(), 'cutiuta': 1})}", status_code=303)


@app.get("/acasa/ore", response_class=HTMLResponse)
def home_hours(request: Request, salvat: int = 0, eroare: str | None = None) -> HTMLResponse:
    patient = home_patient(request)
    if patient is None:
        return home_enter_page()
    return home_page("family_hours.html", patient, "hours", request, saved=bool(salvat), error=eroare, **hours_context(patient))


@app.post("/acasa/ore")
def home_hours_save(
    request: Request,
    wake: Annotated[str, Form(pattern=r"^\d{2}:\d{2}$")],
    breakfast: Annotated[str, Form(pattern=r"^\d{2}:\d{2}$")],
    lunch: Annotated[str, Form(pattern=r"^\d{2}:\d{2}$")],
    dinner: Annotated[str, Form(pattern=r"^\d{2}:\d{2}$")],
    bed: Annotated[str, Form(pattern=r"^\d{2}:\d{2}$")],
) -> Response:
    """E1 pe web: aceeași funcție ca PATCH /patients (ordinea validată, dozele de azi mutate)."""
    patient = home_patient(request)
    if patient is None:
        return RedirectResponse("/acasa", status_code=303)
    anchors = {"wake": wake, "breakfast": breakfast, "lunch": lunch, "dinner": dinner, "bed": bed}
    try:
        save_patient(patient["id"], patient, {**patient, "anchors": anchors})
    except HTTPException as exc:
        return RedirectResponse(f"/acasa/ore?{urlencode({'eroare': exc.detail})}", status_code=303)
    return RedirectResponse("/acasa/ore?salvat=1", status_code=303)


HOME_TICK = 1.0


async def home_stream(request: Request, pid: str):
    """Semnalul „s-a schimbat ceva” pentru pagina familiei: amprenta pacientului (doze, medicamente, alerte, ore),
    comparată la fiecare secundă. Pagina își cere singură conținutul nou, ca portalul (QA5.1)."""
    s = store()
    loop = asyncio.get_running_loop()
    began = pinged = loop.time()
    last = s.patient_fingerprint(pid)
    yield "retry: 3000\n\n"
    while loop.time() - began < LIVE_LIFETIME:
        if await request.is_disconnected() or home_patient(request) is None:
            return
        current = s.patient_fingerprint(pid)
        if current != last:
            last = current
            yield "event: changed\ndata: {}\n\n"
        if loop.time() - pinged >= LIVE_PING:
            pinged = loop.time()
            yield ": ping\n\n"
        await asyncio.sleep(HOME_TICK)


@app.get("/acasa/events")
async def home_events(request: Request) -> StreamingResponse:
    """Server-Sent Events pentru pagina familiei; rută internă, nu face parte din API-ul aplicației."""
    patient = home_patient(request)
    if patient is None:
        raise HTTPException(401, "Deschideți linkul din aplicație.")
    headers = {"Cache-Control": "no-store", "X-Accel-Buffering": "no", "X-Content-Type-Options": "nosniff"}
    return StreamingResponse(home_stream(request, patient["id"]), media_type="text/event-stream", headers=headers)


# ---------------------------------------------------------------- kb


@app.get("/v1/kb/search")
def kb_search(q: str, x_patient_token: str | None = Header(None)) -> dict[str, Any]:
    if not x_patient_token or store().patient_id_for_token(x_patient_token) is None:
        raise HTTPException(401, "Lipsește sau e greșit X-Patient-Token.")
    if len(q.strip()) < 2:
        raise HTTPException(422, "Căutarea are nevoie de cel puțin 2 caractere.")
    return {
        "results": [
            {
                **hit,
                "brand": display_brand(hit["brand"], brand_norm),
                "strength_text": display_strength(hit["strength_text"]),
                "form": display_form(hit["form"]),
            }
            for hit, brand_norm in kb().search_with_keys(q)
        ]
    }


# ---------------------------------------------------------------- demo


@app.post("/demo/reset")
def demo_reset(live_scan: Annotated[int, Query(ge=0, le=1)] = 0) -> dict[str, Any]:
    if not demo_mode():
        raise HTTPException(404, "Ruta există doar cu DEMO_MODE=1.")
    reset_demo(live_scan=bool(live_scan))
    store().clear_gtin_cache()
    LOG.info("DEMO      pacientul demo recreat (%d medicamente)", len(store().list_meds(DEMO_ID)))
    return {"id": DEMO_ID, "patient_token": DEMO_TOKEN, "patient": store().get_patient(DEMO_ID)}


@app.post("/demo/missed-dose")
def demo_missed_dose() -> dict[str, Any]:
    if not demo_mode():
        raise HTTPException(404, "Ruta există doar cu DEMO_MODE=1.")
    patient = store().get_patient(DEMO_ID)
    if patient is None:
        raise HTTPException(404, "Pacientul demo nu există; apelați întâi /demo/reset.")
    meds = store().list_meds(DEMO_ID)
    try:
        return simulate_missed_dose(
            store(), DEMO_ID, patient, meds, build_schedule(patient, meds, today(), kb()), datetime.now(TZ)
        )
    except LookupError as exc:
        raise HTTPException(409, str(exc)) from None


@app.exception_handler(HTTPException)
async def http_error(_: Request, exc: HTTPException) -> JSONResponse:
    return JSONResponse({"detail": exc.detail}, status_code=exc.status_code)


@app.exception_handler(RequestValidationError)
async def request_invalid(request: Request, exc: RequestValidationError) -> JSONResponse:
    LOG.warning("422       %s %s: %s", request.method, request.url.path, exc.errors()[:10])
    return JSONResponse({"detail": request_message(exc.errors())}, status_code=422)


@app.exception_handler(KbMissing)
async def kb_missing(_: Request, exc: KbMissing) -> JSONResponse:
    return JSONResponse({"detail": str(exc)}, status_code=503)
