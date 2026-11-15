# Slide-urile (secțiunea 17 din plan)

Maximum 25 de cuvinte pe slide (textul de pe slide, fără titlu). Cifrele de la slide-urile 1 și 2 sunt cele din [`figures.md`](figures.md), verificate în sursă.
Culori: fundal `#f7f5f2`, text `#1a1a1a`, accent `#0e6b68` (valorile din `backend/polygraph/share/static/share.css`, aceleași ca în aplicație).

## 1. Problema, cu cifre

**Pe slide**

> ~1 din 10 internări ale vârstnicilor: reacții adverse la medicamente.
> Irlanda 10,0% · meta-analiză 8,7%.
> UE (estimare 2008): ~5% din internări, ~197.000 de decese/an.

**De spus**

Aproape una din zece internări ale vârstnicilor are legătură cu o reacție adversă: 10,0% într-un spital din Irlanda, 8,7% într-o meta-analiză a 42 de studii. Comisia Europeană a estimat, în 2008, 5% din toate internările și circa 197.000 de decese pe an în UE. Iar un studiu finlandez a găsit că polimedicația înseamnă de ~3 ori mai multe șanse ca internarea să fie legată de medicamente.

*(Cifra finlandeză, OR 3,3, rămâne doar în cuvinte, ca să nu depășim 25 de cuvinte pe slide.)*

## 2. De ce acum, de ce noi

**Pe slide**

> Nimeni nu vede lista completă.
> Medicii nu comunică între ei.
> Vârstnicul e singurul „integrator”.
> NLM a oprit interacțiunile din RxNav, 2 ianuarie 2024.

**De spus**

Maria, 78 de ani, are rețete de la cinci medici și ia și ce cumpără singură din farmacie. Niciun medic nu vede punga întreagă, deci ea însăși face „integrarea”. În plus, NLM a oprit în ianuarie 2024 funcțiile de interacțiuni din RxNav, așa că nu mai există o sursă publică ușor de folosit; noi am construit una din date deschise și reguli verificabile.

## 3. Soluția

**Pe slide**

> Poză → graf → alerte deterministe → program simplu → voce → familia și medicul de familie, în aceeași buclă.

**De spus**

Pozezi cutiile și rețeta; MedHaven construiește graful terapeutic și găsește interacțiunile, dublurile și medicamentele nepotrivite vârstei. Maria primește un program cu cât mai puține momente pe zi și poate spune cu voce cum se simte. Ana și medicul de familie văd aceeași fișă, cu aceleași alerte.

## 4. Demo (3 minute)

**Pe slide**

> Demo: Maria, 78 de ani, 5 medici, 8 cutii.

**De spus** (scenariul din secțiunea 16: scanare → alerte și graf → programul Mariei → check-in vocal → rețeta ORL → portalul medicului → fișa de tipărit)

Maria are 78 de ani, cinci medici și opt cutii. Vă arătăm cum le scanează Ana, ce găsește MedHaven, ce vede Maria și ce vede medicul de familie. Plan B pentru orice pas: modul demo și video-ul de rezervă.

## 5. Cum e construit

**Pe slide**

> LLM doar la margini: citește poza, nu decide.
> DDInter 2.0 · nomenclator RO · Beers / STOPP / ACB.
> Solver determinist. Un ecran, butoane mari.
>
> Diagrama: [`architecture.svg`](architecture.svg). Fragmentul de log: [`demo-log.txt`](demo-log.txt) (8 linii; nu intră în limita de cuvinte, e ilustrație).

**De spus**

Fluxul normal nu rulează niciun LLM: OCR-ul și vocea sunt pe telefon, potrivirea în nomenclatorul românesc, interacțiunile, severitatea și programul zilei sunt deterministe și au sursa afișată lângă fiecare alertă. Un LLM intervine doar ca rezervă, când potrivirea eșuează, și rezultatul lui trece prin aceleași verificări. Logul din dreapta arată exact asta: fiecare scanare și fiecare alertă își spune ruta și sursa.

**Pe ecran, lângă diagramă:** conținutul din `demo-log.txt`.

## 6. Impact și model

**Pe slide**

> Familii: abonament mic. Medici: fișa medicației pentru consultație, OTC-urile pe care altfel nu le văd.
> Urmează: date licențiate, pilot Timișoara, CNAS prin softul de cabinet.

**De spus**

Familia plătește un abonament mic; medicul de familie primește gratuit portalul și fișa medicației pentru consultație, care îi arată ce nu vede în sistemul lui. Pașii următori sunt datele licențiate comercial (DDInter e doar necomercial), un pilot cu un cabinet din Timișoara și integrarea cu sistemele CNAS prin softul de cabinet.

## 7. Responsabil

**Pe slide**

> Nu diagnosticăm, nu schimbăm doze.
> GDPR: partajare cu token care expiră.
> MDR, Regula 11: probabil cel puțin clasa IIa; de confirmat.

**De spus**

MedHaven nu pune diagnostice și nu spune „opriți medicamentul”; spune „discutați cu medicul de familie”. Datele de sănătate se partajează doar cu un token care expiră în 72 de ore. Știm că un software care dă informații pentru decizii terapeutice poate fi dispozitiv medical și pregătim drumul spre conformitate MDR, cu un specialist în reglementare.
