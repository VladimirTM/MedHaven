"""Persistența aplicației: SQLite `app.sqlite` (pacienți, medicamente, doze, check-in-uri, Noutăți, starea alertelor,
link-uri de partajare, medicii de familie din portal, cache GTIN). Obiectele de contract se țin ca JSON; analiza nu se
salvează, se recalculează la cerere și se îmbină cu `alert_state` (status / resolution puse de aparținător sau de medic).

Calea: PG_APP_DB (implicit backend/app.sqlite, gitignored); „:memory:” pentru teste.
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import sqlite3
import threading
from pathlib import Path
from typing import Any

Json = dict[str, Any]
DEFAULT_DB = Path(__file__).resolve().parents[2] / "app.sqlite"

SCHEMA = """
CREATE TABLE IF NOT EXISTS patients(
    id TEXT PRIMARY KEY, token TEXT NOT NULL UNIQUE, data TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE TABLE IF NOT EXISTS meds(
    patient_id TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE, id TEXT NOT NULL, data TEXT NOT NULL,
    position INTEGER NOT NULL, PRIMARY KEY (patient_id, id)
);
CREATE TABLE IF NOT EXISTS doses(
    patient_id TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE, med_id TEXT NOT NULL, scheduled_at TEXT NOT NULL,
    data TEXT NOT NULL, PRIMARY KEY (patient_id, med_id, scheduled_at)
);
CREATE TABLE IF NOT EXISTS checkins(
    patient_id TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE, id TEXT NOT NULL, at TEXT NOT NULL,
    data TEXT NOT NULL, PRIMARY KEY (patient_id, id)
);
CREATE TABLE IF NOT EXISTS alert_state(
    patient_id TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE, alert_id TEXT NOT NULL,
    status TEXT NOT NULL, resolution TEXT, PRIMARY KEY (patient_id, alert_id)
);
CREATE TABLE IF NOT EXISTS share_tokens(
    token TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE, expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS feed_events(
    patient_id TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE, id TEXT NOT NULL, at TEXT NOT NULL,
    data TEXT NOT NULL, PRIMARY KEY (patient_id, id)
);
CREATE TABLE IF NOT EXISTS home_links(
    code TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE, expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS home_sessions(
    token TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE, expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS pillbox(
    patient_id TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE, day TEXT NOT NULL, moment_label TEXT NOT NULL,
    signature TEXT NOT NULL, prepared_at TEXT NOT NULL, PRIMARY KEY (patient_id, day, moment_label)
);
CREATE TABLE IF NOT EXISTS doctor_sheets(
    patient_id TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE, id TEXT NOT NULL, sent_at TEXT NOT NULL,
    data TEXT NOT NULL, PRIMARY KEY (patient_id, id)
);
CREATE TABLE IF NOT EXISTS gtin_cache(gtin TEXT PRIMARY KEY, product TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS doctors(id TEXT PRIMARY KEY, name TEXT NOT NULL, code_hash TEXT NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS doctor_sessions(
    token TEXT PRIMARY KEY, doctor_id TEXT NOT NULL REFERENCES doctors(id) ON DELETE CASCADE, expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS doctor_patients(
    doctor_id TEXT NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
    patient_id TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    linked_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')), PRIMARY KEY (doctor_id, patient_id)
);
"""


class MedIdTaken(Exception):
    """Id-ul medicamentului e deja folosit la acest pacient; `saved` e medicamentul salvat."""

    def __init__(self, saved: Json):
        super().__init__(saved["id"])
        self.saved = saved


class Store:
    def __init__(self, path: str | Path | None = None):
        self.path = str(path or os.environ.get("PG_APP_DB") or DEFAULT_DB)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(self.path, check_same_thread=False)
        self._conn.execute("PRAGMA foreign_keys = ON")
        self._conn.executescript(SCHEMA)
        self._conn.commit()

    def _q(self, sql: str, args: tuple = ()) -> list[tuple]:
        with self._lock:
            return self._conn.execute(sql, args).fetchall()

    def _x(self, sql: str, args: tuple = ()) -> int:
        with self._lock:
            cur = self._conn.execute(sql, args)
            self._conn.commit()
            return cur.rowcount

    # ---------------------------------------------------------------- pacienți

    def create_patient(self, patient: Json, token: str | None = None) -> str:
        token = token or secrets.token_urlsafe(18)
        self._x("INSERT INTO patients(id, token, data) VALUES (?, ?, ?)", (patient["id"], token, _dump(patient)))
        return token

    def delete_patient(self, pid: str) -> None:
        self._x("DELETE FROM patients WHERE id = ?", (pid,))

    def get_patient(self, pid: str) -> Json | None:
        row = self._q("SELECT data FROM patients WHERE id = ?", (pid,))
        return json.loads(row[0][0]) if row else None

    def patient_id_for_token(self, token: str) -> str | None:
        row = self._q("SELECT id FROM patients WHERE token = ?", (token,))
        return row[0][0] if row else None

    def update_patient(self, pid: str, patient: Json) -> None:
        self._x("UPDATE patients SET data = ? WHERE id = ?", (_dump(patient), pid))

    def update_patient_and_move_doses(self, pid: str, patient: Json, moves: list[tuple[str, str, str, Json]]) -> None:
        """E1: orele zilei noi și dozele de azi mutate la orele noi, în aceeași tranzacție.
        `moves` = (med_id, cheia veche, cheia nouă, doza cu scheduled_at nou)."""
        with self._lock, self._conn:
            self._conn.execute("UPDATE patients SET data = ? WHERE id = ?", (_dump(patient), pid))
            for med_id, old_key, _new_key, _dose in moves:
                self._conn.execute(
                    "DELETE FROM doses WHERE patient_id = ? AND med_id = ? AND scheduled_at = ?", (pid, med_id, old_key)
                )
            for med_id, _old_key, new_key, dose in moves:
                self._conn.execute(
                    "INSERT OR REPLACE INTO doses(patient_id, med_id, scheduled_at, data) VALUES (?, ?, ?, ?)",
                    (pid, med_id, new_key, _dump(dose)),
                )

    # ---------------------------------------------------------------- medicamente

    def list_meds(self, pid: str) -> list[Json]:
        return [json.loads(r[0]) for r in self._q("SELECT data FROM meds WHERE patient_id = ? ORDER BY position", (pid,))]

    def get_med(self, pid: str, mid: str) -> Json | None:
        row = self._q("SELECT data FROM meds WHERE patient_id = ? AND id = ?", (pid, mid))
        return json.loads(row[0][0]) if row else None

    def clear_gtin_cache(self) -> None:
        self._x("DELETE FROM gtin_cache")

    def cached_gtin(self, gtin: str, catalog_version: str) -> int | None:
        row = self._q("SELECT product FROM gtin_cache WHERE gtin = ?", (gtin,))
        if not row:
            return None
        version, _, product_id = row[0][0].rpartition("/")
        return int(product_id) if version == catalog_version and product_id.isdecimal() else None

    def add_med(self, pid: str, med: Json, catalog_product: tuple[str, int] | None = None) -> None:
        """Verificarea id-ului și inserarea sub același lock: două cereri în paralel nu ajung la IntegrityError."""
        with self._lock, self._conn:
            row = self._conn.execute("SELECT data FROM meds WHERE patient_id = ? AND id = ?", (pid, med["id"])).fetchone()
            if row:
                raise MedIdTaken(json.loads(row[0]))
            if catalog_product is not None:
                version, product_id = catalog_product
                prefix = f"{version}/"
                # Valorile vechi, fără versiune, nu pot fi atribuite unui catalog.
                self._conn.execute(
                    "INSERT INTO gtin_cache(gtin, product) VALUES (?, ?)"
                    " ON CONFLICT(gtin) DO UPDATE SET product = excluded.product"
                    " WHERE substr(gtin_cache.product, 1, ?) != ?",
                    (med["product"]["gtin"], f"{prefix}{product_id}", len(prefix), prefix),
                )
            self._conn.execute(
                "INSERT INTO meds(patient_id, id, data, position)"
                " SELECT ?, ?, ?, coalesce(max(position), 0) + 1 FROM meds WHERE patient_id = ?",
                (pid, med["id"], _dump(med), pid),
            )

    def update_med(self, pid: str, med: Json) -> None:
        self._x("UPDATE meds SET data = ? WHERE patient_id = ? AND id = ?", (_dump(med), pid, med["id"]))

    def delete_med(self, pid: str, mid: str) -> bool:
        return self._x("DELETE FROM meds WHERE patient_id = ? AND id = ?", (pid, mid)) > 0

    def replace_meds(self, pid: str, meds: list[Json]) -> None:
        self._x("DELETE FROM meds WHERE patient_id = ?", (pid,))
        for m in meds:
            self.add_med(pid, m)

    # ---------------------------------------------------------------- doze (B4: „Am luat” / „Am sărit” / anulare)

    def record_dose(self, pid: str, key: str, dose: Json) -> None:
        """Idempotent: aceeași (med_id, scheduled_at) suprascrie starea anterioară."""
        self._x(
            "INSERT OR REPLACE INTO doses(patient_id, med_id, scheduled_at, data) VALUES (?, ?, ?, ?)",
            (pid, dose["med_id"], key, _dump(dose)),
        )

    def list_doses(self, pid: str) -> list[Json]:
        rows = self._q("SELECT data FROM doses WHERE patient_id = ? ORDER BY scheduled_at, med_id", (pid,))
        return [json.loads(r[0]) for r in rows]

    # ---------------------------------------------------------------- check-in-uri (scrise de B5; citite de graf)

    def add_checkin(self, pid: str, checkin: Json) -> None:
        self._x(
            "INSERT OR REPLACE INTO checkins(patient_id, id, at, data) VALUES (?, ?, ?, ?)",
            (pid, checkin["id"], checkin["at"], _dump(checkin)),
        )

    def list_checkins(self, pid: str) -> list[Json]:
        return [json.loads(r[0]) for r in self._q("SELECT data FROM checkins WHERE patient_id = ? ORDER BY at", (pid,))]

    # ---------------------------------------------------------------- Noutăți (feed-ul aparținătorului)

    def add_event(self, pid: str, event: Json) -> None:
        self._x(
            "INSERT OR REPLACE INTO feed_events(patient_id, id, at, data) VALUES (?, ?, ?, ?)",
            (pid, event["id"], event["at"], _dump(event)),
        )

    def list_events(self, pid: str) -> list[Json]:
        rows = self._q("SELECT data FROM feed_events WHERE patient_id = ? ORDER BY at, rowid", (pid,))
        return [json.loads(r[0]) for r in rows]

    def last_event_cursor(self) -> int:
        """Cel mai mare rowid din feed_events: cursorul de la care portalul ascultă evenimentele noi (QA5.1)."""
        return self._q("SELECT coalesce(max(rowid), 0) FROM feed_events")[0][0]

    def events_after(self, cursor: int, pids: list[str]) -> list[tuple[int, str, Json]]:
        """(rowid, patient_id, eveniment) scrise după `cursor`, doar pentru pacienții dați. INSERT OR REPLACE dă un rowid
        nou, deci și un eveniment rescris apare aici."""
        if not pids:
            return []
        marks = ",".join("?" * len(pids))
        rows = self._q(
            f"SELECT rowid, patient_id, data FROM feed_events WHERE rowid > ? AND patient_id IN ({marks}) ORDER BY rowid",
            (cursor, *pids),
        )
        return [(r[0], r[1], json.loads(r[2])) for r in rows]

    # ---------------------------------------------------------------- link-uri de partajare (B6)

    def create_share(self, token: str, pid: str, expires_at: str) -> None:
        self._x("INSERT INTO share_tokens(token, patient_id, expires_at) VALUES (?, ?, ?)", (token, pid, expires_at))

    def share(self, token: str) -> tuple[str, str] | None:
        """(patient_id, expires_at) pentru token, fără verificarea expirării (o face apelantul)."""
        row = self._q("SELECT patient_id, expires_at FROM share_tokens WHERE token = ?", (token,))
        return (row[0][0], row[0][1]) if row else None

    # ---------------------------------------------------------------- pagina familiei pe web (E2)

    def create_home_link(self, pid: str, expires_at: str) -> str:
        code = secrets.token_urlsafe(18)
        self._x("INSERT INTO home_links(code, patient_id, expires_at) VALUES (?, ?, ?)", (code, pid, expires_at))
        return code

    def use_home_link(self, code: str) -> tuple[str, str] | None:
        """(patient_id, expires_at) pentru cod, șters în aceeași tranzacție: codul merge o singură dată.
        Expirarea o verifică apelantul."""
        with self._lock, self._conn:
            row = self._conn.execute("SELECT patient_id, expires_at FROM home_links WHERE code = ?", (code,)).fetchone()
            if row:
                self._conn.execute("DELETE FROM home_links WHERE code = ?", (code,))
        return (row[0], row[1]) if row else None

    def create_home_session(self, pid: str, expires_at: str) -> str:
        token = secrets.token_urlsafe(24)
        self._x("INSERT INTO home_sessions(token, patient_id, expires_at) VALUES (?, ?, ?)", (token, pid, expires_at))
        return token

    def home_session(self, token: str) -> tuple[str, str] | None:
        """(patient_id, expires_at), fără verificarea expirării (o face apelantul)."""
        row = self._q("SELECT patient_id, expires_at FROM home_sessions WHERE token = ?", (token,))
        return (row[0][0], row[0][1]) if row else None

    def delete_home_session(self, token: str) -> None:
        self._x("DELETE FROM home_sessions WHERE token = ?", (token,))

    def patient_fingerprint(self, pid: str) -> str:
        """Amprenta a tot ce arată pagina familiei (pacient, medicamente, doze, check-in-uri, Noutăți, alerte): fluxul
        /acasa/events o compară la fiecare tick, ca o bifă din aplicație să apară pe web fără refresh."""
        h = hashlib.sha256()
        with self._lock:
            for sql in (
                "SELECT data FROM patients WHERE id = ?",
                "SELECT id, data FROM meds WHERE patient_id = ? ORDER BY position",
                "SELECT med_id, scheduled_at, data FROM doses WHERE patient_id = ? ORDER BY scheduled_at, med_id",
                "SELECT count(*), max(rowid) FROM checkins WHERE patient_id = ?",
                "SELECT count(*), max(rowid) FROM feed_events WHERE patient_id = ?",
                "SELECT alert_id, status, resolution FROM alert_state WHERE patient_id = ? ORDER BY alert_id",
                "SELECT day, moment_label, signature FROM pillbox WHERE patient_id = ? ORDER BY day, moment_label",
                "SELECT count(*), max(rowid) FROM doctor_sheets WHERE patient_id = ?",
            ):
                for row in self._conn.execute(sql, (pid,)):
                    h.update(repr(row).encode())
                h.update(b"|")
        return h.hexdigest()

    # ---------------------------------------------------------------- fișa trimisă familiei de medicul de familie

    def send_sheet(self, pid: str, sheet: Json, event: Json) -> tuple[Json, bool]:
        """Fișa (o copie fixă, de la momentul trimiterii) și evenimentul din Noutăți, sub același lock. Dacă ultima fișă
        trimisă are același conținut (dublu-click, reîncercare), nu se adaugă nimic: întoarce fișa salvată și False."""
        with self._lock, self._conn:
            row = self._conn.execute(
                "SELECT data FROM doctor_sheets WHERE patient_id = ? ORDER BY sent_at DESC, rowid DESC LIMIT 1", (pid,)
            ).fetchone()
            if row:
                saved = json.loads(row[0])
                if _sheet_content(saved) == _sheet_content(sheet):
                    return saved, False
            self._conn.execute(
                "INSERT INTO doctor_sheets(patient_id, id, sent_at, data) VALUES (?, ?, ?, ?)",
                (pid, sheet["id"], sheet["sent_at"], _dump(sheet)),
            )
            self._conn.execute(
                "INSERT OR REPLACE INTO feed_events(patient_id, id, at, data) VALUES (?, ?, ?, ?)",
                (pid, event["id"], event["at"], _dump(event)),
            )
        return sheet, True

    def list_sheets(self, pid: str) -> list[Json]:
        """Fișele trimise, cea mai nouă prima."""
        rows = self._q("SELECT data FROM doctor_sheets WHERE patient_id = ? ORDER BY sent_at DESC, rowid DESC", (pid,))
        return [json.loads(r[0]) for r in rows]

    # ---------------------------------------------------------------- cutiuța săptămânală (E3)

    def pillbox(self, pid: str, first: str, last: str) -> dict[tuple[str, str], tuple[str, str]]:
        """(zi, eticheta momentului) → (semnătura conținutului, prepared_at) pentru zilele [first, last]."""
        rows = self._q(
            "SELECT day, moment_label, signature, prepared_at FROM pillbox WHERE patient_id = ? AND day BETWEEN ? AND ?",
            (pid, first, last),
        )
        return {(r[0], r[1]): (r[2], r[3]) for r in rows}

    def set_pillbox(self, pid: str, day: str, label: str, signature: str | None, prepared_at: str | None = None) -> None:
        """Bifează compartimentul cu semnătura conținutului de acum, sau îl debifează (signature None)."""
        if signature is None:
            self._x("DELETE FROM pillbox WHERE patient_id = ? AND day = ? AND moment_label = ?", (pid, day, label))
        else:
            self._x(
                "INSERT OR REPLACE INTO pillbox(patient_id, day, moment_label, signature, prepared_at) VALUES (?, ?, ?, ?, ?)",
                (pid, day, label, signature, prepared_at or ""),
            )

    # ---------------------------------------------------------------- portalul medicului de familie (B6)

    def upsert_doctor(self, doctor_id: str, name: str, code: str) -> None:
        self._x(
            "INSERT INTO doctors(id, name, code_hash) VALUES (?, ?, ?)"
            " ON CONFLICT(id) DO UPDATE SET name = excluded.name, code_hash = excluded.code_hash",
            (doctor_id, name, _code_hash(code)),
        )

    def doctor_by_code(self, code: str) -> Json | None:
        row = self._q("SELECT id, name FROM doctors WHERE code_hash = ?", (_code_hash(code),))
        return {"id": row[0][0], "name": row[0][1]} if row else None

    def create_session(self, doctor_id: str, expires_at: str) -> str:
        token = secrets.token_urlsafe(24)
        self._x("INSERT INTO doctor_sessions(token, doctor_id, expires_at) VALUES (?, ?, ?)", (token, doctor_id, expires_at))
        return token

    def session_doctor(self, token: str) -> tuple[Json, str] | None:
        """(medicul, expires_at) pentru sesiune, fără verificarea expirării (o face apelantul)."""
        row = self._q(
            "SELECT d.id, d.name, s.expires_at FROM doctor_sessions s JOIN doctors d ON d.id = s.doctor_id WHERE s.token = ?",
            (token,),
        )
        return ({"id": row[0][0], "name": row[0][1]}, row[0][2]) if row else None

    def delete_session(self, token: str) -> None:
        self._x("DELETE FROM doctor_sessions WHERE token = ?", (token,))

    def link_patient(self, doctor_id: str, pid: str) -> None:
        self._x("INSERT OR IGNORE INTO doctor_patients(doctor_id, patient_id) VALUES (?, ?)", (doctor_id, pid))

    def doctor_patient_ids(self, doctor_id: str) -> list[str]:
        rows = self._q("SELECT patient_id FROM doctor_patients WHERE doctor_id = ? ORDER BY linked_at, rowid", (doctor_id,))
        return [r[0] for r in rows]

    def doctor_has_patient(self, doctor_id: str, pid: str) -> bool:
        return bool(self._q("SELECT 1 FROM doctor_patients WHERE doctor_id = ? AND patient_id = ?", (doctor_id, pid)))

    # ---------------------------------------------------------------- starea alertelor

    def alert_states(self, pid: str) -> dict[str, Json]:
        return {
            aid: {"status": status, "resolution": json.loads(res) if res else None}
            for aid, status, res in self._q("SELECT alert_id, status, resolution FROM alert_state WHERE patient_id = ?", (pid,))
        }

    def review_alert(self, pid: str, alert_id: str, resolution: Json, event: Json) -> tuple[Json, bool]:
        """QA-07: decizia medicului și evenimentul din Noutăți, sub același lock. Aceeași decizie cu aceeași notă
        (dublu-click, reîncercare, 10 cereri în paralel) nu mai adaugă nimic: întoarce rezoluția salvată și False."""
        with self._lock, self._conn:
            row = self._conn.execute(
                "SELECT status, resolution FROM alert_state WHERE patient_id = ? AND alert_id = ?", (pid, alert_id)
            ).fetchone()
            if row and row[0] == "reviewed_by_doctor" and row[1]:
                saved = json.loads(row[1])
                if (saved.get("decision"), saved.get("note", "")) == (resolution["decision"], resolution["note"]):
                    return saved, False
            self._conn.execute(
                "INSERT OR REPLACE INTO alert_state(patient_id, alert_id, status, resolution) VALUES (?, ?, ?, ?)",
                (pid, alert_id, "reviewed_by_doctor", _dump(resolution)),
            )
            self._conn.execute(
                "INSERT OR REPLACE INTO feed_events(patient_id, id, at, data) VALUES (?, ?, ?, ?)",
                (pid, event["id"], event["at"], _dump(event)),
            )
        return resolution, True

    def set_alert_state(self, pid: str, alert_id: str, status: str, resolution: Json | None = None) -> None:
        self._x(
            "INSERT OR REPLACE INTO alert_state(patient_id, alert_id, status, resolution) VALUES (?, ?, ?, ?)",
            (pid, alert_id, status, _dump(resolution) if resolution else None),
        )


def _code_hash(code: str) -> str:
    return hashlib.sha256(code.strip().encode()).hexdigest()


def _sheet_content(sheet: Json) -> Json:
    return {k: v for k, v in sheet.items() if k not in ("id", "sent_at")}


def _dump(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
