"""Verified GitHub release updates for the Windows folder launcher.

New bundles live beside the private game profile, never inside its saves or
the original game. An older launcher delegates to the activated bundle.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tempfile
import uuid
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
import zipfile


REPO = "TiagooopNOC/pokemon-anil-COOP"
API = f"https://api.github.com/repos/{REPO}/releases?per_page=30"
ASSET = "AnilCoop-Launcher-win-x64.zip"
PACKAGE = "AnilCoop-Launcher"
EXE = "AnilCoop-Launcher.exe"
MAX_DOWNLOAD = 150 * 1024 * 1024
MAX_EXTRACTED = 600 * 1024 * 1024
MAX_FILES = 3000
TAG = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
SHA256 = re.compile(r"sha256:([0-9a-f]{64})\Z")


class UpdateError(RuntimeError):
    pass


def current_tag(assets: Path) -> str:
    path = assets / "config/launcher-release.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))["tag"]
    except (OSError, ValueError, KeyError, TypeError):
        return "development"
    return value if isinstance(value, str) and TAG.fullmatch(value) else "development"


def _request(url: str):
    return Request(url, headers={"Accept": "application/vnd.github+json",
                                 "User-Agent": "AnilCoop-Launcher-Updater"})


def find_update(tag: str, *, opener=urlopen):
    """Return the newest published release after this exact release tag."""
    if tag == "development":
        return None
    with opener(_request(API), timeout=10) as response:
        releases = json.load(response)
    if not isinstance(releases, list):
        raise UpdateError("GitHub no devolvió una lista de versiones válida.")
    published = [item for item in releases if isinstance(item, dict) and
                 not item.get("draft") and item.get("published_at") and
                 isinstance(item.get("tag_name"), str)]
    current = next((item for item in published if item["tag_name"] == tag), None)
    if current is None:
        raise UpdateError("La versión instalada no aparece entre las releases recientes.")
    newer = [item for item in published if item["published_at"] > current["published_at"]]
    if not newer:
        return None
    release = max(newer, key=lambda item: item["published_at"])
    assets = [item for item in release.get("assets", []) if isinstance(item, dict) and
              item.get("name") == ASSET and item.get("state") == "uploaded"]
    if len(assets) != 1 or not TAG.fullmatch(release["tag_name"]):
        raise UpdateError("La release nueva no contiene un launcher Windows válido.")
    asset = assets[0]
    digest = SHA256.fullmatch(str(asset.get("digest", "")))
    size = asset.get("size")
    url = asset.get("browser_download_url")
    parsed = urlsplit(url) if isinstance(url, str) else None
    expected = f"/{REPO}/releases/download/{release['tag_name']}/{ASSET}"
    if (not digest or type(size) is not int or not 0 < size <= MAX_DOWNLOAD or not parsed or
            parsed.scheme != "https" or parsed.netloc != "github.com" or parsed.path != expected or
            parsed.query or parsed.fragment):
        raise UpdateError("La release no ofrece un archivo verificable por SHA-256.")
    return {"tag": release["tag_name"], "size": size, "digest": digest[1], "url": url}


def _validate_archive(archive: zipfile.ZipFile):
    entries = archive.infolist()
    if len(entries) > MAX_FILES or sum(item.file_size for item in entries) > MAX_EXTRACTED:
        raise UpdateError("El paquete excede el tamaño permitido.")
    seen = set()
    names = set()
    for item in entries:
        name = item.filename
        path = PurePosixPath(name)
        parts = path.parts
        raw_parts = name.rstrip("/").split("/")
        mode = (item.external_attr >> 16) & 0xFFFF
        if (not parts or parts[0] != PACKAGE or path.is_absolute() or
                any(part in ("", ".", "..") for part in raw_parts) or
                "\\" in name or ":" in name or name.casefold() in seen or
                (mode and stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR))):
            raise UpdateError("El ZIP contiene rutas o archivos no permitidos.")
        seen.add(name.casefold())
        names.add(name)
    required = {f"{PACKAGE}/{EXE}",
                f"{PACKAGE}/_internal/config/build.json",
                f"{PACKAGE}/_internal/config/launcher-release.json"}
    if not required.issubset(names):
        raise UpdateError("El ZIP no contiene un launcher completo.")


def _atomic_json(path: Path, value: dict):
    temp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with temp.open("x", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def stage_update(data: Path, release: dict, progress=lambda *_: None, *, opener=urlopen) -> Path:
    """Download, verify, unpack and activate without replacing a running EXE."""
    updates = data / "launcher-updates"
    versions = updates / "versions"
    if updates.is_symlink() or versions.is_symlink():
        raise UpdateError("La carpeta de actualizaciones no es segura.")
    versions.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix="stage-", dir=updates))
    try:
        archive_path = staging / ASSET
        received = 0
        sha = hashlib.sha256()
        with opener(_request(release["url"]), timeout=30) as response, archive_path.open("xb") as output:
            while block := response.read(1024 * 1024):
                received += len(block)
                if received > MAX_DOWNLOAD or received > release["size"]:
                    raise UpdateError("La descarga superó el tamaño publicado.")
                sha.update(block)
                output.write(block)
                progress("downloading", received, release["size"])
            output.flush()
            os.fsync(output.fileno())
        progress("verifying_update", 0, 1)
        if received != release["size"] or sha.hexdigest() != release["digest"]:
            raise UpdateError("El SHA-256 de la descarga no coincide con GitHub.")
        with zipfile.ZipFile(archive_path) as archive:
            _validate_archive(archive)
            archive.extractall(staging / "unpacked")
        package = staging / "unpacked" / PACKAGE
        if current_tag(package / "_internal") != release["tag"] or not (package / EXE).is_file():
            raise UpdateError("La versión dentro del paquete no coincide con la release.")
        progress("installing_update", 0, 1)
        destination = versions / release["digest"][:24]
        if destination.exists():
            if (destination.is_symlink() or current_tag(destination / "_internal") != release["tag"] or
                    not (destination / EXE).is_file()):
                raise UpdateError("La versión descargada existente está incompleta.")
        else:
            os.replace(package, destination)
        _atomic_json(updates / "active.json", {"tag": release["tag"],
                                                "digest": release["digest"],
                                                "directory": destination.name})
        progress("installing_update", 1, 1)
        return destination / EXE
    except UpdateError:
        raise
    except (OSError, RuntimeError, zipfile.BadZipFile) as error:
        raise UpdateError(f"No se pudo instalar la actualización: {error}") from error
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def active_executable(data: Path, current_exe: Path) -> Path | None:
    """Delegate an old packaged launcher to the installed newer version."""
    if not getattr(sys, "frozen", False):
        return None
    try:
        updates = data / "launcher-updates"
        if updates.is_symlink() or (updates / "versions").is_symlink():
            return None
        marker = json.loads((updates / "active.json").read_text(encoding="utf-8"))
        directory = marker["directory"]
        if not isinstance(directory, str) or not re.fullmatch(r"[0-9a-f]{24}", directory):
            return None
        candidate = updates / "versions" / directory
        exe = candidate / EXE
        if candidate.is_symlink() or exe.is_symlink() or not exe.is_file():
            return None
        if current_tag(candidate / "_internal") != marker["tag"]:
            return None
        if exe.resolve() == current_exe.resolve():
            return None
        return exe
    except (OSError, ValueError, KeyError, TypeError):
        return None


def rollback_activation(data: Path, release: dict):
    """Keep the previous launcher active if the new GUI never starts."""
    marker = data / "launcher-updates/active.json"
    try:
        active = json.loads(marker.read_text(encoding="utf-8"))
        if active.get("tag") == release["tag"] and active.get("digest") == release["digest"]:
            marker.unlink()
    except (OSError, ValueError, KeyError, TypeError):
        pass
