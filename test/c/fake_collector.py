#!/usr/bin/env python3
"""Fake OTLP/HTTP collector for test_otel. Usage: fake_collector.py --dir D --port-file F [--hang]
Listens on a free 127.0.0.1 port, writes the port to F, and saves each request as D/NNNN.json
({"method", "path", "headers", "body"}). With --hang it accepts connections and never answers."""
import argparse, json, os, signal, socketserver, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser()
ap.add_argument("--dir", required=True)
ap.add_argument("--port-file", required=True)
ap.add_argument("--hang", action="store_true")
args = ap.parse_args()
os.makedirs(args.dir, exist_ok=True)
lock = threading.Lock()
count = 0

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        global count
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        with lock:
            count += 1
            n = count
        rec = {"method": "POST", "path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body}
        tmp = os.path.join(args.dir, ".%04d.tmp" % n)
        with open(tmp, "w") as f:
            json.dump(rec, f)
        os.rename(tmp, os.path.join(args.dir, "%04d.json" % n))
        out = b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(out)
        self.close_connection = True

class HangHandler(socketserver.BaseRequestHandler):
    def handle(self):
        time.sleep(3600)

class Server(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):  # HTTPServer.server_bind does a reverse lookup that can stall for seconds
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]

class HangServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

srv = HangServer(("127.0.0.1", 0), HangHandler) if args.hang else Server(("127.0.0.1", 0), Handler)
tmp = args.port_file + ".tmp"
with open(tmp, "w") as f:
    f.write(str(srv.server_address[1]))
os.rename(tmp, args.port_file)
signal.signal(signal.SIGTERM, lambda *a: os._exit(0))
srv.serve_forever()
