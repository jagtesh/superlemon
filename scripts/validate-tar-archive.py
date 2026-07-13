#!/usr/bin/env python3
"""Validate an archive's extraction paths and links without extracting it."""

from __future__ import annotations

import argparse
import posixpath
import sys
import tarfile


class UnsafeArchive(ValueError):
    pass


def normalize_path(path: str, *, description: str) -> str:
    if not path or "\0" in path:
        raise UnsafeArchive(f"{description} is empty or contains NUL")
    if posixpath.isabs(path):
        raise UnsafeArchive(f"{description} is absolute: {path!r}")
    normalized = posixpath.normpath(path)
    if normalized in ("", ".") or normalized == ".." or normalized.startswith("../"):
        raise UnsafeArchive(f"{description} escapes the extraction root: {path!r}")
    return normalized


def is_within(root: str, candidate: str) -> bool:
    return candidate == root or candidate.startswith(root + "/")


def validate_archive(archive_path: str, expected_root: str) -> int:
    root = normalize_path(expected_root, description="expected archive root")
    if "/" in root:
        raise UnsafeArchive(f"expected archive root must be one directory: {expected_root!r}")

    entry_count = 0
    with tarfile.open(archive_path, mode="r:gz") as archive:
        for member in archive:
            entry_count += 1
            name = normalize_path(member.name, description="archive member path")
            if not is_within(root, name):
                raise UnsafeArchive(
                    f"archive member is outside expected root {root!r}: {member.name!r}"
                )

            if member.issym():
                if not member.linkname or "\0" in member.linkname:
                    raise UnsafeArchive(f"symlink has an invalid target: {member.name!r}")
                if posixpath.isabs(member.linkname):
                    raise UnsafeArchive(
                        f"symlink target is absolute: {member.name!r} -> {member.linkname!r}"
                    )
                target = posixpath.normpath(
                    posixpath.join(posixpath.dirname(name), member.linkname)
                )
                if not is_within(root, target):
                    raise UnsafeArchive(
                        f"symlink target escapes {root!r}: "
                        f"{member.name!r} -> {member.linkname!r}"
                    )
            elif member.islnk():
                target = normalize_path(member.linkname, description="hardlink target")
                if not is_within(root, target):
                    raise UnsafeArchive(
                        f"hardlink target escapes {root!r}: "
                        f"{member.name!r} -> {member.linkname!r}"
                    )
            elif not (member.isfile() or member.isdir()):
                raise UnsafeArchive(
                    f"unsupported special archive member type for {member.name!r}"
                )

    if entry_count == 0:
        raise UnsafeArchive("archive is empty")
    return entry_count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", help="gzip-compressed tar archive to validate")
    parser.add_argument("expected_root", help="required single top-level directory")
    args = parser.parse_args()

    try:
        entry_count = validate_archive(args.archive, args.expected_root)
    except (UnsafeArchive, tarfile.TarError, OSError) as error:
        print(f"unsafe tar archive: {error}", file=sys.stderr)
        return 1

    print(f"ARCHIVE OK: {entry_count} entries below {args.expected_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
