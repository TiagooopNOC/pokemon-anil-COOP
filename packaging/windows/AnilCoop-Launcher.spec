from pathlib import Path
import sys

root = Path(SPECPATH).resolve().parents[1]
sys.path.insert(0, str(root))
from tools.install_presence import GAME_SCRIPTS

assets = [
    (str(root / "config/build.json"), "config"),
    (str(root / "src/bootstrap/isolate.rb"), "src/bootstrap"),
    *((str(root / "src/game" / script), "src/game") for script in GAME_SCRIPTS),
]

analysis = Analysis(
    [str(root / "tools/windows_launcher.pyw")],
    pathex=[str(root)],
    datas=assets,
)
archive = PYZ(analysis.pure)
launcher = EXE(
    archive, analysis.scripts, [],
    name="AnilCoop-Launcher",
    exclude_binaries=True,
    console=False,
    upx=False,
)
bundle = COLLECT(launcher, analysis.binaries, analysis.datas, name="AnilCoop-Launcher", upx=False)
