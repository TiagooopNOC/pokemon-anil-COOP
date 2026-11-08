"""Safety regressions using synthetic files, never personal game installs."""
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from tools import h0


class WorkspaceSafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo, self.source = self.base / "mod", self.base / "original"
        self.repo.mkdir()
        self.source.mkdir()
        data = {"Game.exe": b"synthetic executable - never run", "Game.ini": b"[Game]",
                "mkxp.json": b'{// comment\n"windowTitle":"Test","vsync":true}',
                "Data/Scripts.rxdata": b"synthetic scripts",
                "Data/PluginScripts.rxdata": b"synthetic plugin cache",
                "Plugins/Cable Club/main.rb": b"synthetic existing plugin",
                "Game.rxdata": b"personal save must not be copied",
                "Partida 1.rxdata": b"personal multisave must not be copied"}
        for name, value in data.items():
            p = self.source / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(value)
        (self.repo / "config").mkdir()
        critical = {name: h0.digest(self.source / name) for name in data if not h0.is_save(name)}
        h0.write_new(self.repo / "config/build.json", {"critical": critical})
        (self.repo / "src/bootstrap").mkdir(parents=True)
        shutil.copy2(h0.ROOT / "src/bootstrap/isolate.rb", self.repo / "src/bootstrap/isolate.rb")

    def prepare(self, count=4):
        return h0.prepare(self.repo, self.source, count)

    def test_only_old_owned_idle_game_slot_can_be_reclaimed(self):
        lease = {"owner": "anil-h0-previous", "since": 100.0, "procs": [{"pid": 123}]}
        snapshot = {"slots": [{"free": False, "lease": lease}], "running": []}
        self.assertEqual(h0.orphan_game_slot_owner(snapshot, 125.0), "anil-h0-previous")
        self.assertIsNone(h0.orphan_game_slot_owner(snapshot, 110.0))
        self.assertIsNone(h0.orphan_game_slot_owner({**snapshot, "running": [123]}, 125.0))
        self.assertIsNone(h0.orphan_game_slot_owner({"slots": [{"free": False,
            "lease": {**lease, "owner": "another-program"}}], "running": []}, 125.0))
        self.assertIsNone(h0.orphan_game_slot_owner({"slots": [
            {"free": False, "lease": lease},
            {"free": False, "lease": {**lease, "owner": "anil-h0-other"}}], "running": []}, 125.0))

    def test_four_independent_copies_original_and_plugins_unchanged(self):
        original = h0.snapshot(self.source)
        self.prepare()
        self.assertEqual(original, h0.snapshot(self.source))
        self.assertEqual(h0.verify(self.repo)["clients"], 4)
        for i in range(1, 5):
            game = self.repo / f"local/clients/client{i:02d}/game"
            self.assertFalse((game / "Game.rxdata").exists())
            self.assertFalse((game / "Partida 1.rxdata").exists())
            self.assertEqual((game / "Plugins/Cable Club/main.rb").read_bytes(),
                             (self.source / "Plugins/Cable Club/main.rb").read_bytes())
            cfg = h0.read_json(game / "mkxp.json")
            self.assertTrue(cfg["vsync"])

    def test_refuses_overwrite_and_preserves_test_save(self):
        self.prepare()
        save = self.repo / "local/clients/client01/profile/saves/Partida 1.rxdata"
        save.write_bytes(b"owned by test player")
        with self.assertRaises(h0.SafetyError):
            self.prepare()
        self.assertEqual(save.read_bytes(), b"owned by test player")

    def test_rejects_nested_source_and_destination(self):
        for repo, source in [(self.source / "mod", self.source),
                             (self.repo, self.repo / "game"), (self.repo, self.repo)]:
            with self.assertRaises(h0.SafetyError):
                h0.prepare(repo, source, 4)

    def test_rejects_out_of_range_client_count(self):
        for count in (0, 5, -1):
            with self.assertRaises(h0.SafetyError):
                self.prepare(count)
        self.assertFalse((self.repo / "local").exists())

    def test_unsupported_build_refused_before_copy(self):
        (self.source / "Game.exe").write_bytes(b"changed build")
        with self.assertRaises(h0.SafetyError):
            self.prepare()
        self.assertFalse((self.repo / "local/clients").exists())

    def test_detects_changed_original_and_new_files(self):
        self.prepare(1)
        extra = self.source / "unexpected.txt"
        extra.write_text("change")
        with self.assertRaises(h0.SafetyError):
            h0.verify(self.repo)
        extra.unlink()
        (self.source / "Game.exe").write_bytes(b"changed")
        with self.assertRaises(h0.SafetyError):
            h0.verify(self.repo)

    def test_detects_hardlink_to_original(self):
        self.prepare(1)
        copy = self.repo / "local/clients/client01/game/Game.exe"
        copy.unlink()
        os.link(self.source / "Game.exe", copy)
        with self.assertRaises(h0.SafetyError):
            h0.verify(self.repo)

    def test_detects_hardlink_between_clients(self):
        self.prepare(2)
        first = self.repo / "local/clients/client01/game/Game.exe"
        second = self.repo / "local/clients/client02/game/Game.exe"
        second.unlink()
        os.link(first, second)
        with self.assertRaises(h0.SafetyError):
            h0.verify(self.repo)

    def test_rejects_symlink_source(self):
        try:
            (self.source / "link").symlink_to(self.repo, target_is_directory=True)
        except OSError:
            self.skipTest("Symlink creation unavailable to this Windows account")
        with self.assertRaises(h0.SafetyError):
            self.prepare()

    def test_rejects_symlink_save_directory(self):
        self.prepare(1)
        save = self.repo / "local/clients/client01/profile/saves"
        save.rmdir()
        try:
            save.symlink_to(self.source, target_is_directory=True)
        except OSError:
            self.skipTest("Symlink creation unavailable to this Windows account")
        with self.assertRaises(h0.SafetyError):
            h0.verify(self.repo)

    def test_wine_prefix_can_contain_its_own_standard_links(self):
        self.prepare(1)
        link = self.repo / "local/clients/client01/wine-prefix/Downloads"
        try:
            link.symlink_to(self.base, target_is_directory=True)
        except OSError:
            self.skipTest("Symlink creation unavailable to this Windows account")
        self.assertEqual(h0.verify(self.repo)["status"], "PASS")

    def test_detects_removed_bootstrap_and_mutated_config(self):
        self.prepare(1)
        cfg = self.repo / "local/clients/client01/game/mkxp.json"
        old = cfg.read_bytes()
        cfg.write_text('{"dataPathApp":"Pokemon Anil"}')
        with self.assertRaises(h0.SafetyError):
            h0.verify(self.repo)
        cfg.write_bytes(old)
        (cfg.parent / "CoopDev/isolate.rb").unlink()
        with self.assertRaises(h0.SafetyError):
            h0.verify(self.repo)

    def test_duplicate_profile_id_detected(self):
        self.prepare(2)
        path = self.repo / "local/workspace.json"
        w = h0.read_json(path)
        w["clients"][1]["profile_id"] = w["clients"][0]["profile_id"]
        path.write_text(json.dumps(w))
        with self.assertRaises(h0.SafetyError):
            h0.verify(self.repo)

    def test_interrupted_preparation_is_not_overwritten(self):
        incomplete = self.repo / "local/.prepare-test"
        incomplete.mkdir(parents=True)
        with self.assertRaises(h0.SafetyError):
            self.prepare()
        self.assertTrue(incomplete.is_dir())

    def test_four_plans_have_distinct_save_and_wine_directories(self):
        self.prepare()
        plan = h0.launch_plan(self.repo, [f"client{i:02d}" for i in range(1, 5)])
        for key in ("APPDATA", "LOCALAPPDATA", "WINEPREFIX", "ANIL_COOP_PROFILE_ID"):
            self.assertEqual(len({p["environment"][key] for p in plan["clients"]}), 4)
        with self.assertRaises(h0.SafetyError):
            h0.launch_plan(self.repo, ["client01", "client01"])
        with self.assertRaises(h0.SafetyError):
            h0.launch_plan(self.repo, ["../../original"])

    def test_missing_wine_is_blocked_not_a_runtime_pass(self):
        with patch.object(h0.os, "name", "posix"), patch.object(h0.shutil, "which", return_value=None):
            result = h0.doctor(self.repo)
        self.assertEqual(result["runtime"], "BLOCKED_NO_WINE")
        self.assertEqual(result["actual_game_execution"], "NOT_CHECKED_BY_DOCTOR")

    def test_jsonc_preserves_strings_and_urls(self):
        self.assertEqual(h0.parse_jsonc('{"url":"https://test/a",/*comment*/"s":"//x"}'),
                         {"url": "https://test/a", "s": "//x"})

    def test_mkxp_trailing_comma_preserves_string_content(self):
        self.assertEqual(h0.parse_jsonc('{"text":",}","list":[1,],// last\n}'),
                         {"text": ",}", "list": [1]})

    def test_package_excludes_private_game_and_saves(self):
        self.prepare(1)
        for name in ("README.md", ".gitignore", ".gitattributes"):
            (self.repo / name).write_text("test")
        for directory in h0.PACKAGE_DIRS:
            (self.repo / directory).mkdir(exist_ok=True)
        result = h0.package(self.repo)
        self.assertEqual(result["status"], "PACKAGED_TOOLS_ONLY")
        with zipfile.ZipFile(self.repo / "dist/anil-coop-h0-tools.zip") as z:
            names = z.namelist()
        self.assertTrue(names)
        self.assertFalse(any(n.startswith("local/") or n.endswith((".exe", ".rxdata")) for n in names))
        with self.assertRaises(FileExistsError):
            h0.package(self.repo)

    def test_alpha_package_contains_launchers_and_reviewed_vendor_only(self):
        for name in ("README.md", ".gitignore", ".gitattributes", "Jugar-Coop.cmd", "jugar-coop.sh",
                     "vendor/gameslot/gameslot.py", "vendor/gameslot/LICENSE", "vendor/gameslot/README.md",
                     "vendor/private-secret.json", "local/workspace.json", "local/Partida 1.rxdata"):
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("synthetic")
        h0.package(self.repo, alpha=True)
        with zipfile.ZipFile(self.repo / "dist/anil-coop-alpha-menu.zip") as z:
            names = z.namelist()
            self.assertIn("Jugar-Coop.cmd", names)
            self.assertIn("vendor/gameslot/LICENSE", names)
            self.assertNotIn("vendor/private-secret.json", names)
            self.assertFalse(any(n.startswith("local/") for n in names))
            self.assertEqual(z.getinfo("jugar-coop.sh").external_attr >> 16, 0o755)


if __name__ == "__main__":
    unittest.main()
