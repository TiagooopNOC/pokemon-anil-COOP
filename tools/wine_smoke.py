"""Bounded Wine smoke run against one to four isolated clients."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

from h0 import ROOT, SafetyError, launch_plan, read_json, write_new
sys.path.insert(0, str(ROOT))
from src.client.bridge import Bridge, LOCAL_SECRET
from src.server.session_server import private_bind


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", choices=[f"client{i:02d}" for i in range(1, 5)])
    parser.add_argument("--clients", nargs="+", choices=[f"client{i:02d}" for i in range(1, 5)])
    parser.add_argument("--seconds", type=int, default=120)
    parser.add_argument("--gameslot", type=Path, required=True)
    parser.add_argument("--session")
    parser.add_argument("--port", type=int)
    parser.add_argument("--host-client")
    parser.add_argument("--server-host", default="127.0.0.1")
    parser.add_argument("--qa-wild-client", action="append", default=[])
    parser.add_argument("--qa-trainer", action="store_true")
    parser.add_argument("--qa-2v2", action="store_true", help="Experimental NPC fixture, temporary teams, no rewards/saves")
    parser.add_argument("--qa-battle-bot", choices=("engine", "visual"))
    parser.add_argument("--qa-presence", action="store_true", help="Run native remote-motion checks without OS input")
    parser.add_argument("--play", action="store_true", help="Run until the player closes the game")
    parser.add_argument("--coop-battles", action="store_true")
    parser.add_argument("--personal-team", action="store_true")
    parser.add_argument("--qa-scenario", choices=("basic", "automatic-target", "status", "switch", "loss", "disconnect", "menu-disconnect", "desync", "rewards", "personal", "personal-reserves", "personal-share", "personal-npc", "personal-event"), default="basic")
    parser.add_argument("--qa-starter", action="append", default=[], metavar="CLIENT:SPECIES")
    parser.add_argument("--qa-randomlocke", action="append", default=[], metavar="CLIENT")
    args = parser.parse_args()
    if os.name == "nt" or not shutil.which("wine") or not shutil.which("wineserver"):
        raise SafetyError("This smoke runner requires Linux and Wine")
    if args.play and args.qa_battle_bot:
        raise SafetyError("Unbounded play cannot use a QA bot")
    if not 10 <= args.seconds <= 600:
        raise SafetyError("Run length must be 10..600 seconds")
    selected = args.clients or ([args.client] if args.client else [])
    if args.qa_2v2 and (not args.qa_trainer or not args.session or len(selected) != 2):
        raise SafetyError("--qa-2v2 requires --qa-trainer, --session and exactly two clients")
    if args.qa_battle_bot and not args.qa_2v2:
        raise SafetyError("--qa-battle-bot requires --qa-2v2")
    if args.client and args.clients:
        raise SafetyError("Choose --client or --clients")
    plan = launch_plan(ROOT, selected)["clients"]
    if any(client not in selected for client in args.qa_wild_client):
        raise SafetyError("--qa-wild-client must be one of the selected clients")
    if any(":" not in entry for entry in args.qa_starter):
        raise SafetyError("--qa-starter requires CLIENT:SPECIES")
    starters = dict(entry.split(":", 1) for entry in args.qa_starter)
    if any(client not in selected or species not in ("BULBASAUR", "CHARMANDER", "SQUIRTLE") for client, species in starters.items()):
        raise SafetyError("--qa-starter requires selected CLIENT:BULBASAUR|CHARMANDER|SQUIRTLE")
    if any(client not in starters for client in args.qa_randomlocke):
        raise SafetyError("--qa-randomlocke requires a matching --qa-starter")
    if args.session is not None:
        if not args.session.isalnum() or not 6 <= len(args.session) <= 12 or not args.port or not 1 <= args.port <= 65535 or (args.host_client is not None and args.host_client not in selected):
            raise SafetyError("Valid --session, --port and optional --host-client required together")
    secret = os.environ.get("ANIL_COOP_SECRET")
    if args.session:
        try:
            allowed_host = args.server_host == "localhost" or private_bind(args.server_host)
        except ValueError:
            allowed_host = False
        if not allowed_host:
            raise SafetyError("--server-host must be a private IPv4 address")
    if args.session and args.server_host not in ("127.0.0.1", "localhost") and (not secret or len(secret) < 16):
        raise SafetyError("Set ANIL_COOP_SECRET (at least 16 characters) for LAN/VPN")
    workspace = {p["client"]: p for p in read_json(ROOT / "local/workspace.json")["clients"]}
    for client in plan:
        profile = Path(client["save_directory"]).parent
        cfg = read_json(Path(client["cwd"]) / "mkxp.json")
        if (cfg.get("preloadScript") != ["CoopDev/isolate.rb"] or
                cfg.get("dataPathApp") != workspace[client["client"]]["profile_id"] or
                not (Path(client["cwd"]) / "CoopDev/isolate.rb").is_file() or
                not (Path(client["cwd"]) / "CoopDev/coop.rb").is_file() or
                not (Path(client["cwd"]) / "CoopDev/loader.rb").is_file() or
                (profile / "profile-id.txt").read_text().strip() != workspace[client["client"]]["profile_id"]):
            raise SafetyError("Client isolation preflight failed")
        marker = profile / "bootstrap-loaded.txt"
        if marker.exists():
            marker.rename(profile / "logs" / ("bootstrap-previous-" + uuid.uuid4().hex + ".txt"))
        qa_result = profile / "qa-2v2-result.json"
        if args.qa_battle_bot and qa_result.exists():
            qa_result.rename(profile / "logs" / ("qa-2v2-previous-" + uuid.uuid4().hex + ".json"))
        presence_result = profile / "qa-presence-result.json"
        if args.qa_presence and presence_result.exists():
            presence_result.rename(profile / "logs" / ("qa-presence-previous-" + uuid.uuid4().hex + ".json"))
    slot_tool = args.gameslot.resolve()
    if not slot_tool.is_file():
        raise SafetyError("Reviewed GameSlot path is missing")
    state = ROOT / "local/gameslot"
    state.mkdir(exist_ok=True)
    config = state / "gameslot_config.json"
    if not config.exists():
        write_new(config, {"slots": 4, "min_free_gb": 3.0, "process_name": "Game.exe"})
    slot_env = dict(os.environ, GAMESLOT_DIR=str(state))
    owner = "anil-wine-" + uuid.uuid4().hex
    def slot(*arguments):
        subprocess.run([sys.executable, "-I", str(slot_tool), *arguments, "--owner", owner],
                       env=slot_env, check=True, capture_output=True, text=True)
    slot("acquire", "--exclusive", "--ttl", str(args.seconds + 120), "--wait", "0")
    processes = []
    bridges = []
    result_path = ROOT / "local/reports" / f"{owner}.json"
    try:
        for client in plan:
            profile = Path(client["save_directory"]).parent
            output = profile / "logs" / f"{owner}.log"
            run_env = dict(os.environ, **client["environment"], WINEDEBUG="-all")
            run_env.pop("ANIL_COOP_QA_WILD", None)
            run_env.pop("ANIL_COOP_QA_TRAINER", None)
            run_env.pop("ANIL_COOP_QA_STARTER", None)
            run_env.pop("ANIL_COOP_QA_RANDOMLOCKE", None)
            run_env.pop("ANIL_COOP_QA_2V2", None)
            run_env.pop("ANIL_COOP_QA_BOT", None)
            run_env.pop("ANIL_COOP_QA_SCENARIO", None)
            run_env.pop("ANIL_COOP_PRESENCE_QA", None)
            run_env.pop("ANIL_COOP_PERSONAL_TEAM", None)
            run_env.pop("ANIL_COOP_BATTLES", None)
            if args.coop_battles:
                run_env.update(ANIL_COOP_BATTLES="1", ANIL_COOP_PERSONAL_TEAM="1")
            if args.personal_team or args.qa_scenario.startswith("personal"):
                run_env["ANIL_COOP_PERSONAL_TEAM"] = "1"
            if args.qa_battle_bot:
                run_env.update(ANIL_COOP_QA_BOT=args.qa_battle_bot, ANIL_COOP_QA_SCENARIO=args.qa_scenario)
            if args.qa_presence:
                run_env["ANIL_COOP_PRESENCE_QA"] = "1"
            if args.qa_2v2:
                run_env["ANIL_COOP_QA_2V2"] = "1"
            if client["client"] in args.qa_wild_client:
                run_env["ANIL_COOP_QA_WILD"] = "1"
            if args.qa_trainer:
                run_env["ANIL_COOP_QA_TRAINER"] = "1"
            if client["client"] in starters:
                run_env["ANIL_COOP_QA_STARTER"] = starters[client["client"]]
            if client["client"] in args.qa_randomlocke:
                run_env["ANIL_COOP_QA_RANDOMLOCKE"] = "1"
            if args.session:
                bridge = Bridge(args.server_host, args.port, secret or LOCAL_SECRET)
                bridges.append(bridge)
                run_env.update(ANIL_COOP_SESSION=args.session, ANIL_COOP_PORT=str(bridge.port),
                               ANIL_COOP_HOST="127.0.0.1",
                               ANIL_COOP_MODE="create" if client["client"] == args.host_client else "join",
                               ANIL_COOP_NAME=client["client"])
            run_env.pop("ANIL_COOP_SECRET", None)
            with output.open("xb") as log:
                process = subprocess.Popen(client["command"], cwd=client["cwd"], env=run_env,
                                           stdout=log, stderr=subprocess.STDOUT)
            processes.append((client, process, output))
            slot("register-pid", "--pid", str(process.pid))
        deadline = time.monotonic() + args.seconds
        renewed = time.monotonic()
        while any(process.poll() is None for _, process, _ in processes) and (args.play or time.monotonic() < deadline):
            if args.play and time.monotonic() - renewed >= 60:
                slot("acquire", "--exclusive", "--ttl", str(args.seconds + 120), "--wait", "0")
                renewed = time.monotonic()
            time.sleep(0.5)
        observations = [{"client": client["client"], "wine_pid": process.pid,
                         "exit_code_before_cleanup": process.poll(),
                         "bootstrap_observed": (Path(client["save_directory"]).parent / "bootstrap-loaded.txt").is_file(),
                         "log": str(output)} for client, process, output in processes]
        result = {"clients": observations, "duration_limit_seconds": args.seconds,
                  "gameplay_save_reload": "NOT_TESTED_BY_THIS_RUNNER"}
        if args.qa_battle_bot:
            for observation, client in zip(observations, plan):
                report = Path(client["save_directory"]).parent / "qa-2v2-result.json"
                observation["battle_qa"] = read_json(report) if report.is_file() else {"pass": False, "error": "missing result"}
        if args.qa_presence:
            for observation, client in zip(observations, plan):
                report = Path(client["save_directory"]).parent / "qa-presence-result.json"
                observation["presence_qa"] = read_json(report) if report.is_file() else {"pass": False, "error": "missing result"}
        write_new(result_path, result)
        print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
        return 0 if all(item["bootstrap_observed"] and
                        (not args.qa_battle_bot or item["battle_qa"]["pass"]) and
                        (not args.qa_presence or item["presence_qa"]["pass"])
                        for item in observations) else 2
    finally:
        for client, process, _ in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for client, _, _ in processes:
            prefix = client["environment"]["WINEPREFIX"]
            subprocess.run(["wineserver", "-k"], env=dict(os.environ, WINEPREFIX=prefix),
                           capture_output=True, timeout=15)
        for bridge in bridges:
            bridge.close()
        slot("release")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SafetyError, OSError, subprocess.CalledProcessError) as exc:
        print(json.dumps({"status": "FAIL_OR_BLOCKED", "reason": str(exc)}))
        sys.exit(2)
