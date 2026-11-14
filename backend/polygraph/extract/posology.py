"""Interpretează numai instrucțiunile citite de pe rețetă."""

import re
from fractions import Fraction

from polygraph.kb import norm

SLOTS = ("morning", "noon", "evening", "bedtime")
MAX_UNITS = 10  # mai mult de atâtea comprimate la o priză e o citire greșită
# „1-0-1,7 zile”: OCR-ul lipește durata de ultima cifră; virgula urmată de „N zile” nu e zecimală (Q4-01)
DURATION_COMMA = re.compile(r"(?<=\d)\s*[,;]\s*(?=\d{1,3}\s*(?:de\s+)?zi(?:le)?\b)", re.IGNORECASE)
TIMES = (r"dimineata", r"la pranz|amiaza|la amiaza", r"seara", r"la culcare|inainte de culcare")
AMOUNT = r"(?:\d{1,3}\s*/\s*\d{1,3}|\d{1,3}(?:[.,]\d{1,3})?)"
PATTERN = re.compile(rf"(?<![\w/.,-])({AMOUNT})\s*[-–]\s*({AMOUNT})\s*[-–]\s*({AMOUNT})(?:\s*[-–]\s*({AMOUNT}))?(?![\w/-])")
DOSE = r"(?:cp|comprimate?|comprimat|capsul[ae]|caps|plic(?:uri)?|picaturi?|doze?)"
FOOD = {
    "empty_stomach": r"pe stomacul gol|pe nemancate",
    "before_meal": r"inainte de mas[ae]|inaintea meselor",
    "with_meal": r"in timpul meselor|in timpul mesei|cu mas[ae]|cu mancare",
    "after_meal": r"dupa mas[ae]|dupa mese|dupa ce mancati",
}


def parse_posology(raw: str | None) -> tuple[dict, bool]:
    text = norm(raw)
    food = next((key for key, regex in FOOD.items() if re.search(rf"\b(?:{regex})\b", text)), "any")
    as_needed = bool(re.search(r"\b(?:la nevoie|doar la nevoie)\b", text))
    dosage = {"raw": raw, "pattern": dict.fromkeys(SLOTS, 0), "as_needed": as_needed, "with_food": food}
    if not raw:
        return dosage, True

    prepared = raw.translate(str.maketrans({"½": "1/2", "¼": "1/4", "¾": "3/4"}))
    prepared = DURATION_COMMA.sub(", ", prepared)
    notation = PATTERN.search(prepared)
    amounts = {}
    if notation:
        amounts = dict(zip(SLOTS, notation.groups(), strict=True))
    else:
        # Păstrează separatorii fracțiilor și ai zecimalelor după normalizarea diacriticelor.
        prepared = re.sub(r"(?<=\d)[.,](?=\d)", " DECIMAL ", prepared)
        prepared = re.sub(r"(?<=\d)\s*/\s*(?=\d)", " FRACTION ", prepared)
        text = norm(prepared).replace(" decimal ", ".").replace(" fraction ", "/")
        for slot, time in zip(SLOTS, TIMES, strict=True):
            match = re.search(rf"(?<![\d/.])({AMOUNT})\s*(?:{DOSE}\b[. ]*)?(?:zi\s*)?\b(?:{time})\b", text)
            if not match:
                match = re.search(rf"\b(?:{time})\s+({AMOUNT})\s*{DOSE}\b", text)
            if match:
                amounts[slot] = match[1]
    try:
        values = {slot: float(Fraction(value.replace(" ", "").replace(",", "."))) for slot, value in amounts.items() if value}
    except (ValueError, ZeroDivisionError):
        return dosage, True
    if any(v > MAX_UNITS for v in values.values()):
        return dosage, True  # „12-0-0”: nu e o posologie, câmpul rămâne gol și e marcat „verificați”
    if any((v * 4) % 1 for v in values.values()):
        return dosage, True  # „1,7”: o priză e un număr întreg de sferturi de comprimat; altfel e o citire greșită
    dosage["pattern"].update(values)
    # Frecvența singură nu indică orele de administrare.
    return dosage, not amounts and not as_needed
