"""Run two native Windows clients in a disposable QA workspace under local/."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import threading
import uuid

from src.client.bridge import Bridge
from src.server import session_server
from src.server.session_server import Server, State
from tools.h0 import ROOT, launch_plan, launch_windows, no_links, prepare
from tools.install_presence import install_presence

SCENARIOS = ("host", "guest", "decline", "switch", "disconnect", "weather", "status",
             "priority", "draw", "ability", "ability_out", "freeze", "form", "both_switch", "wait",
             "restart", "random", "random_both", "nuzlocke", "randomlocke", "silent",
             "selection_disconnect", "animation_disconnect", "exit", "brock")


def run(source, scenario):
    if os.name != "nt":
        raise RuntimeError("Windows x64 required")
    workspace = ROOT / "local" / f"pvp-qa-{uuid.uuid4().hex}"
    print(f"QA workspace: {workspace}", flush=True)

    def progress(phase, done=0, total=0):
        if done == 0 or done == total:
            print(f"{phase}: {done}/{total}", flush=True)

    prepare(workspace, source, 2, assets=ROOT, progress=progress)
    (workspace / "pvp-qa.marker").touch(exist_ok=False)
    run_prepared(workspace, scenario)


def run_prepared(workspace, scenario):
    names = ["client01", "client02"]
    install_presence(workspace, names, assets=ROOT)
    plans = launch_plan(workspace, names)["clients"]
    fixture = (ROOT / "tests/pvp_windows_qa.rb").read_bytes()
    for plan in plans:
        overlay = Path(plan["cwd"]) / "CoopDev"
        no_links(overlay / "pvp_windows_qa.rb").write_bytes(fixture)
        with no_links(overlay / "loader.rb").open("ab") as loader:
            loader.write(b'\nload "CoopDev/pvp_windows_qa.rb" if ENV["ANIL_PVP_QA_PHASE"]\n')

    class SilentState(State):
        def handle(self, sock, message, identity):
            if message.get("type") == "ping" and identity:
                room = self.rooms.get(identity[0])
                if room and any(duel.last_stage == "setup" for duel in room["duels"].values()):
                    return None, identity
            return super().handle(sock, message, identity)

    session_server.STATE = SilentState() if scenario == "silent" else State()

    with Server(("127.0.0.1", 0)) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        bridge = Bridge("127.0.0.1", server.server_address[1], server.secret)

        def launch(plan, role, phase):
            report_name = ("qa-2v2-result.json" if scenario == "brock" and phase == "duel"
                           else "qa-pvp-result.json")
            profile = Path(plan["save_directory"]).parent
            report = profile / report_name
            report.unlink(missing_ok=True)
            launch_windows(workspace, [plan["client"]], None, environment={
                "ANIL_COOP_PVP": "1", "ANIL_PVP_QA_MODE": scenario,
                "ANIL_COOP_SESSION": "PVPQA1" if phase == "duel" else "",
                "ANIL_COOP_PORT": str(bridge.port), "ANIL_COOP_MODE": role,
                "ANIL_COOP_NAME": ("client03" if role == "create" else "client04")
                if scenario == "brock" else plan["client"],
                "ANIL_PVP_QA_PHASE": phase,
            })
            result = json.loads(report.read_text(encoding="utf-8"))
            report.replace(profile / "logs" / f"pvp-qa-{scenario}-{phase}.json")
            return result

        try:
            with ThreadPoolExecutor(max_workers=2) as pool:
                def pair(phase):
                    jobs = [pool.submit(launch, plan, role, phase)
                            for plan, role in zip(plans, ("create", "join"))]
                    return [job.result() for job in jobs]

                created = pair("create")
                assert all(row.get("created") for row in created), created
                results = pair("duel")
                if scenario != "brock":
                    phase = "reload" if all(row.get("complete") for row in results) else "verify"
                    reloaded = pair(phase)
                    assert all(row.get("cold_reload") for row in reloaded), (results, reloaded)
                    for row in results:
                        row["cold_reload"] = True
        finally:
            bridge.close()
            server.shutdown()
            thread.join()
    print(json.dumps(results, ensure_ascii=False))
    if scenario == "brock":
        assert all(row.get("pass") and row.get("brock_badge") and row.get("brock_progress")
                   for row in results), results
        return
    assert all(row.get("originals") and row.get("save_intact") and row.get("map_restored") and
               row.get("logical_intact") for row in results if not row.get("exited")), results
    if scenario == "decline":
        assert all(row["declined"] and row["connected"] for row in results)
    elif scenario in ("disconnect", "selection_disconnect", "animation_disconnect"):
        assert results[0]["error"] == "battle_disconnect"
        expected = "connection lost" if scenario == "selection_disconnect" else "QA transport closed"
        assert results[1]["error"] == expected, results
    elif scenario == "silent":
        assert all(row["error"] == "battle_server_silent" for row in results), results
    elif scenario == "exit":
        assert results[0]["error"] in ("battle_disconnect", "battle_cancelled") and results[1]["exited"]
    else:
        assert all(row["complete"] and row["connected"] and row["reload"] and row["position_after"] and
                   row["turns"] >= 2 for row in results)
        decisions = [row["decision"] for row in results]
        rounds = results[0]["rounds"]
        assert rounds == results[1]["rounds"], "Replicas disagreed on round evidence"
        if scenario == "weather":
            assert {row["weather"] for row in rounds} >= {"Rain", "Sun", "Sandstorm", "Hail"}
        if scenario == "status":
            assert {row["sides"][1][0] for row in rounds} >= {"PARALYSIS", "BURN", "POISON", "SLEEP"}
        if scenario == "both_switch":
            assert [side[1] for side in rounds[0]["sides"]] == [1, 1]
        if scenario == "priority":
            assert any(row["sides"][0][4] == "FLY" for row in rounds)
        if scenario == "freeze":
            assert rounds[0]["sides"][1][0] in ("FROSTBITE", "FROZEN")
        if scenario == "ability":
            assert rounds[0]["weather"] == "Sun"
        if scenario == "ability_out":
            assert rounds[1]["sides"][0][1] == 1
            assert rounds[1]["party_hp"][0][0] > rounds[0]["party_hp"][0][0]
        if scenario == "form":
            assert all(side[7] == 1 for side in rounds[0]["sides"])
        if scenario == "draw":
            assert decisions == [5, 5]
        elif scenario in ("switch", "random", "random_both", "randomlocke", "nuzlocke"):
            assert sorted(decisions) == [1, 2]
        else:
            assert decisions == ([2, 1] if scenario == "guest" else [1, 2])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--source", type=Path)
    source.add_argument("--qa-workspace", type=Path, help="Reuse a disposable workspace created by this runner")
    parser.add_argument("--scenario", choices=SCENARIOS, default="host")
    args = parser.parse_args()
    if args.qa_workspace:
        workspace = no_links(args.qa_workspace)
        if (workspace.parent != no_links(ROOT / "local") or not workspace.name.startswith("pvp-qa-")
                or not no_links(workspace / "pvp-qa.marker").is_file()):
            parser.error("--qa-workspace must identify a disposable local/pvp-qa-* directory")
        run_prepared(workspace, args.scenario)
    else:
        run(args.source, args.scenario)


if __name__ == "__main__":
    main()
