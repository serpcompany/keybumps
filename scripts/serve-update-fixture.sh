#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  print -u2 "usage: $0 <fixture-directory> [port]"
  exit 64
fi

fixture_directory=${1:A}
fixture_port=${2:-8765}
[[ -f "$fixture_directory/appcast.xml" ]] || { print -u2 "missing $fixture_directory/appcast.xml"; exit 66; }
[[ "$fixture_port" == <1-65535> ]] || { print -u2 "invalid port: $fixture_port"; exit 65; }

print "Fixture feed: http://127.0.0.1:$fixture_port/appcast.xml"
print "This server is loopback-only and is not a production update origin."
cd "$fixture_directory"
/usr/bin/python3 -m http.server "$fixture_port" --bind 127.0.0.1
