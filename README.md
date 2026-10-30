# Saur0n

A native macOS process monitor for a developer running agents, swarms and VMs. It shows what is eating the machine in terms you recognize:
- CPU as a share of the whole machine (100% = every core busy), not Apple's 100% per core.
- Per-core load grouped under the core types the Mac itself reports.
- Every running process, root-owned ones included.

The command-line tool and window share one sampling engine. Group processes by git repo, terminal session or command; see CPU, memory, disk and network activity; inspect readable names and VM core allocations; and keep local snapshots of warnings and spikes. The window adds searchable, resizable process rows, graphs, themes, and Quit / Force Quit / Pause / Resume controls.

Watch mode can run without a window and automatically pause a copies storm. Resource-level alerts have provisional starting settings but stay **off**: they report **unavailable**, not normal. Switching them on requires separate approval after a demo.

## Requirements

- macOS 14 or later on Apple silicon.
- Swift 6 or later via Apple's Command Line Tools. Xcode is not required.
- No third-party Swift packages.

If Command Line Tools are not installed, run `xcode-select --install` and complete Apple's installer. Run the following commands from the repository's root folder.

## Build

```sh
swift build --jobs 4
bash scripts/test.sh --jobs 4
```

Build and open the window app:

```sh
SAUR0N_BUILD_JOBS=4 bash scripts/make-app.sh
open .build/Saur0n.app
```

The app script builds the release CLI and an ad-hoc-signed app bundle. It does not install either or create a login agent. Drag `.build/Saur0n.app` to Applications if you want to keep it there.

## Run

```sh
swift run saur0n                 # table: total, per-core load by core type, every process
swift run saur0n --json          # the same, for scripts
swift run saur0n --interval 5    # sample over 5 seconds (default 1, range 0.1–10)
swift run saur0n --by session    # group by the session that started each process, not by repo
swift run saur0n --by command    # group by command: "runaway.sh × 30", each script copy with everything it started
swift run saur0n --count 0       # keep sampling, each sample with the warnings in force (n samples; 0 = until interrupted)
swift run saur0n snapshots       # the window's snapshots, oldest first: when, why, CPU, Unattributed, processes, size
swift run saur0n snapshot 14:03  # the table as it was at the latest snapshot at or before 14:03 today
swift run saur0n snapshot 2026-10-24 14:03:07 --by command   # a date and seconds too; --by and --json as above
```

The window keeps a snapshot when a warning starts (again every 5 minutes while it lasts), at a spike on a graph (at
most one a minute) and when you press the camera button, "Snapshot now", beside Refresh. Each holds the machine, its
last minute, the process table as it was in all three groupings — every group's figures and count, the processes of
the ten busiest groups of each and of every warned group — and for each kept process its parent, process group, start
time, path and, for your own processes, arguments and folder. They go in
`~/Library/Application Support/Saur0n/snapshots.sqlite`, at most 200 MB, the oldest dropped first; only the window
writes it, and the command line only reads it. `SAUR0N_SNAPSHOT_DIR=<folder>` points both at another folder.

A process a shell left behind under launchd (`nohup … &`, then the shell exits) still belongs to that shell's
process group. Saur0n marks it `[orphaned]` (`"orphaned": true` in the JSON) and ties it to the group's repo and
session when a member in the same scan supplies them. The window also remembers earlier ties, as described below;
the one-shot command line does not. When Unattributed CPU reaches 5%, its line also names what
launchd started in the last minute: "40 processes under launchd started in the last minute, most common: sleep × 40".

Each sample also ends with the machine's memory — for example, `available 8.1 G of 64 G`, counting free, inactive, speculative and purgeable pages, with swap when it can be read — and a `Levels` line. The provisional resource-alert settings use active + wired + compressed memory as a share of physical RAM: 80% held 10 seconds, 90% held 5 seconds and 95% held 2 seconds, clearing below 75%, 85% and 92% respectively. CPU uses a 30-second sustain instead of those memory holds. The independent time-to-memory-floor estimate tries 60-second then 180-second windows, with at least ten readings and a decline of at least 1 MiB/s. These starting values are provisional, not measured memory calibration; see `research/2026-10-29-step2-calibration-proposal.md`.

Resource alerts remain off by default: the app selects the provisional values only for an explicit Bool `true` at `resource.levels.enabled`. Activation needs separate approval after a demo; the live-status and menu-bar switches stay off too. The CLI does not read the app's defaults and keeps resource alerts off, printing `Levels  unavailable — resource alerts off`, never normal. The memory figures remain available.

### Watch mode — the watcher

```sh
bash scripts/make-app.sh                  # builds .build/Saur0n.app
bash scripts/install-agent.sh             # loads ~/Library/LaunchAgents/com.saur0n.watch.plist: the app in --watch from login
bash scripts/install-agent.sh --uninstall # boots it out and removes the plist
```

The agent runs the same app with `--watch`: the sample loop, the warning engine, the snapshot log and the pause ledger
start with the app whether or not a window is open, and no window is shown at launch (macOS 15's scene launch
behaviour; on macOS 14 the window is closed as it appears). Opening Saur0n from the Dock or Finder shows the window in
the same process — Window ▸ Open Saur0n too — and the window reads the same engine. The agent's standard output and
error go to `~/Library/Logs/Saur0n/`; a copy dragged to `/Applications` is the one to install
(`SAUR0N_APP=$HOME/Applications/Saur0n.app bash scripts/install-agent.sh`).

The acting switch is three `UserDefaults` keys, read on every tick: `acting.pause.copies` (on), `acting.pause.memory`
(off) and `acting.throttle` (off). With a rung's switch on, a warning that carries it is acted on — this step pauses a
copies storm's processes through the warning bar's own Pause, each process checked by pid and start time first, and
records what it paused in `pause-ledger.json` beside the snapshot log; the next start resumes everything the ledger
holds, so a restart never leaves processes frozen. With the switch off the warning is logged instead, its figures and
the reason included, in the same snapshot log (`saur0n snapshots` lists the entries as `warning`, their detail
starting `would act:`).

### The window

```sh
bash scripts/make-app.sh         # builds .build/Saur0n.app (icon included) and .build/release/saur0n, so the command-line tool is as new as the window
open .build/Saur0n.app           # or double-click it in Finder; drag it to Applications to keep it
```

The window remembers each own-user process group's last known session and repo while the group has any member,
forgetting it on the first empty scan. An orphan with no live tied member uses that memory, so it can stay with its
session and repo after its launching shell exits even when the one-shot CLI can no longer tie it back.

The window refreshes once a second. Across the top, one row of three cells, each with its figures over a
60-second sparkline: CPU (the whole machine's total), Memory (used of physical — active, wired and compressed
memory, as Activity Monitor's "Memory Used" counts it) and Disk & Network (read and write, in and out). Click a
cell to open its full graph under the row, click it again to close it; one is open at a time, and the window
remembers which. CPU opens one 60-second graph per core type (the newest second at the right edge) and a "Cores
(N)" row that opens onto one strip per core; Memory a graph of used memory with the five largest processes by
memory; Disk & Network the two rate graphs, each with the five processes that moved the most bytes in the last
minute. Under them is the process table, grouped by repo — the toolbar's "Repo / Sesh / Cmd" switches to sessions or commands (each script's copies on one line), "Collapse all" / "Expand all" folds or opens every group, a
group's triangle folds just that group, a column header re-sorts, "Pause" stops refreshing while the window
keeps what it shows, and "Refresh" (⌘R) reads now and re-sorts — while paused it takes one reading and stays
paused. Sorted by Name, PID, User or Session the rows hold still: the numbers update in place, a new process takes
its sorted place, and one that ends stays greyed with empty figures for a minute, or until the next sort, fold or
Refresh. Greyed means ended: a process that moves to another group leaves no greyed copy behind, and a greyed row is
never what Quit, Force Quit or Pause act on, nor a search match. Sorted by CPU, Memory, Disk or Network the order
follows the figures. "Search" in the toolbar filters as you type:
a process stays when its name, readable name, pid, user, session or group contains the text, under its group, which
opens and reads "N of M processes"; Escape clears it. Drag a header's edge to widen or narrow its column; the
widths are kept for the next launch. Name takes what is left: dragging Name's own edge trades width evenly with the
columns to its right, so the table always fits the window, and the window's minimum width grows with the columns so
no column is cut off. The window opens whole: every figure reads "—" until its first reading, about a second
after launch, and then everything fills in together.

The colours come from the app icon and sit on the lines; every figure is in the window's text colour, and where one
graph draws several lines a short sample of each line stands before its figure. The **Ember & Steel** theme puts
flame colours on the hot lines (Super and Performance cores, Disk write, Network out, Memory), a steel blue on
Efficiency and Disk read and a teal on Network in, and the flame red-orange on the open cell's border and the
window's controls; the Paused badges take the flame base. Saur0n ▸ Settings… (⌘,) offers **Two-colour** as a high-contrast
theme that also tells lines apart by style (blue for what comes in, orange for what goes out and for Memory; Network
dashed, Performance dashed, Efficiency dotted), and a box, on by default, that shows Two-colour while System
Settings ▸ Accessibility ▸ Display ▸ Increase contrast is on. **Appearance** there is System (the Mac's light or
dark, the default), Light or Dark. A selected row keeps the Mac's own accent colour, and the toolbar's symbols stay
the system's.

When something runs away — a script copying itself, a group holding a quarter of the machine for ten minutes, the
load or the system share past their bars — a bar above the table shows one line per runaway, starting "!", with
Details (what it tripped, with the figures, and its group selected), Pause (every process of it, at once; the button
then reads Resume), Stop… (Quit through the sheet below) and Ignore (a command stays ignored until you undo it in
Settings; a repo or session only until its warning clears). The group it names goes to the top of the table under
every sort with a warning triangle. Busy CPU, Disk and Network cells are shaded in four steps, and a burst on a graph
gets a dashed mark naming the busiest process at that second. Paused, the toolbar shows a pause icon in place of
the word.

Select a process, an app's sub-group or a whole group and the Process menu's "Quit", "Force Quit" and "Pause" act
on it (the same three are in a row's right-click menu). An app quits as the app does from its own Quit menu, so it can
save; anything else gets SIGTERM, and Force Quit SIGKILL — unsaved work is lost. Pause stops the process where it
is (SIGSTOP): its CPU drops to zero, it keeps its memory, its row shows "paused", and the button reads "Resume".
Before anything happens a sheet names what goes down with it: "Also ends" — everything started under it, by kind
(Claude Code sessions by name, test runs, VMs, shells) — and "Used by (TCP)" — processes connected to a port it
listens on, such as the sessions talking to a local API proxy; a process launchd started is marked as one that may
come back. The button reads "Quit all N" when anything is listed, and the processes are ended children first.
Right before it acts Saur0n looks each process up again by pid and start time, and refuses if it is gone or its
pid now belongs to another process. A process owned by root or another user is refused by macOS; the sheet then
offers "Quit as administrator…", which shows the system's own password dialog and runs only `kill -<signal> <pid>`
as root — nothing is installed and no password is kept.

## Test

```sh
bash scripts/test.sh --jobs 4
bash scripts/test.sh --jobs 4 --filter CoreTopology
```

`scripts/test.sh` supplies the Swift Testing macro-plugin path when Command Line Tools are selected. Use it instead of plain `swift test` in that setup.

Optional live checks compare actual readings with macOS tools:

```sh
bash scripts/check-live.sh core-types
bash scripts/check-live.sh cpu-total
bash scripts/check-live.sh core-types --window
```

Window checks require the running app and an Accessibility grant for the terminal. The script also includes load, network-download, process-control and login-agent checks; read their usage and implementation before running them, because they start workloads or manipulate their own test processes. They are not part of the unit-test command.

## Licence

Copyright (C) 2026 Comandante-Supremo.

Saur0n is licensed under the GNU General Public License, version 3 or (at your option) any later version (`GPL-3.0-or-later`). See [LICENSE](LICENSE) for the full text. It comes without warranty.
