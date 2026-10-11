#!/bin/zsh
# Run Screencast's QA smoke test (-KBScreencastSmokeTest, #470) on the installed QA candidate:
# it records 2 s each of the main display, a window of its own, and an area, takes a screenshot
# of each, checks and deletes every file, and writes a structural result (no titles, app names,
# file names, or paths). The macOS recording indicator shows for about ten seconds.
#
# It quits the running Keybumps by bundle id first, and reopens it afterwards whatever happened.
# Screen Recording must already be granted to the installed app: without it the run reports
# permission-denied, and nothing opens a prompt or System Settings. It never touches the
# person's captures folder or settings.
#
# usage: apps/macos/scripts/smoke-screencast.sh [--timeout <seconds>]
# exit:  0 passed; 1 a capture failed; 2 permission-denied or nothing could run;
#        3 no complete result (crashed, hung, or timed out); 64-69 couldn't start it.
set -euo pipefail

usage="usage: $0 [--timeout <seconds>]"
timeout=180
while (( $# )); do
  case $1 in
    --timeout) (( $# >= 2 )) && [[ "$2" == <-> ]] || { print -u2 "$usage"; exit 64 }; timeout=$2; shift 2 ;;
    *) print -u2 "$usage"; exit 64 ;;
  esac
done

installed_app=/Applications/Keybumps.app
executable="$installed_app/Contents/MacOS/Keybumps"
option=KBScreencastSmokeTest
# Fixed: the app writes here (ScreencastSmokeTest.resultURL), beside build-qa-candidate.sh's backups.
result="$HOME/Library/Developer/Keybumps-QA/screencast-smoke-test.json"

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$installed_app/Contents/Info.plist" 2>/dev/null || true }
# Match only the installed copy, never a Debug build or test host running from DerivedData.
installed_pids() { pgrep -f "^$executable" || true }
json_value() { /usr/bin/plutil -extract "$1" raw -o - "$result" 2>/dev/null || true }

[[ -d "$installed_app" ]] || { print -u2 "no installed app at $installed_app"; exit 66 }
# Release builds ignore the option and would just open Keybumps, so only a QA candidate is run.
require_candidate() {
  [[ "$(plist_value CFBundleShortVersionString)" == *-dev.* ]] || {
    print -u2 "the installed Keybumps ($(plist_value CFBundleShortVersionString)) isn't a QA candidate; install one with build-qa-candidate.sh"
    exit 67
  }
}
require_candidate

# The smoke run this script started, once it's running. Only it is ever stopped: politely, then
# for good.
smoke_pid=
stop_smoke() {
  [[ -n "$smoke_pid" ]] && kill -0 "$smoke_pid" 2>/dev/null || return 0
  kill "$smoke_pid" 2>/dev/null || true
  for _ in {1..20}; do kill -0 "$smoke_pid" 2>/dev/null || return 0; sleep 0.25; done
  kill -KILL "$smoke_pid" 2>/dev/null || true
  for _ in {1..20}; do kill -0 "$smoke_pid" 2>/dev/null || return 0; sleep 0.25; done
}
reopen() {
  local code=$?
  trap - EXIT INT TERM
  stop_smoke
  [[ -n "$(installed_pids)" ]] || open "$installed_app" || print -u2 "couldn't reopen Keybumps; open it from /Applications"
  exit $code
}
trap reopen EXIT
trap 'exit 130' INT TERM

if [[ -n "$(installed_pids)" ]]; then
  osascript -e 'tell application id "com.serp.keybumps" to quit' >/dev/null 2>&1 || true
  for _ in {1..40}; do [[ -z "$(installed_pids)" ]] && break; sleep 0.25; done
  [[ -z "$(installed_pids)" ]] || { print -u2 "Keybumps did not quit; close it and rerun"; exit 68 }
fi
# Quitting can let a downloaded update replace the candidate; then there's nothing to test.
require_candidate

mkdir -p "${result:h}"
rm -f "$result"
# Opened through Launch Services, not run from this shell, so macOS checks Screen Recording for
# Keybumps rather than for the terminal that started the script.
open -n "$installed_app" --args "-$option" YES
# Keybumps was quit above, so the installed copy running now is the smoke run just opened.
for _ in {1..40}; do
  smoke_pid=$(installed_pids | head -1)
  [[ -n "$smoke_pid" || -f "$result" ]] && break
  sleep 0.25
done
# The result can appear between a look for the process and a look for the file.
[[ -n "$smoke_pid" ]] || smoke_pid=$(installed_pids | head -1)
timed_out=0
deadline=$(( SECONDS + timeout ))
while [[ -n "$smoke_pid" ]] && kill -0 "$smoke_pid" 2>/dev/null; do
  if (( SECONDS >= deadline )); then
    timed_out=1
    print -u2 "the smoke test didn't finish in ${timeout}s; stopping it"
    stop_smoke
    break
  fi
  sleep 0.5
done

# The app deletes its captures itself; this covers a run that crashed or was stopped.
temporary=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)
[[ "$temporary" == /* ]] && rm -rf -- "${temporary%/}/Keybumps-screencast-smoke-test"

status=3
if [[ -f "$result" ]]; then
  cat "$result"
  print
  if [[ "$(json_value complete)" != true ]]; then
    print -u2 "the smoke test stopped before it finished (it crashed or hung); the last stage reached is above"
  elif [[ "$(json_value errorCategory)" == permissionDenied ]] || grep -q '"screenRecordingDenied"' "$result"; then
    print -u2 "permission-denied: grant Screen Recording to the installed Keybumps, then rerun"
    status=2
  elif [[ "$(json_value passed)" == true ]]; then
    status=0
  elif [[ -n "$(json_value errorCategory)" ]]; then
    status=2
  else
    status=1
  fi
else
  print -u2 "no result: the smoke test didn't start, or crashed before writing anything"
fi
(( timed_out )) && status=3
print "screencast smoke test: exit $status"
exit $status
