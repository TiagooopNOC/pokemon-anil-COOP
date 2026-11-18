"""Offline release and package checks for the Windows update path."""
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from tools.launcher_updates import (ASSET, EXE, PACKAGE, UpdateError,
                                    active_executable, find_update, rollback_activation,
                                    stage_update)


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def archive(tag="v0.2.0-alpha", extra=None):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as zipped:
        zipped.writestr(f"{PACKAGE}/{EXE}", b"windows-executable-fixture")
        zipped.writestr(f"{PACKAGE}/_internal/config/build.json", b"{}")
        zipped.writestr(f"{PACKAGE}/_internal/config/launcher-release.json",
                        json.dumps({"tag": tag}))
        if extra:
            zipped.writestr(extra, b"unsafe")
    return output.getvalue()


class LauncherUpdateTests(unittest.TestCase):
    def test_finds_new_prerelease_with_official_digest(self):
        releases = [{"tag_name": "v0.2.0-alpha", "published_at": "2026-11-18T12:00:00Z",
                     "draft": False, "assets": [{"name": ASSET, "state": "uploaded", "size": 300,
                       "digest": "sha256:" + "a" * 64,
                       "browser_download_url": "https://github.com/TiagooopNOC/pokemon-anil-COOP/releases/download/v0.2.0-alpha/" + ASSET}]},
                    {"tag_name": "v0.1.1-alpha", "published_at": "2026-11-13T12:00:00Z",
                     "draft": False, "assets": []}]
        opener = lambda *_args, **_kwargs: Response(json.dumps(releases).encode())
        self.assertEqual(find_update("v0.1.1-alpha", opener=opener)["tag"], "v0.2.0-alpha")
        self.assertIsNone(find_update("v0.2.0-alpha", opener=opener))
        releases[0]["assets"][0].pop("digest")
        with self.assertRaisesRegex(UpdateError, "SHA-256"):
            find_update("v0.1.1-alpha", opener=opener)

    def test_stages_verified_bundle_without_touching_saves_and_redirects(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp)
            save = data / "local/clients/client01/profile/saves/Partida 1.rxdata"
            save.parent.mkdir(parents=True)
            save.write_bytes(b"personal-save")
            content = archive()
            release = {"tag": "v0.2.0-alpha", "url": "https://github.com/example.zip",
                       "size": len(content), "digest": hashlib.sha256(content).hexdigest()}
            exe = stage_update(data, release, opener=lambda *_args, **_kwargs: Response(content))
            self.assertEqual(exe.read_bytes(), b"windows-executable-fixture")
            self.assertEqual(save.read_bytes(), b"personal-save")
            with patch("tools.launcher_updates.sys.frozen", True, create=True):
                self.assertEqual(active_executable(data, data / "old.exe"), exe)
                self.assertIsNone(active_executable(data, exe))
                rollback_activation(data, release)
                self.assertIsNone(active_executable(data, data / "old.exe"))
            self.assertEqual(save.read_bytes(), b"personal-save")

    def test_rejects_tampering_and_path_traversal_without_activation(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp)
            content = archive(extra=f"{PACKAGE}/../escaped.exe")
            release = {"tag": "v0.2.0-alpha", "url": "https://github.com/example.zip",
                       "size": len(content), "digest": hashlib.sha256(content).hexdigest()}
            opener = lambda *_args, **_kwargs: Response(content)
            with self.assertRaisesRegex(UpdateError, "rutas"):
                stage_update(data, release, opener=opener)
            self.assertFalse((data / "launcher-updates/active.json").exists())
            release["digest"] = "0" * 64
            with self.assertRaisesRegex(UpdateError, "SHA-256"):
                stage_update(data, release, opener=opener)
            self.assertFalse((data / "launcher-updates/active.json").exists())

    def test_rejects_zip_with_another_release_tag(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp)
            content = archive(tag="v0.3.0-alpha")
            release = {"tag": "v0.2.0-alpha", "url": "https://github.com/example.zip",
                       "size": len(content), "digest": hashlib.sha256(content).hexdigest()}
            with self.assertRaisesRegex(UpdateError, "no coincide"):
                stage_update(data, release, opener=lambda *_args, **_kwargs: Response(content))
            self.assertFalse((data / "launcher-updates/active.json").exists())


if __name__ == "__main__":
    unittest.main()
