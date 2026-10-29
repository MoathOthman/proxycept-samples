#!/usr/bin/env python3
"""Local smoke peer only, not a production ingest service. No credentials are printed."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from datetime import datetime, timezone


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/api/logs/ingest":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 256 * 1024:
            self.send_error(413)
            return
        try:
            batch = json.loads(self.rfile.read(length))
            assert batch["schema_version"] == 1
            assert 0 < len(batch["events"]) <= 50
            for event in batch["events"]:
                assert "event_id" in event and "sequence" in event
                assert "correlation_id" in event
        except (ValueError, KeyError, AssertionError, TypeError):
            self.send_error(400)
            return
        print(json.dumps(batch), flush=True)  # Already sanitized by the SDK; use test data only.
        payload = json.dumps({"accepted": len(batch["events"]), "duplicate": 0,
            "received_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    print("Test peer at http://127.0.0.1:18880 (no authentication)", flush=True)
    HTTPServer(("127.0.0.1", 18880), Handler).serve_forever()
