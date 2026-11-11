"""Authoritative room speed and reconnect behavior; no game files involved."""
import json
import unittest

from src.server.session_server import State
from src.server.coop_battle import BattleExchange


class Peer:
    def __init__(self):
        self.messages = []

    def sendall(self, data):
        self.messages.append(json.loads(data))


class SharedSpeedTests(unittest.TestCase):
    def setUp(self):
        self.state = State()
        self.host, self.guest = Peer(), Peer()
        self.welcome_host, self.host_id = self.state.handle(
            self.host, {"type": "create", "session": "SPEED1", "name": "host"}, None)

    def join(self):
        return self.state.handle(self.guest,
                                 {"type": "join", "session": "SPEED1", "name": "guest"}, None)

    def test_host_only_and_three_stages(self):
        welcome, guest_id = self.join()
        self.assertEqual((welcome["host"], welcome["speed"], welcome["speed_active"]),
                         (self.welcome_host["id"], 0, True))
        self.assertEqual(self.host.messages[-1]["type"], "enter")
        self.assertTrue(self.host.messages[-1]["speed_active"])
        for stage in (1, 2, 0):
            response, _ = self.state.handle(self.host, {"type": "speed_set", "speed": stage}, self.host_id)
            self.assertIsNone(response)
            self.assertEqual(self.guest.messages[-1]["speed"], stage)
        response, _ = self.state.handle(self.guest, {"type": "speed_set", "speed": 2}, guest_id)
        self.assertEqual(response["reason"], "speed_not_host")
        self.assertEqual(self.state.rooms["SPEED1"]["speed"], 0)
        for invalid in (True, -1, 3, 2.5, "2"):
            response, _ = self.state.handle(self.host, {"type": "speed_set", "speed": invalid}, self.host_id)
            self.assertEqual(response["reason"], "invalid_speed")

    def test_new_guest_receives_current_speed_and_disconnect_releases_control(self):
        self.state.handle(self.host, {"type": "speed_set", "speed": 2}, self.host_id)
        welcome, guest_id = self.join()
        self.assertEqual((welcome["speed"], welcome["speed_active"]), (2, True))
        self.state.disconnect(guest_id, self.guest)
        self.assertEqual(self.host.messages[-1]["type"], "leave")
        self.assertFalse(self.host.messages[-1]["speed_active"])
        self.state.disconnect(self.host_id, self.host)
        self.assertFalse(self.state.rooms["SPEED1"]["members"][self.host_id[1]]["sock"])
        resumed, _ = self.state.handle(Peer(), {"type": "join", "session": "SPEED1",
                                                 "name": "host", "resume": self.welcome_host["resume"]}, None)
        self.assertEqual((resumed["host"], resumed["speed"]), (self.welcome_host["id"], 2))

    def test_server_rejects_speed_change_during_coop_battle(self):
        welcome, _ = self.join()
        room = self.state.rooms["SPEED1"]
        room["trainers"]["fixture"] = {"battle": BattleExchange(
            [self.welcome_host["id"], welcome["id"]])}
        response, _ = self.state.handle(self.host, {"type": "speed_set", "speed": 2}, self.host_id)
        self.assertEqual(response["reason"], "speed_battle_locked")
        self.assertEqual(room["speed"], 0)


if __name__ == "__main__":
    unittest.main()
