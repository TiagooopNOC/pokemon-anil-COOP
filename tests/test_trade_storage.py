import hashlib
import tempfile
import unittest
from pathlib import Path

from src.client.trade_storage import TradeStorage, digest


class TradeStorageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.save_dir = Path(self.temp.name) / "profile" / "saves"
        self.save_dir.mkdir(parents=True)
        self.tx = "a" * 32
        self.save = self.save_dir / "Partida 1.rxdata"
        self.candidate = self.save_dir / f"trade-{self.tx}.rxdata.tmp"
        self.save.write_bytes(b"trusted-old-save")
        self.candidate.write_bytes(b"trusted-new-save-with-receipt")
        self.old_hash = digest(self.save)
        self.new_hash = digest(self.candidate)
        self.storage = TradeStorage(self.save_dir)

    def tearDown(self):
        self.storage.close()
        self.temp.cleanup()

    def reopen(self):
        self.storage.close()
        self.storage = TradeStorage(self.save_dir)

    def prepare(self):
        return self.storage.prepare(self.tx, self.save.name, self.candidate.name, self.old_hash)

    def test_interruptions_and_idempotent_recovery(self):
        self.assertEqual(self.storage.pending(), [])  # Before confirmation.
        self.assertEqual(self.prepare(), self.new_hash)
        self.assertTrue(self.storage.lock_path.exists())
        self.reopen()  # After local preparation.
        self.assertIsNone(self.storage.get(self.tx)["decision"])
        self.assertEqual(digest(self.save), self.old_hash)
        with self.assertRaises(ValueError):
            self.storage.apply(self.tx)
        self.storage.decide(self.tx, "commit")
        self.reopen()  # After durable decision, before replacement.
        self.assertEqual(len(self.storage.pending()), 1)
        with self.assertRaisesRegex(RuntimeError, "power loss"):
            self.storage.apply(self.tx, after_replace=lambda: (_ for _ in ()).throw(RuntimeError("power loss")))
        self.assertEqual(digest(self.save), self.new_hash)
        self.assertFalse(self.storage.get(self.tx)["applied"])
        self.reopen()  # Replacement happened; acknowledgment did not.
        self.assertEqual(self.storage.apply(self.tx), self.new_hash)
        self.assertEqual(self.storage.apply(self.tx), self.new_hash)
        self.assertEqual(len(self.storage.pending()), 1)
        self.assertTrue(self.storage.lock_path.exists())
        self.storage.finish(self.tx)
        self.assertEqual(self.storage.pending(), [])
        self.assertFalse(self.storage.lock_path.exists())

    def test_only_one_prepared_player_cannot_apply(self):
        self.prepare()
        with self.assertRaises(ValueError):
            self.storage.apply(self.tx)
        self.assertEqual(digest(self.save), self.old_hash)

    def test_original_change_blocks_replacement(self):
        self.prepare()
        self.storage.decide(self.tx, "commit")
        self.save.write_bytes(b"changed-by-someone-else")
        with self.assertRaisesRegex(ValueError, "diverged"):
            self.storage.apply(self.tx)
        self.assertEqual(self.save.read_bytes(), b"changed-by-someone-else")
        self.assertEqual(len(self.storage.pending()), 1)

    def test_prepared_candidate_is_immutable(self):
        self.prepare()
        self.candidate.write_bytes(b"altered")
        with self.assertRaises(ValueError):
            self.prepare()
        self.storage.decide(self.tx, "commit")
        with self.assertRaisesRegex(ValueError, "diverged"):
            self.storage.apply(self.tx)
        self.assertEqual(digest(self.save), self.old_hash)

    def test_no_unilateral_abort_after_commit(self):
        self.prepare()
        self.storage.decide(self.tx, "commit")
        with self.assertRaisesRegex(ValueError, "conflicting"):
            self.storage.decide(self.tx, "abort")
        self.storage.apply(self.tx)
        with self.assertRaises(ValueError):
            self.storage.decide(self.tx, "abort")
        self.storage.finish(self.tx)

    def test_abort_removes_candidate_and_startup_lock(self):
        self.prepare()
        self.storage.decide(self.tx, "abort")
        self.assertEqual(digest(self.save), self.old_hash)
        self.assertFalse(self.candidate.exists())
        self.assertFalse(self.storage.lock_path.exists())
        self.assertEqual(self.storage.pending(), [])

    def test_orphan_lock_before_local_prepare_can_be_cleared(self):
        self.storage._lock(self.tx)
        self.reopen()
        self.storage.clear_unprepared_lock(self.tx)
        self.assertFalse(self.storage.lock_path.exists())

    def test_reject_paths_outside_isolated_saves(self):
        with self.assertRaises(ValueError):
            self.storage.prepare(self.tx, "../../personal.rxdata", self.candidate.name, self.old_hash)
        self.candidate.unlink()
        self.candidate.symlink_to(self.save)
        with self.assertRaises(ValueError):
            self.prepare()


if __name__ == "__main__":
    unittest.main()
