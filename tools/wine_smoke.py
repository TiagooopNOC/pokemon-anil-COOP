"""Bounded Wine smoke run against one isolated client; no gameplay automation."""
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

from h0 import ROOT, SafetyError, launch_plan, verify, write_new


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", choices=[f"client{i:02d}" for i in range(1, 5)], required=True)
    parser.add_argument("--seconds", type=int, default=120)
    parser.add_argument("--gameslot", type=Path, required=True)
    args = parser.parse_args()
    if os.name == "nt" or not shutil.which("wine") or not shutil.which("wineserver"):
        raise SafetyError("This smoke runner requires Linux and Wine")
    if not 10 <= args.seconds <= 600:
        raise SafetyError("Run length must be 10..600 seconds")
    verify(ROOT)
    client = launch_plan(ROOT, [args.client])["clients"][0]
    profile = Path(client["save_directory"]).parent
    prefix = Path(client["environment"]["WINEPREFIX"])
    if (profile / "bootstrap-loaded.txt").exists():
        raise SafetyError("Previous bootstrap evidence exists; inspect before another run")
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
    process = None
    output = profile / "logs" / f"{owner}.log"
    result_path = ROOT / "local/reports" / f"{owner}.json"
    try:
        run_env = dict(os.environ, **client["environment"], WINEDEBUG="-all")
        with output.open("xb") as log:
            process = subprocess.Popen(client["command"], cwd=client["cwd"], env=run_env,
                                       stdout=log, stderr=subprocess.STDOUT)
            slot("register-pid", "--pid", str(process.pid))
            deadline = time.monotonic() + args.seconds
            while process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.5)
        result = {"client": args.client, "wine_pid": process.pid,
                  "exit_code_before_cleanup": process.poll(),
                  "bootstrap_observed": (profile / "bootstrap-loaded.txt").is_file(),
                  "log": str(output), "duration_limit_seconds": args.seconds,
                  "gameplay_save_reload": "NOT_TESTED_BY_THIS_RUNNER"}
        write_new(result_path, result)
        print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
        return 0 if result["bootstrap_observed"] else 2
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        # This prefix belongs only to this disposable client. No global process kill.
        subprocess.run(["wineserver", "-k"], env=dict(os.environ, WINEPREFIX=str(prefix)),
                       capture_output=True, timeout=15)
        slot("release")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SafetyError, OSError, subprocess.CalledProcessError) as exc:
        print(json.dumps({"status": "FAIL_OR_BLOCKED", "reason": str(exc)}))
        sys.exit(2)
