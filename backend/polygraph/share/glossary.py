"""E2: explicațiile scurte din butoanele „i” ale paginii familiei, într-un singur loc.

Regula T-B2-03: nicio explicație nu dă doze și nu spune „opriți”; cine are o întrebare despre tratament e trimis la
medicul de familie sau la farmacist.
"""

from __future__ import annotations

GLOSSARY: dict[str, tuple[str, str]] = {
    "mg": (
        "Ce înseamnă mg?",
        "Miligrame: cât din substanța activă e într-o pastilă. 1000 mg = 1 gram. "
        "Două cutii cu același nume pot avea concentrații diferite, de aceea contează și cifra de pe cutie.",
    ),
    "mcg": (
        "Ce înseamnă mcg?",
        "Micrograme: o miime de miligram (1000 mcg = 1 mg). Se folosește la medicamentele care se iau "
        "în cantități foarte mici, cum sunt cele pentru tiroidă.",
    ),
    "substance": (
        "Ce e substanța activă?",
        "Substanța care are efectul medicamentului. Numele de pe cutie e al firmei; aceeași substanță poate apărea "
        "sub mai multe nume (de exemplu, ibuprofenul e și în Nurofen, și în alte cutii). De aceea două cutii diferite "
        "pot fi, de fapt, același medicament.",
    ),
    "pattern": (
        "Ce înseamnă 1-0-1?",
        "Câte pastile se iau dimineața, la prânz și seara (uneori și la culcare). 1-0-1 înseamnă una dimineața și una seara; "
        "½ înseamnă jumătate de pastilă. PolyGraph scrie schema în cuvinte, dar pe cutie sau pe rețetă o găsiți așa.",
    ),
    "as_needed": (
        "Ce înseamnă „la nevoie”?",
        "Medicamentul nu are oră fixă: se ia doar când apare problema pentru care a fost recomandat (de exemplu, o durere). "
        "Câte se pot lua într-o zi scrie pe rețetă sau în prospect; dacă nu sunteți sigur, întrebați farmacistul.",
    ),
    "food": (
        "Cu mâncare sau pe stomacul gol?",
        "Unele medicamente se absorb mai bine pe stomacul gol (de obicei cu o jumătate de oră înainte de masă), "
        "altele trebuie luate la masă ca să nu irite stomacul. Programul din tab-ul Azi ține deja cont de asta.",
    ),
    "prescriber": (
        "De ce contează cine l-a prescris?",
        "Medicul de familie vede rețetele lui, dar nu întotdeauna pe ale specialiștilor sau ce se cumpără fără rețetă. "
        "Lista de aici îi arată tot, la un loc.",
    ),
}


def entry(key: str) -> dict[str, str]:
    title, text = GLOSSARY[key]
    return {"key": key, "title": title, "text": text}
