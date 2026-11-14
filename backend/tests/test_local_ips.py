"""local_ips(): ordinea adreselor din `make demo` și din QR (J-1), pe interfețe simulate."""

from __future__ import annotations

from polygraph import net
from polygraph.demo import serve


def fake_ifaces(monkeypatch, pairs):
    monkeypatch.setattr(net, "_interfaces", lambda: pairs)


def test_link_local_comes_after_private_on_same_interface(monkeypatch):
    fake_ifaces(monkeypatch, [("en0", "169.254.10.2"), ("en0", "192.168.1.23")])
    assert net.local_ips() == ["192.168.1.23"]
    assert net.local_addresses() == (["192.168.1.23"], ["169.254.10.2"])


def test_mac_hotspot_bridge100_comes_first(monkeypatch):
    fake_ifaces(
        monkeypatch,
        [("lo0", "127.0.0.1"), ("en0", "169.254.10.2"), ("en0", "192.168.1.23"), ("bridge100", "192.168.2.1")],
    )
    assert net.local_ips() == ["192.168.2.1", "192.168.1.23"]


def test_en_interfaces_in_numeric_order_and_private_before_others(monkeypatch):
    fake_ifaces(
        monkeypatch,
        [
            ("utun4", "100.70.1.2"),
            ("en10", "10.0.0.5"),
            ("en1", "172.20.10.4"),
            ("en11", "169.254.175.58"),
            ("en0", "192.168.1.23"),
        ],
    )
    assert net.local_addresses() == (["192.168.1.23", "172.20.10.4", "10.0.0.5", "100.70.1.2"], ["169.254.175.58"])


def test_only_link_local_gives_clear_message_and_no_qr(monkeypatch):
    fake_ifaces(monkeypatch, [("lo0", "127.0.0.1"), ("en0", "169.254.10.2")])
    usable, unusable = net.local_addresses()
    assert usable == [] and unusable == ["169.254.10.2"]
    assert net.lan_base_url("http://127.0.0.1:8000/") == "http://127.0.0.1:8000"

    text = "\n".join(serve.banner(usable, unusable, 8002, "medic-demo"))
    assert "nu afișăm un QR" in text
    assert "█" not in text and "▀" not in text
    assert "http://169.254.10.2" not in text
    assert "nefolosibilă (link-local, telefoanele nu ajung la ea): 169.254.10.2" in text


def test_banner_qr_and_first_address_use_best_ip(monkeypatch):
    fake_ifaces(monkeypatch, [("en0", "169.254.10.2"), ("en0", "192.168.1.23"), ("bridge100", "192.168.2.1")])
    lines = serve.banner(*net.local_addresses(), 8002, "medic-demo")
    first = next(line for line in lines if "adresa serverului" in line)
    assert first.endswith("http://192.168.2.1:8002")
    assert any("█" in line for line in lines)
    assert lines[-2].strip().startswith("Verificare:")
    assert any(line.endswith("169.254.10.2") and "nefolosibilă" in line for line in lines)
