"""Artwork and native Tk controls for the Windows adventure screen."""
import math
import tkinter as tk
from tkinter import ttk

from PIL import Image, ImageOps, ImageTk


BACKGROUND = "#0b172b"
PANEL = "#102039"
EDGE = "#385f86"
SKY = "#83cfee"
MINT = "#68e4bc"
INK = "#edfaff"
MUTED = "#bfd4e9"


class AdventureView:
    def __init__(self, root, artwork, title, choose, retry, play):
        dpi = root.winfo_fpixels("1i") / 96
        # Keep the complete frame visible on short displays at high scaling.
        self.scale = min(dpi, (root.winfo_screenheight() - 110) / 510,
                         (root.winfo_screenwidth() - 40) / 650)
        root.title(title)
        root.configure(background=BACKGROUND)
        root.minsize(self.px(650), self.px(510))
        width = min(self.px(900), root.winfo_screenwidth() - 40)
        height = min(self.px(590), root.winfo_screenheight() - 110)
        root.geometry(f"{width}x{height}")

        self.panorama = self.load(artwork / "panorama.png")
        self.hero = tk.Canvas(root, background=BACKGROUND, highlightbackground=SKY,
                              highlightthickness=1, height=1)
        self.hero.pack(fill="both", expand=True, padx=self.px(14), pady=(self.px(14), self.px(10)))
        self.hero.bind("<Configure>", self.draw_panorama)

        style = ttk.Style(root)
        style.theme_use("clam")
        style.configure("Adventure.Horizontal.TProgressbar", troughcolor="#203853",
                        background=MINT, lightcolor=MINT, darkcolor=MINT, borderwidth=0,
                        thickness=self.px(8))
        style.configure("Adventure.Play.TButton", font=self.face("Bahnschrift", 26, "bold"),
                        padding=(self.px(48), self.px(8)), background=MINT, foreground="#092d32",
                        bordercolor="#225a58", lightcolor="#b1f5db", darkcolor="#267065",
                        focuscolor="#0d5b53", focusthickness=2)
        style.map("Adventure.Play.TButton",
                  background=[("disabled", "#294057"), ("pressed", "#49bd9e"), ("active", "#a7f3da")],
                  foreground=[("disabled", "#aac4d6")])
        style.configure("Adventure.Setup.TButton", font=self.face("Segoe UI", 14, "bold"),
                        padding=(self.px(12), self.px(4)), background=PANEL, foreground=MUTED,
                        bordercolor=EDGE, lightcolor=PANEL, darkcolor=PANEL,
                        focuscolor=SKY, focusthickness=1)
        style.map("Adventure.Setup.TButton", background=[("active", "#244361")],
                  foreground=[("disabled", "#91a9c3"), ("active", INK)])

        panel = tk.Frame(root, bg=PANEL, highlightbackground=EDGE, highlightcolor=EDGE, highlightthickness=1,
                         padx=self.px(20), pady=self.px(12))
        panel.pack(fill="x", padx=self.px(26), pady=(0, self.px(16)))
        panel.columnconfigure(1, weight=1)
        self.marker = tk.Canvas(panel, width=self.px(14), height=self.px(26), bg=PANEL,
                                highlightthickness=0)
        self.marker.grid(row=0, column=0, sticky="w", padx=(0, self.px(9)))
        self.status = tk.Label(panel, font=self.face("Segoe UI", 23, "bold"),
                               fg=INK, bg=PANEL, anchor="w")
        self.status.grid(row=0, column=1, sticky="ew")
        self.detail = tk.Label(panel, font=self.face("Segoe UI", 15), fg=MUTED,
                               bg=PANEL, justify="left", anchor="nw")
        self.detail.grid(row=1, column=1, sticky="ew", pady=(self.px(1), self.px(8)))
        panel.bind("<Configure>", lambda event: self.detail.configure(
            wraplength=max(1, event.width - self.px(67))))
        self.bar = ttk.Progressbar(panel, style="Adventure.Horizontal.TProgressbar")
        self.bar.grid(row=2, column=1, sticky="ew", pady=(0, self.px(8)))
        self.bar.grid_remove()
        tk.Frame(panel, bg="#2c4a6a", height=1).grid(
            row=3, column=0, columnspan=2, sticky="ew", pady=(0, self.px(6)))

        controls = tk.Frame(panel, bg=PANEL)
        controls.grid(row=4, column=0, columnspan=2, sticky="ew")
        controls.columnconfigure(1, weight=1)
        self.start = ttk.Button(controls, text="JUGAR", style="Adventure.Play.TButton", command=play)
        self.start.grid(row=0, column=1, pady=(self.px(4), self.px(6)))
        self.select = ttk.Button(controls, text="Seleccionar carpeta original",
                                 style="Adventure.Setup.TButton", command=choose)
        self.select.grid(row=1, column=1)
        self.retry = ttk.Button(controls, text="Reintentar", style="Adventure.Setup.TButton", command=retry)
        self.retry.grid(row=2, column=1, pady=(self.px(5), 0))
        self.retry.grid_remove()

        for column, side, sprite_name in ((0, "left", "pikachu-ash.png"), (2, "right", "eevee.png")):
            corner = self.load(artwork / f"corner-{side}.png").convert("RGBA")
            sprite = artwork / sprite_name
            if sprite.is_file():
                try:
                    character = self.load(sprite).convert("RGBA")
                    bounds = character.getbbox()
                    if bounds:
                        character = ImageOps.contain(character.crop(bounds), (34, 37), Image.Resampling.NEAREST)
                        tile = Image.new("RGBA", (48, 55))
                        tile.alpha_composite(corner, (0, 23))
                        tile.alpha_composite(character, ((48 - character.width) // 2, 44 - character.height))
                        corner = tile
                except (OSError, ValueError, Image.DecompressionBombError):
                    pass
            corner = corner.resize((self.px(corner.width * 2), self.px(corner.height * 2)),
                                   Image.Resampling.NEAREST)
            decoration = tk.Label(controls, bg=PANEL, borderwidth=0)
            decoration.image = ImageTk.PhotoImage(corner)
            decoration.configure(image=decoration.image)
            decoration.grid(row=0, column=column, rowspan=3, sticky="s")

    @staticmethod
    def load(path):
        with Image.open(path) as image:
            return image.copy()

    def px(self, value):
        return max(1, round(value * self.scale))

    def face(self, family, size, weight="normal"):
        return (family, -self.px(size), weight)

    def draw_panorama(self, event):
        canvas = self.hero
        width, height = event.width, event.height
        if width < 4 or height < 4:
            return
        fitted = ImageOps.fit(self.panorama, (width, height), Image.Resampling.NEAREST,
                             centering=(0.5, 0.56))
        canvas.picture = ImageTk.PhotoImage(fitted)
        canvas.delete("all")
        canvas.create_image(0, 0, image=canvas.picture, anchor="nw")
        canvas.create_rectangle(5, 5, width - 6, height - 6, outline="#97c5da")
        unit = min(width / 900, height / 292, self.scale * 1.35)
        for text, center, size, color, family in (
            ("POKÉMON", .25, 40, "#f6f3d9", "Arial"),
            ("AÑIL", .48, 99, INK, "Arial"),
            ("CO-OP", .72, 30, "#a6f4dd", "Bahnschrift"),
        ):
            x, y = width / 2, height * center
            face = (family, -max(1, round(size * unit)), "bold")
            outline = max(1, round(unit * 3))
            for step in range(8):
                angle = math.tau * step / 8
                canvas.create_text(x + outline * math.cos(angle), y + outline * math.sin(angle),
                                   text=text, font=face, fill="#142743")
            canvas.create_text(x, y, text=text, font=face, fill=color)

    def render(self, status, detail, *, installing, percent, selectable, playable, retryable):
        self.status.configure(text=status)
        self.detail.configure(text=detail)
        self.marker.delete("all")
        points = [self.px(p) for p in (1, 13, 7, 7, 13, 13, 7, 19)]
        color = "#ffac9b" if status == "Error" else MINT if playable else SKY
        self.marker.create_polygon(*points, fill=color)
        if installing:
            self.bar.configure(value=percent)
            self.bar.grid()
        else:
            self.bar.grid_remove()
        self.select.configure(state="normal" if selectable else "disabled")
        self.start.configure(state="normal" if playable else "disabled")
        if retryable:
            self.retry.grid()
        else:
            self.retry.grid_remove()
