"""Adresa locală a laptopului în rețea (B7 / QA4), folosită de `make demo` și de pagina de prezentare `/`."""

from __future__ import annotations

import re
import socket
import subprocess


def local_ips() -> list[str]:
    """Adresele IPv4 ale laptopului; întâi hotspot-ul (bridge*), apoi Wi-Fi / Ethernet (en*), apoi restul."""
    found: list[tuple[int, str]] = []
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=3).stdout
        iface = ""
        for line in out.splitlines():
            if line and not line[0].isspace():
                iface = line.split(":")[0]
            m = re.search(r"\binet (\d+\.\d+\.\d+\.\d+)", line)
            if m and not m[1].startswith("127."):
                found.append((0 if iface.startswith("bridge") else 1 if iface.startswith("en") else 2, m[1]))
    except (OSError, subprocess.SubprocessError):
        pass
    if not found:
        try:
            out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=3).stdout
            found = [(1, ip) for ip in out.split() if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", ip) and not ip.startswith("127.")]
        except (OSError, subprocess.SubprocessError):
            pass
    if not found:
        # fără nicio interfață parsabilă: adresa pe care ar ieși un pachet (merge și fără internet, nu trimite nimic)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            try:
                s.connect(("10.255.255.255", 1))
                found = [(1, s.getsockname()[0])]
            except OSError:
                pass
    return [ip for _, ip in sorted(dict.fromkeys(found))] or ["127.0.0.1"]


def lan_base_url(raw_base: str) -> str:
    """Când `/` e cerut de pe `localhost` / `127.0.0.1`, înlocuiește host-ul cu primul IP din rețea (QA4)."""
    base = raw_base.rstrip("/")
    m = re.match(r"^(https?://)(?:localhost|127\.0\.0\.1)(:\d+)?$", base, re.IGNORECASE)
    if not m:
        return base
    ip = local_ips()[0]
    return f"{m.group(1)}{ip}{m.group(2) or ''}"
