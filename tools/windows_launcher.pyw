"""Windowed Windows entry point, including the bundled Online server mode."""
from pathlib import Path
import logging
import os
import queue
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
        root.protocol("WM_DELETE_WINDOW", self.close)
        self.view = ClassicMenuView(root, ROOT / "assets/windows-launcher", TITLE,
                                    self.choose, lambda: self.retry_action(), self.play, self.open_import)

        self.check()
        root.after(40, self.poll)

    def render(self, status, detail, percent=0, retry=None):
        self.retry_action = retry
        self.view.render(status, detail, installing=self.busy == "install", percent=percent,
                         selectable=not self.busy and not self.client,
                         playable=bool(self.client and not self.busy), retryable=retry is not None,
                         idle=not self.busy)

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
            if event == "progress":
                phase, done, total = value
                detail = PHASES[phase]
                percent = 100 * done // total if total else 0
                if total:
                    count = f"{done:,} / {total:,}".replace(",", ".")
                    detail += f"\n{count} archivos · {percent}% de esta etapa"
                status = "Instalando" if self.busy == "install" else "En juego" if phase == "playing" else "Iniciando"
                self.render(status, detail, percent)
                continue
            operation, self.busy = self.busy, None
            if self.close_after_play:
                self.root.destroy()
                return
            if event == "error":
                retry = {"install": self.install, "checking": self.check, "play": self.play}[operation]
                self.render("Error", error_message(value, operation), retry=retry)
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
        if self.busy == "install":
            self.view.detail.configure(text="Esperá a que termine la instalación antes de cerrar. Podés minimizar esta ventana.")
        elif self.busy == "play":
            self.close_after_play = True
            self.root.withdraw()
        else:
            self.root.destroy()


def error_message(error, operation):
    message = str(error)
    if message.startswith("Unsupported/changed game build"):
        return "Esa carpeta no contiene el Pokémon Añil v4.14 compatible. Elegí la carpeta original que contiene Game.exe."
    if message.startswith("Insufficient disk space") or getattr(error, "errno", None) == 28:
        return "No hay espacio suficiente para la copia del juego. Liberá espacio y reintentá."
    if isinstance(error, PermissionError):
        return "Windows impidió leer o escribir un archivo. Revisá el acceso a la carpeta y volvé a intentar."
    if message.startswith("Source and development workspace"):
        return "Elegí la carpeta del juego original fuera de la instalación privada de Co-op."
    if isinstance(error, SafetyError) and message.startswith(("Esta", "Falta", "La ", "No se")):
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
    try:
        no_links(data).mkdir(parents=True, exist_ok=True)
        logging.basicConfig(filename=no_links(data / "launcher.log"), encoding="utf-8",
                            level=logging.ERROR)
    except (OSError, SafetyError):
        pass  # Keep the window available to explain setup errors.
    root = tk.Tk()
    Launcher(root, data)
    root.mainloop()


if __name__ == "__main__":
    main()
