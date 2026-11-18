"""Find compatible saves and publish verified copies inside an isolated profile."""
from contextlib import ExitStack
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import tempfile
import uuid

from .h0 import SafetyError, digest, launch_plan, no_links, read_json, windows_profile_lock
from .save_format import MAX_SAVE_SIZE, validate_save
from .windows_install import installed_client


SAVE_NAME = re.compile(r"(?:Partida ([0-9]{1,9})|Auto [1-3]|Game|Backup[0-9]+)\.rxdata(?:\.bak)?", re.I)
TRADE_STATE = re.compile(r"trade|intercambio", re.I)


@dataclass(frozen=True)
class Candidate:
    path: Path
    slot: int | None
    sha256: str = ""
    error: str = ""


@dataclass(frozen=True)
class Destination:
    preferred: str
    free: str
    existing_hash: str | None


def fingerprint(content):
    return hashlib.sha256(content).hexdigest()


def read_save(path):
    path = no_links(path)
    if not path.is_file():
        raise SafetyError("El archivo seleccionado ya no está disponible.")
    with path.open("rb") as handle:
        before = os.fstat(handle.fileno())
        content = handle.read(MAX_SAVE_SIZE + 1)
        after = os.fstat(handle.fileno())
    if len(content) > MAX_SAVE_SIZE:
        raise SafetyError("El archivo supera el tamaño admitido de 32 MiB.")
    current = no_links(path).stat()
    if any((item.st_ino, item.st_size, item.st_mtime_ns) !=
           (before.st_ino, len(content), before.st_mtime_ns) for item in (before, after, current)):
        raise SafetyError("La partida cambió mientras se leía. Cerrá el juego de origen y volvé a elegirla.")
    validate_save(content)
    return content


def find_saves(selection):
    path = no_links(selection)
    paths = sorted(path.iterdir(), key=lambda file: file.name.casefold()) if path.is_dir() else [path]
    candidates = []
    for file in paths:
        match = SAVE_NAME.fullmatch(file.name)
        if not match:
            continue
        slot = int(match[1]) if match[1] else None
        try:
            candidates.append(Candidate(file, slot, fingerprint(read_save(file))))
        except (SafetyError, OSError) as error:
            message = str(error) if isinstance(error, SafetyError) else "No se pudo leer el archivo."
            candidates.append(Candidate(file, slot, error=message))
    return candidates


def suggested_folder(data):
    # The fixed build uses Game.ini's title as its mkxp-z app name.
    for variable in ("APPDATA", "LOCALAPPDATA"):
        if directory := os.environ.get(variable):
            path = Path(directory) / "Pokemon Anil"
            if path.is_dir():
                return path
    baseline = no_links(data / "local/original.json")
    if baseline.is_file():
        path = Path(read_json(baseline)["source"])
        if path.is_dir():
            return path
    return Path.home()


def require_no_trade_recovery(profile):
    # Current builds only exchange invitations. Treat persisted trade state from
    # a newer build as reserved until its recovery format is known.
    for current, dirs, files in os.walk(profile, followlinks=False, onerror=raise_walk_error):
        if any(TRADE_STATE.search(name) for name in dirs + files):
            raise SafetyError("El perfil contiene datos de intercambio. Resolvé su recuperación antes de importar.")
        for name in dirs:
            no_links(Path(current) / name)


def raise_walk_error(error):
    raise error


def require_game_closed():
    """The original game does not participate in Co-op's file locking."""
    import ctypes
    from ctypes import wintypes

    class ProcessEntry(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("usage", wintypes.DWORD),
                    ("pid", wintypes.DWORD), ("heap", ctypes.c_size_t),
                    ("module", wintypes.DWORD), ("threads", wintypes.DWORD),
                    ("parent", wintypes.DWORD), ("priority", wintypes.LONG),
                    ("flags", wintypes.DWORD), ("name", wintypes.WCHAR * 260)]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    for function in (kernel.Process32FirstW, kernel.Process32NextW):
        function.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry)]
        function.restype = wintypes.BOOL
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)  # TH32CS_SNAPPROCESS
    if snapshot == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        entry = ProcessEntry()
        entry.size = ctypes.sizeof(entry)
        found = kernel.Process32FirstW(snapshot, ctypes.byref(entry))
        while found:
            if entry.name.casefold() == "game.exe":
                raise SafetyError("Cerrá Pokémon Añil y cualquier otra copia del juego antes de importar.")
            found = kernel.Process32NextW(snapshot, ctypes.byref(entry))
        if ctypes.get_last_error() != 18:  # ERROR_NO_MORE_FILES
            raise ctypes.WinError(ctypes.get_last_error())
    finally:
        kernel.CloseHandle(snapshot)


def profile_for(data, assets, client):
    if not client or installed_client(data, assets) != client:
        raise SafetyError("Primero completá la instalación de Pokémon Añil Co-op.")
    entry = launch_plan(data, [client])["clients"][0]
    return no_links(Path(entry["save_directory"]).parent)


def destination_for(saves, candidate):
    existing = {file.name.casefold(): file for file in saves.iterdir()}
    used = set(existing)
    index = 1
    while f"partida {index}.rxdata" in used or f"partida {index}.rxdata.bak" in used:
        index += 1
    free = f"Partida {index}.rxdata"
    preferred = f"Partida {candidate.slot}.rxdata" if candidate.slot is not None else free
    # A detached Multi Save backup reserves its slot as well.
    if preferred.casefold() not in used and f"{preferred.casefold()}.bak" in used:
        preferred = free
    conflict = existing.get(preferred.casefold())
    return Destination(conflict.name if conflict else preferred, free,
                       digest(no_links(conflict)) if conflict else None)


def inspect_destination(data, assets, client, candidate):
    import msvcrt

    profile = profile_for(data, assets, client)
    with windows_profile_lock(no_links(profile / "coop-game.lock"), msvcrt):
        require_no_trade_recovery(profile)
        return destination_for(no_links(profile / "saves"), candidate)


def stage_file(directory, content):
    with tempfile.NamedTemporaryFile(dir=directory, prefix=".save-import-", suffix=".tmp", delete=False) as handle:
        staged = Path(handle.name)
        try:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        except BaseException:
            handle.close()
            staged.unlink(missing_ok=True)
            raise
    try:
        if digest(staged) != fingerprint(content):
            raise SafetyError("Falló la verificación de la copia. Volvé a intentar.")
    except BaseException:
        staged.unlink(missing_ok=True)
        raise
    return staged


def import_save(data, assets, client, candidate, expected, *, replace=False):
    import msvcrt

    if candidate.error or not candidate.sha256 or not SAVE_NAME.fullmatch(candidate.path.name):
        raise SafetyError("Elegí una partida compatible de la lista.")
    profile = profile_for(data, assets, client)
    with ExitStack() as locks:
        locks.enter_context(windows_profile_lock(no_links(profile / "coop-game.lock"), msvcrt))
        require_no_trade_recovery(profile)
        saves = no_links(profile / "saves")
        source = no_links(candidate.path)
        if saves == source.parent:
            raise SafetyError("Esa partida ya está dentro del perfil Co-op de destino.")
        source_profile = source.parent.parent
        if source.parent.name == "saves" and no_links(source_profile / "profile-id.txt").is_file():
            locks.enter_context(windows_profile_lock(no_links(source_profile / "coop-game.lock"), msvcrt))
            require_no_trade_recovery(source_profile)
        current = destination_for(saves, candidate)
        if current != expected:
            raise SafetyError("Las partidas del perfil cambiaron. Volvé a elegir el destino.")
        if replace and current.existing_hash is None:
            raise SafetyError("El destino ya no coincide con la partida que elegiste reemplazar.")
        name = current.free if current.existing_hash and not replace else current.preferred
        target = no_links(saves / name)
        content = read_save(source)
        if fingerprint(content) != candidate.sha256:
            raise SafetyError("La partida de origen cambió. Volvé a seleccionarla.")
        if replace and source.samefile(target):
            raise SafetyError("El origen y el destino son la misma partida.")
        require_game_closed()
        staged = stage_file(saves, content)
        backup = None
        try:
            if replace:
                directory = no_links(profile / "save-import-backups")
                directory.mkdir(exist_ok=True)
                with target.open("rb") as handle:
                    previous = handle.read(MAX_SAVE_SIZE + 1)
                if len(previous) > MAX_SAVE_SIZE:
                    raise SafetyError("La partida de destino es demasiado grande para respaldarla. Elegí otra ranura.")
                if fingerprint(previous) != current.existing_hash:
                    raise SafetyError("La partida de destino cambió. Volvé a seleccionar el destino.")
                recovery = directory / uuid.uuid4().hex
                recovery.mkdir()
                backup_stage = stage_file(recovery, previous)
                try:
                    backup = recovery / target.name
                    backup_stage.rename(backup)
                finally:
                    backup_stage.unlink(missing_ok=True)
                staged.replace(target)
            else:
                # On Windows rename fails if another file already occupies the slot.
                staged.rename(target)
        finally:
            staged.unlink(missing_ok=True)
        return name, backup
