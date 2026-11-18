"""Save import regressions with synthetic, disposable Ruby Marshal streams."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import save_import
from tools.h0 import SafetyError, windows_profile_lock
from tools.save_format import CORE_OBJECTS, validate_save


def save_bytes(version=b"4.1.1", extra=b""):
    def sized(value):
        return bytes([len(value) + 5]) + value

    def pair(key, kind, value):
        return b":" + sized(key) + kind + sized(value)

    return (b"\x04\x08{" + bytes([len(CORE_OBJECTS) + 7])
            + b"".join(pair(key, b"o:", name) + b"\x00" for key, name in CORE_OBJECTS.items())
            + pair(b"essentials_version", b'"', b"21.1") + pair(b"game_version", b'"', version) + extra)


class FormatTests(unittest.TestCase):
    def test_rejects_truncated_appended_and_incompatible_data(self):
        validate_save(save_bytes())
        for content in (save_bytes()[:-1], save_bytes(extra=b"extra"), save_bytes(b"4.0.0")):
            with self.subTest(content=content), self.assertRaises(SafetyError):
                validate_save(content)

    def test_folder_lists_only_recognized_files_and_marks_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "Partida 7.rxdata").write_bytes(save_bytes())
            (folder / "Auto 1.rxdata").write_bytes(b"broken")
            (folder / "Scripts.rxdata").write_bytes(save_bytes())
            auto, manual = save_import.find_saves(folder)
            self.assertTrue(auto.error)
            self.assertEqual(manual.slot, 7)
            self.assertFalse(manual.error)


@unittest.skipUnless(os.name == "nt", "uses the Windows profile lock and rename semantics")
class ImportTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.profile = self.root / "profile"
        self.saves = self.profile / "saves"
        self.saves.mkdir(parents=True)
        self.source = self.root / "Partida 3.rxdata"
        self.source.write_bytes(save_bytes())
        self.candidate, = save_import.find_saves(self.source)
        self.profile_mock = patch.object(save_import, "profile_for", return_value=self.profile)
        self.profile_mock.start()
        self.addCleanup(self.profile_mock.stop)
        game_check = patch.object(save_import, "require_game_closed")
        self.game_check = game_check.start()
        self.addCleanup(game_check.stop)
        self.args = (None, None, "client01", self.candidate)

    def destination(self):
        return save_import.inspect_destination(*self.args)

    def test_empty_profile_preserves_source_and_slot(self):
        name, backup = save_import.import_save(*self.args, self.destination())
        self.assertEqual(name, "Partida 3.rxdata")
        self.assertIsNone(backup)
        self.assertEqual((self.saves / name).read_bytes(), self.source.read_bytes())
        self.assertEqual(self.source.read_bytes(), save_bytes())

    def test_conflict_cancel_new_slot_and_explicit_replace(self):
        target = self.saves / "Partida 3.rxdata"
        target.write_bytes(b"existing")
        conflict = self.destination()
        self.assertTrue(conflict.existing_hash)
        self.assertEqual(list(self.saves.iterdir()), [target])  # Inspection and cancel are read-only.
        name, _ = save_import.import_save(*self.args, conflict)
        self.assertEqual(name, "Partida 1.rxdata")
        self.assertEqual(target.read_bytes(), b"existing")
        _, backup = save_import.import_save(*self.args, self.destination(), replace=True)
        self.assertEqual(backup.read_bytes(), b"existing")
        self.assertEqual(target.read_bytes(), save_bytes())
        self.assertEqual(self.source.read_bytes(), save_bytes())

    def test_failed_copy_and_stale_confirmation_preserve_existing_files(self):
        target = self.saves / "Partida 3.rxdata"
        target.write_bytes(b"existing")
        conflict = self.destination()
        with patch.object(save_import.os, "fsync", side_effect=OSError("write failed")):
            with self.assertRaises(OSError):
                save_import.import_save(*self.args, conflict, replace=True)
        self.assertEqual(list(self.saves.iterdir()), [target])
        self.assertEqual(target.read_bytes(), b"existing")
        target.write_bytes(b"newer")
        with self.assertRaisesRegex(SafetyError, "cambiaron"):
            save_import.import_save(*self.args, conflict, replace=True)
        self.assertEqual(target.read_bytes(), b"newer")
        self.assertEqual(self.source.read_bytes(), save_bytes())

    def test_game_lock_and_trade_recovery_block_writes(self):
        import msvcrt

        with windows_profile_lock(self.profile / "coop-game.lock", msvcrt):
            with self.assertRaisesRegex(SafetyError, "abierta"):
                self.destination()
        (self.profile / "pending-trade.json").write_text("{}")
        with self.assertRaisesRegex(SafetyError, "intercambio"):
            self.destination()
        self.assertFalse(list(self.saves.iterdir()))

    def test_running_original_game_blocks_publication(self):
        self.game_check.side_effect = SafetyError("Cerrá Pokémon Añil")
        with self.assertRaisesRegex(SafetyError, "Cerrá"):
            save_import.import_save(*self.args, self.destination())
        self.assertFalse(list(self.saves.iterdir()))
