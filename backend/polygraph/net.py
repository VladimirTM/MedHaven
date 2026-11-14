"""Adresa locală a laptopului în rețea (B7 / QA4), folosită de `make demo` și de pagina de prezentare `/`."""

from __future__ import annotations

import ipaddress
import re
import socket
import subprocess
from collections.abc import Iterable

# Rețelele private în care stau telefoanele (Wi-Fi-ul sălii, hotspot-ul Mac-ului sau al unui iPhone)
PRIVATE = tuple(ipaddress.ip_network(n) for n in ("192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12"))


def _iface_key(iface: str) -> tuple[str, int]:
    """en0 < en1 < en10: prefixul, apoi numărul ca număr, nu ca text."""
    m = re.fullmatch(r"(\D*)(\d*)", iface)
    return (m[1], int(m[2] or 0)) if m else (iface, 0)


def rank_ips(pairs: Iterable[tuple[str, str]]) -> tuple[list[str], list[str]]:
    """(folosibile, nefolosibile) din perechi (interfață, IPv4).

    Folosibile, în ordine: bridge* (hotspot-ul Mac-ului, bridge100), apoi adresele private de pe en* în ordinea
    interfețelor, apoi alte adrese private, apoi restul. Nefolosibile: link-local (169.254.0.0/16, Wi-Fi fără DHCP
    sau cablu fără rețea), afișate la final; telefoanele nu ajung la ele, deci nu intră în QR. Loopback-ul lipsește.
    """
    usable: list[tuple[tuple[int, tuple[str, int], int], str]] = []
    unusable: list[str] = []
    seen: set[str] = set()
    for i, (iface, raw) in enumerate(pairs):
        try:
            ip = ipaddress.IPv4Address(raw)
        except ValueError:
            continue
        if raw in seen or ip.is_loopback or ip.is_unspecified or ip.is_multicast:
            continue
        seen.add(raw)
        if ip.is_link_local:
            unusable.append(raw)
            continue
        private = any(ip in net for net in PRIVATE)
        if iface.startswith("bridge"):
            group = 0
        elif iface.startswith("en") and private:
            group = 1
        else:
            group = 2 if private else 3
        usable.append(((group, _iface_key(iface), i), raw))
    return [raw for _, raw in sorted(usable)], unusable


def _interfaces() -> list[tuple[str, str]]:
    """Perechile (interfață, IPv4) ale laptopului: din ifconfig (macOS), altfel hostname -I (Linux)."""
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=3).stdout
        pairs, iface = [], ""
        for line in out.splitlines():
            if line and not line[0].isspace():
                iface = line.split(":")[0]
            m = re.search(r"\binet (\d+\.\d+\.\d+\.\d+)", line)
            if m:
                pairs.append((iface, m[1]))
        if pairs:
            return pairs
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=3).stdout
        pairs = [("", ip) for ip in out.split() if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", ip)]
        if pairs:
            return pairs
    except (OSError, subprocess.SubprocessError):
        pass
    # fără nicio interfață parsabilă: adresa pe care ar ieși un pachet (merge și fără internet, nu trimite nimic)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("10.255.255.255", 1))
            return [("", s.getsockname()[0])]
        except OSError:
            return []


def local_addresses() -> tuple[list[str], list[str]]:
    """(folosibile, nefolosibile) pentru laptopul acesta; vezi rank_ips."""
    return rank_ips(_interfaces())


def local_ips() -> list[str]:
    """Adresele IPv4 la care pot ajunge telefoanele, cea mai bună prima; listă goală dacă nu e niciuna."""
    return local_addresses()[0]


def lan_base_url(raw_base: str) -> str:
    """Când `/` e cerut de pe `localhost` / `127.0.0.1`, înlocuiește host-ul cu primul IP din rețea (QA4)."""
    base = raw_base.rstrip("/")
    m = re.match(r"^(https?://)(?:localhost|127\.0\.0\.1)(:\d+)?$", base, re.IGNORECASE)
    ips = local_ips()
    if not m or not ips:
        return base
    return f"{m.group(1)}{ips[0]}{m.group(2) or ''}"
