#!/usr/bin/env python3
"""Local HTTP server for ModelManager tests: serves files with Range/ETag support plus fault injection.

Usage: test_http_server.py <root dir> <port file>
Writes the chosen port to <port file>. Faults are controlled per path by query-free control files:
  <root>/.faults/<name>  containing one of:
    drop:<bytes>   close the connection after sending <bytes> of the body (once), then serve normally
    corrupt        flip one byte in the middle of the body (always)
    status:<code>  reply with that HTTP status (always)
Each request is appended to <root>/.requests.log as "<path> <Range header or ->".
"""
import os, sys, threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

ROOT = os.path.abspath(sys.argv[1])
PORT_FILE = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split("?")[0].lstrip("/")
        with open(os.path.join(ROOT, ".requests.log"), "a") as log:
            log.write(f"{path} {self.headers.get('Range', '-')}\n")
        fault_file = os.path.join(ROOT, ".faults", path.replace("/", "__"))
        fault = open(fault_file).read().strip() if os.path.exists(fault_file) else ""
        if fault.startswith("status:"):
            code = int(fault.split(":")[1])
            self.send_response(code)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        full = os.path.join(ROOT, path)
        if not os.path.isfile(full):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        data = open(full, "rb").read()
        if fault == "corrupt":
            data = bytearray(data)
            data[len(data) // 2] ^= 0xFF
            data = bytes(data)
        etag = '"%x-%x"' % (len(data), hash(data) & 0xFFFFFFFF)
        start, end = 0, len(data) - 1
        rng = self.headers.get("Range")
        status = 200
        if rng and rng.startswith("bytes="):
            s, _, e = rng[6:].partition("-")
            start = int(s) if s else 0
            end = int(e) if e else len(data) - 1
            status = 206
        body = data[start:end + 1]
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", etag)
        self.send_header("Last-Modified", "Wed, 01 Oct 2026 00:00:00 GMT")
        self.send_header("Content-Length", str(len(body)))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        if fault.startswith("drop:"):
            cut = int(fault.split(":")[1])
            os.remove(fault_file)  # only once
            self.wfile.write(body[:cut])
            self.wfile.flush()
            self.connection.shutdown(2)
            self.close_connection = True
            return
        self.wfile.write(body)


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True


server = Server(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
