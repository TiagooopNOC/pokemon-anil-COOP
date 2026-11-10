import json
import socket
import threading
import unittest

from src.server.session_server import Server, Handler, State, proof, private_bind
from src.client.bridge import Bridge
import src.server.session_server as module


class SessionServerTests(unittest.TestCase):
    def setUp(self):
        module.STATE = State()
        self.server = Server(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.sockets = []
        self.challenges = {}

    def tearDown(self):
        for sock in self.sockets:
            sock.close()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def client(self):
        sock = socket.create_connection(self.server.server_address)
        sock.settimeout(2)
        self.sockets.append(sock)
        self.challenges[sock] = self.receive(sock)["nonce"]
        return sock

    @staticmethod
    def receive(sock):
        line = b""
        while not line.endswith(b"\n"):
            line += sock.recv(1)
        return json.loads(line)

    def exchange(self, sock, payload):
        if payload.get("type") in ("create", "join"):
            payload = dict(payload, proof=proof(module.LOCAL_SECRET, self.challenges[sock], payload))
        sock.sendall((json.dumps(payload) + "\n").encode())
        return self.receive(sock)

    def test_create_join_four_limit_and_reconnect(self):
        clients = [self.client() for _ in range(5)]
        first = self.exchange(clients[0], {"type": "create", "session": "ABC123", "name": "one"})
        self.assertEqual(first["slot"], 1)
        for i in range(1, 4):
            result = self.exchange(clients[i], {"type": "join", "session": "ABC123", "name": f"p{i}"})
            self.assertEqual(result["slot"], i + 1)
        refusal = self.exchange(clients[4], {"type": "join", "session": "ABC123", "name": "fifth"})
        self.assertEqual(refusal["reason"], "session_full")
        self.assertEqual(len({p["token"] for p in module.STATE.rooms["ABC123"]["members"].values()}), 4)
        clients[0].close()
        for _ in range(100):
            if module.STATE.rooms["ABC123"]["members"][first["id"]]["sock"] is None:
                break
            threading.Event().wait(.01)
        resumed = self.exchange(self.client(), {"type": "join", "session": "ABC123", "name": "one", "resume": first["resume"]})
        self.assertEqual((resumed["id"], resumed["slot"]), (first["id"], 1))

    def test_position_validation_and_delivery(self):
        a, b = self.client(), self.client()
        first = self.exchange(a, {"type": "create", "session": "ABC123", "name": "one"})
        self.exchange(b, {"type": "join", "session": "ABC123", "name": "two"})
        # Consume enter notification on the first connection.
        self.assertEqual(self.receive(a)["type"], "enter")
        valid = {"type": "position", "map": 1, "x": 4, "y": 5,
                 "direction": 2, "pattern": 1, "speed": 3.5, "seq": 0, "sprite": "trainer"}
        a.sendall((json.dumps(valid) + "\n").encode())
        packet = self.receive(b)
        self.assertEqual(packet["player"]["id"], first["id"])
        self.assertEqual(packet["player"]["position"]["x"], 4)
        self.assertEqual(packet["player"]["position"]["speed"], 3.5)
        self.assertEqual(self.exchange(a, dict(valid, seq=1, speed=None))["reason"], "invalid_position")
        legacy = dict(valid, seq=1, x=5)
        del legacy["speed"]
        a.sendall((json.dumps(legacy) + "\n").encode())
        self.assertEqual(self.receive(b)["player"]["position"]["speed"], 4)
        invalid = dict(valid, seq=2, x=True)
        self.assertEqual(self.exchange(a, invalid)["reason"], "invalid_position")
        for bad_speed in (True, 0, 9, float("inf"), "4"):
            self.assertEqual(self.exchange(a, dict(valid, seq=2, speed=bad_speed))["reason"],
                             "invalid_position")
        self.assertEqual(self.exchange(a, {"type": "position", "map": 1})["reason"], "invalid_position")

    def test_ordered_steps_and_warp_validation(self):
        sender, observer = self.client(), self.client()
        self.exchange(sender, {"type": "create", "session": "STEP01", "name": "one"})
        self.exchange(observer, {"type": "join", "session": "STEP01", "name": "two"})
        self.receive(sender)  # enter
        base = {"type": "position", "map": 1, "x": 10, "y": 10,
                "direction": 6, "pattern": 0, "speed": 5.5, "seq": 0,
                "sprite": "trainer", "steps": [], "warp": True}
        sender.sendall((json.dumps(base) + "\n").encode())
        self.assertEqual(self.receive(observer)["player"]["position"]["x"], 10)
        turn = dict(base, x=12, y=11, seq=1, steps=[6, 6, 2], warp=False, direction=2)
        sender.sendall((json.dumps(turn) + "\n").encode())
        received = self.receive(observer)["player"]["position"]
        self.assertEqual(received["steps"], [6, 6, 2])
        self.assertEqual((received["x"], received["y"], received["speed"]), (12, 11, 5.5))
        self.assertEqual(self.exchange(sender, dict(turn, seq=2, x=13, steps=[2]))["reason"], "invalid_position")
        self.assertEqual(self.exchange(sender, dict(turn, seq=2, steps=[6, 3, 2]))["reason"], "invalid_position")
        self.assertEqual(self.exchange(sender, dict(turn, seq=2, steps=[6], warp=True))["reason"], "invalid_position")

    def test_follower_presence_and_ordered_steps(self):
        sender, observer = self.client(), self.client()
        self.exchange(sender, {"type": "create", "session": "FOLL01", "name": "one"})
        self.exchange(observer, {"type": "join", "session": "FOLL01", "name": "two"})
        self.receive(sender)
        base = {"type": "position", "map": 1, "x": 10, "y": 10,
                "direction": 6, "pattern": 0, "speed": 4, "seq": 0,
                "sprite": "trainer", "steps": [], "warp": True}
        follower = {"map": 1, "x": 9, "y": 10, "direction": 6, "pattern": 0,
                    "speed": 4, "seq": 0, "sprite": "Followers/BULBASAUR.png",
                    "hue": 0, "steps": [], "warp": True}
        sender.sendall((json.dumps(dict(base, follower=follower)) + "\n").encode())
        self.assertEqual(self.receive(observer)["player"]["position"]["follower"]["sprite"],
                         "Followers/BULBASAUR.png")
        moved = dict(follower, x=10, seq=1, steps=[6], warp=False)
        sender.sendall((json.dumps(dict(base, x=11, seq=1, steps=[6], warp=False,
                                        follower=moved)) + "\n").encode())
        self.assertEqual(self.receive(observer)["player"]["position"]["follower"]["steps"], [6])
        bad = dict(base, seq=2, x=11, steps=[], warp=False)
        self.assertEqual(self.exchange(sender, dict(bad, follower=dict(moved, seq=2, x=12, steps=[2])))["reason"],
                         "invalid_follower")
        self.assertEqual(self.exchange(sender, dict(bad, follower=dict(moved, seq=2,
                         sprite="../Game.exe", steps=[], warp=True)))["reason"], "invalid_follower")
        self.assertEqual(self.exchange(sender, dict(bad, follower=dict(moved, seq=2,
                         extra="unneeded")))["reason"], "invalid_follower")
        sender.sendall((json.dumps(dict(bad, follower=None)) + "\n").encode())
        self.assertIsNone(self.receive(observer)["player"]["position"]["follower"])

    def test_auth_and_private_binding(self):
        self.assertTrue(private_bind("127.0.0.1"))
        self.assertTrue(private_bind("192.168.1.10"))
        self.assertTrue(private_bind("100.101.10.5"))
        self.assertTrue(private_bind("25.101.10.5"))  # Hamachi virtual IPv4
        self.assertFalse(private_bind("0.0.0.0"))
        self.assertFalse(private_bind("8.8.8.8"))
        self.assertFalse(private_bind("fc00::1"))
        with self.assertRaises(ValueError):
            Bridge("8.8.8.8", 17641, module.LOCAL_SECRET)
        sock = self.client()
        sock.sendall(b'{"type":"create","session":"ABC123","name":"one","proof":"bad"}\n')
        self.assertEqual(self.receive(sock)["reason"], "auth_failed")
        self.assertFalse(module.STATE.rooms)

    def test_bridge_authenticates_without_exposing_secret_to_game(self):
        bridge = Bridge("127.0.0.1", self.server.server_address[1], module.LOCAL_SECRET)
        self.addCleanup(bridge.close)
        game = socket.create_connection(("127.0.0.1", bridge.port))
        self.sockets.append(game)
        game.sendall(b'{"type":"create","session":"BRIDGE1","name":"host"}\n')
        welcome = self.receive(game)
        self.assertEqual(welcome["type"], "welcome")
        self.assertEqual(welcome["slot"], 1)
        game.sendall(b'{"type":"position","map":28,"x":2,"y":3,"direction":2,"pattern":0,"seq":0,"sprite":"trainer"}\n')
        for _ in range(50):
            if module.STATE.rooms["BRIDGE1"]["members"][welcome["id"]]["position"]:
                break
            threading.Event().wait(.01)
        self.assertEqual(module.STATE.rooms["BRIDGE1"]["members"][welcome["id"]]["position"]["x"], 2)

    def test_bridge_rejects_wrong_shared_secret(self):
        bridge = Bridge("127.0.0.1", self.server.server_address[1], "wrong-secret-for-test")
        self.addCleanup(bridge.close)
        game = socket.create_connection(("127.0.0.1", bridge.port))
        self.sockets.append(game)
        game.settimeout(2)
        game.sendall(b'{"type":"create","session":"BRIDGE2","name":"host"}\n')
        self.assertEqual(self.receive(game)["reason"], "auth_failed")
        self.assertNotIn("BRIDGE2", module.STATE.rooms)

    def test_trainer_wait_ready_forced_and_solo_lock(self):
        a, b = self.client(), self.client()
        host = self.exchange(a, {"type": "create", "session": "TRAIN01", "name": "host"})
        guest = self.exchange(b, {"type": "join", "session": "TRAIN01", "name": "guest"})
        self.receive(a)
        pos = {"type": "position", "map": 28, "x": 5, "y": 5, "direction": 2,
               "pattern": 0, "seq": 0, "sprite": "trainer"}
        a.sendall((json.dumps(pos) + "\n").encode())
        self.receive(b)
        b.sendall((json.dumps(pos) + "\n").encode())
        self.receive(a)
        wait = {"type": "trainer_wait", "map": 28, "event": 10, "forced": True}
        state = self.exchange(a, wait)
        self.assertEqual((state["host"], state["phase"]), (host["id"], "pending"))
        self.receive(b)
        self.assertEqual(self.exchange(a, {"type": "trainer_cancel", "map": 28, "event": 10})["reason"], "trainer_forced")
        self.assertEqual(self.exchange(b, dict(wait, forced=False))["participants"][-1]["id"], guest["id"])
        self.receive(a)
        state = self.exchange(b, {"type": "trainer_ready", "map": 28, "event": 10, "ready": True})
        self.assertTrue(state["participants"][-1]["ready"])
        self.receive(a)
        self.assertEqual(self.exchange(a, {"type": "trainer_start", "map": 28, "event": 10, "solo": False})["reason"], "coop_battle_pending")
        locked = self.exchange(a, {"type": "trainer_start", "map": 28, "event": 10, "solo": True})
        self.assertEqual((locked["phase"], len(locked["participants"])), ("locked", 1))
        self.assertEqual(self.receive(b)["phase"], "locked")
        self.assertEqual(self.exchange(b, wait)["reason"], "trainer_locked")
        self.assertEqual(self.exchange(a, {"type": "trainer_finish", "map": 28, "event": 10})["type"], "trainer_closed")


if __name__ == "__main__":
    unittest.main()
