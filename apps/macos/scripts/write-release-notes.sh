#!/bin/zsh
# Turn one release-please CHANGELOG.md section into the Sparkle release notes
# (docs/releases/v<version>.md). Commit and PR links are stripped so users see plain
# notes. A hand-written notes file for the version always wins.
#
# usage: write-release-notes.sh <CHANGELOG.md> <version> <output.md>
set -euo pipefail
(( $# == 3 )) || { print -u2 "usage: $0 <CHANGELOG.md> <version> <output.md>"; exit 64; }
changelog=${1:A}; version=$2; output=$3
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' ]] || { print -u2 "invalid version: $version"; exit 65; }
if [[ -s "$output" ]]; then
  print "Keeping existing release notes: $output"
  exit 0
fi
[[ -f "$changelog" ]] || { print -u2 "missing $changelog"; exit 66; }

/usr/bin/python3 - "$changelog" "$version" "$output" <<'PY'
import re, sys
changelog, version, output = sys.argv[1:]
lines = open(changelog, encoding="utf-8").read().splitlines()
heading = re.compile(r"^##\s+\[?" + re.escape(version) + r"\]?(\s|\(|$)")
start = next((i for i, line in enumerate(lines) if heading.match(line)), None)
if start is None:
    sys.exit(f"CHANGELOG.md has no section for {version}")
body = []
for line in lines[start + 1:]:
    if line.startswith("## "):
        break
    body.append(line)

cleaned = []
for line in body:
    line = re.sub(r"\s*\(\[[0-9a-f]{7,40}\]\([^)]*\)\)", "", line)   # ([abc1234](commit-url))
    line = re.sub(r"\s*\(\[#\d+\]\([^)]*\)\)", "", line)            # ([#60](pr-url))
    line = re.sub(r",?\s*closes\s+\[#\d+\]\([^)]*\)", "", line, flags=re.I)
    line = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", line)            # remaining links → text
    line = re.sub(r"^\* ", "- ", line)
    cleaned.append(line.rstrip())

while cleaned and not cleaned[0]:
    cleaned.pop(0)
while cleaned and not cleaned[-1]:
    cleaned.pop()
if not any(line.startswith("- ") for line in cleaned):
    sys.exit(f"CHANGELOG.md section for {version} has no user-facing entries")
with open(output, "w", encoding="utf-8") as handle:
    handle.write(f"# Keybumps {version}\n\n" + "\n".join(cleaned) + "\n")
PY
print "Wrote $output"
