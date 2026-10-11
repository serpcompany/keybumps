#!/bin/zsh
# Run Screencast's QA smoke test (-KBScreencastSmokeTest, #470) on the installed QA candidate:
# it records 2 s each of the main display, a Finder window, and an area, takes a screenshot of
# each, checks and deletes every file, and writes a structural result (no titles, app names, file
# names, or paths). The macOS recording indicator shows for about ten seconds.
#
# It quits the running Keybumps by bundle id first, and reopens it afterwards whatever happened.
# For the window captures it opens a Finder window on the QA folder (~/Library/Developer/Keybumps-QA,
# which holds only QA files) and closes it afterwards; the smoke test never takes another app's
# window. Screen Recording must already be granted to the installed app: without it the run
# reports permission-denied, and nothing opens a prompt or System Settings. It never touches the
# person's captures folder or settings, and on every exit, Ctrl-C included, it deletes the smoke
# test's temporary captures folder once the smoke run is gone.
#
# usage: apps/macos/scripts/smoke-screencast.sh [--timeout <seconds>]
#        apps/macos/scripts/smoke-screencast.sh --evaluate <result.json>   (that result's exit code)
# exit:  0 passed; 1 a capture failed; 2 permission-denied, or the app couldn't run the captures;
#        3 no complete result (it crashed, hung, timed out, or didn't start).
#        The script couldn't run it: 64 usage; 66 no installed app; 67 not a QA candidate;
#        68 Keybumps didn't quit; 69 couldn't prepare or open it; 130 stopped (Ctrl-C).
set -euo pipefail

usage="usage: $0 [--timeout <seconds>] | --evaluate <result.json>"
timeout=180
evaluate_only=
while (( $# )); do
  case $1 in
    --timeout) (( $# >= 2 )) && [[ "$2" == <-> ]] || { print -u2 "$usage"; exit 64 }; timeout=$2; shift 2 ;;
    --evaluate) (( $# == 2 )) || { print -u2 "$usage"; exit 64 }; evaluate_only=$2; shift 2 ;;
    *) print -u2 "$usage"; exit 64 ;;
  esac
done

json_value() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true }

# Prints a result and sets result_code from it: 0 to 3, as above.
result_code=3
evaluate() {
  local file=$1
  result_code=3
  if [[ ! -f "$file" ]]; then
    print -u2 "no result: the smoke test didn't start, or crashed before writing anything"
    return 0
  fi
  cat "$file"
  print
  if [[ "$(json_value "$file" complete)" != true ]]; then
    print -u2 "the smoke test stopped before it finished (it crashed, hung, or was stopped); the last stage reached is above"
  elif [[ "$(json_value "$file" errorCategory)" == permissionDenied ]] || grep -q '"screenRecordingDenied"' "$file"; then
    print -u2 "permission-denied: grant Screen Recording to the installed Keybumps, then rerun"
    result_code=2
  elif [[ "$(json_value "$file" passed)" == true ]]; then
    result_code=0
  elif [[ -n "$(json_value "$file" errorCategory)" ]]; then
    print -u2 "the smoke test couldn't run its captures: $(json_value "$file" errorCategory)"
    result_code=2
  else
    result_code=1
  fi
}

if [[ -n "$evaluate_only" ]]; then
  evaluate "$evaluate_only"
  print "screencast smoke test: exit $result_code"
  exit $result_code
fi

# Its tests run it on a fake app and folders of their own (ScreencastSmokeScriptTests).
installed_app=${KEYBUMPS_SMOKE_APP:-/Applications/Keybumps.app}
executable="$installed_app/Contents/MacOS/Keybumps"
option=KBScreencastSmokeTest
# Fixed: the app writes here (ScreencastSmokeTest.resultURL), beside build-qa-candidate.sh's backups.
qa_folder="$HOME/Library/Developer/Keybumps-QA"
result="$qa_folder/screencast-smoke-test.json"
# The smoke test's own captures folder (ScreencastSmokeTest.capturesFolderName), in the app's
# temporary folder.
temporary=${KEYBUMPS_SMOKE_TEMPORARY:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)}
captures="${temporary%/}/Keybumps-screencast-smoke-test"

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$installed_app/Contents/Info.plist" 2>/dev/null || true }
# Match only the installed copy, never a Debug build or test host running from DerivedData.
installed_pids() { pgrep -f "^$executable" || true }

[[ -d "$installed_app" ]] || { print -u2 "no installed app at $installed_app"; exit 66 }
# Release builds ignore the option and would just open Keybumps, so only a QA candidate is run.
require_candidate() {
  [[ "$(plist_value CFBundleShortVersionString)" == *-dev.* ]] || {
    print -u2 "the installed Keybumps ($(plist_value CFBundleShortVersionString)) isn't a QA candidate; install one with build-qa-candidate.sh"
    exit 67
  }
}
require_candidate
[[ "$temporary" == /* ]] || { print -u2 "couldn't find the temporary folder"; exit 69 }

# Finder's windows on the QA folder, counted (count) or closed (close); prints how many. Other
# Finder windows are left alone.
finder_windows() {
  osascript - "${qa_folder:A}/" "$1" 2>/dev/null <<'APPLESCRIPT' || true
on run argv
	set folderPath to item 1 of argv
	set found to 0
	tell application "Finder"
		repeat with candidate in (get every Finder window)
			try
				if POSIX path of (target of candidate as alias) is folderPath then
					set found to found + 1
					if item 2 of argv is "close" then close candidate
				end if
			end try
		end repeat
	end tell
	return found
end run
APPLESCRIPT
}

# The smoke run this script opened, once it's running. Only it is ever stopped: politely, then
# for good. False if it's still running.
smoke_pid=
opened=0
finder_opened=0
evaluated=0
stop_smoke() {
  [[ -n "$smoke_pid" ]] && kill -0 "$smoke_pid" 2>/dev/null || return 0
  kill "$smoke_pid" 2>/dev/null || true
  for attempt in {1..20}; do kill -0 "$smoke_pid" 2>/dev/null || return 0; sleep 0.25; done
  kill -KILL "$smoke_pid" 2>/dev/null || true
  for attempt in {1..20}; do kill -0 "$smoke_pid" 2>/dev/null || return 0; sleep 0.25; done
  return 1
}
# Every exit: the smoke run stopped, its captures deleted, the Finder window closed, and Keybumps
# reopened.
finish() {
  local code=$?
  # A second Ctrl-C doesn't cut the clean-up short.
  trap - EXIT
  trap '' INT TERM
  # An exit before the result is read is the script's own failure, never a capture's.
  if (( ! evaluated && code < 64 )); then code=69; fi
  if (( opened )); then
    # One that started after the wait gave up is this script's too: Keybumps was quit first.
    [[ -n "$smoke_pid" ]] || smoke_pid=$(installed_pids | head -1)
    stop_smoke || print -u2 "the smoke test (pid $smoke_pid) didn't stop"
  fi
  # Only once no Keybumps runs, so a smoke run can't save into it again.
  if [[ -z "$(installed_pids)" ]]; then
    rm -rf -- "$captures" 2>/dev/null || print -u2 "couldn't delete the smoke test's captures: $captures"
  elif (( opened )); then
    print -u2 "a Keybumps is still running, so the smoke test's captures are left in $captures"
  fi
  if (( finder_opened )); then finder_windows close >/dev/null; fi
  [[ -n "$(installed_pids)" ]] || open "$installed_app" || print -u2 "couldn't reopen Keybumps; open it from /Applications"
  exit $code
}
trap finish EXIT
trap 'exit 130' INT TERM

if [[ -n "$(installed_pids)" ]]; then
  osascript -e "tell application id \"$(plist_value CFBundleIdentifier)\" to quit" >/dev/null 2>&1 || true
  for attempt in {1..40}; do [[ -z "$(installed_pids)" ]] && break; sleep 0.25; done
  [[ -z "$(installed_pids)" ]] || { print -u2 "Keybumps did not quit; close it and rerun"; exit 68 }
fi
# Quitting can let a downloaded update replace the candidate; then there's nothing to test.
require_candidate

# A run that crashed or was stopped can have left captures behind.
rm -rf -- "$captures" || { print -u2 "couldn't delete the smoke test's captures: $captures"; exit 69 }
mkdir -p "$qa_folder" && rm -f "$result" || { print -u2 "couldn't prepare $qa_folder"; exit 69 }

# The window captures take Finder's frontmost window: this one, on the QA folder. It's closed
# afterwards, unless one was already open there.
already_open=$(finder_windows count)
open "$qa_folder" || { print -u2 "couldn't open the QA folder in Finder"; exit 69 }
if [[ "$already_open" == 0 ]]; then
  finder_opened=1
elif [[ -z "$already_open" ]]; then
  print -u2 "couldn't ask Finder about its windows; close the Keybumps-QA window afterwards"
fi

# Opened through Launch Services, not run from this shell, so macOS checks Screen Recording for
# Keybumps rather than for the terminal that started the script.
opened=1
open -n "$installed_app" --args "-$option" YES || { print -u2 "couldn't open Keybumps"; exit 69 }

# Keybumps was quit above, so the installed copy running now is the smoke run just opened. A
# first launch on a busy Mac can take a while to appear.
deadline=$(( SECONDS + timeout ))
started=$(( SECONDS + 30 ))
(( started < deadline )) || started=$deadline
smoke_pid=$(installed_pids | head -1)
until [[ -n "$smoke_pid" || "$(json_value "$result" complete)" == true ]] || (( SECONDS >= started )); do
  sleep 0.25
  smoke_pid=$(installed_pids | head -1)
done
if [[ -z "$smoke_pid" && "$(json_value "$result" complete)" != true ]]; then
  print -u2 "the smoke test didn't start"
fi
timed_out=0
while [[ -n "$smoke_pid" ]] && kill -0 "$smoke_pid" 2>/dev/null; do
  if (( SECONDS >= deadline )); then
    timed_out=1
    print -u2 "the smoke test didn't finish in ${timeout}s; stopping it"
    stop_smoke || true
    break
  fi
  sleep 0.5
done

evaluated=1
evaluate "$result"
if (( timed_out )); then result_code=3; fi
print "screencast smoke test: exit $result_code"
exit $result_code
