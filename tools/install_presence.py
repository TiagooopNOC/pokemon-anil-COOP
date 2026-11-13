"""Install the mod overlay into prepared game copies."""
import argparse
import json
from pathlib import Path
import shutil
import sys
import uuid

if __package__:
    from .h0 import ROOT, SafetyError, digest, ignore_progress, launch_plan, no_links, read_json
else:
    from h0 import ROOT, SafetyError, digest, ignore_progress, launch_plan, no_links, read_json


GAME_SCRIPTS = (
    "coop.rb",
    "coop_battle.rb",
    "coop_trainers.rb",
    "coop_challenge.rb",
    "coop_result.rb",
    "coop_team.rb",
    "coop_menus.rb",
    "coop_speed.rb",
    "coop_title.rb",
    "coop_online.rb",
    "coop_online_screen.rb",
    "coop_online_map.rb",
    "coop_online_team.rb",
    "coop_online_invites.rb",
    "online_invite_qa.rb",
    "online_team_qa.rb",
    "online_qa.rb",
    "menu_qa.rb",
    "presence_qa.rb",
    "story_qa.rb",
    "challenge_qa.rb",
    "battle_qa.rb",
    "speed_qa.rb",
    "loader.rb",
)


def replace_file(target, write):
    """Publish each overlay file atomically so a retry can finish an update."""
    temp = target.with_name(f".{target.name}-{uuid.uuid4().hex}.tmp")
    try:
        write(temp)
        temp.replace(target)
    finally:
        temp.unlink(missing_ok=True)


def install_presence(repo, clients, *, assets=None, progress=ignore_progress):
    assets = assets or repo
    sources = [assets / "src/bootstrap/isolate.rb", *(assets / "src/game" / name for name in GAME_SCRIPTS)]
    fingerprints = {source: digest(source) for source in sources}
    entries = launch_plan(repo, clients)["clients"]
    total = len(entries) * (len(sources) + 1)
    done = 0
    progress("overlay", done, total)
    for entry in entries:
        game = Path(entry["cwd"])
        profile = Path(entry["save_directory"]).parent
        overlay = no_links(game / "CoopDev")
        logs = no_links(profile / "logs")
        config_path = no_links(game / "mkxp.json")
        config = read_json(config_path)
        if config.get("preloadScript") != ["CoopDev/isolate.rb"]:
            raise SafetyError("Save isolation missing; refuse installation")
        old = config.get("postloadScript")
        if old not in (None, ["CoopDev/coop.rb"], ["CoopDev/loader.rb"]):
            raise SafetyError("Unexpected postload script")
        for original, backup in ((config_path, logs / "mkxp-before-presence.json"),
                                 (overlay / "isolate.rb", logs / "isolate-before-presence.rb")):
            no_links(original)
            if not no_links(backup).exists():
                replace_file(backup, lambda temp: shutil.copy2(original, temp))
        for source, expected in fingerprints.items():
            target = no_links(overlay / source.name)
            current = digest(target) if target.is_file() else None
            if current != expected:
                if current and target.name in ("coop.rb", "coop_battle.rb"):
                    prefix = "coop" if target.name == "coop.rb" else "battle"
                    backup = no_links(logs / f"{prefix}-previous-{current[:12]}.rb")
                    if not backup.exists():
                        replace_file(backup, lambda temp: shutil.copy2(target, temp))
                replace_file(target, lambda temp: shutil.copy2(source, temp))
            if digest(target) != expected:
                raise SafetyError(f"Overlay integrity failed: {source.name}")
            done += 1
            progress("overlay", done, total)
        if "postloadScript" in config:
            config.pop("postloadScript")
            contents = json.dumps(config, ensure_ascii=False, indent=2) + "\n"
            replace_file(config_path, lambda temp: temp.write_text(contents, encoding="utf-8"))
        done += 1
        progress("overlay", done, total)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--clients", nargs="+", required=True)
    args = parser.parse_args()
    install_presence(ROOT, args.clients)
    for client in args.clients:
        print(f"installed own presence overlay: {client}")


if __name__ == "__main__":
    try:
        main()
    except (SafetyError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(2)
