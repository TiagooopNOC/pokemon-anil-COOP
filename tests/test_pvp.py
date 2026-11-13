"""PvP invitation ownership and Singles synchronization."""
import unittest

from src.server.pvp import Duel, PROTOTYPE
from src.server.session_server import State


class Peer:
    def __init__(self):
        self.packets = []

    def sendall(self, data):
        import json
        self.packets.append(json.loads(data))


class DuelTests(unittest.TestCase):
    def test_invitation_starts_duel_only_after_negotiated_acceptance(self):
        state = State()
        host, guest = Peer(), Peer()
        _, host_id = state.handle(host, {"type": "create", "name": "Host", "session": "TEST01"}, None)
        _, guest_id = state.handle(guest, {"type": "join", "name": "Guest", "session": "TEST01"}, None)
        for request, accept in (("a" * 16, False), ("b" * 16, True)):
            state.handle(host, {"type": "invite_request", "request": request, "target": guest_id[1],
                                "kind": "pvp", "pvp": PROTOTYPE}, host_id)
            state.handle(guest, {"type": "invite_reply", "request": request, "accept": accept,
                                 "pvp": PROTOTYPE}, guest_id)
            self.assertEqual(len(state.rooms["TEST01"]["duels"]), int(accept))
        duel = next(iter(state.rooms["TEST01"]["duels"].values()))
        self.assertEqual(host.packets[-1], guest.packets[-1])
        self.assertEqual(host.packets[-1]["type"], "pvp_prepare")
        state.disconnect(guest_id, guest)
        self.assertFalse(state.rooms["TEST01"]["duels"])
        self.assertIn({"type": "battle_abort", "battle": duel.id, "reason": "battle_disconnect"},
                      host.packets)

    def test_orders_are_owned_and_mirrored_in_canonical_sequence(self):
        duel = Duel(["a", "b"])
        duel.teams = {"a": {"team": [{}]}, "b": {"team": [{}, {}]}}

        def step(player, stage, order=None, digest="0" * 64):
            return duel.submit(player, {"battle": duel.id, "seq": duel.seq, "stage": stage,
                                        "digest": digest, "command": order})

        self.assertEqual(step("other", "setup"), ("battle_not_participant", None))
        self.assertEqual(step("a", "setup"), (None, None))
        self.assertEqual(step("b", "setup")[1]["stage"], "setup")
        self.assertEqual(step("a", "turn", ["switch", 1, -1]), ("battle_command", None))
        self.assertEqual(step("b", "turn", ["switch", 1, -1]), (None, None))
        self.assertEqual(step("b", "turn", ["move", 0, -1]), ("battle_duplicate", None))
        self.assertEqual(step("a", "turn", ["move", 0, 1])[1]["commands"],
                         [["move", 0, 1], ["switch", 1, -1]])
        self.assertEqual(step("a", "switch", [1, 0]), ("battle_command", None))
        self.assertEqual(step("a", "switch", [1, -1]), (None, None))
        self.assertEqual(step("b", "switch", [1, 0])[1]["stage"], "switch")
        self.assertEqual(step("a", "state"), (None, None))
        self.assertEqual(step("b", "state", digest="1" * 64), ("battle_desync", None))
