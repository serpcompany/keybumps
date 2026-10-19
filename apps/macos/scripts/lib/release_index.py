#!/usr/bin/python3
"""releases.json, the release index on the production release origin (#565).

A JSON array with one entry per published release, newest (highest build) first:

    {"version": "0.0.3-beta.28", "build": 4033,
     "url": "https://updates.keybumps.app/releases/4033/Keybumps-0.0.3-beta.28.dmg",
     "releasedAt": "2026-10-19T15:21:01Z"}

Merging never drops an entry or rewrites one: an entry already listed stays as it is, a version
published again under a higher build replaces its entry, and anything else that disagrees with
the list (a build listed under another version or date, or a lower build for a listed version)
stops the merge.
"""
import json
import re
import sys
from datetime import datetime

USAGE = """usage: release_index.py entry <version> <build> <released-at> <output>
       release_index.py merge <additions> <output> [<index>]
       release_index.py check <index>"""
ORIGIN = "https://updates.keybumps.app"
FIELDS = ("version", "build", "url", "releasedAt")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$")
RELEASED_AT = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")


class ReleaseIndexError(Exception):
    pass


def dmg_url(version, build):
    """The immutable DMG each release publishes (docs/releases/cloudflare.md)."""
    return f"{ORIGIN}/releases/{build}/Keybumps-{version}.dmg"


def checked_entry(entry, where):
    if not isinstance(entry, dict) or set(entry) != set(FIELDS):
        raise ReleaseIndexError(f"{where}: an entry has exactly the fields {', '.join(FIELDS)}")
    version, build, url, released_at = (entry[field] for field in FIELDS)
    if not isinstance(version, str) or not VERSION.match(version):
        raise ReleaseIndexError(f"{where}: version {version!r} is not a release version")
    if isinstance(build, bool) or not isinstance(build, int) or build <= 0:
        raise ReleaseIndexError(f"{where}: build {build!r} is not a positive integer")
    if url != dmg_url(version, build):
        raise ReleaseIndexError(f"{where}: url must be {dmg_url(version, build)} (found {url!r})")
    if not isinstance(released_at, str) or not RELEASED_AT.match(released_at):
        raise ReleaseIndexError(f"{where}: releasedAt {released_at!r} is not a UTC time like 2026-10-19T12:00:00Z")
    try:
        datetime.strptime(released_at, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise ReleaseIndexError(f"{where}: releasedAt {released_at!r} is not a real time") from error
    return {field: entry[field] for field in FIELDS}


def checked_list(entries, where):
    """The list's entries, each checked, with no version or build twice, newest first."""
    if not isinstance(entries, list):
        raise ReleaseIndexError(f"{where}: the index is a JSON array of releases")
    checked = [checked_entry(entry, f"{where}[{position}]") for position, entry in enumerate(entries)]
    for field in ("version", "build"):
        values = [entry[field] for entry in checked]
        duplicates = sorted({str(value) for value in values if values.count(value) > 1})
        if duplicates:
            raise ReleaseIndexError(f"{where}: {field} listed more than once: {', '.join(duplicates)}")
    builds = [entry["build"] for entry in checked]
    if builds != sorted(builds, reverse=True):
        raise ReleaseIndexError(f"{where}: releases must be listed newest (highest build) first")
    return checked


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as error:
        raise ReleaseIndexError(f"{path}: not readable JSON ({error})") from error
    return checked_list(data, path)


def merge(index, additions):
    """Returns the merged list, newest first, and a line for each addition."""
    merged = list(index)
    changes = []
    for addition in additions:
        same_build = next((entry for entry in merged if entry["build"] == addition["build"]), None)
        same_version = next((entry for entry in merged if entry["version"] == addition["version"]), None)
        if same_build is not None:
            if same_build != addition:
                raise ReleaseIndexError(
                    f"build {addition['build']} is already listed as {same_build['version']} released "
                    f"{same_build['releasedAt']}, not {addition['version']} released {addition['releasedAt']}"
                )
            changes.append(f"already listed: {addition['version']} ({addition['build']})")
            continue
        if same_version is not None:
            if addition["build"] < same_version["build"]:
                raise ReleaseIndexError(
                    f"{addition['version']} is already listed with a higher build "
                    f"({same_version['build']}, not {addition['build']})"
                )
            merged.remove(same_version)
            changes.append(f"replaced: {addition['version']} build {same_version['build']} with {addition['build']}")
        else:
            changes.append(f"added: {addition['version']} ({addition['build']})")
        merged.append(addition)
    merged.sort(key=lambda entry: entry["build"], reverse=True)
    return checked_list(merged, "merged index"), changes


def write(entries, path):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(entries, handle, indent=2)
        handle.write("\n")


def main(arguments):
    command = arguments[0] if arguments else ""
    if command == "entry" and len(arguments) == 5:
        version, build, released_at, output = arguments[1:]
        if not re.match(r"^[0-9]+$", build):
            raise ReleaseIndexError(f"build {build!r} is not a positive integer")
        entry = {"version": version, "build": int(build), "url": dmg_url(version, build), "releasedAt": released_at}
        write(checked_list([entry], "release"), output)
        return 0
    if command == "merge" and len(arguments) in (3, 4):
        additions = load(arguments[1])
        index = load(arguments[3]) if len(arguments) == 4 else []
        merged, changes = merge(index, additions)
        write(merged, arguments[2])
        for change in changes:
            print(f"  {change}")
        if merged:
            count = f"{len(merged)} release" + ("s" if len(merged) != 1 else "")
            print(f"  {count} in all, newest {merged[0]['version']} ({merged[0]['build']})")
        return 0
    if command == "check" and len(arguments) == 2:
        entries = load(arguments[1])
        print(f"{arguments[1]}: {len(entries)} releases, newest first")
        return 0
    print(USAGE, file=sys.stderr)
    return 64


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ReleaseIndexError as error:
        print(f"release index: {error}", file=sys.stderr)
        sys.exit(65)
