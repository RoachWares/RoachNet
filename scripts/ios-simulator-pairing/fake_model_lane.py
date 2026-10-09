"""A tiny stand-in for the local model lane (Ollama-compatible API) used by the
simulator check, so phone chat can be verified without downloading a model.

    python3 fake_model_lane.py <port> <log-file>

Answers /api/version, /api/tags and /api/chat on 127.0.0.1. Every /api/chat
request body is appended to the log file as one JSON line.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
LOG = sys.argv[2]
REPLY_PREFIX = "Sim check reply:"


class Lane(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/version":
            return self._send(200, {"version": "0.0.0-sim-check"})
        if self.path == "/api/tags":
            return self._send(200, {"models": [{"name": "sim-check:latest", "size": 1}]})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0) or 0)
        if self.path != "/api/chat":
            return self._send(404, {"error": "not found"})
        body = json.loads(raw or b"{}")
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(body) + "\n")
        last = next((m.get("content", "") for m in reversed(body.get("messages", [])) if m.get("role") == "user"), "")
        return self._send(200, {
            "model": body.get("model"),
            "message": {"role": "assistant", "content": f"{REPLY_PREFIX} {last.splitlines()[0] if last else ''}"},
            "done": True,
        })


ThreadingHTTPServer(("127.0.0.1", PORT), Lane).serve_forever()
