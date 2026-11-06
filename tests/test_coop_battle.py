import json
import time
import unittest

from src.server.session_server import State
from src.server.coop_battle import BattleExchange, PROTOTYPE


class Peer:
    def __init__(self):
        self.messages = []

    def sendall(self, data):
        self.messages.append(json.loads(data))


class BattleBarrierTests(unittest.TestCase):
    def setUp(self):
        self.battle = BattleExchange(["host", "guest"])

    def step(self, player, stage, command=None, **changes):
        message = dict(battle=self.battle.id, seq=self.battle.seq, stage=stage,
                       digest="a" * 64, command=command)
        message.update(changes)
        return self.battle.submit(player, message)

    def setup_battle(self):
        self.assertEqual(self.step("host", "setup"), (None, None))
        error, packet = self.step("guest", "setup")
        self.assertIsNone(error)
        self.assertEqual(packet["seq"], 0)

    def test_orders_wait_for_both_and_preserve_targets(self):
        self.setup_battle()
        self.assertEqual(self.step("guest", "turn", ["move", 1, 3]), (None, None))
        self.assertEqual(self.battle.seq, 1)
        error, packet = self.step("host", "turn", ["move", 0, 1])
        self.assertIsNone(error)
        self.assertEqual(packet["commands"], [["move", 0, 1], ["move", 1, 3]])
        self.assertEqual(self.step("host", "enemy", [["move", 0, 0], ["move", 1, 2]]), (None, None))
        self.assertIsNotNone(self.step("guest", "enemy")[1])

    def test_forged_owner_stale_duplicate_and_bad_commands(self):
        self.setup_battle()
        for command in (["switch", 0, -1], ["move", True, 1], ["move", 4, 1],
                        ["move", 0, 4], ["save", 0, 1], "payload"):
            self.assertEqual(self.step("guest", "turn", command)[0], "battle_command")
        self.assertEqual(self.step("outsider", "turn", ["move", 0, 1])[0], "battle_not_participant")
        self.assertEqual(self.step("host", "turn", ["move", 0, 1], seq=0)[0], "battle_sequence")
        self.assertEqual(self.step("host", "turn", ["move", 0, 1], battle="old")[0], "battle_stale")
        self.assertEqual(self.step("host", "turn", ["move", 0, 1]), (None, None))
        self.assertEqual(self.step("host", "turn", ["move", 0, 3])[0], "battle_duplicate")
        self.assertEqual(self.battle.pending["host"]["command"], ["move", 0, 1])

    def test_desync_and_out_of_order_fail_closed(self):
        self.assertEqual(self.step("host", "turn", ["move", 0, 1])[0], "battle_stage")
        self.step("host", "setup")
        self.assertEqual(self.step("guest", "setup", digest="b" * 64)[0], "battle_desync")
        self.assertEqual(self.battle.seq, 0)

    def test_replacement_owned_by_one_player(self):
        self.setup_battle()
        self.step("host", "turn", ["move", 0, 1])
        self.step("guest", "turn", ["move", 0, 1])
        self.step("host", "enemy", [["move", 0, 0], ["move", 0, 2]])
        self.step("guest", "enemy")
        self.assertEqual(self.step("host", "switch", [2, 3])[0], "battle_command")
        self.assertEqual(self.step("host", "switch", [2, -1]), (None, None))
        self.assertEqual(self.step("guest", "switch", [2, 3])[1]["commands"], [[2, -1], [2, 3]])


class BattleLobbyTests(unittest.TestCase):
    def setUp(self):
        self.state = State()
        self.peers = [Peer() for _ in range(3)]
        self.ids = []
        for i, peer in enumerate(self.peers):
            reply, identity = self.state.handle(peer, {"type": "create" if i == 0 else "join",
                "name": f"p{i}", "session": "BATTLE1"}, None)
            self.ids.append(identity)
            self.call(i, "position", map=28, x=29, y=10, direction=2, pattern=0, seq=0, sprite="trainer")
        for i in (0, 1):
            self.call(i, "trainer_wait", forced=False, prototype=PROTOTYPE)
            self.call(i, "trainer_ready", ready=True)

    def call(self, i, kind, **extra):
        payload = dict(type=kind, map=28, event=9000)
        payload.update(extra)
        return self.state.handle(self.peers[i], payload, self.ids[i])[0]

    def start(self):
        result = self.call(0, "trainer_start", solo=False)
        self.assertEqual(result["phase"], "locked")
        self.assertTrue(result["battle"])
        for peer in self.peers:
            peer.messages.clear()
        return self.state.rooms["BATTLE1"]["trainers"]["28:9000"]["battle"]

    def test_requires_capability_and_ready_host(self):
        self.call(1, "trainer_wait", forced=False)  # old client loses capability
        self.call(1, "trainer_ready", ready=True)
        self.assertEqual(self.call(0, "trainer_start", solo=False)["reason"], "coop_battle_pending")
        self.call(1, "trainer_wait", forced=False, prototype=PROTOTYPE)
        self.call(1, "trainer_ready", ready=True)
        self.call(0, "trainer_ready", ready=False)
        self.assertEqual(self.call(0, "trainer_start", solo=False)["reason"], "coop_battle_pending")

    def test_disconnect_aborts_without_host_migration(self):
        battle = self.start()
        self.state.disconnect(self.ids[0], self.peers[0])
        self.assertNotIn("28:9000", self.state.rooms["BATTLE1"]["trainers"])
        self.assertEqual(self.peers[1].messages[1]["type"], "battle_abort")
        self.assertFalse(any(m["type"] == "battle_abort" for m in self.peers[2].messages))
        self.assertEqual(self.call(1, "battle_step", battle=battle.id)["reason"], "battle_not_participant")

    def test_locked_roster_spectator_explores_and_no_early_finish(self):
        battle = self.start()
        self.assertEqual(self.call(2, "trainer_wait", forced=False)["reason"], "trainer_locked")
        self.assertEqual(self.call(0, "trainer_finish")["reason"], "trainer_battle_active")
        self.assertIsNone(self.call(2, "position", map=28, x=30, y=10, direction=2, pattern=0, seq=1, sprite="trainer"))
        self.assertEqual(self.call(2, "battle_abort", battle=battle.id)["reason"], "battle_not_participant")
        self.assertIsNone(self.call(1, "battle_abort", battle=battle.id))
        self.assertFalse(self.state.rooms["BATTLE1"]["trainers"])

    def test_timeout_not_extended_by_heartbeat(self):
        battle = self.start()
        battle.deadline = time.monotonic() - 1
        self.call(0, "ping")
        self.assertFalse(self.state.rooms["BATTLE1"]["trainers"])
        self.assertEqual(self.peers[1].messages[0]["reason"], "battle_timeout")

    def test_result_requires_agreement_and_replay_cannot_reward(self):
        battle = self.start()
        stages = [("setup", None, None), ("turn", ["move", 0, 1], ["move", 0, 3]),
                  ("enemy", [["move", 0, 0], ["move", 0, 2]], None), ("result", None, None)]
        for seq, (stage, host, guest) in enumerate(stages):
            for i, cmd in enumerate((host, guest)):
                self.call(i, "battle_step", battle=battle.id, seq=seq, stage=stage,
                          digest="a" * 64, command=cmd)
        self.assertFalse(self.state.rooms["BATTLE1"]["trainers"])
        self.assertEqual(len([m for m in self.peers[0].messages if m["type"] == "battle_step"]), 4)
        self.assertFalse(any(m["type"] == "battle_step" for m in self.peers[2].messages))
        self.assertEqual(self.call(0, "battle_step", battle=battle.id, seq=3, stage="result",
                                   digest="a" * 64)["reason"], "battle_not_participant")


if __name__ == "__main__":
    unittest.main()
