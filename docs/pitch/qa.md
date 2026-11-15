# Întrebări probabile de la juriu: câte 2 fraze

Sursele răspunsurilor: `docs/PLAN.md` (2.3, 2.4, 4, 6.4, 8.2, 8.3, 17, 18). Unde răspunsul spune ce NU știm, e intenționat.

**De unde știți că alertele sunt corecte?**
Nu pretindem corectitudine clinică: pretindem trasabilitate. Fiecare alertă vine din DDInter, din reguli scrise cu sursă (Beers, STOPP, ACB) sau din intrări curate manual, își arată sursa, iar unde baza are nivelul „necunoscut” (cazul Sintrom) alerta e marcată „prin analogie, de confirmat de medicul de familie”.

**Ce faceți cu alert fatigue?**
Alertele minore sunt ascunse, perechile sunt deduplicate, iar avertismentele despre mâncare sunt grupate într-un singur card. Mai departe, alertele merg pe roluri: pacientul vede un card liniștit, aparținătorul și medicul de familie le văd pe cele grave, cu severitatea scrisă, nu doar colorată.

**Cum stați cu licența datelor?**
Datele descărcabile din DDInter 2.0 sunt CC BY-NC-SA 4.0, deci corecte pentru un prototip de hackathon, dar nu pentru un produs comercial. Decizia din plan: după hackathon trecem pe date licențiate comercial; restul surselor sunt publice (catalogul prețurilor maximale) sau reguli citate din ghiduri (Beers, STOPP, ACB), cu sursa în fiecare regulă.

**De ce ar deschide un medic de familie încă un portal?**
Pentru că lista îi arată doar pacienții care au ceva de revizuit, iar fișa îi arată ce nu vede în sistemul lui: OTC-urile și rețetele altor specialiști. Nu instalează nimic (e o pagină web), iar decizia lui („Menține / Modific la consultație / Trimit la specialist”) ajunge la familie.

**Cum convingeți un vârstnic să folosească telefonul?**
Nu îl convingem pe el să configureze ceva: familia face setup-ul, iar vârstnicul are un singur ecran, butoane mari, fără gesturi și vocea. Aparținătorul vede lista și alertele chiar dacă vârstnicul nu folosește aplicația, iar validarea cu utilizatori reali e un obiectiv al pilotului.

**De ce nu luați datele de la CNAS?** (răspunsul din 6.4)
CNAS vede doar rețetele compensate; OTC-urile și rețetele private, unde apar multe interacțiuni, nu sunt acolo. Integrarea realistă e prin softul de cabinet al medicului de familie, care e deja conectat la SIUI, și o vedem ca pas următor după pilot.

**Ce se întâmplă dacă LLM-ul greșește?**
Nu poate schimba nimic medical: el apare doar ca rezervă la citirea pozei sau a textului, iar rezultatul lui trebuie să se potrivească în nomenclatorul românesc, altfel intrarea e marcată „de verificat” și o confirmă omul. Dacă există o interacțiune, cât de gravă e și ce se recomandă vin exclusiv din baze de date și reguli deterministe, iar în fluxul normal (OCR și vocea pe telefon) nu rulează niciun LLM.

**Sunteți dispozitiv medical?**
Nu suntem certificați: MedHaven e un prototip, nu pune diagnostice și nu recomandă doze. Pe de altă parte, un software care oferă informații pentru decizii terapeutice poate intra sub Regula 11 din MDR (probabil cel puțin clasa IIa), așa că încadrarea finală și drumul spre conformitate le stabilim cu un specialist în reglementare înainte de orice utilizare reală.
