"""E2 (docs/PLAN.md 14.6): datele paginii familiei pe web („Azi”, „Medicamentele mele”, „De verificat”).

Aceleași date ca aplicația, din aceleași funcții ca portalul (`med_name`, `plain_posology`, `alert_view`, textele din
`engine/texts_ro.py` prin titlurile alertelor); regulile din secțiunea 13 a planului se aplică și aici. Funcții pure;
rutele sunt în polygraph/api/main.py.
"""

from __future__ import annotations

import hashlib
from datetime import UTC, date, datetime, time, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from polygraph.engine.analyze import is_active
from polygraph.engine.texts_ro import ro_name
from polygraph.share.glossary import entry
from polygraph.share.view import (
    GRAVE,
    alert_view,
    med_name,
    plain_posology,
    plural,
    prescriber,
    relative_day,
    ro_date,
)

Json = dict[str, Any]
TZ = ZoneInfo("Europe/Bucharest")

# aceleași reguli ca SeniorDay din aplicație (app/PolyGraph/Senior/SeniorDay.swift)
GRACE_MINUTES = 120  # cât rămâne „acum” un moment neconfirmat după ora lui
EARLY_MINUTES = 30  # cu cât înainte apare „Am luat”
EMPTY_TODAY = "Nu aveți pastile în program."  # textul din 13.2, identic cu SeniorDay.dayEndTitle(.empty)
WITH_FOOD = {
    "empty_stomach": "pe stomacul gol",
    "before_meal": "înainte de masă",
    "with_meal": "la masă",
    "after_meal": "după masă",
}


def _minutes(clock: str) -> int:
    h, m = clock.split(":")
    return int(h) * 60 + int(m)


def _instant(raw: str) -> datetime:
    at = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    return at if at.tzinfo else at.replace(tzinfo=TZ)


def dose_key(day: date, clock: str) -> datetime:
    """Ora momentului, în UTC: aceeași cheie ca POST /doses (aplicația trimite ziua + ora în fusul telefonului)."""
    return datetime.combine(day, time.fromisoformat(clock), TZ).astimezone(UTC)


def quantity(qty: float, form: str | None) -> str:
    """„1 comprimat”, „½ comprimat”, „1 ½ comprimate”, „2 capsule”."""
    capsule = "caps" in (form or "").lower()
    one, many = ("capsulă", "capsule") if capsule else ("comprimat", "comprimate")
    whole = int(qty)
    half = qty - whole >= 0.25
    if whole == 0:
        return f"½ {one}"
    if whole == 1 and not half:
        return f"1 {one}"
    return f"{whole}{' ½' if half else ''} {many}"


def recorded_doses(doses: list[Json], day: date) -> dict[tuple[str, datetime], Json]:
    """(med_id, ora în UTC) → doza înregistrată, doar pentru `day` (ziua locală)."""
    out = {}
    for d in doses:
        try:
            at = _instant(d["scheduled_at"])
        except ValueError:
            continue
        if at.astimezone(TZ).date() == day:
            out[(d["med_id"], at.astimezone(UTC))] = d
    return out


def moment_status(statuses: list[str | None]) -> str:
    """Ca DoseLog.momentStatus: „taken” / „skipped” doar când toate dozele sunt confirmate."""
    if not statuses or not all(s in ("taken", "skipped") for s in statuses):
        return "open"
    return "taken" if "taken" in statuses else "skipped"


def today_context(schedule: Json, meds: list[Json], doses: list[Json], now: datetime) -> Json:
    """Tab-ul „Azi”: momentele zilei, momentul curent primul, cele trecute neconfirmate marcate."""
    day = date.fromisoformat(schedule["date"])
    by_id = {m["id"]: m for m in meds}
    recorded = recorded_doses(doses, day)
    local_now = now.astimezone(TZ)
    now_min = local_now.hour * 60 + local_now.minute if local_now.date() == day else (24 * 60 if local_now.date() > day else -1)
    moments = []
    for m in schedule["moments"]:
        at = dose_key(day, m["time"])
        items, statuses, taken_at = [], [], []
        for d in m["doses"]:
            med = by_id.get(d["med_id"], {})
            product = med.get("product") or {}
            rec = recorded.get((d["med_id"], at))
            status = rec["status"] if rec and rec["status"] != "pending" else None
            statuses.append(status)
            if status == "taken" and rec.get("recorded_at"):
                taken_at.append(rec["recorded_at"])
            items.append(
                {
                    "med_id": d["med_id"],
                    "name": med_name(med) if med else d["med_id"],
                    "photo_url": med.get("photo_url"),
                    "pill_photo_url": med.get("pill_photo_url"),
                    "quantity": quantity(d["qty"], product.get("form")),
                    "instruction": d.get("instruction") or "",
                }
            )
        status = moment_status(statuses)
        minutes = _minutes(m["time"])
        last = max(taken_at) if taken_at else None
        moments.append(
            {
                "time": m["time"],
                "label": m["label"],
                "doses": items,
                "status": status,
                "taken_at": _instant(last).astimezone(TZ).strftime("%H:%M") if last else None,
                "due": minutes <= now_min + EARLY_MINUTES,
                "missed": status == "open" and now_min - minutes > GRACE_MINUTES,
                "minutes": minutes,
            }
        )
    open_moments = [m for m in moments if m["status"] == "open"]
    current = next((m for m in open_moments if m["minutes"] <= now_min and now_min - m["minutes"] <= GRACE_MINUTES), None)
    current = current or next((m for m in open_moments if m["minutes"] > now_min), None)
    for m in moments:
        m["current"] = m is current
    ordered = ([current] if current else []) + [m for m in moments if m is not current]
    done = sum(1 for m in moments if m["status"] != "open")
    return {
        "day": schedule["date"],
        "moments": ordered,
        "empty": not moments,
        "empty_text": EMPTY_TODAY,
        "progress": f"{done} din {plural(len(moments), 'moment', 'momente')} confirmate" if moments else None,
        "all_done": bool(moments) and done == len(moments),
        "unsatisfied": schedule.get("unsatisfied") or [],
    }


def _expiry(raw: str | None, today: date) -> Json | None:
    if not raw:
        return None
    try:
        when = date.fromisoformat(raw[:10])
    except ValueError:
        return {"text": raw, "tone": None}
    days = (when - today).days
    tone = "expired" if days < 0 else "soon" if days <= 30 else None
    return {"text": ro_date(raw), "tone": tone, "label": "A expirat" if days < 0 else "Expiră"}


def meds_context(meds: list[Json], today: date) -> Json:
    """Tab-ul „Medicamentele mele”: după numele de pe cutie, cu posologia în cuvinte și explicațiile „i”."""
    rows = []
    for med in sorted((m for m in meds if is_active(m, today)), key=lambda m: med_name(m).casefold()):
        dosage = med.get("dosage") or {}
        raw = (dosage.get("raw") or "").strip()
        how = plain_posology(raw, as_needed=bool(dosage.get("as_needed")))
        food = WITH_FOOD.get(dosage.get("with_food") or "")
        subs = med.get("substances") or []
        strength = ((med.get("product") or {}).get("strength_text") or "").lower()
        rows.append(
            {
                "id": med["id"],
                "name": med_name(med),
                "photo_url": med.get("photo_url"),
                "pill_photo_url": med.get("pill_photo_url"),
                "how": how or "Posologie necompletată",
                "raw": raw if raw and raw.lower() != how.lower() else None,
                "food": food,
                "substances": ", ".join(ro_name(s.get("inn"), s.get("dci")) for s in subs) or None,
                "who": f"Prescris de {prescriber(med)}" if prescriber(med) else "Fără rețetă",
                "expiry": _expiry((med.get("product") or {}).get("expiry"), today),
                "unit": "mcg" if "mcg" in strength or "µg" in strength else "mg" if "mg" in strength else None,
                "as_needed": bool(dosage.get("as_needed")),
            }
        )
    glossary = [entry(k) for k in ("mg", "substance", "pattern", "as_needed", "food", "prescriber")]
    if any(r["unit"] == "mcg" for r in rows):
        glossary.insert(1, entry("mcg"))
    return {"meds": rows, "glossary": glossary}


def family_route(alert: Json) -> str:
    """Cui să-i spună familia, din `route_to` și `action` (fără să promită ce nu face aplicația)."""
    route = alert.get("route_to") or []
    if alert["kind"] == "food":
        return "Bine de știut acasă, la mese."
    if "doctor" in route:
        return "Spuneți-i medicului de familie; dacă i-ați arătat codul din aplicație, o vede și el în portal."
    if alert.get("action") == "replace_box":
        return "Cereți o cutie nouă la farmacie sau o rețetă nouă."
    return "De discutat cu medicul de familie la următoarea vizită."


def check_context(analysis: Json, meds: list[Json], today: date) -> Json:
    """Tab-ul „De verificat”: aceeași împărțire ca ecranul Alerte din aplicație (AlertSections.swift): gravele câte un
    card, moderatele strânse, apoi mâncarea și băutura, la urmă ACB; `minor` doar în portalul medicului."""
    names = {m["id"]: med_name(m) for m in meds}
    shown = [a for a in analysis["alerts"] if a["severity"] != "minor"]
    rank = {"critical": 0, "major": 1, "moderate": 2, "info": 3}
    shown.sort(key=lambda a: rank.get(a["severity"], 9))  # sortare stabilă: la aceeași severitate, ordinea serverului
    views = []
    for a in shown:
        v = alert_view(a, names, today)
        # pagina e a familiei: recomandarea din contract, nu varianta reformulată pentru medic
        v["recommendation"] = a["recommendation"]
        v["route_text"] = family_route(a)
        views.append(v)
    acb = [v for v in views if v["kind"] == "anticholinergic"]
    rest = [v for v in views if v["kind"] != "anticholinergic"]
    grave = [v for v in rest if v["kind"] != "food" and v["severity"] in GRAVE]
    moderate = [v for v in rest if v["kind"] != "food" and v["severity"] not in GRAVE]
    food = [v for v in rest if v["kind"] == "food"]
    return {
        "grave": grave,
        "moderate": moderate,
        "moderate_label": plural(len(moderate), "alertă", "alerte"),
        "food": food,
        "acb": acb,
        "acb_total": analysis.get("acb_total", 0),
        "empty": not views,
        "reviewed": sum(1 for v in views if v["reviewed"]),
    }


def hours_context(patient: Json) -> Json:
    a = patient["anchors"]
    return {
        "rows": [
            {"key": "wake", "label": "Trezirea", "value": a["wake"]},
            {"key": "breakfast", "label": "Micul dejun", "value": a["breakfast"]},
            {"key": "lunch", "label": "Prânzul", "value": a["lunch"]},
            {"key": "dinner", "label": "Cina", "value": a["dinner"]},
            {"key": "bed", "label": "Culcarea", "value": a["bed"]},
        ]
    }


def updated_text(now: datetime, today: date) -> str:
    return relative_day(now.isoformat(), today)


# ---------------------------------------------------------------- E3: calendarul săptămânal și cutiuța

WEEKDAY_SHORT = ("Luni", "Marți", "Miercuri", "Joi", "Vineri", "Sâmbătă", "Duminică")
MONTHS_SHORT = ("ian.", "feb.", "mar.", "apr.", "mai", "iun.", "iul.", "aug.", "sept.", "oct.", "nov.", "dec.")


def week_start(day: date) -> date:
    return day - timedelta(days=day.weekday())


def cell_signature(moment: Json) -> str:
    """Ce trebuie să fie în compartiment: ora și dozele. O bifă pusă pe alt conținut nu mai e valabilă."""
    doses = sorted((d["med_id"], float(d["qty"])) for d in moment["doses"])
    return hashlib.sha256(repr((moment["time"], doses)).encode()).hexdigest()[:16]


def week_context(
    start: date, schedules: list[Json], meds: list[Json], pillbox: dict[tuple[str, str], tuple[str, str]], today: date
) -> Json:
    """Grid-ul luni–duminică × momentele zilei. O celulă bifată pe un conținut care s-a schimbat (medicament nou,
    ore noi) e marcată „changed” și apelantul îi șterge bifa."""
    by_id = {m["id"]: m for m in meds}
    # rândurile: etichetele momentelor din săptămână, în ordinea orei la care apar prima dată
    first_time: dict[str, str] = {}
    for sched in schedules:
        for m in sched["moments"]:
            first_time[m["label"]] = min(first_time.get(m["label"], m["time"]), m["time"])
    labels = sorted(first_time, key=lambda lbl: (first_time[lbl], lbl))
    days, stale = [], []
    prev_ids: set[str] | None = None
    for offset, sched in enumerate(schedules):
        day = start + timedelta(days=offset)
        iso = day.isoformat()
        moments = {m["label"]: m for m in sched["moments"]}
        ids = {d["med_id"] for m in sched["moments"] for d in m["doses"]}
        cells = []
        for label in labels:
            m = moments.get(label)
            if m is None:
                cells.append({"label": label, "empty": True})
                continue
            sig = cell_signature(m)
            saved = pillbox.get((iso, label))
            prepared = saved is not None and saved[0] == sig
            changed = saved is not None and not prepared
            if changed:
                stale.append((iso, label))
            items = []
            for d in m["doses"]:
                med = by_id.get(d["med_id"], {})
                items.append(
                    {
                        "name": med_name(med) if med else d["med_id"],
                        "photo_url": med.get("photo_url"),
                        "pill_photo_url": med.get("pill_photo_url"),
                        "quantity": quantity(d["qty"], (med.get("product") or {}).get("form")),
                    }
                )
            cells.append(
                {
                    "label": label,
                    "time": m["time"],
                    "empty": False,
                    "count": sum(float(d["qty"]) for d in m["doses"]),
                    "count_text": quantity_total(m["doses"]),
                    "doses": items,
                    "prepared": prepared,
                    "changed": changed,
                    "id": f"c-{iso}-{labels.index(label)}",
                }
            )
        started = sorted(ids - prev_ids) if prev_ids is not None else []
        ended = sorted(prev_ids - ids) if prev_ids is not None else []
        prev_ids = ids
        days.append(
            {
                "iso": iso,
                "name": WEEKDAY_SHORT[day.weekday()],
                "date": f"{day.day} {MONTHS_SHORT[day.month - 1]}",
                "today": day == today,
                "cells": cells,
                "started": [med_name(by_id[i]) for i in started if i in by_id],
                "ended": [med_name(by_id[i]) for i in ended if i in by_id],
            }
        )
    filled = [c for d in days for c in d["cells"] if not c["empty"]]
    end = start + timedelta(days=6)
    return {
        "start": start.isoformat(),
        "prev": (start - timedelta(days=7)).isoformat(),
        "next": (start + timedelta(days=7)).isoformat(),
        "range": f"{start.day} {MONTHS_SHORT[start.month - 1]} – {end.day} {MONTHS_SHORT[end.month - 1]} {end.year}",
        "labels": labels,
        "days": days,
        "all_prepared": bool(filled) and all(c["prepared"] for c in filled),
        "prepared_count": sum(1 for c in filled if c["prepared"]),
        "cell_count": len(filled),
        "stale": stale,
    }


def quantity_total(doses: list[Json]) -> str:
    """„3 pastile”, „1 pastilă”, „2 ½ pastile” (pe celula din calendar)."""
    total = sum(float(d["qty"]) for d in doses)
    whole = int(total)
    half = total - whole >= 0.25
    if whole == 0:
        return "½ pastilă"
    if whole == 1 and not half:
        return "1 pastilă"
    return f"{whole}{' ½' if half else ''} pastile"
