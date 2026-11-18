import tempfile
import unittest
from pathlib import Path

from src.server.session_server import State
from src.server.trade_journal import TradeJournal
from tests.test_coop_battle import Peer
from tests.test_trade_preview import offer


def full_data(preview):
    return {"version": 1,
            "pokemon": {"class": "Pokemon", "fields": {
                "species": {"symbol": preview["species"]},
                "form": preview["form"], "forced_form": None,
                "personalID": preview["pid"],
                "owner": {"class": "Owner", "fields": preview["owner"]}}},
            "effective": {"types": preview["types"], "base_stats": preview["base_stats"]}}


class TransferProtocolTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.journal = TradeJournal(Path(self.temp.name) / "trades.sqlite3")
        self.state = State(self.journal)
        self.a, self.b = Peer(), Peer()
        self.profile_a, self.profile_b = "a" * 32, "b" * 32
        self.host, self.host_identity = self.state.handle(
            self.a, {"type": "create", "session": "TEST01", "name": "host", "profile": self.profile_a}, None)
        self.guest, self.guest_identity = self.state.handle(
            self.b, {"type": "join", "session": "TEST01", "name": "guest", "profile": self.profile_b}, None)

    def tearDown(self):
        self.journal.close()
        self.temp.cleanup()

    def send(self, peer, identity, **packet):
        return self.state.handle(peer, packet, identity)[0]

    def open_trade(self):
        invite = "e" * 16
        self.send(self.a, self.host_identity, type="invite_request", request=invite,
                  target=self.guest["id"], kind="trade")
        self.send(self.b, self.guest_identity, type="invite_reply", request=invite, accept=True)
        trade = next(iter(self.state.rooms["TEST01"]["trades"].values()))
        self.assertTrue(trade.transfer_enabled)
        first, second = offer(), offer(1)
        self.send(self.a, self.host_identity, type="trade_offer", trade=trade.id, offer=first)
        self.send(self.b, self.guest_identity, type="trade_offer", trade=trade.id, offer=second)
        self.send(self.a, self.host_identity, type="trade_confirm", trade=trade.id, version=trade.version)
        self.send(self.b, self.guest_identity, type="trade_confirm", trade=trade.id, version=trade.version)
        self.assertEqual(trade.phase, "payloads")
        return trade, first, second

    def prepare(self):
        trade, first, second = self.open_trade()
        self.send(self.a, self.host_identity, type="trade_payload", trade=trade.id,
                  payload=full_data(first))
        self.assertIsNone(self.journal.get(trade.id))
        self.send(self.b, self.guest_identity, type="trade_payload", trade=trade.id,
                  payload=full_data(second))
        record = self.journal.get(trade.id)
        self.assertEqual(record["players"], (self.profile_a, self.profile_b))
        self.assertEqual(trade.phase, "preparing")
        return trade, record

    def test_two_preparations_commit_and_two_applications(self):
        trade, record = self.prepare()
        x, y = record["digests"]
        self.send(self.a, self.host_identity, type="trade_prepared", trade=trade.id,
                  own_digest=x, incoming_digest=y)
        self.assertIsNone(self.journal.get(trade.id)["decision"])
        self.send(self.b, self.guest_identity, type="trade_prepared", trade=trade.id,
                  own_digest=y, incoming_digest=x)
        self.assertEqual(self.journal.get(trade.id)["decision"], "commit")
        self.assertEqual(trade.phase, "commit")
        self.send(self.a, self.host_identity, type="trade_applied", trade=trade.id)
        self.assertEqual(self.journal.get(trade.id)["applied"], (True, False))
        self.send(self.b, self.guest_identity, type="trade_applied", trade=trade.id)
        self.assertEqual(self.journal.get(trade.id)["applied"], (True, True))
        self.assertEqual(self.a.messages[-1]["phase"], "complete")
        self.assertEqual(self.b.messages[-1]["phase"], "complete")
        self.assertEqual(self.a.messages[-1]["decision"], "commit")

    def test_cancel_after_one_preparation_persists_abort(self):
        trade, record = self.prepare()
        x, y = record["digests"]
        self.send(self.a, self.host_identity, type="trade_prepared", trade=trade.id,
                  own_digest=x, incoming_digest=y)
        self.send(self.b, self.guest_identity, type="trade_cancel", trade=trade.id)
        self.assertEqual(self.journal.get(trade.id)["decision"], "abort")
        self.assertEqual(self.a.messages[-1]["phase"], "cancelled")
        self.assertEqual(self.b.messages[-1]["phase"], "cancelled")
        self.assertEqual(self.a.messages[-1]["decision"], "abort")

    def test_wrong_payload_does_not_replace_confirmed_offer(self):
        trade, first, _ = self.open_trade()
        wrong = full_data(first)
        wrong["pokemon"]["fields"]["personalID"] += 1
        result = self.send(self.a, self.host_identity, type="trade_payload", trade=trade.id,
                           payload=wrong)
        self.assertEqual(result["reason"], "invalid_payload")
        self.assertEqual(trade.payloads, {})


if __name__ == "__main__":
    unittest.main()
