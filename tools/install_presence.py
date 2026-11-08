"""Install own late-loaded presence script into prepared test copies only."""
import argparse
import json
from pathlib import Path
import shutil
import sys

from h0 import ROOT, SafetyError, digest, launch_plan


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--clients", nargs="+", required=True)
    args = parser.parse_args()
    source = ROOT / "src/game/coop.rb"
    loader = ROOT / "src/game/loader.rb"
    bootstrap = ROOT / "src/bootstrap/isolate.rb"
    for entry in launch_plan(ROOT, args.clients)["clients"]:
        game = Path(entry["cwd"])
        profile = Path(entry["save_directory"]).parent
        target = game / "CoopDev/coop.rb"
        config_path = game / "mkxp.json"
        config = json.loads(config_path.read_text())
        if config.get("preloadScript") != ["CoopDev/isolate.rb"]:
            raise SafetyError("Save isolation missing; refuse installation")
        old = config.get("postloadScript")
        if old not in (None, ["CoopDev/coop.rb"], ["CoopDev/loader.rb"]):
            raise SafetyError("Unexpected postload script")
        backup = profile / "logs/mkxp-before-presence.json"
        if not backup.exists():
            shutil.copy2(config_path, backup)
        original_bootstrap = game / "CoopDev/isolate.rb"
        old_bootstrap = profile / "logs/isolate-before-presence.rb"
        if not old_bootstrap.exists():
            shutil.copy2(original_bootstrap, old_bootstrap)
        shutil.copy2(bootstrap, original_bootstrap)
        if target.exists() and digest(target) != digest(source):
            previous = profile / "logs" / ("coop-previous-" + digest(target)[:12] + ".rb")
            if not previous.exists():
                shutil.copy2(target, previous)
        shutil.copy2(source, target)
        battle_target = game / "CoopDev/coop_battle.rb"
        if battle_target.exists():
            previous = profile / "logs" / ("battle-previous-" + digest(battle_target)[:12] + ".rb")
            if not previous.exists():
                shutil.copy2(battle_target, previous)
        shutil.copy2(ROOT / "src/game/coop_battle.rb", battle_target)
        shutil.copy2(ROOT / "src/game/coop_trainers.rb", game / "CoopDev/coop_trainers.rb")
        shutil.copy2(ROOT / "src/game/coop_result.rb", game / "CoopDev/coop_result.rb")
        shutil.copy2(ROOT / "src/game/coop_team.rb", game / "CoopDev/coop_team.rb")
        shutil.copy2(ROOT / "src/game/coop_menus.rb", game / "CoopDev/coop_menus.rb")
        shutil.copy2(ROOT / "src/game/coop_title.rb", game / "CoopDev/coop_title.rb")
        shutil.copy2(ROOT / "src/game/menu_qa.rb", game / "CoopDev/menu_qa.rb")
        shutil.copy2(ROOT / "src/game/presence_qa.rb", game / "CoopDev/presence_qa.rb")
        shutil.copy2(ROOT / "src/game/battle_qa.rb", game / "CoopDev/battle_qa.rb")
        shutil.copy2(loader, game / "CoopDev/loader.rb")
        # Añil does not call rgss_main, so mkxp's postloadScript never runs.
        # The preloaded isolation script triggers this loader after plugins run.
        config.pop("postloadScript", None)
        config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n")
        print(f"installed own presence overlay: {entry['client']}")


if __name__ == "__main__":
    try:
        main()
    except (SafetyError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(2)
