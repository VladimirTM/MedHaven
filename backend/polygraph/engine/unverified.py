"""Medicamentele pe care motorul nu le poate verifica (QA-03): fără substanțe sau doar cu substanțe necunoscute în kb.

Fără alerta asta, un astfel de medicament nu apare în nicio verificare, iar fișa spune „nicio alertă”: lipsa unei
probleme ar arăta la fel ca lipsa datelor. Alerta e `unverified`, `moderate`, sursa PolyGraph.
"""

from __future__ import annotations

from polygraph.engine import texts_ro as T
from polygraph.engine.context import Ctx, brand, make_alert


def check(ctx: Ctx) -> list[dict]:
    known = {c.med_id for c in ctx.components if c.sub is not None}
    out = []
    for m in ctx.meds:
        if m["id"] in known:
            continue
        b = brand(m)
        names = [s.get("dci") or s.get("inn") for s in m.get("substances") or [] if s.get("dci") or s.get("inn")]
        out.append(
            make_alert(
                kind="unverified",
                severity="moderate",
                med_ids=[m["id"]],
                title=T.unverified_title(b),
                patient_text=T.unverified_patient_text(b),
                detail=T.unverified_detail(b, names),
                recommendation=T.UNVERIFIED_RECOMMENDATION,
                action="ask_doctor",
                source={"db": "app", "ref": "substanța activă lipsește din baza de date PolyGraph", "url": None},
            )
        )
    return out
