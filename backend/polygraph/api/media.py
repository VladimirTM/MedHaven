"""Stochează fotografiile scanate (cutii, pastile) și servește pozele din fixture-uri."""

import os
import re
import struct
import zlib
from hashlib import sha256
from io import BytesIO
from pathlib import Path
from tempfile import NamedTemporaryFile

from fastapi import HTTPException, Response
from fastapi.responses import FileResponse
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[3]
NAME = re.compile(r"(?:[a-f0-9]{64}\.jpg|med_[0-9]{2}\.(?:jpg|png))")
PNG = b"\x89PNG\r\n\x1a\n"


def media_dir() -> Path:
    return Path(os.environ.get("PG_MEDIA_DIR") or ROOT / "backend" / "media")


def save_photo(picture: bytes) -> str:
    directory = media_dir()
    path = directory / f"{sha256(picture).hexdigest()}.jpg"
    if not path.is_file():
        directory.mkdir(parents=True, exist_ok=True)
        with NamedTemporaryFile(dir=directory, delete_on_close=False) as upload:
            upload.write(picture)
            upload.close()
            try:
                # Publică fișierul complet fără a suprascrie o încărcare identică din altă cerere.
                path.hardlink_to(upload.name)
            except FileExistsError:
                pass
    return f"/media/{path.name}"


PILL_PHOTO_SIDE = 1024
JPEG = b"\xff\xd8"


def save_pill_photo(picture: bytes) -> str:
    """E5: poza pastilei, micșorată la 1024 px pe latura mare (o pastilă nu are nevoie de mai mult);
    EXIF-ul (locația, ora) se pierde la reîncodare. ValueError dacă nu e un JPEG care se poate citi."""
    if not picture.startswith(JPEG):
        raise ValueError("nu e JPEG")
    try:
        with Image.open(BytesIO(picture)) as image:
            if image.format != "JPEG":
                raise ValueError("nu e JPEG")
            image = ImageOps.exif_transpose(image).convert("RGB")
            image.thumbnail((PILL_PHOTO_SIDE, PILL_PHOTO_SIDE))
            out = BytesIO()
            image.save(out, "JPEG", quality=85)
    except (OSError, Image.DecompressionBombError) as error:
        raise ValueError("JPEG ilizibil") from error
    return save_photo(out.getvalue())


def placeholder_png() -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", 320, 240, 8, 2, 0, 0, 0)
    pixels = (b"\x00" + bytes.fromhex("d9d4c7") * 320) * 240
    return PNG + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(pixels, 9)) + chunk(b"IEND", b"")


PLACEHOLDER = placeholder_png()


def get_photo(name: str) -> Response:
    if not NAME.fullmatch(name):
        raise HTTPException(404)
    for directory in (media_dir(), ROOT / "demo" / "photos"):
        path = directory / name
        if path.is_file():
            with path.open("rb") as picture:
                mime = "image/png" if picture.read(len(PNG)) == PNG else "image/jpeg"
            return FileResponse(path, media_type=mime)
    return Response(PLACEHOLDER, media_type="image/png")
