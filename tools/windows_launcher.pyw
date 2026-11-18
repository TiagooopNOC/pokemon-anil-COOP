"""Windowed Windows entry point, including the bundled Online server mode."""
from pathlib import Path
import json
import logging
import os
import queue
import secrets
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox

if not getattr(sys, "frozen", False):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.server import session_server
from tools.h0 import ROOT, SafetyError, no_links
from tools.launcher_view import ClassicMenuView
from tools.launcher_updates import (UpdateError, active_executable, current_tag,
                                    find_update, rollback_activation, stage_update)
from tools.save_import_view import SaveImportDialog
from tools.windows_install import install, installed_client, play


TITLE = "Pokémon Añil Co-op"
PHASES = {
    "validating": "Validando archivos del juego original",
    "copying": "Copiando la instalación original",
    "saves": "Configurando el perfil y sus partidas",
    "checking_source": "Comprobando que el original sigue intacto",
    "verifying": "Verificando la integridad de la copia",
    "overlay": "Instalando y verificando la modificación",
    "finishing": "Finalizando la instalación",
    "playing": "El juego se está abriendo. Podés minimizar esta ventana.",
    "downloading": "Descargando el launcher verificado desde GitHub",
    "verifying_update": "Comprobando el SHA-256 y el contenido del ZIP",
    "installing_update": "Preparando la nueva versión sin tocar tus partidas",
}


class Launcher:
    def __init__(self, root, data):
        self.root, self.data = root, data
        self.events = queue.SimpleQueue()
        self.client = None
        self.source = None
        self.busy = None
        self.close_after_play = False
        self.retry_action = None
        self.update_release = None
        self.update_checking = False
        root.protocol("WM_DELETE_WINDOW", self.close)
        self.view = ClassicMenuView(root, ROOT / "assets/windows-launcher", TITLE,
                                    self.choose, lambda: self.retry_action(), self.play,
                                    self.open_import, self.update)

        self.check()
        root.after(40, self.poll)
        root.after(1200, lambda: self.check_updates(auto=True))

    def render(self, status, detail, percent=0, retry=None):
        self.retry_action = retry
        self.view.render(status, detail, installing=self.busy in ("install", "update"), percent=percent,
                         selectable=not self.busy and not self.client,
                         playable=bool(self.client and not self.busy), retryable=retry is not None,
                         idle=not self.busy, update_tag=self.update_release and self.update_release["tag"],
                         update_checking=self.update_checking)

    def check_updates(self, *, auto=False):
        if self.update_checking or (self.busy and not auto):
            return
        self.update_checking = True
        if not auto:
            self.render("Buscando", "Consultando las releases oficiales de GitHub…")

        def worker():
            try:
                tag = current_tag(ROOT)
                release = find_update(tag)
                self.events.put(("release", (release, None, auto, tag)))
            except Exception as error:
                logging.exception("Release check failed")
                self.events.put(("release", (None, error, auto, None)))

        threading.Thread(target=worker, daemon=True).start()

    def update(self):
        if self.busy:
            return
        if not self.update_release:
            self.check_updates()
            return
        release = self.update_release
        size = round(release["size"] / 1024 / 1024, 1)
        if not messagebox.askyesno(TITLE, f"¿Actualizar a {release['tag']}?\n"
                                    f"Se descargarán {size} MiB desde GitHub.\n"
                                    "Tus partidas y la instalación original permanecerán en su carpeta.",
                                    parent=self.root):
            return
        self.run("update", lambda report: stage_update(self.data, release, report))

    def await_update_start(self):
        if self.update_ready.is_file():
            self.update_ready.unlink(missing_ok=True)
            self.root.destroy()
            return
        if self.update_process.poll() is not None or time.monotonic() >= self.update_deadline:
            if self.update_process.poll() is None:
                self.update_process.terminate()
            rollback_activation(self.data, self.update_release)
            self.busy = None
            self.render("Error", "El launcher nuevo no abrió correctamente. Seguís en la versión anterior.",
                        retry=self.update)
            return
        self.root.after(200, self.await_update_start)

    def open_import(self):
        if self.busy:
            return
        if not self.client:
            messagebox.showinfo(TITLE, "Primero completá la instalación de Pokémon Añil Co-op.",
                                parent=self.root)
            return
        SaveImportDialog(self.root, self.view, self.data, ROOT, self.client)

    def check(self):
        self.run("checking", lambda _: installed_client(self.data, ROOT))

    def choose(self):
        source = filedialog.askdirectory(parent=self.root, mustexist=True,
                                         title="Elegí la carpeta de tu Pokémon Añil v4.14")
        if source:
            self.source = Path(source)
            self.install()

    def install(self):
        self.run("install", lambda progress: install(self.data, ROOT, self.source, progress))

    def play(self):
        self.run("play", lambda progress: play(self.data, ROOT, self.client, progress))

    def run(self, operation, work):
        self.busy = operation
        if operation == "install":
            self.render("Instalando", "Validando archivos del juego original…")
        elif operation == "update":
            self.render("Actualizando", "Descargando la nueva versión…")
        else:
            self.render("Comprobando instalación" if operation == "checking" else "Iniciando",
                        "Comprobando la copia de Pokémon Añil Co-op…")

        def worker():
            last_phase = None
            last_update = 0

            def report(phase, done=0, total=0):
                nonlocal last_phase, last_update
                now = time.monotonic()
                if phase != last_phase or done in (0, total) or now - last_update >= 0.06:
                    self.events.put(("progress", (phase, done, total)))
                    last_phase, last_update = phase, now

            try:
                self.events.put(("done", work(report)))
            except Exception as error:
                logging.exception("Launcher operation failed")
                self.events.put(("error", error))

        threading.Thread(target=worker, daemon=True).start()

    def poll(self):
        while not self.events.empty():
            event, value = self.events.get_nowait()
            if event == "release":
                release, error, auto, tag = value
                self.update_checking = False
                self.update_release = release
                if release:
                    if not self.busy:
                        self.render("Actualización disponible", f"Nueva versión {release['tag']} lista para descargar.")
                elif not auto:
                    detail = ("Este paquete de desarrollo no tiene una etiqueta de release." if tag == "development"
                              else str(error) if isinstance(error, UpdateError) else
                              "No se pudo consultar GitHub. Revisá tu conexión." if error else
                              "Ya tenés la versión más reciente.")
                    self.render("Actualizaciones", detail)
                elif not self.busy:
                    self.render("Listo para jugar" if self.client else "No instalado",
                                "Tu copia de Pokémon Añil Co-op está lista." if self.client else
                                "Seleccioná la carpeta que contiene Game.exe.")
                continue
            if event == "progress":
                phase, done, total = value
                detail = PHASES[phase]
                percent = 100 * done // total if total else 0
                if total:
                    if phase == "downloading":
                        detail += f"\n{done / 1048576:.1f} / {total / 1048576:.1f} MiB · {percent}%"
                    elif self.busy != "update":
                        count = f"{done:,} / {total:,}".replace(",", ".")
                        detail += f"\n{count} archivos · {percent}% de esta etapa"
                status = ("Instalando" if self.busy == "install" else "Actualizando" if self.busy == "update"
                          else "En juego" if phase == "playing" else "Iniciando")
                self.render(status, detail, percent)
                continue
            operation, self.busy = self.busy, None
            if self.close_after_play:
                self.root.destroy()
                return
            if event == "error":
                retry = {"install": self.install, "checking": self.check,
                         "play": self.play, "update": self.update}[operation]
                self.render("Error", error_message(value, operation), retry=retry)
                continue
            if operation == "update":
                try:
                    nonce = secrets.token_hex(8)
                    self.update_ready = self.data / "launcher-updates" / f"ready-{nonce}"
                    self.update_process = subprocess.Popen([str(value), f"--update-ready={nonce}"],
                                                           cwd=value.parent, close_fds=True)
                except OSError as error:
                    rollback_activation(self.data, self.update_release)
                    self.render("Error", f"La actualización se instaló, pero no se pudo abrir: {error}",
                                retry=self.update)
                    continue
                self.busy = "starting_update"
                self.update_deadline = time.monotonic() + 20
                self.render("Actualizando", "Abriendo y comprobando la nueva versión…")
                self.root.after(200, self.await_update_start)
                continue
            if operation in ("checking", "install"):
                self.client = value
            if self.client:
                detail = "Instalación completada. Ya podés jugar." if operation == "install" else "Tu copia de Pokémon Añil Co-op está lista."
                self.render("Listo para jugar", detail)
                self.view.start.focus_set()
            else:
                self.render("No instalado", "Seleccioná la carpeta que contiene el Game.exe de tu Pokémon Añil v4.14.")
                self.view.select.focus_set()
        self.root.after(40, self.poll)

    def close(self):
        if self.busy in ("install", "update", "starting_update"):
            self.view.detail.configure(text="Esperá a que termine la operación antes de cerrar. Podés minimizar esta ventana.")
        elif self.busy == "play":
            self.close_after_play = True
            self.root.withdraw()
        else:
            self.root.destroy()


def error_message(error, operation):
    message = str(error)
    if operation == "update":
        return message if isinstance(error, UpdateError) else "No se pudo actualizar. Reintentá más tarde."
    if message.startswith("Unsupported/changed game build"):
        return "Esa carpeta no contiene el Pokémon Añil v4.14 compatible. Elegí la carpeta original que contiene Game.exe."
    if message.startswith("Insufficient disk space") or getattr(error, "errno", None) == 28:
        return "No hay espacio suficiente para la copia del juego. Liberá espacio y reintentá."
    if isinstance(error, PermissionError):
        return "Windows impidió leer o escribir un archivo. Revisá el acceso a la carpeta y volvé a intentar."
    if message.startswith("Source and development workspace"):
        return "Elegí la carpeta del juego original fuera de la instalación privada de Co-op."
    if isinstance(error, SafetyError) and message.startswith(("Esta", "Falta", "Hay", "La ", "No se")):
        return message
    if operation == "play":
        return "No se pudo abrir el juego o se cerró con un error. Podés volver a intentar."
    return "No se pudo comprobar la instalación. Revisá que los archivos estén disponibles y volvé a intentar."


def main():
    if sys.argv[1:2] == ["--session-server"]:
        del sys.argv[1]
        session_server.main()
        return
    data = Path(os.environ["LOCALAPPDATA"]) / "AnilCoop"
    installed = active_executable(data, Path(sys.executable))
    if installed:
        try:
            nonce = secrets.token_hex(8)
            ready = data / "launcher-updates" / f"ready-{nonce}"
            process = subprocess.Popen([str(installed), f"--update-ready={nonce}"],
                                       cwd=installed.parent, close_fds=True)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and process.poll() is None and not ready.exists():
                time.sleep(0.2)
            if ready.exists():
                ready.unlink(missing_ok=True)
                return
            if process.poll() is None:
                process.terminate()
        except (OSError, ValueError):
            pass
        try:
            marker = data / "launcher-updates/active.json"
            rollback_activation(data, json.loads(marker.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            pass  # The previous launcher remains usable if a staged EXE cannot start.
    try:
        no_links(data).mkdir(parents=True, exist_ok=True)
        logging.basicConfig(filename=no_links(data / "launcher.log"), encoding="utf-8",
                            level=logging.ERROR)
    except (OSError, SafetyError):
        pass  # Keep the window available to explain setup errors.
    root = tk.Tk()
    Launcher(root, data)
    if sys.argv[1:2] and sys.argv[1].startswith("--update-ready="):
        nonce = sys.argv[1].partition("=")[2]
        if len(nonce) == 16 and all(char in "0123456789abcdef" for char in nonce):
            (data / "launcher-updates" / f"ready-{nonce}").write_text("ready", encoding="ascii")
    root.mainloop()


if __name__ == "__main__":
    main()
