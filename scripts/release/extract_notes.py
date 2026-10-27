#!/usr/bin/env python3
"""Extract a strictly matching version section from CHANGELOG.md."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


HEADING = re.compile(
    r"^## (?:\[(?P<bracket_version>[^\]]+)\]|v(?P<tag_version>\S+))"
    r"(?:\s+-\s+.+)?\s*$"
)
TAG = re.compile(r"^v?(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$")
PUBSPEC_VERSION = re.compile(
    r"^version:\s*(?P<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\+\d+)?\s*$",
    re.MULTILINE,
)


def extract_release_notes(changelog: Path, tag: str, pubspec: Path) -> str:
    match = TAG.fullmatch(tag)
    if match is None:
        raise ValueError(f"tag {tag!r} is not a valid vX.Y.Z release tag")
    version = tag.removeprefix("v")
    try:
        pubspec_contents = pubspec.read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError(f"cannot read package manifest {pubspec}: {error}") from error
    pubspec_match = PUBSPEC_VERSION.search(pubspec_contents)
    if pubspec_match is None:
        raise ValueError(f"cannot find a valid version in {pubspec}")
    if pubspec_match.group("version") != version:
        raise ValueError(
            f"tag version {version} does not match pubspec version "
            f"{pubspec_match.group('version')}"
        )
    try:
        contents = changelog.read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError(f"cannot read changelog {changelog}: {error}") from error

    lines = contents.splitlines()
    headings = [
        (
            index,
            heading.group("bracket_version") or heading.group("tag_version"),
        )
        for index, line in enumerate(lines)
        if (heading := HEADING.fullmatch(line)) is not None
    ]
    matches = [index for index, heading_version in headings if heading_version == version]
    if len(matches) != 1:
        raise ValueError(
            f"expected exactly one '## [{version}]' section in {changelog}; found {len(matches)}"
        )

    start = matches[0] + 1
    end = next((index for index, _ in headings if index > matches[0]), len(lines))
    notes = "\n".join(lines[start:end]).strip()
    if not notes:
        raise ValueError(f"release section [{version}] in {changelog} is empty")
    if not any(line.strip() for line in notes.splitlines()):
        raise ValueError(f"release section [{version}] in {changelog} contains no notes")
    return notes + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="release tag, for example v2.0.0")
    parser.add_argument("--changelog", type=Path, default=Path("CHANGELOG.md"))
    parser.add_argument("--pubspec", type=Path, default=Path("pubspec.yaml"))
    parser.add_argument("--output", type=Path, help="write notes here instead of stdout")
    args = parser.parse_args()
    try:
        notes = extract_release_notes(args.changelog, args.tag, args.pubspec)
        if args.output:
            args.output.write_text(notes, encoding="utf-8")
        else:
            sys.stdout.write(notes)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
