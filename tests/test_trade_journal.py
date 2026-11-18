import copy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from src.server.trade_journal import TradeJournal


class TradeJournalTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "server" / "trades.sqlite3"
        self.a, self.b = "a" * 32, "b" * 32
        self.tx = "c" * 32
        self.offers = ({"version": 1, "pokemon": {"class": "Pokemon", "fields": {"personalID": 11}}},
                       {"version": 1, "pokemon": {"class": "Pokemon", "fields": {"personalID": 22}}})
        self.journal = TradeJournal(self.path)

    def tearDown(self):
        self.journal.close()
        self.temp.cleanup()

    def reopen(self):
        self.journal.close()
        self.journal = TradeJournal(self.path)

    def prepare(self):
        self.journal.store_offers(self.tx, (self.a, self.b), self.offers)
        digest_a, digest_b = self.journal.get(self.tx)["digests"]
        self.journal.mark_prepared(self.tx, self.a, digest_a, digest_b)
        self.journal.mark_prepared(self.tx, self.b, digest_b, digest_a)

    def test_recovery_at_each_decision_boundary(self):
        self.assertIsNone(self.journal.get(self.tx))  # Before confirmation.
        self.journal.store_offers(self.tx, (self.a, self.b), self.offers)
        self.reopen()  # After both offers reach the server.
        self.assertEqual(self.journal.get(self.tx)["prepared"], (False, False))
        digests = self.journal.get(self.tx)["digests"]
        self.journal.mark_prepared(self.tx, self.a, *digests)
        self.reopen()  # One client prepared; commit remains impossible.
        self.assertEqual(self.journal.get(self.tx)["prepared"], (True, False))
        with self.assertRaises(ValueError):
            self.journal.decide_commit(self.tx)
        self.journal.mark_prepared(self.tx, self.b, *reversed(digests))
        self.reopen()  # Both prepared; no decision yet.
        self.assertIsNone(self.journal.get(self.tx)["decision"])
        self.journal.decide_commit(self.tx)
        self.reopen()  # Durable commit survives a server restart.
        self.assertEqual(self.journal.get(self.tx)["decision"], "commit")
        self.assertEqual(len(self.journal.pending_for(self.a)), 1)
        self.assertEqual(len(self.journal.pending_for(self.b)), 1)
        self.journal.mark_applied(self.tx, self.a)
        self.reopen()  # One client applied; the other is still pending.
        self.assertEqual(self.journal.get(self.tx)["applied"], (True, False))
        self.assertEqual(len(self.journal.pending_for(self.a)), 1)
        self.journal.mark_applied(self.tx, self.b)
        self.journal.mark_applied(self.tx, self.b)  # Idempotent acknowledgment.
        self.reopen()
        self.assertEqual(self.journal.get(self.tx)["applied"], (True, True))
        self.assertEqual(self.journal.pending_for(self.a), [])

    def test_immutable_offers_and_no_unilateral_decision(self):
        self.journal.store_offers(self.tx, (self.a, self.b), self.offers)
        altered = copy.deepcopy(self.offers)
        altered[0]["pokemon"]["fields"]["personalID"] = 99
        with self.assertRaisesRegex(ValueError, "immutable"):
            self.journal.store_offers(self.tx, (self.a, self.b), altered)
        with self.assertRaises(ValueError):
            self.journal.mark_applied(self.tx, self.a)
        with self.assertRaises(ValueError):
            self.journal.mark_prepared(self.tx, self.a, "0" * 64, "0" * 64)
        self.assertEqual(self.journal.get(self.tx)["offers"], self.offers)
        self.assertEqual(self.journal.get(self.tx)["prepared"], (False, False))

    def test_commit_never_reverses_or_changes_offers(self):
        self.prepare()
        self.journal.decide_commit(self.tx)
        self.journal.decide_commit(self.tx)
        with self.assertRaises(ValueError):
            self.journal.mark_prepared(self.tx, self.a, *self.journal.get(self.tx)["digests"])
        with self.assertRaises(ValueError):
            self.journal.store_offers(self.tx, (self.b, self.a), tuple(reversed(self.offers)))
        self.assertEqual(self.journal.get(self.tx)["decision"], "commit")

    def test_commit_survives_abrupt_process_exit(self):
        self.journal.close()
        code = """import os, sys
from pathlib import Path
from src.server.trade_journal import TradeJournal
j = TradeJournal(Path(sys.argv[1]))
a, b, tx = 'a'*32, 'b'*32, 'c'*32
j.store_offers(tx, (a,b), ({'version':1,'pokemon':{'id':1}}, {'version':1,'pokemon':{'id':2}}))
x, y = j.get(tx)['digests']
j.mark_prepared(tx, a, x, y)
j.mark_prepared(tx, b, y, x)
j.decide_commit(tx)
os._exit(0)
"""
        try:
            subprocess.run([sys.executable, "-c", code, str(self.path)],
                           check=True, cwd=Path(__file__).resolve().parents[1])
        finally:
            self.journal = TradeJournal(self.path)
        record = self.journal.get(self.tx)
        self.assertEqual(record["decision"], "commit")
        self.assertEqual(record["applied"], (False, False))


if __name__ == "__main__":
    unittest.main()
