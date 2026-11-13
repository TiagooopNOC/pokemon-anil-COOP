"""Launcher publication and recovery tests using disposable game files."""
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from tools import h0, windows_install
from tools.install_presence import GAME_SCRIPTS


@unittest.skipUnless(os.name == "nt", "uses the Windows setup lock")
class WindowsInstallTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        self.source, self.data, self.assets = (root / name for name in ("original", "data", "assets"))
        self.source.mkdir()
        (self.source / "mkxp.json").write_text("{}")
        (self.source / "Game.exe").write_bytes(b"fixture")
        (self.source / "Partida 1.rxdata").write_bytes(b"original save")
        h0.write_new(self.assets / "config/build.json", {"critical": {
            name: h0.digest(self.source / name) for name in ("mkxp.json", "Game.exe")}})
        (self.assets / "src/bootstrap").mkdir(parents=True)
        (self.assets / "src/game").mkdir()
        shutil.copy2(h0.ROOT / "src/bootstrap/isolate.rb", self.assets / "src/bootstrap")
        for name in GAME_SCRIPTS:
            shutil.copy2(h0.ROOT / "src/game" / name, self.assets / "src/game")

    def install(self, **options):
        return windows_install.install(self.data, self.assets, self.source, **options)

    def test_invalid_source_leaves_no_published_workspace_and_can_retry(self):
        (self.source / "Game.exe").write_bytes(b"wrong version")
        with self.assertRaisesRegex(h0.SafetyError, "Unsupported/changed"):
            self.install()
        self.assertIsNone(windows_install.installed_client(self.data, self.assets))
        (self.source / "Game.exe").write_bytes(b"fixture")
        self.assertEqual(self.install(), "client01")

    def test_recovery_publishes_verified_copy_and_reports_files(self):
        before = h0.snapshot(self.source)
        events = []

        def interrupt(phase, done=0, total=0):
            if phase == "copying" and done == 1:
                raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            self.install(progress=interrupt)
        self.assertTrue((self.data / "setup-pending").exists())
        self.assertIsNone(windows_install.installed_client(self.data, self.assets))
        self.assertEqual(self.install(progress=lambda *args: events.append(args)), "client01")
        self.assertEqual([event for event in events if event[0] == "copying"],
                         [("copying", 0, 2), ("copying", 1, 2), ("copying", 2, 2)])
        self.assertIn(("verifying", 4, 4), events)
        self.assertEqual(h0.snapshot(self.source), before)
        client = self.data / "local/clients/client01"
        self.assertFalse((client / "game/Partida 1.rxdata").exists())
        save = client / "profile/saves/Partida 1.rxdata"
        save.write_bytes(b"private save")
        with patch.object(windows_install, "prepare", side_effect=AssertionError("copied again")):
            self.assertEqual(self.install(), "client01")
        self.assertEqual(save.read_bytes(), b"private save")

    def test_recovery_preserves_a_save_in_an_unpublished_profile(self):
        save = self.data / "setup-pending/local/.prepare-old/client01/profile/saves/Partida 1.rxdata"
        save.parent.mkdir(parents=True)
        save.write_bytes(b"private save")
        with self.assertRaisesRegex(h0.SafetyError, "contiene partidas"):
            self.install()
        self.assertEqual(save.read_bytes(), b"private save")

    def test_play_opts_into_pvp_alongside_cooperative_battles(self):
        client = self.install()
        with patch.object(windows_install, "launch_windows") as launch:
            windows_install.play(self.data, self.assets, client)
        self.assertTrue(launch.call_args.kwargs["pvp"])
        self.assertTrue(launch.call_args.kwargs["coop_battles"])
