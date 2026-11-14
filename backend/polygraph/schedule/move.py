"""E1 (docs/PLAN.md 14.6): orele zilei schimbate după onboarding.

Dozele de azi deja înregistrate („Am luat”, „Am sărit”) se mută la noile ore: pentru fiecare doză, momentul vechi
se găsește în programul calculat cu orele vechi (med_id + ora), iar doza ia ora aceluiași moment din programul nou
(a câta apariție a medicamentului în zi). Dozele din alte zile nu se ating.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import UTC, date, datetime, time
from typing import Any
from zoneinfo import ZoneInfo

Json = dict[str, Any]
TZ = ZoneInfo("Europe/Bucharest")
ANCHOR_ORDER = ("wake", "breakfast", "lunch", "dinner", "bed")
ANCHOR_LABELS = {"wake": "trezirea", "breakfast": "micul dejun", "lunch": "prânzul", "dinner": "cina", "bed": "culcarea"}


def anchors_in_order(anchors: Json) -> bool:
    """trezire < mic dejun < prânz < cină < culcare (orele „HH:MM” se compară corect ca text)."""
    times = [anchors[k] for k in ANCHOR_ORDER]
    return all(a < b for a, b in zip(times, times[1:], strict=False))


def changed_anchors(old: Json, new: Json) -> list[str]:
    """„cina 19:00 → 20:00”, pentru log."""
    return [f"{ANCHOR_LABELS[k]} {old.get(k)} → {new.get(k)}" for k in ANCHOR_ORDER if old.get(k) != new.get(k)]


def occurrences(schedule: Json) -> dict[str, list[str]]:
    """med_id → orele la care apare în zi, în ordine."""
    out: dict[str, list[str]] = {}
    for moment in schedule["moments"]:
        for dose in moment["doses"]:
            out.setdefault(dose["med_id"], []).append(moment["time"])
    return out


def _instant(raw: str) -> datetime:
    at = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    return at if at.tzinfo else at.replace(tzinfo=TZ)


def dose_key(at: datetime) -> str:
    """Aceeași cheie ca POST /doses: ora în UTC, ISO."""
    return at.astimezone(UTC).isoformat()


def moved_doses(doses: list[Json], day: date, old: Json, new: Json) -> list[tuple[str, str, Json]]:
    """(med_id, cheia veche, doza mutată) pentru dozele din `day` al căror moment are altă oră în programul nou.
    O doză care nu se mai regăsește în programul vechi (ora scrisă de mână, medicament șters) rămâne pe loc."""
    before, after = occurrences(old), occurrences(new)
    moves = []
    for dose in doses:
        at = _instant(dose["scheduled_at"])
        local = at.astimezone(TZ)
        if local.date() != day:
            continue
        hhmm = local.strftime("%H:%M")
        times = before.get(dose["med_id"], [])
        if hhmm not in times:
            continue
        index = times.index(hhmm)
        targets = after.get(dose["med_id"], [])
        if index >= len(targets) or targets[index] == hhmm:
            continue
        moved_at = datetime.combine(day, time.fromisoformat(targets[index]), TZ)
        moves.append(
            (dose["med_id"], dose_key(at), {**dose, "scheduled_at": moved_at.astimezone(UTC).isoformat().replace("+00:00", "Z")})
        )
    return moves


def move_today(
    store: Any, pid: str, day: date, old_patient: Json, new_patient: Json, schedule_for: Callable[[Json, date], Json]
) -> int:
    """Calculează programul vechi și pe cel nou și mută dozele de azi, într-o tranzacție. Întoarce câte s-au mutat."""
    moves = moved_doses(store.list_doses(pid), day, schedule_for(old_patient, day), schedule_for(new_patient, day))
    store.update_patient_and_move_doses(
        pid, new_patient, [(mid, old, dose_key(_instant(d["scheduled_at"])), d) for mid, old, d in moves]
    )
    return len(moves)
