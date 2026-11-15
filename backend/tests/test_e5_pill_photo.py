"""E5 (docs/PLAN.md 14.6): poza pastilei lângă poza cutiei.

T-E5-01: upload → `pill_photo_url` setat, `/media/...` răspunde (JPEG, ≤ 1024 px); non-JPEG sau > 5 MB → 422 în română;
DELETE → `null`. Plus: pagina familiei arată poza doar dacă există (fără poză, markup-ul de dinainte), tipărirea din
portal nu o arată, iar poza nu schimbă analiza.
"""

from __future__ import annotations

from io import BytesIO

import pytest
import validate as contracts
from engine_helpers import real_kb
from fastapi.testclient import TestClient
from PIL import Image

from polygraph.api import main
from polygraph.store import Store

P = "/v1/patients/pat_demo"
H = {"X-Patient-Token": "demo-token"}
URL = f"{P}/meds/med_01/pill-photo"


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DEMO_MODE", "1")
    monkeypatch.setenv("PG_MEDIA_DIR", str(tmp_path / "media"))
    main.configure(store=Store(":memory:"), kb=real_kb())
    main.reset_demo()
    with TestClient(main.app, follow_redirects=False) as c:
        yield c
    main.configure(None, None)


def jpeg(width: int = 2000, height: int = 1500) -> bytes:
    out = BytesIO()
    Image.new("RGB", (width, height), (236, 232, 220)).save(out, "JPEG", quality=90)
    return out.getvalue()


def upload(client, data: bytes, mime: str = "image/jpeg", name: str = "pastila.jpg"):
    return client.post(URL, headers=H, files={"image": (name, data, mime)})


def test_upload_sets_url_and_media_serves_resized_jpeg(client):
    r = upload(client, jpeg())
    assert r.status_code == 200, r.text
    med = r.json()
    assert not contracts.schema_errors("medication_item", med)
    url = med["pill_photo_url"]
    assert url.startswith("/media/") and url.endswith(".jpg")
    assert med["photo_url"] == "/media/med_01.jpg"  # poza cutiei rămâne

    picture = client.get(url)
    assert picture.status_code == 200 and picture.headers["content-type"] == "image/jpeg"
    with Image.open(BytesIO(picture.content)) as image:
        assert image.format == "JPEG" and max(image.size) == 1024 and image.size == (1024, 768)

    listed = {m["id"]: m for m in client.get(f"{P}/meds", headers=H).json()}
    assert listed["med_01"]["pill_photo_url"] == url
    assert "pill_photo_url" not in listed["med_02"]  # celelalte medicamente rămân fără poză


def test_small_photo_is_not_enlarged(client):
    url = upload(client, jpeg(600, 800)).json()["pill_photo_url"]
    with Image.open(BytesIO(client.get(url).content)) as image:
        assert image.size == (600, 800)


@pytest.mark.parametrize(
    ("data", "mime", "name"),
    [
        (b"\x89PNG\r\n\x1a\n" + b"0" * 100, "image/png", "pastila.png"),
        (b"\xff\xd8 nu e chiar un JPEG", "image/jpeg", "pastila.jpg"),
        (b"text", "text/plain", "pastila.txt"),
    ],
)
def test_non_jpeg_is_422_in_romanian(client, data, mime, name):
    r = upload(client, data, mime, name)
    assert r.status_code == 422
    assert r.json()["detail"] == "Poza pastilei trebuie să fie JPEG."
    assert "pill_photo_url" not in client.get(f"{P}/meds", headers=H).json()[0]


def test_png_saved_as_jpg_is_rejected(client):
    out = BytesIO()
    Image.new("RGB", (40, 40)).save(out, "PNG")
    assert upload(client, out.getvalue()).status_code == 422


def test_over_5_mb_is_422_in_romanian(client):
    big = b"\xff\xd8\xff\xe0" + b"0" * (5 * 1024 * 1024)
    r = upload(client, big)
    assert r.status_code == 422
    assert r.json()["detail"] == "Poza pastilei depășește 5 MB."


def test_missing_file_unknown_med_and_token(client):
    r = client.post(URL, headers=H)
    assert r.status_code == 422 and r.json()["detail"] == "Lipsește poza pastilei."
    files = {"image": ("p.jpg", jpeg(10, 10), "image/jpeg")}
    assert client.post(f"{P}/meds/med_nu_exista/pill-photo", headers=H, files=files).status_code == 404
    assert client.post(URL, files=files).status_code == 401
    assert client.delete(f"{P}/meds/med_nu_exista/pill-photo", headers=H).status_code == 404
    assert client.delete(URL).status_code == 401


def test_delete_sets_null(client):
    upload(client, jpeg())
    r = client.delete(URL, headers=H)
    assert r.status_code == 200
    assert r.json()["pill_photo_url"] is None
    assert not contracts.schema_errors("medication_item", r.json())
    saved = next(m for m in client.get(f"{P}/meds", headers=H).json() if m["id"] == "med_01")
    assert saved["pill_photo_url"] is None


def test_patch_accepts_pill_photo_url(client):
    url = upload(client, jpeg()).json()["pill_photo_url"]
    r = client.patch(f"{P}/meds/med_01", headers=H, json={"end_date": "2027-01-31"})
    assert r.status_code == 200 and r.json()["pill_photo_url"] == url  # PATCH-ul nu pierde poza
    r = client.patch(f"{P}/meds/med_01", headers=H, json={"pill_photo_url": None})
    assert r.status_code == 200 and r.json()["pill_photo_url"] is None


def test_photo_does_not_change_the_analysis(client):
    before = client.get(f"{P}/analysis", headers=H).json()["alerts"]
    upload(client, jpeg())
    assert client.get(f"{P}/analysis", headers=H).json()["alerts"] == before


def _enter_family(client) -> None:
    url = client.post(f"{P}/web-link", headers=H).json()["url"]
    assert client.get(url[url.index("/acasa/") :]).status_code == 303


def test_family_pages_show_the_pill_only_when_there_is_one(client):
    _enter_family(client)
    for path in ("/acasa", "/acasa/medicamente"):
        page = client.get(path).text
        assert "photo-pair" not in page and "Pastila de" not in page and "<figcaption>" not in page
    url = upload(client, jpeg()).json()["pill_photo_url"]
    for path in ("/acasa", "/acasa/medicamente"):
        page = client.get(path).text
        assert page.count('alt="Pastila de Sintrom 4 mg"') >= 1, path
        assert f'src="{url}"' in page
        assert "<figcaption>Cutia</figcaption>" in page and "<figcaption>Pastila</figcaption>" in page
        assert 'style="' not in page  # CSP style-src 'self'


def test_doctor_print_never_shows_the_pill(client):
    url = upload(client, jpeg()).json()["pill_photo_url"]
    client.post("/portal/login", data={"code": "medic-demo", "next": "/portal"})
    r = client.get("/portal/patients/pat_demo/print")
    assert r.status_code == 200
    assert url not in r.text and "Pastila de" not in r.text
