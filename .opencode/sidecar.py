#!/usr/bin/env python3
# .opencode/sidecar.py
# Per-repo sidecar - run from repo root with `python3 .opencode/sidecar.py <socket-path>`

import http.server
import socketserver
import json
import os
import sys

socket_path = sys.argv[1] if len(sys.argv) > 1 else None

if not socket_path:
    print("Usage: python3 .opencode/sidecar.py <socket-path>", file=sys.stderr)
    sys.exit(1)

# Remove stale socket
try:
    os.unlink(socket_path)
except FileNotFoundError:
    pass

# Load handler logic ONCE into memory
# Disk edits are inert until restart (opencode-reload)
import importlib.util
spec = importlib.util.spec_from_file_location("handler", os.path.join(os.path.dirname(__file__), "sidecar", "handler.py"))
handler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handler)

class RequestHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length)
            payload = json.loads(body)
            output = handler.handle_action(payload)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(output.encode())
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f"error: {e}".encode())

    def log_message(self, format, *args):
        pass  # Suppress request logging

with socketserver.UnixStreamServer(socket_path, RequestHandler) as server:
    print(f"Sidecar listening on {socket_path}")
    server.serve_forever()
