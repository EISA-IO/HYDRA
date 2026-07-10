#!/usr/bin/env bash
# Hydra (macOS) launcher.
#   • If the native app "Hydra.app" is present, open it.
#   • Otherwise build it from the Swift sources in ./mac (needs the Xcode Command
#     Line Tools: xcode-select --install), then open it.
#   • If Swift is unavailable, fall back to a lightweight folder+model picker so
#     you can still launch a Claude session.
# Double-click in Finder. First run may need: chmod +x Hydra-Mac.command
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/Hydra.app"

open_app() { open "$APP"; }

if [ -d "$APP" ]; then
  open_app
  exit 0
fi

if command -v swiftc >/dev/null 2>&1 && [ -d "$HERE/mac" ]; then
  osascript -e 'display notification "Building Hydra (first run)…" with title "Hydra"' >/dev/null 2>&1
  if bash "$HERE/build-mac.sh"; then
    open_app
    exit 0
  fi
  osascript -e 'display alert "Build failed" message "Falling back to the lightweight launcher." as warning' >/dev/null 2>&1
fi

# ---------------- lightweight fallback (no Swift toolchain) ----------------
PROXY_PORT=8787
port_up() { nc -z 127.0.0.1 "$PROXY_PORT" >/dev/null 2>&1; }
ensure_proxy() {
  port_up && return 0
  command -v headroom >/dev/null 2>&1 || { osascript -e 'display alert "Headroom not found" as warning' >/dev/null 2>&1; return 1; }
  osascript -e 'tell application "Terminal" to do script "headroom proxy"' >/dev/null 2>&1
  for _ in $(seq 1 20); do port_up && return 0; sleep 0.5; done
  return 1
}
launch_one() {
  local folder model modelarg mode prefix
  folder=$(osascript -e 'try
      POSIX path of (choose folder with prompt "Pick a folder to launch Claude in")
    on error
      return ""
    end try' 2>/dev/null)
  [ -z "$folder" ] && return 1
  model=$(osascript -e 'set m to choose from list {"Default","claude-fable-5","claude-opus-4-8","claude-sonnet-5","claude-haiku-4-5"} with prompt "Select the model" default items {"Default"}
    if m is false then return "Default"
    return item 1 of m' 2>/dev/null)
  [ -z "$model" ] && model="Default"
  case "$model" in
    fable) model="claude-fable-5" ;;
    opus) model="claude-opus-4-8" ;;
    sonnet|claude-sonnet-4-6) model="claude-sonnet-5" ;;
    haiku|claude-haiku-4-5-20251001) model="claude-haiku-4-5" ;;
  esac
  modelarg=""
  [ "$model" != "Default" ] && modelarg="--model $model "
  mode=$(osascript -e 'button returned of (display dialog "RTK + Caveman compression are on by default. Also route this session through Headroom?" buttons {"No (default)", "Yes, add Headroom"} default button "No (default)")' 2>/dev/null)
  prefix=""
  if [ "$mode" = "Yes, add Headroom" ] && ensure_proxy; then
    prefix="export ANTHROPIC_BASE_URL=http://127.0.0.1:$PROXY_PORT && "
  fi
  osascript <<OSA
tell application "Terminal"
  activate
  set cmdStr to "cd " & quoted form of "$folder" & " && ${prefix}claude ${modelarg}--dangerously-skip-permissions"
  if (count of windows) is 0 then
    do script cmdStr
  else
    tell application "System Events" to keystroke "t" using command down
    delay 0.3
    do script cmdStr in front window
  end if
end tell
OSA
  return 0
}
while true; do
  launch_one || { echo "Cancelled."; break; }
  again=$(osascript -e 'button returned of (display dialog "Open another Claude session in a new tab?" buttons {"Done","New tab"} default button "Done")' 2>/dev/null)
  [ "$again" = "New tab" ] || break
done
