"""Modal save picker using the launcher's classic menu palette."""
from pathlib import Path
from queue import SimpleQueue
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from .h0 import SafetyError
from .launcher_view import BLUE, INK, PANEL, PAPER, TRIM
from .save_import import find_saves, import_save, inspect_destination, suggested_folder


class SaveImportDialog:
    def __init__(self, parent, view, data, assets, client):
        self.data, self.assets, self.client = data, assets, client
        self.candidates = []
        self.events = SimpleQueue()
        self.busy = False
        self.window = window = tk.Toplevel(parent, background=PANEL, padx=view.px(16), pady=view.px(16))
        window.title("Importar partida guardada")
        window.transient(parent)
        window.protocol("WM_DELETE_WINDOW", self.close)
        window.bind("<Escape>", lambda _: self.close())
        window.minsize(view.px(510), view.px(370))
        window.columnconfigure(0, weight=1)
        window.rowconfigure(3, weight=1)
        tk.Label(window, text="Importar partida guardada", bg=BLUE, fg=PAPER,
                 font=view.face("Bahnschrift", 24, "bold"), anchor="w",
                 padx=view.px(10), pady=view.px(7)).grid(row=0, sticky="ew")
        tk.Label(window, text="Cerrá el juego de origen. Podés copiar una de tus partidas al perfil Co-op y conservar la original.",
                 bg=PANEL, fg=INK, font=view.face("Segoe UI", 15), justify="left",
                 anchor="w", wraplength=view.px(460)).grid(row=1, sticky="ew", pady=view.px(9))
        buttons = tk.Frame(window, bg=PANEL)
        buttons.grid(row=2, sticky="ew", pady=(0, view.px(8)))
        self.file = ttk.Button(buttons, text="Elegir archivo", command=lambda: self.choose(False))
        self.folder = ttk.Button(buttons, text="Elegir carpeta", command=lambda: self.choose(True))
        self.file.pack(side="left")
        self.folder.pack(side="left", padx=view.px(6))

        listing = tk.Frame(window, bg=TRIM, padx=1, pady=1)
        listing.grid(row=3, sticky="nsew")
        self.listing = tk.Listbox(listing, height=5, width=45, bg=PAPER, fg=INK,
                                  font=view.face("Segoe UI", 14), exportselection=False,
                                  selectbackground=BLUE, highlightthickness=0, borderwidth=0)
        scroll = ttk.Scrollbar(listing, orient="vertical", command=self.listing.yview)
        self.listing.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        self.listing.pack(side="left", fill="both", expand=True)
        self.listing.bind("<<ListboxSelect>>", self.select)
        self.detail = tk.Label(window, bg=PANEL, fg=INK, anchor="w", justify="left",
                               font=view.face("Segoe UI", 14), wraplength=view.px(460), height=3)
        self.detail.grid(row=4, sticky="ew")
        actions = tk.Frame(window, bg=PANEL)
        actions.grid(row=5, sticky="ew")
        self.cancel = ttk.Button(actions, text="Cerrar", command=self.close)
        self.cancel.pack(side="right")
        self.submit = ttk.Button(actions, text="Importar", command=self.inspect)
        self.submit.pack(side="right", padx=view.px(6))
        self.submit.state(["disabled"])
        window.grab_set()
        self.file.focus_set()
        self.initial = Path.home()
        self.run(lambda: suggested_folder(data), self.suggest, "Buscando partidas de Añil…")

    def suggest(self, folder):
        self.initial = folder
        if folder.name == "Pokemon Anil":
            self.scan(folder)
        else:
            self.detail.configure(text="Elegí un archivo o la carpeta donde guardás tus partidas.")

    def choose(self, directory):
        options = {"parent": self.window, "initialdir": self.initial}
        if directory:
            chosen = filedialog.askdirectory(mustexist=True, **options)
        else:
            chosen = filedialog.askopenfilename(filetypes=[("Partidas de Añil", "*.rxdata *.rxdata.bak")],
                                                **options)
        if chosen:
            path = Path(chosen)
            self.initial = path if directory else path.parent
            self.scan(path)

    def scan(self, path):
        self.candidates = []
        self.listing.delete(0, "end")
        self.run(lambda: find_saves(path), self.show_saves, "Verificando las partidas…")

    def show_saves(self, candidates):
        self.candidates = candidates
        first = None
        for index, candidate in enumerate(candidates):
            state = "No compatible" if candidate.error else "Compatible"
            self.listing.insert("end", f"{candidate.path.name}   ·   {state}")
            if first is None and not candidate.error:
                first = index
        if first is not None:
            self.listing.selection_set(first)
            self.listing.see(first)
        elif candidates:
            self.listing.selection_set(0)
        else:
            self.detail.configure(text="No se encontraron archivos de partida reconocidos.")
        self.select()

    def selected(self):
        selected = self.listing.curselection()
        return self.candidates[selected[0]] if selected else None

    def select(self, _event=None):
        candidate = self.selected()
        if self.busy or candidate is None:
            return
        self.submit.state(["disabled" if candidate.error else "!disabled"])
        self.detail.configure(text=candidate.error or
                              "Se conservarán los datos de la partida. Elegí Importar para continuar.")

    def inspect(self):
        candidate = self.selected()
        if not candidate or candidate.error:
            return
        self.run(lambda: inspect_destination(self.data, self.assets, self.client, candidate),
                 lambda target: self.confirm(candidate, target), "Comprobando el perfil Co-op…")

    def confirm(self, candidate, target):
        replace = False
        if target.existing_hash:
            choice = self.conflict_choice(target)
            if not choice:
                self.select()
                return
            replace = choice == "replace"
            if replace and not messagebox.askyesno(
                    "Confirmar reemplazo", f"¿Querés reemplazar {target.preferred} en Co-op?",
                    default=messagebox.NO, parent=self.window):
                self.select()
                return
        self.run(lambda: import_save(self.data, self.assets, self.client, candidate, target, replace=replace),
                 self.success, "Copiando y verificando la partida…")

    def conflict_choice(self, target):
        dialog = tk.Toplevel(self.window, bg=PANEL, padx=16, pady=16)
        dialog.title("Partida existente")
        dialog.transient(self.window)
        dialog.resizable(False, False)
        choice = []

        def choose(value):
            choice.append(value)
            dialog.destroy()

        tk.Label(dialog, bg=PANEL, fg=INK, justify="left", anchor="w",
                 text=f"Ya existe {target.preferred} en Co-op.\n"
                      "Podés conservarla e importar en otra ranura.").pack(fill="x", pady=(0, 10))
        for label, value in ((f"Usar {target.free}", "free"),
                             ("Reemplazar con respaldo", "replace"), ("Cancelar", "")):
            button = ttk.Button(dialog, text=label, style="Classic.Setup.TButton",
                                command=lambda option=value: choose(option))
            button.pack(fill="x")
            if value == "free":
                button.focus_set()
        dialog.bind("<Escape>", lambda _: dialog.destroy())
        dialog.grab_set()
        self.window.wait_window(dialog)
        self.window.grab_set()
        return choice[0] if choice else ""

    def success(self, result):
        name, backup = result
        details = f"Partida importada correctamente.\n\n{name}"
        if backup:
            details += f"\n\nRespaldo del archivo anterior:\n{backup}"
        messagebox.showinfo("Pokémon Añil Co-op", details, parent=self.window)
        self.close()

    def run(self, work, completed, status):
        self.busy = True
        self.detail.configure(text=status)
        for button in (self.file, self.folder, self.submit, self.cancel):
            button.state(["disabled"])

        def worker():
            try:
                self.events.put((True, work()))
            except Exception as error:
                self.events.put((False, error))

        def poll():
            if self.events.empty():
                self.window.after(40, poll)
                return
            success, result = self.events.get_nowait()
            self.busy = False
            for button in (self.file, self.folder, self.cancel):
                button.state(["!disabled"])
            self.select()
            if success:
                completed(result)
            else:
                message = str(result) if isinstance(result, SafetyError) else "No se pudo leer o copiar la partida. Revisá los permisos y el espacio disponible."
                self.detail.configure(text=message)

        threading.Thread(target=worker, daemon=True).start()
        self.window.after(40, poll)

    def close(self):
        if not self.busy:
            self.window.destroy()
