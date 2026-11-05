"""Local-only JSON-lines presence server. Python standard library only."""
import argparse
import json
import re
import secrets
import socketserver
import threading
import time

MAX_LINE = 4096
MAX_PLAYERS = 4
VALID_CODE = re.compile(r"[A-Z0-9]{6,12}\Z")
VALID_NAME = re.compile(r"[\w -]{1,24}\Z", re.UNICODE)
VALID_SPRITE = re.compile(r"[\w -]{1,80}\Z", re.UNICODE)


class State:
    def __init__(self):
        self.lock = threading.RLock()
        self.rooms = {}

    def handle(self, sock, message, identity):
        if not isinstance(message, dict) or not isinstance(message.get("type"), str):
            return {"type": "error", "reason": "invalid_message"}, identity
        kind = message["type"]
        with self.lock:
            if kind in ("create", "join"):
                if identity:
                    return {"type": "error", "reason": "already_joined"}, identity
                code = message.get("session")
                name = message.get("name")
                if not isinstance(code, str) or not VALID_CODE.fullmatch(code) or not isinstance(name, str) or not VALID_NAME.fullmatch(name):
                    return {"type": "error", "reason": "invalid_identity"}, None
                if kind == "create":
                    if code in self.rooms:
                        return {"type": "error", "reason": "session_exists"}, None
                    self.rooms[code] = {"members": {}, "next_slot": 1}
                room = self.rooms.get(code)
                if not room:
                    return {"type": "error", "reason": "no_session"}, None
                resume = message.get("resume")
                if resume is not None and not isinstance(resume, str):
                    return {"type": "error", "reason": "invalid_resume"}, None
                existing = next((p for p in room["members"].values() if p["token"] == resume), None) if resume else None
                active = sum(p["sock"] is not None for p in room["members"].values())
                if existing and existing["sock"] is not None:
                    return {"type": "error", "reason": "already_connected"}, None
                if active >= MAX_PLAYERS:
                    return {"type": "error", "reason": "session_full"}, None
                if existing:
                    player = existing
                    player["sock"] = sock
                    player["last"] = time.monotonic()
                else:
                    used = {p["slot"] for p in room["members"].values() if p["sock"] is not None}
                    slot = next(i for i in range(1, MAX_PLAYERS + 1) if i not in used)
                    player = {"id": secrets.token_hex(8), "token": secrets.token_hex(16), "slot": slot,
                              "name": name, "sock": sock, "position": None, "last": time.monotonic(), "seq": -1}
                    room["members"][player["id"]] = player
                identity = (code, player["id"])
                peers = [self.public(p) for p in room["members"].values() if p["sock"] is not None and p is not player]
                self.broadcast(room, {"type": "enter", "player": self.public(player)}, except_sock=sock)
                return {"type": "welcome", "session": code, "id": player["id"], "slot": player["slot"],
                        "resume": player["token"], "peers": peers}, identity
            if not identity:
                return {"type": "error", "reason": "join_first"}, None
            code, player_id = identity
            room = self.rooms.get(code)
            player = room["members"].get(player_id) if room else None
            if not player or player["sock"] is not sock:
                return {"type": "error", "reason": "invalid_session"}, None
            if kind == "position":
                keys = ("map", "x", "y", "direction", "pattern", "seq")
                if any(type(message.get(k)) is not int for k in keys):
                    return {"type": "error", "reason": "invalid_position"}, identity
                if not (1 <= message["map"] <= 9999 and 0 <= message["x"] <= 9999 and
                        0 <= message["y"] <= 9999 and message["direction"] in (2, 4, 6, 8) and
                        0 <= message["pattern"] <= 3 and player["seq"] < message["seq"] <= player["seq"] + 10000):
                    return {"type": "error", "reason": "invalid_position"}, identity
                sprite = message.get("sprite", "")
                if not isinstance(sprite, str) or not VALID_SPRITE.fullmatch(sprite):
                    return {"type": "error", "reason": "invalid_sprite"}, identity
                player["seq"] = message["seq"]
                player["position"] = {k: message[k] for k in keys if k != "seq"}
                player["position"]["sprite"] = sprite
                self.broadcast(room, {"type": "position", "player": self.public(player)}, except_sock=sock)
                return None, identity
            if kind == "ping":
                return {"type": "pong"}, identity
            return {"type": "error", "reason": "unknown_type"}, identity

    @staticmethod
    def public(player):
        return {"id": player["id"], "slot": player["slot"], "name": player["name"],
                "position": player["position"]}

    @staticmethod
    def broadcast(room, message, except_sock=None):
        data = (json.dumps(message, separators=(",", ":")) + "\n").encode()
        for peer in room["members"].values():
            sock = peer["sock"]
            if sock is not None and sock is not except_sock:
                try:
                    sock.sendall(data)
                except OSError:
                    pass

    def disconnect(self, identity, sock):
        if not identity:
            return
        with self.lock:
            room = self.rooms.get(identity[0])
            player = room["members"].get(identity[1]) if room else None
            if player and player["sock"] is sock:
                player["sock"] = None
                player["position"] = None
                self.broadcast(room, {"type": "leave", "id": player["id"]})


STATE = State()


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        identity = None
        self.connection.settimeout(30)
        try:
            while True:
                line = self.rfile.readline(MAX_LINE + 1)
                if not line:
                    break
                if len(line) > MAX_LINE or not line.endswith(b"\n"):
                    break
                try:
                    message = json.loads(line)
                except (ValueError, UnicodeError):
                    self.wfile.write(b'{"type":"error","reason":"bad_json"}\n')
                    continue
                response, identity = STATE.handle(self.connection, message, identity)
                if response is not None:
                    self.wfile.write((json.dumps(response, separators=(",", ":")) + "\n").encode())
        except (OSError, TimeoutError):
            pass
        finally:
            STATE.disconnect(identity, self.connection)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    with Server(("127.0.0.1", args.port), Handler) as server:
        print(server.server_address[1], flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
