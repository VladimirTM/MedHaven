# PolyGraph

PolyGraph e o aplicație iOS și un portal web care ajută familia unui vârstnic cu mai multe medicamente să țină lista completă într-un singur loc: pozezi cutiile și rețetele, iar aplicația construiește graful terapeutic și găsește interacțiunile, dublurile și medicamentele nepotrivite vârstei. Alertele vin exclusiv din baze de date și reguli deterministe, cu sursa afișată; un LLM intervine doar ca rezervă la citirea pozei sau a textului. Pacientul primește un program zilnic simplu și poate spune cu voce cum se simte, iar familia și medicul de familie văd aceeași fișă.

UniHack 2026 · The Bloom → Medical Renaissance · iOS nativ (SwiftUI) + backend Python (FastAPI).

> Prototip de hackathon. Nu pune diagnostice, nu schimbă și nu oprește medicamente, nu recomandă doze.

## Capturi

| Graful terapeutic | Alertele, cu sursa | Modul senior („Acum”) | „Arată medicului” (QR) |
|---|---|---|---|
| <img src="docs/reviews/Q3/graf.png" width="200" alt="Graful terapeutic al Mariei, cu muchii colorate după severitate"> | <img src="docs/reviews/Q3/alerte-acb.png" width="200" alt="Lista de alerte: scor ACB 3 și interacțiunea Sintrom + Nurofen"> | <img src="docs/reviews/Q3/acum-light.png" width="200" alt="Ecranul Acum: doza de la 07:00 și butonul mare Am luat"> | <img src="docs/reviews/Q3/partajare-ana.png" width="200" alt="Codul QR pentru medicul de familie, valabil 72 de ore"> |

Capturile sunt din turul de review pe simulator (`docs/reviews/Q3/`), pe pacientul demo fictiv.

## Arhitectura

Două telefoane (pacientul și aparținătorul) vorbesc prin JSON cu un backend FastAPI (extragere, motor determinist de alerte, solver de program, `kb.sqlite`); medicul de familie folosește un portal web, fără instalare. LLM-ul apare doar la margini, ca rezervă pentru citirea pozei și a textului.

Diagrama: [`docs/pitch/architecture.svg`](docs/pitch/architecture.svg) · detalii: [`docs/PLAN.md`](docs/PLAN.md), secțiunile 8.1–8.3.

## Sursele de date și licențele

| Sursă | Licență / observații |
|---|---|
| DDInter 2.0 (interacțiuni medicament-medicament, doar nivelul) | **CC BY-NC-SA 4.0, doar necomercial.** Bun pentru hackathon; decizia din plan (secțiunea 18): după hackathon, date licențiate comercial |
| Catalogul Public național al prețurilor maximale (Ministerul Sănătății) | public; dicționarul pentru potrivirea textului de pe cutii |
| AGS Beers Criteria 2023, STOPP/START v3 | reguli scrise de mână, cu sursa citată în fiecare regulă |
| ACB Scale (Regenstrief) | scorul de încărcare anticolinergică, în `kb/rules/acb.yaml` |
| RCP-urile de pe anm.ro | regulile de orar și efectele adverse, curate manual pentru substanțele din demo |

Nu folosim DrugBank (licența nu permite redistribuirea) și nici API-ul de interacțiuni RxNav, oprit de NLM la 2 ianuarie 2024. Detalii în `kb/raw/*/README.md` și `kb/rules/README.md`.

## Cum se rulează

Cerințe: Mac, [uv](https://docs.astral.sh/uv/), Xcode (pentru aplicație).

```bash
make setup     # hook-urile git + mediul Python (uv)
make kb        # kb/kb.sqlite din kb/raw (fișierele de date: kb/raw/*/README.md)
make demo      # backend-ul pentru scenă pe :8000; afișează adresa și un cod QR
make check     # contracte + ruff + pytest
```

- **Portalul medicului:** `http://localhost:8000/portal`, cod de acces `medic-demo`.
- **Aplicația iOS:** deschideți `app/PolyGraph.xcodeproj` în Xcode, alegeți un iPhone sau simulator, rulați (⌘R); în Setări, adresa serverului e cea afișată de `make demo`. Pașii de semnare: [`app/README.md`](app/README.md).
- **Verificarea scenariului demo prin API:** `make demo-check URL=http://127.0.0.1:8000`.

Cum lucrăm: [`CONTRIBUTING.md`](CONTRIBUTING.md). Designul: [`docs/DESIGN.md`](docs/DESIGN.md).

## Ce NU face

- Nu pune diagnostice, nu schimbă și nu oprește medicamente, nu recomandă doze: spune „discutați cu medicul de familie”.
- Nu înlocuiește medicul de familie; îi aduce informația pe care altfel n-o vede (OTC-uri, rețete de la mai mulți specialiști).
- Nu e dispozitiv medical certificat; e un prototip, iar încadrarea de reglementare (MDR) rămâne de confirmat cu un specialist.
- Nu se conectează la CNAS: lista medicamentelor vine din ce scanează familia.

## Structura repo-ului

| Folder | Ce e |
|---|---|
| `app/` | proiectul Xcode (SwiftUI) |
| `backend/` | FastAPI, portalul, testele |
| `kb/` | reguli, interacțiuni verificate, ingestia |
| `contracts/` | schemele, API-ul, fixture-urile demo: sursa de adevăr |
| `demo/` | poze, rețeta, transcrieri |
| `docs/` | [planul](docs/PLAN.md), [designul](docs/DESIGN.md), review-urile, materialele de [pitch](docs/pitch/) |
