#!/usr/bin/env python3
"""Tiny HTTP server for the local gazette preview workflow.

Serves www/ overlaid with local-data/ so the page can fetch /status.json,
/gazette.json, and /gazette-N.png from the data the developer pulled with
`make pull-prod`.

Local-data wins on path conflicts so a regenerate-latest run is picked up
on next browser refresh without restarting the server.

Cache-Control: no-store on every response — we want every refresh to be
authoritative when iterating on the renderer.

Run from inside the dev container by `make preview`. Mount points the
container expects:
    /srv/www    (read-only, the static site)
    /srv/local  (read-only, the pulled data)
"""

import http.server
import os
import posixpath
import socketserver
import sys
import urllib.parse

ROOTS = ["/srv/local", "/srv/www"]
PORT = int(os.environ.get("PORT", "8080"))


class OverlayHandler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path: str) -> str:
        path = path.split("?", 1)[0].split("#", 1)[0]
        path = posixpath.normpath(urllib.parse.unquote(path)).lstrip("/")
        # Empty path = directory root. Don't return a directory candidate
        # for it (we never want the overlay to serve a directory listing).
        # Skip dirs in the lookup so an explicit file always wins.
        for root in ROOTS:
            cand = os.path.join(root, path)
            if os.path.isfile(cand):
                return cand
        # No file — fall back to the static root and let
        # SimpleHTTPRequestHandler do its index.html dance there.
        return os.path.join(ROOTS[-1], path)

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def main() -> int:
    for r in ROOTS:
        if not os.path.isdir(r):
            print(f"[preview] missing mount: {r}", file=sys.stderr)
            return 1
    with socketserver.TCPServer(("0.0.0.0", PORT), OverlayHandler) as srv:
        srv.allow_reuse_address = True
        print(f"[preview] http://localhost:{PORT}", flush=True)
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\n[preview] stopped", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
