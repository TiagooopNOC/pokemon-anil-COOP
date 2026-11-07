"""Safe, cross-platform Hito 0 workspace preparation (Python 3.10+)."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import time
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (".gitignore", ".gitattributes", "README.md", "config/build.json",
            "src/bootstrap/isolate.rb", "tools/h0.py", "tools/wine_smoke.py",
            "tests/test_h0.py",
            "docs/architecture.md", "docs/requirements.md", "docs/hito-0.md",
            "docs/third-party.md", "packaging/windows/Prepare.ps1",
            "packaging/windows/Launch.ps1")
PACKAGE_DIRS = ("config", "src", "tools", "tests", "docs", "packaging")


class SafetyError(RuntimeError):
    """Refuse an operation rather than guess about isolation."""


def no_links(path: Path) -> Path:
    path = Path(os.path.abspath(path))
    for p in (path, *path.parents):
        reparse = (getattr(p.lstat(), "st_file_attributes", 0) & 0x400) if p.exists() else 0
        if p.is_symlink() or reparse or (hasattr(p, "is_junction") and p.is_junction()):
            raise SafetyError(f"Symlink/junction not allowed: {p}")
    return path


def disjoint(a: Path, b: Path) -> None:
    a, b = no_links(a).resolve(), no_links(b).resolve()
    if a == b or a in b.parents or b in a.parents:
        raise SafetyError("Source and development workspace must be disjoint")


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_new(path: Path, value) -> None:
    no_links(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8", newline="\n") as f:
        json.dump(value, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


def parse_jsonc(text: str) -> dict:
    # Preserve strings such as URLs; strip only actual // and /* */ comments.
    tokens = r'("(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/)'
    clean = re.sub(tokens, lambda m: m[0] if m[0].startswith('"') else " ", text)
    # mkxp accepts a final comma; the supplied configuration uses one.
    clean = re.sub(r'"(?:\\.|[^"\\])*"|,\s*([}\]])',
                   lambda m: m[1] if m[1] else m[0], clean)
    result = json.loads(clean)
    if not isinstance(result, dict):
        raise SafetyError("mkxp.json must be an object")
    return result


def snapshot(root: Path) -> dict:
    no_links(root)
    if not root.is_dir():
        raise SafetyError(f"Directory missing: {root}")
    files = {}
    for current, dirs, names in os.walk(root, followlinks=False):
        for name in dirs + names:
            p = Path(current) / name
            no_links(p)
            if p.is_file():
                if not stat.S_ISREG(p.stat().st_mode):
                    raise SafetyError(f"Not a regular file: {p}")
                files[p.relative_to(root).as_posix()] = {
                    "size": p.stat().st_size, "sha256": digest(p)}
            elif not p.is_dir():
                raise SafetyError(f"Unsupported filesystem entry: {p}")
    return files


def differences(expected: dict, actual: dict) -> list[str]:
    return [key for key in sorted(expected.keys() | actual.keys())
            if expected.get(key) != actual.get(key)]


def is_save(name: str) -> bool:
    # No personal saves are imported, even if somebody placed them in the install.
    base = Path(name).name
    return bool(re.match(r"^(Game|Partida\s*\d+|Auto\s*\d+|Backup.*)\.rxdata(?:\..*)?$",
                         base, re.IGNORECASE))


def validate_build(source: Path, build: dict) -> None:
    for name, expected in build["critical"].items():
        path = no_links(source / name)
        if not path.is_file() or digest(path) != expected:
            raise SafetyError(f"Unsupported/changed game build: {name}")
    if (source / "CoopDev").exists():
        raise SafetyError("Source already contains a development overlay")


def record_baseline(repo: Path, source: Path) -> dict:
    disjoint(repo, source)
    validate_build(source, read_json(repo / "config/build.json"))
    manifest = repo / "local/original.json"
    if manifest.exists():
        baseline = read_json(no_links(manifest))
        if Path(baseline["source"]).resolve() != source.resolve():
            raise SafetyError("Existing baseline belongs to another source")
        changed = differences(baseline["files"], snapshot(source))
        if changed:
            raise SafetyError(f"Original differs from baseline: {changed[:10]}")
        return baseline
    baseline = {"schema": 1, "source": str(source.resolve()), "files": snapshot(source)}
    write_new(manifest, baseline)
    return baseline


def prepare(repo: Path, source: Path, count: int) -> dict:
    if not 1 <= count <= 4:
        raise SafetyError("Client count must be between 1 and 4")
    source = no_links(source).resolve()
    disjoint(repo, source)
    local = no_links(repo / "local")
    clients = no_links(local / "clients")
    if clients.exists() or (local / "workspace.json").exists():
        raise SafetyError("Workspace already prepared; verify it, never overwrite profiles")
    if list(local.glob(".prepare-*")):
        raise SafetyError("Incomplete preparation exists; inspect its manifest before retrying")
    baseline = record_baseline(repo, source)
    files = {k: v for k, v in baseline["files"].items() if not is_save(k)}
    required = sum(v["size"] for v in files.values()) * count
    if shutil.disk_usage(local).free < required + 100 * 1024 * 1024:
        raise SafetyError("Insufficient disk space for independent copies")
    config = parse_jsonc((source / "mkxp.json").read_text(encoding="utf-8-sig"))
    if config.get("customScript") or config.get("preloadScript") or config.get("postloadScript"):
        raise SafetyError("Unexpected custom/pre/post scripts: review before preparing")
    stage = local / (".prepare-" + uuid.uuid4().hex)
    stage.mkdir()
    profiles = []
    for index in range(1, count + 1):
        client = f"client{index:02d}"
        token = uuid.uuid4().hex
        base = stage / client
        game, profile = base / "game", base / "profile"
        for directory in (game, profile / "saves", profile / "logs",
                          profile / "appdata", profile / "localappdata", base / "wine-prefix"):
            directory.mkdir(parents=True, exist_ok=True)
        for name in files:
            dest = game / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name, dest)  # Never hardlink or symlink game files.
        shutil.copy2(game / "mkxp.json", profile / "mkxp.original.json")
        overlay = game / "CoopDev"
        overlay.mkdir()
        shutil.copy2(repo / "src/bootstrap/isolate.rb", overlay / "isolate.rb")
        for marker in (overlay / "profile-id.txt", profile / "profile-id.txt"):
            marker.write_text(token + "\n", encoding="ascii")
        patched = dict(config, dataPathOrg="AnilCoopDev", dataPathApp=token,
                       preloadScript=["CoopDev/isolate.rb"], fullscreen=False,
                       windowTitle=f"Anil Co-op H0 - {client}")
        (game / "mkxp.json").write_text(json.dumps(patched, indent=2, ensure_ascii=False) + "\n",
                                        encoding="utf-8")
        overrides = {name: {"size": (game / name).stat().st_size,
                            "sha256": digest(game / name)} for name in
                     ("mkxp.json", "CoopDev/isolate.rb", "CoopDev/profile-id.txt")}
        profiles.append({"client": client, "profile_id": token, "overrides": overrides})
    if differences(baseline["files"], snapshot(source)):
        raise SafetyError("Source changed while copying; staged copies retained for inspection")
    write_new(stage / "preparation.json", {"clients": profiles})
    stage.rename(clients)
    result = {"schema": 1, "clients": profiles,
              "excluded_saves": sorted(set(baseline["files"]) - set(files))}
    write_new(local / "workspace.json", result)
    return {"status": "PREPARED", "clients": count, "files_per_base": len(files),
            "excluded_saves": result["excluded_saves"], "runtime_tested": False}


def verify(repo: Path, include_source: bool = True) -> dict:
    local = no_links(repo / "local")
    baseline = read_json(no_links(local / "original.json"))
    workspace = read_json(no_links(local / "workspace.json"))
    source = Path(baseline["source"])
    disjoint(repo, source)
    if include_source:
        changed = differences(baseline["files"], snapshot(source))
        if changed:
            raise SafetyError(f"Original integrity failed: {changed[:10]}")
    base_files = {k: v for k, v in baseline["files"].items() if not is_save(k)}
    identities, tokens = set(), set()
    if not 1 <= len(workspace["clients"]) <= 4:
        raise SafetyError("Invalid number of profiles")
    if include_source:
        for name in base_files:
            stat = (source / name).stat()
            identities.add((stat.st_dev, stat.st_ino))
    for entry in workspace["clients"]:
        client = entry["client"]
        if not re.fullmatch(r"client0[1-4]", client):
            raise SafetyError("Invalid client identifier")
        base = local / "clients" / client
        game, profile = base / "game", base / "profile"
        no_links(base / "wine-prefix")
        # Wine creates standard links inside its prefix (for example Downloads).
        # The game and the private save profile must still contain no links.
        for checked_root in (game, profile):
            for current, dirs, names in os.walk(checked_root, followlinks=False):
                for name in dirs + names:
                    no_links(Path(current) / name)
        no_links(profile / "saves")
        if not (profile / "saves").is_dir():
            raise SafetyError("Save directory missing")
        token = entry["profile_id"]
        if not re.fullmatch(r"[a-f0-9]{32}", token):
            raise SafetyError("Invalid profile token")
        if token in tokens:
            raise SafetyError("Two clients share a profile identity")
        tokens.add(token)
        if (profile / "profile-id.txt").read_text().strip() != token:
            raise SafetyError("Profile marker changed")
        expected = dict(base_files, **entry["overrides"])
        changed = differences(expected, snapshot(game))
        if changed:
            raise SafetyError(f"{client}: game copy changed: {changed[:10]}")
        # In addition to stored hashes, assert safety policy independently.
        cfg = read_json(game / "mkxp.json")
        if (cfg.get("dataPathOrg") != "AnilCoopDev" or cfg.get("dataPathApp") != token
                or cfg.get("preloadScript") != ["CoopDev/isolate.rb"]
                or cfg.get("customScript") or cfg.get("postloadScript")
                or digest(game / "CoopDev/isolate.rb") != digest(repo / "src/bootstrap/isolate.rb")
                or (game / "CoopDev/profile-id.txt").read_text().strip() != token
                or digest(profile / "mkxp.original.json") != base_files["mkxp.json"]["sha256"]):
            raise SafetyError(f"{client}: isolation policy failed")
        # Check every link inode, including across siblings; no shared mutable files.
        for name in expected:
            stat = (game / name).stat()
            identity = (stat.st_dev, stat.st_ino)
            if identity in identities or stat.st_nlink != 1:
                raise SafetyError(f"Shared/hardlinked file: {client}/{name}")
            identities.add(identity)
    return {"status": "PASS", "original_files": len(baseline["files"]),
            "original_checked": include_source, "clients": len(tokens),
            "independent_files": True,
            "save_isolation_runtime": "SEE_SEPARATE_RUNTIME_REPORTS"}


def doctor(repo: Path) -> dict:
    names = ("git", "wine", "wine64", "winepath", "ruby", "qemu-system-x86_64",
             "xvfb-run", "dotnet", "cmake", "x86_64-w64-mingw32-gcc")
    found = {name: shutil.which(name) for name in names}
    native = os.name == "nt" and platform.machine().lower() in ("amd64", "x86_64")
    wine = found["wine"] or found["wine64"]
    return {"python": sys.version.split()[0], "platform": platform.platform(),
            "tools": found, "structure_missing": [p for p in REQUIRED if not (repo / p).is_file()],
            "runtime": "AVAILABLE_UNTESTED" if native or wine else "BLOCKED_NO_WINE",
            "native_windows_x64": native,
            "actual_game_execution": "NOT_CHECKED_BY_DOCTOR"}


def launch_plan(repo: Path, clients: list[str]) -> dict:
    if not clients or len(set(clients)) != len(clients):
        raise SafetyError("Select distinct prepared clients")
    workspace = read_json(repo / "local/workspace.json")
    available = {p["client"]: p for p in workspace["clients"]}
    result = []
    for client in clients:
        if client not in available:
            raise SafetyError(f"Unknown client: {client}")
        base = (repo / "local/clients" / client).resolve()
        executable = base / "game/Game.exe"
        command = [str(executable)] if os.name == "nt" else ["wine", str(executable)]
        result.append({"client": client, "command": command, "cwd": str(base / "game"),
                       "environment": {"ANIL_COOP_PROFILE_ID": available[client]["profile_id"],
                                       "APPDATA": str(base / "profile/appdata"),
                                       "LOCALAPPDATA": str(base / "profile/localappdata"),
                                       "WINEPREFIX": str(base / "wine-prefix")},
                       "save_directory": str(base / "profile/saves")})
    return {"status": "PLAN_ONLY", "runtime": doctor(repo)["runtime"], "clients": result}


def launch_windows(repo: Path, clients: list[str], gameslot: Path, *, qa_2v2: bool = False, personal_team: bool = False, coop_battles: bool = False) -> dict:
    # Wine support is intentionally gated until its process/slot adapter is tested.
    # The final target is native Windows, for which gameslot has PID identity checks.
    if not doctor(repo)["native_windows_x64"]:
        raise SafetyError("Runtime blocked: native Windows x64 required for this launcher")
    plan = launch_plan(repo, clients)
    workspace = {p["client"]: p for p in read_json(repo / "local/workspace.json")["clients"]}
    for client in plan["clients"]:
        game = Path(client["cwd"])
        profile = Path(client["save_directory"]).parent
        cfg = read_json(game / "mkxp.json")
        if (cfg.get("preloadScript") != ["CoopDev/isolate.rb"] or
                cfg.get("dataPathApp") != workspace[client["client"]]["profile_id"] or
                not (game / "CoopDev/isolate.rb").is_file() or
                not profile.joinpath("saves").is_dir() or
                profile.joinpath("profile-id.txt").read_text().strip() != workspace[client["client"]]["profile_id"]):
            raise SafetyError("Client save isolation preflight failed")
    if not gameslot.is_file():
        raise SafetyError("Provide the reviewed coop-anything/tools/gameslot/gameslot.py")
    state = no_links(repo / "local/gameslot")
    state.mkdir(parents=True, exist_ok=True)
    cfg = state / "gameslot_config.json"
    if not cfg.exists():
        write_new(cfg, {"slots": 4, "min_free_gb": 3.0, "process_name": "Game.exe"})
    owner = "anil-h0-" + uuid.uuid4().hex
    env = dict(os.environ, GAMESLOT_DIR=str(state))
    def slot(*args):
        subprocess.run([sys.executable, "-I", str(gameslot), *args, "--owner", owner],
                       env=env, check=True, capture_output=True, text=True)
    # Exclusive over all four slots: selected profiles can never overlap another run.
    slot("acquire", "--exclusive", "--ttl", "300", "--wait", "0")
    processes, handles = [], []
    try:
        for client in plan["clients"]:
            profile = Path(client["save_directory"]).parent
            evidence = profile / "bootstrap-loaded.txt"
            if evidence.exists():
                evidence.rename(profile / "logs" / ("bootstrap-previous-" + uuid.uuid4().hex + ".txt"))
            logfile = profile / "logs" / (owner + ".log")
            handle = logfile.open("xb")
            handles.append(handle)
            run_env = dict(os.environ, **client["environment"])
            run_env.pop("WINEPREFIX", None)
            run_env.pop("ANIL_COOP_SECRET", None)
            run_env.pop("ANIL_COOP_QA_WILD", None)
            run_env.pop("ANIL_COOP_QA_TRAINER", None)
            run_env.pop("ANIL_COOP_QA_STARTER", None)
            run_env.pop("ANIL_COOP_QA_RANDOMLOCKE", None)
            run_env.pop("ANIL_COOP_QA_2V2", None)
            run_env.pop("ANIL_COOP_QA_BOT", None)
            run_env.pop("ANIL_COOP_QA_SCENARIO", None)
            run_env.pop("ANIL_COOP_PERSONAL_TEAM", None)
            run_env.pop("ANIL_COOP_BATTLES", None)
            if coop_battles:
                run_env.update(ANIL_COOP_BATTLES="1", ANIL_COOP_PERSONAL_TEAM="1")
            if personal_team:
                run_env["ANIL_COOP_PERSONAL_TEAM"] = "1"
            if qa_2v2:
                run_env.update(ANIL_COOP_QA_TRAINER="1", ANIL_COOP_QA_2V2="1")
            process = subprocess.Popen(client["command"], cwd=client["cwd"], env=run_env,
                                       stdout=handle, stderr=subprocess.STDOUT)
            processes.append(process)
            slot("register-pid", "--pid", str(process.pid))
        renewed = time.monotonic()
        while any(p.poll() is None for p in processes):
            if time.monotonic() - renewed >= 60:
                slot("acquire", "--exclusive", "--ttl", "300", "--wait", "0")
                renewed = time.monotonic()
            time.sleep(0.25)
        codes = [p.returncode for p in processes]
        if any(codes):
            raise SafetyError(f"Game process failed: exit codes {codes}")
        if not all((Path(c["save_directory"]).parent / "bootstrap-loaded.txt").is_file()
                   for c in plan["clients"]):
            raise SafetyError("Game exited without bootstrap evidence")
        return {"status": "BOOTSTRAP_OBSERVED", "exit_codes": codes,
                "save_reload_test": "NOT_RUN", "cooperative_play": "PERSONAL_2V2_ALPHA" if coop_battles else "PRESENCE_ONLY"}
    finally:
        # Only children created by this launcher. Never terminate games by image name.
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for handle in handles:
            handle.close()
        slot("release")


def package(repo: Path) -> dict:
    names = ["README.md", ".gitignore", ".gitattributes"]
    allowed = {".md", ".py", ".rb", ".json", ".ps1"}
    for dirname in PACKAGE_DIRS:
        for p in (repo / dirname).rglob("*"):
            no_links(p)
            if p.is_file() and p.suffix in allowed and "__pycache__" not in p.parts:
                names.append(p.relative_to(repo).as_posix())
    out = no_links(repo / "dist/anil-coop-h0-tools.zip")
    out.parent.mkdir(exist_ok=True)
    # Deterministic archive, own source only, refuses to overwrite a prior deliverable.
    with zipfile.ZipFile(out, "x", compression=zipfile.ZIP_DEFLATED) as z:
        for name in sorted(names):
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, (repo / name).read_bytes())
    return {"status": "PACKAGED_TOOLS_ONLY", "files": len(names), "sha256": digest(out)}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    prep.add_argument("--source", type=Path, required=True)
    prep.add_argument("--clients", type=int, default=4)
    commands.add_parser("verify")
    commands.add_parser("doctor")
    commands.add_parser("package")
    launch = commands.add_parser("launch")
    launch.add_argument("--clients", nargs="+", default=["client01"])
    launch.add_argument("--run", action="store_true")
    launch.add_argument("--gameslot", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            result = prepare(ROOT, args.source, args.clients)
        elif args.command == "verify":
            result = verify(ROOT)
        elif args.command == "doctor":
            result = doctor(ROOT)
        elif args.command == "package":
            result = package(ROOT)
        elif args.run:
            if not args.gameslot:
                raise SafetyError("--run requires --gameslot PATH")
            result = launch_windows(ROOT, args.clients, args.gameslot.resolve())
        else:
            result = launch_plan(ROOT, args.clients)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (SafetyError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        print(json.dumps({"status": "FAIL_OR_BLOCKED", "reason": str(exc)}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    sys.exit(main())
