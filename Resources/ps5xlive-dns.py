#!/usr/bin/env python3
"""PS5 X Live LAN DNS: a tiny forwarding resolver for "Direct from PS5 (LAN)" mode.

A queries for Twitch's plain-RTMP ingest hostnames are answered with this Mac's LAN IP so
the PS5's Twitch broadcast is received here. Everything else is forwarded upstream unchanged.
Only clients on private / link-local / loopback ranges are answered, so this is never an open
resolver. ingest.twitch.tv is deliberately NOT overridden (HTTPS discovery, TLS-validated).

Usage: ps5xlive-dns.py --lan-ip A.B.C.D [--port 53] [--upstream 1.1.1.1 --upstream 8.8.8.8]
"""
import argparse, ipaddress, os, socket, struct, sys, threading, time

OVERRIDE_SUFFIXES = ("contribute.live-video.net",)
OVERRIDE_EXACT = ("ingest.global-contribute.live-video.net", "live.twitch.tv")

def overridden(name: str) -> bool:
    n = name.lower().rstrip(".")
    if n == "ingest.twitch.tv":
        return False
    if n in OVERRIDE_EXACT or any(n == s or n.endswith("." + s) for s in OVERRIDE_SUFFIXES):
        return True
    return n.endswith(".twitch.tv") and n.count(".") == 2 and n.startswith("live-")

ALLOWED = [ipaddress.ip_network(n) for n in
           ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
            "127.0.0.0/8", "100.64.0.0/10")]

def client_allowed(ip: str) -> bool:
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(a in n for n in ALLOWED)

def parse_question(pkt: bytes):
    """Return (qname, qtype) for a single-question query, else None."""
    if len(pkt) < 12:
        return None
    qd = struct.unpack(">H", pkt[4:6])[0]
    if qd != 1 or (pkt[2] & 0x80):
        return None
    i, labels = 12, []
    while True:
        if i >= len(pkt):
            return None
        length = pkt[i]
        if length == 0:
            i += 1
            break
        if length & 0xC0:
            return None  # no compression in questions
        i += 1
        if i + length > len(pkt):
            return None
        labels.append(pkt[i:i + length].decode("idna", "replace") if False else pkt[i:i + length].decode("latin-1"))
        i += length
    if i + 4 > len(pkt):
        return None
    qtype, qclass = struct.unpack(">HH", pkt[i:i + 4])
    return ".".join(labels), qtype, qclass, i + 4

def build_answer(pkt: bytes, qend: int, qtype: int, lan_ip: str) -> bytes:
    tid = pkt[0:2]
    flags = b"\x81\x80"  # response, recursion available, NOERROR
    header = tid + flags + b"\x00\x01"  # 1 question
    question = pkt[12:qend]
    if qtype == 1:  # A -> our IP
        ancount = b"\x00\x01"
        rr = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 5, 4) + socket.inet_aton(lan_ip)  # TTL 5
    else:  # AAAA or other -> NODATA so the console falls back to our A record
        ancount = b"\x00\x00"
        rr = b""
    return header + ancount + b"\x00\x00\x00\x00" + question + rr

def _skip_name(pkt, i):
    n = len(pkt)
    while i < n:
        l = pkt[i]
        if l == 0:
            return i + 1
        if l & 0xC0 == 0xC0:
            return i + 2
        i += 1 + l
    return i

def cap_ttls(pkt: bytes, max_ttl: int) -> bytes:
    """Rewrite every RR TTL in a DNS response down to at most max_ttl (upstream TTL kept if lower)."""
    try:
        ba = bytearray(pkt)
        qd, an, ns, ar = struct.unpack(">HHHH", ba[4:12])
        i = 12
        for _ in range(qd):
            i = _skip_name(ba, i); i += 4
        for _ in range(an + ns + ar):
            i = _skip_name(ba, i)
            if i + 10 > len(ba):
                break
            ttl = struct.unpack(">I", ba[i + 4:i + 8])[0]
            rdlen = struct.unpack(">H", ba[i + 8:i + 10])[0]
            if ttl > max_ttl:
                struct.pack_into(">I", ba, i + 4, max_ttl)
            i += 10 + rdlen
        return bytes(ba)
    except Exception:
        return pkt

class Resolver:
    def __init__(self, lan_ip, upstreams, flag_path=None, max_passthrough_ttl=30):
        self.lan_ip = lan_ip
        self.upstreams = upstreams
        self.flag_path = flag_path
        self.max_passthrough_ttl = max_passthrough_ttl

    def overrides_on(self) -> bool:
        # Overrides are active only while the relay runs in LAN mode (relay creates the flag file).
        # With no flag configured, default to on (backward compatible).
        return True if not self.flag_path else os.path.exists(self.flag_path)

    def forward(self, pkt: bytes) -> bytes:
        for up in self.upstreams:
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                s.settimeout(3.0)
                s.sendto(pkt, (up, 53))
                data, _ = s.recvfrom(4096)
                s.close()
                return data
            except Exception:
                try: s.close()
                except Exception: pass
        return b""

    def handle(self, pkt: bytes, client_ip: str) -> bytes:
        if not client_allowed(client_ip):
            return b""
        q = parse_question(pkt)
        if not q:
            return self.forward(pkt)
        name, qtype, qclass, qend = q
        is_ingest = qclass == 1 and overridden(name)
        if is_ingest and qtype in (1, 28) and self.overrides_on():
            print(f"override {name} ({'A' if qtype==1 else 'AAAA'}) -> "
                  f"{self.lan_ip if qtype==1 else 'NODATA'} (ttl 5)", flush=True)
            return build_answer(pkt, qend, qtype, self.lan_ip)
        resp = self.forward(pkt)
        if is_ingest and resp:
            resp = cap_ttls(resp, self.max_passthrough_ttl)
            print(f"passthrough {name} -> upstream (ttl<={self.max_passthrough_ttl})", flush=True)
        return resp

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lan-ip", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=53)
    ap.add_argument("--upstream", action="append", default=[])
    ap.add_argument("--override-flag", default=None)
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        assert overridden("aps30.contribute.live-video.net")
        assert overridden("ingest.global-contribute.live-video.net")
        assert overridden("live.twitch.tv")
        assert overridden("live-sea.twitch.tv")
        assert not overridden("ingest.twitch.tv")
        assert not overridden("www.twitch.tv")
        assert not overridden("example.com")
        assert client_allowed("10.1.2.3") and client_allowed("192.168.1.5")
        assert not client_allowed("8.8.8.8")
        import tempfile
        # cap_ttls lowers a large TTL and keeps a small one
        hdr = b"\x12\x34\x81\x80" + struct.pack(">HHHH", 1, 1, 0, 0)
        question = b"\x07example\x03com\x00" + struct.pack(">HH", 1, 1)
        big = hdr + question + b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 3600, 4) + bytes([1, 2, 3, 4])
        capped = cap_ttls(big, 30)
        assert b"\x00\x00\x0e\x10" not in capped and b"\x00\x00\x00\x1e" in capped
        small = hdr + question + b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 10, 4) + bytes([1, 2, 3, 4])
        assert cap_ttls(small, 30) == small
        # override flag gating
        f = tempfile.NamedTemporaryFile(delete=False); f.close(); os.unlink(f.name)
        r = Resolver("10.1.2.3", ["1.1.1.1"], flag_path=f.name)
        assert r.overrides_on() is False
        open(f.name, "w").close(); assert r.overrides_on() is True; os.unlink(f.name)
        print("self-test ok")
        return
    up = a.upstream or ["1.1.1.1", "8.8.8.8"]
    res = Resolver(a.lan_ip, up, flag_path=a.override_flag)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", a.port))
    except PermissionError:
        print(f"ERROR: cannot bind UDP :{a.port} (needs privilege)", flush=True); sys.exit(13)
    except OSError as e:
        print(f"ERROR: cannot bind UDP :{a.port}: {e}", flush=True); sys.exit(14)
    print(f"dns listening on :{a.port}, lan-ip={a.lan_ip}, upstream={','.join(up)}", flush=True)
    while True:
        try:
            data, addr = sock.recvfrom(4096)
        except Exception:
            continue
        def serve(data=data, addr=addr):
            try:
                reply = res.handle(data, addr[0])
                if reply:
                    sock.sendto(reply, addr)
            except Exception as e:
                print(f"error: {e}", flush=True)
        threading.Thread(target=serve, daemon=True).start()

if __name__ == "__main__":
    main()
