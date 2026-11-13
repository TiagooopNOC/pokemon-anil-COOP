"""Singles preparation and synchronized barriers for two opposing humans."""
import time

if __package__:
    from .coop_battle import BattleExchange, DIGEST, validate_team, validate_trainer
else:
    from coop_battle import BattleExchange, DIGEST, validate_team, validate_trainer


PROTOTYPE = "singles-v1"


class Duel(BattleExchange):
    def __init__(self, players):
        super().__init__(players)
        self.teams = {}

    def ready(self, player, message):
        if player not in self.players:
            return "battle_not_participant", None
        team, trainer = message.get("team"), message.get("trainer")
        if player in self.teams or not validate_team(team, 6) or not validate_trainer(trainer):
            return "battle_invalid_team", None
        self.teams[player] = {"team": team, "trainer": trainer}
        if len(self.teams) == 2:
            return None, {"type": "pvp_start", "battle": self.id, "seed": self.seed,
                          "players": list(self.players), "teams": [self.teams[p] for p in self.players]}
        return None, None

    def submit(self, player, message):
        if player not in self.players or message.get("battle") != self.id:
            return "battle_not_participant", None
        stage, digest, order = (message.get(key) for key in ("stage", "digest", "command"))
        if len(self.teams) != 2 or type(message.get("seq")) is not int or message["seq"] != self.seq:
            return "battle_sequence", None
        if player in self.pending:
            return "battle_duplicate", None
        allowed = {None: ("setup",), "setup": ("turn", "switch"), "turn": ("switch", "state", "result"),
                   "switch": ("switch", "turn", "state", "result"), "state": ("turn", "result")}
        if stage not in allowed.get(self.last_stage, ()) or not isinstance(digest, str) or not DIGEST.fullmatch(digest):
            return "battle_stage", None
        if not self.valid_order(player, stage, order):
            return "battle_command", None
        self.last_attempt[self.players.index(player)] = {
            "seq": self.seq, "stage": stage, "action": self.action_kind(order),
            "at": time.monotonic()}
        if self.pending:
            other = next(iter(self.pending.values()))
            if (stage, digest) != (other["stage"], other["digest"]) or (
                    stage == "switch" and order[0] != other["command"][0]):
                return "battle_desync", None
        self.pending[player] = {"stage": stage, "digest": digest, "command": order}
        if len(self.pending) == 1:
            return None, None
        return None, self.complete(stage, digest)

    def valid_order(self, player, stage, order):
        owner = self.players.index(player)
        size = len(self.teams[player]["team"])
        if stage == "switch":
            return (isinstance(order, list) and len(order) == 2 and
                    all(type(v) is int for v in order) and order[0] in (0, 1) and
                    (-1 <= order[1] < size if order[0] == owner else order[1] == -1))
        if stage != "turn":
            return order is None
        if not isinstance(order, list) or len(order) != 3 or any(type(v) is not int for v in order[1:]):
            return False
        action, slot, target = order
        return ((action == "move" and -1 <= slot <= 3 and -1 <= target <= 1) or
                (action == "switch" and 0 <= slot < size and target == -1) or
                order in (["none", 0, -1], ["forfeit", 0, -1]))
