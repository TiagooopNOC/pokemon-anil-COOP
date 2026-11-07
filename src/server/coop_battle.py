"""Bounded, non-persistent two-player QA battle barrier. No game objects on wire."""
import re
import secrets
import time

PROTOTYPE = "qa2v2-v1"
PERSONAL_PROTOTYPE = "personal2v2-v1"
DIGEST = re.compile(r"[a-f0-9]{64}\Z")
DATA_ID = re.compile(r"[A-Za-z0-9_]{1,40}\Z")
SNAPSHOT_KEYS = frozenset(("key", "slot", "species", "name", "level", "exp", "form", "pid",
                         "owner", "gender", "shiny", "super_shiny", "ability", "nature",
                         "nature_stats", "item", "moves", "iv", "ev", "maxed", "stats",
                         "base_stats", "types", "hp", "status", "status_count", "happiness",
                         "pokerus", "ball"))


def _integer(value, low, high):
    return type(value) is int and low <= value <= high


def _text(value):
    return isinstance(value, str) and 1 <= len(value) <= 40 and all(ord(c) >= 32 for c in value)


def _data_id(value):
    return isinstance(value, str) and DATA_ID.fullmatch(value) is not None


def validate_trainer(trainer):
    return (isinstance(trainer, dict) and
            trainer.keys() == {"id", "name", "gender", "language", "trainer_type"} and
            _integer(trainer["id"], 0, 2**32 - 1) and _text(trainer["name"]) and
            _integer(trainer["gender"], 0, 2) and _integer(trainer["language"], 0, 20) and
            _data_id(trainer["trainer_type"]))


def validate_team(team, max_size=3):
    """Validate only primitive snapshots, never deserialize executable game objects.

    All fields, nesting and collection sizes are bounded. Clients also resolve
    game-data IDs and verify reconstructed effective stats before the setup barrier.
    """
    if not isinstance(team, list) or not 1 <= len(team) <= max_size:
        return False
    keys, slots = set(), set()
    for pokemon in team:
        if not isinstance(pokemon, dict) or pokemon.keys() != SNAPSHOT_KEYS:
            return False
        owner = pokemon["owner"]
        if (not isinstance(owner, dict) or owner.keys() != {"id", "name", "gender", "language"} or
                not _integer(owner["id"], 0, 2**32 - 1) or not _text(owner["name"]) or
                not _integer(owner["gender"], 0, 2) or not _integer(owner["language"], 0, 20)):
            return False
        if not _integer(pokemon["pid"], 0, 2**32 - 1):
            return False
        key, slot = pokemon["key"], pokemon["slot"]
        if (key != f'{owner["id"]}:{pokemon["pid"]}' or key in keys or
                not _integer(slot, 0, 5) or slot in slots):
            return False
        keys.add(key)
        slots.add(slot)
        if not _text(pokemon["name"]):
            return False
        for field in ("species", "ability", "nature", "nature_stats", "status", "ball"):
            if not _data_id(pokemon[field]):
                return False
        if pokemon["item"] is not None and not _data_id(pokemon["item"]):
            return False
        for field, low, high in (("level", 1, 100), ("exp", 0, 100000000), ("form", 0, 999),
                                 ("gender", 0, 2), ("hp", 1, 65535), ("status_count", 0, 100),
                                 ("happiness", 0, 255), ("pokerus", 0, 255)):
            if not _integer(pokemon[field], low, high):
                return False
        if any(type(pokemon[field]) is not bool for field in ("shiny", "super_shiny")):
            return False
        for field, low, high in (("iv", 0, 31), ("ev", 0, 252),
                                 ("stats", 1, 65535), ("base_stats", 1, 65535)):
            array = pokemon[field]
            if (not isinstance(array, list) or len(array) != 6 or
                    any(not _integer(value, low, high) for value in array)):
                return False
        if pokemon["hp"] > pokemon["stats"][0]:
            return False
        if (not isinstance(pokemon["maxed"], list) or len(pokemon["maxed"]) != 6 or
                any(type(value) is not bool for value in pokemon["maxed"])):
            return False
        if (not isinstance(pokemon["types"], list) or not 1 <= len(pokemon["types"]) <= 3 or
                any(not _data_id(value) for value in pokemon["types"])):
            return False
        moves = pokemon["moves"]
        if not isinstance(moves, list) or not 1 <= len(moves) <= 4:
            return False
        for move in moves:
            if (not isinstance(move, list) or len(move) != 3 or not _data_id(move[0]) or
                    not _integer(move[1], 0, 255) or not _integer(move[2], 0, 3)):
                return False
    return True


class BattleExchange:
    def __init__(self, players, team_sizes=(2, 2)):
        if (len(players) != 2 or len(set(players)) != 2 or len(team_sizes) != 2 or
                any(type(size) is not int or not 1 <= size <= 3 for size in team_sizes)):
            raise ValueError("two distinct players with 1–3 selected Pokemon each required")
        self.id = secrets.token_hex(16)
        self.players = tuple(players)  # canonical ally battlers 0 and 2
        self.team_sizes = tuple(team_sizes)
        self.party_ranges = (range(team_sizes[0]), range(team_sizes[0], sum(team_sizes)))
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
        owner_number = self.players.index(player)
        owner = owner_number * 2
        owned_party = self.party_ranges[owner_number]
        if stage == "turn":
            if (not isinstance(command, list) or len(command) != 3 or
                    any(type(x) is not int for x in command[1:])):
                return "battle_command", None
            action, index, target = command
            if not ((action == "move" and -1 <= index <= 3 and -1 <= target <= 3) or
                    (action == "switch" and index in owned_party and target == -1) or
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
                    (command[0] == owner and command[1] not in owned_party) or
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
