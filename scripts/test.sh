#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Run the Swift Testing suite. Extra arguments pass through (e.g. --filter <name>).
#
# Command Line Tools ship Swift Testing's macro plugin outside the compiler's
# default search path, so plain `swift test` fails with "plugin for module
# 'TestingMacros' not found". Point the compiler at it unless an Xcode
# toolchain is selected (Xcode finds it on its own).
set -euo pipefail
cd "$(dirname "$0")/.."

args=()
if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
    args+=(-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing)
fi

exec swift test "${args[@]}" "$@"
