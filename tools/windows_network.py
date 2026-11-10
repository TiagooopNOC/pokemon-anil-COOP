"""Native Windows client with an authenticated local bridge."""
import argparse
import json
import os
import sys
from pathlib import Path

from h0 import ROOT, SafetyError, launch_plan, launch_windows
sys.path.insert(0, str(ROOT))
from src.client.bridge import Bridge, LOCAL_SECRET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", choices=[f"client{i:02d}" for i in range(1, 5)], required=True)
    parser.add_argument("--server-host", required=True)
    parser.add_argument("--port", type=int, default=17641)
    parser.add_argument("--session", required=True)
    parser.add_argument("--mode", choices=("create", "join"), required=True)
    parser.add_argument("--gameslot", type=Path, required=True)
    parser.add_argument("--qa-2v2", action="store_true", help="Experimental NPC with temporary teams, no rewards/saves")
    parser.add_argument("--personal-team", action="store_true")
    parser.add_argument("--coop-battles", action="store_true")
    args = parser.parse_args()
    if args.personal_team and not (args.qa_2v2 or args.coop_battles):
        raise SafetyError("--personal-team currently requires --qa-2v2")
    if os.name != "nt":
        raise SafetyError("Use tools/wine_smoke.py on Linux")
    if not 1 <= args.port <= 65535 or not 6 <= len(args.session) <= 12 or not args.session.isalnum():
        raise SafetyError("Invalid port or session code")
    secret = os.environ.get("ANIL_COOP_SECRET")
    if args.server_host not in ("127.0.0.1", "localhost") and (not secret or len(secret) < 16):
        raise SafetyError("Set ANIL_COOP_SECRET (at least 16 characters) for LAN/VPN")
    game = Path(launch_plan(ROOT, [args.client])["clients"][0]["cwd"])
    if not all((game / "CoopDev" / filename).is_file() for filename in ("coop.rb", "coop_team.rb", "coop_trainers.rb", "coop_challenge.rb", "coop_result.rb", "coop_battle.rb", "coop_menus.rb", "loader.rb")):
        raise SafetyError("Co-op overlay missing: run packaging/windows/Prepare.ps1 first")
    bridge = Bridge(args.server_host, args.port, secret or LOCAL_SECRET)
    names = ("ANIL_COOP_SESSION", "ANIL_COOP_PORT", "ANIL_COOP_HOST", "ANIL_COOP_MODE", "ANIL_COOP_NAME")
    previous = {key: os.environ.get(key) for key in names}
    try:
        os.environ.update(ANIL_COOP_SESSION=args.session, ANIL_COOP_PORT=str(bridge.port),
                          ANIL_COOP_HOST="127.0.0.1", ANIL_COOP_MODE=args.mode,
                          ANIL_COOP_NAME=args.client)
        return launch_windows(ROOT, [args.client], args.gameslot.resolve(), qa_2v2=args.qa_2v2, personal_team=args.personal_team, coop_battles=args.coop_battles)
    finally:
        bridge.close()
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


if __name__ == "__main__":
    try:
        print(json.dumps(main(), ensure_ascii=False, indent=2))
    except (SafetyError, OSError, ValueError) as exc:
        print(json.dumps({"status": "FAIL_OR_BLOCKED", "reason": str(exc)}))
        sys.exit(2)
