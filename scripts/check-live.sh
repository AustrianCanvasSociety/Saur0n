#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Live checks: compare what Saur0n shows with what the machine itself reports.
# Usage: bash scripts/check-live.sh <core-types|cpu-total|readable-names|vm-cores|repo-groups|exited-cpu|overhead|disk-total|disk-load|network-total|network-load>
#        (network-load: SAUR0N_NET_URL=<url> downloads a file from a host instead of a local server)
#        bash scripts/check-live.sh <core-types|cpu-total|readable-names|vm-cores|repo-groups|disk-total|disk-load|network-total|network-load> --window
#            (read Saur0n.app's window, not the CLI; for repo-groups, REPO_GROUPS_MEMBERS_CMD=<command> starts
#            the swarm wave itself, after the set-up and before the loads)
#        bash scripts/check-live.sh overhead   (OVERHEAD_MEMBERS_CMD=<command> starts a swarm wave once the app is up)
#        bash scripts/check-live.sh layout --window   (window only: the table fits, nothing covers the last row,
#            Collapse all / Expand all, no legend on the Cores row, the Memory header — Phase 4 Step 4)
#        bash scripts/check-live.sh <kill|dependants> --window   (window only: Quit, Force Quit, Pause and Resume on
#            the check's own children; what the confirmation sheet lists — Phase 5 Step 5)
#        bash scripts/check-live.sh load [--window]   (load averages against uptime, user + system against the
#            total, every one of a known set of starts counted, on any machine load — Phase 6 Step 2)
#        bash scripts/check-live.sh snapshot   (a storm's warning snapshot read back with `saur0n snapshot <time>`
#            after the storm, the window's log in a scratch folder — Phase 6 Step 7)
#        bash scripts/check-live.sh orphans   (a bounded storm's copies under launchd shown with this check's session
#            and repo, marked orphaned; launchd's own agents left alone — Phase 6 Step 8)
#        bash scripts/check-live.sh dock --window   (the Dock's "!" badge while a storm's warning lasts, read from
#            the Dock; the icon's step up under one busy loop per CPU and back after, read from the app's log —
#            Phase 6 Step 9)
#        bash scripts/check-live.sh warning-safety --window   (a bounded storm under a stand-in terminal session, in
#            an isolated build of the app with its own settings and snapshot folder: the bar's Pause stops the
#            workers and nothing of the session, Stop… lists exactly the workers and ends them, the session's root,
#            filter and shell keep running; generated load capped at two cores, never a real Apple service)
#        bash scripts/check-live.sh watcher   (the app installed as a test-scoped launchd agent, com.saur0n.watch.test,
#            in --watch: a storm is detected with no window and its would-have-acted entry lands in the agent's own
#            snapshot log — Phase 7 Step 1; the real com.saur0n.watch is never touched)
# Exit: 0 ok · 1 check failed · 2 usage · 3 check not yet implemented
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    echo "usage: bash scripts/check-live.sh <core-types|cpu-total|readable-names|vm-cores|repo-groups|exited-cpu|overhead|disk-total|disk-load|network-total|network-load|load|copies|snapshot|orphans|watcher>" >&2
    echo "       bash scripts/check-live.sh <core-types|cpu-total|readable-names|vm-cores|repo-groups|layout|disk-total|disk-load|network-total|network-load|kill|dependants|load|copies|warn|runaway|runaway-join|dock|warning-safety> --window" >&2
    exit 2
}
check=${1:-}
window=0
case $#:${2:-} in
    1:) ;;
    2:--window) [[ $check != exited-cpu ]] || usage; window=1 ;;
    *) usage ;;
esac

build() { swift build -q >/dev/null; }

# --- The window source: Saur0n.app read through accessibility (scripts/read-window.swift) ---

# The app this check launched and the user's saved Cores-row state ("absent", 0 or 1). Globals for the
# EXIT trap, as in cpu-total. Only the recorded pid is ever stopped.
app_pid="" saved_cores=""
app_domain=app.saur0n.monitor
app_bundle=.build/Saur0n.app    # warning-safety builds and launches its own (SAUR0N_APP_DIR, SAUR0N_BUNDLE_ID)

# Builds the app bundle (make-app.sh, honouring its SAUR0N_* overrides) and the reader, outside any timed window.
build_window() {
    local out
    out=$(bash scripts/make-app.sh 2>&1) || { echo "$out" | tail -20; echo "$check: FAIL — cannot build Saur0n.app"; return 1; }
    out=$(swiftc -O scripts/read-window.swift -o .build/read-window 2>&1) ||
        { echo "$out" | tail -20; echo "$check: FAIL — cannot build the window reader"; return 1; }
}

# The reader against the launched app; exit 3 means this terminal lacks the Accessibility grant.
read_window() {
    local rc=0
    .build/read-window "$app_pid" "$@" || rc=$?
    [[ $rc -ne 3 ]] || echo "$check: FAIL — grant this terminal app Accessibility in System Settings, then re-run" >&2
    return "$rc"
}

# The user's saved open graph (Backlog window-graph-area-space): "absent" or its name, read before the first launch
# and put back by stop_window, since a check opens graphs and the app remembers the last one.
saved_graph=""

restore_graph_state() {
    case $saved_graph in
        "") ;;
        absent) defaults delete "$app_domain" openGraph >/dev/null 2>&1 || true ;;
        *) defaults write "$app_domain" openGraph -string "$saved_graph" ;;
    esac
    saved_graph=""
}

# Opens graph $1 (cpu, memory, disk-network or none) in the graph row; the reader waits until it shows.
open_graph() { read_window open-graph "$1" >/dev/null || { echo "$check: FAIL — cannot open the $1 graph"; return 1; }; }

# Starts the bundle's executable (it runs as Saur0n.app) and waits for its window.
launch_app() {
    [[ -n $saved_graph ]] || saved_graph=$(defaults read "$app_domain" openGraph 2>/dev/null || echo absent)
    save_theme_state
    "$app_bundle/Contents/MacOS/Saur0nApp" ${app_args[@]+"${app_args[@]}"} >/dev/null 2>&1 &
    app_pid=$!
    read_window state >/dev/null || { echo "$check: FAIL — Saur0n.app (pid $app_pid) showed no window"; return 1; }
}

quit_app() {
    [[ -n $app_pid ]] || return 0
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    app_pid=""    # reaped: its pid may be reused
}

# The Cores row's open state as the window shows it: true or false.
cores_open() { read_window state | jq -r .coresOpen; }

# Presses the Cores row and waits up to 2 s for the window to show $1 (true / false).
press_cores_until() {
    local tries=0
    read_window press-cores
    until [[ $(cores_open) == "$1" ]]; do
        ((++tries <= 20)) || { echo "$check: FAIL — the Cores row did not turn coresOpen=$1"; return 1; }
        sleep 0.1
    done
}

save_cores_state() { saved_cores=$(defaults read "$app_domain" coresOpen 2>/dev/null || echo absent); }

restore_cores_state() {
    case $saved_cores in
        "") ;;
        absent) defaults delete "$app_domain" coresOpen >/dev/null 2>&1 || true ;;
        1) defaults write "$app_domain" coresOpen -bool true ;;
        *) defaults write "$app_domain" coresOpen -bool false ;;
    esac
    saved_cores=""
}

# The user's saved column widths (Backlog resizable-columns): "absent", or the data as hex, for `defaults write -data`.
saved_widths=""

save_widths_state() {
    saved_widths=$(defaults export "$app_domain" - 2>/dev/null | plutil -extract columnWidths raw -o - - 2>/dev/null |
        base64 -d | xxd -p | tr -d '\n') || true    # no key: the extract fails, and pipefail with it
    [[ -n $saved_widths ]] || saved_widths=absent
}

restore_widths_state() {
    case $saved_widths in
        "") ;;
        absent) defaults delete "$app_domain" columnWidths >/dev/null 2>&1 || true ;;
        *) defaults write "$app_domain" columnWidths -data "$saved_widths" ;;
    esac
    saved_widths=""
}

# The user's saved theme, appearance and the Settings window's frame (Backlog window-theme): "absent" or the value,
# read before the first launch and put back by stop_window, since the layout check picks themes and appearances in
# Settings and relaunches in each.
saved_theme="" saved_appearance="" saved_settings_frame=""
settings_frame_key="NSWindow Frame com_apple_SwiftUI_Settings_window"

save_theme_state() {
    [[ -n $saved_theme ]] || saved_theme=$(defaults read "$app_domain" theme 2>/dev/null || echo absent)
    [[ -n $saved_appearance ]] || saved_appearance=$(defaults read "$app_domain" appearance 2>/dev/null || echo absent)
    [[ -n $saved_settings_frame ]] ||
        saved_settings_frame=$(defaults read "$app_domain" "$settings_frame_key" 2>/dev/null || echo absent)
}

restore_theme_state() {
    case $saved_theme in
        "") ;;
        absent) defaults delete "$app_domain" theme >/dev/null 2>&1 || true ;;
        *) defaults write "$app_domain" theme -string "$saved_theme" ;;
    esac
    case $saved_appearance in
        "") ;;
        absent) defaults delete "$app_domain" appearance >/dev/null 2>&1 || true ;;
        *) defaults write "$app_domain" appearance -string "$saved_appearance" ;;
    esac
    case $saved_settings_frame in
        "") ;;
        absent) defaults delete "$app_domain" "$settings_frame_key" >/dev/null 2>&1 || true ;;
        *) defaults write "$app_domain" "$settings_frame_key" -string "$saved_settings_frame" ;;
    esac
    saved_theme="" saved_appearance="" saved_settings_frame=""
}

# The window's light or dark under appearance $1 (system, light, dark): System follows the Mac's.
appearance_shown() {
    case $1 in
        light | dark) echo "$1" ;;
        *) [[ $(defaults read -g AppleInterfaceStyle 2>/dev/null) == Dark ]] && echo dark || echo light ;;
    esac
}

# The theme the window should show with $1 chosen: Two-colour while the Mac's Increase contrast is on and the user's
# Settings box (on by default) follows it, else $1.
theme_shown() {
    local contrast follows
    contrast=$(defaults read com.apple.universalaccess increaseContrast 2>/dev/null || echo 0)
    follows=$(defaults read "$app_domain" highContrastFollowsMac 2>/dev/null || echo 1)
    if [[ $contrast == 1 && $follows == 1 ]]; then echo two-colour; else echo "$1"; fi
}

stop_window() { quit_app; restore_cores_state; restore_graph_state; restore_widths_state; restore_theme_state; }

# Builds and launches the app (outside any timed window) and waits until its table shows a refresh whose
# processes started at least $1 refreshes after launch, so processes started before the call are in it.
# Polled through `state`, which does not pause: a paused read each half second would hold every refresh.
window_up() {
    build_window || return 1
    launch_app || return 1
    wait_for_rows "${1:-2}"
}

# Waits until the launched app's table shows its $1th refresh.
wait_for_rows() {
    local tries=0
    until [[ $(read_window state 2>/dev/null | jq '.refresh // 0') -ge ${1:-2} ]]; do
        ((++tries <= 30)) || { echo "$check: FAIL — Saur0n.app showed no process table within 15 s"; return 1; }
        sleep 0.5
    done
}

# Every process row the window shows, as the CLI's --json `processes` (plus `group`), with the total; or
# with --window unset, the CLI's own --json over a $1-second sample. Fields the window lacks (uid, source,
# repo root, session kind and id) are absent from the window's rows.
process_json() {
    if ((window)); then read_window rows; else saur0n --json --interval "$1"; fi
}

# The window's core types as the CLI's --json shape (plus `columns`), in the global `window_json`. A fresh
# defaults key first: the Cores row must start closed; pressed, it opens; after a relaunch it is still open.
# The caller's traps stop the app and restore the user's key.
window_json=""
window_core_types() {
    build_window || return 1
    save_cores_state
    saved_graph=$(defaults read "$app_domain" openGraph 2>/dev/null || echo absent)
    defaults delete "$app_domain" coresOpen >/dev/null 2>&1 || true
    defaults delete "$app_domain" openGraph >/dev/null 2>&1 || true
    launch_app || return 1
    local windows
    windows=$(read_window state | jq .windows)
    [[ $windows -eq 1 ]] || { echo "core-types: FAIL — Saur0n.app opened $windows windows, want 1"; return 1; }
    # A first launch opens no graph (Backlog window-graph-area-space); the CPU cell opens the per-type graphs.
    [[ $(read_window state | jq -r .openGraph) == none ]] || { echo "core-types: FAIL — a graph is open on a first launch"; return 1; }
    open_graph cpu || return 1
    [[ $(cores_open) == false ]] || { echo "core-types: FAIL — the Cores row is open on a first launch"; return 1; }
    press_cores_until true || return 1
    wait_for_rows 1 || return 1    # every figure reads "—" until the first reading
    window_json=$(read_window json) || { echo "core-types: FAIL — cannot read the window's cores"; return 1; }
    sleep 1    # let the app's defaults write land before it is stopped
    quit_app
    launch_app || return 1
    [[ $(read_window state | jq -r .openGraph) == cpu ]] || { echo "core-types: FAIL — the CPU graph did not stay open across a relaunch"; return 1; }
    [[ $(cores_open) == true ]] || { echo "core-types: FAIL — the Cores row did not stay open across a relaunch"; return 1; }
}

# The built CLI; each check builds once first, outside any timed window.
saur0n() { .build/debug/saur0n "$@"; }

saur0n_json() {
    build
    saur0n --json
}

# The readableName of the first process in JSON $1 matching jq filter $2 (with $pid / $name from
# $3 / $4), else "absent".
readable_of() {
    jq -r --argjson pid "${3:-0}" --arg name "${4:-}" "[.processes[] | select($2) | .readableName] | first // \"absent\"" <<<"$1"
}

# IO-registry cluster-type letter for each cpuN, as "N LETTER" lines.
registry_letters() {
    ioreg -p IODeviceTree -n cpus -r -d 2 -l |
        awk '/^[ |+-]*o cpu[0-9]+@/{ match($0, /cpu[0-9]+/); n = substr($0, RSTART + 3, RLENGTH - 3) }
             /"cluster-type" = <"/ && n != "" { match($0, /<"[A-Z]">/); print n, substr($0, RSTART + 2, 1); n = "" }'
}

check_core_types() {
    local json levels i name count want_name want_count letters
    if ((window)); then
        trap 'stop_window; trap - RETURN EXIT INT TERM HUP' RETURN EXIT
        trap 'echo "core-types: interrupted"; exit 130' INT TERM HUP
        window_core_types || return 1
        json=$window_json
        # Up to six strips a column, each core type in its own columns.
        local columns
        columns=$(jq -r '.coreTypes[] | select(.columns != ((.cpus | length) as $n | [range(0; $n; 6) | [6, $n - .] | min]))
                         | "\(.name) columns \(.columns)"' <<<"$json")
        [[ -z $columns ]] || { echo "core-types: FAIL — strips not in columns of up to 6: $columns"; return 1; }
    else
        json=$(saur0n_json)
    fi
    # A machine without perf levels reads 0 or has no such key ("unknown oid"), as Saur0n treats
    # it; any other failed read is not.
    if ! levels=$(sysctl -n hw.nperflevels 2>&1); then
        [[ $levels == *"unknown oid"* ]] || { echo "core-types: FAIL — cannot read hw.nperflevels: $levels"; return 1; }
        levels=0
    fi
    if [[ $levels -eq 0 ]]; then
        count=$(jq '.coreTypes | length' <<<"$json")
        [[ $count -eq 1 ]] || { echo "core-types: FAIL — no perf levels, but Saur0n shows $count groups"; return 1; }
        echo "core-types: ok (single level)"; return 0
    fi

    count=$(jq '.coreTypes | length' <<<"$json")
    [[ $count -eq $levels ]] ||
        { echo "core-types: FAIL — Saur0n shows $count groups, sysctl reports $levels levels"; return 1; }

    letters=$(registry_letters)
    # The registry's letter for each core type (CLAUDE.md § Platform facts): E = Efficiency,
    # M = Performance, P = Super on chips that have M (M5), else Performance.
    local p_name=Performance
    awk '$2 == "M" { found = 1 } END { exit !found }' <<<"$letters" && p_name=Super
    local seen_letters=""
    for ((i = 0; i < levels; i++)); do
        want_name=$(sysctl -n "hw.perflevel$i.name")
        want_count=$(sysctl -n "hw.perflevel$i.logicalcpu_max")
        name=$(jq -r ".coreTypes[] | select(.level == $i) | .name" <<<"$json")
        count=$(jq ".coreTypes[] | select(.level == $i) | .cpus | length" <<<"$json")
        [[ $name == "$want_name" ]] || { echo "core-types: FAIL — level $i named '$name', sysctl says '$want_name'"; return 1; }
        [[ $count -eq $want_count ]] || { echo "core-types: FAIL — $name has $count CPUs, sysctl says $want_count"; return 1; }

        # Every CPU in the group carries the same registry letter, no other group uses it, and the
        # letter is the one for the group's name. A CPU with no registry entry reads as "?".
        local group_letters letter_name
        group_letters=$(jq -r ".coreTypes[] | select(.level == $i) | .cpus[]" <<<"$json" |
            awk 'NR == FNR { l[$1] = $2; next } { print ($1 in l) ? l[$1] : "?" }' <(echo "$letters") - | sort -u)
        [[ $(wc -l <<<"$group_letters") -eq 1 && -n $group_letters ]] ||
            { echo "core-types: FAIL — $name CPUs carry registry letters: $(tr '\n' ' ' <<<"$group_letters")"; return 1; }
        [[ $seen_letters != *"$group_letters"* ]] ||
            { echo "core-types: FAIL — registry letter $group_letters spans two groups"; return 1; }
        seen_letters+="$group_letters"
        case $group_letters in E) letter_name=Efficiency ;; M) letter_name=Performance ;; P) letter_name=$p_name ;; *) letter_name="?" ;; esac
        [[ $letter_name == "$name" ]] ||
            { echo "core-types: FAIL — $name CPUs carry registry letter $group_letters, which is $letter_name"; return 1; }
    done

    local all
    all=$(jq '[.coreTypes[].cpus[]] | (length == (unique | length)) and (length == (sort | last) + 1)' <<<"$json")
    [[ $all == true ]] || { echo "core-types: FAIL — CPU indices are not each listed exactly once"; return 1; }

    if ((window)); then
        echo "core-types: ok (window: $(jq -r '[.coreTypes[] | "\(.name) \(.cpus | length) in \(.columns | length) column(s)"] | join(", ")' <<<"$json"); one window, Cores row closed at first launch, open after a relaunch)"
    else
        echo "core-types: ok"
    fi
}

# Three checks over one 5-second window (2 s drifted up to 4 points on a busy machine):
# - Saur0n's total within 5 points of top's "CPU usage" user + sys. top's first sample covers no
#   window, so Saur0n starts the moment top prints it (when top's timed window opens), and only
#   top's last line counts.
# - The per-process shares sum to no more than 5 points above Saur0n's total. Processes that exit
#   mid-window are in the total but in no row, so the sum may fall short (the gap is printed); it
#   may not overshoot (double counting, a unit error).
# - Calibration: one busy `yes` reads the same share in Saur0n (libproc) as its `ps` CPU-time delta
#   across Saur0n's run, within 0.5 points. Catches the undercounts the sum cannot (task-info times
#   left in Mach units read about 41x low). Not 100 / CPU count: a saturated Mac gives `yes` less.
# Then, on the same output, the shape checks below (per_core_problem, root_rows_problem).
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# Per-core values in JSON $1, against CPU count $2: one value per CPU, each 0–100, each group's
# average the mean of its CPUs (within 0.1, rounding), and the mean of all CPUs within 1 point of
# the total (the total weighs CPUs by ticks elapsed, which on a live Mac are near equal). Prints
# the first problem, or nothing.
per_core_problem() {
    jq -r --argjson n "$2" '[.coreTypes[].busyPercent[]] as $all
        | if ($all | length) != $n then "\($all | length) per-core values for \($n) CPUs"
          elif any($all[]; . < 0 or . > 100) then "a per-core value outside 0–100"
          elif any(.coreTypes[]; ((.busyPercent | add / length) - .averageBusyPercent | fabs) > 0.1)
            then "a group average is not the mean of its CPUs"
          elif (($all | add / length) - .totalBusyPercent | fabs) > 1 then "per-core mean \($all | add / length) vs total \(.totalBusyPercent)"
          else empty end' <<<"$1"
}

# Root's processes in JSON $1, whose task info a normal user cannot read: rows from `ps` with
# memory, at least one with CPU over the window, and kernel_task from `top`. Prints the first
# problem, or nothing.
root_rows_problem() {
    jq -r '[.processes[] | select(.uid == 0 and .pid != 0)] as $root
        | [.processes[] | select(.pid == 0)] as $kernel
        | if ($root | length) == 0 then "no root processes listed"
          elif any($root[]; .source != "ps") then "a root row not from ps: \(first($root[] | select(.source != "ps")) | .name)"
          elif ($root | map(select(.residentBytes > 0)) | length) == 0 then "no root row has memory"
          elif ($root | map(select(.cpuPercent > 0)) | length) == 0 then "no root row has CPU over the window"
          elif ($kernel | length) != 1 or $kernel[0].source != "top" or $kernel[0].residentBytes == 0
            then "kernel_task missing or not from top with memory"
          else empty end' <<<"$1"
}

# `ps` cumulative CPU time of one pid, in seconds.
ps_seconds() {
    ps -o time= -p "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%.2f", s }'
}

# cpu-total's `yes`, `top` and top's output file. Globals, not locals: after a `set -e` abort the
# EXIT trap runs once the function's locals are gone.
yes_pid="" top_pid="" top_out=""

# Stops `yes` and `top` (either may be gone already) and removes top's output.
stop_cpu_total() {
    local pid
    for pid in $yes_pid $top_pid; do kill "$pid" 2>/dev/null || true; done
    [[ -z $top_out ]] || rm -f "$top_out"
}

# Starts `top` over one $1-second window into $top_out and returns once it prints its first sample (which
# covers no window: top's timed window opens then).
start_top() {
    top_out=$(mktemp)
    top -l 2 -n 0 -s "$1" >"$top_out" &
    top_pid=$!
    local tries=0
    until grep -q '^CPU usage:' "$top_out"; do
        ((++tries <= 250)) || { echo "cpu-total: FAIL — top printed no first sample within 5 s"; return 1; }
        sleep 0.02
    done
}

# top's busy share (user + sys) over its window, from its second "CPU usage" line.
top_busy() {
    local busy
    busy=$(awk '/^CPU usage:/ { u = $3; s = $5; n++ }
                END { if (n == 2) { sub(/%/, "", u); sub(/%/, "", s); printf "%.1f", u + s } }' "$top_out")
    [[ -n $busy ]] || { echo "cpu-total: FAIL — top printed no second CPU usage line" >&2; return 1; }
    echo "$busy"
}

# The window's total against top over one 5-second window: the window refreshes each second, so its total
# is read once a second across top's window (starting a second in, when the first refresh inside it lands)
# and the mean compared, within 5 points. Then per-core values with the Cores row opened (per_core_problem).
# Then the process table:
# - One refresh's groups plus its unattributed line against its total (`snapshot`, read against the refresh
#   counter), within 1 point plus 0.05 per figure for the one decimal the window shows.
# - Calibration: the busy `yes` reads in the window as its `ps` CPU-time share across the read, within 0.5.
# - Root's processes (user root): some with memory, one with CPU; kernel_task with memory and its age.
# The rows-only sum and the rows' sources stay CLI-only (the window shows open groups' rows and no source).
check_cpu_total_window() {
    local seconds=5 totals window_total top_total diff json problem ncpu
    local t0 t1 cpu0 cpu1 ps_share yes_share snapshot groups unattributed total balance slack
    ncpu=$(sysctl -n hw.ncpu)
    trap 'stop_cpu_total; stop_window; trap - RETURN EXIT INT TERM HUP' RETURN EXIT
    trap 'echo "cpu-total: interrupted"; exit 130' INT TERM HUP
    build_window || return 1
    save_cores_state
    yes >/dev/null &
    yes_pid=$!
    launch_app || return 1
    open_graph cpu || return 1
    [[ $(cores_open) == true ]] || press_cores_until true || return 1
    sleep 2    # the first load needs two tick reads
    start_top "$seconds" || return 1
    sleep 1
    totals=$(read_window totals "$seconds") || { echo "cpu-total: FAIL — cannot read the window's total"; return 1; }
    wait "$top_pid"
    top_pid=""
    window_total=$(jq '.totals | add / length * 10 | round / 10' <<<"$totals")
    top_total=$(top_busy) || return 1
    diff=$(awk -v a="$window_total" -v b="$top_total" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.1f", d }')
    local summary="window $window_total% (mean of $(jq -c .totals <<<"$totals")), top $top_total%, diff $diff"
    awk -v d="$diff" 'BEGIN { exit !(d <= 5.0) }' || { echo "cpu-total: FAIL — window total off top by more than 5.0: $summary"; return 1; }
    json=$(read_window json) || { echo "cpu-total: FAIL — cannot read the window's cores"; return 1; }
    problem=$(per_core_problem "$json" "$ncpu")
    [[ -z $problem ]] || { echo "cpu-total: FAIL — per-core load: $problem"; return 1; }
    summary+="; $ncpu per-core values agree with the total"

    snapshot=$(read_window snapshot) || { echo "cpu-total: FAIL — cannot read one refresh of the process table"; return 1; }
    groups=$(jq '[.repoGroups[].cpuPercent] | add' <<<"$snapshot")
    unattributed=$(jq '.unattributedCpuPercent' <<<"$snapshot")
    total=$(jq '.totalBusyPercent' <<<"$snapshot")
    slack=$(jq '1 + 0.05 * (.repoGroups | length + 1)' <<<"$snapshot")
    balance=$(awk -v g="$groups" -v u="$unattributed" -v t="$total" 'BEGIN { printf "%.2f", g + u - t }')
    summary+="; refresh $(jq .refresh <<<"$snapshot"): groups $groups% + unattributed $unattributed% off the total $total% by $balance (within $slack)"
    awk -v u="$unattributed" -v b="$balance" -v s="$slack" 'BEGIN { if (b < 0) b = -b; exit !(u + 0 == u && b <= s) }' ||
        { echo "cpu-total: FAIL — groups plus unattributed off the total: $summary"; return 1; }

    cpu0=$(ps_seconds "$yes_pid"); t0=$(now)
    json=$(read_window rows) || { echo "cpu-total: FAIL — cannot read the window's rows"; return 1; }
    cpu1=$(ps_seconds "$yes_pid"); t1=$(now)
    ps_share=$(awk -v c0="$cpu0" -v c1="$cpu1" -v t0="$t0" -v t1="$t1" -v n="$ncpu" \
        'BEGIN { printf "%.2f", 100 * (c1 - c0) / ((t1 - t0) * n) }')
    yes_share=$(jq --argjson pid "$yes_pid" '[.processes[] | select(.pid == $pid) | .cpuPercent] | first // empty' <<<"$json")
    [[ -n $yes_share ]] || { echo "cpu-total: FAIL — the calibration yes (pid $yes_pid) is not in the window"; return 1; }
    summary+="; calibration window $yes_share%, ps $ps_share%"
    awk -v y="$yes_share" -v p="$ps_share" 'BEGIN { d = y - p; if (d < 0) d = -d; exit !(d <= 0.5) }' ||
        { echo "cpu-total: FAIL — calibration process off its ps reading by more than 0.5: $summary"; return 1; }
    problem=$(jq -r '[.processes[] | select(.user == "root" and .pid != 0)] as $root
        | [.processes[] | select(.pid == 0)] as $kernel
        | if ($root | length) == 0 then "no root processes listed"
          elif ($root | map(select(.residentBytes > 0)) | length) == 0 then "no root row has memory"
          elif ($root | map(select(.cpuPercent > 0)) | length) == 0 then "no root row has CPU"
          elif ($kernel | length) != 1 or $kernel[0].residentBytes == 0 or (($kernel[0].readableName // "") | test("read [0-9]+ s ago$") | not)
            then "kernel_task missing, without memory or without its age"
          else empty end' <<<"$json")
    [[ -z $problem ]] || { echo "cpu-total: FAIL — root processes: $problem"; return 1; }
    summary+="; $(jq '[.processes[] | select(.user == "root")] | length' <<<"$json") root rows, kernel_task '$(jq -r '.processes[] | select(.pid == 0) | .readableName' <<<"$json")'"
    echo "cpu-total: ok (window: $summary; rows-only sum and row sources not shown in the window)"
}

check_cpu_total() {
    local window=5 json saur0n_total top_busy diff sum gap ncpu
    local t0 t1 cpu0 cpu1 ps_share yes_share
    build    # outside the timed window
    ncpu=$(sysctl -n hw.ncpu)
    # Every exit path: return, or a `set -e` abort. Cleared in the trap string itself — bash
    # restores a RETURN trap that a function called from it clears. Ctrl-C says so, instead of
    # failing on top's cut-short output, and exits through the EXIT trap's cleanup.
    trap 'stop_cpu_total; trap - RETURN EXIT INT' RETURN EXIT
    trap 'echo "cpu-total: interrupted"; exit 130' INT
    yes >/dev/null &
    yes_pid=$!
    start_top "$window" || return 1
    cpu0=$(ps_seconds "$yes_pid"); t0=$(now)
    json=$(saur0n --json --interval "$window")
    cpu1=$(ps_seconds "$yes_pid"); t1=$(now)
    wait "$top_pid"
    top_pid=""    # reaped: its pid may be reused

    saur0n_total=$(jq '.totalBusyPercent' <<<"$json")
    top_busy=$(top_busy) || return 1
    diff=$(awk -v a="$saur0n_total" -v b="$top_busy" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.1f", d }')
    sum=$(jq '[.processes[].cpuPercent] | add * 10 | round / 10' <<<"$json")
    gap=$(awk -v t="$saur0n_total" -v s="$sum" 'BEGIN { printf "%.1f", t - s }')
    # Groups (own + exited-children CPU) plus the unattributed line against the total, both ways.
    local groups unattributed balance
    groups=$(jq '[.repoGroups[] | .cpuPercent + .exitedChildrenCpuPercent] | add * 100 | round / 100' <<<"$json")
    unattributed=$(jq '.unattributedCpuPercent' <<<"$json")
    balance=$(awk -v g="$groups" -v u="$unattributed" -v t="$saur0n_total" 'BEGIN { printf "%.2f", g + u - t }')
    ps_share=$(awk -v c0="$cpu0" -v c1="$cpu1" -v t0="$t0" -v t1="$t1" -v n="$ncpu" \
        'BEGIN { printf "%.2f", 100 * (c1 - c0) / ((t1 - t0) * n) }')
    yes_share=$(jq --argjson pid "$yes_pid" '[.processes[] | select(.pid == $pid) | .cpuPercent] | first // empty' <<<"$json")
    [[ -n $yes_share ]] || { echo "cpu-total: FAIL — the calibration yes (pid $yes_pid) is not in Saur0n's process list"; return 1; }

    local summary="saur0n $saur0n_total%, top $top_busy%, diff $diff; rows $sum% (gap $gap%), groups $groups% + unattributed $unattributed% off the total by $balance; calibration saur0n $yes_share%, ps $ps_share%"
    if ! awk -v d="$diff" 'BEGIN { exit !(d <= 5.0) }'; then
        echo "cpu-total: FAIL — total off top by more than 5.0: $summary"; return 1
    elif ! awk -v u="$unattributed" -v b="$balance" 'BEGIN { if (b < 0) b = -b; exit !(u + 0 == u && b <= 1.0) }'; then
        echo "cpu-total: FAIL — groups plus unattributed off the total by more than 1.0: $summary"; return 1
    elif ! awk -v y="$yes_share" -v p="$ps_share" 'BEGIN { d = y - p; if (d < 0) d = -d; exit !(d <= 0.5) }'; then
        echo "cpu-total: FAIL — calibration process off its ps reading by more than 0.5: $summary"; return 1
    fi
    local problem
    problem=$(per_core_problem "$json" "$ncpu")
    [[ -z $problem ]] || { echo "cpu-total: FAIL — per-core load: $problem"; return 1; }
    problem=$(root_rows_problem "$json")
    [[ -z $problem ]] || { echo "cpu-total: FAIL — root processes: $problem"; return 1; }
    summary+="; $ncpu per-core values agree with the total; $(jq '[.processes[] | select(.uid == 0)] | length' <<<"$json") root rows from ps and top"
    echo "cpu-total: ok ($summary)"
}

# readable-names' stand-in test processes, the name each must read, and their folder. Globals for
# the EXIT trap, as in cpu-total.
probe_pids=() probe_wants=() probe_dir=""

stop_readable_names() {
    local pid
    for pid in ${probe_pids[@]+"${probe_pids[@]}"}; do kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null || true; done
    [[ -z $probe_dir ]] || rm -rf "$probe_dir"
}

# An idle C program, built once at $1 and copied to each path after it. A copied system binary
# would not do: macOS kills a copied /bin/sleep on launch; a copy of our own build runs.
stand_ins() {
    local built=$1 exe; shift
    printf '#include <unistd.h>\nint main(void) { for (;;) pause(); }\n' | cc -x c -o "$built" - ||
        { echo "readable-names: FAIL — cc could not build a stand-in"; return 1; }
    for exe in "$@"; do mkdir -p "$(dirname "$exe")" && cp "$built" "$exe" || return 1; done
}

# Start "$2…" in the background; Saur0n must show it as $1.
launch() {
    local want=$1; shift
    "$@" &
    probe_pids+=($!) probe_wants+=("$want")
}

# One process per test launch shape the readable-names claim names — Rust, Go, Swift, bun,
# node:test, vitest: idle programs at each tool's path, started with its argv and environment;
# pytest: the real python3.
check_readable_names() {
    local json name i
    build
    trap 'stop_readable_names; trap - RETURN EXIT' RETURN EXIT
    probe_dir=$(mktemp -d)
    local rust=$probe_dir/target/debug/deps/probe_test-0123456789abcdef
    # No CARGO_PKG_NAME: the crate name is the folder that holds target/.
    local rust_bare=$probe_dir/bare-crate/target/debug/deps/probe_test-0123456789abcdef
    local go=$probe_dir/go-build123/b001/probe.test
    local helper=$probe_dir/bin/swiftpm-testing-helper bun=$probe_dir/bin/bun node=$probe_dir/bin/node
    local xctest=$probe_dir/ProbePkg/.build/debug/ProbePkgPackageTests.xctest/Contents/MacOS/ProbePkgPackageTests
    # Impostors: system names outside the system folders must get no system description.
    local fake_kernel=$probe_dir/bin/kernel_task fake_trustd=$probe_dir/bin/trustd
    stand_ins "$probe_dir/stand-in" "$rust" "$rust_bare" "$go" "$helper" "$bun" "$node" "$fake_kernel" "$fake_trustd" || return 1
    launch absent "$fake_kernel"
    launch absent "$fake_trustd"
    launch "test: probe_test · probe-crate" env CARGO_PKG_NAME=probe-crate "$rust"
    launch "test: probe_test · bare-crate" env -u CARGO_PKG_NAME "$rust_bare"
    launch "test: probe" "$go"
    launch "test: ProbePkgPackageTests · ProbePkg" "$helper" --test-bundle-path "$xctest"
    launch "test: bun" "$bun" test
    # node:test child as Node 22 starts it: no --test-* flags, the runner's NODE_TEST_CONTEXT set.
    launch "test: probe.test.mjs" env NODE_TEST_CONTEXT=child-v8 "$node" "$probe_dir/probe.test.mjs"
    launch "test: vitest worker" "$node" "$probe_dir/node_modules/vitest/dist/workers/forks.js"
    # The real python3 (Command Line Tools ship one): framework Pythons run as `…/MacOS/Python`. Its
    # own interpreter path, so a version manager's shell shim is not what Saur0n sees.
    local python
    python=$(python3 -c 'import sys; print(sys.executable)') ||
        { echo "readable-names: FAIL — no python3 to run pytest's launch shape"; return 1; }
    launch "test: pytest" "$python" -c 'import time; time.sleep(60)' -m pytest
    if ((window)); then
        trap 'stop_readable_names; stop_window; trap - RETURN EXIT' RETURN EXIT
        window_up || return 1
    fi
    # The window's full-table read is not one refresh: rows that reorder mid-read can skip a row (1 run in
    # 5, 2026-10-19), so a read missing a stand-in is read again, up to 3 reads.
    local attempt missing
    for attempt in 1 2 3; do
        json=$(process_json 0.2) || { echo "readable-names: FAIL — cannot read the process list"; return 1; }
        missing=$(jq -r --argjson pids "[$(IFS=,; echo "${probe_pids[*]}")]" \
            '[.processes[].pid] as $shown | [$pids[] | select(. as $p | $shown | index($p) | not)] | map(tostring) | join(" ")' <<<"$json")
        [[ -n $missing ]] || break
    done
    [[ -z $missing ]] ||
        { echo "readable-names: FAIL — stand-in pid(s) $missing missing from Saur0n's process list on 3 reads"; return 1; }
    for i in "${!probe_pids[@]}"; do
        name=$(readable_of "$json" '.pid == $pid' "${probe_pids[$i]}")
        [[ $name == "${probe_wants[$i]}" ]] ||
            { echo "readable-names: FAIL — stand-in (pid ${probe_pids[$i]}) reads '$name', want '${probe_wants[$i]}'"; return 1; }
    done
    local summary="${#probe_pids[@]} stand-ins read as wanted (impostor kernel_task and trustd unlabelled; '${probe_wants[2]}' … '${probe_wants[${#probe_wants[@]} - 1]}')"

    # A daemon with a man page shows the page's own .Nd line (trustd, else cfprefsd — both always run),
    # its surrounding quotes stripped as mdoc does.
    local daemon page nd shown
    for daemon in trustd cfprefsd; do
        page=/usr/share/man/man8/$daemon.8
        [[ -f $page ]] || continue
        jq -e --arg n "$daemon" 'any(.processes[]; .name == $n)' <<<"$json" >/dev/null || continue
        nd=$(sed -n 's/^\.Nd //p' "$page" | head -1 | sed -e 's/[[:space:]]*$//' -e 's/^"\([^"]*\)"$/\1/')
        # Not the check's own impostor trustd (pid probe_pids[1]), which the window may list first.
        shown=$(readable_of "$json" '.name == $name and .pid != $pid' "${probe_pids[1]}" "$daemon")
        [[ -n $nd && $shown == "$nd" ]] ||
            { echo "readable-names: FAIL — $daemon reads '$shown', its man page says '$nd'"; return 1; }
        summary+="; $daemon reads its man page line '$shown'"
        break
    done
    [[ -n ${shown:-} ]] || { echo "readable-names: FAIL — neither trustd nor cfprefsd is running with a man page"; return 1; }

    # A visible daemon without a page reads Saur0n's own description. Spotlight may be off: then skip.
    shown=$(readable_of "$json" '.name == $name' 0 mds_stores)
    if [[ $shown == absent ]]; then
        summary+="; mds_stores not running (skipped)"
    elif [[ $shown == *Spotlight* ]]; then
        summary+="; mds_stores reads '$shown'"
    else
        echo "readable-names: FAIL — mds_stores reads '$shown', want Saur0n's Spotlight description"; return 1
    fi
    ((window)) && summary="window: $summary"
    echo "readable-names: ok ($summary)"
}

# vm-cores' load: the host `limactl shell` pid, the folder of the guest's output and of the fifo whose
# write end (fd 9) is the guest's stdin, and the result line. Globals for the traps and the caller.
load_pid="" load_dir="" load_result=""

# Close the guest's stdin (it then kills its loops), stop the host side, remove the files.
stop_vm_load() {
    exec 9>&-
    if [[ -n $load_pid ]]; then
        kill "$load_pid" 2>/dev/null || true
        wait "$load_pid" 2>/dev/null || true
    fi
    [[ -z $load_dir ]] || rm -rf "$load_dir"
    load_pid="" load_dir=""
}

# Saur0n's share of its cores for VM $1 over a 2-second sample, or "absent"; with --window, the window's
# row two refreshes after the load started.
vm_share() {
    local json
    if ((window)); then sleep 2; json=$(read_window rows); else json=$(.build/debug/saur0n --json --interval 2); fi
    jq -r --arg n "$1" '[.processes[] | select(.vm.name == $n) | .vm.shareOfAllotted] | first // "absent"' <<<"$json"
}

# A known load's plan for VM $2 ($3 cores, idle at $4%; $1 names its kind): min(2, cores) busy loops,
# which should read that many cores' worth (`want`%). Sets the caller's `loops` and `want`. The VM must
# be idle (≤ 5%), or a load that never ran could pass.
load_plan() {
    loops=$(( $3 < 2 ? $3 : 2 ))
    want=$(awk -v l="$loops" -v v="$3" 'BEGIN { printf "%.1f", 100 * l / v }')
    awk -v b="$4" 'BEGIN { exit !(b <= 5) }' ||
        { echo "vm-cores: FAIL — every $1 is busy (least busy: $2 at $4% of its cores); the known load needs one at 5% or less"; return 1; }
}

# A known load's verdict for VM $1 ($2 cores, idle at $3%) reading share $4, against the caller's
# `loops` and `want`: at least 80% of `want`, at most 110% of it plus the idle share and 1 point of
# rounding. The result line goes in load_result.
load_verdict() {
    awk -v s="$4" -v w="$want" -v b="$3" 'BEGIN { exit !(s + 0 == s && s >= 0.8 * w && s <= 1.1 * w + b + 1) }' ||
        { echo "vm-cores: FAIL — $loops busy loops in $1 read '$4'% of its $2 cores, want about $want%"; return 1; }
    load_result="$loops busy loops in $1 read $4% of its cores, want about $want%"
}

# A known load in Lima instance $2 (LIMA_HOME $1, $3 vCPUs, idle at $4%), per load_plan and
# load_verdict. No loop outlives the check: the guest kills them when its stdin closes (the check
# ending, or the session dropping), each also runs under the guest's own `timeout 60`, and sampling
# starts only once the guest says the loops run. 60, not 15: the window's `rows` read opens every group and
# can take ~30 s on a full table (probe 2026-10-19), so a 15 s load ended before the read reached the VM row.
vm_known_load() {
    local home=$1 vm=$2 vcpus=$3 idle=$4 loops want share status
    load_plan "Lima VM" "$vm" "$vcpus" "$idle" || return 1
    command -v limactl >/dev/null || { echo "vm-cores: FAIL — limactl is needed to load a VM"; return 1; }
    # On return only the load stops; on exit the window check's app too (stop_window: a no-op without one).
    trap 'stop_vm_load; trap - RETURN' RETURN
    trap 'stop_vm_load; stop_window' EXIT
    trap 'stop_vm_load; exit 1' INT TERM HUP
    load_dir=$(mktemp -d)
    mkfifo "$load_dir/stdin"
    LIMA_HOME=$home limactl shell "$vm" -- sh -c "p=; trap 'kill \$p 2>/dev/null; exit 0' HUP INT TERM
        i=0; while [ \$i -lt $loops ]; do timeout 60 yes >/dev/null & p=\"\$p \$!\"; i=\$((i + 1)); done
        echo started; cat >/dev/null; kill \$p 2>/dev/null; exit 0" <"$load_dir/stdin" >"$load_dir/out" 2>&1 &
    load_pid=$!
    exec 9>"$load_dir/stdin"
    for _ in {1..40}; do
        grep -q '^started' "$load_dir/out" && break
        kill -0 "$load_pid" 2>/dev/null || break
        sleep 0.25
    done
    grep -q '^started' "$load_dir/out" ||
        { echo "vm-cores: FAIL — the load in $vm did not start: $(tail -2 "$load_dir/out" | tr '\n' ' ')"; return 1; }
    share=$(vm_share "$vm")
    kill -0 "$load_pid" 2>/dev/null ||
        { echo "vm-cores: FAIL — the load in $vm ended during the sample: $(tail -2 "$load_dir/out" | tr '\n' ' ')"; return 1; }
    exec 9>&-
    wait "$load_pid" && status=0 || status=$?
    load_pid=""
    [[ $status == 0 ]] ||
        { echo "vm-cores: FAIL — the load in $vm ended with status $status: $(tail -2 "$load_dir/out" | tr '\n' ' ')"; return 1; }
    load_verdict "$vm" "$vcpus" "$idle" "$share"
}

# The cores a QEMU command line ($1) starts with, as QEMU reads them: every `-smp` merged key by key,
# the later value winning; then `cpus` (or a leading bare number), else `maxcpus`, else the product of
# the topology members; else nothing. Numbers as strtoull with base 0: `+`, `0x` hex, leading-0 octal.
smp_count() {
    awk 'function num(x,   b, d, i, c, v) {
            sub(/^\+/, "", x); b = 10
            if (x ~ /^0[xX]/) { b = 16; x = substr(x, 3) } else if (x ~ /^0./) { b = 8; x = substr(x, 2) }
            if (x == "") return -1
            d = substr("0123456789abcdef", 1, b); v = 0
            for (i = 1; i <= length(x); i++) { c = index(d, tolower(substr(x, i, 1))); if (!c) return -1; v = v * b + c - 1 }
            return v
        }
        { for (i = 1; i < NF; i++) if ($i == "-smp" || $i == "--smp") {
              n = split($(i + 1), items, ",")
              for (j = 1; j <= n; j++) {
                  k = "cpus"; x = items[j]; e = index(x, "=")
                  if (e) { k = substr(x, 1, e - 1); x = substr(x, e + 1) }
                  raw[k] = x; any_smp = 1
              }
          } }
        END {
            if (!any_smp) exit
            for (k in raw) { x = num(raw[k]); if (x <= 0) exit; val[k] = x }
            if ("cpus" in val) { print val["cpus"]; exit }
            if ("maxcpus" in val) { print val["maxcpus"]; exit }
            m = split("drawers books sockets dies clusters modules cores threads", t, " "); p = 1; any = 0
            for (j = 1; j <= m; j++) if (t[j] in val) { p *= val[t[j]]; any = 1 }
            if (any) print p
        }' <<<"$1"
}

# The UTM VM (its UUID) carrying vm-cores' load. A global for the traps.
utm_load_vm=""

# Kill exactly the loops the load started (their pids are in the guest's pid file) and remove its files.
stop_utm_load() {
    [[ -n $utm_load_vm ]] || return 0
    utmctl exec "$utm_load_vm" --cmd sh -c \
        'kill $(cat /tmp/saur0n-load.pids 2>/dev/null) 2>/dev/null; rm -f /tmp/saur0n-load /tmp/saur0n-load.pids' >/dev/null 2>&1 || true
    utm_load_vm=""
}

# A known load in UTM VM $1 (UUID $2, $3 cores, idle at $4%, the Mac $5% busy), per load_plan and
# load_verdict. The Mac must be no more than 70% busy — a saturated host starves the vCPUs
# (research/2026-10-17-utm-qemu-vms.md § Q4). `utmctl exec` returns at once and never reports the
# guest's exit, so each loop ends itself under the guest's `timeout 30`; the check kills them by the
# pids the guest wrote down on every exit path, and samples only once the guest's marker file says
# they run.
utm_known_load() {
    local vm=$1 uuid=$2 vcpus=$3 idle=$4 total=$5 loops want share started
    load_plan "Linux UTM VM" "$vm" "$vcpus" "$idle" || return 1
    awk -v t="$total" 'BEGIN { exit !(t + 0 == t && t <= 70) }' ||
        { echo "vm-cores: FAIL — the Mac is $total% busy; the UTM known load needs it at 70% or less"; return 1; }
    trap 'stop_utm_load; trap - RETURN' RETURN
    trap 'stop_utm_load; stop_window' EXIT
    trap 'stop_utm_load; exit 1' INT TERM HUP
    utm_load_vm=$uuid
    started=$SECONDS
    utmctl exec "$uuid" --cmd sh -c "rm -f /tmp/saur0n-load /tmp/saur0n-load.pids; p=; i=0
        while [ \$i -lt $loops ]; do timeout 30 yes >/dev/null 2>&1 & p=\"\$p \$!\"; i=\$((i + 1)); done
        echo \$p >/tmp/saur0n-load.pids; echo started >/tmp/saur0n-load" >/dev/null 2>&1 ||
        { echo "vm-cores: FAIL — utmctl could not run the load in $vm"; return 1; }
    until [[ $(utmctl file pull "$uuid" /tmp/saur0n-load 2>/dev/null) == started ]]; do
        (( SECONDS - started < 10 )) || { echo "vm-cores: FAIL — the load in $vm did not start within 10 s"; return 1; }
        sleep 0.25
    done
    share=$(vm_share "$vm")
    (( SECONDS - started < 28 )) || { echo "vm-cores: FAIL — the load in $vm may have ended during the sample"; return 1; }
    load_verdict "$vm" "$vcpus" "$idle" "$share"
}

# Every VM of this user that runs through the sample is shown as a VM: each Virtualization.framework
# process, and each UTM QEMU VM (`QEMULauncher` running a `*-softmmu` QEMU; UTM's TPM helper `swtpm.0`
# runs from the same launcher and is not a VM). Names and cores are checked against sources Saur0n
# does not read:
# - Lima: the folder of its open `disk` / `vz-efi` holds `lima.yaml`; named after that instance, with
#   its `cpus`.
# - UTM QEMU: named after the `.utm` bundle of a file it holds open (`lsof`); cores = the `-smp` count
#   in its `ps` arguments, and = `config.plist` `System.CPUCount` when that reads non-zero.
# - Any other VM: the `.utm` bundle of its disk (UTM's Apple engine), "Docker Desktop" for
#   `Docker.raw`, else "VM · …".
# Spread over the machine, each share fits inside the process's own CPU (1 point of slack for
# rounding). A Virtualization.framework share is also at most 100% (its vCPU threads only); a QEMU
# share is not capped (the whole process, its own I/O included). Then the least busy Lima VM and the
# least busy Linux UTM VM each carry a known load (vm_known_load, utm_known_load). No VM to load is a
# failure, never a pass.
check_vm_cores() {
    local json vms running pid name vcpus share cpu files cpus
    local summary="" loads="" target="" target_home="" target_vcpus=0 target_share=101 utm_vms="" utm_pids=" "
    build
    if ((window)); then
        trap 'stop_window' EXIT
        trap 'stop_window; exit 1' INT TERM HUP
        window_up || return 1
    fi
    cpus=$(sysctl -n hw.logicalcpu)
    running=$(running_vms) || { echo "$running"; return 1; }
    utm_pids+=$(awk '$2 == "utm" { printf "%s ", $1 }' <<<"$running")
    json=$(process_json 1) || { echo "vm-cores: FAIL — cannot read the process list"; return 1; }
    vms=$(jq -r '.processes[] | select(.vm != null) | "\(.pid)\t\(.vm.name)\t\(.vm.vcpus)\t\(.vm.shareOfAllotted)\t\(.cpuPercent)"' <<<"$json")
    [[ -n $vms ]] || { echo "vm-cores: FAIL — no VM running; start a VM first"; return 1; }
    for pid in $(cut -f1 <<<"$running"); do
        kill -0 "$pid" 2>/dev/null || continue  # exited during the sample: Saur0n drops it, as top does
        jq -e --argjson pid "$pid" 'any(.processes[]; .pid == $pid and .vm != null)' <<<"$json" >/dev/null ||
            { echo "vm-cores: FAIL — VM pid $pid runs, but Saur0n shows no VM for it"; return 1; }
    done
    while IFS=$'\t' read -r pid name vcpus share cpu; do
        files=$(lsof -Fn -p "$pid" 2>/dev/null) || {
            kill -0 "$pid" 2>/dev/null || continue  # exited since the sample
            echo "vm-cores: FAIL — lsof could not list VM pid $pid's open files"; return 1; }
        files=$(sed -n 's/^n//p' <<<"$files")
        if [[ $utm_pids == *" $pid "* ]]; then
            check_utm_vm || return 1
        else
            check_vz_vm || return 1
        fi
    done <<<"$vms"
    [[ -n $target || -n $utm_vms ]] || { echo "vm-cores: FAIL — no Lima or UTM QEMU VM running to load; start one first"; return 1; }
    if [[ -n $target ]]; then
        vm_known_load "$target_home" "$target" "$target_vcpus" "$target_share" || return 1
        loads+="; $load_result"
    fi
    if [[ -n $utm_vms ]]; then
        load_utm_vm "$(jq -r '.totalBusyPercent' <<<"$json")" || return 1
        loads+="; $load_result"
    fi
    echo "vm-cores: ok ($( ((window)) && echo "window: ")$summary$loads)"
}

# This user's VM processes, one `<pid>\tvz` or `<pid>\tutm` line each.
running_vms() {
    local running pid
    running=$(ps -U "$(id -u)" -o pid=,comm=) || { echo "vm-cores: FAIL — ps could not list this user's processes"; return 1; }
    awk '$2 ~ /\/com\.apple\.Virtualization\.VirtualMachine$/ { print $1 "\tvz" }' <<<"$running"
    # A QEMU VM's launcher runs a `*-softmmu` binary as argv[1]. `ps` joins argv with spaces and UTM's
    # path may hold some, so argv[1] runs from after the launcher up to the first ` -` option.
    for pid in $(awk '/\/QEMULauncher\.app\/Contents\/MacOS\/QEMULauncher$/ { print $1 }' <<<"$running"); do
        ps -ww -o args= -p "$pid" 2>/dev/null |
            awk '{ sub(/^.*\/QEMULauncher\.app\/Contents\/MacOS\/QEMULauncher /, ""); sub(/ -.*$/, ""); exit !/-softmmu$/ }' &&
            printf '%s\tutm\n' "$pid"
    done
    return 0
}

# The `.utm` bundle holding one of the open `files`, if any.
utm_bundle() { sed -nE 's#^(.*\.utm)/Data/.*#\1#p' <<<"$files" | head -1 || true; }

# One UTM QEMU row (check_vm_cores' pid, name, vcpus, share, cpu, files, cpus): its share fits the
# process's CPU, it is named after its bundle, its cores match `-smp` and `config.plist`. Adds to the
# caller's summary and utm_vms.
check_utm_vm() {
    local bundle args want_cpus plist uuid
    awk -v s="$share" -v v="$vcpus" -v n="$cpus" -v c="$cpu" 'BEGIN { exit !(s >= 0 && s * v / n <= c + 1) }' ||
        { echo "vm-cores: FAIL — $name: $share% of $vcpus cores does not fit the process's $cpu% of $cpus CPUs"; return 1; }
    bundle=$(utm_bundle)
    [[ -n $bundle ]] || { echo "vm-cores: FAIL — UTM VM pid $pid holds no file open inside a .utm bundle"; return 1; }
    [[ $name == "$(basename "$bundle" .utm)" ]] ||
        { echo "vm-cores: FAIL — UTM VM pid $pid named '$name', its bundle is '$(basename "$bundle")'"; return 1; }
    args=$(ps -ww -o args= -p "$pid" 2>/dev/null || true)
    want_cpus=$(smp_count "$args")
    [[ $vcpus == "$want_cpus" ]] ||
        { echo "vm-cores: FAIL — $name shows $vcpus cores, its -smp says ${want_cpus:-<none>}"; return 1; }
    # A config.plist whose System settings lack the key passes on -smp alone; one without readable
    # System settings fails (`plutil -lint` passes any text as an old-style plist, so it cannot tell).
    plist=$(plutil -extract System.CPUCount raw -o - "$bundle/config.plist" 2>/dev/null) || {
        plutil -extract System xml1 -o - "$bundle/config.plist" >/dev/null 2>&1 ||
            { echo "vm-cores: FAIL — $name's $bundle/config.plist cannot be read"; return 1; }
        plist=""; }
    [[ ! $plist =~ ^[1-9][0-9]*$ || $plist == "$vcpus" ]] ||
        { echo "vm-cores: FAIL — $name shows $vcpus cores, its config.plist says CPUCount $plist"; return 1; }
    summary+="${summary:+; }$name $vcpus cores (UTM QEMU: -smp $want_cpus, config.plist CPUCount ${plist:-not set}), $share% of its cores"
    uuid=$(awk '{ for (i = 1; i < NF; i++) if ($i == "-uuid") u = $(i + 1) } END { print u }' <<<"$args")
    utm_vms+="$share"$'\t'"$name"$'\t'"$uuid"$'\t'"$vcpus"$'\n'
}

# One Virtualization.framework row (check_vm_cores' pid, name, vcpus, share, cpu, files, cpus): its
# share is at most 100% and fits the process's CPU; a Lima VM is named after its instance with its
# `cpus`, any other after its UTM bundle, "Docker Desktop" or "VM · …". Adds to the caller's summary
# and keeps the least busy Lima VM as its load target.
check_vz_vm() {
    local folder bundle want want_cpus
    awk -v s="$share" -v v="$vcpus" -v n="$cpus" -v c="$cpu" 'BEGIN { exit !(s >= 0 && s <= 100 && s * v / n <= c + 1) }' ||
        { echo "vm-cores: FAIL — $name: $share% of $vcpus cores does not fit the process's $cpu% of $cpus CPUs"; return 1; }
    folder=$(sed -nE 's#/(disk|vz-efi)$##p' <<<"$files" | head -1 || true)
    if [[ -z $folder || ! -f $folder/lima.yaml ]]; then
        bundle=$(utm_bundle) want=""
        if [[ -n $bundle ]]; then want=$(basename "$bundle" .utm)
        elif grep -q '/Docker\.raw$' <<<"$files"; then want="Docker Desktop"
        fi
        if [[ -n $want ]]; then
            [[ $name == "$want" ]] || { echo "vm-cores: FAIL — VM pid $pid named '$name', want '$want'"; return 1; }
        else
            [[ $name == "VM" || $name == "VM · "* ]] ||
                { echo "vm-cores: FAIL — VM pid $pid holds no Lima, UTM or Docker disk open but is named '$name', want 'VM · …'"; return 1; }
        fi
        summary+="${summary:+; }$name $vcpus cores (not Lima), $share% of its cores"
        return 0
    fi
    want_cpus=$(awk '/^cpus:/ { print $2; exit }' "$folder/lima.yaml")
    [[ $name == "$(basename "$folder")" ]] ||
        { echo "vm-cores: FAIL — VM pid $pid named '$name', its Lima instance is '$(basename "$folder")'"; return 1; }
    [[ $vcpus == "$want_cpus" ]] ||
        { echo "vm-cores: FAIL — $name shows $vcpus cores, lima.yaml says cpus: ${want_cpus:-<none>}"; return 1; }
    summary+="${summary:+; }$name $vcpus cores (lima.yaml $want_cpus), $share% of its cores"
    if awk -v s="$share" -v t="$target_share" 'BEGIN { exit !(s < t) }'; then
        target=$name target_home=$(dirname "$folder") target_vcpus=$vcpus target_share=$share
    fi
}

# The known load on the least busy Linux UTM VM among check_vm_cores' utm_vms whose guest agent
# answers, the Mac being $1% busy in check_vm_cores' sample.
load_utm_vm() {
    local share name uuid vcpus picked=""
    while IFS=$'\t' read -r share name uuid vcpus; do
        # `utmctl file pull` exits 0 even when the file is missing: read the content.
        [[ -n $uuid ]] && utmctl file pull "$uuid" /etc/os-release 2>/dev/null | grep '^ID=' >/dev/null &&
            { picked="$name"$'\t'"$uuid"$'\t'"$vcpus"$'\t'"$share"; break; }
    done < <(sort -n <<<"${utm_vms%$'\n'}")
    [[ -n $picked ]] ||
        { echo "vm-cores: FAIL — no running UTM VM is a Linux guest whose agent answers; the known load needs one"; return 1; }
    IFS=$'\t' read -r name uuid vcpus share <<<"$picked"
    utm_known_load "$name" "$uuid" "$vcpus" "$share" "$1"
}

# repo-groups' known loads and the mktemp folder holding the probe repo, its worktree and the load
# program, and the --window working-folder sampler. Globals for the traps.
repo_pids=() repo_dir="" sampler_pid=""

# Kill exactly the loads and the sampler the check started, remove the worktree, then the folder — only
# when it is the one mktemp made (under the temp root, named by mktemp's template).
stop_repo_groups() {
    local pid
    for pid in ${repo_pids[@]+"${repo_pids[@]}"} $sampler_pid; do kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null || true; done
    sampler_pid=""
    [[ -n $repo_dir ]] || return 0
    git -C "$repo_dir/probe-repo" worktree remove --force "$repo_dir/probe-wt" >/dev/null 2>&1 || true
    [[ $repo_dir == "$(dirname "$(mktemp -u)")"/tmp.* && -d $repo_dir ]] && rm -rf -- "$repo_dir"
    repo_dir=""
}

# The `ps` CPU time, in seconds, of the loads in the probe repo and its worktree (repo_pids 0 and 1), summed.
loads_seconds() {
    awk -v a="$(ps_seconds "${repo_pids[0]}")" -v b="$(ps_seconds "${repo_pids[1]}")" 'BEGIN { printf "%.2f", a + b }'
}

# git in the probe repo, with none of the user's hooks, signing or identity in play.
probe_git() {
    env -u GIT_DIR -u GIT_WORK_TREE git -c core.hooksPath=/dev/null -c commit.gpgsign=false \
        -c user.name=probe -c user.email=probe@example.invalid "$@"
}

# The repo root git itself gives for folder $1 (the folder holding the common .git, a bare repo
# itself, a submodule's top), or nothing outside a repo.
git_root() {
    local common
    common=$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
    case $common in
        */.git/modules/*) env -u GIT_DIR -u GIT_WORK_TREE git -C "$1" rev-parse --show-toplevel 2>/dev/null || true ;;
        */.git) dirname "$common" ;;
        *) echo "$common" ;;
    esac
}

# Each own-user pid and its working directory as lsof sees it, "<pid>\t<folder>" per line.
own_cwds() {
    lsof -a -d cwd -u "$(id -u)" -Fpn 2>/dev/null | awk '/^p/ { p = substr($0, 2) } /^n/ && p { print p "\t" substr($0, 2); p = "" }'
}

# The Claude Code session this check runs under: the nearest ancestor of this shell with a
# `~/.claude/sessions/<pid>.json` whose `procStart` (UTC) is that pid's start time. Prints
# `<sessionId>\t<label>` (label = the file's `name`, else its cwd's basename and the id's first 8
# characters), or nothing when no ancestor is registered. Reads the registry only.
check_claude_session() {
    local pid=$$ file started registered
    while [[ $pid -gt 1 ]]; do
        file=$HOME/.claude/sessions/$pid.json
        if [[ -f $file ]]; then
            started=$(date -j -f "%a %b %d %T %Y" "$(ps -o lstart= -p "$pid" | xargs)" +%s 2>/dev/null)
            registered=$(TZ=UTC date -j -f "%a %b %d %T %Y" "$(jq -r '.procStart // ""' "$file" | xargs)" +%s 2>/dev/null)
            if [[ -n $started && $started == "$registered" ]]; then
                jq -r '[.sessionId, (.name // "" | if . == "" then null else . end) //
                        "\((.cwd // "") | split("/") | map(select(. != "")) | last // "") \(.sessionId[0:8])"] | @tsv' "$file"
                return 0
            fi
        fi
        pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
        [[ -n $pid ]] || return 0
    done
}

# (1) A throwaway repo and a linked worktree of it, one known CPU load working in each: Saur0n puts
# both in one group named after the repo, names the worktree on its row, and gives the group at least
# the two loads' own `ps` CPU-time share across the read, less 2 points. (2) Every own-user process whose working directory git places in a
# repo (`lsof` for the directory, `git rev-parse` for the repo) sits in that repo's group. (3) A `git
# clone` of the repo with a third load is its own group, headed "clone of probe-repo" in the table.
# (4) Every swarm member running (cwd outside any repo, a repo granted by `--add-dir`) sits in that
# repo's group; the count is printed. (5) Under a Claude Code session, the loads carry that session
# (kind, id and label); otherwise the part is skipped.
# With --window the same parts read Saur0n.app's window: repos by the group a row sits under (the window
# shows no root; a group title is the repo's name, with its root when two share it), the worktree by its
# folder name, sessions by label (the window shows no kind or id); at least 2 swarm members must run.
check_repo_groups() {
    local json ncpu real wt_real clone_real bin pid root worktree group_cpu want summary t0 t1 cpu0 cpu1
    build
    trap 'stop_repo_groups; stop_window; trap - RETURN EXIT' RETURN EXIT
    trap 'stop_repo_groups; stop_window; exit 1' INT TERM HUP
    ((window)) && { window_up || return 1; }
    repo_dir=$(mktemp -d)
    probe_git init -q -b main "$repo_dir/probe-repo" &&
        probe_git -C "$repo_dir/probe-repo" commit -q --allow-empty --no-verify -m probe &&
        probe_git -C "$repo_dir/probe-repo" worktree add -q -b probe-wt "$repo_dir/probe-wt" ||
        { echo "repo-groups: FAIL — could not make the probe repo and its worktree"; return 1; }
    probe_git clone -q "$repo_dir/probe-repo" "$repo_dir/probe-clone" ||
        { echo "repo-groups: FAIL — could not clone the probe repo"; return 1; }
    real=$(cd "$repo_dir/probe-repo" && pwd -P) wt_real=$(cd "$repo_dir/probe-wt" && pwd -P)
    clone_real=$(cd "$repo_dir/probe-clone" && pwd -P)
    # A busy loop that ends itself after 180 s, whatever happens to the check (the window's row read takes
    # 67–84 s on a busy Mac and the By session read comes after it; 60 s ended the loads first, 2026-10-21).
    bin=$repo_dir/bin/probe-load
    mkdir -p "$repo_dir/bin"
    printf '#include <time.h>\nint main(void) { time_t end = time(0) + 180; while (time(0) < end) {} return 0; }\n' |
        cc -O0 -x c -o "$bin" - || { echo "repo-groups: FAIL — cc could not build the load"; return 1; }
    # REPO_GROUPS_MEMBERS_CMD starts a swarm wave. Run here, after the slow set-up (app, repos, load binary)
    # and before the loads, and the reads start once two members run: a wave whose members finish in ~95 s
    # was gone by the member read when started before the check (2026-10-19).
    start_members "${REPO_GROUPS_MEMBERS_CMD:-}" || return 1
    (cd "$real" && exec "$bin") &
    repo_pids+=($!)
    (cd "$wt_real" && exec "$bin") &
    repo_pids+=($!)
    (cd "$clone_real" && exec "$bin") &
    repo_pids+=($!)
    ncpu=$(sysctl -n hw.logicalcpu)
    # The group's floor: the two loads' own ps CPU time across the read, as a share of the machine
    # (research 2026-10-19 decision 9; "two cores' worth" failed on a busy Mac, where the loads get less).
    local group
    if ((window)); then
        # Every own-user pid's folder twice a second from here to the end of the row read: the refresh the
        # read freezes on lags a single lsof just before it by seconds on a busy Mac (2026-10-21 wave round).
        (while :; do own_cwds; sleep 0.5; done) >"$repo_dir/cwd-samples" &
        sampler_pid=$!
        sleep 2.5    # two refreshes since the loads started
        cpu0=$(loads_seconds); t0=$(now)
        group=$(read_window snapshot --expand probe-repo) || { echo "repo-groups: FAIL — cannot read one refresh of the window"; return 1; }
        cpu1=$(loads_seconds); t1=$(now)
        json=$(read_window rows) || { echo "repo-groups: FAIL — cannot read the window's rows"; return 1; }
        kill "$sampler_pid" 2>/dev/null && wait "$sampler_pid" 2>/dev/null || true; sampler_pid=""
    else
        cpu0=$(loads_seconds); t0=$(now)
        json=$(saur0n --json --interval 2)
        cpu1=$(loads_seconds); t1=$(now)
        group=$json
    fi
    want=$(awk -v c0="$cpu0" -v c1="$cpu1" -v t0="$t0" -v t1="$t1" -v n="$ncpu" \
        'BEGIN { printf "%.2f", 100 * (c1 - c0) / ((t1 - t0) * n) - 2 }')

    if ((window)); then
        for pid in "${repo_pids[@]:0:2}"; do
            root=$(jq -r --argjson p "$pid" '[.processes[] | select(.pid == $p) | .group] | first // "absent"' <<<"$json")
            [[ $root == probe-repo ]] || { echo "repo-groups: FAIL — load pid $pid sits under group '$root', want 'probe-repo'"; return 1; }
        done
        wt_real=$(basename "$wt_real")    # the window names a worktree by its folder
    else
        for pid in "${repo_pids[@]:0:2}"; do
            root=$(jq -r --argjson p "$pid" '[.processes[] | select(.pid == $p) | .repo.root // "none"] | first // "absent"' <<<"$json")
            [[ $root == "$real" ]] || { echo "repo-groups: FAIL — load pid $pid reads repo root '$root', want '$real'"; return 1; }
        done
    fi
    worktree=$(jq -r --argjson p "${repo_pids[0]}" '.processes[] | select(.pid == $p) | .repo.worktree' <<<"$json")
    [[ $worktree == null ]] || { echo "repo-groups: FAIL — the load in the main checkout names worktree '$worktree'"; return 1; }
    worktree=$(jq -r --argjson p "${repo_pids[1]}" '.processes[] | select(.pid == $p) | .repo.worktree' <<<"$json")
    [[ $worktree == "$wt_real" ]] || { echo "repo-groups: FAIL — the load in the worktree names worktree '$worktree', want '$wt_real'"; return 1; }
    group_cpu=$(jq -r --argjson a "${repo_pids[0]}" --argjson b "${repo_pids[1]}" \
        '[.repoGroups[] | select(.name == "probe-repo" and (.pids | index($a)) and (.pids | index($b))) | .cpuPercent + .exitedChildrenCpuPercent] | first // "absent"' <<<"$group")
    awk -v c="$group_cpu" -v w="$want" 'BEGIN { exit !(c + 0 == c && c >= w) }' ||
        { echo "repo-groups: FAIL — group probe-repo holding both loads reads '$group_cpu'%, want at least $want% (the loads' ps share less 2)"; return 1; }
    summary="probe-repo and its worktree in one group at $group_cpu% (want ≥ $want%, the loads' ps share less 2)"

    # A full clone keeps its own group; the table's header names what it is a clone of (no JSON field).
    if ((window)); then
        root=$(jq -r --argjson p "${repo_pids[2]}" '[.processes[] | select(.pid == $p) | .group] | first // "absent"' <<<"$json")
        [[ $root == "probe-clone  (clone of probe-repo)" ]] ||
            { echo "repo-groups: FAIL — load pid ${repo_pids[2]} in the clone sits under group '$root', want 'probe-clone  (clone of probe-repo)'"; return 1; }
    else
        root=$(jq -r --argjson p "${repo_pids[2]}" '[.processes[] | select(.pid == $p) | .repo.root // "none"] | first // "absent"' <<<"$json")
        [[ $root == "$clone_real" ]] || { echo "repo-groups: FAIL — load pid ${repo_pids[2]} in the clone reads repo root '$root', want '$clone_real'"; return 1; }
        grep -q '^probe-clone  (clone of probe-repo)  ' <<<"$(saur0n --interval 1)" ||
            { echo "repo-groups: FAIL — the table has no 'probe-clone  (clone of probe-repo)' group header"; return 1; }
    fi
    summary+="; probe-clone its own group, 'clone of probe-repo'"

    # Each own-user pid's working directory as lsof sees it, right after Saur0n's read, then git's
    # repo for each distinct one. The window's read takes 40–80 s, so there the pids the sampler saw in more
    # than one folder (Gradle's daemon enters the project folder per build) are skipped and named; in the
    # CLI's 2 s a process that changed directory in between would show as a mismatch.
    local cwds stable moved="" roots shown checked mismatches
    cwds=$(own_cwds)
    [[ -n $cwds ]] || { echo "repo-groups: FAIL — lsof listed no working directories"; return 1; }
    stable=$cwds
    if ((window)); then
        # Only pids the window shows and lsof still lists after the read: a busy Mac reuses the pids of
        # short-lived processes within the read, which would read as moves.
        moved=$(awk -F'\t' 'FILENAME == ARGV[1] { keep[$1] = 1; next } FILENAME == ARGV[2] { if ($1 in keep) alive[$1] = 1; next }
            ($1 in alive) && NF == 2 && !(($1, $2) in seen) { seen[$1, $2] = 1; dirs[$1] = dirs[$1] (dirs[$1] == "" ? "" : ", ") $2; n[$1]++ }
            END { for (p in n) if (n[p] > 1) { print p; printf "pid %s moved during the read (%s), skipped\n", p, dirs[p] > "/dev/stderr" } }' \
            <(jq -r '.processes[].pid' <<<"$json") <(printf '%s\n' "$cwds") "$repo_dir/cwd-samples" <(printf '%s\n' "$cwds"))
        stable=$(awk -F'\t' 'FILENAME == ARGV[1] { if ($1 != "") skip[$1] = 1; next } !($1 in skip)' <(printf '%s\n' "$moved") <(printf '%s\n' "$cwds"))
    fi
    roots=$(cut -f2 <<<"$cwds" | sort -u | while IFS= read -r dir; do
        root=$(git_root "$dir")
        [[ -z $root ]] || printf '%s\t%s\n' "$dir" "$root"
    done)
    # The CLI gives each pid's repo root; the window, the title of the group it sits under (the repo's name,
    # then " (<root>)" when two repos share it or "  (clone of …)"), so there the root's folder name is compared.
    if ((window)); then
        shown=$(jq -r --arg u "$(id -un)" '.processes[] | select(.user == $u) | "\(.pid)\t\(.group)"' <<<"$json")
    else
        shown=$(jq -r --argjson u "$(id -u)" '.processes[] | select(.uid == $u) | "\(.pid)\t\(.repo.root // "")"' <<<"$json")
    fi
    # Join: pid → cwd → git's root, against Saur0n's root for that pid; pids in both lists only.
    read -r checked mismatches < <(awk -F'\t' -v window="$window" '
        function shown_as(root,   n, parts) { if (!window) return root; n = split(root, parts, "/"); return parts[n] }
        FILENAME == ARGV[1] { root[$1] = $2; next }
        FILENAME == ARGV[2] { if ($2 in root) want[$1] = root[$2]; next }
        ($1 in want) { n++; got = $2; if (window) sub(/ +\(.*$/, "", got)
                       if (got != shown_as(want[$1])) { bad++; printf "pid %s in %s reads '\''%s'\''\n", $1, want[$1], $2 > "/dev/stderr" } }
        END { print n + 0, bad + 0 }' <(printf '%s\n' "$roots") <(printf '%s\n' "$stable") <(printf '%s\n' "$shown"))
    [[ $mismatches == 0 ]] ||
        { echo "repo-groups: FAIL — $mismatches of $checked in-repo processes are not under git's repo for their working directory (listed above)"; return 1; }
    [[ $checked -ge 2 ]] || { echo "repo-groups: FAIL — only $checked in-repo processes matched; the two loads alone make 2"; return 1; }
    summary+="; all $checked in-repo own-user processes under git's repo for their working directory"
    [[ -z $moved ]] || summary+="; $(grep -c . <<<"$moved") moved folder during the read, skipped: $(while IFS= read -r pid; do
        jq -r --argjson p "$pid" '[.processes[] | select(.pid == $p) | .name] | first // "?" | "\(.) (\($p))"' <<<"$json"; done <<<"$moved" | paste -sd, - | sed 's/,/, /g')"

    # Swarm members: own-user processes working outside any repo whose command line grants a repo with
    # `--add-dir` (every value up to the next flag; ps splits on spaces, so a path with one is missed)
    # sit in git's repo for the last such folder. Pids that started after Saur0n's read are left out.
    # A member is a process tree (the driver's zsh wrapper, then `claude`, both carrying the flags): the
    # count is of trees, the check of every process in them.
    local verified="" members ppid args dir add_root member_root
    while IFS=$'\t' read -r pid ppid args; do
        dir=$(awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }' <<<"$cwds")
        [[ -n $dir && -z $(git_root "$dir") ]] || continue
        add_root=""
        while IFS= read -r dir; do
            root=$(git_root "$dir")
            [[ -z $root ]] || add_root=$root
        done < <(awk '{ for (i = 1; i <= NF; i++) { if ($i == "--add-dir") take = 1; else if ($i ~ /^--add-dir=/) { take = 0; print substr($i, 11) }
                        else if ($i ~ /^-/) take = 0; else if (take) print $i } }' <<<"$args")
        [[ -n $add_root ]] || continue
        member_root=$(awk -F'\t' -v p="$pid" '$1 == p { print ($2 == "" ? "none" : $2); exit }' <<<"$shown")
        [[ -n $member_root ]] || continue
        if ((window)); then
            member_root=${member_root%% (*}; member_root=${member_root%% }    # the group title's repo name
            add_root=$(basename "$add_root")
        fi
        [[ $member_root == "$add_root" ]] ||
            { echo "repo-groups: FAIL — swarm member pid $pid (--add-dir $add_root) reads repo root '$member_root'"; return 1; }
        verified+="$pid $ppid"$'\n'
    done < <(ps -U "$(id -u)" -ww -o pid=,ppid=,args= |
             awk '/ --add-dir[ =]/ { pid = $1; ppid = $2; sub(/^ *[0-9]+ +[0-9]+ /, ""); print pid "\t" ppid "\t" $0 }')
    members=$(awk 'NF { pid[$1] = 1; parent[$1] = $2 } END { for (p in pid) if (!(parent[p] in pid)) n++; print n + 0 }' <<<"$verified")
    if [[ $members -gt 0 ]]; then
        summary+="; $members swarm members ($(grep -c . <<<"$verified") processes) under their project's repo"
    else
        summary+="; no swarm member running"
    fi
    ((window == 0 || members >= 2)) ||
        { echo "repo-groups: FAIL — $members swarm members running; the window check needs at least 2 (start a two-member /swarm wave first)"; return 1; }

    local claude session_id label shown_session
    claude=$(check_claude_session)
    if [[ -z $claude ]]; then
        echo "SKIP session: not under Claude Code"
    else
        IFS=$'\t' read -r session_id label <<<"$claude"
        if ((window)); then
            # The window shows the session's label on each row, and its group in the By session view.
            local by_session
            for pid in "${repo_pids[@]}"; do
                shown_session=$(jq -r --argjson p "$pid" '[.processes[] | select(.pid == $p) | .session.name // "none"] | first // "absent"' <<<"$json")
                [[ $shown_session == "$label" ]] ||
                    { echo "repo-groups: FAIL — load pid $pid reads session '$shown_session', want '$label'"; return 1; }
            done
            read_window group-by session || { echo "repo-groups: FAIL — cannot turn the window to By session"; return 1; }
            # Under the loads, session groups reorder by CPU between refreshes and one coherent read in ~3
            # can fail its 5 tries (probe 2026-10-19), so the read gets 3 attempts and the reader's own reason.
            local attempt
            for attempt in 1 2 3; do
                by_session=$(read_window snapshot --expand "$label" 2>"$repo_dir/by-session.err") && break
            done ||
                { read_window group-by repo; echo "repo-groups: FAIL — cannot read the By session group '$label': $(tail -1 "$repo_dir/by-session.err")"; return 1; }
            read_window group-by repo || { echo "repo-groups: FAIL — cannot turn the window back to By repo"; return 1; }
            jq -e --arg n "$label" --argjson a "${repo_pids[0]}" --argjson b "${repo_pids[1]}" \
                '[.sessionGroups[] | select(.name == $n and (.pids | index($a)) and (.pids | index($b)))] | length == 1' <<<"$by_session" >/dev/null ||
                { echo "repo-groups: FAIL — no one session group named '$label' holds both loads"; return 1; }
            summary+="; both loads in Claude Code session '$label' (window: label only)"
        else
        for pid in "${repo_pids[@]}"; do
            shown_session=$(jq -r --argjson p "$pid" '[.processes[] | select(.pid == $p) | .session | if . == null then "none" else "\(.kind)\t\(.id)\t\(.name)" end] | first // "absent"' <<<"$json")
            [[ $shown_session == "claude"$'\t'"$session_id"$'\t'"$label" ]] ||
                { echo "repo-groups: FAIL — load pid $pid reads session '${shown_session//$'\t'/ | }', want 'claude | $session_id | $label'"; return 1; }
        done
        jq -e --arg n "$label" --argjson a "${repo_pids[0]}" --argjson b "${repo_pids[1]}" \
            '[.sessionGroups[] | select(.name == $n and (.pids | index($a)) and (.pids | index($b)))] | length == 1' <<<"$json" >/dev/null ||
            { echo "repo-groups: FAIL — no one session group named '$label' holds both loads"; return 1; }
        summary+="; both loads in Claude Code session '$label'"
        fi
    fi

    local started=("${repo_pids[@]}")
    stop_repo_groups
    for pid in "${started[@]}"; do
        ! kill -0 "$pid" 2>/dev/null || { echo "repo-groups: FAIL — load pid $pid still runs after cleanup"; return 1; }
    done
    repo_pids=()
    echo "repo-groups: ok ($( ((window)) && echo "window: ")$summary)"
}

# exited-cpu's parents, the long load's pid file and grandchild, and the mktemp folder. Globals for the traps.
exited_pids=() exited_dir=""

# Whether pid $1 still runs the check's own load binary — the long load is not the check's child, so
# once it exits its pid may be reused (phase 3 gate round 1).
runs_exited_load() {
    [[ -n $exited_dir && $(ps -ww -o comm= -p "$1" 2>/dev/null) == "$exited_dir/bin/probe-load" ]]
}

# Kill exactly the processes the check started (the long load's pid once its parent wrote it, while it
# still runs the load), then remove the folder — only when it is the one mktemp made.
stop_exited_cpu() {
    local pid
    if [[ -n $exited_dir && -s $exited_dir/grandchild.pid ]]; then
        pid=$(cat "$exited_dir/grandchild.pid")
        ! runs_exited_load "$pid" || exited_pids+=("$pid")
    fi
    for pid in ${exited_pids[@]+"${exited_pids[@]}"}; do kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null || true; done
    [[ -n $exited_dir ]] || return 0
    [[ $exited_dir == "$(dirname "$(mktemp -u)")"/tmp.* && -d $exited_dir ]] && rm -rf -- "$exited_dir"
    exited_dir=""
}

# Children user + system seconds from the last `times` the stream's parent appended to file $1.
children_seconds() {
    tail -n 1 "$1" | awk '{ s = 0; for (i = 1; i <= 2; i++) { split($i, p, "m"); sub(/s$/, "", p[2]); s += p[1] * 60 + p[2] } printf "%.3f", s }'
}

# Ask the stream's parent $1 for its `times` into file $2 and wait for the new lines (it answers once
# its current ~30 ms load exits).
stream_times() {
    local before tries=0
    before=$(wc -l <"$2")
    kill -USR1 "$1"
    until (($(wc -l <"$2") >= before + 2)); do
        ((++tries <= 100)) || return 1
        sleep 0.02
    done
}

# (1) A parent shell working in a throwaway repo runs a stream of ~30 ms C loads, each exiting: the
# parent's exitedChildrenCpuPercent and its repo group's each carry at least 80% of the stream's share
# of the machine, as the shell's own `times` measures it over Saur0n's run. (2) A second parent's
# child reaps a long load (4 s of CPU) started 2.5 s before the window, then exits inside it: the
# parent is charged no more than the load's in-window part (+0.25 s), not its whole life.
check_exited_cpu() {
    local json ncpu real bin pid t0 t1 c0 c1 stream want shown group g0 long_cpu limit charged summary
    build
    trap 'stop_exited_cpu; trap - RETURN EXIT' RETURN EXIT
    trap 'stop_exited_cpu; exit 1' INT TERM HUP
    exited_dir=$(mktemp -d)
    probe_git init -q -b main "$exited_dir/probe-repo" ||
        { echo "exited-cpu: FAIL — could not make the probe repo"; return 1; }
    real=$(cd "$exited_dir/probe-repo" && pwd -P)
    # Busy for $1 seconds of its own CPU (default 0.03), and never past 10 s of wall time.
    bin=$exited_dir/bin/probe-load
    mkdir -p "$exited_dir/bin"
    printf '%s\n' '#include <stdlib.h>' '#include <time.h>' \
        'int main(int c, char **v) { double s = c > 1 ? atof(v[1]) : 0.03; time_t wall = time(0) + 10;' \
        '  clock_t end = clock() + (clock_t)(s * CLOCKS_PER_SEC); while (clock() < end && time(0) < wall) {} return 0; }' |
        cc -O0 -x c -o "$bin" - || { echo "exited-cpu: FAIL — cc could not build the load"; return 1; }
    : >"$exited_dir/times"
    ncpu=$(sysctl -n hw.logicalcpu)

    # The stream: loads one after another for 20 s; `times` on USR1.
    (cd "$real" && LOAD=$bin TIMES=$exited_dir/times exec bash -c \
        'trap "times >>\"\$TIMES\"" USR1; end=$((SECONDS + 20)); while ((SECONDS < end)); do "$LOAD"; done') &
    exited_pids+=($!)
    # The long load under a child shell that waits for it, then exits; the parent outlives the window.
    # `; true` keeps bash from exec'ing `sleep` in its place: exec resets reaped-children time.
    (cd "$real" && LOAD=$bin PIDFILE=$exited_dir/grandchild.pid exec bash -c \
        'sh -c "\"\$LOAD\" 4 & echo \$! >\"\$PIDFILE\"; wait"; sleep 8; true') &
    exited_pids+=($!)
    sleep 2.5
    [[ -s $exited_dir/grandchild.pid ]] || { echo "exited-cpu: FAIL — the long load did not start"; return 1; }
    g0=$(ps_seconds "$(cat "$exited_dir/grandchild.pid")")

    stream_times "${exited_pids[0]}" "$exited_dir/times" || { echo "exited-cpu: FAIL — the stream's parent did not answer"; return 1; }
    c0=$(children_seconds "$exited_dir/times"); t0=$(now)
    json=$(saur0n --json --interval 3)
    stream_times "${exited_pids[0]}" "$exited_dir/times" || { echo "exited-cpu: FAIL — the stream's parent did not answer"; return 1; }
    c1=$(children_seconds "$exited_dir/times"); t1=$(now)

    stream=$(awk -v c0="$c0" -v c1="$c1" -v t0="$t0" -v t1="$t1" -v n="$ncpu" 'BEGIN { printf "%.2f", 100 * (c1 - c0) / ((t1 - t0) * n) }')
    awk -v s="$stream" 'BEGIN { exit !(s > 0) }' || { echo "exited-cpu: FAIL — the stream used no CPU ($c0 → $c1 s)"; return 1; }
    want=$(awk -v s="$stream" 'BEGIN { printf "%.2f", 0.8 * s }')
    pid=${exited_pids[0]}
    shown=$(jq -r --argjson p "$pid" '[.processes[] | select(.pid == $p) | .exitedChildrenCpuPercent // "null"] | first // "absent"' <<<"$json")
    awk -v x="$shown" -v w="$want" 'BEGIN { exit !(x + 0 == x && x >= w) }' ||
        { echo "exited-cpu: FAIL — the stream's parent (pid $pid) reads exited '$shown'%, want at least $want% (stream $stream%)"; return 1; }
    group=$(jq -r --argjson p "$pid" '[.repoGroups[] | select(.name == "probe-repo" and (.pids | index($p))) | .exitedChildrenCpuPercent] | first // "absent"' <<<"$json")
    awk -v x="$group" -v w="$want" 'BEGIN { exit !(x + 0 == x && x >= w) }' ||
        { echo "exited-cpu: FAIL — group probe-repo reads exited '$group'%, want at least $want% (stream $stream%)"; return 1; }
    summary="stream $stream% of the machine; its parent $shown%, group probe-repo $group% (want ≥ $want%)"

    pid=$(cat "$exited_dir/grandchild.pid")
    ! jq -e --argjson p "$pid" 'any(.processes[]; .pid == $p)' <<<"$json" >/dev/null ||
        { echo "exited-cpu: FAIL — the long load (pid $pid) was still running at the end of the window; machine too busy?"; return 1; }
    long_cpu=4
    limit=$(awk -v l="$long_cpu" -v g="$g0" 'BEGIN { printf "%.2f", l - g + 0.25 }')
    charged=$(jq -r --argjson p "${exited_pids[1]}" --argjson n "$ncpu" \
        '[.processes[] | select(.pid == $p) | (.exitedChildrenCpuPercent // "null")] | first // "absent"
         | if type == "number" then . * 3 * $n / 100 else . end' <<<"$json")
    awk -v c="$charged" -v l="$limit" 'BEGIN { exit !(c + 0 == c && c > 0 && c <= l) }' ||
        { echo "exited-cpu: FAIL — the long load's grandparent (pid ${exited_pids[1]}) is charged '$charged' s, want more than 0 and at most $limit s (4 s load, $g0 s used before the window)"; return 1; }
    summary+="; long load charged $(printf '%.2f' "$charged") s of its 4 s (≤ $limit s in the window)"

    local started=("${exited_pids[@]}") load=$pid dir=$exited_dir
    stop_exited_cpu
    for pid in "${started[@]}"; do
        ! kill -0 "$pid" 2>/dev/null || { echo "exited-cpu: FAIL — pid $pid still runs after cleanup"; return 1; }
    done
    [[ $(ps -ww -o comm= -p "$load" 2>/dev/null) != "$dir/bin/probe-load" ]] ||
        { echo "exited-cpu: FAIL — the long load (pid $load) still runs after cleanup"; return 1; }
    exited_pids=()
    echo "exited-cpu: ok ($summary)"
}

# Starts the swarm wave command $1 (none: nothing to do) in the background and returns once two swarm members
# (processes with `--add-dir`) run. The wave is left to finish on its own; this check does not own its processes.
start_members() {
    [[ -n $1 ]] || return 0
    bash -c "$1" >/dev/null 2>&1 &
    local tries=0
    until (( $(ps -U "$(id -u)" -ww -o args= | grep -c -- ' --add-dir[ =]') >= 2 )); do
        ((++tries <= 120)) || { echo "$check: FAIL — no two swarm members within 60 s of starting the wave"; return 1; }
        sleep 0.5
    done
}

# The own and reaped-children CPU seconds of pid $1, "<own> <children>", from `proc_pid_rusage(RUSAGE_INFO_V4)`
# (Command Line Tools' Python, ctypes only). `ps` time leaves the children out (`ps -S` adds none on macOS), and
# the `ps`, `top` and `tmux` the app runs are part of its cost.
rusage_seconds() {
    python3 -I -c '
import ctypes, sys
class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
tb = Timebase()
ctypes.CDLL("/usr/lib/libSystem.dylib").mach_timebase_info(ctypes.byref(tb))
words = (ctypes.c_uint64 * 64)()    # rusage_info_v4 is 37 words
if ctypes.CDLL("/usr/lib/libproc.dylib").proc_pid_rusage(int(sys.argv[1]), 4, ctypes.byref(words)) != 0:
    sys.exit(1)
seconds = lambda units: units * tb.numer / tb.denom / 1e9
# Words: ri_uuid (0-1), ri_user_time, ri_system_time (2-3), ..., ri_child_user_time, ri_child_system_time (12-13).
print("%.4f %.4f" % (seconds(words[2] + words[3]), seconds(words[12] + words[13])))' "$1"
}

# Saur0n.app's cost at its 1-second refresh: launched from the bundle, after its first process refresh, its own
# CPU plus its reaped children's over 60 s, as a share of every CPU over the same wall time. Under 1% passes.
# OVERHEAD_MEMBERS_CMD=<command> starts a swarm wave once the app is up, and the 60 s start once two members run
# (the wave keeps running after, for `repo-groups --window` next).
check_overhead() {
    local cpus own0 kids0 own1 kids1 t0 t1 share own kids total secs members
    trap 'stop_window' EXIT
    trap 'stop_window; exit 1' INT TERM HUP
    window=1
    window_up 1 || return 1
    # The graph that draws the most: one line per core and per type (Backlog window-graph-area-space).
    open_graph cpu || return 1
    start_members "${OVERHEAD_MEMBERS_CMD:-}" || return 1
    members=$(ps -U "$(id -u)" -ww -o args= | grep -c -- ' --add-dir[ =]' || true)
    cpus=$(sysctl -n hw.logicalcpu)
    read -r own0 kids0 < <(rusage_seconds "$app_pid") || { echo "overhead: FAIL — cannot read the app's CPU time"; return 1; }
    t0=$(now)
    sleep "${OVERHEAD_SECONDS:-60}"
    read -r own1 kids1 < <(rusage_seconds "$app_pid") || { echo "overhead: FAIL — the app (pid $app_pid) is gone"; return 1; }
    t1=$(now)
    share=$(awk -v a="$own0" -v b="$own1" -v c="$kids0" -v d="$kids1" -v t0="$t0" -v t1="$t1" -v n="$cpus" \
        'BEGIN { w = (t1 - t0) * n; printf "%.3f %.3f %.3f %.0f", 100 * (b - a) / w, 100 * (d - c) / w, 100 * (b - a + d - c) / w, t1 - t0 }')
    read -r own kids total secs <<<"$share"
    local summary="$total% of the machine over $secs s: app $own%, its ps/top/tmux/nettop $kids%; $members swarm member processes running at the start"
    awk -v t="$total" 'BEGIN { exit !(t < 1) }' || { echo "overhead: FAIL — $summary; budget under 1%"; return 1; }
    echo "overhead: ok ($summary)"
}

# The layout check's search target: a process named s0search, built here (a copied system binary is killed for its
# signature, and a symlink still reads as its target's name), started and stopped by its recorded pid. Globals for
# the EXIT trap.
search_pid="" search_dir=""
# The layout check's sleep that ends to leave a greyed row, by its recorded pid; a global for the EXIT trap.
gone_pid=""

start_search_target() {
    search_dir=$(mktemp -d)
    echo 'int pause(void); int main(void) { for (;;) pause(); }' | cc -x c - -o "$search_dir/s0search" 2>/dev/null ||
        { echo "$check: FAIL — cannot build the search target"; return 1; }
    "$search_dir/s0search" &
    search_pid=$!
}

stop_search() {
    [[ -z $search_pid ]] || { kill "$search_pid" 2>/dev/null || true; wait "$search_pid" 2>/dev/null || true; }
    search_pid=""
    [[ -z $gone_pid ]] || { kill "$gone_pid" 2>/dev/null || true; wait "$gone_pid" 2>/dev/null || true; }
    gone_pid=""
    [[ -z $search_dir ]] || { rm -f "$search_dir/s0search"; rmdir "$search_dir" 2>/dev/null || true; }
    search_dir=""
}

# The layout check's CPU spikes (the Phase 6 gate's round 1): a C busy loop under a long fixed name, so its name is cut
# on the graph, one copy per CPU for 3 s per burst. Globals for the EXIT trap; only the recorded pids are stopped.
spike_dir="" spike_pids=()
spike_burner=saur0n-layout-check-spike-burner

start_spikes() {
    spike_dir=$(mktemp -d /tmp/saur0n-spike.XXXXXX)
    printf 'int main(void) { for (;;) {} }\n' | cc -x c - -o "$spike_dir/$spike_burner" ||
        { echo "layout: FAIL — cannot build the spike burner"; return 1; }
}

# burst: every CPU busy for 3 s with the burner, then each copy stopped by its pid.
burst() {
    local i cpus
    cpus=$(sysctl -n hw.logicalcpu)
    for ((i = 0; i < cpus; i++)); do
        "$spike_dir/$spike_burner" &
        spike_pids+=($!)
    done
    sleep 3
    kill "${spike_pids[@]}" 2>/dev/null || true
    wait "${spike_pids[@]}" 2>/dev/null || true
    spike_pids=()
}

stop_spikes() {
    ((${#spike_pids[@]} == 0)) || { kill "${spike_pids[@]}" 2>/dev/null || true; wait "${spike_pids[@]}" 2>/dev/null || true; }
    spike_pids=()
    [[ -z $spike_dir ]] || { rm -f "$spike_dir/$spike_burner"; rmdir "$spike_dir" 2>/dev/null || true; }
    spike_dir=""
}

# Phase 4 Step 4 touchups read from the running window: at the default size, at the main display's width
# (every group closed, then open) and at the 802 × 580 minimum (640 × 360 before Phase 5 Step 3), the table is no wider than its view, shows no
# horizontal scroll bar and keeps its last row inside the view (touchups 3, 4), and every CPU and Memory
# value — group totals and process values — starts inside its header column (Backlog
# wide-window-group-row-alignment: closed groups' totals sat mid-Name after a resize); the toolbar button folds
# every group and then opens every group (5); the Cores row carries no percent text (2); a column header reads
# "Memory" and is wide enough for the title beside a sort indicator (7; 52 pt showed "Me…"). The window is the
# check's own copy of the app.
check_layout() {
    local out fails=0 size groups started_open
    trap 'stop_spikes; stop_search; stop_window' EXIT
    trap 'stop_spikes; stop_search; stop_window; exit 1' INT TERM HUP
    save_cores_state    # the minimum-size case below may close the user's Cores row; stop_window puts it back
    start_spikes || return 1
    start_search_target || return 1
    window_up 2 || return 1
    # expect <label> <json> <jq filter> <wanted>: prints a mismatch and counts it; never stops the check.
    expect() {
        local got
        got=$(jq -r "$3" <<<"$2")
        [[ $got == "$4" ]] || { echo "layout: $1 — expected $4, got $got"; ((++fails)); }
    }
    # fits <label> <json>: the three size checks, then every CPU and Memory cell of the rows read against
    # its header: "<id>@<x>" for each cell whose x lies outside [header x, header x + width).
    fits() {
        local misplaced
        expect "$1: table wider than its view" "$2" .tableWiderThanView false
        expect "$1: rows wider than the view (a sideways scroll)" "$2" .rowWiderThanView false
        expect "$1: last row inside the view when scrolled to the bottom" "$2" .lastRowVisible true
        expect "$1: rows read for cell positions" "$2" '.rows | length > 0' true
        # Disk and Network (Phase 5 Step 3): disk-<pid>, disk-group-<n>, disk-unattributed; network the same. A cell at
        # screen x 0 has no frame yet — reloaded by a refresh during the read (seen at loads 14–21 since the copy runs
        # behind the user's app, 2026-10-21) — and cannot be drawn there, the window being elsewhere: named, not failed.
        local unplaced
        unplaced=$(jq -r '[.rows[].cells[] | select(.x == 0) | .id] | join(" ")' <<<"$2")
        [[ -z $unplaced ]] || echo "layout: $1 — not laid out at the read (x 0), skipped: $unplaced"
        misplaced=$(jq -r '
            def column(t): .columns[] | select(.title == t);
            def outside(t; pattern): column(t) as $c | .rows[].cells[] | select(.x != 0)
                | select(.id | test(pattern)) | select(.x < $c.x or .x >= $c.x + $c.w) | "\(.id)@\(.x)";
            [outside("CPU"; "cpu$|^cpu-"), outside("Memory"; "memory$|^memory-"), outside("Disk"; "^disk-"),
             outside("Network"; "^network-")] | join(" ")' <<<"$2")
        [[ -z $misplaced ]] || { echo "layout: $1 — CPU, Memory, Disk and Network cells outside their header columns: $misplaced"; ((++fails)); }
        expect "$1: Disk and Network cells read" "$2" '[.rows[].cells[] | select(.id | test("^(disk|network)-"))] | length > 0' true
    }
    # The graph row (Backlog window-graph-area-space): its three cells read their figures; the CPU graph's Cores row
    # carries no percent text; then Disk & Network open for the rate headers and strips below.
    local spark_problem
    out=$(read_window spark) || return 1
    spark_problem=$(jq -r '.cells | [
        (if (.cpu.text // "" | test("^CPU [0-9.]+%$")) then empty else "CPU reads \(.cpu.text)" end),
        (if (.memory.text // "" | test("^Memory [0-9.]+ G of [0-9]+ G$")) then empty else "Memory reads \(.memory.text)" end),
        (if (.["disk-network"].text // "" | test("^Disk R .+ W .+ · Network In .+ Out .+$")) then empty
         else "Disk & Network reads \(.["disk-network"].text)" end)] | join("; ")' <<<"$out")
    [[ -z $spark_problem ]] || { echo "layout: graph row — $spark_problem"; ((++fails)); }
    open_graph cpu || return 1
    out=$(read_window layout) || return 1
    expect "percent texts on the Cores row" "$out" '.legendTexts | length' 0
    # Graph text (the Phase 6 gate's round 1, the user's "there is some overlap on the text": spike names over the first
    # title, the Performance title on two lines, spike lines running under the next graph). Two bursts of the burner
    # 12 s apart, once the window holds the 10 s a spike needs before it; then, at the default and the minimum size with
    # the CPU graph open, no title, spike name or spike line meets another and every title keeps to one line.
    local tries=0 named load_seen
    until (($(read_window state | jq '.refresh // 0') >= 12)); do
        ((++tries <= 40)) || { echo "layout: FAIL — no 12th refresh before the spikes"; return 1; }
        sleep 0.5
    done
    burst; sleep 9; burst; sleep 2
    out=$(read_window graph-text) || return 1
    named=$(jq '[.names[] | select(.id | startswith("spike-name-cpu-"))] | length' <<<"$out")
    load_seen=$(sysctl -n vm.loadavg | awk '{print $2}')
    # A spike line with no name read: the names are not where accessibility reads them; no line either: no spike (the
    # minute's median too high for one).
    ((named > 0)) || { echo "layout: no CPU spike name read after two bursts of every CPU ($(jq '[.lines[] | select(.id | startswith("spike-cpu-"))] | length' <<<"$out") CPU spike lines read, load $load_seen)"; ((++fails)); }
    local graph_sizes=""
    for size in default min; do
        if [[ $size == default ]]; then out=$(read_window layout) || return 1
        else out=$(read_window layout --min) || return 1; fi
        expect "$size size, CPU graph: graph texts that meet" "$out" '.graphText.overlaps | join(", ")' ""
        expect "$size size, CPU graph: titles over one line" "$out" '.graphText.tallTitles | join(", ")' ""
        # One size for every title (the user, 2026-10-25: "text size is still wonky", four sizes in one row).
        expect "$size size, CPU graph: titles in one size (their heights within 0.5 pt)" "$out" \
            '[.graphText.titles[].frame.h] | if max - min <= 0.5 then "one size" else "heights \(map(tostring) | join(" / ")) pt" end' "one size"
        expect "$size size, CPU graph: titles read" "$out" '[.graphText.titles[] | select(.id | startswith("core-type-"))] | length > 0' true
        graph_sizes+="$size $(jq '.window.w | round' <<<"$out") pt with $(jq '.graphText.names | length' <<<"$out") names and $(jq '.graphText.lines | length' <<<"$out") spike lines, "
    done
    open_graph disk-network || return 1
    out=$(read_window layout) || return 1
    fits "default size" "$out"
    # Paused, the grouping picker and the search field stay out of the overflow menu (Phase 6 Step 4, the picker's
    # segments "Repo / Sesh / Cmd"; Step 6, the Paused mark an icon).
    expect "default size, paused: the grouping picker in the toolbar" "$out" '.pausedToolbar | .paused and .grouping' true
    expect "default size, paused: the search field in the toolbar" "$out" .pausedToolbar.searchField true
    # A header's frame holds its column's spacing too; the widened case below expects PID 80 pt wider than this.
    local pid_header
    pid_header=$(jq '[.columns[] | select(.title == "PID") | .w] | first' <<<"$out")
    expect "a column header reads Memory" "$out" .memoryHeader true
    # "Memory" is 42.6 pt in the header font (11 pt system); the header cell pads 11 pt left and gives the sort
    # indicator its 9 pt plus 11 pt on the right (measured 2026-10-21 on a 69 pt cell showing "Me…").
    expect "Memory header wide enough for its title beside a sort indicator (≥ 74 pt)" "$out" \
        '[.columns[] | select(.title == "Memory") | .w >= 74] | first' true
    # The two rate graphs: each header parses ("Disk · R … · W …", "Network · In … · Out …") and each strip shows its
    # rows or its "nothing moved" text (Phase 5 Step 3).
    expect "Disk header parses" "$out" '.rates.diskTotal.readBytesPerSecond != null' true
    expect "Network header parses" "$out" '.rates.networkTotal.inBytesPerSecond != null' true
    expect "disk strip present" "$out" '(.strips.disk | length > 0) or .strips.diskEmpty' true
    expect "network strip present" "$out" '(.strips.network | length > 0) or .strips.networkEmpty' true
    expect "strip rows parse" "$out" '[.strips.disk[], .strips.network[] | select(.bytes == null)] | length' 0
    groups=$(jq .groups <<<"$out"); started_open=$(jq .openGroups <<<"$out")
    ((groups > 0)) || { echo "layout: FAIL — no groups in the table"; return 1; }
    # Stable rows (Backlog stable-rows-under-fixed-sort), with the groups as they open at launch: sorted by Name through
    # the header, three refreshes keep one order — a process that appears takes its place, one that exits stays — so
    # the rows two reads share come in the same order. Then CPU, highest first, so no gone line is left for the reads below.
    local orders=() order refresh=0 tries
    read_window sort Name || return 1
    while ((${#orders[@]} < 3)); do
        tries=0
        until (($(read_window state | jq .refresh) > refresh)); do
            ((++tries <= 20)) || { echo "layout: FAIL — no new refresh to read the row order from"; return 1; }
            sleep 0.5
        done
        order=$(read_window order) || return 1
        refresh=$(jq .refresh <<<"$order"); orders+=("$order")
    done
    local named_rows
    named_rows=$(jq -c '.rows | (map(startswith("group:")) | index(true)) as $s | .[$s + 1:]
        | (map(startswith("pid:")) | index(false) // length) as $e
        | [.[:$e][] | split(":")[2:] | join(":") | ascii_downcase]' <<<"${orders[0]}")
    expect "Name sort: first open group's rows by name (read: $(cut -c1-600 <<<"$named_rows"))" "$named_rows" \
        '. == sort and length > 0' true
    for i in 1 2; do
        expect "Name sort: rows shared by refreshes $((i)) and $((i + 1)) in the same order" \
            "$(jq -n --argjson a "${orders[i - 1]}" --argjson b "${orders[i]}" '{a: $a.rows, b: $b.rows}')" '
            [.a[] as $r | select(any(.b[]; . == $r)) | $r] as $x | [.b[] as $r | select(any(.a[]; . == $r)) | $r] as $y
            | $x == $y' true
    done
    # Greyed means ended (Phase 5 gate round 2): the check's own sleep, once ended, reads greyed in its place on a later
    # refresh; the toolbar's Refresh takes a reading at once and the greyed row is gone. Then Refresh while paused: one
    # reading, and the window stays paused.
    sleep 600 &
    gone_pid=$!
    # wait_order <jq filter on the order read>: reads `order` after each new refresh until the filter holds, ten reads at
    # most. Each read pauses the window, so reading again before a new refresh landed would starve the refresh loop.
    wait_order() {
        local reads=0 tries
        until order=$(read_window order) && refresh=$(jq .refresh <<<"$order") && [[ $(jq "$1" <<<"$order") == true ]]; do
            ((++reads < 10)) || return 1
            tries=0
            until (($(read_window state | jq '.refresh // 0') > refresh)); do
                ((++tries <= 20)) || return 1
                sleep 0.5
            done
        done
    }
    wait_order "any(.rows[]; startswith(\"pid:$gone_pid:\"))" ||
        { echo "layout: FAIL — the check's sleep $gone_pid never showed under the Name sort; groups and sleeps last read: $(jq -c '[.rows[] | select(test("group:|:sleep$"))]' <<<"$order" | cut -c1-1500)"; return 1; }
    local ended=$gone_pid
    kill "$gone_pid"; wait "$gone_pid" 2>/dev/null || true
    gone_pid=""
    wait_order "any(.rows[]; startswith(\"gone:$ended:\"))" ||
        { echo "layout: the ended sleep $ended never read greyed in place"; ((++fails)); }
    out=$(read_window refresh) || return 1
    expect "Refresh: a reading within 3 s" "$out" '.after > .before and .seconds < 3' true
    order=$(read_window order) || return 1
    expect "after Refresh: no row left for the ended sleep" "$order" "any(.rows[]; contains(\":$ended:\")) | not" true
    out=$(read_window refresh --paused) || return 1
    expect "Refresh while paused: one reading" "$out" '.after == .before + 1' true
    expect "Refresh while paused: no other reading in the 2 s after" "$out" '.later == .after' true
    expect "Refresh while paused: still paused" "$out" .paused true
    # Twice: a new column sorts ascending first; the second press gives the launch order, CPU highest first.
    read_window sort CPU && read_window sort CPU || return 1
    # Search (Backlog window-search): the check's own s0search typed into the field leaves one group, holding only it,
    # counted "1 of N processes"; emptied, every group comes back (within one: a session or repo can start or end in the
    # seconds between the two counts — 12 then 13 on 2026-10-21). The reader sets the field's text through
    # accessibility and never takes the user's focus; Escape is tried and reported, and lands only while Saur0n is the
    # active app (escape_note).
    local before_search escape_note
    before_search=$(read_window state | jq .groups) || return 1
    out=$(read_window search s0search) || return 1
    expect "search field reads what was set" "$out" .search s0search
    # The groups open as the filter lands, a moment after the field's text: up to five reads a second apart.
    local reads=0
    until out=$(read_window order) && jq -e "any(.rows[]; . == \"pid:$search_pid:s0search\")" <<<"$out" >/dev/null; do
        ((++reads < 5)) || break
        sleep 1
    done
    expect "search: the rows shown" "$out" '[.rows[] | select(startswith("group:") or startswith("pid:"))] | map(sub("^group:.*"; "group")) | join(" ")' \
        "group pid:$search_pid:s0search"
    expect "search: the group's count" "$out" '[.counts[]] | first | test("^1 of [0-9]+ processes$")' true
    out=$(read_window search --clear) || return 1
    expect "the search field empties" "$out" .search ""
    if [[ $(jq .escape <<<"$out") == true ]]; then escape_note="Escape emptied it"
    else escape_note="emptied through accessibility (Escape not tried: Saur0n was not the active app)"; fi
    out=$(read_window state) || return 1
    expect "emptied: every group back ($before_search before the search, $(jq .groups <<<"$out") after)" "$out" \
        ".groups - $before_search | fabs <= 1" true
    if ((started_open > 0)); then
        expect "button while groups are open" "$out" .foldButton "Collapse all"
        read_window fold || return 1
        sleep 0.5
    fi
    out=$(read_window state) || return 1
    expect "after Collapse all: open groups" "$out" .openGroups 0
    expect "after Collapse all: button" "$out" .foldButton "Expand all"
    # The wide window with every group closed: the case the user's screenshot showed.
    out=$(read_window layout --wide) || return 1
    fits "wide, groups closed" "$out"
    read_window fold || return 1
    sleep 0.5
    out=$(read_window state) || return 1
    expect "after Expand all: open groups" "$out" .openGroups "$(jq .groups <<<"$out")"
    expect "after Expand all: button" "$out" .foldButton "Collapse all"
    out=$(read_window layout --wide) || return 1
    fits "wide, groups open" "$out"
    out=$(read_window layout --min) || return 1
    fits "minimum size" "$out"
    # 802 pt at the default widths, plus a full-width scroll bar's 15 pt on a Mac that shows them (a mouse connected).
    local default_min
    default_min=$(jq '.window.w | round' <<<"$out")
    # At 802 pt the search field first fell into the toolbar's overflow menu (2026-10-21); Refresh must not push it.
    expect "minimum size: the search field in the toolbar" "$out" .searchField true
    expect "minimum size: the Refresh button in the toolbar" "$out" .refreshButton true
    expect "minimum size, paused: the grouping picker in the toolbar" "$out" '.pausedToolbar | .paused and .grouping' true
    # Paused at the minimum the search field stays: the Paused mark is an icon since Phase 6 Step 6 (Backlog
    # paused-toolbar-search-at-minimum-width; the "Paused" label pushed it into the overflow menu).
    expect "minimum size, paused: the search field in the toolbar" "$out" .pausedToolbar.searchField true
    # Phase 5 Step 4, still with every group open: Expand all opened the catch-alls' sub-groups too, and their cells
    # were held to the headers above; then one rows read checks the VMs group and each catch-all's lines.
    expect "after Expand all: sub-groups shown and all open" "$out" '.subgroups > 0 and .openSubgroups == .subgroups' true
    expect "sub-group cells read for positions" "$out" \
        '[.rows[].cells[] | select(.id | test("^subgroup-[0-9]+-[0-9]+-cpu$"))] | length > 0' true
    # The minimum height leaves the table room with any one graph open, or none (Backlog window-graph-area-space); the
    # Memory graph's strip parses while it is open. "Room" is the table's view at least five rows high: the header and
    # four rows. Disk & Network last, as the reads below want it.
    local graph min_heights=""
    for graph in none cpu memory disk-network; do
        open_graph "$graph" || return 1
        # The minimum is sized for the CPU graph with its Cores row closed; opened, the strips take the table's rows.
        if [[ $graph == cpu && $(cores_open) == true ]]; then press_cores_until false || return 1; fi
        out=$(read_window layout --min) || return 1
        fits "minimum size, $graph graph open" "$out"
        expect "minimum size, $graph graph open: the row reads it open" "$out" .spark.open "$graph"
        expect "minimum size, $graph graph open: the table's view holds its header and four rows" "$out" \
            '.scrollView.h >= 5 * .rows[0].frame.h' true
        min_heights+="$graph $(jq '.scrollView.h | floor' <<<"$out") pt, "
        if [[ $graph == memory ]]; then
            expect "memory graph header parses" "$out" '.memory.total | test("^Memory [0-9.]+ G of [0-9]+ G · [0-9.]+%$")' true
            expect "memory strip: rows that parse" "$out" '(.memory.top | length > 0) and ([.memory.top[] | select(.bytes == null)] | length == 0)' true
        fi
    done
    local rows problems vms="skipped (no VM running)"
    rows=$(read_window rows) || return 1
    if pgrep -x com.apple.Virtualization.VirtualMachine >/dev/null; then
        expect "a VMs group while a VM runs" "$rows" '[.repoGroups[] | select(.name == "VMs")] | length' 1
        expect "VM rows sit in the VMs group" "$rows" \
            '[.processes[] | select(.vm != null and .group != "VMs" and (.group == "Not in a repo" or .group == "System and other users"))] | length' 0
        vms="present"
    fi
    expect "Not in a repo has an app sub-group" "$rows" \
        '[.repoGroups[] | select(.name == "Not in a repo") | .subgroups[] | select(.name | test(" other process(es)?$") | not)] | length > 0' true
    expect "Not in a repo has an other line" "$rows" \
        '[.repoGroups[] | select(.name == "Not in a repo") | .subgroups[] | select(.name | test(" other process(es)?$"))] | length' 1
    # Each catch-all's shown CPU and memory against its sub-group lines plus its lifted bare rows (own + exited CPU),
    # within the rounding of every figure summed (0.05% each; half the memory text's last digit each); its count
    # against theirs; every member read sits under a sub-group or is a bare row, and each sub-group lists its count.
    problems=$(jq -r '
        def unit: if . < 1024 then 1 else (pow(1024; (log / (1024 | log) | floor))) as $u
            | (if . / $u < 9.95 then 0.1 else 1 end) * $u end;
        . as $all | .repoGroups[] | select(.name == "Not in a repo" or .name == "System and other users") | . as $g
        | [$all.processes[] | select(.group == $g.name and .subgroup == null)] as $bare
        | ([$g.subgroups[] | {cpu: .cpuPercent, mem: .residentBytes}] + [$bare[] | {cpu: (.cpuPercent + .exitedChildrenCpuPercent), mem: .residentBytes}]) as $parts
        | ($parts | map(.cpu) | add // 0) as $cpu | ($parts | map(.mem) | add // 0) as $mem
        | ((($parts | length) + ([$bare[] | select(.exitedChildrenCpuPercent > 0)] | length) + 1) * 0.05 + 1e-6) as $cpuTol
        | ((([$parts[] | .mem | unit] | add // 0) + ($g.residentBytes | unit)) / 2 + 1) as $memTol
        | (if ($g.subgroups | length) == 0 then "\($g.name): no sub-group lines" else empty end),
          (if (($cpu - $g.cpuPercent) | fabs) > $cpuTol then "\($g.name): CPU \($g.cpuPercent) vs its lines \($cpu)" else empty end),
          (if (($mem - $g.residentBytes) | fabs) > $memTol then "\($g.name): memory \($g.residentBytes) vs its lines \($mem)" else empty end),
          (if ([$g.subgroups[].count] | add // 0) + ($bare | length) != $g.count
           then "\($g.name): \($g.count) processes vs \([$g.subgroups[].count] | add // 0) in sub-groups and \($bare | length) bare" else empty end),
          ($g.subgroups[] | select(((.pids // []) | length) != .count) | "\($g.name) / \(.name): \(.count) shown, \((.pids // []) | length) read")
        ' <<<"$rows")
    [[ -z $problems ]] || { echo "layout: catch-all lines —"; sed 's/^/  /' <<<"$problems"; ((++fails)); }
    # Resizable columns (Backlog resizable-columns): a PID column widened to 120 pt, saved as a drag saves it, grows the
    # window's minimum by the 80 pt it gained (882 pt), and the table still fits there. The user's saved widths are put
    # back when the check ends. The drag itself is the user's: accessibility cannot drag a header divider.
    quit_app
    save_widths_state
    defaults write "$app_domain" columnWidths -data "$(printf '{"pid":120}' | xxd -p | tr -d '\n')"
    launch_app && wait_for_rows 2 || return 1
    out=$(read_window layout --min) || return 1
    fits "minimum size, PID widened to 120 pt" "$out"
    expect "minimum width with PID at 120 pt (80 pt over the default $default_min)" "$out" '.window.w | round' $((default_min + 80))
    # Within 3 pt: a header's frame carries a share of the spacing beside it, which moves a point or two with its
    # neighbours (55.5 pt at the defaults, 138 widened on 2026-10-21).
    expect "PID header 80 pt wider than at the defaults ($pid_header pt), within 3 pt" "$out" \
        "[.columns[] | select(.title == \"PID\") | (.w - $pid_header - 80) | fabs <= 3] | first" true
    local widened_min
    widened_min=$(jq '.window.w' <<<"$out")
    # The theme (Backlog window-theme). Picked in Settings (Saur0n ▸ Settings…), each theme reaches the open window at
    # once — Two-colour instead while the Mac's Increase contrast is on and the Settings box follows it — and so does
    # each appearance, System being the Mac's. Single-colour is not offered, and a saved `single-colour` (it left the
    # choice) opens in Ember & Steel. Then the app relaunched in each theme, in Dark and in Light: it opens in the saved
    # theme and appearance, the graph row reads its figures, and with each graph open the table fits at the minimum
    # size. The user's theme and appearance are put back when the check ends.
    quit_app
    restore_widths_state
    local id title mode themes_read=""
    launch_app && wait_for_rows 2 || return 1
    for title in Two-colour "Ember & Steel"; do
        case $title in Two-colour) id=two-colour ;; *) id=ember-steel ;; esac
        out=$(read_window settings "$title") || return 1
        expect "Settings: $title picked" "$out" ".themes[\"$title\"]" true
        expect "Settings: $title reaches the window" "$out" '"\(.window.themeChosen) \(.window.theme)"' "$id $(theme_shown "$id")"
    done
    expect "Settings: the themes offered" "$out" '.themes | keys | join(", ")' "Ember & Steel, Two-colour"
    for title in Dark Light System; do
        mode=$(tr '[:upper:]' '[:lower:]' <<<"$title")
        out=$(read_window settings "$title") || return 1
        expect "Settings: $title picked" "$out" ".appearances[\"$title\"]" true
        expect "Settings: $title reaches the window" "$out" .window.appearance "$(appearance_shown "$mode")"
    done
    expect "Settings: the high-contrast box reads" "$out" '.highContrast | type' boolean
    quit_app
    defaults write "$app_domain" theme -string single-colour
    launch_app && wait_for_rows 2 || return 1
    out=$(read_window state) || return 1
    expect "a saved single-colour opens in Ember & Steel" "$out" .themeChosen ember-steel
    for id in ember-steel-dark ember-steel-light two-colour-dark two-colour-light; do
        mode=${id##*-} id=${id%-*}
        quit_app
        defaults write "$app_domain" theme -string "$id"
        defaults write "$app_domain" appearance -string "$mode"
        launch_app && wait_for_rows 2 || return 1
        out=$(read_window state) || return 1
        expect "$id, $mode: the window opens in it" "$out" '"\(.themeChosen) \(.theme) \(.appearance)"' \
            "$id $(theme_shown "$id") $mode"
        id="$id, $mode"
        out=$(read_window spark) || return 1
        expect "$id: the graph row reads its figures" "$out" \
            '.cells | (.cpu.text | test("^CPU [0-9.]+%$")) and (.memory.text | test("^Memory [0-9.]+ G of [0-9]+ G$"))
             and (.["disk-network"].text | test("^Disk R .+ W .+ · Network In .+ Out .+$"))' true
        for graph in cpu memory disk-network; do
            open_graph "$graph" || return 1
            out=$(read_window layout --min) || return 1
            fits "$id, minimum size, $graph graph open" "$out"
        done
        expect "$id: rate headers parse" "$out" \
            '.rates.diskTotal.readBytesPerSecond != null and .rates.networkTotal.inBytesPerSecond != null' true
        themes_read+="$id, "
    done
    ((fails == 0)) || { echo "layout: FAIL — $fails mismatch(es) above"; return 1; }
    echo "layout: ok (with the CPU graph open and $named CPU spike(s) named (load $load_seen), no graph title, spike name or spike" \
         "line met another and every title kept to one line — ${graph_sizes%, };" \
         "table fits at the default, wide and minimum ($default_min × 420) sizes with no sideways scroll bar, the last row" \
         "in view and every CPU, Memory, Disk and Network cell under its header; Collapse all folded $groups groups and" \
         "Expand all opened them; sorted by Name the rows kept one order over three refreshes and its own ended sleep read" \
         "greyed in place until Refresh took a reading and dropped it; Refresh while paused took one reading and stayed paused;" \
         "the search field and Refresh in the toolbar at 802 pt; a search for its own process showed one group" \
         "holding only it, and emptying the field ($escape_note) brought every group back; no legend on the Cores row; a header reads Memory, $(jq '[.columns[] | select(.title == "Memory") | .w] | first' <<<"$out") pt wide;" \
         "both rate headers parse and both strips show; VMs group $vms; each catch-all's sub-group lines and bare rows sum" \
         "to its CPU, memory and count, every member read under one; the graph row's three cells read their figures, and" \
         "at the minimum the table fit with each graph open and none — its view ${min_heights%, }; with PID saved at" \
         "120 pt the minimum width was $widened_min pt and the table fit there; each theme and appearance picked in Settings" \
         "reached the open window, a saved single-colour opened in Ember & Steel, and relaunched in each" \
         "(${themes_read%, }) the row read its figures and the table fit at the" \
         "minimum with every graph open)"
}

# --- Disk (Phase 5 Step 1) ---

# disk-total's iostat and its output file. Globals for the EXIT trap, as in cpu-total.
iostat_pid="" iostat_out=""

stop_disk_total() {
    [[ -z $iostat_pid ]] || kill "$iostat_pid" 2>/dev/null || true
    [[ -z $iostat_out ]] || rm -f "$iostat_out"
}

# Problems with the snapshot's disk rows, one line each; empty when none: a row not read through libproc (another
# user's, or one whose task info failed) with a disk figure, or rows plus the unattributed line off the machine's
# rate in a direction (exact, unless the rows hold more than the machine — page-cached writes are charged to a
# process before they reach the disk — and the remainder is 0).
disk_rows_problem() {
    jq -r '
        ([.processes[] | select(.source != "libproc" and .disk != null) | .pid] | if length > 0 then
            "rows not read through libproc with a disk figure: \(map(tostring) | join(", "))" else empty end),
        (["read", "write"][] as $d | "\($d)BytesPerSecond" as $k
         | ([.processes[].disk[$k] // 0] | add) as $rows | .unattributedDisk[$k] as $rest | .disk[$k] as $machine
         | if $rows + $rest == $machine or ($rest == 0 and $rows >= $machine) then empty
           else "\($d): rows \($rows) + unattributed \($rest) != machine \($machine)" end)' <<<"$1"
}

# The machine's disk rate against `iostat -d -w 1` over the same seconds. iostat is given the physical disks only
# (`diskutil list physical`): it lists mounted disk images too, which Saur0n leaves out. Its first row covers the
# time since boot; each later row covers the second up to when it printed (each line is stamped on arrival). Saur0n's JSON gives the wall-clock times
# of its two machine disk reads (`disk.windowStart`, `disk.windowEnd`), and its rate is compared with iostat's rows
# weighted by how much of each that window overlaps. Disk load here swings by hundreds of MB/s from one second to
# the next, so a window guessed from outside the process fails (2026-10-21: 4 of 5 over Saur0n's whole run, 4 of 8
# from the end of its first `ps`).
# iostat's MB/s is reads plus writes in units of 2^20 bytes (its since-boot total matches the registry counters
# divided so). Within 20% or 5 MB/s, whichever is larger. Then the rows: `ps` and `top` rows show no disk figure,
# and the rows plus the unattributed line make the machine's rate (disk_rows_problem).
check_disk_total() {
    local disks json saur0n_mb iostat_mb diff tolerance problem ts te tries=0
    build    # outside the timed window
    trap 'stop_disk_total; trap - RETURN EXIT INT' RETURN EXIT
    trap 'echo "disk-total: interrupted"; exit 130' INT
    # shellcheck disable=SC2207    # disk names hold no spaces
    disks=($(diskutil list physical | awk '/^\/dev\/disk[0-9]+ / { sub("/dev/", "", $1); print $1 }'))
    ((${#disks[@]} > 0)) || { echo "disk-total: FAIL — diskutil lists no physical disk"; return 1; }
    iostat_out=$(mktemp)
    # Each line is stamped with the wall-clock time it arrived: a row covers the second from the line before it to
    # its own stamp. Process substitution keeps $! on iostat itself, so the trap stops it, not the stamper.
    iostat -d -w 1 -c 30 "${disks[@]}" > >(perl -MTime::HiRes=time -ne '$| = 1; printf "%.3f %s", time, $_' >"$iostat_out") &
    iostat_pid=$!
    until (($(wc -l <"$iostat_out") >= 3)); do
        ((++tries <= 250)) || { echo "disk-total: FAIL — iostat printed no first row within 5 s"; return 1; }
        sleep 0.02
    done
    json=$(saur0n --json --interval 2)
    ts=$(jq '.disk.windowStart // empty' <<<"$json")
    te=$(jq '.disk.windowEnd // empty' <<<"$json")
    [[ -n $ts && -n $te ]] || { echo "disk-total: FAIL — Saur0n's JSON has no disk.windowStart / windowEnd"; return 1; }
    tries=0
    until awk -v te="$te" '$1 >= te { found = 1 } END { exit !found }' "$iostat_out"; do
        ((++tries <= 250)) || { echo "disk-total: FAIL — iostat stopped printing rows"; return 1; }
        sleep 0.02
    done
    kill "$iostat_pid" 2>/dev/null || true
    wait "$iostat_pid" 2>/dev/null || true
    iostat_pid=""    # reaped: its pid may be reused
    iostat_mb=$(awk -v ts="$ts" -v te="$te" 'NR >= 4 {
            lo = prev; hi = $1
            a = lo > ts ? lo : ts; b = hi < te ? hi : te
            if (b > a) { mb = 0; for (i = 4; i <= NF; i += 3) mb += $i; s += mb * (b - a); w += b - a }
        } { prev = $1 } END { if (w > 0) printf "%.2f", s / w }' "$iostat_out")
    [[ -n $iostat_mb ]] || { echo "disk-total: FAIL — no iostat row overlaps the Saur0n run"; return 1; }
    saur0n_mb=$(jq '(.disk.readBytesPerSecond + .disk.writeBytesPerSecond) / 1048576 * 100 | round / 100' <<<"$json")
    diff=$(awk -v a="$saur0n_mb" -v b="$iostat_mb" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.2f", d }')
    tolerance=$(awk -v b="$iostat_mb" 'BEGIN { t = 0.2 * b; printf "%.2f", (t > 5 ? t : 5) }')
    local summary="saur0n $saur0n_mb MB/s (read $(jq .disk.readBytesPerSecond <<<"$json") B/s, write $(jq .disk.writeBytesPerSecond <<<"$json") B/s), iostat $iostat_mb MB/s over ${disks[*]} across Saur0n's $(awk -v a="$ts" -v b="$te" 'BEGIN { printf "%.1f", b - a }') s, diff $diff (within $tolerance)"
    awk -v d="$diff" -v t="$tolerance" 'BEGIN { exit !(d <= t) }' ||
        { echo "disk-total: FAIL — machine rate off iostat: $summary"; return 1; }
    problem=$(disk_rows_problem "$json")
    [[ -z $problem ]] || { echo "disk-total: FAIL — $problem ($summary)"; return 1; }
    summary+="; $(jq '[.processes[] | select(.source != "libproc")] | length' <<<"$json") ps and top rows show no disk figure; rows plus unattributed (read $(jq .unattributedDisk.readBytesPerSecond <<<"$json"), write $(jq .unattributedDisk.writeBytesPerSecond <<<"$json") B/s) make the machine's rate"
    echo "disk-total: ok ($summary)"
}

# disk-load's writer: `dd`, the pipe feeding it and its folder (the pipe and the file it writes). Globals for the
# EXIT trap, as in cpu-total.
dd_pid="" feeder_pid="" load_dir=""

# Stops the feeder, then dd (the feeder's `head`, if still writing, ends on the closed pipe), and removes the two
# files and their folder by name.
stop_disk_load() {
    local pid
    for pid in $feeder_pid $dd_pid; do kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null || true; done
    feeder_pid="" dd_pid=""
    [[ -z $load_dir ]] || { rm -f "$load_dir/feed" "$load_dir/written"; rmdir "$load_dir" 2>/dev/null || true; }
}

# A known writer: `dd` writes 512 MiB of zeros into a temp file, read from a named pipe whose writer then sleeps, so
# dd stays alive for the second snapshot (alone it writes 512 MiB in under 0.1 s and exits; its rusage counts the
# bytes as it writes them, page cache or not — probe 2026-10-20 — less the last 8 MiB, which the flush is charged
# with: 504 of 512 MiB in every run, 2026-10-21). One snapshot before dd starts, one once the file
# is whole and `sync` has pushed it to the disk. dd's row's written bytes must be 512 MiB ± 10% (it is new between
# the two, so all of them), and the machine's written bytes rise by at least the 512 MiB written (plan's Acceptance).
check_disk_load() {
    local size=536870912 before after dd_written machine_written tries=0
    build
    trap 'stop_disk_load; trap - RETURN EXIT INT TERM HUP' RETURN EXIT
    trap 'echo "disk-load: interrupted"; exit 130' INT TERM HUP
    load_dir=$(mktemp -d)
    mkfifo "$load_dir/feed"
    before=$(saur0n --json --interval 1)
    (head -c "$size" /dev/zero; exec sleep 60) >"$load_dir/feed" &
    feeder_pid=$!
    dd if="$load_dir/feed" of="$load_dir/written" bs=1m 2>/dev/null &
    dd_pid=$!
    until (($(stat -f %z "$load_dir/written" 2>/dev/null || echo 0) >= size)); do
        ((++tries <= 1500)) || { echo "disk-load: FAIL — dd wrote $(stat -f %z "$load_dir/written" 2>/dev/null || echo 0) of $size bytes in 30 s"; return 1; }
        sleep 0.02
    done
    sync
    after=$(saur0n --json --interval 1)
    dd_written=$(jq --argjson pid "$dd_pid" '[.processes[] | select(.pid == $pid) | .disk.writeBytes] | first // empty' <<<"$after")
    [[ -n $dd_written ]] || { echo "disk-load: FAIL — the writer dd (pid $dd_pid) is not in Saur0n's process list"; return 1; }
    [[ $dd_written != null ]] || { echo "disk-load: FAIL — the writer dd (pid $dd_pid) has no disk figure"; return 1; }
    machine_written=$(( $(jq .disk.writeBytes <<<"$after") - $(jq .disk.writeBytes <<<"$before") ))
    local summary="dd wrote $dd_written bytes (want $size ± 10%), the machine $machine_written bytes (want at least $size)"
    awk -v w="$dd_written" -v s="$size" 'BEGIN { exit !(w >= 0.9 * s && w <= 1.1 * s) }' ||
        { echo "disk-load: FAIL — the writer's row: $summary"; return 1; }
    ((machine_written >= size)) || { echo "disk-load: FAIL — the machine total: $summary"; return 1; }
    echo "disk-load: ok ($summary)"
}

# --- Network (Phase 5 Step 2) ---

# network-total's netstat loop and its output file. Globals for the EXIT trap, as in cpu-total.
netstat_pid="" netstat_out=""

stop_network_total() {
    [[ -z $netstat_pid ]] || { kill "$netstat_pid" 2>/dev/null && wait "$netstat_pid" 2>/dev/null || true; }
    netstat_pid=""
    [[ -z $netstat_out ]] || rm -f "$netstat_out"
}

# Problems with the snapshot's network rows, one line each; empty when none: a row without a network figure (nettop
# lists root's processes too, and a process it does not list reads 0), or a group whose figures are not its members'
# sums, in either view.
network_rows_problem() {
    jq -r '
        ([.processes[] | select(.network == null) | .pid] | if length > 0 then
            "rows without a network figure: \(map(tostring) | join(", "))" else empty end),
        (INDEX(.processes[]; .pid) as $rows
         | ("repoGroups", "sessionGroups") as $view | .[$view][]? as $group
         | ("inBytesPerSecond", "outBytesPerSecond", "inBytes", "outBytes") as $k
         | ([$group.pids[] | $rows[tostring].network[$k]] | add // 0) as $sum
         | if $group.network[$k] == $sum then empty
           else "\($view) \($group.name): \($k) \($group.network[$k]) != members'"'"' \($sum)" end)' <<<"$1"
}

# The machine's network rate against `netstat -ib` over the same seconds and interfaces. A perl loop reads
# `netstat -ibn` every 0.25 s (without `-n` each read waits 5 s on name lookups here) and writes one line per read: the wall-clock time halfway through it and the summed
# `Ibytes` / `Obytes` of the `en<N>` link rows — the interfaces Saur0n counts. Saur0n's JSON gives the wall-clock
# times of its two machine reads (`network.windowStart`, `network.windowEnd`); its rate is compared, per direction,
# with the loop's interval rates weighted by how much of each the window overlaps (as disk-total). Within 20% or
# 1 MB/s, whichever is larger. Then its cumulative counters against netstat's interpolated at the window's end,
# within 0.1% or 10 MB: a 32-bit read wraps at 4 GB and would be off by a multiple of it (Phase 5 Step 2 sheet,
# Risks). Then the rows (network_rows_problem).
check_network_total() {
    local json ts te problem tries=0
    build    # outside the timed window
    trap 'stop_network_total; trap - RETURN EXIT INT' RETURN EXIT
    trap 'echo "network-total: interrupted"; exit 130' INT
    netstat_out=$(mktemp)
    perl -MTime::HiRes=time,sleep -e '$| = 1; for (1 .. 160) {
            my $t0 = time; my ($i, $o) = (0, 0);
            for (`netstat -ibn`) { my @f = split; if ($f[0] =~ /^en\d+$/ && $f[2] =~ /^<Link/) { $i += $f[6]; $o += $f[9] } }
            printf "%.3f %d %d\n", ($t0 + time) / 2, $i, $o; sleep 0.25 }' >"$netstat_out" &
    netstat_pid=$!
    until (($(wc -l <"$netstat_out") >= 2)); do
        ((++tries <= 250)) || { echo "network-total: FAIL — the netstat loop printed nothing within 5 s"; return 1; }
        sleep 0.02
    done
    json=$(saur0n --json --interval 2)
    ts=$(jq '.network.windowStart // empty' <<<"$json")
    te=$(jq '.network.windowEnd // empty' <<<"$json")
    [[ -n $ts && -n $te ]] || { echo "network-total: FAIL — Saur0n's JSON has no network.windowStart / windowEnd"; return 1; }
    tries=0
    until awk -v te="$te" '$1 >= te { found = 1 } END { exit !found }' "$netstat_out"; do
        ((++tries <= 250)) || { echo "network-total: FAIL — the netstat loop stopped printing"; return 1; }
        sleep 0.02
    done
    kill "$netstat_pid" 2>/dev/null || true
    wait "$netstat_pid" 2>/dev/null || true
    netstat_pid=""    # reaped: its pid may be reused
    # Reference in and out rates over the window, and the counters interpolated at its end.
    local ref_in ref_out end_in end_out
    read -r ref_in ref_out end_in end_out < <(awk -v ts="$ts" -v te="$te" '
        NR > 1 && $1 > pt {
            a = pt > ts ? pt : ts; b = $1 < te ? $1 : te
            if (b > a) { si += ($2 - pi) / ($1 - pt) * (b - a); so += ($3 - po) / ($1 - pt) * (b - a); w += b - a }
            if (pt <= te && $1 >= te) { f = (te - pt) / ($1 - pt); ei = pi + f * ($2 - pi); eo = po + f * ($3 - po) }
        } { pt = $1; pi = $2; po = $3 }
        END { if (w > 0) printf "%.0f %.0f %.0f %.0f\n", si / w, so / w, ei, eo }' "$netstat_out") || true
    [[ -n ${end_out:-} ]] || { echo "network-total: FAIL — no netstat read brackets the Saur0n run"; return 1; }
    local s_in s_out c_in c_out
    s_in=$(jq .network.inBytesPerSecond <<<"$json"); s_out=$(jq .network.outBytesPerSecond <<<"$json")
    c_in=$(jq .network.inBytes <<<"$json"); c_out=$(jq .network.outBytes <<<"$json")
    local summary="saur0n in $s_in B/s out $s_out B/s, netstat -ib in $ref_in B/s out $ref_out B/s over the en<N> interfaces across Saur0n's $(awk -v a="$ts" -v b="$te" 'BEGIN { printf "%.1f", b - a }') s"
    # Within 20% of netstat's or 1 MB/s (10^6 bytes, as the column's units), whichever is larger.
    awk -v a="$s_in" -v b="$ref_in" -v c="$s_out" -v d="$ref_out" 'function ok(x, r,  t) { t = 0.2 * r; if (t < 1e6) t = 1e6; return (x - r <= t && r - x <= t) }
        BEGIN { exit !(ok(a, b) && ok(c, d)) }' ||
        { echo "network-total: FAIL — machine rate off netstat: $summary"; return 1; }
    summary+="; counters in $c_in out $c_out, netstat's at the window's end in $end_in out $end_out"
    awk -v a="$c_in" -v b="$end_in" -v c="$c_out" -v d="$end_out" 'function ok(x, r,  t) { t = 0.001 * r; if (t < 1e7) t = 1e7; return (x - r <= t && r - x <= t) }
        BEGIN { exit !(ok(a, b) && ok(c, d)) }' ||
        { echo "network-total: FAIL — cumulative counters off netstat: $summary"; return 1; }
    problem=$(network_rows_problem "$json")
    [[ -z $problem ]] || { echo "network-total: FAIL — $problem ($summary)"; return 1; }
    summary+="; all $(jq '.processes | length' <<<"$json") rows carry a network figure and every group's is its members' sum"
    echo "network-total: ok ($summary)"
}

# network-load's pieces: the local server, the pipe holder, curl and their folder. Globals for the EXIT trap.
server_pid="" holder_pid="" curl_pid="" net_dir=""

# Stops curl, the holder and the server by recorded pid, then removes the folder's files by name.
stop_network_load() {
    local pid
    for pid in $curl_pid $holder_pid $server_pid; do kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null || true; done
    curl_pid="" holder_pid="" server_pid=""
    [[ -z $net_dir ]] || { rm -f "$net_dir/zeros" "$net_dir/hold" "$net_dir/port" "$net_dir/curl.out"; rmdir "$net_dir" 2>/dev/null || true; }
}

# A known download: `curl` fetches a file of known size — from SAUR0N_NET_URL when set, else 32 MiB of zeros from an
# HTTP/1.1 server the check runs on 127.0.0.1 — then moves on to reading a named pipe whose writer sleeps. nettop
# counts open sockets only (a process's bytes vanish once its sockets close; probe 2026-10-21), so curl must stay
# alive with its connection open for the second snapshot: it keeps the finished download's connection in its cache
# while it waits on the pipe. One snapshot before curl starts, one after the download is whole. curl's row must hold
# the file's size ± 5% in `inBytes` (new between the two, so all of it). The machine half follows the host's route:
# over `en<N>` the machine's `inBytes` rise by at least the size; over loopback (the default local server) or a
# tunnel it is skipped — a tunnel's packets cross the physical interface it rides on, so the machine total moves
# either way.
check_network_load() {
    local url host iface before after code size row machine tries=0
    build
    trap 'stop_network_load; trap - RETURN EXIT INT TERM HUP' RETURN EXIT
    trap 'echo "network-load: interrupted"; exit 130' INT TERM HUP
    net_dir=$(mktemp -d)
    mkfifo "$net_dir/hold"
    if [[ -n ${SAUR0N_NET_URL:-} ]]; then
        url=$SAUR0N_NET_URL
    else
        head -c 33554432 /dev/zero >"$net_dir/zeros"
        python3 -I -c 'import http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), lambda *a: H(*a, directory=sys.argv[1]))
print(s.server_address[1], flush=True)
s.serve_forever()' "$net_dir" >"$net_dir/port" 2>/dev/null &
        server_pid=$!
        until [[ -s $net_dir/port ]]; do
            ((++tries <= 250)) || { echo "network-load: FAIL — the local server did not start within 5 s"; return 1; }
            sleep 0.02
        done
        url="http://127.0.0.1:$(head -1 "$net_dir/port")/zeros"
    fi
    host=${url#*://}
    host=${host%%[/:]*}
    iface=$(route -n get "$host" 2>/dev/null | awk '/interface:/ { print $2 }')
    before=$(saur0n --json --interval 1)
    (exec sleep 120) >"$net_dir/hold" &
    holder_pid=$!
    # The write-out goes to stderr: curl holds stdout's buffer until it exits, and it must not exit.
    curl -s -o /dev/null -w '%{stderr}%{http_code} %{size_download}\n' "$url" -o /dev/null "file://$net_dir/hold" 2>"$net_dir/curl.out" &
    curl_pid=$!
    tries=0
    until [[ -s $net_dir/curl.out ]]; do
        kill -0 "$curl_pid" 2>/dev/null || { echo "network-load: FAIL — curl exited before the download finished ($url)"; return 1; }
        ((++tries <= 3000)) || { echo "network-load: FAIL — the download of $url took over 60 s"; return 1; }
        sleep 0.02
    done
    read -r code size <"$net_dir/curl.out"
    [[ $code == 200 && $size -gt 0 ]] || { echo "network-load: FAIL — $url answered $code with $size bytes"; return 1; }
    after=$(saur0n --json --interval 1)
    row=$(jq --argjson pid "$curl_pid" '[.processes[] | select(.pid == $pid) | .network.inBytes] | first // empty' <<<"$after")
    [[ -n $row ]] || { echo "network-load: FAIL — curl (pid $curl_pid) is not in Saur0n's process list"; return 1; }
    [[ $row != null ]] || { echo "network-load: FAIL — curl (pid $curl_pid) has no network figure"; return 1; }
    machine=$(jq .network.inBytes <<<"$after")
    machine=$((machine - $(jq .network.inBytes <<<"$before")))
    local summary="curl fetched $size bytes from $url over ${iface:-an unknown interface}; its row received $row (want $size ± 5%)"
    awk -v r="$row" -v s="$size" 'BEGIN { exit !(r >= 0.95 * s && r <= 1.05 * s) }' ||
        { echo "network-load: FAIL — curl's row: $summary"; return 1; }
    case $iface in
        en[0-9]*)
            summary+=", the machine $machine (want at least $size)"
            ((machine >= size)) || { echo "network-load: FAIL — the machine total: $summary"; return 1; } ;;
        lo0) summary+=", machine half skipped: loopback is not a physical interface (set SAUR0N_NET_URL for a host over en<N>)" ;;
        *) summary+=", machine half skipped: ${iface:-the route} is not an en<N> interface" ;;
    esac
    echo "network-load: ok ($summary)"
}

# --- Disk and network in the window (Phase 5 Step 3) ---

# One refresh of the window with every group open for the read (snapshot --expand each group by name), so every
# process row's disk and network cells are read and parsed (a cell that does not parse fails the read).
window_full_snapshot() {
    local names args=()
    names=$(read_window snapshot | jq -r '(.repoGroups // .sessionGroups)[].name') || return 1
    while IFS= read -r name; do [[ -z $name ]] || args+=(--expand "$name"); done <<<"$names"
    read_window snapshot "${args[@]}"
}

# Groups whose shown disk or network rate is not the sum of their members' shown rates, one line each; empty when
# none. Each shown figure is rounded to its unit's tenth (TextFormat.bytesPerSecondText), so the sum may be off by
# half a step per figure.
window_sums_problem() {
    jq -r '
        def half: if . == 0 then 0 elif . < 1000 then 0.5 elif . < 1e6 then 50 elif . < 1e9 then 5e4 else 5e7 end;
        def abs: if . < 0 then -. else . end;
        .processes as $rows | (.repoGroups // .sessionGroups)[] as $g | ("disk", "network") as $k
        | [$rows[] | select(.group == $g.name) | .[$k].bytesPerSecond // 0] as $members
        | ($members | add // 0) as $sum | $g[$k].bytesPerSecond as $shown
        | (([$members[] | half] | add // 0) + ($shown | half)) as $tolerance
        | if ($sum - $shown | abs) <= $tolerance then empty
          else "\($g.name): \($k) \($shown) B/s, members sum to \($sum) (± \($tolerance))" end' <<<"$1"
}

# Reads the window's graph headers $1 times one second apart into the file $2, one JSON line each (`read-window
# rates`: the rates and when the app took the reads behind them).
read_rates() {
    local i
    for ((i = 0; i < $1; i++)); do
        ((i == 0)) || sleep 1
        read_window rates >>"$2" || return 1
    done
}

# disk-total against the window: the Disk header's read + write rate over eight refreshes, each over the two machine
# reads the header's hint stamps, against `iostat -d -w 1` over the physical disks weighted by overlap with those
# same windows (as disk-total). The windows' time-weighted mean must be within 20% or 5 MB/s of iostat's over them.
# Then one refresh with every group open: every process row's Disk and Network cells parse, and each group's shown
# rates are its members' within rounding.
check_disk_total_window() {
    local disks rates windows result saur0n_mb iostat_mb span n diff tolerance snapshot problem tries=0
    trap 'stop_disk_total; stop_window; rm -f "${rates:-}"' EXIT
    trap 'echo "disk-total: interrupted"; exit 130' INT TERM HUP
    window_up 3 || return 1
    open_graph disk-network || return 1
    # shellcheck disable=SC2207    # disk names hold no spaces
    disks=($(diskutil list physical | awk '/^\/dev\/disk[0-9]+ / { sub("/dev/", "", $1); print $1 }'))
    ((${#disks[@]} > 0)) || { echo "disk-total: FAIL — diskutil lists no physical disk"; return 1; }
    iostat_out=$(mktemp) rates=$(mktemp)
    iostat -d -w 1 -c 40 "${disks[@]}" > >(perl -MTime::HiRes=time -ne '$| = 1; printf "%.3f %s", time, $_' >"$iostat_out") &
    iostat_pid=$!
    until (($(wc -l <"$iostat_out") >= 3)); do
        ((++tries <= 250)) || { echo "disk-total: FAIL — iostat printed no first row within 5 s"; return 1; }
        sleep 0.02
    done
    sleep 1.5    # the first window read must start after iostat's first stamped second
    read_rates 8 "$rates" || return 1
    windows=$(jq -r 'select(.diskTotal.windowStart != null) | .diskTotal
        | "\(.windowStart) \(.windowEnd) \(.readBytesPerSecond + .writeBytesPerSecond)"' "$rates" | sort -u)
    local last_end
    last_end=$(awk 'END { print $2 }' <<<"$windows")
    [[ -n $last_end ]] || { echo "disk-total: FAIL — the Disk header carried no read window"; return 1; }
    tries=0
    until awk -v te="$last_end" '$1 >= te { found = 1 } END { exit !found }' "$iostat_out"; do
        ((++tries <= 250)) || { echo "disk-total: FAIL — iostat stopped printing rows"; return 1; }
        sleep 0.02
    done
    kill "$iostat_pid" 2>/dev/null || true
    wait "$iostat_pid" 2>/dev/null || true
    iostat_pid=""
    result=$(awk 'FNR == NR { ws[++n] = $1; we[n] = $2; wr[n] = $3; next }
        FNR >= 4 {
            lo = prev; hi = $1; mb = 0; for (i = 4; i <= NF; i += 3) mb += $i
            for (k = 1; k <= n; k++) { a = lo > ws[k] ? lo : ws[k]; b = hi < we[k] ? hi : we[k]; if (b > a) { s += mb * (b - a); w += b - a } }
        } { prev = $1 }
        END { for (k = 1; k <= n; k++) { d = we[k] - ws[k]; ss += wr[k] / 1048576 * d; sw += d }
              if (w > 0 && sw > 0) printf "%.2f %.2f %.1f %d\n", ss / sw, s / w, sw, n }' <(echo "$windows") "$iostat_out")
    read -r saur0n_mb iostat_mb span n <<<"$result"
    [[ -n ${n:-} ]] || { echo "disk-total: FAIL — no iostat row overlaps the window's reads"; return 1; }
    ((n >= 5)) || { echo "disk-total: FAIL — only $n distinct refreshes in 8 reads"; return 1; }
    diff=$(awk -v a="$saur0n_mb" -v b="$iostat_mb" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.2f", d }')
    tolerance=$(awk -v b="$iostat_mb" 'BEGIN { t = 0.2 * b; printf "%.2f", (t > 5 ? t : 5) }')
    local summary="window $saur0n_mb MB/s, iostat $iostat_mb MB/s over ${disks[*]} across the window's $n refreshes ($span s), diff $diff (within $tolerance)"
    awk -v d="$diff" -v t="$tolerance" 'BEGIN { exit !(d <= t) }' ||
        { echo "disk-total: FAIL — the window's rate off iostat: $summary"; return 1; }
    snapshot=$(window_full_snapshot) || { echo "disk-total: FAIL — cannot read the table with every group open ($summary)"; return 1; }
    problem=$(window_sums_problem "$snapshot")
    [[ -z $problem ]] || { echo "disk-total: FAIL — $problem ($summary)"; return 1; }
    summary+="; all $(jq '.processes | length' <<<"$snapshot") rows' Disk and Network cells parse ($(jq '[.processes[] | select(.disk == null)] | length' <<<"$snapshot") show —) and every group's are its members' sums; unattributed disk $(jq '.unattributedDisk.bytesPerSecond' <<<"$snapshot") B/s"
    echo "disk-total: ok ($summary)"
}

# network-total against the window: the Network header's in and out rates over eight refreshes against the
# `netstat -ibn` loop of network-total over the en<N> interfaces, weighted by overlap with the header's stamped
# windows; each direction's time-weighted mean within 20% or 1 MB/s of netstat's. Then the rows, as disk-total.
check_network_total_window() {
    local rates windows result s_in s_out ref_in ref_out span n snapshot problem tries=0
    trap 'stop_network_total; stop_window; rm -f "${rates:-}"' EXIT
    trap 'echo "network-total: interrupted"; exit 130' INT TERM HUP
    window_up 3 || return 1
    open_graph disk-network || return 1
    netstat_out=$(mktemp) rates=$(mktemp)
    perl -MTime::HiRes=time,sleep -e '$| = 1; for (1 .. 160) {
            my $t0 = time; my ($i, $o) = (0, 0);
            for (`netstat -ibn`) { my @f = split; if ($f[0] =~ /^en\d+$/ && $f[2] =~ /^<Link/) { $i += $f[6]; $o += $f[9] } }
            printf "%.3f %d %d\n", ($t0 + time) / 2, $i, $o; sleep 0.25 }' >"$netstat_out" &
    netstat_pid=$!
    until (($(wc -l <"$netstat_out") >= 2)); do
        ((++tries <= 250)) || { echo "network-total: FAIL — the netstat loop printed nothing within 5 s"; return 1; }
        sleep 0.02
    done
    sleep 1.5    # the first window read must start after the loop's first read
    read_rates 8 "$rates" || return 1
    windows=$(jq -r 'select(.networkTotal.windowStart != null) | .networkTotal
        | "\(.windowStart) \(.windowEnd) \(.inBytesPerSecond) \(.outBytesPerSecond)"' "$rates" | sort -u)
    local last_end
    last_end=$(awk 'END { print $2 }' <<<"$windows")
    [[ -n $last_end ]] || { echo "network-total: FAIL — the Network header carried no read window"; return 1; }
    tries=0
    until awk -v te="$last_end" '$1 >= te { found = 1 } END { exit !found }' "$netstat_out"; do
        ((++tries <= 250)) || { echo "network-total: FAIL — the netstat loop stopped printing"; return 1; }
        sleep 0.02
    done
    kill "$netstat_pid" 2>/dev/null || true
    wait "$netstat_pid" 2>/dev/null || true
    netstat_pid=""    # reaped: its pid may be reused
    result=$(awk 'FNR == NR { ws[++n] = $1; we[n] = $2; wi[n] = $3; wo[n] = $4; next }
        FNR > 1 && $1 > pt {
            for (k = 1; k <= n; k++) { a = pt > ws[k] ? pt : ws[k]; b = $1 < we[k] ? $1 : we[k]
                if (b > a) { si += ($2 - pi) / ($1 - pt) * (b - a); so += ($3 - po) / ($1 - pt) * (b - a); w += b - a } }
        } { pt = $1; pi = $2; po = $3 }
        END { for (k = 1; k <= n; k++) { d = we[k] - ws[k]; ti += wi[k] * d; to += wo[k] * d; sw += d }
              if (w > 0 && sw > 0) printf "%.0f %.0f %.0f %.0f %.1f %d\n", ti / sw, to / sw, si / w, so / w, sw, n }' \
        <(echo "$windows") "$netstat_out") || true
    read -r s_in s_out ref_in ref_out span n <<<"$result"
    [[ -n ${n:-} ]] || { echo "network-total: FAIL — no netstat read overlaps the window's reads"; return 1; }
    ((n >= 5)) || { echo "network-total: FAIL — only $n distinct refreshes in 8 reads"; return 1; }
    local summary="window in $s_in B/s out $s_out B/s, netstat -ib in $ref_in B/s out $ref_out B/s over the en<N> interfaces across the window's $n refreshes ($span s)"
    awk -v a="$s_in" -v b="$ref_in" -v c="$s_out" -v d="$ref_out" 'function ok(x, r,  t) { t = 0.2 * r; if (t < 1e6) t = 1e6; return (x - r <= t && r - x <= t) }
        BEGIN { exit !(ok(a, b) && ok(c, d)) }' ||
        { echo "network-total: FAIL — the window's rate off netstat: $summary"; return 1; }
    snapshot=$(window_full_snapshot) || { echo "network-total: FAIL — cannot read the table with every group open ($summary)"; return 1; }
    problem=$(window_sums_problem "$snapshot")
    [[ -z $problem ]] || { echo "network-total: FAIL — $problem ($summary)"; return 1; }
    summary+="; all $(jq '.processes | length' <<<"$snapshot") rows' Network cells parse and every group's is its members' sum"
    echo "network-total: ok ($summary)"
}

# The window's shown row of pid $1 in the JSON line of `read-window rows`, as {disk, network}; empty when absent.
window_row() { read_window rows | jq -c --argjson pid "$1" '[.processes[] | select(.pid == $pid)] | first // empty'; }

# The strip entry $2 (disk or network) named $1, its minute's bytes; empty when the strip does not list it.
strip_bytes() { read_window strips | jq -r --arg name "$1" --arg kind "$2" '[.[$kind][] | select(.name == $name) | .bytes] | first // empty'; }

# The name the window shows for pid $1 (its readable name, else its name), from the CLI's own sample: the strips
# show that name, and the window's `rows` would pause it (strip_until).
shown_name() { saur0n --json --interval 0.5 | jq -r --argjson pid "$1" '[.processes[] | select(.pid == $pid) | .readableName // .name] | first // empty'; }

# strip_until <kind> <name> <bytes>: polls the strip for 20 s until it lists <name> with at least <bytes>; prints
# the bytes, or nothing.
strip_until() {
    local strip="" start
    start=$(date +%s)
    while [[ -z $strip ]] && (($(date +%s) - start <= 20)); do
        strip=$(strip_bytes "$2" "$1") || return 1
        [[ -z $strip ]] || awk -v b="$strip" -v w="$3" 'BEGIN { exit !(b >= w) }' || strip=""
        [[ -n $strip ]] || sleep 1
    done
    echo "$strip"
}

# Reading the rows pauses the window for ~40 s with every group open (1219 rows, 2026-10-21), and no refresh
# covers a pause, so the load checks read the strip first and the row last, while the load still runs on.

# disk-load against the window: dd writes 512 MiB fed from the named pipe as in disk-load, but in 32 MiB steps a
# second apart (16 s) — alone it writes the lot in under 0.1 s, inside one refresh — then 4 MiB a second for 90 s.
# Within 20 s of the 512 MiB, the disk strip must list dd with at least 90% of them for the minute (its rusage counts
# the bytes as it writes them, less the last 8 MiB the flush is charged with — disk-load); then, while dd still
# writes, its row (read by recorded pid) must show a non-zero Disk rate. The window has no cumulative counter, so the
# CLI check's "rose by 512 MiB" becomes the strip's minute (sheet: the --window load checks' shape).
check_disk_load_window() {
    local size=536870912 name row rate strip tries=0
    trap 'stop_disk_load; stop_window' EXIT
    trap 'echo "disk-load: interrupted"; exit 130' INT TERM HUP
    build
    window_up 2 || return 1
    open_graph disk-network || return 1
    load_dir=$(mktemp -d)
    mkfifo "$load_dir/feed"
    (for _ in $(seq 16); do head -c 33554432 /dev/zero; sleep 1; done
     for _ in $(seq 90); do head -c 4194304 /dev/zero; sleep 1; done; exec sleep 120) >"$load_dir/feed" &
    feeder_pid=$!
    dd if="$load_dir/feed" of="$load_dir/written" bs=1m 2>/dev/null &
    dd_pid=$!
    name=$(shown_name "$dd_pid")
    [[ -n $name ]] || { echo "disk-load: FAIL — the CLI does not list dd (pid $dd_pid)"; return 1; }
    until (($(stat -f %z "$load_dir/written" 2>/dev/null || echo 0) >= size)); do
        ((++tries <= 2000)) || { echo "disk-load: FAIL — dd wrote $(stat -f %z "$load_dir/written" 2>/dev/null || echo 0) of $size bytes in 40 s"; return 1; }
        sleep 0.02
    done
    sleep 2    # past the refresh that read dd's 512 MiB
    strip=$(strip_until disk "$name" $((size * 9 / 10))) || return 1
    [[ -n $strip ]] || { echo "disk-load: FAIL — the disk strip did not list dd (\"$name\") with at least 90% of $size bytes within 20 s ($(read_window strips | jq -c .disk))"; return 1; }
    row=$(window_row "$dd_pid") || return 1
    rate=$(jq -r 'select(.disk.bytesPerSecond > 0) | .disk.bytesPerSecond' <<<"${row:-null}")
    [[ -n $rate ]] || { echo "disk-load: FAIL — dd (pid $dd_pid) showed no disk rate in the window while it wrote (${row:-no row})"; return 1; }
    echo "disk-load: ok (the disk strip lists dd as \"$name\" with $strip bytes for the minute, want at least 90% of $size; its row showed $rate B/s while it wrote on)"
}

# network-load against the window: curl fetches the file as in network-load (the local server's 32 MiB of zeros, or
# SAUR0N_NET_URL) at most 2 MiB/s, so the download spans several refreshes, then fetches it twice more and holds its
# connection open on the pipe. Within 20 s of the first download's end, the network strip must list curl with at
# least 95% of the file's size for the minute; then, while the second or third download runs, its row (by recorded
# pid) must show a non-zero Network rate (strip first, row last: the rows read pauses the window).
check_network_load_window() {
    local url name row rate strip code size tries=0
    trap 'stop_network_load; stop_window' EXIT
    trap 'echo "network-load: interrupted"; exit 130' INT TERM HUP
    build
    window_up 2 || return 1
    open_graph disk-network || return 1
    net_dir=$(mktemp -d)
    mkfifo "$net_dir/hold"
    if [[ -n ${SAUR0N_NET_URL:-} ]]; then
        url=$SAUR0N_NET_URL
    else
        head -c 33554432 /dev/zero >"$net_dir/zeros"
        python3 -I -c 'import http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), lambda *a: H(*a, directory=sys.argv[1]))
print(s.server_address[1], flush=True)
s.serve_forever()' "$net_dir" >"$net_dir/port" 2>/dev/null &
        server_pid=$!
        until [[ -s $net_dir/port ]]; do
            ((++tries <= 250)) || { echo "network-load: FAIL — the local server did not start within 5 s"; return 1; }
            sleep 0.02
        done
        url="http://127.0.0.1:$(head -1 "$net_dir/port")/zeros"
    fi
    (exec sleep 120) >"$net_dir/hold" &
    holder_pid=$!
    curl -s --limit-rate 2M -w '%{stderr}%{http_code} %{size_download}\n' -o /dev/null "$url" -o /dev/null "$url" \
        -o /dev/null "$url" -o /dev/null "file://$net_dir/hold" 2>"$net_dir/curl.out" &
    curl_pid=$!
    name=$(shown_name "$curl_pid")
    [[ -n $name ]] || { echo "network-load: FAIL — the CLI does not list curl (pid $curl_pid)"; return 1; }
    tries=0
    until [[ -s $net_dir/curl.out ]]; do
        kill -0 "$curl_pid" 2>/dev/null || { echo "network-load: FAIL — curl exited before the download finished ($url)"; return 1; }
        ((++tries <= 2000)) || { echo "network-load: FAIL — the download of $url took over 40 s"; return 1; }
        sleep 0.02
    done
    read -r code size <"$net_dir/curl.out"
    [[ $code == 200 && $size -gt 0 ]] || { echo "network-load: FAIL — $url answered $code with $size bytes"; return 1; }
    sleep 2    # past the refresh that read the first download's last bytes
    strip=$(strip_until network "$name" $((size * 95 / 100))) || return 1
    [[ -n $strip ]] || { echo "network-load: FAIL — the network strip did not list curl (\"$name\") with at least 95% of $size bytes within 20 s of the download's end ($(read_window strips | jq -c .network))"; return 1; }
    (($(wc -l <"$net_dir/curl.out") < 3)) || { echo "network-load: FAIL — curl's three downloads ended before its row was read ($url)"; return 1; }
    row=$(window_row "$curl_pid") || return 1
    rate=$(jq -r 'select(.network.bytesPerSecond > 0) | .network.bytesPerSecond' <<<"${row:-null}")
    [[ -n $rate ]] || { echo "network-load: FAIL — curl (pid $curl_pid) showed no network rate in the window while it downloaded (${row:-no row})"; return 1; }
    echo "network-load: ok (curl fetched $size bytes from $url; the network strip lists curl as \"$name\" with $strip bytes for the minute, want at least 95%; its row showed $rate B/s while it downloaded again)"
}

# --- Quit, Force Quit, Pause and Resume from the window (Phase 5 Step 5) ---

# The children kill and dependants start, each stopped by recorded pid on every way out (resumed first, in case it
# was left paused). Globals for the EXIT trap.
control_pids="" control_dir=""

stop_control() {
    local pid
    for pid in $control_pids; do
        kill -CONT "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    control_pids=""
    [[ -z $control_dir ]] || {
        rm -f "$control_dir/pids" "$control_dir/port" "$control_dir/small" "$control_dir/hold" "$control_dir/curl1.out" \
            "$control_dir/curl2.out"
        rmdir "$control_dir" 2>/dev/null || true
        control_dir=""
    }
}

# pid $1's row as the window shows it ({pid, cpuPercent, paused, …}), or null.
shown_row() { read_window row "$1" | jq -c .row; }

# The window's refresh count, without pausing it.
refresh_now() { read_window state | jq .refresh; }

# Waits until the window applied two refreshes after refresh $1 (at most 10 s).
two_refreshes_after() {
    local tries=0
    until (($(refresh_now) >= $1 + 2)); do
        ((++tries <= 100)) || { echo "$check: FAIL — the window did not refresh twice after refresh $1 in 10 s"; return 1; }
        sleep 0.1
    done
}

# Waits for pid $1's row to show (a process started after the window's last refresh), reading it after each two new
# refreshes, five times at most: a `row` read pauses the window, and the sample after a pause applies nothing, so
# back-to-back reads would hold every refresh.
row_shown() {
    local tries=0
    until [[ $(shown_row "$1") != null ]]; do
        ((++tries <= 5)) || { echo "$check: FAIL — pid $1 has no row in the window after 10 refreshes"; return 1; }
        two_refreshes_after "$(refresh_now)" || return 1
    done
}

# act <action> <pid> [--cancel] through the reader; the sheet as JSON. A confirm the window refused fails here.
act_window() {
    local out
    out=$(read_window act "$@") || {
        # On stderr: callers send the sheet to /dev/null. With where the CLI files the process, since a row the window
        # does not show is one in a group it holds closed.
        echo "$check: FAIL — act $* did not run; the CLI files pid $2 as $(.build/release/saur0n --json --interval 1 |
            jq -c --argjson p "$2" '[.processes[] | select(.pid == $p) | {ppid, orphaned, cpuPercent, repo: .repo.name,
            session: .session.name}] | first')" >&2
        return 1
    }
    if [[ $# -eq 2 && $(jq -r '.error // empty' <<<"$out") != "" ]]; then
        echo "$check: FAIL — act $* was refused: $(jq -r .error <<<"$out")" >&2; return 1
    fi
    echo "$out"
}

# Child $1 of this shell ended by signal $2 (TERM or KILL): no longer running (a zombie until reaped), then its
# exit status names the signal.
ended_by() {
    local stat status=0
    stat=$(ps -o stat= -p "$1" 2>/dev/null || true)
    [[ -z $stat || $stat == Z* ]] || { echo "$check: FAIL — pid $1 still runs (state $stat)"; return 1; }
    wait "$1" 2>/dev/null || status=$?
    control_pids=$(tr ' ' '\n' <<<"$control_pids" | grep -vx "$1" | tr '\n' ' ' || true)
    ((status == 128 + $(kill -l "$2"))) || { echo "$check: FAIL — pid $1 exited with $status, not by SIG$2"; return 1; }
}

# kill --window: two `sleep 600` children; Quit on the first cancelled leaves both; Quit confirmed ends the first by
# SIGTERM — its row gone within two refreshes — and leaves the second; a third ended by Force Quit (SIGKILL) the same
# way; a busy `yes` paused reads "paused" with 0.0% CPU within two refreshes, and resumed runs again with no badge.
# Every child by recorded pid; nothing else is touched.
check_kill() {
    local a b c busy out r row
    trap 'stop_control; stop_window' EXIT
    trap 'echo "kill: interrupted"; exit 130' INT TERM HUP
    sleep 600 & a=$!
    sleep 600 & b=$!
    control_pids="$a $b"
    window_up 2 || return 1
    row_shown "$a" || return 1
    out=$(act_window quit "$a" --cancel) || return 1
    [[ $(jq -r .title <<<"$out") == "Quit sleep" && $(jq -r .confirmTitle <<<"$out") == Quit ]] ||
        { echo "kill: FAIL — the Quit sheet for sleep (pid $a) reads $out"; return 1; }
    kill -0 "$a" 2>/dev/null && kill -0 "$b" 2>/dev/null || { echo "kill: FAIL — a child ended after Cancel"; return 1; }
    r=$(refresh_now)
    act_window quit "$a" >/dev/null || return 1
    two_refreshes_after "$r" || return 1
    [[ $(shown_row "$a") == null ]] || { echo "kill: FAIL — pid $a still has a row two refreshes after Quit"; return 1; }
    ended_by "$a" TERM || return 1
    kill -0 "$b" 2>/dev/null || { echo "kill: FAIL — Quit on pid $a also ended pid $b"; return 1; }

    sleep 600 & c=$!
    control_pids="$control_pids $c"
    row_shown "$c" || return 1
    out=$(act_window force-quit "$c" --cancel) || return 1
    [[ $(jq -r .warning <<<"$out") == "Unsaved work in it is lost." ]] || { echo "kill: FAIL — the Force Quit sheet reads $out"; return 1; }
    r=$(refresh_now)
    act_window force-quit "$c" >/dev/null || return 1
    two_refreshes_after "$r" || return 1
    [[ $(shown_row "$c") == null ]] || { echo "kill: FAIL — pid $c still has a row two refreshes after Force Quit"; return 1; }
    ended_by "$c" KILL || return 1
    kill -0 "$b" 2>/dev/null || { echo "kill: FAIL — Force Quit on pid $c ended pid $b"; return 1; }

    yes >/dev/null & busy=$!
    control_pids="$control_pids $busy"
    row_shown "$busy" || return 1
    # Counted from the confirm: the refresh under way then still covers time the process ran.
    act_window pause "$busy" >/dev/null || return 1
    two_refreshes_after "$(refresh_now)" || return 1
    row=$(shown_row "$busy")
    [[ $(jq -r '.paused and .cpuPercent == 0' <<<"$row") == true ]] ||
        { echo "kill: FAIL — yes (pid $busy) two refreshes after Pause reads $row (want paused, 0.0% CPU)"; return 1; }
    [[ $(ps -o stat= -p "$busy") == T* ]] || { echo "kill: FAIL — yes (pid $busy) is not stopped ($(ps -o stat= -p "$busy"))"; return 1; }
    local paused_row=$row
    act_window resume "$busy" >/dev/null || return 1
    two_refreshes_after "$(refresh_now)" || return 1
    row=$(shown_row "$busy")
    [[ $(jq -r '(.paused | not) and .cpuPercent > 0' <<<"$row") == true ]] ||
        { echo "kill: FAIL — yes (pid $busy) two refreshes after Resume reads $row (want no badge, CPU above 0)"; return 1; }

    # The Process menu acts on the selection, and the selection stays on the process selected while the table re-sorts
    # (Phase 6 Step 7's demo: "i selected Resilio, but it cycled as the list got reordered"): a fourth `sleep` is
    # selected, four busy `yes` start in its group and sort above it, and two refreshes on the selection is still that
    # sleep's row. The right-click menu itself cannot be driven from here: opened through accessibility, the reader's
    # calls stalled for minutes and then found no menu (2026-10-24, twice). Every process by recorded pid.
    local target selected i
    sleep 600 & target=$!
    control_pids="$control_pids $target"
    row_shown "$target" || return 1
    read_window select "$target" >/dev/null || { echo "kill: FAIL — cannot select sleep $target"; return 1; }
    r=$(refresh_now)
    for i in 1 2 3 4; do
        yes >/dev/null &
        control_pids="$control_pids $!"
    done
    two_refreshes_after "$r" || return 1
    selected=$(read_window selected | jq -c .selected)
    [[ $selected == "[\"name-$target\"]" ]] ||
        { echo "kill: FAIL — selected sleep $target, four busy processes sorted above it, and the selection is now $selected"; return 1; }
    echo "kill: ok (Cancel left sleep $a and $b running; Quit ended $a by SIGTERM and its row was gone within two refreshes, $b untouched; Force Quit ended $c by SIGKILL the same way; yes $busy paused read $(jq -c '{paused, cpuPercent}' <<<"$paused_row"), resumed $(jq -c '{paused, cpuPercent}' <<<"$row"); sleep $target selected, four busy processes sorted above it, the selection still $selected)"
}

# dependants --window: a shell with two `sleep 600` children lists both under "Also ends" and confirms "Quit all 3";
# a lone `sleep 600` reads "Nothing else depends on it" and "Quit"; a local HTTP server the check starts on 127.0.0.1
# lists the two `curl`s that hold a connection to it under "Used by (TCP)" — each fetched a small file and then reads a
# named pipe, so its kept-alive connection stays open (network-load's holder shape) — and still reads "Quit": clients
# are named, not signalled. All cancelled; every process by recorded pid. Never a server the check did not start.
check_dependants() {
    local shell lone out kids server holder curl1 curl2 port tries=0
    trap 'stop_control; stop_window' EXIT
    trap 'echo "dependants: interrupted"; exit 130' INT TERM HUP
    control_dir=$(mktemp -d)
    bash -c 'sleep 600 & echo $!; sleep 600 & echo $!; wait' >"$control_dir/pids" & shell=$!
    sleep 600 & lone=$!
    control_pids="$shell $lone"
    until [[ $(wc -l <"$control_dir/pids") -ge 2 ]]; do sleep 0.05; done
    kids=$(tr '\n' ' ' <"$control_dir/pids")
    control_pids="$kids$control_pids"    # the shell's children first, so stop_control ends them before it
    window_up 2 || return 1
    row_shown "$shell" || return 1
    out=$(act_window quit "$shell" --cancel) || return 1
    [[ $(jq '[.alsoEnds[] | select((.name | startswith("sleep")) and (.kind == "shell" or .kind == "process"))] | length' <<<"$out") == 2 &&
       $(jq '.alsoEnds | length' <<<"$out") == 2 && $(jq -r .confirmTitle <<<"$out") == "Quit all 3" ]] ||
        { echo "dependants: FAIL — the sheet for bash (pid $shell, children $kids) reads $out"; return 1; }
    local shell_sheet=$out
    row_shown "$lone" || return 1
    out=$(act_window quit "$lone" --cancel) || return 1
    [[ $(jq '.alsoEnds | length' <<<"$out") == 0 && $(jq -r .nothingElse <<<"$out") == true && $(jq -r .confirmTitle <<<"$out") == Quit ]] ||
        { echo "dependants: FAIL — the sheet for the lone sleep (pid $lone) reads $out"; return 1; }
    local lone_sheet=$out

    head -c 1024 /dev/zero >"$control_dir/small"
    mkfifo "$control_dir/hold"
    python3 -I -c 'import http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), lambda *a: H(*a, directory=sys.argv[1]))
print(s.server_address[1], flush=True)
s.serve_forever()' "$control_dir" >"$control_dir/port" 2>/dev/null &
    server=$!
    control_pids="$control_pids $server"
    until [[ -s $control_dir/port ]]; do
        ((++tries <= 250)) || { echo "dependants: FAIL — the local server did not start within 5 s"; return 1; }
        sleep 0.02
    done
    port=$(head -1 "$control_dir/port")
    # Each curl keeps its connection to the server while it waits on the pipe; the write-out goes to stderr, which
    # curl does not hold back.
    curl -s -o /dev/null -w '%{stderr}%{http_code}\n' "http://127.0.0.1:$port/small" -o /dev/null "file://$control_dir/hold" \
        2>"$control_dir/curl1.out" &
    curl1=$!
    curl -s -o /dev/null -w '%{stderr}%{http_code}\n' "http://127.0.0.1:$port/small" -o /dev/null "file://$control_dir/hold" \
        2>"$control_dir/curl2.out" &
    curl2=$!
    (exec sleep 600) >"$control_dir/hold" &
    holder=$!
    control_pids="$curl1 $curl2 $holder $control_pids"
    tries=0
    until [[ -s $control_dir/curl1.out && -s $control_dir/curl2.out ]]; do
        ((++tries <= 250)) || { echo "dependants: FAIL — the two curls did not fetch from the local server within 5 s"; return 1; }
        sleep 0.02
    done
    row_shown "$server" || return 1
    out=$(act_window quit "$server" --cancel) || return 1
    [[ $(jq '[.usedBy[] | select((.name | startswith("curl")) and .kind == "process")] | length' <<<"$out") == 2 &&
       $(jq '.usedBy | length' <<<"$out") == 2 && $(jq -r .confirmTitle <<<"$out") == Quit ]] ||
        { echo "dependants: FAIL — the sheet for the local server (pid $server on 127.0.0.1:$port, clients curl $curl1 and $curl2) reads $out"; return 1; }
    local server_sheet=$out
    for pid in $control_pids; do kill -0 "$pid" 2>/dev/null || { echo "dependants: FAIL — pid $pid ended after Cancel"; return 1; }; done
    echo "dependants: ok (bash $shell: $(jq -c '{alsoEndsHeading, alsoEnds, confirmTitle}' <<<"$shell_sheet"); lone sleep $lone: \"Nothing else depends on it\", $(jq -c '{confirmTitle}' <<<"$lone_sheet"); local server $server on 127.0.0.1:$port: $(jq -c '{usedBy, confirmTitle}' <<<"$server_sheet") for curl $curl1 and $curl2; all cancelled, all alive)"
}

# load's known launcher: perl starting `sh -c 'echo $$'` (one process a start, as `sh -c true`, each writing its own
# pid) about 100 times a second, and the file of those pids. Perl forks and execs `sh` itself, so the pacing adds no
# process (a `sleep` between starts would add one a start). Globals for the EXIT trap; only that pid is stopped.
launcher_pid="" launched_file=""

stop_load() {
    [[ -z $launcher_pid ]] || { kill "$launcher_pid" 2>/dev/null || true; wait "$launcher_pid" 2>/dev/null || true; }
    launcher_pid=""
    [[ -z $launched_file ]] || rm -f "$launched_file"
    launched_file=""
}

# Starts $1 known launches in the background, paced 10 ms apart; their pids go to $launched_file, and the loop's own
# start and end (epoch seconds) to its last line, "elapsed <start> <end>".
start_launcher() {
    launched_file=$(mktemp)
    perl -MTime::HiRes=time,sleep -e '
        my ($n, $out) = @ARGV; open(my $fh, ">>", $out) or die; my $t0 = time;
        for (1 .. $n) { system("sh", "-c", "echo \$\$ >>\"\$0\"", $out) == 0 or die; sleep 0.01 }
        printf $fh "elapsed %.3f %.3f\n", $t0, time;' "$1" "$launched_file" &
    launcher_pid=$!
}

# Waits for the launcher to finish and reaps it.
finish_launcher() {
    wait "$launcher_pid" || { launcher_pid=""; echo "load: FAIL — the launcher failed"; return 1; }
    launcher_pid=""
}

# uptime's three load averages, "<1> <5> <15>".
uptime_load() { uptime | sed -E 's/.*load averages?: *//; s/,//g'; }

# Whether each of Saur0n's three averages ($1, "<1> <5> <15>") is within 0.5 of the same figure in uptime's reading
# just before ($2) or just after ($3): the kernel recomputes them every 5 s, so one of the two brackets matches.
load_matches() {
    awk -v s="$1" -v a="$2" -v b="$3" 'BEGIN {
        split(s, x, " "); split(a, y, " "); split(b, z, " ")
        for (i = 1; i <= 3; i++) { d1 = x[i] - y[i]; d2 = x[i] - z[i]; if (d1 < 0) d1 = -d1; if (d2 < 0) d2 = -d2
                                   if (d1 > 0.5 && d2 > 0.5) exit 1 }
    }'
}

# Whether a shown launch count covers the check's own starts: "<known> <advance>" on stdout for the summary, and exit 0
# only when the count ($1) is the pid counter's whole advance from $2 to $3 (wrap-aware: pids run 100…99,998, then
# 100) and at least one of the launcher's pids lies inside that window — so every known start inside it is counted.
launches_cover() {
    grep -v '^elapsed' "$launched_file" | awk -v c="$1" -v f="$2" -v l="$3" '
        (f <= l && $1 > f && $1 <= l) || (f > l && ($1 > f || $1 <= l)) { n++ }
        END { a = f <= l ? l - f : (99998 - f) + (l - 100 + 1); print n + 0, a; exit !(n > 0 && c == a && c >= n) }'
}

# load (Phase 6 Step 2): a snapshot's load averages within 0.5 of `uptime` bracketing it and its user + system its
# total; then a 2-second snapshot while 400 known starts run (`sh -c 'echo $$'`, each writing its pid): the snapshot's
# count must be the pid counter's whole advance between its two `ps` pids, with the launcher's pids inside it, so every
# known start in the window is counted, whatever else the machine launches (the user, 2026-10-22: "yes proceed").
check_load() {
    local json before after load split total cover known advance rc count first last seconds summary
    build
    trap 'stop_load; trap - RETURN EXIT INT' RETURN EXIT
    trap 'echo "load: interrupted"; exit 130' INT
    before=$(uptime_load)
    json=$(saur0n --json --interval 2)
    after=$(uptime_load)
    load=$(jq -r '.loadAverage | "\(.oneMinute) \(.fiveMinutes) \(.fifteenMinutes)"' <<<"$json")
    [[ $load != "null null null" ]] || { echo "load: FAIL — Saur0n's JSON has no loadAverage"; return 1; }
    summary="Saur0n's load $load on $(jq .loadAverage.cpus <<<"$json") CPUs, uptime $before before and $after after"
    load_matches "$load" "$before" "$after" || { echo "load: FAIL — load average off uptime by more than 0.5: $summary"; return 1; }
    split=$(jq -r '"\(.userBusyPercent) \(.systemBusyPercent)"' <<<"$json")
    total=$(jq .totalBusyPercent <<<"$json")
    awk -v s="$split" -v t="$total" 'BEGIN { split(s, x, " "); d = x[1] + x[2] - t; if (d < 0) d = -d; exit !(d <= 0.15) }' ||
        { echo "load: FAIL — user + system ($split) is not the total $total"; return 1; }
    summary+="; user + system $split = total $total"
    start_launcher 400
    sleep 0.5    # the snapshot's first `ps` starts inside the launcher's run
    json=$(saur0n --json --interval 2)
    finish_launcher || return 1
    read -r count first last seconds < <(jq -r '.launches | "\(.count) \(.firstPid) \(.lastPid) \(.windowEnd - .windowStart)"' <<<"$json")
    [[ $count != null ]] || { echo "load: FAIL — Saur0n's JSON has no launches ($summary)"; return 1; }
    cover=$(launches_cover "$count" "$first" "$last") && rc=0 || rc=$?
    read -r known advance <<<"$cover"
    summary+="; launches $count ($(jq .launches.perSecond <<<"$json") a second) between pids $first and $last over $(printf '%.2f' "$seconds") s, the pids advanced $advance, $known of the 400 known starts inside"
    ((rc == 0)) || { echo "load: FAIL — the launch count does not cover the known starts: $summary"; return 1; }
    echo "load: ok ($summary)"
}

# load --window: the CPU graph's Load header within 0.5 of `uptime` bracketing the read; then, while 600 known starts
# run, three reads of the Launched header from the launcher's second second on: each read whose window holds the
# launcher's pids (its hint, "launches <count> pids <first> <last>") must count the pid counter's whole advance, and at
# least one must hold them. The app is launched in the background and its graph opened through accessibility, never
# activated (lesson window-probes-never-take-focus).
check_load_window() {
    local figures before after load reads=0 covered=0 cover known advance rc count first last summary i
    trap 'stop_load; stop_window' EXIT
    trap 'echo "load: interrupted"; exit 130' INT TERM HUP
    window_up 3 || return 1
    open_graph cpu || return 1
    before=$(uptime_load)
    figures=$(read_window load) || { echo "load: FAIL — cannot read the CPU graph's figures"; return 1; }
    after=$(uptime_load)
    load=$(jq -r '.loadAverage | "\(.oneMinute) \(.fiveMinutes) \(.fifteenMinutes)"' <<<"$figures")
    [[ $load != "null null null" && $load != *null* ]] || { echo "load: FAIL — the Load header shows no figures: $figures"; return 1; }
    summary="window load $load on $(jq .loadAverage.cpus <<<"$figures") CPUs, uptime $before before and $after after"
    load_matches "$load" "$before" "$after" || { echo "load: FAIL — load average off uptime by more than 0.5: $summary"; return 1; }
    start_launcher 600
    sleep 2
    for ((i = 0; i < 3; i++)); do
        ((i == 0)) || sleep 1.5
        figures=$(read_window load) || { echo "load: FAIL — cannot read the Launched header"; return 1; }
        read -r count first last < <(jq -r '.launches | "\(.count) \(.firstPid) \(.lastPid)"' <<<"$figures")
        [[ $count != null ]] || { echo "load: FAIL — the Launched header carries no launch window: $figures"; return 1; }
        ((++reads))
        cover=$(launches_cover "$count" "$first" "$last") && rc=0 || rc=$?
        read -r known advance <<<"$cover"
        summary+="; read $reads: $count launches between pids $first and $last (advance $advance), $known known inside"
        if ((known > 0)); then
            ((rc == 0)) || { echo "load: FAIL — the window's launch count does not cover the known starts: $summary"; return 1; }
            ((++covered))
        fi
    done
    finish_launcher || return 1
    ((covered > 0)) || { echo "load: FAIL — no read's window held any of the known starts: $summary"; return 1; }
    echo "load: ok ($summary)"
}

# --- copies (Phase 6 Step 4): a script copying itself reads as one command group at the top ---

# The copies' scratch folder (left in /tmp) and the script every copy runs. Globals for the EXIT trap; only the pids
# the copies recorded, still running a command that names the folder, are ever stopped.
copies_dir="" copies_count=30
copies_script_name=saur0n-copies.sh

# Starts $copies_count copies of one script, each orphaned to launchd at birth as the 2026-10-22 copies were (a
# subshell that exits at once), so no script of this check owns them. Each copy starts one throttled busy child (a
# perl loop busy $1 of each 100 ms, about $1 of one core) and records "<its pid> <the child's pid>". Waits until all
# have recorded, at most 10 s.
start_copies() {
    local i tries=0
    copies_dir=$(mktemp -d /tmp/saur0n-copies.XXXXXX)
    printf '%s\n' '#!/bin/bash' \
        '# One copy: a busy child, both pids recorded, then wait for it.' \
        "perl -MTime::HiRes=time,sleep -e 'my \$d = shift; while (1) { my \$t = time + 0.1 * \$d; 1 while time < \$t; sleep 0.1 * (1 - \$d) }' \"\$2\" \"\$0\" &" \
        'echo "$$ $!" >>"$1"' \
        'wait' >"$copies_dir/$copies_script_name"
    for ((i = 0; i < copies_count; i++)); do
        (nohup bash "$copies_dir/$copies_script_name" "$copies_dir/pids" "$1" >/dev/null 2>&1 &)
    done
    until [[ -f $copies_dir/pids && $(wc -l <"$copies_dir/pids") -ge $copies_count ]]; do
        ((++tries <= 100)) || { echo "copies: FAIL — only $(wc -l <"$copies_dir/pids" 2>/dev/null || echo 0) of $copies_count copies started"; return 1; }
        sleep 0.1
    done
}

# Every pid the copies recorded, one per line.
copies_pids() { [[ -f $copies_dir/pids ]] && tr ' ' '\n' <"$copies_dir/pids" | grep -E '^[0-9]+$'; }

# Stops each recorded pid whose command line still names the scratch folder (a reused pid names something else),
# continued first so a check that failed during Pause leaves nothing stopped.
stop_copies() {
    local pid
    [[ -n $copies_dir ]] || return 0
    for pid in $(copies_pids); do
        [[ $(ps -p "$pid" -o command= 2>/dev/null) == *"$copies_dir"* ]] && kill -CONT "$pid" 2>/dev/null &&
            kill "$pid" 2>/dev/null || true
    done
    copies_dir=""
}

# Whether JSON group $1 (`commandGroups[0]` from the CLI, or the window's first group) holds every recorded pid ($2,
# space-separated); the window gives no pids, so there its process count must be twice the copies.
copies_group_holds() {
    jq -e --argjson want "$(jq -nc --arg p "$2" '$p | split(" ") | map(select(. != "") | tonumber)')" \
        '(.pids // []) as $have | $want - $have == []' <<<"$1" >/dev/null
}

# copies: 30 copies of one script under launchd, each with a busy child at 20% of a core, read through
# `saur0n --json` as one command group named after the script, with 30 copies, every copy and child inside it, first
# under the CPU sort, and no group of their children; then the same group first in `--by command`'s table, titled
# "<script> × 30".
check_copies() {
    local json first pids summary title
    build
    trap 'stop_copies; trap - RETURN EXIT INT' RETURN EXIT
    trap 'echo "copies: interrupted"; exit 130' INT
    start_copies 0.2 || return 1
    pids=$(copies_pids | tr '\n' ' ')
    sleep 1    # each child's first busy second
    json=$(saur0n --json --interval 2)
    first=$(jq -c '.commandGroups[0] // empty' <<<"$json")
    [[ -n $first ]] || { echo "copies: FAIL — Saur0n's JSON has no commandGroups"; return 1; }
    summary="first group $(jq -r '"\(.name) × \(.copies), \(.pids | length) processes, \((.cpuPercent + .exitedChildrenCpuPercent) * 100 | round / 100)%"' <<<"$first")"
    summary+=", next $(jq -r '[.commandGroups[1:3][] | "\(.name) \((.cpuPercent + .exitedChildrenCpuPercent) * 100 | round / 100)%"] | join(", ")' <<<"$json")"
    [[ $(jq -r .name <<<"$first") == "$copies_script_name" ]] ||
        { echo "copies: FAIL — the copies are not the first command group: $summary"; return 1; }
    [[ $(jq .copies <<<"$first") -eq $copies_count ]] ||
        { echo "copies: FAIL — the group counts $(jq .copies <<<"$first") copies, not $copies_count: $summary"; return 1; }
    copies_group_holds "$first" "$pids" || { echo "copies: FAIL — the group lacks some of the copies or their children: $summary"; return 1; }
    ! jq -e '.commandGroups[] | select(.name == "perl")' <<<"$json" >/dev/null ||
        { echo "copies: FAIL — the children also form a 'perl' group: $summary"; return 1; }
    title=$(saur0n --by command --interval 1 | grep -m1 -E '^[^ ].*  [0-9.]+%  ' || true)
    [[ $title == "$copies_script_name × $copies_count  "* ]] ||
        { echo "copies: FAIL — --by command's first group reads '$title'"; return 1; }
    echo "copies: ok ($summary; table '$title')"
}

# copies --window: the same 30 copies, the window turned to "By command" without taking focus (lesson
# window-probes-never-take-focus) and read once its refresh count has advanced twice past the copies' start (a read
# before that sees a table without them): its first group is "<script> × 30" with 60 processes.
check_copies_window() {
    local snapshot first since summary
    trap 'stop_copies; stop_window' EXIT
    trap 'echo "copies: interrupted"; exit 130' INT TERM HUP
    window_up 3 || return 1
    read_window group-by command || { echo "copies: FAIL — cannot turn the window to By command"; return 1; }
    start_copies 0.2 || return 1
    since=$(read_window state | jq .refresh)
    wait_for_rows $((since + 3)) || return 1
    snapshot=$(read_window snapshot) || { echo "copies: FAIL — cannot read the window's table"; return 1; }
    [[ $(jq -r .grouping <<<"$snapshot") == command ]] || { echo "copies: FAIL — the window is not By command"; return 1; }
    first=$(jq -c '.commandGroups[0] // empty' <<<"$snapshot")
    summary="refresh $(jq .refresh <<<"$snapshot") (copies up at $since), first group $(jq -r '"\(.name), \(.count) processes, \(.cpuPercent)%"' <<<"$first")"
    summary+=", next $(jq -r '[.commandGroups[1:3][] | "\(.name) \(.cpuPercent)%"] | join(", ")' <<<"$snapshot")"
    [[ $(jq -r .name <<<"$first") == "$copies_script_name × $copies_count" ]] ||
        { echo "copies: FAIL — the window's first group is not the copies: $summary"; return 1; }
    [[ $(jq .count <<<"$first") -eq $((2 * copies_count)) ]] ||
        { echo "copies: FAIL — the group holds $(jq .count <<<"$first") processes, not $((2 * copies_count)): $summary"; return 1; }
    echo "copies: ok ($summary)"
}

# --- warn (Phase 6 Step 6): a runaway's warning in the window — the bar, the pinned row, Pause from the bar, contrast ---

# Waits up to $1 seconds from epoch second $2 for a bar line; prints the reader's `warnings` JSON once one shows.
wait_for_warning() {
    local json
    while :; do
        json=$(read_window warnings) && [[ $(jq '.lines | length' <<<"$json") -ge 1 ]] && { echo "$json"; return 0; }
        (($(date +%s) - $2 <= $1)) || return 1
        sleep 0.5
    done
}

# The recorded copies' and children's pids whose status reads stopped (T).
stopped_copies() {
    local pid
    for pid in $(copies_pids); do
        if [[ $(ps -p "$pid" -o stat= 2>/dev/null) == T* ]]; then echo "$pid"; fi    # an `&&` list would end the loop at 1
    done
}

# warn --window: Step 4's 30 copies (each with a busy child at 20% of a core, about 33% of an 18-core machine) raise
# one bar line within 15 s naming the script; the first group row carries the badge (`warned-group-0`) and no other
# does, By repo, session and command and under a Name sort; Pause from the bar stops every copy and child (`ps`
# status T) and its button reads Resume, pressed again none is stopped; then, relaunched in Ember & Steel and
# Two-colour (the high-contrast theme), light and dark, the shaded CPU cell keeps its figure at 4.5:1 and the badge
# reads 3:1 on its row (WCAG 2.2 § 1.4.3, § 1.4.11), measured from a window-id capture. Only recorded pids are stopped.
check_warn() {
    local json started seconds line title grouping summary stopped since theme appearance read cell badge fails=0
    trap 'stop_copies; stop_window' EXIT
    trap 'echo "warn: interrupted"; exit 130' INT TERM HUP
    window_up 3 || return 1
    started=$(date +%s)
    start_copies 0.2 || return 1
    json=$(wait_for_warning 15 "$started") || { echo "warn: FAIL — no bar line within 15 s of the copies' start"; return 1; }
    seconds=$(($(date +%s) - started))
    line=$(jq -r '.lines[0].text' <<<"$json")
    [[ $(jq '.lines | length' <<<"$json") -eq 1 ]] ||
        { echo "warn: FAIL — $(jq '.lines | length' <<<"$json") bar lines, want 1: $(jq -c '[.lines[].text]' <<<"$json")"; return 1; }
    [[ $line == *"$copies_script_name"* ]] || { echo "warn: FAIL — the bar line does not name the script: $line"; return 1; }
    summary="bar line in ${seconds} s: '$line'"
    # Pause from the bar, then Resume, first: stopped, the copies' CPU drops under the bar and the warning clears 10 s on.
    read_window warning-press 0 pause >/dev/null || { echo "warn: FAIL — cannot press the bar's Pause"; return 1; }
    sleep 1
    stopped=$(stopped_copies | wc -l | tr -d ' ')
    [[ $stopped -eq $((2 * copies_count)) ]] ||
        { echo "warn: FAIL — Pause from the bar stopped $stopped of $((2 * copies_count)) copies and children"; return 1; }
    json=$(read_window warnings)
    [[ $(jq -r '.lines[0].pause' <<<"$json") == Resume ]] ||
        { echo "warn: FAIL — the bar's Pause does not read Resume while the copies are stopped: $(jq -c .lines <<<"$json")"; return 1; }
    read_window warning-press 0 pause >/dev/null || { echo "warn: FAIL — cannot press the bar's Resume"; return 1; }
    sleep 1
    stopped=$(stopped_copies | wc -l | tr -d ' ')
    [[ $stopped -eq 0 ]] || { echo "warn: FAIL — $stopped copies or children still stopped after Resume"; return 1; }
    summary+="; Pause stopped all $((2 * copies_count)), Resume none left"
    # pinned <label>: after the next two refreshes, the first group row badged and no other.
    pinned() {
        since=$(read_window state | jq .refresh)
        wait_for_rows $((since + 2)) || return 1
        json=$(read_window warnings) || return 1
        jq -e '.groups[0].warned and ([.groups[1:][] | select(.warned)] | length == 0)' <<<"$json" >/dev/null ||
            { echo "warn: FAIL — $1: the badge is not on the first group row alone: $(jq -c .groups <<<"$json")"; return 1; }
        title=$(jq -r '.groups[0].title' <<<"$json")
    }
    for grouping in repo session command; do
        read_window group-by "$grouping" >/dev/null || { echo "warn: FAIL — cannot turn the window to By $grouping"; return 1; }
        pinned "By $grouping" || return 1
        summary+="; By $grouping first '$title'"
    done
    [[ $title == "$copies_script_name × $copies_count" ]] ||
        { echo "warn: FAIL — By command, the pinned group is '$title', not the copies"; return 1; }
    read_window sort Name >/dev/null && pinned "By command under the Name sort" || return 1
    read_window sort Name >/dev/null && pinned "By command under the Name sort, descending" || return 1
    # Contrast, relaunched in each theme and appearance (put back by stop_window).
    for theme in ember-steel two-colour; do
        for appearance in light dark; do
            # A fresh storm each time: a relaunched app counts copies already there as its baseline, not as growth.
            quit_app
            stop_copies
            defaults write "$app_domain" theme -string "$theme"
            defaults write "$app_domain" appearance -string "$appearance"
            launch_app || return 1
            wait_for_rows 3 || return 1
            started=$(date +%s)
            start_copies 0.2 || return 1
            wait_for_warning 15 "$started" >/dev/null ||
                { echo "warn: FAIL — $theme $appearance: no bar line within 15 s of the copies' start"; return 1; }
            wait_for_rows "$(($(read_window state | jq .refresh) + 1))" || return 1
            read=$(read_window contrast group-0-cpu) && badge=$(read_window contrast --margin 3 warned-group-0) ||
                { echo "warn: FAIL — $theme $appearance: cannot capture the window"; return 1; }
            cell=$(jq -r '(."group-0-cpu".ratio // 0) * 100 | round / 100' <<<"$read")
            summary+="; $theme $appearance cell $cell:1 on $(jq -r '."group-0-cpu".background // "?"' <<<"$read"), badge $(jq -r '(."warned-group-0".ratio // 0) * 100 | round / 100' <<<"$badge"):1"
            jq -e '."group-0-cpu".ratio >= 4.5' <<<"$read" >/dev/null ||
                { echo "warn: $theme $appearance — the shaded CPU cell reads $cell:1, want 4.5: $(jq -c . <<<"$read")"; ((++fails)); }
            jq -e '."warned-group-0".ratio >= 3' <<<"$badge" >/dev/null ||
                { echo "warn: $theme $appearance — the badge reads under 3:1: $(jq -c . <<<"$badge")"; ((++fails)); }
        done
    done
    ((fails == 0)) || { echo "warn: FAIL — $fails contrast reads under their bar ($summary)"; return 1; }
    echo "warn: ok ($summary)"
}

# --- runaway (Phase 6 gate round 2): the 2026-10-22 shape through an agent's tool shells gives one warning line ---

runaway_script_name=saur0n-runaway.sh

# Starts $copies_count copies of a script under launchd, each over a stand-in agent — a compiled `claude` (the agent
# rule reads the program name), busy 5% of a core — whose one tool call is a `zsh -c` over a busy `perl build.pl` (10%
# of a core) that, as an agent's tool shells do, also runs short commands one after another (a perl busy 20 ms of
# every 320), so the tool shells' finished-children CPU lifts `zsh` past its own bar beside the login shells. While
# the folder holds a `quiet` file the agents idle at 1% of a core, as agents waiting on their tool calls do, and the
# builds work on. Each process records "<its pid> <its child's pid>" in the folder's `pids`; waits until each copy's
# three lines are in, at most 10 s. The folder is left in /tmp.
start_runaway() {
    local tries=0 i want=$((3 * copies_count))
    copies_dir=$(mktemp -d /tmp/saur0n-runaway.XXXXXX)
    printf '%s\n' '#!/bin/bash' \
        '# One copy: the stand-in agent, both pids recorded, then wait for it.' \
        'dir=$(dirname "$0")' \
        '"$dir/claude" "$dir" &' \
        'echo "$$ $!" >>"$dir/pids"' \
        'wait' >"$copies_dir/$runaway_script_name"
    printf '%s\n' 'use Time::HiRes qw(time sleep);' \
        'while (1) { my $t = time + 0.01; 1 while time < $t; sleep 0.09 }' >"$copies_dir/build.pl"
    cat >"$copies_dir/claude.c" <<'EOF'
/* The stand-in agent: one tool call, a zsh -c over a busy build that runs short commands one after another, and a
   busy loop of its own at 5% of a core, 1% while the folder holds `quiet`. argv[1]: the scratch folder. */
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    pid_t tool = fork();
    if (tool < 0) return 1;
    if (tool == 0) {
        execl("/bin/zsh", "zsh", "-c",
              "perl \"$0/build.pl\" & echo \"$$ $!\" >>\"$0/pids\"; "
              "while :; do perl -MTime::HiRes=time,sleep -e '$t = time + 0.02; 1 while time < $t; sleep 0.3'; done",
              argv[1], (char *)0);
        _exit(127);
    }
    char path[1024], quiet[1024];
    snprintf(path, sizeof path, "%s/pids", argv[1]);
    snprintf(quiet, sizeof quiet, "%s/quiet", argv[1]);
    FILE *f = fopen(path, "a");
    if (!f) return 1;
    fprintf(f, "%d %d\n", (int)getpid(), (int)tool);
    fclose(f);
    for (;;) {
        double end = now() + (access(quiet, F_OK) == 0 ? 0.001 : 0.005);
        while (now() < end) {}
        usleep(95000);
    }
}
EOF
    cc -O -o "$copies_dir/claude" "$copies_dir/claude.c" || { echo "runaway: FAIL — cannot compile the stand-in agent"; return 1; }
    for ((i = 0; i < copies_count; i++)); do
        (nohup bash "$copies_dir/$runaway_script_name" >/dev/null 2>&1 &)
    done
    until [[ -f $copies_dir/pids && $(wc -l <"$copies_dir/pids") -ge $want ]]; do
        ((++tries <= 100)) || { echo "runaway: FAIL — only $(wc -l <"$copies_dir/pids" 2>/dev/null || echo 0) of $want records"; return 1; }
        sleep 0.1
    done
}

# The recorded pids, each once, whose status reads stopped (T).
runaway_stopped() {
    local pid
    for pid in $(copies_pids | sort -u); do
        if [[ $(ps -p "$pid" -o stat= 2>/dev/null) == T* ]]; then echo "$pid"; fi
    done
}

# runaway --window: 30 copies of a script, each over a stand-in agent whose tool shell (`zsh -c`, the login shells'
# command, busy enough with its finished commands to warn on its own) runs a busy build, raise one bar line within 20 s
# naming the script, and still one line at each of the next 15 reads a second apart; then the agents go quiet while
# the builds work on (the gate's round 3) and the line holds — one line naming the script at each of 25 reads, past
# the 10 s a cleared line takes and the 10 s a new one would hold before it showed; By command the first group is the
# script's copies and alone carries the badge; Pause from the bar stops every copy, agent, tool shell and build (the
# line carries the tool shells' and the builds' pids), Resume none left. Only recorded pids are stopped.
check_runaway() {
    local json started seconds line summary stopped title i want=$((4 * copies_count))
    trap 'stop_copies; stop_window' EXIT
    trap 'echo "runaway: interrupted"; exit 130' INT TERM HUP
    window_up 3 || return 1
    started=$(date +%s)
    start_runaway || return 1
    json=$(wait_for_warning 20 "$started") || { echo "runaway: FAIL — no bar line within 20 s of the copies' start"; return 1; }
    seconds=$(($(date +%s) - started))
    # one_line <read>: the bar holds one line, naming the script.
    one_line() {
        [[ $(jq '.lines | length' <<<"$json") -eq 1 ]] ||
            { echo "runaway: FAIL — $1: $(jq '.lines | length' <<<"$json") bar lines, want 1: $(jq -c '[.lines[].text]' <<<"$json")"; return 1; }
        line=$(jq -r '.lines[0].text' <<<"$json")
        [[ $line == *"$runaway_script_name"* ]] || { echo "runaway: FAIL — $1: the bar line does not name the script: $line"; return 1; }
    }
    for ((i = 0; i <= 15; i++)); do
        ((i == 0)) || { sleep 1; json=$(read_window warnings) || return 1; }
        one_line "read $i" || return 1
    done
    summary="one bar line from ${seconds} s through 15 more reads: '$line'"
    : >"$copies_dir/quiet"
    for ((i = 1; i <= 25; i++)); do
        sleep 1
        json=$(read_window warnings) || return 1
        one_line "agents quiet, read $i" || return 1
    done
    summary+="; agents quiet, still one line through 25 reads: '$line'"
    read_window group-by command >/dev/null || { echo "runaway: FAIL — cannot turn the window to By command"; return 1; }
    wait_for_rows $(($(read_window state | jq .refresh) + 2)) || return 1
    json=$(read_window warnings) || return 1
    title=$(jq -r '.groups[0].title' <<<"$json")
    jq -e '.groups[0].warned and ([.groups[1:][] | select(.warned)] | length == 0)' <<<"$json" >/dev/null &&
        [[ $title == "$runaway_script_name × $copies_count" ]] ||
        { echo "runaway: FAIL — By command, the badge is not on '$runaway_script_name × $copies_count' alone: $(jq -c '[.groups[:4][] | {title, warned}]' <<<"$json")"; return 1; }
    summary+="; By command first '$title', badged alone"
    read_window warning-press 0 pause >/dev/null || { echo "runaway: FAIL — cannot press the bar's Pause"; return 1; }
    sleep 1
    stopped=$(runaway_stopped | wc -l | tr -d ' ')
    [[ $stopped -eq $want ]] ||
        { echo "runaway: FAIL — Pause from the bar stopped $stopped of $want copies, agents, tool shells and builds"; return 1; }
    read_window warning-press 0 pause >/dev/null || { echo "runaway: FAIL — cannot press the bar's Resume"; return 1; }
    sleep 1
    stopped=$(runaway_stopped | wc -l | tr -d ' ')
    [[ $stopped -eq 0 ]] || { echo "runaway: FAIL — $stopped still stopped after Resume"; return 1; }
    summary+="; Pause stopped all $want, Resume none left"
    echo "runaway: ok ($summary)"
}

# --- runaway-join (Phase 6 gate round 5): a runaway's agent-started work counts toward its script; the user's own
# shells and sessions on no line (research 2026-10-25 § A, § B) ---

# This Mac's tool-call filter, which every Claude Code Bash call runs under (`bash shell-prefix-filter.sh "<call>"`);
# absent, the stand-ins run their tool calls as a stock Mac's `zsh -c`.
tool_filter=${SAUR0N_TOOL_FILTER:-$HOME/Dev/SysConfig/AgentBehavior/scripts/shell-prefix-filter.sh}

# Starts $1 copies of a script under launchd, each over a stand-in agent busy $2 of a core (0: idle), whose tool call
# leads its own session and process group as Claude Code's do and runs as a Bash call through `$tool_filter` — its
# log and state kept in the scratch folder, no upgrade check — over a `zsh -c` running a busy `perl build.pl` (10% of
# a core) and short busy commands one after another. Each process records "<its pid> <its child's pid>" in `pids`;
# the copies' own lines also go to `copies`. Waits until each copy's three lines are in, at most 10 s.
start_join_runaway() {
    local tries=0 i want=$((3 * $1))
    copies_dir=$(mktemp -d /tmp/saur0n-runaway.XXXXXX)
    mkdir -p "$copies_dir/shell-snapshots" "$copies_dir/filter-state"
    : >"$copies_dir/shell-snapshots/snapshot-zsh-0-check.sh"
    printf '%s\n' '#!/bin/bash' \
        '# One copy: the stand-in agent, both pids recorded, then wait for it.' \
        'dir=$(dirname "$0")' \
        '"$dir/claude" "$dir" "$1" "$2" &' \
        'echo "$$ $!" >>"$dir/pids"; echo "$$" >>"$dir/copies"' \
        'wait' >"$copies_dir/$runaway_script_name"
    printf '%s\n' 'use Time::HiRes qw(time sleep);' \
        'while (1) { my $t = time + 0.01; 1 while time < $t; sleep 0.09 }' >"$copies_dir/build.pl"
    printf '%s\n' 'use Time::HiRes qw(time sleep);' 'my $t = time + 0.02; 1 while time < $t; sleep 0.3;' >"$copies_dir/short.pl"
    cat >"$copies_dir/claude.c" <<'EOF'
/* The stand-in agent: one tool call in a session of its own, run as a Claude Code Bash call — through the filter
   (argv[3]) when one is given, else as a bare zsh -c — and a busy loop of its own at argv[2] of a core.
   argv[1]: the scratch folder. */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    const char *dir = argv[1], *filter = argv[3];
    double busy = atof(argv[2]);
    char body[2048], call[4096];
    snprintf(body, sizeof body, "perl %s/build.pl & echo $$ $! >>%s/pids; while :; do perl %s/short.pl; done",
             dir, dir, dir);
    pid_t tool = fork();
    if (tool < 0) return 1;
    if (tool == 0) {
        setsid();
        if (*filter) {
            snprintf(call, sizeof call, "source %s/shell-snapshots/snapshot-zsh-0-check.sh 2>/dev/null || true"
                     " && eval '%s' < /dev/null && pwd -P >| %s/cwd", dir, body, dir);
            char state[1024];
            snprintf(state, sizeof state, "%s/filter-state", dir);
            setenv("SHELL_PREFIX_FILTER_STATE", state, 1);
            unsetenv("CLAUDE_CODE_EXECPATH");
            unsetenv("CLAUDE_PROJECT_DIR");
            execl("/bin/bash", "bash", filter, call, (char *)0);
        } else {
            execl("/bin/zsh", "zsh", "-c", body, (char *)0);
        }
        _exit(127);
    }
    char path[1024];
    snprintf(path, sizeof path, "%s/pids", dir);
    FILE *f = fopen(path, "a");
    if (!f) return 1;
    fprintf(f, "%d %d\n", (int)getpid(), (int)tool);
    fclose(f);
    if (busy <= 0) for (;;) pause();
    for (;;) {
        double end = now() + busy * 0.1;
        while (now() < end) {}
        usleep((useconds_t)((1 - busy) * 100000));
    }
}
EOF
    cc -O -o "$copies_dir/claude" "$copies_dir/claude.c" || { echo "runaway-join: FAIL — cannot compile the stand-in agent"; return 1; }
    for ((i = 0; i < $1; i++)); do
        (nohup bash "$copies_dir/$runaway_script_name" "$2" "$( [[ -f $tool_filter ]] && echo "$tool_filter")" >/dev/null 2>&1 &)
    done
    until [[ -f $copies_dir/pids && $(wc -l <"$copies_dir/pids") -ge $want ]]; do
        ((++tries <= 100)) || { echo "runaway-join: FAIL — only $(wc -l <"$copies_dir/pids" 2>/dev/null || echo 0) of $want records"; return 1; }
        sleep 0.1
    done
}

# Each of the pids $1 (space-separated; `all`: every process) as "<pid> <own|check|other> <stat> <command>" from one
# `ps` read, a pid gone since left out. own: one of the user's own — a login shell (`-zsh`, `zsh -l`, `bash --login`)
# or an agent with a terminal the check did not start; check: a pid in `$copies_dir/pids` or a descendant of one.
classify() {
    copies_pids >"$copies_dir/recorded"
    ps -axo pid=,ppid=,stat=,tty=,args= | awk -v recorded="$copies_dir/recorded" -v want="$1" '
        BEGIN { while ((getline line < recorded) > 0) rec[line] = 1 }
        function base(s) { sub(/.*\//, "", s); return s }
        function check(p,    h) { for (h = 0; h < 64 && p > 1; h++) { if (p in rec) return 1; p = parent[p] } return 0 }
        function own(p,    word, k, i, cmd) {
            if (args[p] ~ /^-/) return 1
            k = split(args[p], word, " "); cmd = base(word[1])
            if (cmd ~ /^(zsh|bash|sh)$/)
                for (i = 2; i <= k && word[i] ~ /^-./; i++)
                    if (word[i] == "--login" || (word[i] !~ /^--/ && word[i] ~ /l/)) return 1
            return cmd ~ /^(claude|codex|cli-proxy-api)$/ && tty[p] != "??" && !check(p)
        }
        { a = $0; sub(/^ *[0-9]+ +[0-9]+ +[^ ]+ +[^ ]+ +/, "", a)
          parent[$1] = $2; stat[$1] = $3; tty[$1] = $4; args[$1] = a }
        END {
            n = want == "all" ? 0 : split(want, w, " ")
            if (want == "all") for (p in args) w[++n] = p
            for (i = 1; i <= n; i++) {
                p = w[i]
                if (!(p in args)) continue
                print p, own(p) ? "own" : check(p) ? "check" : "other", stat[p], substr(args[p], 1, 40)
            }
        }'
}

# Every bar line in $json: fails when one holds one of the user's own; Pauses each whose live members are all the
# check's own, then reads every login shell and interactive agent still running (not T) and the line's own stopped,
# and Resumes it. Labels its failures $1; adds "<n> lines paused" to `paused_lines`.
pause_every_line() {
    local i n name pids read held stopped users
    n=$(jq '.lines | length' <<<"$json")
    for ((i = 0; i < n; i++)); do
        name=$(jq -r ".lines[$i].text" <<<"$json")
        [[ $(jq ".lines[$i].pids | type" <<<"$json") == '"array"' ]] ||
            { echo "runaway-join: FAIL — $1: bar line $i ($name) carries no pids for the check to read"; return 1; }
        [[ $(jq -r ".lines[$i].spoken" <<<"$json") != *[0-9][0-9]* ]] ||
            { echo "runaway-join: FAIL — $1: VoiceOver would read pids on bar line $i: $(jq -r ".lines[$i].spoken" <<<"$json")"; return 1; }
        pids=$(jq -r "[.lines[$i].pids[]] | join(\" \")" <<<"$json")
        read=$(classify "$pids")
        held=$(awk '$2 == "own"' <<<"$read")
        [[ -z $held ]] || { echo "runaway-join: FAIL — $1: bar line '$name' holds the user's own: $(tr '\n' ';' <<<"$held")"; return 1; }
        [[ -n $read ]] && ! awk '$2 != "check" { found = 1 } END { exit !found }' <<<"$read" || continue
        read_window warning-press "$i" pause >/dev/null || { echo "runaway-join: FAIL — $1: cannot press Pause on '$name'"; return 1; }
        sleep 1
        users=$(classify all | awk '$2 == "own"')
        stopped=$(classify "$pids" | awk '$2 == "check" && $3 ~ /^T/' | wc -l | tr -d ' ')
        read_window warning-press "$i" pause >/dev/null || { echo "runaway-join: FAIL — $1: cannot press Resume on '$name'"; return 1; }
        [[ -z $(awk '$3 ~ /^T/' <<<"$users") ]] ||
            { echo "runaway-join: FAIL — $1: Pause on '$name' left the user's own stopped: $(awk '$3 ~ /^T/' <<<"$users" | tr '\n' ';')"; return 1; }
        ((stopped > 0)) || { echo "runaway-join: FAIL — $1: Pause on '$name' stopped none of its own processes"; return 1; }
        paused_lines+=("'$name' stopped $stopped of its own, all $(wc -l <<<"$users" | tr -d ' ') login shells and interactive agents running")
        sleep 1
    done
}

# Reads the bar $2 times a second apart; each read must show exactly one line, naming the script (`$3` = one), or no
# line holding the user's own (`$3` = clean); labels failures $1.
watch_bar() {
    local i
    for ((i = 1; i <= $2; i++)); do
        json=$(read_window warnings) || return 1
        case $3 in
        one)
            [[ $(jq '.lines | length' <<<"$json") -eq 1 && $(jq -r '.lines[0].text' <<<"$json") == *"$runaway_script_name"* ]] ||
                { echo "runaway-join: FAIL — $1, read $i: want one line naming the script: $(jq -c '[.lines[].text]' <<<"$json")"; return 1; } ;;
        clean)
            local held
            held=$(classify "$(jq -r '[.lines[].pids[]?] | join(" ")' <<<"$json")" | awk '$2 == "own"')
            [[ -z $held ]] ||
                { echo "runaway-join: FAIL — $1, read $i: a line holds the user's own: $(tr '\n' ';' <<<"$held") $(jq -c '[.lines[].text]' <<<"$json")"; return 1; } ;;
        esac
        sleep 1
    done
}

# runaway-join --window: the research's two shapes (2026-10-25), through this Mac's tool-call filter. Quiet agents:
# 25 copies of a script, each over a stand-in agent at 0% whose tool call works through the filter — under the old
# rule the script never warned and `zsh` or the filter warned with the login shells — give one bar line naming the
# script within 20 s and at each of the next 15 reads; Pause on every bar line stops the check's own (`ps` T) and
# leaves every login shell and interactive agent running; with SAUR0N_DEMO_HOLD naming a file, the check then holds
# while that file exists (at most 10 minutes) for the user to look. Killed copies: a fresh 25, the agents busy 8% of
# a core, raise the script's line; the copies are killed from here (TERM, each copy only) while the agents work on;
# through 25 reads no line holds a login shell or an interactive agent, then Pause on every line as above. A line
# holding anything the check did not start is never paused. Only recorded pids and their descendants are stopped.
check_runaway_join() {
    local started seconds summary line pid count=25 tries=0
    trap 'stop_copies; stop_window' EXIT
    trap 'echo "runaway-join: interrupted"; exit 130' INT TERM HUP
    window_up 3 || return 1
    started=$(date +%s)
    start_join_runaway "$count" 0 || return 1
    json=$(wait_for_warning 20 "$started") || { echo "runaway-join: FAIL — quiet agents: no bar line within 20 s of the copies' start"; return 1; }
    seconds=$(($(date +%s) - started))
    watch_bar "quiet agents" 15 one || return 1
    line=$(jq -r '.lines[0].text' <<<"$json")
    summary="quiet agents ($([[ -f $tool_filter ]] && echo "through the filter" || echo "bare zsh -c")): one line from ${seconds} s through 15 reads: '$line'"
    paused_lines=()
    pause_every_line "quiet agents" || return 1
    summary+="; Pause: ${paused_lines[*]:-no line to pause}"
    if [[ -n ${SAUR0N_DEMO_HOLD:-} ]]; then
        echo "runaway-join: demo — holding while $SAUR0N_DEMO_HOLD exists: '$line'"
        while [[ -e $SAUR0N_DEMO_HOLD ]] && ((tries++ < 600)); do sleep 1; done
    fi
    stop_copies
    sleep 12    # the line clears 10 s after its copies go
    started=$(date +%s)
    start_join_runaway "$count" 0.08 || return 1
    json=$(wait_for_warning 20 "$started") || { echo "runaway-join: FAIL — killed copies: no bar line within 20 s of the copies' start"; return 1; }
    watch_bar "killed copies, before the kill" 5 one || return 1
    for pid in $(<"$copies_dir/copies"); do
        if [[ $(ps -p "$pid" -o command= 2>/dev/null) == *"$copies_dir"* ]]; then kill "$pid"; fi
    done
    sleep 1
    count=$(ps -axo ppid=,command= | awk -v d="$copies_dir/claude" '$1 == 1 && index($0, d)' | wc -l | tr -d ' ')
    summary+="; killed copies: $count agents working on under launchd"
    watch_bar "killed copies" 25 clean || return 1
    json=$(read_window warnings) || return 1
    summary+=", 25 reads with no line holding the user's own, lines then: $(jq -c '[.lines[].text]' <<<"$json")"
    paused_lines=()
    pause_every_line "killed copies" || return 1
    summary+="; Pause: ${paused_lines[*]:-no line to pause}"
    echo "runaway-join: ok ($summary)"
}

# --- snapshot (Phase 6 Step 7): a runaway's evidence kept after it ends ---

# snapshot: the window launched with its snapshot log in a scratch folder under /tmp (SAUR0N_SNAPSHOT_DIR, so the
# user's own log is never written: its modification time is checked unchanged), Step 4's 30 copies raise a warning,
# the copies are stopped, and the log then holds a warning snapshot naming the script; `saur0n snapshot <its time>
# --by command` prints the copies' group "<script> × 30" with all 60 processes and the Unattributed CPU line. Reports
# the snapshot's size in the log and unpacked. Only recorded pids are stopped; the scratch folder stays in /tmp.
# First the peak clause, on the disk graph (a CPU burst cannot double the median on a busy machine): once the window
# has 10 s of history, two bursts 3 s apart, each 1 GB written and flushed to a scratch file, and the log holds peak
# snapshots, each named for a graph, a minute or more apart. The scratch file is removed by its path on every way out.
burst_file=""
disk_burst() { dd if=/dev/zero of="$burst_file" bs=1m count=1024 2>/dev/null && sync; }
peak_snapshots() { saur0n snapshots --json | jq -c '[.[] | select(.reason == "peak") | .detail]'; }
check_snapshot() {
    local started entry taken time printed title unattributed real before after unpacked summary peaks
    trap 'stop_copies; stop_window; [[ -z $burst_file ]] || rm -f "$burst_file"' EXIT
    trap 'echo "snapshot: interrupted"; exit 130' INT TERM HUP
    real="$HOME/Library/Application Support/Saur0n/snapshots.sqlite"
    before=$(stat -f %m "$real" 2>/dev/null || echo absent)
    SAUR0N_SNAPSHOT_DIR=$(mktemp -d /tmp/saur0n-snapshots.XXXXXX)
    export SAUR0N_SNAPSHOT_DIR
    build
    window_up 12 || return 1
    burst_file="$SAUR0N_SNAPSHOT_DIR/burst"
    # On a busy Mac other work spikes the disk too (a test run's bun at 177 M/s, 2026-10-24), so which spike took the
    # snapshot is not pinned: the log must hold at least one peak snapshot after the two bursts, each named for a graph,
    # and none within a minute of another — the burst inside the minute adds none. The mark names the busiest process
    # still alive at that second, which is seldom dd (gone within it).
    disk_burst || { echo "snapshot: FAIL — cannot write the disk burst"; return 1; }
    sleep 3
    disk_burst || { echo "snapshot: FAIL — cannot write the second disk burst"; return 1; }
    sleep 3
    peaks=$(peak_snapshots)
    [[ $(jq length <<<"$peaks") -ge 1 ]] && jq -e 'all(.[]; test("^(CPU|Disk|Network)"))' <<<"$peaks" >/dev/null ||
        { echo "snapshot: FAIL — two 1 GB disk bursts left peak snapshots $peaks: $(saur0n snapshots)"; return 1; }
    saur0n snapshots --json | jq -e '[.[] | select(.reason == "peak") | .takenAt] | . as $t
        | [range(1; length) | $t[.] - $t[. - 1]] | all(. >= 60)' >/dev/null ||
        { echo "snapshot: FAIL — two peak snapshots within a minute: $(saur0n snapshots)"; return 1; }
    rm -f "$burst_file"
    burst_file=""
    summary="peak snapshots $peaks, a minute or more apart; "
    started=$(date +%s)
    start_copies 0.2 || return 1
    wait_for_warning 15 "$started" >/dev/null || { echo "snapshot: FAIL — no warning within 15 s of the copies' start"; return 1; }
    sleep 2    # the writer runs beside the refresh loop
    stop_copies
    sleep 2    # the storm is over
    entry=$(saur0n snapshots --json | jq -c --arg s "$copies_script_name" \
        '[.[] | select(.reason == "warning" and (.detail | contains($s)))] | first // empty')
    [[ -n $entry ]] || { echo "snapshot: FAIL — no warning snapshot names the script: $(saur0n snapshots)"; return 1; }
    taken=$(jq -r '.takenAt | floor' <<<"$entry")
    time=$(date -r "$taken" '+%Y-%m-%d %H:%M:%S')
    printed=$(saur0n snapshot "$time" --by command)
    [[ $(head -1 <<<"$printed") == "Snapshot $time (warning: "*"$copies_script_name"* ]] ||
        { echo "snapshot: FAIL — saur0n snapshot '$time' printed another snapshot: $(head -1 <<<"$printed")"; return 1; }
    title=$(grep -m1 "^$copies_script_name × " <<<"$printed" || true)
    [[ $title == "$copies_script_name × $copies_count  "*"  $((2 * copies_count)) processes" ]] ||
        { echo "snapshot: FAIL — the copies' group reads '$title', want '$copies_script_name × $copies_count' with $((2 * copies_count)) processes"; return 1; }
    unattributed=$(grep -m1 '^Unattributed CPU  ' <<<"$printed" || true)
    [[ -n $unattributed ]] || { echo "snapshot: FAIL — the snapshot has no Unattributed CPU line"; return 1; }
    after=$(stat -f %m "$real" 2>/dev/null || echo absent)
    [[ $after == "$before" ]] || { echo "snapshot: FAIL — the user's own snapshot log changed during the check"; return 1; }
    unpacked=$(saur0n snapshot "$time" --json | wc -c | tr -d ' ')
    summary+="snapshot $time ($(saur0n snapshots | wc -l | tr -d ' ') in the log), group '${title%%  *}' $((2 * copies_count)) processes"
    summary+=", '$unattributed', $(jq .processes <<<"$entry") processes, $(jq .bytes <<<"$entry") bytes in the log, $unpacked unpacked"
    echo "snapshot: ok ($summary)"
}

# --- warning-safety (safe runaway controls): the bar's Pause and Stop spare the user's terminal session ---

# A stand-in terminal session in a scratch folder under /tmp: a copy of bash named `codex` (the interactive agent,
# holding this terminal), the bash filter it runs, the `zsh -c` shell that filter runs, and $safety_workers
# `zsh worker.sh` copies under that shell, each busy a few percent of a core (the whole storm capped at two cores).
# Every process ends itself at a deadline 4 minutes out; only the pids recorded in the folder, still running a command
# that names it, are ever signalled. Globals for the EXIT trap.
safety_dir="" safety_workers=30 safety_user_log=""

stop_safety() {
    local pid
    [[ -n $safety_dir ]] || return 0
    for pid in $(cat "$safety_dir/root.pid" "$safety_dir/filter.pid" "$safety_dir/shell.pid" "$safety_dir/workers" 2>/dev/null); do
        [[ $(ps -p "$pid" -o command= 2>/dev/null) == *"$safety_dir"* ]] && kill -CONT "$pid" 2>/dev/null &&
            kill "$pid" 2>/dev/null || true
    done
    safety_dir=""
}

# Starts the session with each worker busy $1 seconds of each ~0.1 s period and waits until all have recorded.
start_safety_session() {
    local deadline tries=0
    safety_dir=$(mktemp -d /tmp/saur0n-safety.XXXXXX)
    deadline=$(($(date +%s) + 240))
    # A copy of a system binary is killed on launch until it is signed again.
    cp /bin/bash "$safety_dir/codex"
    codesign --force --sign - "$safety_dir/codex" 2>/dev/null
    printf '%s\n' '#!/bin/zsh' 'zmodload zsh/datetime zsh/zselect' 'print -r -- $$ >>"$1"' \
        'while (( EPOCHREALTIME < $2 )); do' \
        '  t=$(( EPOCHREALTIME + $3 )); while (( EPOCHREALTIME < t )); do :; done' \
        '  zselect -t 9' 'done' >"$safety_dir/worker.sh"
    printf '%s\n' '#!/bin/bash' "echo \$\$ >'$safety_dir/filter.pid'" \
        "zsh -c 'zmodload zsh/datetime zsh/zselect; print -r -- \$\$ >\"$safety_dir/shell.pid\"; for ((i = 0; i < $safety_workers; i++)); do zsh \"$safety_dir/worker.sh\" \"$safety_dir/workers\" $deadline $1 & done; while (( EPOCHREALTIME < $deadline )); do zselect -t 50; done'" \
        >"$safety_dir/filter.sh"
    # Orphaned to launchd at birth, as a terminal's own agent is, on a pty of its own from `script` (the check may not
    # run in a terminal), which is what makes it an interactive agent.
    (nohup script -q /dev/null "$safety_dir/codex" -c "echo \$\$ >'$safety_dir/root.pid'; bash '$safety_dir/filter.sh'; :" </dev/null >/dev/null 2>&1 &)
    until [[ -f $safety_dir/workers && $(wc -l <"$safety_dir/workers") -ge $safety_workers &&
        -f $safety_dir/root.pid && -f $safety_dir/filter.pid && -f $safety_dir/shell.pid ]]; do
        ((++tries <= 100)) || { echo "warning-safety: FAIL — the session did not start ($(wc -l <"$safety_dir/workers" 2>/dev/null || echo 0) of $safety_workers workers recorded)"; return 1; }
        sleep 0.1
    done
}

# The workers' pids as a sorted JSON array.
safety_workers_json() { jq -Rnc '[inputs | select(length > 0) | tonumber] | sort' <"$safety_dir/workers"; }

# A process's state letters ("" when gone; zombies count as gone) and its start time.
safety_state() { local s; s=$(ps -p "$1" -o stat= 2>/dev/null | tr -d ' ') || true; [[ $s == Z* ]] && s=""; echo "$s"; }
safety_started() { ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//'; }

# Waits up to $1 seconds for a bar line naming the workers; prints the reader's `warnings` JSON once there is one.
safety_warning() {
    local json started
    started=$(date +%s)
    while :; do
        json=$(read_window warnings 2>/dev/null) || json=""
        if [[ -n $json ]] && jq -e 'any(.lines[]; .text | contains("worker.sh"))' <<<"$json" >/dev/null; then echo "$json"; return 0; fi
        (($(date +%s) - started <= $1)) || return 1
        sleep 0.5
    done
}
safety_line() { jq -r '[.lines | to_entries[] | select(.value.text | contains("worker.sh")) | .key][0]' <<<"$1"; }

# warning-safety --window: an isolated build of the app (own bundle id and defaults, snapshot folder in /tmp) beside the
# stand-in session above. Within 40 s of its start one bar line names the workers and its pids are exactly the workers,
# none of the session's root, filter or shell; Pause from the bar stops every worker (`ps` state T) and nothing of the
# session, and reads Resume; Resume continues them; Stop… shows a sheet whose targets are exactly the workers (cancel
# leaves all running), and confirming ends them all while the root, filter and shell run on, each with its start time
# unchanged, and the app's snapshot log is in its scratch folder. Generated load is capped at two cores; the installed
# Saur0n and its watcher are never touched.
check_warning_safety() {
    local ncpu cores busy json i out pid want got stopped summary role
    local -a keep
    trap 'stop_safety; stop_window; defaults delete app.saur0n.monitor.safety >/dev/null 2>&1 || true' EXIT
    trap 'echo "warning-safety: interrupted"; exit 130' INT TERM HUP
    ncpu=$(sysctl -n hw.ncpu)
    # 7% of the machine clears the 5% bar with room; over two cores the probe will not run.
    cores=$(awk -v n="$ncpu" 'BEGIN { printf "%.3f", n * 0.07 }')
    awk -v c="$cores" 'BEGIN { exit !(c <= 2) }' ||
        { echo "warning-safety: FAIL — $ncpu cores need $cores cores of load to pass 5% of the machine; the limit is 2"; return 1; }
    # Each worker is busy b of every b + 0.09 s: duty = cores / workers, so b = 0.09 d / (1 - d).
    busy=$(awk -v c="$cores" -v w="$safety_workers" 'BEGIN { d = c / w; printf "%.5f", 0.09 * d / (1 - d) }')
    export SAUR0N_BUNDLE_ID=app.saur0n.monitor.safety SAUR0N_APP_DIR=.build/Saur0n-safety.app SAUR0N_BUILD_JOBS=2
    app_domain=$SAUR0N_BUNDLE_ID app_bundle=$SAUR0N_APP_DIR
    # The windowed app runs the watcher with its defaults: switch the copies rung off for this launch so it cannot
    # pause the check's workers or a real storm; only the bar's own Pause acts.
    app_args=(-acting.pause.copies NO)
    SAUR0N_SNAPSHOT_DIR=$(mktemp -d /tmp/saur0n-safety-snap.XXXXXX)
    export SAUR0N_SNAPSHOT_DIR
    window_up 3 || return 1
    start_safety_session "$busy" || return 1
    out=$(ps -p "$(cat "$safety_dir/root.pid")" -o tty= | tr -d ' ')
    [[ -n $out && $out != "??" ]] ||
        { echo "warning-safety: FAIL — the stand-in agent has no controlling terminal"; return 1; }
    want=$(safety_workers_json)
    keep=(root filter shell)
    for role in "${keep[@]}"; do safety_started "$(cat "$safety_dir/$role.pid")" >"$safety_dir/$role.start"; done
    # The bar line.
    json=$(safety_warning 40) || { echo "warning-safety: FAIL — no bar line naming worker.sh within 40 s of the session's start"; return 1; }
    i=$(safety_line "$json")
    got=$(jq -c ".lines[$i].pids // [] | sort" <<<"$json")
    summary="bar line '$(jq -r ".lines[$i].text" <<<"$json")' at ${cores} cores of load"
    [[ $got == "$want" ]] ||
        { echo "warning-safety: FAIL — the bar line's pids are $got, not exactly the $safety_workers workers $want ($summary)"; return 1; }
    summary+="; its pids are exactly the $safety_workers workers"
    # Pause: workers stopped, the session running.
    read_window warning-press "$i" pause >/dev/null || { echo "warning-safety: FAIL — cannot press the bar's Pause"; return 1; }
    sleep 1
    stopped=0
    for pid in $(jq -r '.[]' <<<"$want"); do [[ $(safety_state "$pid") == T* ]] && stopped=$((stopped + 1)); done
    [[ $stopped -eq $safety_workers ]] || { echo "warning-safety: FAIL — Pause stopped $stopped of $safety_workers workers"; return 1; }
    for role in "${keep[@]}"; do
        [[ $(safety_state "$(cat "$safety_dir/$role.pid")") == [!T]* ]] ||
            { echo "warning-safety: FAIL — Pause from the bar stopped the session's $role"; return 1; }
    done
    json=$(safety_warning 15) || { echo "warning-safety: FAIL — the bar line vanished after Pause"; return 1; }
    i=$(safety_line "$json")
    [[ $(jq -r ".lines[$i].pause" <<<"$json") == Resume ]] ||
        { echo "warning-safety: FAIL — the bar's Pause does not read Resume while the workers are stopped: $(jq -c .lines <<<"$json")"; return 1; }
    read_window warning-press "$i" pause >/dev/null || { echo "warning-safety: FAIL — cannot press the bar's Resume"; return 1; }
    sleep 1
    stopped=0
    for pid in $(jq -r '.[]' <<<"$want"); do [[ $(safety_state "$pid") == T* ]] && stopped=$((stopped + 1)); done
    [[ $stopped -eq 0 ]] || { echo "warning-safety: FAIL — $stopped workers still stopped after Resume"; return 1; }
    summary+="; Pause stopped all $safety_workers workers and none of the session, Resume left none stopped"
    # Stop…, cancelled: exactly the workers listed, none ended.
    json=$(safety_warning 15) || { echo "warning-safety: FAIL — the bar line vanished before Stop"; return 1; }
    i=$(safety_line "$json")
    out=$(read_window warning-stop-sheet "$i" --cancel) || { echo "warning-safety: FAIL — cannot read the Stop sheet"; return 1; }
    got=$(jq -c '.targetPids | sort' <<<"$out")
    [[ $got == "$want" ]] ||
        { echo "warning-safety: FAIL — the Stop sheet lists $got, not exactly the workers $want ($(jq -c .targets <<<"$out"))"; return 1; }
    for pid in $(jq -r '.[]' <<<"$want"); do
        [[ -n $(safety_state "$pid") ]] || { echo "warning-safety: FAIL — Cancel ended worker $pid"; return 1; }
    done
    summary+="; the Stop sheet lists exactly the workers ($(jq -r '.targetsHeading' <<<"$out")), Cancel ended none, it names $(jq '.sparedPids | length' <<<"$out") processes left running"
    # Stop…, confirmed: the workers end, the session stays with the same start times.
    json=$(safety_warning 15) || { echo "warning-safety: FAIL — the bar line vanished before Stop"; return 1; }
    i=$(safety_line "$json")
    out=$(read_window warning-stop-sheet "$i") || { echo "warning-safety: FAIL — cannot confirm the Stop sheet"; return 1; }
    [[ $(jq -r '.error' <<<"$out") == null ]] || { echo "warning-safety: FAIL — Stop reported: $(jq -r .error <<<"$out")"; return 1; }
    sleep 3
    stopped=0
    for pid in $(jq -r '.[]' <<<"$want"); do [[ -z $(safety_state "$pid") ]] || stopped=$((stopped + 1)); done
    [[ $stopped -eq 0 ]] || { echo "warning-safety: FAIL — $stopped of $safety_workers workers still run after Stop"; return 1; }
    for role in "${keep[@]}"; do
        pid=$(cat "$safety_dir/$role.pid")
        [[ -n $(safety_state "$pid") && $(safety_started "$pid") == "$(<"$safety_dir/$role.start")" ]] ||
            { echo "warning-safety: FAIL — Stop ended the session's $role (pid $pid)"; return 1; }
    done
    summary+="; Stop ended all $safety_workers workers, the root, filter and shell run on with their start times"
    # The installed watcher writes the user's own log while this runs, so its time says nothing; what shows the app
    # wrote here is a log in the scratch folder.
    [[ -s $SAUR0N_SNAPSHOT_DIR/snapshots.sqlite ]] ||
        { echo "warning-safety: FAIL — the isolated app wrote no snapshot log in its own folder"; return 1; }
    echo "warning-safety: ok ($summary)"
}

# --- watcher (Phase 7 Step 1): the app runs headless from launchd and logs a storm's warning with no window ---

# The probe's own LaunchAgent, loaded from a scratch folder and booted out again — never the real com.saur0n.watch
# (calibration lock 7). Its app is the built bundle in `--watch`, its snapshot log and pause ledger in the scratch
# folder (SAUR0N_SNAPSHOT_DIR), and `-acting.pause.copies NO` in the argument domain, so the run is the dry one: the
# storm must be logged with its figures and nothing paused, and the user's own defaults are left alone.
watcher_label=com.saur0n.watch.test
watcher_dir="" watcher_loaded=""

stop_watcher() {
    [[ -z $watcher_loaded ]] || launchctl bootout "gui/$(id -u)/$watcher_label" 2>/dev/null || true
    watcher_loaded=""
}

# The agent's pid as `launchctl list` prints it ({"PID" = 1234;}); empty until it has started.
watcher_pid() { launchctl list "$watcher_label" 2>/dev/null | sed -nE 's/.*"PID" = ([0-9]+);.*/\1/p'; }

# Whether `launchctl list com.saur0n.watch` finds the user's real watcher — its pause would stop the storm's copies.
real_watcher_running() { launchctl list com.saur0n.watch >/dev/null 2>&1; }

# watcher: the built app installed as a test-scoped launchd agent in --watch; 30 copies of the check's script raise
# their warning with no window open; the agent's snapshot log then holds the would-have-acted entry naming the script
# with its figures, no copy was paused, and the agent is still running. The agent is booted out either way.
check_watcher() {
    local exe="$PWD/.build/Saur0n.app/Contents/MacOS/Saur0nApp" uid snap plist pid cmdline started json entry
    local seconds tries=0 stopped pause_note summary windows=unread
    trap 'stop_watcher; stop_copies' EXIT
    trap 'echo "watcher: interrupted"; exit 130' INT TERM HUP
    uid=$(id -u)
    build_window || return 1
    build || return 1
    watcher_dir=$(mktemp -d /tmp/saur0n-watcher.XXXXXX)
    snap=$watcher_dir/snapshots
    plist=$watcher_dir/$watcher_label.plist
    mkdir -p "$snap"
    cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$watcher_label</string>
  <key>ProgramArguments</key><array>
    <string>$exe</string>
    <string>--watch</string>
    <string>-acting.pause.copies</string><string>NO</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>SAUR0N_SNAPSHOT_DIR</key><string>$snap</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$watcher_dir/watch.out.log</string>
  <key>StandardErrorPath</key><string>$watcher_dir/watch.err.log</string>
</dict></plist>
PLIST
    plutil -lint "$plist" >/dev/null || { echo "watcher: FAIL — the test agent's plist does not lint"; return 1; }
    launchctl bootstrap "gui/$uid" "$plist" 2>"$watcher_dir/bootstrap.err" ||
        { echo "watcher: FAIL — launchctl bootstrap refused $watcher_label: $(cat "$watcher_dir/bootstrap.err")"; return 1; }
    watcher_loaded=1
    # launchd's first PID for the label can be the xpcproxy that execs the app: wait for the app's own command line.
    cmdline=""
    until [[ $cmdline == *"--watch"* ]]; do
        pid=$(watcher_pid)
        [[ -z $pid ]] || cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
        [[ $cmdline == *"--watch"* ]] && break
        ((++tries <= 40)) || { echo "watcher: FAIL — $watcher_label never ran the app in --watch (last '$cmdline', pid ${pid:-none})"; return 1; }
        sleep 0.5
    done
    # No window at launch (calibration lock 1), read through accessibility: a window read is a failure; the terminal
    # having no Accessibility grant (exit 3) or no window (exit 1, "no window titled Saur0n") is not.
    local read_rc=0 window_out
    window_out=$(.build/read-window "$pid" state 2>&1) || read_rc=$?
    case $read_rc in
        0) windows=$(jq -r .windows <<<"$window_out")
           [[ $windows -eq 0 ]] ||
               { echo "watcher: FAIL — the app in --watch opened $windows window(s): $window_out"; return 1; } ;;
        1) [[ $window_out == *"no window titled Saur0n"* ]] ||
               { echo "watcher: FAIL — cannot read the app's windows: $window_out"; return 1; }
           windows=0 ;;
        *) : ;;    # 3: no Accessibility grant this terminal; the claim is read on a machine that has one
    esac
    # The storm: 30 copies of the check's script, each with a busy child, as the copies check raises them. Twenty
    # seconds first: the engine counts growth from the fewest copies in its 10-second buckets, so the agent must have
    # a bucket holding no copies before the storm starts — otherwise the copies are their own baseline and no
    # warning raises (the same rule the copies check's fresh-storm comment names).
    sleep 20
    started=$(date +%s)
    start_copies 0.2 || { echo "watcher: FAIL — the storm did not start"; return 1; }
    while :; do
        json=$(SAUR0N_SNAPSHOT_DIR="$snap" .build/debug/saur0n snapshots --json 2>/dev/null) || json=""
        entry=$(jq -c --arg script "$copies_script_name" --arg prefix "would act: " \
            '[.[] | select(.reason == "warning" and (.detail | startswith($prefix)) and (.detail | contains($script)))]
             | first // empty' <<<"${json:-[]}" 2>/dev/null) || entry=""
        [[ -z $entry ]] || break
        # A busy machine can space the watcher's windows past a second, which restarts the warning's hold: give the
        # storm the minute and a half the copies check's own burn-in allows for.
        (($(date +%s) - started <= 90)) || break
        sleep 1
    done
    seconds=$(($(date +%s) - started))
    # The dry run signals nothing: with the user's own watcher out of the picture, no copy reads stopped. Counted
    # before the storm is stopped, while the copies are still alive to read.
    stopped=$(stopped_copies | wc -l | tr -d ' ')
    stop_copies
    [[ -n $entry ]] ||
        { echo "watcher: FAIL — the agent logged no would-act entry naming $copies_script_name within 90 s of the storm (log: $(SAUR0N_SNAPSHOT_DIR="$snap" .build/debug/saur0n snapshots 2>&1 | head -5); agent stderr: $(head -5 "$watcher_dir/watch.err.log" 2>/dev/null))"; return 1; }
    if real_watcher_running; then
        pause_note="com.saur0n.watch is installed, so copies paused by it are not counted"
    elif [[ $stopped -eq 0 ]]; then
        pause_note="no copy paused (acting.pause.copies off)"
    else
        echo "watcher: FAIL — $stopped copies read stopped while acting was off"; return 1
    fi
    [[ -n $(ps -p "$pid" -o pid= 2>/dev/null) ]] || { echo "watcher: FAIL — the agent's process ($pid) is gone"; return 1; }
    summary="agent pid $pid in --watch, windows $windows, would-act entry ${seconds} s into the storm '$(jq -r '.detail' <<<"$entry")'; $pause_note"
    echo "watcher: ok ($summary)"
}

orphans_count=20 orphans_seconds=60 orphans_dir=""

# The 2026-10-22 shape, bounded: a launcher (`/bin/bash`, whose environment reads back empty: probe 2026-10-24) that
# `nohup`s $orphans_count copies of itself with `&` and exits, so each copy lands under launchd at birth, keeping this
# check's process group. Each copy works in the scratch folder (no repo), starts one throttled busy child (a perl loop
# busy 20% of each 100 ms that ends by itself after $orphans_seconds s, so nothing outlives a killed check) and records
# "<pid> <start>" for itself and its child the moment both exist; the launcher records itself first. Waits until every
# copy has recorded, at most 10 s.
start_orphans() {
    local tries=0
    orphans_dir=$(mktemp -d /tmp/saur0n-orphans.XXXXXX)
    printf '%s\n' '#!/bin/bash' \
        '# Generation 0 starts the copies and exits; a copy starts a busy child, records both, then waits.' \
        'record() { ps -o pid=,lstart= -p "$1" >>"$2/pids"; }' \
        'if [[ $1 == launch ]]; then' \
        '    record $$ "$2"' \
        '    for ((i = 0; i < $3; i++)); do nohup /bin/bash "$0" copy "$2" "$4" >/dev/null 2>&1 & done' \
        '    exit 0' \
        'fi' \
        'cd "$2" || exit 1' \
        "perl -MTime::HiRes=time,sleep -e 'my \$end = time + shift; while (time < \$end) { my \$t = time + 0.02; 1 while time < \$t; sleep 0.08 }' \"\$3\" \"\$0\" &" \
        'record $$ "$2"; record $! "$2"; echo "$$ $!" >>"$2/pairs"' \
        'wait' >"$orphans_dir/orphan-storm.sh"
    /bin/bash "$orphans_dir/orphan-storm.sh" launch "$orphans_dir" "$orphans_count" "$orphans_seconds"
    until [[ -f $orphans_dir/pairs && $(wc -l <"$orphans_dir/pairs") -ge $orphans_count ]]; do
        ((++tries <= 100)) || { echo "orphans: FAIL — only $(wc -l <"$orphans_dir/pairs" 2>/dev/null || echo 0) of $orphans_count copies recorded"; return 1; }
        sleep 0.1
    done
}

# Pids under launchd that launchd's own rule leaves alone: leading their own group, or not this user's; text-sorted
# for `comm`.
launchd_agents() { ps -ax -o pid=,ppid=,pgid=,uid= | awk -v me="$(id -u)" '$2 == 1 && ($3 == $1 || $4 != me) { print $1 }' | sort; }

# Launchd's own agents ($1's rows under launchd that `launchd_agents` lists) in session $2, text-sorted.
agents_in() {
    jq -r --arg session "$2" '.processes[] | select(.ppid == 1 and .session.id == $session) | .pid' <<<"$1" | sort |
        comm -12 - <(launchd_agents)
}

# Stops each recorded pid that still has its recorded start time and names the scratch folder (a reused pid has
# neither). `ps -o lstart=` alone pads the time with spaces on both sides.
stop_orphans() {
    local pid started
    [[ -n $orphans_dir && -f $orphans_dir/pids ]] || return 0
    while read -r pid started; do
        [[ $(ps -o lstart= -p "$pid" 2>/dev/null | sed -E 's/^ +| +$//g') == "$started" &&
            $(ps -o command= -p "$pid" 2>/dev/null) == *"$orphans_dir"* ]] && kill "$pid" 2>/dev/null || true
    done <"$orphans_dir/pids"
    orphans_dir=""
}

# The recorded copies as a JSON array: [{pid, child}].
orphans_recorded() { jq -Rsc '[split("\n")[] | select(. != "") | split(" ") | {pid: (.[0] | tonumber), child: (.[1] | tonumber)}]' <"$orphans_dir/pairs"; }

# orphans: the bounded storm's copies, read through `saur0n --json`, sit under the repo and session of this check's
# process group leader, each marked orphaned, their busy children with them and not marked; `newUnderLaunchd` counts
# at least the copies; and launchd's own agents stay put — every process under launchd that leads its own group, or is
# root's or another user's, is unmarked, and none of them joined the leader's session during the storm.
check_orphans() {
    local group json leader session repo copies before during moved wrong marked newcomers summary
    build
    trap 'stop_orphans; trap - RETURN EXIT INT TERM HUP' RETURN EXIT
    trap 'echo "orphans: interrupted"; exit 130' INT TERM HUP
    group=$(ps -o pgid= -p $$ | tr -d ' ')
    json=$(saur0n --json --interval 1)
    session=$(jq -r --argjson g "$group" '[.processes[] | select(.pid == $g) | .session.id // empty] | first // empty' <<<"$json")
    [[ -n $session ]] || { echo "orphans: FAIL — this check's process group leader ($group) has no session in Saur0n; run it from a Claude Code session, tmux or a terminal tab"; return 1; }
    before=$(agents_in "$json" "$session")
    start_orphans || return 1
    copies=$(orphans_recorded)
    sleep 1    # each child's first busy second
    json=$(saur0n --json --interval 2)
    leader=$(jq -c --argjson g "$group" '[.processes[] | select(.pid == $g)] | first // empty' <<<"$json")
    [[ -n $leader ]] || { echo "orphans: FAIL — the group leader $group is not in Saur0n's rows"; return 1; }
    session=$(jq -r '.session.id // empty' <<<"$leader")
    repo=$(jq -r '.repo.root // empty' <<<"$leader")
    wrong=$(jq -r --argjson copies "$copies" --arg session "$session" --arg repo "$repo" '
        (.processes | map({(.pid | tostring): .}) | add) as $rows
        | $copies[] | . as $c
        | ($rows[$c.pid | tostring]) as $copy | ($rows[$c.child | tostring]) as $child
        | if $copy == null or $child == null then "\($c.pid)/\($c.child) missing from the rows"
          elif $copy.ppid != 1 then "copy \($c.pid) is not under launchd (parent \($copy.ppid))"
          elif ($copy.orphaned | not) then "copy \($c.pid) not marked orphaned"
          elif $child.orphaned then "child \($c.child) marked orphaned"
          elif ($copy.session.id // "") != $session or ($child.session.id // "") != $session then
              "copy \($c.pid) in session \($copy.session.name // "none"), child in \($child.session.name // "none")"
          elif ($copy.repo.root // "") != $repo then "copy \($c.pid) in repo \($copy.repo.name // "none")"
          else empty end' <<<"$json" | head -3)
    summary="leader $group in $(jq -r '"session \(.session.name // "none"), repo \(.repo.name // "none")"' <<<"$leader")"
    [[ -z $wrong ]] || { echo "orphans: FAIL — $summary; ${wrong//$'\n'/; }"; return 1; }
    marked=$(jq '[.processes[] | select(.orphaned)] | length' <<<"$json")
    wrong=$(jq -r '.processes[] | select(.ppid == 1 and .orphaned) | .pid' <<<"$json" | sort |
        comm -12 - <(launchd_agents) | head -3 | tr '\n' ' ')
    [[ -z $wrong ]] || { echo "orphans: FAIL — launchd's own agents marked orphaned: $wrong"; return 1; }
    during=$(agents_in "$json" "$session")
    moved=$(comm -13 <(echo "$before") <(echo "$during") | grep -E '^[0-9]+$' | head -3 | tr '\n' ' ' || true)
    [[ -z $moved ]] || { echo "orphans: FAIL — launchd's own agents joined the leader's session during the storm: $moved"; return 1; }
    newcomers=$(jq -c '.newUnderLaunchd // empty' <<<"$json")
    [[ -n $newcomers && $(jq .count <<<"$newcomers") -ge $orphans_count ]] ||
        { echo "orphans: FAIL — newUnderLaunchd reads '${newcomers:-absent}', want a count of at least $orphans_count"; return 1; }
    summary+=", $orphans_count copies and their children with it, $marked rows marked orphaned"
    summary+=", $(echo "$during" | grep -cE '^[0-9]+$' || true) launchd agents in that session before and after, newUnderLaunchd $newcomers"
    echo "orphans: ok ($summary)"
}

# --- dock (Phase 6 Step 9): the Dock icon's step under a load, and its "!" badge while a warning lasts ---

dock_dir="" dock_seconds=30

# The launched app's Dock changes since $1 (a `log show --start` time), oldest first, as the app logs each one:
# "step=<1-5> cpu=<1-5> memory=<1|3|5> border=<none|orange|red> badge=<0|1>". The tile's image cannot be read.
dock_lines() {
    /usr/bin/log show --style compact --start "$1" \
        --predicate "subsystem == \"app.saur0n.monitor\" AND category == \"dock\" AND processID == $app_pid" |
        sed -nE 's/.* dock (step=.*)$/\1/p'
}

# The latest Dock state since $1, or the state at rest when nothing changed yet.
dock_now() { dock_lines "$1" | tail -1 | grep . || echo "step=1 cpu=1 memory=1 border=none badge=0"; }

# Field $1 of a state line on stdin.
dock_field() { sed -nE "s/^(.* )?$1=([a-z0-9]+).*/\2/p"; }

# The Dock's own item for this check's bundle: {found, label, running} (read-window dock-badge, the Dock's pid).
dock_badge() { .build/read-window "$(pgrep -x -U "$(id -u)" Dock | head -1)" dock-badge "$PWD/.build/Saur0n.app"; }

# Waits up to $1 s for the Dock's label to read $2 ("!" or null); prints the seconds taken.
wait_for_badge() {
    local waited=0
    until [[ $(dock_badge | jq -r '.label // "null"') == "$2" ]]; do
        ((waited++ < $1)) || return 1
        sleep 1
    done
    echo "$waited"
}

# Starts one busy perl loop per CPU, each ending by itself after $dock_seconds s (nothing outlives a killed check),
# each recorded as "<pid> <start>" the moment it starts.
start_burners() {
    local i
    dock_dir=$(mktemp -d /tmp/saur0n-dock.XXXXXX)
    for ((i = 0; i < $(sysctl -n hw.ncpu); i++)); do
        perl -MTime::HiRes=time -e 'my $end = time + shift; 1 while time < $end' "$dock_seconds" "$dock_dir" &
        ps -o pid=,lstart= -p $! >>"$dock_dir/pids"
    done
}

# Stops each recorded loop that still has its recorded start time and names the scratch folder (a reused pid has
# neither).
stop_burners() {
    local pid started
    [[ -n $dock_dir && -f $dock_dir/pids ]] || return 0
    while read -r pid started; do
        [[ $(ps -o lstart= -p "$pid" 2>/dev/null | sed -E 's/^ +| +$//g') == "$started" &&
            $(ps -o command= -p "$pid" 2>/dev/null) == *"$dock_dir"* ]] && kill "$pid" 2>/dev/null || true
    done <"$dock_dir/pids"
    dock_dir=""
}

# dock --window: the app launched from this build; (a) Step 4's 30 copies raise a warning and the Dock's own label for
# this bundle reads "!" within 5 s of the bar line, the app's log saying badge=1; the copies stopped, the label clears
# within 25 s (the warning's 10 s clear and a reading); (b) once the copies' load has cleared, one busy loop per CPU for
# $dock_seconds s: within 25 s of the start the logged CPU step rises above the one before the load and to 2 or more
# (the 50% bar, held 10 s); within 60 s of the loops' end it is back to the one before or lower — or, on a machine
# busy enough to hold a step (it clears only after 10 s under 7/8 of its bar), it came down from its peak and the
# window's total stays over that step's 7/8 for the next 10 s, said in the summary. A machine already at
# CPU step 5 before the load cannot show a rise: the check says what it saw and fails. Memory steps are reported, not
# asserted. After the app is stopped the Dock's label for this bundle is gone. Only recorded pids are stopped.
check_dock() {
    local since start ended state lines baseline cpu peak="" border=none rise="" fall="" seconds left held clear summary
    trap 'stop_copies; stop_burners; stop_window' EXIT
    trap 'echo "dock: interrupted"; exit 130' INT TERM HUP
    since=$(date '+%Y-%m-%d %H:%M:%S')
    window_up 3 || return 1
    open_graph cpu || return 1    # the total, read if a busy machine holds a step after the load
    # (a) the badge
    start=$(date +%s)
    start_copies 0.2 || return 1
    wait_for_warning 15 "$start" >/dev/null || { echo "dock: FAIL — no bar line within 15 s of the copies' start"; return 1; }
    seconds=$(wait_for_badge 5 '!') ||
        { echo "dock: FAIL — the bar shows a warning but the Dock's label reads $(dock_badge | jq -c .)"; return 1; }
    [[ $(dock_now "$since" | dock_field badge) == 1 ]] ||
        { echo "dock: FAIL — the Dock shows \"!\" but the app's last Dock line reads '$(dock_now "$since")'"; return 1; }
    summary="badge \"!\" ${seconds} s after the bar line"
    stop_copies
    seconds=$(wait_for_badge 25 null) ||
        { echo "dock: FAIL — the Dock's label still reads $(dock_badge | jq -c .label) 25 s after the copies stopped"; return 1; }
    summary+=", gone ${seconds} s after the copies stopped"
    sleep 12    # the copies' CPU clears from the step, as any load does
    # (b) the step
    state=$(dock_now "$since")
    baseline=$(dock_field cpu <<<"$state")
    summary+="; before the load '$state'"
    ((baseline < 5)) || { echo "dock: FAIL — the machine sat at CPU step 5 (95% or more) before the load, so no rise can show: '$state'; rerun when it is quieter"; return 1; }
    start=$(date +%s)
    start_burners
    while (($(date +%s) - start <= 25)); do
        state=$(dock_now "$since")
        cpu=$(dock_field cpu <<<"$state")
        if ((cpu > baseline && cpu >= 2)); then
            rise=$(($(date +%s) - start))
            break
        fi
        sleep 1
    done
    [[ -n $rise ]] || { echo "dock: FAIL — no CPU step rise within 25 s of $(sysctl -n hw.ncpu) busy loops; last '$state' ($summary)"; return 1; }
    # The loops end by themselves; the peak is the highest CPU step and border logged while they ran.
    ended=$((start + dock_seconds))
    left=$((ended - $(date +%s)))
    ((left <= 0)) || sleep "$left"
    stop_burners
    lines=$(dock_lines "$since")    # one `log show`: each takes seconds
    peak=$(dock_field cpu <<<"$lines" | sort -n | tail -1)
    if grep -q 'border=red' <<<"$lines"; then border=red
    elif grep -q 'border=orange' <<<"$lines"; then border=orange; fi
    summary+="; CPU step above $baseline in ${rise} s, up to $peak, border $border at most"
    # 60 s from the loops' end: each step clears only after 10 s under 7/8 of its bar, and a Mac whose own load wavers
    # near the lowest of those (43.75%) took 32 s to come back to step 1 (2026-10-24, the log's times).
    while (($(date +%s) - ended <= 60)); do
        state=$(dock_now "$since")
        if (($(dock_field cpu <<<"$state") <= baseline)); then
            fall=$(($(date +%s) - ended))
            break
        fi
        sleep 1
    done
    if [[ -n $fall ]]; then
        summary+=", back to '$state' by ${fall} s after the load ended"
    else
        # A busy Mac can hold a step after the load. Then the step must have come down from its peak and the window's
        # own total must stay over that step's 7/8 for the next 10 s.
        cpu=$(dock_field cpu <<<"$state")
        held=$(read_window totals 10 | jq '.totals | min') || { echo "dock: FAIL — cannot read the window's total"; return 1; }
        clear=$(awk -v s="$cpu" 'BEGIN { split("50 65 80 95", bar, " "); printf "%.2f", bar[s - 1] * 7 / 8 }')
        ((cpu < peak)) && awk -v h="$held" -v c="$clear" 'BEGIN { exit !(h >= c) }' ||
            { echo "dock: FAIL — the CPU step did not fall back to $baseline within 60 s of the load's end; last '$state', the window's lowest total over the next 10 s $held%, step $cpu clears under $clear% ($summary)"; return 1; }
        summary+=", down to '$state' 60 s after the load ended, held there by the machine's own load (the window's total at least $held% over the next 10 s, step $cpu clears under $clear%)"
    fi
    summary+="; $(dock_lines "$since" | wc -l | tr -d ' ') Dock changes in all"
    quit_app
    sleep 1
    [[ $(dock_badge | jq -r '.label // "null"') == null ]] ||
        { echo "dock: FAIL — after the app stopped the Dock's label reads $(dock_badge | jq -c .)"; return 1; }
    echo "dock: ok ($summary; no label after quit)"
}

case $check in
    dock) ((window)) || usage; check_dock ;;
    orphans) ((window == 0)) || usage; check_orphans ;;
    snapshot) ((window == 0)) || usage; check_snapshot ;;
    watcher) ((window == 0)) || usage; check_watcher ;;
    warn) ((window)) || usage; check_warn ;;
    warning-safety) ((window)) || usage; check_warning_safety ;;
    runaway) ((window)) || usage; check_runaway ;;
    runaway-join) ((window)) || usage; check_runaway_join ;;
    copies) if ((window)); then check_copies_window; else check_copies; fi ;;
    load) if ((window)); then check_load_window; else check_load; fi ;;
    kill) ((window)) || usage; check_kill ;;
    dependants) ((window)) || usage; check_dependants ;;
    disk-total) if ((window)); then check_disk_total_window; else check_disk_total; fi ;;
    disk-load) if ((window)); then check_disk_load_window; else check_disk_load; fi ;;
    network-total) if ((window)); then check_network_total_window; else check_network_total; fi ;;
    network-load) if ((window)); then check_network_load_window; else check_network_load; fi ;;
    layout) ((window)) || usage; check_layout ;;
    overhead) ((window == 0)) || usage; check_overhead ;;
    exited-cpu) check_exited_cpu ;;
    core-types) check_core_types ;;
    cpu-total) if ((window)); then check_cpu_total_window; else check_cpu_total; fi ;;
    readable-names) check_readable_names ;;
    vm-cores) check_vm_cores ;;
    repo-groups) check_repo_groups ;;
    *) usage ;;
esac
