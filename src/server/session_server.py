"""Private-network JSON-lines presence server. Python standard library only."""
import argparse
import math
import copy
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import socketserver
import threading
import time

if __package__:
    from .coop_battle import BattleExchange, PROTOTYPE, PERSONAL_PROTOTYPE, DIGEST, validate_team, validate_trainer
else:
    from coop_battle import BattleExchange, PROTOTYPE, PERSONAL_PROTOTYPE, DIGEST, validate_team, validate_trainer

MAX_LINE = 32768  # Bounded personal-team snapshots; no binary game objects.
MAX_PLAYERS = 4
VALID_CODE = re.compile(r"[A-Z0-9]{6,12}\Z")
VALID_NAME = re.compile(r"[\w -]{1,24}\Z", re.UNICODE)
VALID_SPRITE = re.compile(r"[\w -]{1,80}\Z", re.UNICODE)
VALID_FOLLOWER_SPRITE = re.compile(r"Followers(?: shiny)?/[\w -]{1,80}\.png\Z", re.UNICODE)
LOCAL_SECRET = "local-development-only"


def private_bind(address):
    ip = ipaddress.ip_address(address)
    # Hamachi assigns 25/8 virtual IPv4 addresses. Bind remains exact-address only.
    networks = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "25.0.0.0/8")
    return ip.version == 4 and (
        ip.is_loopback or any(ip in ipaddress.ip_network(n) for n in networks))


def proof(secret, nonce, message):
    fields = (nonce, message.get("type", ""), message.get("session", ""),
              message.get("name", ""), message.get("resume", ""))
    if not all(isinstance(x, str) for x in fields):
        return None
    return hmac.new(secret.encode(), "\n".join(fields).encode(), hashlib.sha256).hexdigest()


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
                    self.rooms[code] = {"members": {}, "next_slot": 1, "trainers": {}}
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
            for key, encounter in list(room["trainers"].items()):
                if encounter.get("battle") and time.monotonic() > encounter["battle"].deadline:
                    self.battle_close(room, key, "battle_timeout")
            if kind in ("battle_step", "battle_abort"):
                found = next(((k, e) for k, e in room["trainers"].items()
                              if e.get("battle") and e["battle"].id == message.get("battle")), None)
                if not found or player_id not in found[1]["battle"].players:
                    return {"type": "error", "reason": "battle_not_participant"}, identity
                key, encounter = found
                if kind == "battle_abort":
                    self.battle_close(room, key, "battle_cancelled")
                    return None, identity
                error, packet = encounter["battle"].submit(player_id, message)
                if error:
                    self.battle_close(room, key, error)
                elif packet:
                    self.battle_notify(room, encounter, packet)
                    if packet["stage"] == "result":
                        self.battle_close(room, key, None)
                return None, identity
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
                speed = message.get("speed", 4)
                if type(speed) not in (int, float) or not math.isfinite(speed) or not 1 <= speed <= 8:
                    return {"type": "error", "reason": "invalid_position"}, identity
                steps = message.get("steps")
                warp = message.get("warp", False)
                if steps is not None:
                    if (not isinstance(steps, list) or len(steps) > 24 or
                            any(type(direction) is not int or direction not in (2, 4, 6, 8)
                                for direction in steps) or type(warp) is not bool or (warp and steps)):
                        return {"type": "error", "reason": "invalid_position"}, identity
                    previous = player["position"]
                    if not warp:
                        if not previous or previous["map"] != message["map"]:
                            return {"type": "error", "reason": "invalid_position"}, identity
                        endpoint_x, endpoint_y = previous["x"], previous["y"]
                        for direction in steps:
                            endpoint_x += (direction == 6) - (direction == 4)
                            endpoint_y += (direction == 2) - (direction == 8)
                        if (endpoint_x, endpoint_y) != (message["x"], message["y"]):
                            return {"type": "error", "reason": "invalid_position"}, identity
                follower = message.get("follower")
                if follower is not None:
                    follower_keys = ("map", "x", "y", "direction", "pattern", "seq", "hue")
                    if (not isinstance(follower, dict) or
                            any(type(follower.get(k)) is not int for k in follower_keys) or
                            follower["map"] != message["map"] or
                            not 0 <= follower["x"] <= 9999 or not 0 <= follower["y"] <= 9999 or
                            follower["direction"] not in (2, 4, 6, 8) or
                            not 0 <= follower["pattern"] <= 3 or
                            follower["seq"] != message["seq"] or
                            not 0 <= follower["hue"] <= 360 or
                            not isinstance(follower.get("sprite"), str) or
                            not VALID_FOLLOWER_SPRITE.fullmatch(follower["sprite"])):
                        return {"type": "error", "reason": "invalid_follower"}, identity
                    follower_speed = follower.get("speed")
                    follower_steps = follower.get("steps")
                    follower_warp = follower.get("warp")
                    if (type(follower_speed) not in (int, float) or not math.isfinite(follower_speed) or
                            not 1 <= follower_speed <= 8 or
                            not isinstance(follower_steps, list) or len(follower_steps) > 24 or
                            any(type(direction) is not int or direction not in (2, 4, 6, 8)
                                for direction in follower_steps) or
                            type(follower_warp) is not bool or (follower_warp and follower_steps)):
                        return {"type": "error", "reason": "invalid_follower"}, identity
                    previous = player["position"] and player["position"].get("follower")
                    if not follower_warp:
                        if not previous or previous["map"] != follower["map"]:
                            return {"type": "error", "reason": "invalid_follower"}, identity
                        endpoint_x, endpoint_y = previous["x"], previous["y"]
                        for direction in follower_steps:
                            endpoint_x += (direction == 6) - (direction == 4)
                            endpoint_y += (direction == 2) - (direction == 8)
                        if (endpoint_x, endpoint_y) != (follower["x"], follower["y"]):
                            return {"type": "error", "reason": "invalid_follower"}, identity
                player["seq"] = message["seq"]
                player["position"] = {k: message[k] for k in keys if k != "seq"}
                player["position"]["sprite"] = sprite
                player["position"]["speed"] = speed
                player["position"]["seq"] = message["seq"]
                if steps is not None:
                    player["position"]["steps"] = steps
                    player["position"]["warp"] = warp
                player["position"]["follower"] = follower
                self.broadcast(room, {"type": "position", "player": self.public(player)}, except_sock=sock)
                return None, identity
            if kind == "ping":
                return {"type": "pong"}, identity
            if kind == "trainer_wait":
                map_id, event_id, forced = message.get("map"), message.get("event"), message.get("forced")
                if type(map_id) is not int or type(event_id) is not int or type(forced) is not bool or not 1 <= map_id <= 9999 or not 1 <= event_id <= 9999:
                    return {"type": "error", "reason": "invalid_trainer"}, identity
                if not player["position"] or player["position"]["map"] != map_id:
                    return {"type": "error", "reason": "trainer_map_mismatch"}, identity
                key = f"{map_id}:{event_id}"
                prototype = message.get("prototype")
                if prototype not in (None, PROTOTYPE, PERSONAL_PROTOTYPE) or (prototype == PROTOTYPE and event_id != 9000):
                    return {"type": "error", "reason": "trainer_prototype"}, identity
                encounter_key = message.get("encounter_key")
                if prototype == PERSONAL_PROTOTYPE and (event_id != 9000 or encounter_key is not None):
                    if not isinstance(encounter_key, str) or not DIGEST.fullmatch(encounter_key):
                        return {"type": "error", "reason": "trainer_encounter_key"}, identity
                elif encounter_key is not None:
                    return {"type": "error", "reason": "trainer_encounter_key"}, identity
                if any(player_id in e["participants"] and k != key for k, e in room["trainers"].items()):
                    return {"type": "error", "reason": "trainer_busy"}, identity
                encounter = room["trainers"].get(key)
                if encounter and encounter["phase"] != "pending":
                    return {"type": "error", "reason": "trainer_locked"}, identity
                if encounter and encounter.get("encounter_key") != encounter_key:
                    return {"type": "error", "reason": "trainer_incompatible"}, identity
                if not encounter:
                    encounter = {"map": map_id, "event": event_id, "host": player_id,
                                 "phase": "pending", "participants": {}, "encounter_key": encounter_key}
                    room["trainers"][key] = encounter
                encounter["participants"][player_id] = {"ready": False, "forced": forced, "prototype": prototype}
                return self.trainer_notify(room, encounter, sock), identity
            if kind in ("trainer_foe", "trainer_team", "trainer_ready", "trainer_cancel", "trainer_start", "trainer_finish"):
                map_id, event_id = message.get("map"), message.get("event")
                if type(map_id) is not int or type(event_id) is not int:
                    return {"type": "error", "reason": "invalid_trainer"}, identity
                key = f"{map_id}:{event_id}"
                encounter = room["trainers"].get(key)
                if not encounter or player_id not in encounter["participants"]:
                    return {"type": "error", "reason": "no_trainer_wait"}, identity
                if kind == "trainer_finish":
                    if encounter.get("battle"):
                        return {"type": "error", "reason": "trainer_battle_active"}, identity
                    if encounter["phase"] != "locked" or player_id != encounter["host"]:
                        return {"type": "error", "reason": "trainer_not_started"}, identity
                    del room["trainers"][key]
                    self.broadcast(room, {"type": "trainer_closed", "map": map_id, "event": event_id})
                    return {"type": "trainer_closed", "map": map_id, "event": event_id}, identity
                if encounter["phase"] != "pending":
                    return {"type": "error", "reason": "trainer_locked"}, identity
                if kind == "trainer_foe":
                    if player_id != encounter["host"]:
                        return {"type": "error", "reason": "trainer_not_host"}, identity
                    if encounter["participants"][player_id].get("prototype") != PERSONAL_PROTOTYPE:
                        return {"type": "error", "reason": "trainer_prototype"}, identity
                    if not validate_team(message.get("team"), max_size=6) or not validate_trainer(message.get("trainer")):
                        return {"type": "error", "reason": "invalid_trainer_foe"}, identity
                    if encounter.get("enemy_team") is not None and (
                            encounter["enemy_team"] != message["team"] or encounter["enemy_trainer"] != message["trainer"]):
                        return {"type": "error", "reason": "trainer_foe_fixed"}, identity
                    encounter["enemy_team"] = copy.deepcopy(message["team"])
                    encounter["enemy_trainer"] = copy.deepcopy(message["trainer"])
                    return self.trainer_notify(room, encounter, sock), identity
                if kind == "trainer_team":
                    entry = encounter["participants"][player_id]
                    if entry.get("prototype") != PERSONAL_PROTOTYPE:
                        return {"type": "error", "reason": "trainer_prototype"}, identity
                    if not validate_team(message.get("team")) or not validate_trainer(message.get("trainer")):
                        return {"type": "error", "reason": "invalid_trainer_team"}, identity
                    entry["team"] = copy.deepcopy(message["team"])
                    entry["trainer"] = copy.deepcopy(message["trainer"])
                    entry["ready"] = False
                    return self.trainer_notify(room, encounter, sock), identity
                if kind == "trainer_ready":
                    if type(message.get("ready")) is not bool:
                        return {"type": "error", "reason": "invalid_ready"}, identity
                    entry = encounter["participants"][player_id]
                    if (message["ready"] and entry.get("prototype") == PERSONAL_PROTOTYPE and
                            not entry.get("team")):
                        return {"type": "error", "reason": "trainer_team_required"}, identity
                    entry["ready"] = message["ready"]
                    return self.trainer_notify(room, encounter, sock), identity
                if kind == "trainer_cancel":
                    if encounter["participants"][player_id]["forced"]:
                        return {"type": "error", "reason": "trainer_forced"}, identity
                    del encounter["participants"][player_id]
                    if not encounter["participants"]:
                        del room["trainers"][key]
                        self.broadcast(room, {"type": "trainer_closed", "map": map_id, "event": event_id})
                        return {"type": "trainer_closed", "map": map_id, "event": event_id}, identity
                    if encounter["host"] == player_id:
                        encounter["host"] = next(iter(encounter["participants"]))
                    return self.trainer_notify(room, encounter, sock), identity
                if player_id != encounter["host"]:
                    return {"type": "error", "reason": "trainer_not_host"}, identity
                if type(message.get("solo")) is not bool:
                    return {"type": "error", "reason": "invalid_trainer_start"}, identity
                selected = [player_id]
                if not message["solo"]:
                    selected += [pid for pid, entry in encounter["participants"].items()
                                 if pid != player_id and entry["ready"]]
                if len(selected) != 1:
                    prototype = encounter["participants"][player_id].get("prototype")
                    if (len(selected) != 2 or (prototype == PROTOTYPE and event_id != 9000) or
                            prototype not in (PROTOTYPE, PERSONAL_PROTOTYPE) or
                            any(not encounter["participants"][pid]["ready"] or
                                encounter["participants"][pid].get("prototype") != prototype
                                for pid in selected)):
                        return {"type": "error", "reason": "coop_battle_pending"}, identity
                    sizes = (2, 2)
                    if prototype == PERSONAL_PROTOTYPE:
                        if any(not encounter["participants"][pid].get("team") for pid in selected):
                            return {"type": "error", "reason": "trainer_team_required"}, identity
                        if event_id != 9000 and not encounter.get("enemy_team"):
                            return {"type": "error", "reason": "trainer_foe_required"}, identity
                        sizes = tuple(len(encounter["participants"][pid]["team"]) for pid in selected)
                    encounter["prototype"] = prototype
                    encounter["battle"] = BattleExchange(selected, sizes)
                encounter["phase"] = "locked"
                encounter["participants"] = {pid: encounter["participants"][pid] for pid in selected}
                return self.trainer_notify(room, encounter, sock), identity
            return {"type": "error", "reason": "unknown_type"}, identity

    @staticmethod
    def trainer_public(room, encounter, recipient=None):
        state = {"type": "trainer_state", "map": encounter["map"], "event": encounter["event"],
                "phase": encounter["phase"], "host": encounter["host"],
                "encounter_key": encounter.get("encounter_key"),
                "battle": encounter["battle"].id if encounter.get("battle") else None,
                "seed": encounter["battle"].seed if encounter.get("battle") else None,
                "participants": [{"id": pid, "name": room["members"][pid]["name"],
                                  "ready": entry["ready"], "forced": entry["forced"],
                                  "team_count": len(entry.get("team", []))}
                                 for pid, entry in encounter["participants"].items()]}
        if encounter.get("battle"):
            state["prototype"] = encounter["prototype"]
            state["team_sizes"] = list(encounter["battle"].team_sizes)
            if (encounter["prototype"] == PERSONAL_PROTOTYPE and
                    recipient in encounter["participants"]):
                state["selected_teams"] = [entry["team"] for entry in encounter["participants"].values()]
                state["selected_trainers"] = [entry["trainer"] for entry in encounter["participants"].values()]
                if encounter.get("enemy_team"):
                    state["enemy_team"] = encounter["enemy_team"]
                    state["enemy_trainer"] = encounter["enemy_trainer"]
        return state

    def trainer_notify(self, room, encounter, except_sock):
        response = None
        for pid, peer in room["members"].items():
            sock = peer["sock"]
            if sock is None:
                continue
            state = self.trainer_public(room, encounter, pid)
            if sock is except_sock:
                response = state
            else:
                try:
                    sock.sendall((json.dumps(state, separators=(",", ":")) + "\n").encode())
                except OSError:
                    pass
        return response

    @staticmethod
    def battle_notify(room, encounter, message):
        data = (json.dumps(message, separators=(",", ":")) + "\n").encode()
        for pid in encounter["battle"].players:
            sock = room["members"][pid]["sock"]
            if sock:
                try:
                    sock.sendall(data)
                except OSError:
                    pass

    def battle_close(self, room, key, reason):
        encounter = room["trainers"].pop(key)
        if reason:
            self.battle_notify(room, encounter, {"type": "battle_abort",
                               "battle": encounter["battle"].id, "reason": reason})
        self.broadcast(room, {"type": "trainer_closed", "map": encounter["map"], "event": encounter["event"]})

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
                for key, encounter in list(room["trainers"].items()):
                    if player["id"] not in encounter["participants"]:
                        continue
                    if encounter.get("battle"):
                        self.battle_close(room, key, "battle_disconnect")
                        continue
                    del encounter["participants"][player["id"]]
                    if not encounter["participants"]:
                        del room["trainers"][key]
                        self.broadcast(room, {"type": "trainer_closed", "map": encounter["map"], "event": encounter["event"]})
                    else:
                        if encounter["host"] == player["id"]:
                            encounter["host"] = next(iter(encounter["participants"]))
                        self.broadcast(room, self.trainer_public(room, encounter))


STATE = State()


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        identity = None
        self.connection.settimeout(30)
        nonce = secrets.token_hex(16)
        try:
            self.wfile.write((json.dumps({"type": "challenge", "nonce": nonce}) + "\n").encode())
            while True:
                line = self.rfile.readline(MAX_LINE + 1)
                if not line:
                    break
                if len(line) > MAX_LINE or not line.endswith(b"\n"):
                    break
                try:
                    message = json.loads(line)
                except (ValueError, UnicodeError, RecursionError):
                    self.wfile.write(b'{"type":"error","reason":"bad_json"}\n')
                    continue
                if identity is None:
                    if not isinstance(message, dict) or message.get("type") not in ("create", "join"):
                        self.wfile.write(b'{"type":"error","reason":"auth_required"}\n')
                        break
                    expected = proof(self.server.secret, nonce, message)
                    provided = message.get("proof")
                    if not expected or not isinstance(provided, str) or not hmac.compare_digest(provided, expected):
                        self.wfile.write(b'{"type":"error","reason":"auth_failed"}\n')
                        break
                    nonce = None
                response, identity = STATE.handle(self.connection, message, identity)
                if response is not None:
                    self.wfile.write((json.dumps(response, separators=(",", ":")) + "\n").encode())
                    if identity is None and nonce is None:
                        break
        except (OSError, TimeoutError):
            pass
        finally:
            STATE.disconnect(identity, self.connection)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, handler=Handler, secret=LOCAL_SECRET):
        self.secret = secret
        super().__init__(address, handler)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    try:
        allowed = private_bind(args.bind)
    except ValueError:
        allowed = False
    if not allowed:
        parser.error("--bind must be an explicit loopback, LAN or private VPN IPv4 address")
    secret = os.environ.get("ANIL_COOP_SECRET")
    if not ipaddress.ip_address(args.bind).is_loopback and (not secret or len(secret) < 16):
        parser.error("ANIL_COOP_SECRET must contain at least 16 characters on a LAN/VPN")
    with Server((args.bind, args.port), Handler, secret or LOCAL_SECRET) as server:
        print(server.server_address[1], flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
