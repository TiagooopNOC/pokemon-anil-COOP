import hashlib
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path

from src.client.trade_storage import TradeStorage, digest
from src.server.trade_journal import TradeJournal
from tools.trade_recovery import recover

ROOT = Path(__file__).resolve().parents[1]


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class TradeRecoveryTest(unittest.TestCase):
    def test_two_independent_profiles_recover_after_server_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profiles = [root / "host", root / "guest"]
            txid = "c" * 32
            code = "ABCDEFGHJKLM"
            ids = []
            for i, profile in enumerate(profiles):
                (profile / "saves").mkdir(parents=True)
                marker = f"profile-{i}"
                (profile / "profile-id.txt").write_text(marker)
                ids.append(hashlib.sha256(marker.encode()).hexdigest()[:32])
                save = profile / "saves" / "Partida 1.rxdata"
                candidate = profile / "saves" / f"trade-{txid}.rxdata.tmp"
                save.write_bytes(f"old-{i}".encode())
                candidate.write_bytes(f"committed-{i}-with-receipt".encode())
                storage = TradeStorage(profile / "saves")
                storage.prepare(txid, save.name, candidate.name, digest(save),
                                {"mode": "create" if i == 0 else "join",
                                 "host": "127.0.0.1", "code": code})
                storage.close()
            journal = TradeJournal(profiles[0] / "trade-server.sqlite3")
            offers = ({"version": 1, "pokemon": {"fixture": 1}},
                      {"version": 1, "pokemon": {"fixture": 2}})
            journal.store_offers(txid, tuple(ids), offers)
            first, second = journal.get(txid)["digests"]
            journal.mark_prepared(txid, ids[0], first, second)
            journal.mark_prepared(txid, ids[1], second, first)
            journal.decide_commit(txid)
            journal.close()  # Session server starts with only the durable database.
            port = free_port()
            outcomes = [None, None]

            def run(i):
                try:
                    outcomes[i] = recover(ROOT, profiles[i], port=port, wait_seconds=12)
                except Exception as error:
                    outcomes[i] = error

            host = threading.Thread(target=run, args=(0,))
            guest = threading.Thread(target=run, args=(1,))
            host.start()
            time.sleep(0.3)
            guest.start()
            host.join(timeout=20)
            guest.join(timeout=20)
            self.assertFalse(host.is_alive())
            self.assertFalse(guest.is_alive())
            self.assertEqual(outcomes, [[(txid, "commit")], [(txid, "commit")]])
            for i, profile in enumerate(profiles):
                self.assertEqual((profile / "saves" / "Partida 1.rxdata").read_bytes(),
                                 f"committed-{i}-with-receipt".encode())
                self.assertFalse((profile / "trade-pending.lock").exists())


if __name__ == "__main__":
    unittest.main()
