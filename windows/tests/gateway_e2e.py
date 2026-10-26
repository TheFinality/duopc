"""Plays the phone against a running DuoPC Gateway: pinned TLS 1.3, the DPC1 hello, then VNC through it.

Usage: gateway_e2e.py FILE_WITH_PAIRING_CODE   (see run-gateway-test.ps1)"""
import base64, hashlib, socket, ssl, sys, time, urllib.parse

uri = open(sys.argv[1], encoding="utf-8").read().strip()
q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(uri).query))
host, port, fp = q["h"], int(q["p"]), q["fp"]
token = base64.urlsafe_b64decode(q["t"] + "=" * (-len(q["t"]) % 4))
print(f"pairing code: host={host} port={port} name={q['n']} fp={fp[:16]}... token={len(token)} bytes pw={'pw' in q}")

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE          # the pin below is the check, as in the app
ctx.minimum_version = ssl.TLSVersion.TLSv1_3

def session(tok, read_vnc=True):
    raw = socket.create_connection((host, port), timeout=5)
    s = ctx.wrap_socket(raw)
    der = s.getpeercert(binary_form=True)
    pinned = hashlib.sha256(der).hexdigest() == fp
    s.sendall(b"DPC1" + tok)
    reply = s.recv(1)
    out = {"tls": s.version(), "pinned": pinned, "reply": reply.hex() if reply else "closed"}
    if reply == b"\x00" and read_vnc:
        banner = b""
        while len(banner) < 12: banner += s.recv(12 - len(banner))
        s.sendall(b"RFB 003.008\n")
        n = s.recv(1)[0]; types = list(s.recv(n))
        out.update(banner=banner.decode().strip(), types=types)
    s.close()
    return out

checks = []
def check(name, ok, detail):
    checks.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}")

r = session(token)
check("paired phone gets VNC through TLS", r.get("pinned") and r["tls"] == "TLSv1.3" and r["reply"] == "00" and r.get("banner") == "RFB 003.008" and r.get("types") == [16, 2], r)

r2 = session(token)
check("second session works too", r2["reply"] == "00", r2)

bad = bytes(32)
results = [session(bad, read_vnc=False)["reply"] for _ in range(5)]
check("wrong token is rejected", results == ["01"] * 5, results)

try:
    r = session(token)
    check("address blocked after 5 bad tokens", False, r)
except (ssl.SSLError, ConnectionError, OSError) as e:
    check("address blocked after 5 bad tokens", True, type(e).__name__)

try:
    raw = socket.create_connection((host, port), timeout=5); raw.sendall(b"RFB 003.008\n"); data = raw.recv(64); raw.close()
    check("plain (non-TLS) VNC isn't let through", b"RFB" not in data, data[:20])
except OSError as e:
    check("plain (non-TLS) VNC isn't let through", True, type(e).__name__)

sys.exit(0 if all(checks) else 1)
