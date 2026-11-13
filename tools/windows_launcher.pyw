"""Windowed Windows entry point, including the bundled Online server mode."""
from pathlib import Path
import logging
import os
import queue
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, ttk

if not getattr(sys, "frozen", False):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.server import session_server
from tools.h0 import ROOT, SafetyError, no_links
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
        root.title(TITLE)
        root.minsize(530, 355)
        root.configure(background="#101b30")
        root.protocol("WM_DELETE_WINDOW", self.close)

        style = ttk.Style(root)
        style.theme_use("clam")
        style.configure("Launcher.Horizontal.TProgressbar", troughcolor="#253955",
                        background="#69dfbe", borderwidth=0, thickness=10)
        style.configure("Play.TButton", font=("Segoe UI", 15, "bold"), padding=(24, 12),
                        background="#69dfbe", foreground="#102538", borderwidth=0)
        style.map("Play.TButton", background=[("disabled", "#253955"), ("active", "#a0f4d8")],
                  foreground=[("disabled", "#9cacc4")])
        style.configure("Setup.TButton", font=("Segoe UI", 10), padding=(12, 7))

        body = tk.Frame(root, background="#101b30", padx=30, pady=24)
        body.pack(fill="both", expand=True)
        tk.Label(body, text=TITLE, font=("Segoe UI", 24, "bold"), fg="#f6f9ff",
                 bg="#101b30", anchor="w").pack(fill="x")
        self.status = tk.Label(body, font=("Segoe UI", 11, "bold"), fg="#69dfbe",
                               bg="#101b30", anchor="w")
        self.status.pack(fill="x", pady=(12, 7))
        self.detail = tk.Label(body, font=("Segoe UI", 10), fg="#d4e2f7", bg="#101b30",
                               justify="left", anchor="nw", wraplength=465, height=3)
        self.detail.pack(fill="x")
        self.bar = ttk.Progressbar(body, style="Launcher.Horizontal.TProgressbar")
        self.bar.pack(fill="x", pady=(4, 18))
        buttons = tk.Frame(body, background="#101b30")
        buttons.pack(fill="x")
        self.select = ttk.Button(buttons, text="Seleccionar carpeta original",
                                 style="Setup.TButton", command=self.choose)
        self.select.pack(side="left")
        self.retry = ttk.Button(buttons, text="Reintentar", style="Setup.TButton",
                                command=lambda: self.retry_action())
        self.retry.pack(side="left", padx=(10, 0))
        self.start = ttk.Button(body, text="JUGAR", style="Play.TButton", command=self.play)
        self.start.pack(fill="x", side="bottom", pady=(18, 0))

        self.check()
        root.after(40, self.poll)

    def render(self, status, detail, percent=0, retry=None):
        self.status.configure(text=status)
        self.detail.configure(text=detail)
        self.bar.configure(value=percent)
        self.select.configure(state="disabled" if self.busy or self.client else "normal")
        self.start.configure(state="normal" if self.client and not self.busy else "disabled")
        self.retry_action = retry
        self.retry.configure(state="normal" if retry else "disabled")
        if retry:
            self.retry.pack(side="left", padx=(10, 0))
        else:
            self.retry.pack_forget()

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
                self.render("Listo", detail, 100)
                self.start.focus_set()
            else:
                self.render("No instalado", "Seleccioná la carpeta que contiene el Game.exe de tu Pokémon Añil v4.14.")
                self.select.focus_set()
        self.root.after(40, self.poll)

    def close(self):
        if self.busy == "install":
            self.detail.configure(text="Esperá a que termine la instalación antes de cerrar. Podés minimizar esta ventana.")
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
