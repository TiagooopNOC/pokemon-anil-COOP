import json
import time
import unittest

from src.server.session_server import State
from src.server.coop_battle import (BattleExchange, PROTOTYPE, PERSONAL_PROTOTYPE,
                                    validate_team, validate_trainer)


def personal_trainer():
    return dict(id=100, name="Owner", gender=0, language=2, trainer_type="POKEMONTRAINER_Red")


def personal_pokemon(slot=0):
    return dict(key=f"100:{1000 + slot}", slot=slot, species="BULBASAUR", name="Bulbasaur",
                level=10, exp=560, form=0, pid=1000 + slot,
                owner=dict(id=100, name="Owner", gender=0, language=2), gender=0,
                shiny=False, super_shiny=False, ability="OVERGROW", nature="HARDY",
                nature_stats="HARDY", item=None, moves=[["TACKLE", 35, 0]], iv=[15] * 6,
                ev=[0] * 6, maxed=[False] * 6, stats=[31, 20, 20, 20, 20, 20],
                base_stats=[45, 49, 49, 65, 65, 45], types=["GRASS", "POISON"],
                hp=31, status="NONE", status_count=0, happiness=70, pokerus=0, ball="POKEBALL")


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

    def test_qa_event_accepts_valid_personal_encounter_identity(self):
        self.call(0, "trainer_cancel")
        self.call(1, "trainer_cancel")
        state = self.call(0, "trainer_wait", forced=False, prototype=PERSONAL_PROTOTYPE, encounter_key="a" * 64)
        self.assertEqual(state["encounter_key"], "a" * 64)
        self.assertEqual(self.call(1, "trainer_wait", forced=False, prototype=PERSONAL_PROTOTYPE,
                                   encounter_key="bad")["reason"], "trainer_encounter_key")

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


class PersonalSnapshotTests(unittest.TestCase):
    def test_bounded_snapshot_and_identity(self):
        self.assertTrue(validate_trainer(personal_trainer()))
        self.assertTrue(validate_team([personal_pokemon(i) for i in (5, 2, 0)]))
        self.assertFalse(validate_team([]))
        self.assertFalse(validate_team([personal_pokemon(i) for i in range(4)]))
        self.assertTrue(validate_team([personal_pokemon(i) for i in range(6)], max_size=6))
        self.assertFalse(validate_team([personal_pokemon(), personal_pokemon()]))
        for field, value in (("pid", True), ("hp", 32), ("slot", 6), ("key", "100:999"),
                             ("species", "../../game"), ("iv", [31] * 7),
                             ("moves", [["TACKLE", 256, 0]]), ("maxed", [0] * 6),
                             ("extra", "untrusted"), ("owner", {"id": 100})):
            pokemon = personal_pokemon()
            pokemon[field] = value
            self.assertFalse(validate_team([pokemon]), field)
        trainer = personal_trainer()
        trainer["id"] = True
        self.assertFalse(validate_trainer(trainer))

    def test_personal_ranges_reject_other_owner_and_unselected_slots(self):
        battle = BattleExchange(["host", "guest"], (1, 3))
        def step(player, stage, command=None):
            return battle.submit(player, dict(battle=battle.id, seq=battle.seq,
                                 stage=stage, digest="a" * 64, command=command))
        step("host", "setup")
        step("guest", "setup")
        self.assertEqual(step("host", "turn", ["switch", 1, -1])[0], "battle_command")
        self.assertEqual(step("guest", "turn", ["switch", 0, -1])[0], "battle_command")
        self.assertEqual(step("guest", "turn", ["switch", 4, -1])[0], "battle_command")
        step("host", "turn", ["move", 0, 1])
        self.assertIsNone(step("guest", "turn", ["switch", 3, -1])[0])
        step("host", "enemy", [["move", 0, 0], ["move", 0, 2]])
        step("guest", "enemy")
        self.assertEqual(step("guest", "switch", [2, 0])[0], "battle_command")
        step("host", "switch", [2, -1])
        self.assertEqual(step("guest", "switch", [2, 1])[1]["commands"], [[2, -1], [2, 1]])

    def test_team_size_bounds(self):
        for sizes in ((0, 1), (4, 1), (True, 1), (1,)):
            with self.assertRaises(ValueError):
                BattleExchange(["host", "guest"], sizes)


class PersonalLobbyTests(unittest.TestCase):
    call = BattleLobbyTests.call

    def setUp(self):
        BattleLobbyTests.setUp(self)
        for i in (0, 1):
            self.call(i, "trainer_wait", forced=False, prototype=PERSONAL_PROTOTYPE)

    def team(self, player, slots=(0,)):
        return self.call(player, "trainer_team", team=[personal_pokemon(i) for i in slots],
                         trainer=personal_trainer())

    def test_confirm_both_freeze_and_keep_snapshots_private(self):
        self.assertEqual(self.call(0, "trainer_ready", ready=True)["reason"], "trainer_team_required")
        self.assertEqual(self.call(0, "trainer_team", team=[personal_pokemon()])["reason"], "invalid_trainer_team")
        self.team(0)
        self.team(1, (5, 2, 0))
        for i in (0, 1):
            self.call(i, "trainer_ready", ready=True)
        state = self.call(0, "trainer_start", solo=False)
        self.assertEqual(state["prototype"], PERSONAL_PROTOTYPE)
        self.assertEqual(state["team_sizes"], [1, 3])
        self.assertEqual([p["slot"] for p in state["selected_teams"][1]], [5, 2, 0])
        self.assertEqual(len(state["selected_trainers"]), 2)
        guest = self.peers[1].messages[-1]
        self.assertEqual(guest["selected_teams"], state["selected_teams"])
        spectator = self.peers[2].messages[-1]
        self.assertNotIn("selected_teams", spectator)
        self.assertNotIn("selected_trainers", spectator)
        self.assertEqual([p["team_count"] for p in spectator["participants"]], [1, 3])
        self.assertEqual(self.team(1)["reason"], "trainer_locked")

    def test_changes_revoke_ready_and_selection_is_copied(self):
        team = [personal_pokemon()]
        self.call(0, "trainer_team", team=team, trainer=personal_trainer())
        team[0]["hp"] = 1
        entry = self.state.rooms["BATTLE1"]["trainers"]["28:9000"]["participants"][self.ids[0][1]]
        self.assertEqual(entry["team"][0]["hp"], 31)
        self.call(0, "trainer_ready", ready=True)
        state = self.team(0, (1, 3))
        self.assertFalse(state["participants"][0]["ready"])
        self.assertEqual(state["participants"][0]["team_count"], 2)

    def test_solo_and_nonparticipants(self):
        self.assertEqual(self.team(2)["reason"], "no_trainer_wait")
        state = self.call(0, "trainer_start", solo=True)
        self.assertEqual(state["phase"], "locked")
        self.assertIsNone(state["battle"])
        self.assertNotIn("selected_teams", state)


class RealTrainerLobbyTests(unittest.TestCase):
    team = PersonalLobbyTests.team

    def call(self, i, kind, **extra):
        extra.setdefault("event", self.event)
        return BattleLobbyTests.call(self, i, kind, **extra)

    def setUp(self):
        self.event = 9000
        BattleLobbyTests.setUp(self)
        self.call(0, "trainer_cancel")
        self.call(1, "trainer_cancel")
        self.event = 42
        for i in (0, 1):
            self.call(i, "trainer_wait", forced=False, prototype=PERSONAL_PROTOTYPE, encounter_key="a" * 64)
            self.team(i, (0, 1, 2))
            self.call(i, "trainer_ready", ready=True)

    def foe(self, i, team=None):
        return self.call(i, "trainer_foe", team=team or [personal_pokemon()], trainer=personal_trainer())

    def test_host_freezes_effective_foes_and_only_participants_receive_them(self):
        self.assertEqual(self.call(0, "trainer_start", solo=False)["reason"], "trainer_foe_required")
        self.assertEqual(self.foe(1)["reason"], "trainer_not_host")
        self.assertEqual(self.foe(2)["reason"], "no_trainer_wait")
        self.assertEqual(self.foe(0, [personal_pokemon(i) for i in range(7)])["reason"], "invalid_trainer_foe")
        team = [personal_pokemon(i) for i in range(6)]
        pending = self.foe(0, team)
        self.assertNotIn("enemy_team", pending)
        self.assertEqual(self.foe(0, team)["phase"], "pending")  # Idempotent snapshot retry.
        team[0]["hp"] = 1
        self.assertEqual(self.foe(0, team)["reason"], "trainer_foe_fixed")
        locked = self.call(0, "trainer_start", solo=False)
        self.assertEqual(locked["encounter_key"], "a" * 64)
        self.assertEqual(len(locked["enemy_team"]), 6)
        self.assertEqual(locked["enemy_team"][0]["hp"], 31)
        self.assertEqual(locked["enemy_trainer"], personal_trainer())
        self.assertEqual(self.peers[1].messages[-1]["enemy_team"], locked["enemy_team"])
        self.assertNotIn("enemy_team", self.peers[2].messages[-1])
        self.assertEqual(self.foe(0)["reason"], "trainer_locked")
        self.assertLess(len(json.dumps(locked).encode()), 32768)

    def test_event_revision_mismatch_is_rejected_before_joining(self):
        request = dict(forced=False, prototype=PERSONAL_PROTOTYPE)
        self.assertEqual(self.call(2, "trainer_wait", **request)["reason"], "trainer_encounter_key")
        self.assertEqual(self.call(2, "trainer_wait", encounter_key="b" * 64, **request)["reason"], "trainer_incompatible")
        self.assertEqual(self.call(2, "trainer_wait", forced=False, prototype=PROTOTYPE)["reason"], "trainer_prototype")
        state = self.call(2, "trainer_wait", encounter_key="a" * 64, **request)
        self.assertEqual(len(state["participants"]), 3)

    def test_solo_does_not_need_remote_foe_snapshot(self):
        state = self.call(0, "trainer_start", solo=True)
        self.assertEqual(state["phase"], "locked")
        self.assertIsNone(state["battle"])
        self.assertNotIn("enemy_team", state)


if __name__ == "__main__":
    unittest.main()
