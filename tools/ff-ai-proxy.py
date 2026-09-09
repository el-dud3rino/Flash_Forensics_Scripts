#!/usr/bin/env python3
"""
Flash Forensics - local AI proxy + static server.

Some AI gateways (notably GenAI.mil) do not send CORS headers, so a browser
refuses to read their responses when the dashboard calls them directly. This
script serves the dashboard AND relays its API calls server-to-server, where
CORS does not apply. Everything stays on your machine; your API key travels
from the browser to this local proxy to the gateway, exactly as it would
directly - nothing is stored or logged here.

Usage (from the repository root, so index.html/data.js are served):

    python tools/ff-ai-proxy.py
    # then open http://localhost:8000/  (or  /example/  for the sample)

Options:
    --port 8000       port to listen on (default 8000)
    --dir  .          directory to serve (default: current directory)
    --insecure        skip TLS certificate verification for the upstream
                      (only if your network does TLS inspection and you
                      understand the risk)

In the dashboard's AI Settings, tick "Route through local proxy" so requests
go to this server instead of straight to the gateway.
"""
import argparse
import json
import ssl
import sys
import urllib.request
import urllib.error
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from functools import partial

PROXY_PATH = "/__ai_proxy"
# Headers we relay to the upstream (auth + content type + Anthropic's browser flags).
FORWARD_HEADERS = [
    "Authorization", "Content-Type", "x-api-key",
    "anthropic-version", "anthropic-dangerous-direct-browser-access",
]
_ssl_ctx = None  # set in main() when --insecure is used


class Handler(SimpleHTTPRequestHandler):
    # ---- CORS safety net (same-origin needs none, but harmless if cross-origin) ----
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def _relay(self, method):
        target = self.headers.get("X-FF-Target")
        if not target or not (target.startswith("http://") or target.startswith("https://")):
            self._json(400, {"error": {"message": "Missing or invalid X-FF-Target header"}})
            return
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else None
        fwd = {}
        for h in FORWARD_HEADERS:
            v = self.headers.get(h)
            if v:
                fwd[h] = v
        req = urllib.request.Request(target, data=body, headers=fwd, method=method)
        try:
            with urllib.request.urlopen(req, timeout=120, context=_ssl_ctx) as resp:
                data, code = resp.read(), resp.status
                ctype = resp.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as e:      # upstream 4xx/5xx: pass body through verbatim
            data, code = e.read(), e.code
            ctype = e.headers.get("Content-Type", "application/json")
        except Exception as e:                   # connection/TLS failure
            self._json(502, {"error": {"message": "Proxy could not reach upstream: " + str(e)}})
            return
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    def _json(self, code, obj):
        payload = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self._cors()
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if self.path == PROXY_PATH:
            self._relay("POST")
        else:
            self.send_error(404, "Not found")

    def do_GET(self):
        if self.path == PROXY_PATH:
            self._relay("GET")          # used by the "Load models" (GET /v1/models) call
        else:
            super().do_GET()

    def log_message(self, fmt, *args):
        # Keep it quiet; never log request bodies (which could contain the key/data).
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    ap = argparse.ArgumentParser(description="Flash Forensics local AI proxy + static server")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--dir", default=".")
    ap.add_argument("--insecure", action="store_true",
                    help="skip upstream TLS verification (use only on TLS-inspected networks)")
    args = ap.parse_args()

    global _ssl_ctx
    if args.insecure:
        _ssl_ctx = ssl.create_default_context()
        _ssl_ctx.check_hostname = False
        _ssl_ctx.verify_mode = ssl.CERT_NONE
        print("WARNING: upstream TLS verification disabled (--insecure).")

    handler = partial(Handler, directory=args.dir)
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    print("Flash Forensics AI proxy serving %s on http://localhost:%d/" % (args.dir, args.port))
    print("Open the dashboard there and enable 'Route through local proxy' in AI Settings.")
    print("Press Ctrl+C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
