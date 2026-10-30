#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install Saur0n's watcher as this user's login agent (Phase 7 Step 1): writes
#   ~/Library/LaunchAgents/com.saur0n.watch.plist
# — the app in `--watch`, started at login (RunAtLoad) and kept alive — and loads it with
#   launchctl bootstrap gui/$UID <plist>
# so detection runs whether or not anyone opens the window. `--uninstall` boots the agent out and removes the plist.
# This script touches that one label and nothing else: no other job is loaded, booted out or edited.
#
# Usage: bash scripts/install-agent.sh [--uninstall | --write-only]
#   --write-only   writes the plist and loads nothing: a by-hand look, and how the script's own shape is checked.
#
# Environment (each has its default):
#   SAUR0N_APP=<bundle>     the app to run            (.build/Saur0n.app, from scripts/make-app.sh)
#   SAUR0N_AGENT_DIR=<dir>  where the plist goes      (~/Library/LaunchAgents)
#   SAUR0N_LOG_DIR=<dir>    the agent's stdout/stderr (~/Library/Logs/Saur0n)
# A copy dragged to /Applications is the one to install: SAUR0N_APP=$HOME/Applications/Saur0n.app
set -euo pipefail
cd "$(dirname "$0")/.."

label=com.saur0n.watch
agent_dir=${SAUR0N_AGENT_DIR:-$HOME/Library/LaunchAgents}
log_dir=${SAUR0N_LOG_DIR:-$HOME/Library/Logs/Saur0n}
app=${SAUR0N_APP:-$PWD/.build/Saur0n.app}
plist=$agent_dir/$label.plist
mode=install
case ${1:-} in
    --uninstall) mode=uninstall ;;
    --write-only) mode=write ;;
    "") ;;
    *) echo "usage: bash scripts/install-agent.sh [--uninstall | --write-only]" >&2; exit 2 ;;
esac

uid=$(id -u)
bootout() { launchctl bootout "gui/$uid/$label" 2>/dev/null || true; }

if [[ $mode == uninstall ]]; then
    bootout
    rm -f "$plist"
    echo "uninstalled: $label booted out, $plist removed"
    exit 0
fi

exe=$app/Contents/MacOS/Saur0nApp
[[ -x $exe ]] || { echo "install-agent: no app at $app — run 'bash scripts/make-app.sh' first, or set SAUR0N_APP" >&2; exit 1; }
mkdir -p "$agent_dir" "$log_dir"
cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>$exe</string>
    <string>--watch</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$log_dir/watch.out.log</string>
  <key>StandardErrorPath</key><string>$log_dir/watch.err.log</string>
</dict></plist>
PLIST
plutil -lint "$plist" >/dev/null
if [[ $mode == write ]]; then
    echo "wrote $plist (not loaded: --write-only)"
    exit 0
fi
bootout                      # a running copy is replaced, never doubled
launchctl bootstrap "gui/$uid" "$plist"
echo "loaded $label from $plist — $exe --watch, log in $log_dir"
echo "uninstall: bash scripts/install-agent.sh --uninstall"
