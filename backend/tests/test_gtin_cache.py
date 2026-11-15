import os
import sqlite3

from fastapi.testclient import TestClient

from polygraph.api import main
from polygraph.extract.gs1 import valid_gtin
from polygraph.kb import Kb
from polygraph.store import Store

SCAN = "/v1/patients/pat_demo/scan"
MEDS = "/v1/patients/pat_demo/meds"
HEADERS = {"X-Patient-Token": "demo-token"}
GTIN = "05949000000014"
PROBE = {"kind": "box", "datamatrix": f"01{GTIN}"}


def seed_catalog(path, product_id, brand):
    with sqlite3.connect(path) as conn:
        conn.execute(
            "INSERT INTO product(id, brand, brand_norm, dci_raw, form, strength_text, source)"
            " VALUES (?, ?, ?, 'ACENOCOUMAROLUM', 'COMPR.', '4mg', 'extra')",
            (product_id, brand, brand.lower()),
        )
        conn.execute(
            "INSERT INTO product_substance(product_id, substance_id) SELECT ?, id FROM substance WHERE inn = 'acenocoumarol'",
            (product_id,),
        )


def confirm(client):
    response = client.post(
        SCAN,
        headers=HEADERS,
        data={**PROBE, "ocr_lines": '[{"text":"Sintrom 4 mg"},{"text":"Acenocumarol"}]'},
    )
    assert response.status_code == 200, response.text
    (candidate,) = response.json()["candidates"]
    assert candidate["product"]["brand"] == "Sintrom"
    assert candidate["match"]["method"] == "exact_brand"
    assert client.post(MEDS, headers=HEADERS, json=candidate).status_code == 201


def probe(client):
    response = client.post(SCAN, headers=HEADERS, data=PROBE)
    assert response.status_code == 200, response.text
    return response.json()["candidates"]


def test_gtin_cache_clears_on_demo_reset(mini_kb, monkeypatch):
    seed_catalog(mini_kb.path, 1, "Sintrom")
    monkeypatch.setenv("DEMO_MODE", "1")
    main.configure(Store(":memory:"), Kb(mini_kb.path))
    try:
        with TestClient(main.app) as client:
            confirm(client)
            assert probe(client)[0]["match"]["method"] == "gtin_cache"
            assert client.post("/demo/reset", params={"live_scan": 1}).status_code == 200
            assert probe(client) == []
    finally:
        main.configure()


def test_catalog_replacement_invalidates_persisted_cache(mini_kb, tmp_path, monkeypatch):
    path = mini_kb.path
    replacement = tmp_path / "rebuilt.sqlite"
    replacement.write_bytes(path.read_bytes())
    seed_catalog(path, 1, "Sintrom")
    seed_catalog(replacement, 1, "Other")
    seed_catalog(replacement, 2, "Sintrom")
    monkeypatch.setenv("PG_KB", str(path))
    app_db = tmp_path / "app.sqlite"
    with sqlite3.connect(app_db) as conn:
        conn.execute("CREATE TABLE gtin_cache(gtin TEXT PRIMARY KEY, product TEXT NOT NULL)")
        conn.execute("INSERT INTO gtin_cache VALUES (?, '1')", (GTIN,))
    main.configure(Store(app_db))
    main.reset_demo()
    try:
        with TestClient(main.app) as client:
            assert probe(client) == []
            confirm(client)
            assert probe(client)[0]["product"]["brand"] == "Sintrom"
            main.configure(Store(app_db))
            assert probe(client)[0]["product"]["brand"] == "Sintrom"
            os.replace(replacement, path)
            assert probe(client) == []
            confirm(client)
            assert probe(client)[0]["product"]["brand"] == "Sintrom"
    finally:
        main.configure()


def test_missing_catalog_returns_503(tmp_path, monkeypatch):
    monkeypatch.setenv("PG_KB", str(tmp_path / "missing.sqlite"))
    main.configure(Store(":memory:"))
    main.reset_demo()
    try:
        with TestClient(main.app) as client:
            response = client.get("/v1/kb/search", params={"q": "sintrom"}, headers=HEADERS)
            assert response.status_code == 503
            assert "make kb" in response.json()["detail"]
    finally:
        main.configure()


def test_catalog_gtins_identify_the_pack_before_it_is_saved(mini_kb):
    with sqlite3.connect(mini_kb.path) as conn:
        conn.executemany(
            "INSERT INTO product(id, brand, brand_norm, form, strength_text, source) VALUES (?, ?, ?, ?, ?, 'extra')",
            [
                (1, "PADUDEN SR 300 mg", "paduden sr", "CAPS. CU ELIB. PREL.", "300mg"),
                (2, "PADUDEN SR 300 mg", "paduden sr", "COMPR.", "300mg"),
            ],
        )
    gtin = "05944702001390"
    assert valid_gtin(gtin)
    store = Store(":memory:")
    kb = Kb(mini_kb.path)
    assert store.cached_gtin(gtin, kb.version) is None
    main.configure(store, kb)
    main.reset_demo()
    try:
        with TestClient(main.app) as client:
            response = client.post(SCAN, headers=HEADERS, data={"kind": "box", "datamatrix": f"01{gtin}17251200"})
            assert response.status_code == 200, response.text
            (candidate,) = response.json()["candidates"]
            assert candidate["match"]["method"] == "gtin_cache"
            assert candidate["product"]["form"] == "capsule cu eliberare prelungită"
            assert candidate["product"]["gtin"] == gtin
            assert candidate["product"]["pack_size"] == 10
            assert candidate["product"]["expiry"] == "2025-12-31"
    finally:
        main.configure()


def test_demo_boxes_get_the_box_and_pill_photos_without_a_picture(mini_kb):
    """Cutiile din demo/photos/gtins.csv recunoscute doar din cod (gtin_cache, fără poză) primesc pozele pregătite."""
    with sqlite3.connect(mini_kb.path) as conn:
        conn.execute(
            "INSERT INTO product(id, brand, brand_norm, form, strength_text, source)"
            " VALUES (1, 'PADUDEN SR 300 mg', 'paduden sr', 'CAPS. CU ELIB. PREL.', '300mg', 'extra')"
        )
    main.configure(Store(":memory:"), Kb(mini_kb.path))
    main.reset_demo()
    try:
        with TestClient(main.app) as client:
            response = client.post(SCAN, headers=HEADERS, data={"kind": "box", "datamatrix": "0105944702001390"})
            assert response.status_code == 200, response.text
            (candidate,) = response.json()["candidates"]
            assert candidate["match"]["method"] == "gtin_cache"
            assert candidate["photo_url"] == "/media/med_11.jpg"
            assert candidate["pill_photo_url"] == "/media/pill_11.jpg"
            saved = client.post(MEDS, headers=HEADERS, json=candidate)
            assert saved.status_code == 201, saved.text
            assert saved.json()["pill_photo_url"] == "/media/pill_11.jpg"
            assert client.get("/media/pill_11.jpg").headers["content-type"] == "image/jpeg"
    finally:
        main.configure()
