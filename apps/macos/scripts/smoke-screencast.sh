#!/bin/zsh
# Run Screencast's QA smoke test (-KBScreencastSmokeTest, #470) on the installed QA candidate:
# it records 2 s each of the main display, a blank window, and an area, checks and deletes every
# file, and writes a structural result (no titles, app names, file names, or paths). On screen: a
# blank window titled "Keybumps smoke test" and the macOS recording indicator, for about ten
# seconds. Nothing asks for a permission. If the window capture fails with noSmokeWindow, leave
# full screen and run it again.
#
# It quits the running Keybumps by bundle id first, and reopens it afterwards whatever happened.
# The blank window comes from a helper process of the script's own (osascript running
# JavaScript, which draws its own window, sends no Apple events, and never takes keyboard focus),
# and the smoke test records only that process's window, never one of the person's. Screen
# Recording must already be granted to the installed app: without it the run reports
# permission-denied, and nothing opens a prompt or System Settings. It never touches the person's
# captures folder or settings. On every exit (Ctrl-C and a closed terminal included) it stops the
# smoke run and the helper, and deletes the smoke test's temporary captures folder once
# the smoke run is gone.
#
# usage: apps/macos/scripts/smoke-screencast.sh [--timeout <seconds>]
#        apps/macos/scripts/smoke-screencast.sh --evaluate <result.json>   (that result's exit code)
# exit:  0 passed; 1 a capture failed; 2 permission-denied, or the app couldn't run the captures;
#        3 no complete result (it crashed, hung, timed out, or didn't start).
#        The script couldn't run it: 64 usage; 66 no installed app; 67 not a QA candidate;
#        68 Keybumps didn't quit; 69 couldn't prepare or open it; 130 stopped (Ctrl-C, or the
#        terminal closed).
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

# Its tests run it on a fake app and folders of their own, and shorten the start wait
# (ScreencastSmokeScriptTests).
installed_app=${KEYBUMPS_SMOKE_APP:-/Applications/Keybumps.app}
executable="$installed_app/Contents/MacOS/Keybumps"
option=KBScreencastSmokeTest
window_option=KBScreencastSmokeWindowPID
# How long the smoke run has to appear after it's opened, and how much longer the clean-up looks
# for one that appears later still.
start_wait=${KEYBUMPS_SMOKE_START_WAIT:-30}
[[ "$start_wait" == <-> ]] || start_wait=30
late_wait=10
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

# The blank window the window capture takes, shown by a helper of the script's own so the smoke
# test can tell it by its process ID. It's an accessory app, so it never becomes active or takes
# keyboard focus; it's on every Space, full-screen ones included; and it closes when the script
# is gone (it's given the script's PID, so that holds from its first line), or after its lifetime
# at most.
helper_pid=
work=
start_helper() {
  : >| "$work/window-ready"
  osascript -l JavaScript - $(( start_wait + timeout + 120 )) $$ >| "$work/window-ready" 2>/dev/null <<'JAVASCRIPT' &
ObjC.import('Cocoa');
ObjC.import('unistd');
function run(argv) {
	const lifetime = Number(argv[0]) || 600;
	const script = Number(argv[1]);
	if ($.getppid() !== script) return;
	$.NSApplication.sharedApplication.setActivationPolicy(1); // accessory
	const visible = $.NSScreen.screens.objectAtIndex(0).visibleFrame;
	const width = 480, height = 270;
	const frame = $.NSMakeRect(visible.origin.x + visible.size.width - width - 40, visible.origin.y + 40, width, height);
	const window = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(frame, 1, 2, false); // titled, buffered
	window.releasedWhenClosed = false;
	window.title = 'Keybumps smoke test';
	window.collectionBehavior = 1 | 256; // every Space, full-screen ones included
	window.orderFrontRegardless;
	$.NSFileHandle.fileHandleWithStandardOutput.writeData($('ready\n').dataUsingEncoding($.NSUTF8StringEncoding));
	const end = Date.now() + lifetime * 1000;
	while (Date.now() < end && $.getppid() === script) {
		$.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.25));
	}
}
JAVASCRIPT
  helper_pid=$!
  for attempt in {1..40}; do
    [[ "$(<"$work/window-ready")" == ready ]] && kill -0 "$helper_pid" 2>/dev/null && return 0
    kill -0 "$helper_pid" 2>/dev/null || break
    sleep 0.25
  done
  return 1
}

# A process this script started (the helper) or opened (the smoke run), stopped by its PID:
# politely, then for good. False if it's still running.
stop_pid() {
  local pid=$1
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || return 0
  kill "$pid" 2>/dev/null || true
  for attempt in {1..20}; do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.25; done
  kill -KILL "$pid" 2>/dev/null || true
  for attempt in {1..20}; do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.25; done
  return 1
}

# The smoke run this script opened, once it's running. Only it is ever stopped.
smoke_pid=
opened=0
evaluated=0
# Every exit: the smoke run and the helper stopped, the captures and the script's own files
# deleted, and Keybumps reopened.
finish() {
  local code=$?
  # A second Ctrl-C doesn't cut the clean-up short.
  trap - EXIT
  trap '' INT TERM HUP
  # An exit before the result is read is the script's own failure, never a capture's.
  if (( ! evaluated && code < 64 )); then code=69; fi
  if (( opened )); then
    # Keybumps was quit first, so an installed copy that appears now is this script's smoke run
    # too: one that hasn't finished is looked for a while longer, then stopped.
    if [[ -z "$smoke_pid" && "$(json_value "$result" complete)" != true ]]; then
      local late_deadline=$(( SECONDS + late_wait ))
      smoke_pid=$(installed_pids | head -1)
      while [[ -z "$smoke_pid" ]] && (( SECONDS < late_deadline )); do
        sleep 0.25
        smoke_pid=$(installed_pids | head -1)
      done
    fi
    stop_pid "$smoke_pid" || print -u2 "the smoke test (pid $smoke_pid) didn't stop"
  fi
  stop_pid "$helper_pid" || print -u2 "the smoke test's window (pid $helper_pid) didn't close"
  [[ -z "$work" ]] || rm -rf -- "$work" 2>/dev/null || true
  # Only once no Keybumps runs, so a smoke run can't save into it again.
  if [[ -z "$(installed_pids)" ]]; then
    rm -rf -- "$captures" 2>/dev/null || print -u2 "couldn't delete the smoke test's captures: $captures"
  elif (( opened )); then
    print -u2 "a Keybumps is still running, so the smoke test's captures are left in $captures"
  fi
  [[ -n "$(installed_pids)" ]] || open "$installed_app" || print -u2 "couldn't reopen Keybumps; open it from /Applications"
  exit $code
}
trap finish EXIT
trap 'exit 130' INT TERM HUP

# Quitting Keybumps by its bundle id is the only Apple event the script sends, as
# build-qa-candidate.sh does on every install.
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

work=$(mktemp -d "${temporary%/}/keybumps-smoke-script.XXXXXX") || { print -u2 "couldn't prepare a folder for the script"; exit 69 }
# Without the window, the smoke test still runs, and its window capture fails as noSmokeWindow.
window_arguments=()
if start_helper; then
  window_arguments=("-$window_option" "$helper_pid")
else
  print -u2 "couldn't show the smoke test's window, so its window capture will fail"
  stop_pid "$helper_pid" || true
  helper_pid=
fi

# Opened through Launch Services, not run from this shell, so macOS checks Screen Recording for
# Keybumps rather than for the terminal that started the script.
opened=1
open -n "$installed_app" --args "-$option" YES "${window_arguments[@]}" || { print -u2 "couldn't open Keybumps"; exit 69 }

# Keybumps was quit above, so the installed copy running now is the smoke run just opened. A
# first launch on a busy Mac can take a while to appear.
deadline=$(( SECONDS + timeout ))
started=$(( SECONDS + start_wait ))
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
    stop_pid "$smoke_pid" || true
    break
  fi
  sleep 0.5
done

evaluated=1
evaluate "$result"
if (( timed_out )); then result_code=3; fi
print "screencast smoke test: exit $result_code"
exit $result_code
