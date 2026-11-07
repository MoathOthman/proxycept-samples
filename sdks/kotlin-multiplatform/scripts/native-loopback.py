"""Local test fixture only: no real credentials, production URLs, or request logging."""
import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--port-file', required=True)
args = parser.parse_args()
state = {'redirected': 0, 'slow': 0}

class Target(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        state['redirected'] += 1
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()

target = ThreadingHTTPServer(('127.0.0.1', 0), Target)
threading.Thread(target=target.serve_forever, daemon=True).start()

class Origin(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        if length > 262144 or self.headers.get('Authorization') != 'Bearer plog_ingest_nativeLoopback':
            self.send_response(400); self.end_headers(); return
        body = json.loads(self.rfile.read(length))
        message = body['events'][0]['message']
        if message == 'slow-trickle':
            import time
            state['slow'] += 1
            self.send_response(200)
            self.end_headers()
            try:
                for _ in range(100):
                    self.wfile.write(b' ')
                    self.wfile.flush()
                    time.sleep(0.5)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if message == 'redirect':
            self.send_response(307)
            self.send_header('Location', f'http://127.0.0.1:{target.server_port}/stolen')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        payload = json.dumps({'accepted': 1, 'duplicate': 0, 'received_at': '2026-10-30T12:00:00Z', 'redirected': state['redirected'], 'slow': state['slow']}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

origin = ThreadingHTTPServer(('127.0.0.1', 0), Origin)
Path(args.port_file).write_text(str(origin.server_port))
origin.serve_forever()
