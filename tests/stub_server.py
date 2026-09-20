#!/usr/bin/env python3
"""Local stand-in for the System One endpoint, so the fail-open paths can be
proven without anything leaving the machine.

    stub_server.py hang   <portfile>          accept the request, never answer
    stub_server.py 401    <portfile>          answer 401
    stub_server.py record <portfile> <out>    append each request body to <out>,
                                              then answer with zero scores
    stub_server.py badscore <portfile>        answer 200 with a score of 2,
                                              outside the probability range

Record mode is how "what would actually leave this machine" gets measured: by
capturing the bytes the shipped hook really sends, rather than by re-running a
copy of the redactor. A copy drifts from the original — that is exactly how a
redaction rule went missing while the README still claimed it.

The chosen port is written to <portfile> once the socket is listening.
"""
import json
import socket
import sys
import threading

mode, portfile = sys.argv[1], sys.argv[2]
outfile = sys.argv[3] if len(sys.argv) > 3 else None
lock = threading.Lock()

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(8)
with open(portfile, "w") as fh:
    fh.write(str(srv.getsockname()[1]))

BODY = b'{"detail":"invalid api key"}'
RESP_401 = (
    b"HTTP/1.1 401 Unauthorized\r\n"
    b"Content-Type: application/json\r\n"
    b"Content-Length: " + str(len(BODY)).encode() + b"\r\n\r\n" + BODY
)


def ok_response(payload):
    """Build a 200 response carrying ``payload`` as JSON."""
    body = json.dumps(payload).encode()
    return (b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)


def read_request(conn):
    """Read headers, then exactly Content-Length bytes of body."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(65536)
        if not chunk:
            return b""
        buf += chunk
    head, _, body = buf.partition(b"\r\n\r\n")
    length = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    while len(body) < length:
        chunk = conn.recv(65536)
        if not chunk:
            break
        body += chunk
    return body


def serve(conn):
    """Handle one connection according to the mode this stub was started in."""
    try:
        if mode == "record":
            body = read_request(conn)
            with lock, open(outfile, "a") as fh:
                fh.write(body.decode("utf-8", "replace") + "\n")
            try:
                names = list(json.loads(body).get("questions", {}))
            except (ValueError, AttributeError):
                names = []
            conn.sendall(ok_response({"answers": {n: {"noul": 0.0} for n in names}}))
            return
        if mode == "badscore":
            # A well-formed 200 carrying an impossible probability. A hook that
            # allowlists characters rather than checking the range accepts 2,
            # and 2 clears every threshold, so malformed input would block.
            body = read_request(conn)
            try:
                names = list(json.loads(body).get("questions", {}))
            except (ValueError, AttributeError):
                names = []
            conn.sendall(ok_response({"answers": {n: {"noul": 2} for n in names}}))
            return
        if mode == "401":
            # Drain the whole request first. A single recv can return before
            # curl has finished uploading, and closing mid-upload resets the
            # connection: curl then takes its transport-error branch and the
            # case never sees the HTTP 401 marker it keys on.
            read_request(conn)
            conn.sendall(RESP_401)
        else:
            conn.recv(65536)
            threading.Event().wait(120)   # accepted, then never answered
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
