#!/usr/bin/env python3
"""A local origin with the shape AE#377 is about: ranges, an endless body, and a refusal window on
a compressed clock. It is not the measurement. It exists so the probe can be shown to REPORT
correctly (arm C reproducing an unstopped sender, arm D catching a canary flip) before anyone
points it at a real origin and reads its verdicts as findings.

    python3 window-origin.py 8477 40 20     # serve 40 s, refuse 20 s, forever
    AE_PROBE_URL=http://127.0.0.1:8477/big.bin AE_PROBE_WINDOW_SECONDS=110 swift test

/neutral is served through the refusal window, so it stands in for the non-origin canary.
"""
# arms end to end: ranges, an endless body, and a refusal window on a compressed clock.
import os, socket, sys, threading, time

PORT = int(sys.argv[1])
SERVE = float(sys.argv[2]) if len(sys.argv) > 2 else 40.0   # seconds serving
REFUSE = float(sys.argv[3]) if len(sys.argv) > 3 else 20.0  # seconds refusing
TOTAL = 64 * 1024 * 1024 * 1024
CHUNK = 256 * 1024
START = time.time()

def refusing():
    return ((time.time() - START) % (SERVE + REFUSE)) >= SERVE

def handle(conn, tag):
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    req = b""
    try:
        while b"\r\n\r\n" not in req:
            d = conn.recv(4096)
            if not d:
                conn.close(); return
            req += d
    except Exception:
        conn.close(); return

    text = req.decode("latin1")
    line = text.split("\r\n")[0]
    path = line.split(" ")[1] if " " in line else "/"
    start, end = 0, None
    for header in text.split("\r\n"):
        if header.lower().startswith("range:"):
            spec = header.split("=", 1)[1].strip()
            lo, _, hi = spec.partition("-")
            if lo:
                start = int(lo)
            if hi:
                end = int(hi)

    neutral = path.startswith("/neutral")
    if refusing() and not neutral:
        conn.sendall(b"HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        print("%s 429 (window closed)" % tag, flush=True)
        conn.close(); return

    last = TOTAL - 1 if end is None else min(end, TOTAL - 1)
    body = last - start + 1
    head = ("HTTP/1.1 206 Partial Content\r\n"
            "Content-Range: bytes %d-%d/%d\r\n"
            "Content-Length: %d\r\nAccept-Ranges: bytes\r\n"
            "Content-Type: application/octet-stream\r\n\r\n" % (start, last, TOTAL, body))
    conn.sendall(head.encode())
    if neutral or body <= 1024 * 1024:
        conn.sendall(os.urandom(body))
        conn.close(); return

    payload = os.urandom(CHUNK)
    written = 0
    t0 = time.time()
    last = t0
    try:
        while written < body:
            written += conn.send(payload)
            now = time.time()
            if now - last >= 5:
                print("%s t=%.0f server wrote %.1fMB" % (tag, now - t0, written / 1048576.0), flush=True)
                last = now
    except Exception as e:
        print("%s ended after %.1fMB (%s)" % (tag, written / 1048576.0, e), flush=True)
        conn.close(); return
    conn.close()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", PORT)); s.listen(16)
print("listening on %d, serve %.0fs / refuse %.0fs" % (PORT, SERVE, REFUSE), flush=True)
n = 0
while True:
    c, _ = s.accept()
    n += 1
    threading.Thread(target=handle, args=(c, "conn%d" % n), daemon=True).start()
