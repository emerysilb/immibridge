#!/usr/bin/env python3
"""Recording proxy in front of Immich. Logs every request the client actually makes.

Immich does not request-log by default, so the only trustworthy way to prove the v3
gates issue ZERO HTTP calls is to sit in the path and count.
    usage: proxy.py <listen_port> <upstream_base> <logfile>
"""
import http.server, socketserver, sys, urllib.request, urllib.error

PORT = int(sys.argv[1]); UP = sys.argv[2].rstrip("/"); LOG = sys.argv[3]
open(LOG, "w").close()

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def _do(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        with open(LOG, "a") as f:
            f.write(f"{self.command} {self.path}\n")
        req = urllib.request.Request(UP + self.path, data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in ("host", "content-length", "connection", "accept-encoding"):
                req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                data, code, hdrs = r.read(), r.status, r.headers
        except urllib.error.HTTPError as e:
            data, code, hdrs = e.read(), e.code, e.headers
        except Exception as e:
            data, code, hdrs = str(e).encode(), 502, {}
        self.send_response(code)
        ct = (hdrs.get("Content-Type") if hdrs else None) or "application/json"
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _do

class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True; daemon_threads = True

S(("127.0.0.1", PORT), H).serve_forever()
