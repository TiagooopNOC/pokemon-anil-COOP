import json
import socket
import threading
import unittest

from src.server.session_server import Server, Handler, State
import src.server.session_server as module


class SessionServerTests(unittest.TestCase):
    def setUp(self):
        module.STATE = State()
        self.server = Server(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.sockets = []

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
        return sock

    @staticmethod
    def receive(sock):
        line = b""
        while not line.endswith(b"\n"):
            line += sock.recv(1)
        return json.loads(line)

    @classmethod
    def exchange(cls, sock, payload):
        sock.sendall((json.dumps(payload) + "\n").encode())
        return cls.receive(sock)

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
        resumed = self.exchange(clients[4], {"type": "join", "session": "ABC123", "name": "one", "resume": first["resume"]})
        self.assertEqual((resumed["id"], resumed["slot"]), (first["id"], 1))

    def test_position_validation_and_delivery(self):
        a, b = self.client(), self.client()
        first = self.exchange(a, {"type": "create", "session": "ABC123", "name": "one"})
        self.exchange(b, {"type": "join", "session": "ABC123", "name": "two"})
        # Consume enter notification on the first connection.
        self.assertEqual(self.receive(a)["type"], "enter")
        valid = {"type": "position", "map": 1, "x": 4, "y": 5,
                 "direction": 2, "pattern": 1, "seq": 0, "sprite": "trainer"}
        a.sendall((json.dumps(valid) + "\n").encode())
        packet = self.receive(b)
        self.assertEqual(packet["player"]["id"], first["id"])
        self.assertEqual(packet["player"]["position"]["x"], 4)
        invalid = dict(valid, seq=1, x=True)
        self.assertEqual(self.exchange(a, invalid)["reason"], "invalid_position")
        self.assertEqual(self.exchange(a, {"type": "position", "map": 1})["reason"], "invalid_position")


if __name__ == "__main__":
    unittest.main()
