"""Validated, session-only trade negotiation. This module never commits a transfer."""
import secrets
import time

if __package__:
    from .coop_battle import validate_view_team
else:
    from coop_battle import validate_view_team


class TradePreview:
    def __init__(self, players):
        self.id = secrets.token_hex(16)
        self.players = tuple(players)
        self.offers = {}
        self.confirmed = set()
        self.version = 0
        self.updated = time.monotonic()

    def state(self, phase="choosing"):
        return {"type": "trade_state", "trade": self.id, "phase": phase,
                "players": list(self.players), "version": self.version,
                "offers": self.offers.copy(), "confirmed": list(self.confirmed),
                "transfer_enabled": False}

    def offer(self, player, snapshot):
        if player not in self.players or not validate_view_team([snapshot]):
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
        if (player not in self.players or type(version) is not int or
                version != self.version or len(self.offers) != 2):
            return None
        self.confirmed.add(player)
        self.updated = time.monotonic()
        return len(self.confirmed) == 2
