"""A-3: erorile de validare ca un singur mesaj în română (`Error.detail` din openapi.yaml), primul câmp greșit.

Lista completă rămâne în log; aplicația și portalul afișează doar `detail`.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Sequence
from typing import Any

from jsonschema.exceptions import ValidationError as SchemaError

# tipurile de eroare pydantic (FastAPI) → partea a doua a mesajului
PYDANTIC_KINDS = {
    "missing": "lipsește",
    "extra_forbidden": "nu e permis",
    "enum": "are o valoare nepermisă",
    "literal_error": "are o valoare nepermisă",
    "too_long": "are prea multe elemente",
    "too_short": "are prea puține elemente",
    "string_too_long": "e prea lung",
    "string_too_short": "e prea scurt",
    "string_pattern_mismatch": "nu are formatul așteptat",
}
RANGE = ("greater_than", "greater_than_equal", "less_than", "less_than_equal", "multiple_of")

# cuvintele cheie JSON Schema (contracts/) → partea a doua a mesajului
SCHEMA_KINDS = {
    "additionalProperties": "conține un câmp necunoscut",
    "enum": "are o valoare nepermisă",
    "const": "are o valoare nepermisă",
    "type": "are tipul greșit",
    "minimum": "e în afara intervalului permis",
    "maximum": "e în afara intervalului permis",
    "exclusiveMinimum": "e în afara intervalului permis",
    "exclusiveMaximum": "e în afara intervalului permis",
    "pattern": "nu are formatul așteptat",
    "format": "nu are formatul așteptat",
    "minLength": "e prea scurt",
    "maxLength": "e prea lung",
    "minItems": "are prea puține elemente",
    "maxItems": "are prea multe elemente",
}


def _field(path: Iterable[Any]) -> str | None:
    parts = [str(p) for p in path]
    return "/".join(parts) if parts else None


# E0: căile din schemă pe care le poate atinge familia, cu numele din aplicație; restul rămân «cale/câmp»
FIELD_LABELS = {
    "name": "numele",
    "birth_year": "anul nașterii",
    "caregiver_name": "numele aparținătorului",
    "anchors": "orele zilei",
    "product": "produsul",
    "product/brand": "numele de pe cutie",
    "product/strength_text": "concentrația",
    "product/form": "forma farmaceutică",
    "product/gtin": "codul de pe cutie (GTIN)",
    "product/pack_size": "numărul de comprimate din cutie",
    "product/expiry": "data expirării",
    "product/batch": "lotul",
    "substances": "substanțele active",
    "substances/dci": "DCI-ul substanței",
    "substances/inn": "numele internațional al substanței",
    "substances/atc": "codul ATC al substanței",
    "substances/strength_mg": "cantitatea de substanță (mg)",
    "dosage": "posologia",
    "dosage/raw": "textul de pe rețetă",
    "dosage/pattern": "schema de administrare",
    "dosage/pattern/morning": "doza de dimineață",
    "dosage/pattern/noon": "doza de la prânz",
    "dosage/pattern/evening": "doza de seară",
    "dosage/pattern/bedtime": "doza de la culcare",
    "dosage/as_needed": "„la nevoie”",
    "dosage/with_food": "legătura cu masa",
    "prescriber": "medicul care l-a prescris",
    "prescriber/name": "numele medicului",
    "prescriber/specialty": "specialitatea medicului",
    "start_date": "data de început",
    "end_date": "data de sfârșit",
    "photo_url": "poza cutiei",
    "match": "potrivirea în nomenclator",
}

PLURAL_LABELS = {"substanțele active", "orele zilei"}


def _label(field: str) -> str | None:
    # căile din liste (substances/0/atc) folosesc eticheta listei
    parts = [p for p in field.split("/") if not p.isdigit()]
    return FIELD_LABELS.get("/".join(parts))


def _sentence(field: str | None, kind: str) -> str:
    if not field:
        return f"Corpul cererii {kind}."
    label = _label(field)
    if label is None:
        return f"Câmpul «{field}» {kind}."
    if kind == "lipsește":
        return f"{'Lipsesc' if label in PLURAL_LABELS else 'Lipsește'} {label}."
    return f"Câmpul „{label}” {kind}."


def request_message(errors: Sequence[dict[str, Any]]) -> str:
    """Erorile din `RequestValidationError` (JSON stricat, câmp lipsă, enum greșit, parametri de query)."""
    if not errors:
        return "Cererea nu e validă."
    first = errors[0]
    kind = first.get("type", "")
    if kind == "json_invalid":
        return "Corpul cererii nu e JSON valid."
    loc = list(first.get("loc", ()))
    if loc and loc[0] in ("body", "query", "path", "header"):
        loc = loc[1:]
    field = _field(loc)
    if kind in PYDANTIC_KINDS:
        return _sentence(field, PYDANTIC_KINDS[kind])
    if kind in RANGE:
        return _sentence(field, "e în afara intervalului permis")
    if kind.endswith("_type") or kind.endswith("_parsing"):
        return _sentence(field, "are tipul greșit")
    return _sentence(field, "nu e valid")


def schema_message(errors: Sequence[SchemaError]) -> str:
    """Erorile JSON Schema din contracts/ (`invalid()` în main.py), sortate după cale."""
    if not errors:
        return "Corpul cererii nu respectă schema."
    first = errors[0]
    path = list(first.absolute_path)
    if first.validator == "required":
        missing = re.match(r"'([^']+)'", first.message)
        name = missing.group(1) if missing else "?"
        return _sentence(_field([*path, name]), "lipsește")
    return _sentence(_field(path), SCHEMA_KINDS.get(str(first.validator), "nu e valid"))
