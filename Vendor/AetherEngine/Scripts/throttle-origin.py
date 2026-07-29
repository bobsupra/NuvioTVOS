#!/usr/bin/env python3
"""Range-preserving throttling proxy: puts a real origin behind a shaped link.

Some reader defects only appear at a MODERATE multiple of media rate. A fast LAN origin
fills the socket buffer, TCP throttles the sender, and client-side backpressure never has
to hold anything, so everything looks correct. #220 lived in that blind spot for weeks: the
same box, file and start position killed at 2.6x media rate and ran clean at 1.0x, and no
amount of repeating the run without shaping the link would have separated them.

This forwards Range requests upstream verbatim and re-serves the body at a fixed rate, so
real content from a real server can be played over a link of a chosen shape without
touching the server. Per-connection byte totals are logged on close, which is the
client-independent ground truth: a healthy reader measures at media rate, and a connection
running above it is reading further ahead than the consumer is draining.

  python3 Scripts/throttle-origin.py <upstream> <port> <MB/s> [--lan] [--shared] [--head MB]
                                     [--idle-timeout S]

`upstream` takes two forms, picked automatically:

  http://host:8096/Items/<id>/Download?api_key=...   one media URL
  http://host:32400                                  a whole server

The single-URL form serves that one file on any request path. The server form is a reverse
proxy: every path, query and header is forwarded, so a client that builds its own URLs from
a server address (Plex, Jellyfin, Emby) only needs its server address pointed here, with no
client-side override. Only large bodies are throttled, so API calls, artwork and playlists
stay at full speed and just the media stream is shaped.

To pick the rate, take the source's media rate (bit_rate / 8) and multiply. For a 53.5
Mbit/s remux that is 6.7 MB/s, so 17 is roughly 2.5x.

`--shared` shapes the SUM of all connections instead of each one, which is what a real link
does. Without it two readers each get the full rate and a defect that only appears when they
have to share it cannot reproduce: #240 is exactly that shape, a subtitle side reader and the
video pump on one link with ~1.4x headroom, where per-connection shaping shows nothing.

Binds loopback unless `--lan` is given. It forwards the upstream's credentials and has no
auth of its own, so exposing it is opt-in even though testing a separate device (an Apple
TV, a phone) needs exactly that.

Every close names its reason, because a proxy that ends a body quietly is indistinguishable
from a client-side stall and gets read as one. `[proxy TRUNCATED]` in particular means the
UPSTREAM ended a body short of its own Content-Length: `HTTPResponse.read` returns b"" for
that rather than raising, so a short body has to be detected by counting, and a client left
waiting on the missing bytes learns nothing until its own stall timeout fires. `blocked=` on
a close line is time the proxy spent inside sendall, which is the client not draining.
"""
import re
import socket
import sys
import threading
import time
import urllib.parse
import urllib.error
import urllib.request

_argv = [a for a in sys.argv[1:] if not a.startswith("--")]
_flags = {a for a in sys.argv[1:] if a.startswith("--")}
UPSTREAM = _argv[0].rstrip("/")
PORT = int(_argv[1])
RATE = float(_argv[2]) * 1e6
# Loopback by default: this serves whatever the upstream serves, with the upstream's own
# credentials, and no auth of its own. Testing from a separate device needs --lan, which is
# the case server mode is usually for, so it is a flag rather than the default.
BIND = "0.0.0.0" if "--lan" in _flags else "127.0.0.1"
SHARED = "--shared" in _flags

# A bare scheme://host[:port] means proxy the whole server; anything with a path is one
# media URL. urlsplit rather than string matching so a port-only authority is not mistaken
# for a path.
_parts = urllib.parse.urlsplit(UPSTREAM)
SERVER_MODE = _parts.path in ("", "/") and not _parts.query

# Shaping starts only after this much of a body has gone out, so metadata, artwork and
# playlists pass at full speed and only the media stream is shaped. Decided on bytes
# actually sent rather than on Content-Length, because a server answering chunked gives no
# length up front and must not be mistaken for a small response.
#
# `--head MB` overrides it. Set it to 0 when measuring a reader that fetches in bounded ranges:
# every range is a new body, so an 8 MB free head hands a reader 8 MB of unshaped bytes per range
# and, worse, rewards whichever build opens MORE connections. That is exactly backwards for #240,
# where opening fewer is the fix.
THROTTLE_AFTER_BYTES = 8 * 1024 * 1024
for _i, _a in enumerate(sys.argv[1:]):
    if _a == "--head" and _i + 2 <= len(sys.argv) - 1:
        THROTTLE_AFTER_BYTES = int(float(sys.argv[_i + 2]) * 1024 * 1024)

# Two different waits, so one of them cannot end the other's connection.
#
# IO_TIMEOUT covers a body in flight: the client has asked for bytes and is expected to take
# them, so a socket that blocks this long is a client that stopped draining.
#
# IDLE_TIMEOUT covers the wait for the NEXT request on a kept-alive connection, and it has to
# outlast a legitimate park. A reader that fetches in bounded ranges asks again only once its
# consumer has drained, and a subtitle side reader that has filled its head start parks for
# minutes by design. Both timeouts used to be the same 180 s, which quietly closed parked
# connections and charged the reconnects to whatever was being measured.
IO_TIMEOUT = 180
IDLE_TIMEOUT = 900.0
for _i, _a in enumerate(sys.argv[1:]):
    if _a == "--idle-timeout" and _i + 2 <= len(sys.argv) - 1:
        IDLE_TIMEOUT = float(sys.argv[_i + 2])

conns = {}
lock = threading.Lock()
t0 = time.time()
shared_sent = 0


class SharedLink:
    """One token budget for every connection at once (`--shared`).

    A virtual clock rather than a token bucket: each chunk reserves the time it would take on a
    link of RATE bytes/s, starting from whichever is later, now or the end of the last
    reservation. Chunks from different connections interleave at 256 KB, so several readers
    divide the link the way they would divide a real one, and an idle link never accrues credit
    a burst could spend.
    """

    def __init__(self, rate):
        self.rate = rate
        self.lock = threading.Lock()
        self.next_free = time.time()

    def reserve(self, nbytes):
        if self.rate <= 0:
            return
        with self.lock:
            start = max(time.time(), self.next_free)
            self.next_free = start + nbytes / self.rate
            deadline = self.next_free
        delay = deadline - time.time()
        if delay > 0:
            time.sleep(delay)


link = SharedLink(RATE) if SHARED else None

# Hop-by-hop headers must not be forwarded (RFC 9110). Content-Length and Content-Range are
# rewritten from what we actually serve, and Accept-Encoding is dropped so the upstream
# cannot hand back a compressed body whose length no longer matches the Range arithmetic.
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
              "te", "trailers", "transfer-encoding", "upgrade"}
DROP_REQUEST = HOP_BY_HOP | {"host", "accept-encoding"}
DROP_RESPONSE = HOP_BY_HOP | {"content-length", "content-range", "content-encoding"}


def upstream_size(url):
    req = urllib.request.Request(url, headers={"Range": "bytes=0-1"})
    with urllib.request.urlopen(req, timeout=30) as r:
        cr = r.headers.get("Content-Range", "")
        m = re.search(r"/(\d+)$", cr)
        if m:
            return int(m.group(1))
        length = r.headers.get("Content-Length")
        if length:
            return int(length)
        raise RuntimeError("upstream did not answer Range with Content-Range: " + cr)


SIZE = 0 if SERVER_MODE else upstream_size(UPSTREAM)


def _pct(pos, total):
    return (100.0 * pos / total) if total else 0.0


def reporter():
    while True:
        time.sleep(10.0)
        with lock:
            snap = list(conns.items())
        now = time.time()
        if link is not None:
            with lock:
                total_sent = shared_sent
            print("[proxy t=%5.1fs] shared link: %.2f MB/s aggregate over %d conns (cap %.2f MB/s)"
                  % (now - t0, (total_sent / (now - t0)) / 1e6 if now > t0 else 0.0,
                     len(snap), RATE / 1e6), flush=True)
        for cid, c in snap:
            dur = now - c["start"]
            pos = c["range_start"] + c["sent"]
            print("[proxy t=%5.1fs] conn#%d range=%d+ sent=%.1fMB pos=%.2fGB (%.1f%%) %.2f MB/s"
                  % (now - t0, cid, c["range_start"], c["sent"] / 1e6, pos / 1e9,
                     _pct(pos, c["total"]), (c["sent"] / dur) / 1e6 if dur > 0 else 0.0),
                  flush=True)


def read_request(f):
    """Request line plus headers, or None at end of connection."""
    line = f.readline()
    if not line:
        return None
    parts = line.decode("latin-1").strip().split(" ")
    if len(parts) < 2:
        return None
    method, path = parts[0], parts[1]
    headers = {}
    while True:
        h = f.readline()
        if not h or h in (b"\r\n", b"\n"):
            break
        k, _, v = h.decode("latin-1").partition(":")
        headers[k.strip().lower()] = v.strip()
    return method, path, headers


def handle(sock, cid):
    global shared_sent
    sock.settimeout(IDLE_TIMEOUT)
    f = sock.makefile("rb")
    up = None
    opened = time.time()
    served = 0
    reason = ["client closed"]
    print("[proxy OPEN ] conn#%d" % cid, flush=True)
    try:
        while True:
            sock.settimeout(IDLE_TIMEOUT)
            try:
                req = read_request(f)
            except socket.timeout:
                reason[0] = "idle %.0fs with no request (--idle-timeout)" % IDLE_TIMEOUT
                return
            sock.settimeout(IO_TIMEOUT)
            if req is None:
                return
            served += 1
            method, path, headers = req
            if method not in ("GET", "HEAD"):
                sock.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
                reason[0] = "405 %s" % method
                return

            target = (UPSTREAM + path) if SERVER_MODE else UPSTREAM
            fwd = {k: v for k, v in headers.items() if k not in DROP_REQUEST}
            upreq = urllib.request.Request(target, headers=fwd, method=method)
            try:
                up = urllib.request.urlopen(upreq, timeout=60)
            except urllib.error.HTTPError as e:
                up = e
            except Exception:
                sock.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                reason[0] = "upstream unreachable"
                return

            status = up.status if hasattr(up, "status") else up.code
            body_len = up.headers.get("Content-Length")
            body_len = int(body_len) if body_len is not None else None
            cr = up.headers.get("Content-Range")
            total = SIZE
            start = 0
            if cr:
                m = re.match(r"bytes (\d+)-(\d+)/(\d+|\*)", cr)
                if m:
                    start = int(m.group(1))
                    if m.group(3) != "*":
                        total = int(m.group(3))

            out = ["HTTP/1.1 %d %s" % (status, "Partial Content" if status == 206 else "OK")]
            for k, v in up.headers.items():
                if k.lower() not in DROP_RESPONSE:
                    out.append("%s: %s" % (k, v))
            if cr:
                out.append("Content-Range: " + cr)
            if body_len is not None:
                out.append("Content-Length: %d" % body_len)
            # With no Content-Length the client cannot find the end of the body, and this
            # proxy does not re-chunk. Closing the connection after it is the framing that
            # leaves, so say so up front (RFC 9112). Answering keep-alive here left curl
            # waiting on a complete JSON body until the socket timed out.
            keep_alive = body_len is not None
            out.append("Connection: " + ("keep-alive" if keep_alive else "close"))
            if keep_alive:
                out.append("Keep-Alive: timeout=%d" % int(IDLE_TIMEOUT))
            sock.sendall(("\r\n".join(out) + "\r\n\r\n").encode())

            if method == "HEAD" or body_len == 0:
                up.close()
                up = None
                continue

            track = False
            sent = 0
            blocked = 0.0
            began = time.time()
            upstream_stall = False
            while body_len is None or sent < body_len:
                want = 262144 if body_len is None else min(262144, body_len - sent)
                # Named separately from a client-side timeout: both are socket.timeout, and the
                # upstream's is the 60 s from urlopen while the client's is IO_TIMEOUT. Reporting
                # one as the other is how a shaping proxy gets blamed for its origin.
                try:
                    chunk = up.read(want)
                except socket.timeout:
                    upstream_stall = True
                    break
                if not chunk:
                    break
                # Timed separately from the shaping sleep below: this is the client not taking
                # bytes it asked for, which is the only way the proxy stops draining upstream.
                _t = time.time()
                sock.sendall(chunk)
                blocked += time.time() - _t
                sent += len(chunk)
                if not track and sent >= THROTTLE_AFTER_BYTES:
                    # This is a media body. Start shaping and start accounting, rebasing the
                    # clock so the unshaped head does not count as time owed.
                    track = True
                    began = time.time()
                    with lock:
                        conns[cid] = {"range_start": start + sent, "sent": 0,
                                      "start": began, "total": total}
                if track:
                    with lock:
                        if cid in conns:
                            conns[cid]["sent"] = sent - THROTTLE_AFTER_BYTES
                        shared_sent += len(chunk)
                    if link is not None:
                        link.reserve(len(chunk))
                    elif RATE > 0:
                        owed = (sent - THROTTLE_AFTER_BYTES) / RATE - (time.time() - began)
                        if owed > 0:
                            time.sleep(min(owed, 0.5))
            up.close()
            up = None
            with lock:
                c = conns.pop(cid, None)
            if c and c["sent"] > 0:
                dur = time.time() - c["start"]
                pos = c["range_start"] + c["sent"]
                print("[proxy RANGE] conn#%d req#%d range=bytes=%d- %d bytes / %.2fs = %.2f MB/s "
                      "blocked=%.1fs final pos=%.2fGB (%.1f%%)"
                      % (cid, served, c["range_start"], c["sent"], dur,
                         (c["sent"] / dur) / 1e6 if dur > 0 else 0.0, blocked, pos / 1e9,
                         _pct(pos, c["total"])), flush=True)
            # An upstream that ends a body early reaches us as a plain EOF: HTTPResponse.read
            # returns b"" on a truncated body instead of raising IncompleteRead, so the only
            # way to see it is to count. Continuing the keep-alive loop here would leave the
            # client waiting on a Content-Length that can no longer arrive, on a socket nobody
            # closes: silent to both sides until the client's own stall timeout fires, and then
            # charged to the client. Close instead, so the drop costs one RTT.
            if body_len is not None and sent < body_len:
                print("[proxy TRUNCATED] conn#%d req#%d upstream %s %d bytes short of %d "
                      "after %.1fs (blocked=%.1fs). Closing so the client sees the drop."
                      % (cid, served, "stalled 60s" if upstream_stall else "ended",
                         body_len - sent, body_len, time.time() - began, blocked), flush=True)
                reason[0] = "upstream %s req#%d" % ("stalled" if upstream_stall else "truncated", served)
                return
            if not keep_alive:
                reason[0] = "no Content-Length, framing is the close"
                return
    except socket.timeout:
        reason[0] = "no progress for %ds with a body in flight (client not draining)" % IO_TIMEOUT
    except (BrokenPipeError, ConnectionResetError, OSError) as e:
        reason[0] = "socket: %s" % e
    finally:
        if up is not None:
            try:
                up.close()
            except Exception:
                pass
        with lock:
            c = conns.pop(cid, None)
        if c and c["sent"] > 0:
            dur = time.time() - c["start"]
            pos = c["range_start"] + c["sent"]
            print("[proxy RANGE] conn#%d req#%d range=bytes=%d- %d bytes / %.2fs = %.2f MB/s "
                  "final pos=%.2fGB (%.1f%%) [incomplete, connection ending]"
                  % (cid, served, c["range_start"], c["sent"], dur,
                     (c["sent"] / dur) / 1e6 if dur > 0 else 0.0, pos / 1e9,
                     _pct(pos, c["total"])), flush=True)
        # Connection-level, so a connection's lifetime is never read off a per-range line.
        print("[proxy GONE ] conn#%d age=%.1fs requests=%d reason=%s"
              % (cid, time.time() - opened, served, reason[0]), flush=True)
        try:
            sock.close()
        except OSError:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((BIND, PORT))
    srv.listen(16)
    if SERVER_MODE:
        print("proxying server %s at %.1f MB/s on %s:%d (shaping after %d MB per body, idle timeout %.0fs)"
              % (UPSTREAM, RATE / 1e6, BIND, PORT, THROTTLE_AFTER_BYTES // (1024 * 1024), IDLE_TIMEOUT), flush=True)
    else:
        print("proxying %.2f GB upstream at %.1f MB/s (%s) on %s:%d (idle timeout %.0fs)"
              % (SIZE / 1e9, RATE / 1e6, "shared across connections" if SHARED else "per connection",
                 BIND, PORT, IDLE_TIMEOUT),
              flush=True)
    threading.Thread(target=reporter, daemon=True).start()
    cid = 0
    while True:
        sock, _ = srv.accept()
        cid += 1
        threading.Thread(target=handle, args=(sock, cid), daemon=True).start()


main()
