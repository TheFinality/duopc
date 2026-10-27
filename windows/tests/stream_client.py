"""Plays the phone against DuoPC Streamer: asks for video and sound, receives them for a few seconds,
and checks that they decode (by feeding them to FFmpeg's decoders). Saves nothing.

Usage: stream_client.py HOST PORT FFMPEG [SECONDS] [--gateway URIFILE]
  --gateway: connect through DuoPC Gateway (pinned TLS 1.3 + DPC2 hello) using a pairing code file.
"""
import base64, hashlib, socket, ssl, struct, subprocess, sys, time, urllib.parse

host, port, ffmpeg = sys.argv[1], int(sys.argv[2]), sys.argv[3]
seconds = float(sys.argv[4]) if len(sys.argv) > 4 and not sys.argv[4].startswith("--") else 4.0

sock = socket.create_connection((host, port), timeout=10)
if "--gateway" in sys.argv:
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(open(sys.argv[sys.argv.index("--gateway") + 1]).read().strip()).query))
    token = base64.urlsafe_b64decode(q["t"] + "=" * (-len(q["t"]) % 4))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    sock = ctx.wrap_socket(sock)
    assert hashlib.sha256(sock.getpeercert(binary_form=True)).hexdigest() == q["fp"], "certificate pin mismatch"
    sock.sendall(b"DPC2" + token + bytes([2]))     # channel 2 = video
    assert sock.recv(1) == b"\x00", "gateway rejected the hello"

def read_exact(n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk: raise EOFError
        data += chunk
    return data

def send(kind, payload=b""):
    sock.sendall(struct.pack("<BI", kind, len(payload)) + payload)

send(0x19, bytes([1 | 2]))                         # Options: sound, automatic quality
send(0x10, struct.pack("<IH", 8000, 30))           # Start: 8 Mbps, 30 fps

annexb, config, frames, keyframes, sizes, first_frame_at, stats = bytearray(), None, 0, 0, [], None, []
configs, pending_sets = 0, bytearray()
adts, audio_frames = bytearray(), 0
start = time.time()
sock.settimeout(2)
try:
    while time.time() - start < seconds:
        kind, length = struct.unpack("<BI", read_exact(5))
        payload = read_exact(length)
        if kind == 0x01:
            width, height, fps, codec = struct.unpack_from("<IIHB", payload)
            hvcc = payload[11:]
            config = (width, height, fps, codec, len(hvcc))
            configs += 1
            pending_sets = bytearray()
            n, pos = hvcc[22], 23
            for _ in range(n):                            # parameter sets → Annex B, put before the next
                count = struct.unpack_from(">H", hvcc, pos + 1)[0]; pos += 3   # frame unless it has its own
                for _ in range(count):
                    size = struct.unpack_from(">H", hvcc, pos)[0]
                    pending_sets += b"\x00\x00\x00\x01" + hvcc[pos + 2:pos + 2 + size]; pos += 2 + size
        elif kind == 0x02:
            flags = payload[0]; sample = payload[9:]
            in_band = len(sample) > 4 and ((sample[4] >> 1) & 0x3F) in (32, 33, 34, 35)
            if pending_sets and not in_band: annexb += pending_sets
            pending_sets = bytearray()
            send(0x17, payload[1:9])                       # FrameAck: echo the frame's time
            frames += 1; keyframes += flags & 1; sizes.append(len(sample))
            first_frame_at = first_frame_at or time.time() - start
            pos = 0
            while pos + 4 <= len(sample):                  # length-prefixed → Annex B
                size = struct.unpack_from(">I", sample, pos)[0]
                annexb += b"\x00\x00\x00\x01" + sample[pos + 4:pos + 4 + size]; pos += 4 + size
        elif kind == 0x03:
            print("status:", payload[0], payload[1:].decode(errors="replace"))
        elif kind == 0x05:
            stats.append(struct.unpack_from("<HHIHHI", payload))
        elif kind == 0x06:
            adts += payload; audio_frames += 1
except (socket.timeout, EOFError):
    pass
sock.close()

print(f"config: {config} (received {configs})")
print(f"stats (fps, skipped, kbps, best rtt ms, recent rtt ms, cap kbps): {stats}")
print(f"frames: {frames} ({keyframes} keyframes) in {seconds:.0f}s, first after {first_frame_at and round(first_frame_at, 2)}s, "
      f"avg {sum(sizes) // max(len(sizes), 1)} bytes, max {max(sizes, default=0)} bytes")
result = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "hevc", "-i", "-", "-f", "null", "-"],
                        input=bytes(annexb), capture_output=True)
errors = result.stderr.decode(errors="replace").strip()
print("decodes cleanly:", result.returncode == 0 and not errors, errors[:300])
sound = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "aac", "-i", "-", "-f", "null", "-"],
                       input=bytes(adts), capture_output=True)
sound_errors = sound.stderr.decode(errors="replace").strip()
print(f"sound: {audio_frames} frames ({audio_frames * 1024 / 48000:.1f} s), decodes cleanly:",
      audio_frames > 0 and sound.returncode == 0 and not sound_errors, sound_errors[:300])
ok = (config is not None and frames > 0 and keyframes >= 1 and result.returncode == 0 and not errors
      and audio_frames > 0 and sound.returncode == 0 and not sound_errors)
sys.exit(0 if ok else 1)
