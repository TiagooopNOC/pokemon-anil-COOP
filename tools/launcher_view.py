"""Classic Pokémon menu artwork and native Tk controls."""
import tkinter as tk
from tkinter import ttk

from PIL import Image, ImageOps, ImageTk


SHELL = "#dbe9ef"
PAPER = "#f8fcff"
PANEL = "#e8f2f8"
INK = "#223e65"
BLUE = "#284e7c"
TRIM = "#6d9cc0"


class ClassicMenuView:
    def __init__(self, root, artwork, title, choose, retry, play):
        dpi = root.winfo_fpixels("1i") / 96
        self.scale = min(dpi, (root.winfo_screenheight() - 110) / 480,
                         (root.winfo_screenwidth() - 40) / 660)
        root.title(title)
        root.iconbitmap(default=str(artwork / "anil-coop.ico"))
        root.configure(background=SHELL)
        root.minsize(self.px(660), self.px(480))
        width = min(self.px(900), root.winfo_screenwidth() - 40)
        height = min(self.px(568), root.winfo_screenheight() - 110)
        root.geometry(f"{width}x{height}")

        frame = self.frame(root, PAPER, self.px(4))
        frame.pack(fill="both", expand=True, padx=self.px(21), pady=self.px(21))
        header = tk.Frame(frame, bg=BLUE, highlightbackground=TRIM, highlightthickness=self.px(3))
        header.pack(fill="x", padx=self.px(9), pady=(self.px(9), self.px(14)))
        tk.Label(header, text=title, font=self.face("Bahnschrift", 37, "bold"), fg=PAPER,
                 bg=BLUE, anchor="w", padx=self.px(20), pady=self.px(14)).pack(fill="x")

        body = tk.Frame(frame, bg=PAPER)
        body.pack(fill="both", expand=True, padx=self.px(19), pady=(0, self.px(20)))
        body.rowconfigure(0, weight=1)
        body.columnconfigure(0, weight=4, uniform="menu")
        body.columnconfigure(1, weight=5, uniform="menu")
        with Image.open(artwork / "panorama.png") as panorama:
            self.panorama = panorama.copy()
        landscape = self.frame(body, INK, self.px(4))
        landscape.grid(row=0, column=0, sticky="nsew", padx=(0, self.px(12)))
        self.hero = tk.Canvas(landscape, width=1, height=1, bg=SHELL, highlightthickness=0)
        self.hero.pack(fill="both", expand=True)
        self.hero.bind("<Configure>", self.draw_landscape)

        panel = self.frame(body, PANEL, self.px(4))
        panel.grid(row=0, column=1, sticky="nsew")
        # Wrapped text must not resize the grid column that sets its wrap width.
        panel.grid_propagate(False)
        panel.columnconfigure(0, weight=1)
        panel.rowconfigure(6, weight=1)
        inset = self.px(17)
        self.status = tk.Label(panel, font=self.face("Bahnschrift", 26, "bold"),
                               fg=INK, bg=PANEL, anchor="w")
        self.status.grid(row=0, sticky="ew", padx=inset, pady=(self.px(15), self.px(5)))
        self.detail = tk.Label(panel, font=self.face("Segoe UI", 15), fg=INK,
                               bg=PANEL, justify="left", anchor="nw")
        self.detail.grid(row=1, sticky="ew", padx=inset)
        panel.bind("<Configure>", lambda event: self.detail.configure(
            wraplength=max(1, event.width - 2 * inset - self.px(10))))
        self.configure_styles(root)
        self.bar = ttk.Progressbar(panel, style="Classic.Horizontal.TProgressbar")
        self.bar.grid(row=2, sticky="ew", padx=inset, pady=(self.px(7), 0))
        self.bar.grid_remove()
        tk.Frame(panel, bg=TRIM, height=self.px(2)).grid(
            row=3, sticky="ew", padx=inset, pady=(self.px(13), self.px(8)))

        self.cursor_image = self.make_cursor(root)
        self.start = ttk.Button(panel, text="JUGAR", image=self.cursor_image, compound="left",
                                style="Classic.Play.TButton", command=play)
        self.start.grid(row=4, sticky="ew", padx=inset)
        self.select = ttk.Button(panel, text="Seleccionar carpeta original",
                                 style="Classic.Setup.TButton", command=choose)
        self.select.grid(row=5, sticky="ew", padx=inset, pady=(self.px(4), 0))
        self.retry = ttk.Button(panel, text="Reintentar", style="Classic.Setup.TButton", command=retry)
        self.retry.grid(row=6, sticky="new", padx=inset, pady=(self.px(4), 0))
        self.retry.grid_remove()
        tk.Label(panel, text="Pokémon Añil v4.14", font=self.face("Segoe UI", 13), fg="#46627e",
                 bg=PANEL,
                 anchor="w", padx=self.px(10), pady=self.px(6)).grid(
                     row=7, sticky="ew", padx=inset, pady=(self.px(9), self.px(13)))

    @staticmethod
    def frame(parent, background, border):
        return tk.Frame(parent, bg=background, highlightbackground=INK,
                        highlightcolor=INK, highlightthickness=border)

    def configure_styles(self, root):
        style = ttk.Style(root)
        style.theme_use("clam")
        style.configure("Classic.Horizontal.TProgressbar", troughcolor="#d2e4ee",
                        background=BLUE, lightcolor=BLUE, darkcolor=BLUE, bordercolor=TRIM,
                        thickness=self.px(9))
        for name, face in (("Classic.Play.TButton", self.face("Bahnschrift", 29, "bold")),
                           ("Classic.Setup.TButton", self.face("Segoe UI", 15, "bold"))):
            style.configure(name, anchor="w", font=face, background=PANEL, foreground=INK,
                            bordercolor=PANEL, lightcolor=PANEL, darkcolor=PANEL, focuscolor=BLUE,
                            padding=(self.px(8), self.px(5)))
            style.map(name, background=[("pressed", "#b9d8ec"), ("active", "#d2e4ee")],
                      foreground=[("disabled", "#607994")])

    def make_cursor(self, root):
        image = tk.PhotoImage(master=root, width=self.px(25), height=self.px(18))
        width = self.px(14)
        center = image.height() // 2
        for y in range(image.height()):
            end = width - abs(y - center) * width // max(1, center)
            if end > 0:
                image.put(BLUE, to=(0, y, end, y + 1))
        return image

    def px(self, value):
        return max(1, round(value * self.scale))

    def face(self, family, size, weight="normal"):
        return (family, -self.px(size), weight)

    def draw_landscape(self, event):
        if event.width < 2 or event.height < 2:
            return
        fitted = ImageOps.fit(self.panorama, (event.width, event.height),
                              Image.Resampling.NEAREST, centering=(0.5, 0.5))
        self.hero.picture = ImageTk.PhotoImage(fitted)
        self.hero.delete("all")
        self.hero.create_image(0, 0, image=self.hero.picture, anchor="nw")

    def render(self, status, detail, *, installing, percent, selectable, playable, retryable):
        self.status.configure(text=status, fg="#973e43" if status == "Error" else INK)
        self.detail.configure(text=detail)
        if installing:
            self.bar.configure(value=percent)
            self.bar.grid()
        else:
            self.bar.grid_remove()
        self.select.configure(state="normal" if selectable else "disabled")
        self.start.configure(state="normal" if playable else "disabled",
                             image=self.cursor_image if playable else "")
        if retryable:
            self.retry.grid()
        else:
            self.retry.grid_remove()
