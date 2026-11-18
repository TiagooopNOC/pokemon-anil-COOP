"""Validated, session-only trade negotiation. This module never commits a transfer."""
import secrets
import time

if __package__:
    from .coop_battle import validate_view_team
else:
    from coop_battle import validate_view_team


class TradePreview:
    def __init__(self, players, transfer_enabled=False):
        self.id = secrets.token_hex(16)
        self.players = tuple(players)
        self.offers = {}
        self.confirmed = set()
        self.version = 0
        self.updated = time.monotonic()
        self.transfer_enabled = transfer_enabled
        self.phase = "choosing"
        self.payloads = {}

    def state(self, phase=None):
        phase = phase or self.phase
        packet = {"type": "trade_state", "trade": self.id, "phase": phase,
                "players": list(self.players), "version": self.version,
                "offers": self.offers.copy(), "confirmed": list(self.confirmed),
                "transfer_enabled": self.transfer_enabled}
        if phase in ("preparing", "commit", "complete"):
            packet["payloads"] = self.payloads.copy()
        return packet

    def offer(self, player, snapshot):
        if self.phase != "choosing" or player not in self.players or not validate_view_team([snapshot]):
            return False
        if snapshot["egg_steps"] or not snapshot["moves"]:
            return False
        if self.offers.get(player) != snapshot:
            self.offers[player] = snapshot
            self.confirmed.clear()
            self.version += 1
        self.updated = time.monotonic()
        return True

    def confirm(self, player, version):
        if (self.phase != "choosing" or player not in self.players or type(version) is not int or
                version != self.version or len(self.offers) != 2):
            return None
        self.confirmed.add(player)
        self.updated = time.monotonic()
        complete = len(self.confirmed) == 2
        if complete and self.transfer_enabled:
            self.phase = "payloads"
        return complete

    def payload(self, player, data):
        if self.phase != "payloads" or player not in self.players:
            return False
        preview = self.offers[player]
        if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("effective"), dict):
            return False
        record = data.get("pokemon")
        if not isinstance(record, dict) or record.get("class") != "Pokemon" or not isinstance(record.get("fields"), dict):
            return False
        fields = record["fields"]
        owner = fields.get("owner")
        if not isinstance(owner, dict) or owner.get("class") != "Owner" or not isinstance(owner.get("fields"), dict):
            return False
        effective_form = fields.get("forced_form") if fields.get("forced_form") is not None else fields.get("form")
        if (fields.get("personalID") != preview["pid"] or
                fields.get("species") != {"symbol": preview["species"]} or
                effective_form != preview["form"] or
                owner["fields"].get("id") != preview["owner"]["id"] or
                data["effective"].get("types") != preview["types"] or
                data["effective"].get("base_stats") != preview["base_stats"]):
            return False
        if player in self.payloads and self.payloads[player] != data:
            return False
        self.payloads[player] = data
        self.updated = time.monotonic()
        return True
