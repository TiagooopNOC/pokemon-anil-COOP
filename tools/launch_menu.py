"""Start isolated Pokémon Añil and its local menu helper without terminal prompts."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import threading

from h0 import ROOT, SafetyError, launch_plan, launch_windows, read_json
sys.path.insert(0, str(ROOT))
from menu_control import MenuControl, ControlServer
from src.client.trade_storage import TradeStorage


def choose_install_folder():
    import tkinter as tk
    from tkinter import filedialog
    root = tk.Tk()
    root.withdraw()
    try:
        return filedialog.askdirectory(title="Elegí la carpeta de tu Pokémon Añil original", parent=root)
    finally:
        root.destroy()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", help="Perfil aislado; por defecto, el primero disponible")
    args = parser.parse_args()
    workspace = ROOT / "local/workspace.json"
    if not workspace.exists():
        source = choose_install_folder()
        if not source:
            return 0
        subprocess.run([sys.executable, "-B", str(ROOT / "tools/h0.py"), "prepare",
                        "--source", source, "--clients", "1"], cwd=ROOT, check=True)
    clients = [entry["client"] for entry in read_json(workspace)["clients"]]
    client = args.client or clients[0]
    if client not in clients:
        raise SafetyError("El perfil aislado elegido no existe")
    profile = Path(launch_plan(ROOT, [client])["clients"][0]["save_directory"]).parent
    if (profile / "trade-escrow.sqlite3").exists() or (profile / "trade-pending.lock").exists():
        storage = TradeStorage(profile / "saves")
        try:
            for record in storage.pending():
                if record["decision"] == "commit":
                    storage.apply(record["txid"])
                else:
                    raise SafetyError("Hay un intercambio pendiente. Reconectá al anfitrión para recuperarlo; la partida está bloqueada.")
            if (profile / "trade-pending.lock").exists():
                txid = (profile / "trade-pending.lock").read_text(encoding="ascii")
                record = storage.get(txid)
                if record and record["decision"] == "abort":
                    storage.finish_abort(txid)
                elif record is None:
                    storage.clear_unprepared_lock(txid)
                else:
                    raise SafetyError("Registro de intercambio incompleto. La partida está bloqueada para proteger los Pokémon.")
        finally:
            storage.close()
    subprocess.run([sys.executable, "-B", str(ROOT / "tools/install_presence.py"),
                    "--clients", client], cwd=ROOT, check=True)
    control = MenuControl(ROOT, server_port=int(os.environ.get("ANIL_COOP_GAME_PORT", "17641")), profile=profile)
    server = ControlServer(control)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    keys = ("ANIL_COOP_MENU", "ANIL_COOP_CONTROL_PORT", "ANIL_COOP_CONTROL_TOKEN")
    old = {key: os.environ.get(key) for key in keys}
    try:
        os.environ.update(ANIL_COOP_MENU="1", ANIL_COOP_CONTROL_PORT=str(server.server_address[1]),
                          ANIL_COOP_CONTROL_TOKEN=server.token)
        slot = ROOT / "vendor/gameslot/gameslot.py"
        if os.name == "nt":
            launch_windows(ROOT, [client], slot, coop_battles=True)
            return 0
        return subprocess.call([sys.executable, "-B", str(ROOT / "tools/wine_smoke.py"),
                                "--client", client, "--gameslot", str(slot),
                                "--coop-battles", "--play"], cwd=ROOT)
    finally:
        server.close()
        thread.join()
        for key, value in old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SafetyError, OSError, ValueError, subprocess.CalledProcessError) as error:
        if os.name == "nt":
            from tkinter import Tk, messagebox
            root = Tk()
            root.withdraw()
            messagebox.showerror("Pokémon Añil Co-op", str(error), parent=root)
            root.destroy()
        else:
            print(f"No se pudo iniciar: {error}", file=sys.stderr)
        sys.exit(2)
