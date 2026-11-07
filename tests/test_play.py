import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from play import game_command, validate_connection
from h0 import SafetyError


class PlayLauncherTests(unittest.TestCase):
    def test_windows_uses_native_client_and_no_test_npc(self):
        command = game_command("nt", "client01", "192.168.1.9", 17641, "FRIEND1", "join")
        self.assertTrue(any(arg.endswith("windows_network.py") for arg in command))
        self.assertIn("--coop-battles", command)
        self.assertNotIn("--qa-2v2", command)
        self.assertNotIn("--play", command)
        self.assertIn("vendor", command[command.index("--gameslot") + 1])

    def test_linux_play_has_no_ten_minute_deadline(self):
        host = game_command("posix", "client03", "192.168.1.9", 17641, "FRIEND1", "create")
        guest = game_command("posix", "client04", "192.168.1.9", 17641, "FRIEND1", "join")
        self.assertIn("--play", host)
        self.assertIn("--host-client", host)
        self.assertNotIn("--host-client", guest)
        self.assertNotIn("--qa-battle-bot", host)

    def test_public_and_invalid_connection_settings_fail(self):
        validate_connection("192.168.1.9", 17641, "FRIEND1")
        for address in ("8.8.8.8", "0.0.0.0"):
            with self.assertRaises(SafetyError):
                validate_connection(address, 17641, "FRIEND1")
        for session in ("a", "a" * 13, "ábcdef", "abc def"):
            with self.assertRaises(SafetyError):
                validate_connection("192.168.1.9", 17641, session)
