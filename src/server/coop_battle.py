"""Bounded, non-persistent two-player QA battle barrier. No game objects on wire."""
import re
import secrets
import time

PROTOTYPE = "qa2v2-v1"
DIGEST = re.compile(r"[a-f0-9]{64}\Z")


class BattleExchange:
    def __init__(self, players):
        self.id = secrets.token_hex(16)
        self.players = tuple(players)  # canonical ally battlers 0 and 2
        self.seed = secrets.randbelow(2**30)
        self.seq = 0
        self.pending = {}
        self.last_stage = None
        self.deadline = time.monotonic() + 180

    def submit(self, player, message):
        """Return (error, complete packet). A duplicate never replaces an order."""
        if player not in self.players:
            return "battle_not_participant", None
        if message.get("battle") != self.id:
            return "battle_stale", None
        if type(message.get("seq")) is not int or message["seq"] != self.seq:
            return "battle_sequence", None
        if player in self.pending:
            return "battle_duplicate", None
        stage, digest, command = (message.get(k) for k in ("stage", "digest", "command"))
        if stage not in ("setup", "turn", "enemy", "state", "switch", "result"):
            return "battle_stage", None
        allowed = {None: ("setup",), "setup": ("turn",), "turn": ("enemy",),
                   "enemy": ("state", "switch", "result"),
                   "switch": ("switch", "state", "result"), "state": ("turn", "result")}
        if stage not in allowed.get(self.last_stage, ()):
            return "battle_stage", None
        if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
            return "battle_digest", None
        owner = self.players.index(player) * 2
        if stage == "turn":
            if (not isinstance(command, list) or len(command) != 3 or
                    any(type(x) is not int for x in command[1:])):
                return "battle_command", None
            action, index, target = command
            if not ((action == "move" and -1 <= index <= 3 and -1 <= target <= 3) or
                    (action == "switch" and index in (owner, owner + 1) and target == -1) or
                    (action == "none" and index == 0 and target == -1)):
                return "battle_command", None
        elif stage == "enemy":
            if owner == 0:
                if not isinstance(command, list) or len(command) != 2:
                    return "battle_command", None
                for order in command:
                    if (not isinstance(order, list) or len(order) != 3 or
                            any(type(x) is not int for x in order[1:]) or
                            not ((order[0] == "move" and -1 <= order[1] <= 3 and -1 <= order[2] <= 3) or
                                 (order == ["none", 0, -1]))):
                        return "battle_command", None
            elif command is not None:
                return "battle_command", None
        elif stage == "switch":
            if (not isinstance(command, list) or len(command) != 2 or
                    any(type(x) is not int for x in command) or
                    command[0] not in (0, 2) or
                    (command[0] == owner and command[1] not in (owner, owner + 1)) or
                    (command[0] != owner and command[1] != -1)):
                return "battle_command", None
        elif command is not None:
            return "battle_command", None
        if self.pending:
            first = next(iter(self.pending.values()))
            if stage != first["stage"] or digest != first["digest"]:
                return "battle_desync", None
            if stage == "switch" and command[0] != first["command"][0]:
                return "battle_desync", None
        self.pending[player] = {"stage": stage, "digest": digest, "command": command}
        if len(self.pending) < 2:
            return None, None
        packet = {"type": "battle_step", "battle": self.id, "seq": self.seq,
                  "stage": stage, "digest": digest,
                  "commands": [self.pending[p]["command"] for p in self.players],
                  "seed": secrets.randbelow(2**30)}
        self.seq += 1
        self.last_stage = stage
        self.pending.clear()
        self.deadline = time.monotonic() + 180
        return None, packet
