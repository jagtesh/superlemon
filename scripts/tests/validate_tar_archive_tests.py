#!/usr/bin/env python3

from __future__ import annotations

import io
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = "nvim-macos-arm64"
HELPER = pathlib.Path(__file__).resolve().parents[1] / "validate-tar-archive.py"


def directory(name: str) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    return info


def regular_file(name: str, contents: bytes = b"fixture\n") -> tuple[tarfile.TarInfo, bytes]:
    info = tarfile.TarInfo(name)
    info.type = tarfile.REGTYPE
    info.mode = 0o755
    info.size = len(contents)
    return info, contents


def link(name: str, target: str, link_type: bytes) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.type = link_type
    info.linkname = target
    return info


class ArchiveValidatorTests(unittest.TestCase):
    def make_archive(self, entries: list[tarfile.TarInfo | tuple[tarfile.TarInfo, bytes]]) -> str:
        archive_path = pathlib.Path(self.temp_dir.name) / "fixture.tar.gz"
        with tarfile.open(archive_path, mode="w:gz") as archive:
            for entry in entries:
                if isinstance(entry, tuple):
                    info, contents = entry
                    archive.addfile(info, io.BytesIO(contents))
                else:
                    archive.addfile(entry)
        return str(archive_path)

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def run_validator(self, archive: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(HELPER), archive, ROOT],
            check=False,
            capture_output=True,
            text=True,
        )

    def assert_rejected(self, entries, diagnostic: str) -> None:
        result = self.run_validator(self.make_archive(entries))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(diagnostic, result.stderr)

    def test_accepts_regular_files_and_links_that_stay_below_root(self) -> None:
        entries = [
            directory(ROOT),
            directory(f"{ROOT}/bin"),
            directory(f"{ROOT}/lib"),
            regular_file(f"{ROOT}/bin/nvim"),
            regular_file(f"{ROOT}/lib/libnvim.dylib"),
            link(f"{ROOT}/bin/libnvim.dylib", "../lib/libnvim.dylib", tarfile.SYMTYPE),
            link(f"{ROOT}/bin/nvim-hardlink", f"{ROOT}/bin/nvim", tarfile.LNKTYPE),
        ]
        result = self.run_validator(self.make_archive(entries))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ARCHIVE OK", result.stdout)

    def test_rejects_parent_traversal_member(self) -> None:
        self.assert_rejected(
            [regular_file(f"{ROOT}/../../escape")], "archive member path escapes"
        )

    def test_rejects_member_outside_expected_top_level_directory(self) -> None:
        self.assert_rejected([regular_file("sibling/file")], "outside expected root")

    def test_rejects_absolute_symlink_target(self) -> None:
        self.assert_rejected(
            [link(f"{ROOT}/bin/link", "/tmp/escape", tarfile.SYMTYPE)],
            "symlink target is absolute",
        )

    def test_rejects_escaping_symlink_target(self) -> None:
        self.assert_rejected(
            [link(f"{ROOT}/bin/link", "../../../escape", tarfile.SYMTYPE)],
            "symlink target escapes",
        )

    def test_rejects_escaping_hardlink_target(self) -> None:
        self.assert_rejected(
            [link(f"{ROOT}/bin/link", "../../escape", tarfile.LNKTYPE)],
            "hardlink target escapes",
        )

    def test_rejects_special_device_members(self) -> None:
        device = tarfile.TarInfo(f"{ROOT}/device")
        device.type = tarfile.CHRTYPE
        self.assert_rejected([device], "unsupported special archive member type")


if __name__ == "__main__":
    unittest.main()
