"""A stand-in for TightVNC 2.8 for the gateway test: answers RFB 3.8 and offers Tight (16) and VNC password (2)."""
import socket, sys, threading

def handle(c):
    try:
        c.sendall(b"RFB 003.008\n"); c.recv(12); c.sendall(bytes([2, 16, 2])); c.recv(1)
    except OSError:
        pass
    finally:
        c.close()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 45901
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen()
print(f"fake VNC on 127.0.0.1:{port}", flush=True)
s.settimeout(float(sys.argv[2]) if len(sys.argv) > 2 else 120)
try:
    while True:
        c, _ = s.accept(); threading.Thread(target=handle, args=(c,), daemon=True).start()
except socket.timeout:
    pass
