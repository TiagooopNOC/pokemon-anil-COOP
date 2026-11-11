import unittest

from src.server.trade_preview import TradePreview
from tests.test_coop_battle import personal_pokemon


def offer(slot=0):
    return dict(personal_pokemon(slot), egg_steps=0)


class TradePreviewTests(unittest.TestCase):
    def test_changes_reset_both_confirmations_and_no_transfer_exists(self):
        trade = TradePreview(("a", "b"))
        self.assertFalse(trade.state()["transfer_enabled"])
        self.assertFalse(trade.offer("intruder", offer()))
        self.assertFalse(trade.offer("a", dict(offer(), egg_steps=100)))
        self.assertTrue(trade.offer("a", offer()))
        self.assertTrue(trade.offer("b", offer(1)))
        version = trade.version
        self.assertIsNone(trade.confirm("a", version - 1))
        self.assertFalse(trade.confirm("a", version))
        self.assertTrue(trade.state()["confirmed"] == ["a"])
        self.assertTrue(trade.offer("b", dict(offer(1), name="Changed")))
        self.assertEqual(trade.state()["confirmed"], [])
        self.assertIsNone(trade.confirm("a", version))
        self.assertFalse(trade.confirm("b", trade.version))
        self.assertTrue(trade.confirm("a", trade.version))
        self.assertFalse(trade.state("preview_complete")["transfer_enabled"])
