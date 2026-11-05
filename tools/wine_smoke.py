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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", choices=[f"client{i:02d}" for i in range(1, 5)])
    parser.add_argument("--clients", nargs="+", choices=[f"client{i:02d}" for i in range(1, 5)])
    parser.add_argument("--seconds", type=int, default=120)
    parser.add_argument("--gameslot", type=Path, required=True)
    parser.add_argument("--session")
    parser.add_argument("--port", type=int)
    parser.add_argument("--host-client")
    args = parser.parse_args()
    if os.name == "nt" or not shutil.which("wine") or not shutil.which("wineserver"):
        raise SafetyError("This smoke runner requires Linux and Wine")
    if not 10 <= args.seconds <= 600:
        raise SafetyError("Run length must be 10..600 seconds")
    selected = args.clients or ([args.client] if args.client else [])
    if args.client and args.clients:
        raise SafetyError("Choose --client or --clients")
    plan = launch_plan(ROOT, selected)["clients"]
    if args.session is not None:
        if not args.session.isalnum() or not 6 <= len(args.session) <= 12 or not args.port or not 1 <= args.port <= 65535 or args.host_client not in selected:
            raise SafetyError("Valid --session, --port and --host-client required together")
    workspace = {p["client"]: p for p in read_json(ROOT / "local/workspace.json")["clients"]}
    for client in plan:
        profile = Path(client["save_directory"]).parent
        cfg = read_json(Path(client["cwd"]) / "mkxp.json")
        if (cfg.get("preloadScript") != ["CoopDev/isolate.rb"] or
                cfg.get("dataPathApp") != workspace[client["client"]]["profile_id"] or
                not (Path(client["cwd"]) / "CoopDev/isolate.rb").is_file() or
                (profile / "profile-id.txt").read_text().strip() != workspace[client["client"]]["profile_id"]):
            raise SafetyError("Client isolation preflight failed")
        marker = profile / "bootstrap-loaded.txt"
        if marker.exists():
            marker.rename(profile / "logs" / ("bootstrap-previous-" + uuid.uuid4().hex + ".txt"))
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
    result_path = ROOT / "local/reports" / f"{owner}.json"
    try:
        for client in plan:
            profile = Path(client["save_directory"]).parent
            output = profile / "logs" / f"{owner}.log"
            run_env = dict(os.environ, **client["environment"], WINEDEBUG="-all")
            if args.session:
                run_env.update(ANIL_COOP_SESSION=args.session, ANIL_COOP_PORT=str(args.port),
                               ANIL_COOP_MODE="create" if client["client"] == args.host_client else "join",
                               ANIL_COOP_NAME=client["client"])
            with output.open("xb") as log:
                process = subprocess.Popen(client["command"], cwd=client["cwd"], env=run_env,
                                           stdout=log, stderr=subprocess.STDOUT)
            processes.append((client, process, output))
            slot("register-pid", "--pid", str(process.pid))
        deadline = time.monotonic() + args.seconds
        while any(process.poll() is None for _, process, _ in processes) and time.monotonic() < deadline:
            time.sleep(0.5)
        observations = [{"client": client["client"], "wine_pid": process.pid,
                         "exit_code_before_cleanup": process.poll(),
                         "bootstrap_observed": (Path(client["save_directory"]).parent / "bootstrap-loaded.txt").is_file(),
                         "log": str(output)} for client, process, output in processes]
        result = {"clients": observations, "duration_limit_seconds": args.seconds,
                  "gameplay_save_reload": "NOT_TESTED_BY_THIS_RUNNER"}
        write_new(result_path, result)
        print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
        return 0 if all(item["bootstrap_observed"] for item in observations) else 2
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
        slot("release")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SafetyError, OSError, subprocess.CalledProcessError) as exc:
        print(json.dumps({"status": "FAIL_OR_BLOCKED", "reason": str(exc)}))
        sys.exit(2)
