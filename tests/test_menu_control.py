import json
import socket
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from menu_control import ControlServer, MenuControl, ROOM_ALPHABET, room_secret


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class MenuControlTests(unittest.TestCase):
    def test_room_code_is_validated_and_secret_is_stable(self):
        self.assertEqual(room_secret("ABCD2345EFGH"), room_secret("ABCD2345EFGH"))
        self.assertNotEqual(room_secret("ABCD2345EFGH"), room_secret("ABCD2345EFGJ"))
        control = MenuControl(ROOT)
        with self.assertRaises(ValueError):
            control.start("join", "8.8.8.8", "ABCD2345EFGH")
        with self.assertRaises(ValueError):
            control.start("join", "127.0.0.1", "short")
        from src.server.session_server import private_bind
        self.assertTrue(private_bind("25.42.12.9"))

    def test_loopback_menu_creates_room_and_guest_authenticates(self):
        import threading
        port = free_port()
        host = MenuControl(ROOT, server_port=port)
        guest = MenuControl(ROOT, server_port=port)
        host_api = ControlServer(host)
        guest_api = ControlServer(guest)
        threads = [threading.Thread(target=api.serve_forever, daemon=True) for api in (host_api, guest_api)]
        for thread in threads:
            thread.start()

        def request(api, op, **values):
            with socket.create_connection(api.server_address) as sock:
                sock.sendall((json.dumps({"token": api.token, "op": op, **values}) + "\n").encode())
                return json.loads(sock.makefile("rb").readline())

        try:
            created = request(host_api, "create", host="127.0.0.1")
            self.assertTrue(created["ok"])
            self.assertEqual(len(created["code"]), 12)
            self.assertTrue(set(created["code"]) <= set(ROOM_ALPHABET))
            joined = request(guest_api, "join", host="127.0.0.1", code=created["code"])
            self.assertTrue(joined["ok"])
            self.assertNotEqual(created["port"], joined["port"])
            self.assertEqual(request(host_api, "status")["session"]["code"], created["code"])
            with socket.create_connection(("127.0.0.1", created["port"])) as sock:
                sock.settimeout(5)
                file = sock.makefile("rb")
                hello = {"type": "create", "session": created["code"], "name": "Host"}
                sock.sendall((json.dumps(hello) + "\n").encode())
                self.assertEqual(json.loads(file.readline())["type"], "welcome")
            self.assertTrue(request(host_api, "stop")["ok"])
            self.assertIsNone(request(host_api, "status")["session"])
        finally:
            for api in (guest_api, host_api):
                api.close()
            for thread in threads:
                thread.join()


if __name__ == "__main__":
    unittest.main()
