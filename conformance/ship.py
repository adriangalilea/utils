"""Runs a probe with LOG_SHIP pointed at a collector on 127.0.0.1 and proves
that what it shipped is what it wrote: its batches, put back in the order of
the stream and joined by "\n", are its stderr byte for byte.

    python3 ship.py <stderr-file> <command...>

Checked on every batch, the wire: a POST with Content-Type
text/plain;charset=utf-8 and Content-Length, the bearer from LOG_SHIP_TOKEN,
at most 64 KB and 50 lines, no empty line and no trailing newline. Batches may
arrive in any order (a writer can have several in flight); each must be a run
of whole lines of the stream, and together they must be all of it, once.

The probe's stderr is written to <stderr-file>, so the run is also normalized
and diffed like the others: shipping changes nothing on stderr.
"""

import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "conformance-token"
MAX_BYTES = 64 * 1024
MAX_LINES = 50

batches: list[bytes] = []
wrong: list[str] = []


class Collector(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = self.headers.get("Content-Length")
        if length is None:
            wrong.append("a batch without Content-Length")
            body = b""
        else:
            body = self.rfile.read(int(length))
        n = len(batches) + 1
        if self.path != "/ingest":
            wrong.append(f"batch {n}: POSTed to {self.path!r}, want /ingest")
        if (self.headers.get("Content-Type") or "").lower() != "text/plain;charset=utf-8":
            wrong.append(f"batch {n}: Content-Type {self.headers.get('Content-Type')!r}")
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            wrong.append(f"batch {n}: Authorization {self.headers.get('Authorization')!r}")
        if len(body) > MAX_BYTES:
            wrong.append(f"batch {n}: {len(body)} bytes, over 64 KB")
        lines = body.split(b"\n")
        if len(lines) > MAX_LINES:
            wrong.append(f"batch {n}: {len(lines)} lines, over 50")
        if any(not line for line in lines):
            wrong.append(f"batch {n}: an empty line or a trailing newline")
        batches.append(body)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_: object) -> None:
        pass


def main() -> None:
    stderr_file, command = sys.argv[1], sys.argv[2:]
    server = ThreadingHTTPServer(("127.0.0.1", 0), Collector)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(
        os.environ,
        LOG_SHIP=f"http://127.0.0.1:{server.server_address[1]}/ingest",
        LOG_SHIP_TOKEN=TOKEN,
    )
    # The probe has shipped everything by the time it exits: a writer sends
    # what waits before its process ends.
    done = subprocess.run(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    server.shutdown()
    with open(stderr_file, "wb") as f:
        f.write(done.stderr)
    if done.returncode != 0:
        sys.exit(f"probe exited {done.returncode}")
    if not batches:
        sys.exit("nothing shipped")
    stream = done.stderr
    assert stream.endswith(b"\n"), "stderr ends mid-line"

    # Each batch is a run of whole lines of the stream: find where it starts.
    placed: list[tuple[int, bytes]] = []
    for n, body in enumerate(batches, 1):
        at = stream.find(body + b"\n")
        while at > 0 and stream[at - 1 : at] != b"\n":
            at = stream.find(body + b"\n", at + 1)
        if at < 0:
            wrong.append(f"batch {n} is not a run of lines of stderr:\n{body.decode(errors='replace')}")
            continue
        placed.append((at, body))
    shipped = b"".join(body + b"\n" for _, body in sorted(placed))
    if not wrong and shipped != stream:
        newline = b"\n"
        missing = [line for line in stream.split(newline) if line and line not in shipped]
        wrong.append(
            f"shipped {shipped.count(newline)} lines, stderr has {stream.count(newline)}; not shipped:\n"
            + "\n".join(line.decode(errors="replace") for line in missing)
        )
    if wrong:
        sys.exit("\n".join(wrong))


main()
