#!/usr/bin/env python3

"""Mock server for local UI testing. Serves www/ and stubs CGI endpoints.
Log in with any username and password."""

import json
import time
from http.server import HTTPServer, SimpleHTTPRequestHandler
import os

FAKE_MESSAGES = [
    {
        "role": "player",
        "content": "Hello editor,\n\nI have some news from the front.\n\nThe **Vikings** are massing near my borders — at least *three* full legions. Our scouts report their commander is none other than `Ragnar_the_Bold`.",
        "created_at": int(time.time()) - 3600,
    },
    {
        "role": "editor",
        "content": "Most intriguing, dear correspondent.\n\nWe shall watch this development with great interest. The **Chronicle** appreciates your vigilance — *particularly* the detail about `Ragnar_the_Bold`.\n\nDo keep us informed.",
        "created_at": int(time.time()) - 3000,
    },
    {
        "role": "player",
        "content": "Will do.\n\nOne more thing: their navy has *three* triremes and a **Dreadnought**. The unit type is listed as `TRIREME_ADV` in our intelligence files.",
        "created_at": int(time.time()) - 1800,
    },
]

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.path.join(os.path.dirname(__file__), 'www'), **kwargs)

    def do_POST(self):
        if self.path == '/cgi-bin/editor-login':
            self.send_json({"ok": True, "token": "mock-token", "player": "peter"})
        elif self.path.startswith('/cgi-bin/editor-submit'):
            length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(length)) if length else {}
            FAKE_MESSAGES.append({
                "role": "player",
                "content": body.get("message", ""),
                "created_at": int(time.time()),
            })
            self.send_json({"ok": True})
        else:
            self.send_error(404)

    def do_GET(self):
        if self.path.startswith('/cgi-bin/editor-messages'):
            self.send_json({
                "ok": True,
                "player": "peter",
                "messages": FAKE_MESSAGES,
            })
        elif self.path.startswith('/cgi-bin/'):
            self.send_error(404)
        else:
            super().do_GET()

    def send_json(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(fmt % args)

if __name__ == '__main__':
    port = 8888
    print(f'Serving at http://localhost:{port}/editor.html')
    print('Log in with any username and password.')
    HTTPServer(('', port), Handler).serve_forever()
