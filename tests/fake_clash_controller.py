"""Small local Mihomo API stand-in for the Web controller integration test."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import time
from urllib.parse import parse_qs, unquote, urlsplit


SECRET = "test-only-secret"
GROUP = "节点选择"
NODES = ["日本/JP", "自动选择", "测试慢"]
state = {"selected": NODES[0]}


class Controller(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, code, value=None):
        body = b"" if value is None else json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def authorized(self):
        if self.headers.get("Authorization") == "Bearer " + SECRET:
            return True
        self.respond(401, {"message": "unauthorized"})
        return False

    def do_GET(self):
        if not self.authorized():
            return
        path = urlsplit(self.path).path
        if path == "/group":
            self.respond(200, {"proxies": [{"name": GROUP, "type": "Selector", "now": state["selected"], "all": NODES}]})
        elif path == "/proxies":
            self.respond(200, {"proxies": {
                GROUP: {"name": GROUP, "type": "Selector", "now": state["selected"], "all": NODES},
                NODES[0]: {"name": NODES[0], "type": "Vmess", "udp": True, "history": [{"delay": 82}]},
                NODES[1]: {"name": NODES[1], "type": "URLTest", "now": NODES[0], "all": [NODES[0]], "history": []},
                NODES[2]: {"name": NODES[2], "type": "Vmess", "history": []},
            }})
        elif path.startswith("/proxies/") and path.endswith("/delay"):
            name = unquote(path[len("/proxies/"):-len("/delay")])
            query = parse_qs(urlsplit(self.path).query)
            if query.get("url") != ["https://latency.example/test"] or query.get("timeout") != ["3500"]:
                self.respond(400, {"message": "wrong latency settings"})
            elif name not in NODES:
                self.respond(404, {"message": "unknown proxy"})
            else:
                if name == NODES[2]:
                    time.sleep(3)
                self.respond(200, {"delay": 123})
        else:
            self.respond(404, {"message": "not found"})

    def do_PUT(self):
        if not self.authorized():
            return
        name = unquote(urlsplit(self.path).path[len("/proxies/"):])
        size = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(size).decode("utf-8"))
        if name != GROUP or payload.get("name") not in NODES:
            self.respond(400, {"message": "invalid selection"})
            return
        state["selected"] = payload["name"]
        self.respond(204)


server = ThreadingHTTPServer(("127.0.0.1", 0), Controller)
Path(sys.argv[1]).write_text(str(server.server_port), encoding="ascii")
server.serve_forever()
