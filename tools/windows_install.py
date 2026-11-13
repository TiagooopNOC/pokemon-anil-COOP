"""Transactional first installation and session lifecycle for the Windows launcher."""
from pathlib import Path
import os
import re
import shutil
import threading

from .h0 import (SafetyError, digest, disjoint, ignore_progress, launch_plan, launch_windows,
                 no_links, prepare, read_json, verify, windows_profile_lock)
from .install_presence import install_presence
from .menu_control import ControlServer, MenuControl


def installed_client(data: Path, assets: Path):
    workspace = no_links(data / "local/workspace.json")
    if not workspace.exists():
        if no_links(data / "local").exists():
            raise SafetyError("La instalación privada está incompleta. Conservá esa carpeta y sus partidas.")
        return None
    entry = read_json(workspace)["clients"][0]
    client = entry["client"]
    plan = launch_plan(data, [client])["clients"][0]
    game = no_links(Path(plan["cwd"]))
    profile = no_links(Path(plan["save_directory"]).parent)
    token = entry["profile_id"]
    cfg = read_json(no_links(game / "mkxp.json"))
    if (not re.fullmatch(r"[a-f0-9]{32}", token)
            or cfg.get("dataPathOrg") != "AnilCoopDev" or cfg.get("dataPathApp") != token
            or cfg.get("preloadScript") != ["CoopDev/isolate.rb"]
            or cfg.get("customScript")
            or cfg.get("postloadScript") not in (None, ["CoopDev/coop.rb"], ["CoopDev/loader.rb"])
            or not no_links(profile / "saves").is_dir()
            or no_links(profile / "profile-id.txt").read_text(encoding="ascii").strip() != token
            or no_links(game / "CoopDev/profile-id.txt").read_text(encoding="ascii").strip() != token):
        raise SafetyError("No se pudo confirmar el aislamiento de las partidas.")
    bootstrap = no_links(game / "CoopDev/isolate.rb")
    if not bootstrap.is_file():
        raise SafetyError("Falta el script que aísla las partidas.")
    for name, expected in read_json(assets / "config/build.json")["critical"].items():
        if name == "mkxp.json":
            continue
        file = no_links(game / name)
        if not file.is_file() or file.stat().st_nlink != 1 or digest(file) != expected:
            raise SafetyError(f"Falta un archivo esencial o está dañado: {name}")
    return client


def discard_unpublished(pending: Path):
    """The setup lock excludes other installers. Preserve any populated save directory."""
    no_links(pending)
    local = no_links(pending / "local")
    for stage in local.glob("*"):
        if not no_links(stage).is_dir():
            continue
        for client in stage.glob("client*"):
            saves = no_links(client / "profile/saves")
            if saves.exists() and any(saves.iterdir()):
                raise SafetyError("La preparación interrumpida contiene partidas. Se conservó su carpeta.")
    shutil.rmtree(pending)


def install(data: Path, assets: Path, source: Path, progress=ignore_progress):
    import msvcrt

    disjoint(data, source)
    data = no_links(data)
    data.mkdir(parents=True, exist_ok=True)
    with windows_profile_lock(no_links(data / "setup.lock"), msvcrt):
        client = installed_client(data, assets)
        if client:
            return client
        pending = no_links(data / "setup-pending")
        if pending.exists():
            discard_unpublished(pending)
        pending.mkdir()
        try:
            prepare(pending, source, 1, assets=assets, progress=progress)
            verify(pending, include_source=False, assets=assets, progress=progress)
            install_presence(pending, ["client01"], assets=assets, progress=progress)
            client = installed_client(pending, assets)
        except Exception:
            discard_unpublished(pending)
            raise
        progress("finishing")
        (pending / "local").rename(data / "local")
        pending.rmdir()
        return client


def play(data: Path, assets: Path, client: str, progress=ignore_progress):
    if installed_client(data, assets) != client:
        raise SafetyError("No se encontró el perfil de juego.")
    server = ControlServer(MenuControl(assets, server_port=int(os.environ.get("ANIL_COOP_GAME_PORT", "17641"))))
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()

    def update_overlay():
        install_presence(data, [client], assets=assets, progress=progress)
        progress("playing")

    try:
        return launch_windows(
            data, [client], None, coop_battles=True, pvp=True, before_launch=update_overlay,
            environment={"ANIL_COOP_MENU": "1", "ANIL_COOP_CONTROL_PORT": str(server.server_address[1]),
                         "ANIL_COOP_CONTROL_TOKEN": server.token})
    finally:
        server.close()
        worker.join()
