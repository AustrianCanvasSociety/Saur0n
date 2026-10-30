// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import Observation
import os
import Saur0nCore

/// What the window shows, refreshed once a second. All view state lives here: Command Line Tools cannot
/// build SwiftUI's `@State` on the macOS 27 SDK (CLAUDE.md § Toolchain).
@MainActor @Observable
final class MonitorModel {
    fileprivate nonisolated static let log = Logger(subsystem: "app.saur0n.monitor", category: "watcher")
    /// Where the Cores row's open state is remembered (the app's own defaults domain).
    static let coresOpenKey = "coresOpen"

    private(set) var topology: CoreTopology?
    private(set) var history: CPUHistory?
    /// The last read that failed — topology at launch, the CPU load, the process scan or a disk or network read
    /// since — or nil.
    private(set) var error: String?
    var coresOpen: Bool {
        didSet { UserDefaults.standard.set(coresOpen, forKey: Self.coresOpenKey) }
    }
    /// Which graph row cell has its graph open under the row, remembered as the Cores row is (Backlog
    /// window-graph-area-space).
    static let openGraphKey = "openGraph"
    var openGraph: OpenGraph {
        didSet { UserDefaults.standard.set(openGraph.rawValue, forKey: Self.openGraphKey) }
    }
    /// The width a full-width vertical scroll bar takes beside the table's rows, as the table measures it
    /// (`TableFixes`): 0 while macOS shows overlay scroll bars, the bar's width while it shows full-width ones (a mouse
    /// connected, or "Always" in System Settings) — then Name gives it up, so no sideways scroll bar appears.
    var scrollerWidth = 0.0
    /// The colours every view draws with, as Settings sets them (Backlog window-theme).
    let theme = ThemeModel()

    /// Where the value columns' widths are remembered, as one JSON value (Backlog resizable-columns).
    static let columnWidthsKey = "columnWidths"
    /// The value columns' widths as the user last dragged them; Name takes the rest and the window's minimum width
    /// follows them.
    private(set) var columnWidths = ProcessTable.ColumnWidths(saved: UserDefaults.standard.data(forKey: columnWidthsKey)) {
        didSet { UserDefaults.standard.set(columnWidths.saved, forKey: Self.columnWidthsKey) }
    }

    /// A header divider dragged: each value column's width as the table now has it, by header title; or, when the
    /// dragged column is Name, Name's new width traded with the value columns (`ColumnWidths.resizeName`).
    func columnsResized(dragged: String, _ byTitle: [String: Double], tableWidth: Double) {
        let titles: [String: ProcessTable.Column] = ["PID": .pid, "User": .user, "CPU": .cpu, "Memory": .memory,
                                                     "Disk": .disk, "Network": .network, "Session": .session]
        var widths = columnWidths
        if dragged == "Name", let name = byTitle["Name"] {
            widths.resizeName(to: name, tableWidth: tableWidth)
        } else {
            for (title, width) in byTitle { if let column = titles[title] { widths.set(column, width) } }
        }
        if widths != columnWidths { columnWidths = widths }
    }

    /// Refreshes applied so far. The window shows it to accessibility so a reader can tell whether its reads
    /// all came from one refresh (`scripts/read-window.swift`).
    private var refreshProgress = RefreshProgress()
    var refreshes: Int { refreshProgress.count }
    /// The table as shown: the last refresh's rows under `grouping`, sorted by `sortOrder`; under a sort by Name, PID,
    /// User or Session in the order the table had, until the sort, the grouping, a fold or Refresh changes it, ended
    /// processes greyed for a minute.
    private(set) var lines: [ProcessTable.Line] = [] {
        didSet { shownLines = ProcessTable.filtered(lines, by: searchText) }
    }
    /// The toolbar's search field; the table shows `lines` filtered by it (`ProcessTable.filtered`).
    var searchText = "" {
        didSet { shownLines = ProcessTable.filtered(lines, by: searchText) }
    }
    /// What the table shows: `lines`, or the rows matching the search under their groups.
    private(set) var shownLines: [ProcessTable.Line] = []
    var searching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    var grouping = ProcessTable.Grouping.repo {
        didSet { rebuildLines(keepingOrder: false) }
    }
    var sortOrder = [KeyPathComparator(\ProcessTable.Line.cpuPercent, order: .reverse)] {
        didSet { rebuildLines(keepingOrder: false) }
    }
    /// The toolbar's Pause: while set, the loop takes no samples and the window keeps its last refresh.
    var paused = false {
        didSet { pause.setPaused(paused) }
    }
    let pause = RefreshPause()
    /// Which groups are open: each group's default, or all closed / all open after the toolbar's fold button,
    /// with the groups the user toggled since flipped (`ProcessTable.Folding`).
    private var folding = ProcessTable.Folding()
    private var latest: ProcessRefresh?
    /// The machine's disk (read, write) and network (in, out) over the last minute: the two rate graphs.
    private(set) var diskHistory = RateHistory()
    private(set) var networkHistory = RateHistory()
    /// The strips under them, one per grouping so a strip's group names match the table's.
    private var diskMovers: [ProcessTable.Grouping: TopMovers] = [:]
    private var networkMovers: [ProcessTable.Grouping: TopMovers] = [:]
    var diskTop: [TopMovers.Mover] { diskMovers[grouping]?.top() ?? [] }
    var networkTop: [TopMovers.Mover] { networkMovers[grouping]?.top() ?? [] }
    /// Used memory over the last minute (the Memory cell and graph), and the five largest processes now, one list per
    /// grouping as the strips are.
    private(set) var memoryHistory = MemoryHistory()
    /// The 1-minute load, the system share and launches a second over the last minute: the CPU graph's last three.
    private(set) var loadHistory = LoadHistory()
    private var largestByMemory: [ProcessTable.Grouping: [TopMovers.Mover]] = [:]
    var memoryTop: [TopMovers.Mover] { largestByMemory[grouping] ?? [] }
    /// The latest machine rates, for the graphs' headers.
    var disk: DiskUsage? { latest?.disk }
    var network: NetworkUsage? { latest?.network }
    /// "window <start> <end>" in epoch seconds: when the reads behind a header's rates were taken, for the live
    /// checks (empty before the first rates).
    var diskWindowHint: String { latest?.diskWindow.map { Self.windowHint($0.start, $0.end) } ?? "" }
    var networkWindowHint: String { latest?.networkWindow.map { Self.windowHint($0.start, $0.end) } ?? "" }

    static func windowHint(_ start: Double, _ end: Double) -> String { String(format: "window %.3f %.3f", start, end) }

    init() {
        coresOpen = UserDefaults.standard.bool(forKey: Self.coresOpenKey)
        openGraph = OpenGraph(saved: UserDefaults.standard.string(forKey: Self.openGraphKey))
        watchVisibility()
        watchMenus()
        resumePausedOnQuit()
        // The model lives as long as the app, so the task holds it for good.
        Task.detached(priority: .utility) { [self] in
            await Self.sample(into: self)
        }
    }

    /// Whether anyone can see the window. Quiet, the readings go on (the Dock icon and warnings need them) but the
    /// window is not updated; `heldReading` is the last reading taken meanwhile, shown on return.
    @ObservationIgnored private var quiet = QuietState<GraphPoints>()
    @ObservationIgnored private var heldReading: Reading?

    /// The screen lock (`com.apple.screenIsLocked` / `…Unlocked`, distributed) and the app's visibility (Apple's
    /// Energy Efficiency Guide, "Notify Your App When Visibility Changes"); either alone makes the window quiet. With
    /// `SAUR0N_TEST_LOCK_NAMES=1` in its environment the app also takes `app.saur0n.test.screenIsLocked` / `…Unlocked`
    /// as the lock, so a live check can lock it alone: posting the real names would lock every app that hears them.
    /// The model lives as long as the app, so the observers are never removed.
    private func watchVisibility() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        quiet = QuietState(screenLocked: session?["CGSSessionScreenIsLocked"] as? Bool ?? false)
        var lockNames = [("com.apple.screenIsLocked", QuietState<GraphPoints>.Event.screenLocked),
                         ("com.apple.screenIsUnlocked", .screenUnlocked)]
        if ProcessInfo.processInfo.environment["SAUR0N_TEST_LOCK_NAMES"] == "1" {
            lockNames += [("app.saur0n.test.screenIsLocked", .screenLocked), ("app.saur0n.test.screenIsUnlocked", .screenUnlocked)]
        }
        for (name, event) in lockNames {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil,
                                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged(event) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeOcclusionStateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged(.visible(NSApp.occlusionState.contains(.visible))) }
        }
    }

    /// Back in view: the points of every reading taken while quiet, then the last of them shown.
    private func visibilityChanged(_ event: QuietState<GraphPoints>.Event) {
        guard let points = quiet.handle(event), let reading = heldReading else { return }
        heldReading = nil
        show(reading, points: points)
    }

    /// While searching, every group and sub-group shown is open, so each match is in view (a filter that left the
    /// match inside a closed catch-all would show nothing the user can see).
    func isOpen(_ line: ProcessTable.Line) -> Bool { searching || folding.isOpen(line) }

    func setOpen(_ line: ProcessTable.Line, _ open: Bool) {
        guard !searching else { return }
        folding.setOpen(line, open)
    }

    /// Whether any group in the table is open: the toolbar button reads "Collapse all" then, else "Expand all".
    var anyGroupOpen: Bool { folding.anyOpen(lines) }

    /// The toolbar button: folds every group while any is open, else opens every group; gone lines go with it.
    func foldAll() {
        if anyGroupOpen { folding.collapseAll() } else { folding.expandAll() }
        rebuildLines(keepingOrder: false)
    }

    /// The watcher's pause ledger (Phase 7 Step 1): what it paused resumes when the app quits as it does on the next
    /// start — a watcher must never leave processes frozen. The loop's own task resumes at start; this covers a Quit
    /// (a SIGTERM from launchd kills the app without it, and the next start takes it).
    private func resumePausedOnQuit() {
        // The model lives as long as the app, so the observer is never removed.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { _ in
            // An unreadable process list leaves the ledger on disk for the next start (`resumeAll`).
            guard let current = try? ProcessControl.currentIdentities() else { return }
            var ledger = PauseLedger.load(PauseLedger.defaultURL())
            ledger.resumeAll(current: current, signaller: KillSignaller())
            do { try ledger.save(PauseLedger.defaultURL()) } catch {
                MonitorModel.log.error("pause ledger not saved at quit: \(error.localizedDescription)")
            }
        }
    }

    /// Once a second off the main actor: one tick read and one process scan, each closing one window and
    /// opening the next; kernel_task every 30th refresh. The main actor only applies the result. While paused
    /// the loop waits; the sample after a pause only opens a new window, so no refresh covers the pause. Refresh
    /// ends the second's wait at once, or while paused lets one reading through (`RefreshPause.refreshNow`). The
    /// reading's graph and strip points are built here too, off the main actor.
    private nonisolated static func sample(into model: MonitorModel) async {
        var sampler = LoadSampler()
        var refresher: ProcessRefresher?
        // The watcher (Phase 7 Step 1) rides this loop, which starts with the app: detection never waits on a window,
        // and the LaunchAgent's `--watch` start is the same loop with no window at all. What the last run left paused
        // resumes before the first tick, whatever ended it.
        var watcher = resumedWatcher()
        var reportedLedgerError: String?
        var reportedStatusError: String?
        let statusPublisher = ResourceStatusProducer(url: ResourceStatusProducer.defaultURL())
        while !Task.isCancelled {
            let held = await model.pause.waitWhilePaused()
            let ignoring = await model.ignoring
            let load = Result { try sampler.next(topology: SystemReaders.coreTopology, ticks: SystemReaders.cpuTicks) }
            if let topology = sampler.topology {
                if refresher == nil { refresher = ProcessRefresher(topology: topology) }
                refresher?.topology = topology
            }
            let processes = Result { try refresher?.next(load: try load.get(), ignoring: ignoring, watcher: &watcher) }
            var sampledAt: Date?
            var level: ResourceLevel?
            if case .success(let refresh?) = processes {
                let readingAt = Date()
                sampledAt = readingAt
                level = refresh.resourceLevel
                // The approved switches, read on every tick as the acting ones are: off by default, and the only
                // nickname permitted is Pro, so an unswitched or unnamed Mac publishes nothing and is never labelled.
                publish(refresh, load: load,
                        machine: LiveStatusSwitches.machine { UserDefaults.standard.object(forKey: $0) },
                        level: level, sampledAt: readingAt, with: statusPublisher, reportedError: &reportedStatusError)
                // Acting on this tick's new warnings (Phase 7 Step 1): the copies storm pauses through the window's own
                // Pause path, or is logged as a would-have-acted while its rung's switch is off.
                let actions = watcher.decide(
                    warnings: refresh.warnings, rows: refresh.rows,
                    switches: actingSwitches(),
                    current: { try ProcessControl.currentIdentities() }, signaller: KillSignaller())
                if actions.contains(where: { !$0.paused.isEmpty }) {
                    await MainActor.run { model.processPause.recordWatcher(actions, rows: refresh.rows) }
                }
                // A failed ledger write is logged once per distinct reason, not once a second.
                if watcher.ledgerError != reportedLedgerError, let failure = watcher.ledgerError {
                    log.error("pause ledger not saved: \(failure)")
                }
                reportedLedgerError = watcher.ledgerError
                // A due snapshot goes to the writer without the loop waiting on it — the warning's, and one per action.
                if let input = refresh.snapshotInput {
                    let store = model.snapshots
                    if let trigger = refresh.snapshotTrigger {
                        Task.detached(priority: .utility) {
                            await model.snapshotWritten(await store.save(input, trigger), manual: false)
                        }
                    }
                    for action in actions {
                        Task.detached(priority: .utility) {
                            await model.snapshotWritten(await store.save(input, action.trigger), manual: false)
                        }
                    }
                }
            }
            if !held {
                await model.deliver(Reading(load: load, processes: processes, topology: sampler.topology,
                                            sampledAt: sampledAt, level: level))
            }
            await model.pause.sleep(seconds: 1)
        }
    }

    private nonisolated static func resumedWatcher() -> WatcherModel {
        var watcher = WatcherModel(ledgerURL: PauseLedger.defaultURL())
        do {
            try watcher.resumeOnStart(current: try? ProcessControl.currentIdentities(), signaller: KillSignaller())
        } catch {
            log.error("pause ledger not saved at start: \(error.localizedDescription)")
        }
        return watcher
    }

    /// One completed tick's live status, published under `machine` when this Mac is activated: the figures of this
    /// tick only, never the window's kept disk or network rates. A failed write is logged once per distinct reason
    /// and leaves the previous document and its timestamp in place. Nil `machine` publishes nothing, so a Mac
    /// without the approved identity writes nothing and is never labelled as another one.
    nonisolated static func publish(_ refresh: ProcessRefresh, load: Result<CPULoad?, Error>, machine: String?,
                                    level: ResourceLevel?, sampledAt: Date, with publisher: ResourceStatusProducer,
                                    reportedError: inout String?) {
        guard let machine,
              let status = ResourceStatus(sample: ResourceStatus.Sample(
                  sampledAt: sampledAt, intervalSeconds: refresh.intervalSeconds, machine: machine,
                  cpuPercent: (try? load.get())?.total, memory: refresh.memory,
                  disk: refresh.tickDisk, network: refresh.tickNetwork,
                  warningCount: refresh.warnings.count, resourceLevel: statusLevel(level)))
        else { return }
        do {
            try publisher.publish(status)
            reportedError = nil
        } catch {
            let failure = String(describing: error)
            if failure != reportedError {
                log.error("live status not published: \(failure)")
                reportedError = failure
            }
        }
    }

    /// The engine's level in the status vocabulary, mapped case by case — no second reading of the thresholds, and an
    /// uncalibrated engine's nil stays nil rather than becoming `normal`.
    nonisolated static func statusLevel(_ level: ResourceLevel?) -> ResourceStatus.Level? {
        switch level {
        case nil: nil
        case .normal: .normal
        case .notice: .notice
        case .triage: .triage
        case .critical: .critical
        }
    }

    /// The acting switches as the user's defaults hold them now, read on every use so a change takes effect live.
    nonisolated static func actingSwitches() -> ActingSwitches {
        ActingSwitches.read { UserDefaults.standard.object(forKey: $0) }
    }

    /// The Dock icon (Phase 6 Step 9), set from every reading, the window quiet or not.
    @ObservationIgnored private let dock = DockIcon()

    /// A reading from the loop: shown at once, or while quiet its points held and the reading kept for the return.
    /// The Dock icon takes it either way: it is the signal while the window is behind other apps. Occlusion and the
    /// screen lock quiet *this* — the rendering — and nothing upstream of it: the loop, the engine and the watcher run
    /// the same with no window at all (Phase 7 Step 1, calibration lock 2).
    private func deliver(_ reading: Reading) {
        // The reading's own time and level, not the publication's outcome: a failed write does not hide a completed
        // reading.
        if let sampledAt = reading.sampledAt { lastReadingAt = sampledAt }
        resourceLevel = reading.level
        guard !paused || readingWhilePaused else { return }    // sampled before Pause was pressed
        readingWhilePaused = false
        if case .success(let refresh?) = reading.processes {
            dock.show(refresh.dock, badge: DockLevel.badge(refresh.warnings, ignoring: ignoring))
        }
        guard quiet.quiet else { return show(reading, points: reading.points.map { [$0] } ?? []) }
        if let points = reading.points { quiet.hold(points) }
        heldReading = reading
    }

    /// `points` added to the graphs and strips, oldest first, then `reading` shown in the table.
    private func show(_ reading: Reading, points: [GraphPoints]) {
        do {
            for point in points { try append(point) }
            guard try reading.load.get() != nil else { return }
            error = nil
        } catch {
            self.error = "cannot read CPU load: \(error)"
            return
        }
        do {
            guard let refresh = try refreshProgress.accept(reading.processes) else { return }
            latest = refresh
            if !refresh.problems.isEmpty { error = refresh.problems.joined(separator: "; ") }
            ignoredGroups.formIntersection(refresh.raised)
            let ignoring = ignoring
            let inForce = refresh.warnings.filter { !ignoring.contains($0.subject) }
            if inForce != warnings { warnings = inForce }
            if refresh.spikes != spikes { spikes = refresh.spikes }
            spikesEnd = refresh.end
        } catch {
            self.error = "cannot read processes: \(error)"
            return
        }
        refreshPausedRows()
        rebuildLines(keepingOrder: !resortNextReading)
        resortNextReading = false
    }

    /// One point on each graph and one tick of each strip.
    private func append(_ points: GraphPoints) throws {
        if topology != points.topology {
            topology = points.topology
            history = CPUHistory(topology: points.topology)
        }
        try history?.append(points.load)
        loadHistory.append(split: points.load.split, load: points.loadAverage, launches: points.launches)
        if let disk = points.disk { diskHistory.append(disk.readBytesPerSecond, disk.writeBytesPerSecond) }
        if let network = points.network { networkHistory.append(network.inBytesPerSecond, network.outBytesPerSecond) }
        if let memory = points.memory { memoryHistory.append(memory) }
        for (grouping, strip) in points.strips {
            largestByMemory[grouping] = strip.largestByMemory
            diskMovers[grouping, default: TopMovers()].tick(strip.disk)
            networkMovers[grouping, default: TopMovers()].tick(strip.network)
        }
    }

    /// While a menu is open — a row's right-click menu or the menu bar's — the table keeps its lines: the right-click
    /// menu acts on the row at the place clicked, so a re-sort under it handed Quit whichever process moved there
    /// (Phase 6 Step 7's demo; the user, 2026-10-24: "i selected Resilio, but it cycled as the list got reordered").
    /// Activity Monitor's and Finder's menus act on the item clicked. The latest reading is shown as the menu closes.
    @ObservationIgnored private var menuOpen = false

    private func watchMenus() {
        for (name, open) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuOpen = open
                    if !open { self?.rebuildLines() }
                }
            }
        }
    }

    /// `keepingOrder`: a refresh, which under a fixed sort keeps the shown order (`ProcessTable.lines(previous:)`),
    /// greyed lines leaving a minute after they ended, by the system's uptime; false builds the table afresh.
    private func rebuildLines(keepingOrder: Bool = true) {
        guard let latest, !menuOpen else { return }
        lines = Self.lines(latest, grouping: grouping, sort: Self.sort(sortOrder), pausedPids: Set(pausedRows.map(\.pid)),
                           now: ProcessInfo.processInfo.systemUptime, previous: keepingOrder ? lines : [],
                           warnings: warnings)
        // The bar redraws only when a line of it changed (the overhead budget).
        let bar = WarningBar.lines(warnings, table: lines, exemptApple: Self.actingSwitches().exemptApple)
        if bar != barLines { barLines = bar }
    }

    nonisolated static func lines(_ refresh: ProcessRefresh, grouping: ProcessTable.Grouping, sort: ProcessTable.Sort,
                                  pausedPids: Set<Int32> = [], now: Double = 0,
                                  previous: [ProcessTable.Line] = [], warnings: [Warning] = []) -> [ProcessTable.Line] {
        ProcessTable.lines(rows: refresh.rows, repoGroups: refresh.repoGroups, sessionGroups: refresh.sessionGroups,
                           commandGroups: refresh.commandGroups, grouping: grouping, sort: sort, unattributedCpuPercent: refresh.unattributedCpuPercent,
                           unattributedHint: refresh.unattributedHint,
                           unattributedDisk: refresh.unattributedDisk, kernelTaskAge: refresh.kernelTaskAge,
                           pausedPids: pausedPids, now: now, previous: previous, warnings: warnings)
    }

    /// The snapshot log's writer (Phase 6 Step 7), shared with the refresh loop.
    nonisolated let snapshots = SnapshotStore()

    /// With no window to show, the app is exactly what App Nap suspends: the loop's windows then arrive past the
    /// warnings' 1-second gap, every hold restarts, and a storm never raises (Phase 7 Step 1's probe saw it). The
    /// activity holds for the app's life and keeps the 1-second beat; the Mac may still sleep when it is idle.
    @ObservationIgnored private let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep], reason: "Saur0n watches the machine once a second")
    /// Beside Snapshot now for 5 s: `Saved 14:03:07` or `Snapshot failed` — a manual snapshot's outcome, or an
    /// automatic one's failure — with its tooltip (the error in full); nil otherwise. Short, so the toolbar keeps
    /// the search field at the minimum width.
    private(set) var snapshotNote: (text: String, help: String)?
    @ObservationIgnored private var snapshotNoteClear: Task<Void, Never>?

    /// The toolbar's Snapshot now: what the window shows, paused or not, kept in the snapshot log.
    func snapshotNow() {
        guard let input = latest?.snapshotInput else { return }
        Task {
            snapshotWritten(await snapshots.save(input, SnapshotTrigger(reason: .manual, detail: "")), manual: true)
        }
    }

    func snapshotWritten(_ result: Result<SnapshotLog.Entry, Error>, manual: Bool) {
        switch result {
        case .success(let entry):
            guard manual else { return }
            snapshotNote = ("Saved " + SnapshotTime.text(entry.takenAt).suffix(8),
                            "Kept in the snapshot log; saur0n snapshots lists it")
        case .failure(let error):
            snapshotNote = ("Snapshot failed", "Cannot write the snapshot log: \(error)")
        }
        snapshotNoteClear?.cancel()
        snapshotNoteClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.snapshotNote = nil
        }
    }

    /// The toolbar's Refresh (⌘R): the table re-sorted now, greyed lines gone, and a reading taken now and shown the
    /// same way. While paused, that one reading, and the window stays paused (`RefreshPause.refreshNow`).
    func refresh() {
        rebuildLines(keepingOrder: false)
        resortNextReading = true
        if paused { readingWhilePaused = true }
        pause.refreshNow()
    }

    /// Set by Refresh: the next reading builds the table afresh, and is shown though the window is paused.
    private var resortNextReading = false
    private var readingWhilePaused = false

    /// The table's header sort as `ProcessTable.Sort`; CPU, highest first, when none is set.
    static func sort(_ order: [KeyPathComparator<ProcessTable.Line>]) -> ProcessTable.Sort {
        guard let first = order.first else { return .cliOrder }
        let columns: [PartialKeyPath<ProcessTable.Line>: ProcessTable.Column] = [
            \.cpuPercent: .cpu, \.residentBytes: .memory, \.diskBytesPerSecond: .disk,
            \.networkBytesPerSecond: .network, \.name: .name, \.userText: .user,
            \.sessionText: .session, \.pidNumber: .pid,
        ]
        return ProcessTable.Sort(column: columns[first.keyPath] ?? .cpu, ascending: first.order == .forward)
    }

    // MARK: - Quit, Force Quit, Pause and Resume (Phase 5 Step 5)

    /// The table's selected line: a process, sub-group or group line; nil or the unattributed line selects nothing.
    var selection: ProcessTable.Line.ID?
    /// The confirmation sheet, while it is open.
    var pending: PendingAction?
    /// The processes Saur0n paused that still read as stopped: their rows carry the "paused" badge.
    private var processPause = ProcessPauseState()
    var pausedRows: Set<ProcessTable.RowID> { processPause.rows }

    /// Saur0n's own pid: never a target (`ProcessControl.refusal`).
    static let ownPid = ProcessInfo.processInfo.processIdentifier

    /// The selected line's processes as the last refresh shows them: the process itself, or every process under a
    /// group or sub-group — under a search, the ones it shows.
    var selectedTargets: [ProcessUsage] { targets(of: selection) }

    /// A greyed line is never a target: it ended (`ProcessTable.liveProcesses`).
    func targets(of id: ProcessTable.Line.ID?) -> [ProcessUsage] {
        guard let id, let latest, let line = Self.find(id, in: shownLines) else { return [] }
        let ids = Set(ProcessTable.liveProcesses(line).compactMap(\.rowID))
        return latest.rows.filter { ids.contains(ProcessTable.rowID($0)) }
    }

    /// Whether line `id` (the selection when nil) has a process the window may act on: false on kernel_task's,
    /// launchd's or Saur0n's own row alone, as Activity Monitor greys out Quit for kernel_task, and on a line with
    /// only greyed lines under it.
    func canAct(on id: ProcessTable.Line.ID? = nil) -> Bool {
        targets(of: id ?? selection).contains { ProcessControl.refusal($0.pid, ownPid: Self.ownPid) == nil }
    }

    /// Whether every selected process is paused: the toolbar's Pause then reads Resume.
    var selectionPaused: Bool {
        let targets = selectedTargets
        return !targets.isEmpty && targets.allSatisfy { pausedRows.contains(ProcessTable.rowID($0)) }
    }

    static func find(_ id: ProcessTable.Line.ID, in lines: [ProcessTable.Line]) -> ProcessTable.Line? {
        for line in lines {
            if line.id == id { return line }
            if let found = find(id, in: line.children ?? []) { return found }
        }
        return nil
    }

    /// Opens the sheet for `action` on the selection: what goes down with it from the last refresh's rows, the
    /// launchd flag, then "Used by" from one socket read on a background task. kernel_task, launchd and Saur0n itself
    /// leave the targets first, each reason a line on the sheet.
    func request(_ action: ProcessControl.Action) {
        guard let selection, let line = Self.find(selection, in: shownLines) else { return }
        request(action, on: selectedTargets, name: line.name)
    }

    /// The sheet for `action` on `selected`, named `name` when it is more than one process.
    private func request(_ action: ProcessControl.Action, on selected: [ProcessUsage], name groupName: String,
                         sparing: (ProcessUsage) -> String? = { _ in nil }) {
        guard let latest else { return }
        let reach = ProcessControl.select(selected, rows: latest.rows, ownPid: Self.ownPid, sparing: sparing)
        let targets = reach.targets, alsoEnds = reach.alsoEnds
        guard !targets.isEmpty else { return }
        let pids = targets.map(\.pid)
        let single = targets.count == 1 ? targets[0] : nil
        // Named as the Name column shows it, the readable name under it (Activity Monitor's dialog names the process).
        let name = single?.name ?? groupName
        let sheet = PendingAction(action: action, title: "\(action.title) \(name)",
                                  subtitle: single.map { row in
                                      (["pid \(row.pid)", row.user] + (row.readableName.map { [$0] } ?? [])).joined(separator: " · ")
                                  } ?? "\(targets.count) processes",
                                  targets: targets, alsoEnds: alsoEnds, left: reach.left, spared: reach.spared,
                                  confirmTitle: ProcessControl.confirmTitle(action: action, targetCount: targets.count,
                                                                            dependantCount: alsoEnds.count))
        pending = sheet
        let rows = latest.rows, id = sheet.id
        Task.detached(priority: .userInitiated) { [weak self] in
            let launchctl = ProcessControl.launchctlList() ?? ""
            let keepAlive = targets.contains { ProcessControl.launchdManaged($0.pid, ppid: $0.ppid, launchctlList: launchctl) }
            let usedBy: [ProcessControl.Dependant]? = (try? NettopRunner.sockets()).map { listing in
                var seen = Set(pids), out: [ProcessControl.Dependant] = []
                for pid in pids {
                    for user in ProcessControl.usedBy(pid, listing: listing, rows: rows) where seen.insert(user.pid).inserted {
                        out.append(user)
                    }
                }
                return out
            }
            await MainActor.run {
                guard let self, var sheet = self.pending, sheet.id == id else { return }
                sheet.keepAlive = keepAlive
                sheet.usedBy = usedBy.map { .read($0) } ?? .unreadable
                self.pending = sheet
            }
        }
    }

    func cancelPending() { pending = nil }

    /// Confirms the sheet: every target and everything under it, checked against a fresh process list by pid and
    /// start time, children first. The sheet closes when all went through; otherwise it stays with the reasons, and
    /// offers the administrator path for the processes macOS refused.
    func confirmPending() {
        guard var sheet = pending, let latest else { return }
        let current: [ProcessIdentity]
        do {
            current = try ProcessControl.currentIdentities()
        } catch {
            sheet.error = "cannot read the process list: \(error)"
            pending = sheet
            return
        }
        // What the sheet listed, by pid and start time: a pid a new process has taken since is not a target.
        let rows = sheet.targets + ProcessControl.resolve(sheet.alsoEnds, in: latest.rows)
        let outcomes = ProcessControl.perform(sheet.action, on: rows, current: current, signaller: KillSignaller(),
                                              terminator: Self.appTerminator, ownPid: Self.ownPid)
        let rowsByPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var failures: [String] = [], denied: [ProcessUsage] = []
        for outcome in outcomes {
            guard let row = rowsByPid[outcome.pid] else { continue }
            switch outcome.result {
            case .success: record(sheet.action, row)
            case .failure(let error):
                failures.append(ProcessControl.message(error, name: row.name, pid: row.pid))
                if error == .permissionDenied { denied.append(row) }
            }
        }
        rebuildLines()
        guard !failures.isEmpty else { pending = nil; return }
        sheet.error = failures.joined(separator: "\n")
        sheet.denied = denied
        pending = sheet
    }

    /// The administrator path for the processes macOS refused: `kill -<signal> <pid>` for each, checked again against
    /// a fresh process list, run as root by AppleScript's `do shell script … with administrator privileges` — the
    /// system's own password dialog, nothing stored (research 2026-10-20 § Q2).
    func confirmAsAdministrator() {
        guard var sheet = pending, !sheet.denied.isEmpty else { return }
        let current = (try? ProcessControl.currentIdentities()) ?? []
        let live = sheet.denied.filter { ProcessControl.verify(ProcessTable.rowID($0), in: current) != nil }
        guard !live.isEmpty else {
            sheet.error = "the refused processes are gone"
            sheet.denied = []
            pending = sheet
            return
        }
        let batch = ProcessControl.AdministratorBatch(signal: sheet.action.signal, rows: live, ownPid: Self.ownPid)
        guard let command = batch.command else {
            sheet.error = batch.error
            pending = sheet
            return
        }
        var failure: NSDictionary?
        NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges")?.executeAndReturnError(&failure)
        if let failure {
            sheet.error = (failure[NSAppleScript.errorMessage] as? String) ?? "the administrator command failed"
            pending = sheet
            return
        }
        for row in live { record(sheet.action, row) }
        rebuildLines()
        pending = nil
    }

    /// A paused process gets its badge; a resumed one loses it.
    private func record(_ action: ProcessControl.Action, _ row: ProcessUsage) {
        processPause.record(action, row)
    }

    /// Each refresh: a badge stays only on a process that still reads as stopped (resumed elsewhere, or gone, drops it).
    private func refreshPausedRows() {
        guard !pausedRows.isEmpty else { return }
        processPause.refresh(isStopped: ProcessControl.isStopped)
    }

    // MARK: - The warning bar (Phase 6 Step 6)

    /// When the last completed reading was taken: the menu reads it for its display-only age, whatever the live
    /// status's publication state; nil before the first reading.
    private(set) var lastReadingAt: Date?

    /// The level the last completed reading named, from the engine and never recomputed here; nil while production's
    /// calibration is pending, read by the menu whatever the publication state.
    private(set) var resourceLevel: ResourceLevel?

    /// The warnings in force, the ignored ones left out: the last reading's, less any ignored since.
    private(set) var warnings: [Warning] = []
    /// The bar above the table, one line per warning.
    private(set) var barLines: [WarningBar.Line] = []
    /// The spike marks on the graphs, and the uptime of the reading they came with (which places them).
    private(set) var spikes = Spikes()
    private(set) var spikesEnd = 0.0
    /// The bar lines Details opened, by line id.
    private(set) var expandedWarnings: Set<String> = []
    /// The last Pause or Resume failures from a bar line, by line id.
    private(set) var barErrors: [String: String] = [:]

    /// The group warnings ignored until they clear: not remembered (calibration 2026-10-23; research 2026-10-22 § Q3,
    /// the group row: "a build or a long test run, which the ignore list in the controls covers").
    private var ignoredGroups: Set<Warning.Subject> = []

    /// The subjects the user ignored, as the loop's engine reads them: the commands kept in settings and the groups
    /// ignored until they clear.
    var ignoring: Set<Warning.Subject> {
        Set(theme.ignoredWarnings.compactMap(Warning.Subject.init(key:))).union(ignoredGroups)
    }

    /// Details: opens the line onto its conditions and selects the group it pinned; pressed again it folds.
    func details(_ line: WarningBar.Line) {
        if expandedWarnings.remove(line.id) == nil {
            expandedWarnings.insert(line.id)
            if let group = line.group { selection = group }
        }
    }

    /// Whether Saur0n paused processes on the line that still read as stopped: it then reads Resume.
    func barPaused(_ line: WarningBar.Line) -> Bool {
        processPause.barPaused(line.id)
    }

    /// Pause from the bar, at once (Resume undoes it; Apple's HIG Alerts: "Avoid displaying alerts for common, undoable
    /// actions"): every live process of the warning and everything under it; pressed again, Resume on what it paused.
    func pauseFromBar(_ line: WarningBar.Line) {
        guard let latest else { return }
        barErrors[line.id] = nil
        if barPaused(line), let paused = processPause.barRows[line.id] {
            act(.resume, on: latest.rows.filter { paused.contains(ProcessTable.rowID($0)) }, line: line)
            processPause.barRows[line.id] = nil
            return
        }
        let pids = Set(line.pids)
        let reach = ProcessControl.select(latest.rows.filter { pids.contains($0.pid) }, rows: latest.rows, ownPid: Self.ownPid,
                                          sparing: ProcessControl.barSparing(exempt: Set(line.exempt)))
        processPause.barRows[line.id] = act(.pause, on: reach.targets + ProcessControl.resolve(reach.alsoEnds, in: latest.rows),
                                             line: line)
    }

    /// Stop from the bar: Quit on the warning's workload, through the confirmation sheet — which lists every process it
    /// ends and every one left running. The Apple services the line names are offered to the selection too, so the sheet
    /// can say they are left.
    func stopFromBar(_ line: WarningBar.Line) {
        guard let latest else { return }
        let pids = Set(line.pids).union(line.exempt)
        request(.quit, on: latest.rows.filter { pids.contains($0.pid) }, name: line.name,
                sparing: ProcessControl.barSparing(exempt: Set(line.exempt)))
    }

    /// Ignore: a command is kept in the app's settings until undone there; a session or repo only until its warning
    /// clears. The line leaves now.
    func ignore(_ line: WarningBar.Line) {
        guard let key = line.ignoreKey, let subject = Warning.Subject(key: key) else { return }
        if case .command = subject {
            if !theme.ignoredWarnings.contains(key) { theme.ignoredWarnings.append(key) }
        } else {
            ignoredGroups.insert(subject)
        }
        warnings.removeAll { $0.subject.key == key }
        expandedWarnings.remove(line.id)
        rebuildLines()
    }

    /// `action` on `rows` at once, each checked against a fresh process list by pid and start time, children first; the
    /// processes it went through for. Failures show on the bar line.
    @discardableResult
    private func act(_ action: ProcessControl.Action, on rows: [ProcessUsage], line: WarningBar.Line) -> Set<ProcessTable.RowID> {
        let current: [ProcessIdentity]
        do {
            current = try ProcessControl.currentIdentities()
        } catch {
            barErrors[line.id] = "cannot read the process list: \(error)"
            return []
        }
        let outcomes = ProcessControl.perform(action, on: rows, current: current, signaller: KillSignaller(),
                                              terminator: Self.appTerminator, ownPid: Self.ownPid)
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var done: Set<ProcessTable.RowID> = [], failures: [String] = []
        for outcome in outcomes {
            guard let row = byPid[outcome.pid] else { continue }
            switch outcome.result {
            case .success:
                record(action, row)
                done.insert(ProcessTable.rowID(row))
            case .failure(let error): failures.append(ProcessControl.message(error, name: row.name, pid: row.pid))
            }
        }
        if !failures.isEmpty { barErrors[line.id] = failures.joined(separator: "; ") }
        rebuildLines()
        return done
    }

    /// An app's Quit and Force Quit through `NSRunningApplication`; nil when the pid is not a running application.
    static let appTerminator = AppTerminator(
        terminate: { pid in NSRunningApplication(processIdentifier: pid).map { $0.terminate() } },
        forceTerminate: { pid in NSRunningApplication(processIdentifier: pid).map { $0.forceTerminate() } })
}

/// The confirmation sheet's content: built once when it opens, "Used by" filled in when the socket read lands.
struct PendingAction: Identifiable {
    enum UsedBy {
        case reading, unreadable
        case read([ProcessControl.Dependant])
    }

    let id = UUID()
    let action: ProcessControl.Action
    let title: String
    /// "pid N · user" for one process, "N processes" for a group.
    let subtitle: String
    let targets: [ProcessUsage]
    let alsoEnds: [ProcessControl.Dependant]
    /// Why a selected or dependent process is left out: "Saur0n itself is left running", "kernel_task and launchd
    /// can't be ended".
    let left: [String]
    /// The processes the action spared and the sheet names among those left running.
    let spared: [ProcessControl.Dependant]
    let confirmTitle: String
    var usedBy = UsedBy.reading
    /// launchd started a target; it may come back.
    var keepAlive = false
    /// The last attempt's failures, one per line.
    var error: String?
    /// The processes macOS refused (EPERM): the administrator path's targets.
    var denied: [ProcessUsage] = []

    var summary: String { ProcessControl.summary(alsoEnds) }
    var usedByRows: [ProcessControl.Dependant] {
        if case .read(let rows) = usedBy { return rows }
        return []
    }
}

/// One refresh's process rows and groups, as the CLI computes them.
struct ProcessRefresh: Sendable {
    let rows: [ProcessUsage]
    let repoGroups: [RepoGroup]
    let sessionGroups: [SessionGroup]
    let commandGroups: [CommandGroup]
    let unattributedCpuPercent: Double?
    let kernelTaskAge: Int?
    /// The machine's disk and network rates over the second; nil before two reads succeeded.
    var disk: DiskUsage? = nil
    var network: NetworkUsage? = nil
    /// The interval this refresh's CPU and rate figures were measured over, and this tick's own machine rates —
    /// nil when that read failed this tick, so the live status never shows a kept rate under a new timestamp.
    var intervalSeconds: Double = 0
    var tickDisk: DiskRate? = nil
    var tickNetwork: NetworkRate? = nil
    var unattributedDisk: DiskRate? = nil
    /// What is new under launchd, on the Unattributed line (`Snapshot.unattributedHint`); nil below its bar.
    var unattributedHint: String? = nil
    /// When the two machine reads behind `disk` / `network` were taken (the live checks line them up with `iostat`
    /// and `netstat`), and the seconds between the two `nettop` reads behind the rows' network — nil when this
    /// refresh's `nettop` read failed, so the network strip does not count the kept rates twice.
    var diskWindow: DiskWindow? = nil
    var networkWindow: NetworkWindow? = nil
    var nettopSeconds: Double? = nil
    /// The machine's used memory this refresh; nil when the read failed.
    var memory: MemoryUsage? = nil
    /// The held resource level the engine named for this refresh; nil while production's calibration is pending, and
    /// never `normal` in its place.
    var resourceLevel: ResourceLevel? = nil
    /// The kernel's load averages this refresh, and the processes launched since the last scan's `ps` started; nil
    /// when not read.
    var loadAverage: LoadAverage? = nil
    var launches: LaunchRate? = nil
    /// This refresh's failed disk and network reads (`cannot read disk activity: …`), whose figures kept the last
    /// refresh's values.
    var problems: [String] = []
    /// The warnings in force after this refresh, the ignored ones left out (Phase 6 Step 6), and every subject raised,
    /// ignored or not (an Ignore on a group lasts while its subject is here).
    var warnings: [Warning] = []
    var raised: Set<Warning.Subject> = []
    /// The spike marks on the CPU, Disk and Network graphs, and the uptime this refresh ended at, which places them.
    var spikes = Spikes()
    var end = 0.0
    /// The Dock icon's step and border after this refresh (Phase 6 Step 9).
    var dock = DockLevel.State()
    /// What a snapshot of this refresh is built from (Snapshot now takes the shown one's), and the snapshot this
    /// refresh is due, if any (Phase 6 Step 7).
    var snapshotInput: SnapshotInput? = nil
    var snapshotTrigger: SnapshotTrigger? = nil
}

/// The snapshot log's one writer (Phase 6 Step 7): builds, compresses and writes each snapshot off the refresh loop and
/// the main actor, opening the log on the first one — nothing on the loop opens the database (the overhead budget).
actor SnapshotStore {
    private var log: SnapshotLog?

    func save(_ input: SnapshotInput, _ trigger: SnapshotTrigger) -> Result<SnapshotLog.Entry, Error> {
        Result {
            let record = SnapshotRecord(input, reason: trigger.reason, detail: trigger.detail)
            let log = try log ?? SnapshotLog(url: SnapshotLog.defaultURL())
            self.log = log
            return try log.write(record)
        }
    }
}

/// One reading's spike marks per graph.
struct Spikes: Equatable, Sendable {
    var cpu: [SpikeMarks.Mark] = []
    var disk: [SpikeMarks.Mark] = []
    var network: [SpikeMarks.Mark] = []
}

/// One reading as the refresh loop hands it to the window, with its graph and strip points.
struct Reading: Sendable {
    let load: Result<CPULoad?, Error>
    let processes: Result<ProcessRefresh?, Error>
    /// nil when the load read failed or gave no window yet.
    let points: GraphPoints?
    /// When this completed reading was taken; nil while there is none.
    let sampledAt: Date?
    /// The level the engine named for this reading; nil while its calibration is pending.
    let level: ResourceLevel?

    init(load: Result<CPULoad?, Error>, processes: Result<ProcessRefresh?, Error>, topology: CoreTopology?,
         sampledAt: Date? = nil, level: ResourceLevel? = nil) {
        self.load = load
        self.processes = processes
        self.sampledAt = sampledAt
        self.level = level
        points = (try? load.get()).flatMap { load in
            topology.map { GraphPoints(load: load, refresh: try? processes.get(), topology: $0) }
        }
    }
}

/// What one reading adds to the graphs and strips. Built on the refresh loop's task, so the three groupings' lines
/// the strips need are built off the main actor; while the window is quiet these are all it keeps of a reading.
struct GraphPoints: Sendable {
    /// One grouping's strips: the five largest by memory, and each line's bytes this tick (its rate over the tick's
    /// length — the process scans' interval for disk, the `nettop` reads' for network).
    struct Strip: Sendable {
        let largestByMemory: [TopMovers.Mover]
        let disk: [TopMovers.Mover]
        let network: [TopMovers.Mover]
    }

    let load: CPULoad
    let topology: CoreTopology
    let loadAverage: LoadAverage?
    let launches: LaunchRate?
    let disk: DiskRate?
    let network: NetworkRate?
    let memory: MemoryUsage?
    /// Empty when the process read failed: the strips do not tick.
    let strips: [ProcessTable.Grouping: Strip]

    init(load: CPULoad, refresh: ProcessRefresh?, topology: CoreTopology) {
        self.load = load
        self.topology = topology
        loadAverage = refresh?.loadAverage
        launches = refresh?.launches
        disk = refresh?.tickDisk
        network = refresh?.tickNetwork
        memory = refresh?.memory
        var strips: [ProcessTable.Grouping: Strip] = [:]
        if let refresh {
            for grouping in ProcessTable.Grouping.allCases {
                let lines = ProcessTable.flattened(MonitorModel.lines(refresh, grouping: grouping, sort: .cliOrder))
                strips[grouping] = Strip(
                    largestByMemory: TopMovers.largest(lines, by: \.residentBytes),
                    disk: TopMovers.rows(lines, seconds: refresh.intervalSeconds, rate: \.diskBytesPerSecond),
                    network: refresh.nettopSeconds.map { TopMovers.rows(lines, seconds: $0, rate: \.networkBytesPerSecond) } ?? [])
            }
        }
        self.strips = strips
    }
}

/// The window's process path, run off the main actor: one scan per refresh (this refresh's closing scan opens
/// the next window), descriptions extended for new processes only, kernel_task from a `top` started every
/// 30th refresh and finished on the next (`ProcessReaders.KernelTaskSchedule`); repo lookups and tmux panes kept
/// for 10 refreshes.
struct ProcessRefresher {
    var topology: CoreTopology
    private var scanner = ProcessScanner()
    private var descriptions: DescriptionSources?
    private var kernelTask = ProcessReaders.KernelTaskSchedule()
    private var pendingTop: ProcessReaders.KernelTaskSampler?
    /// Repo lookups kept for 10 refreshes: a new process's repo shows at once, a `.git` made since within 10 s.
    private var resolvers = KeptResolver()
    private var orphanGroups = KeptOrphanGroups()
    /// tmux panes, read every 10 refreshes: a new pane's session shows within 10 s.
    private static let tmuxRefreshInterval = 10
    private var tmuxPanes: [Int32: String]?
    /// Arguments kept across refreshes except for shells and interpreters, which can exec another script;
    /// terminal names kept while the process lives. Reading every process again was a fifth of the app's cost
    /// (research 2026-10-23-overhead, findings 3 and 4).
    private var arguments = KeptPerProcess<ProcessArguments>()
    private var terminalNames = KeptPerProcess<String>()
    private var refresh = 0
    /// Rows keep the last machine rates on failure; graphs and live status take only this tick's successful reads.
    private var diskReading = RateReading<DiskBytes, DiskUsage>()
    private var networkReading = RateReading<NetworkBytes, NetworkUsage>()
    private var disk: DiskUsage? { diskReading.latest }
    private var network: NetworkUsage? { networkReading.latest }
    private var tickDisk: DiskRate? { diskReading.tick?.rate }
    private var tickNetwork: NetworkRate? { networkReading.tick?.rate }
    private var diskWindow: DiskWindow? { diskReading.window }
    private var networkWindow: NetworkWindow? { networkReading.window }
    private var lastNettop: NettopRead?
    /// The fixed levels' engine (Phase 7 Step 2), driven on the warnings' tick. The default-off selection below
    /// resets its holds and projection whenever the resource-alert switch changes.
    private var levels = ResourceLevelEngine()
    private var perProcessNetwork: [Int32: NetworkUsage]?
    private var nettopSeconds: Double?
    /// The warnings and spike marks, run on every reading, the window quiet or not (Phase 6 Step 6). Floors: CPU 25
    /// points of the machine, Disk 50 MB/s, Network 10 MB/s above the minute's median. The warnings' engine moved to
    /// the watcher in Phase 7 Step 1 (`WatcherModel`): it outlives the window, so it cannot live in this refresher.
    private var cpuSpikes = SpikeMarks(floor: 25), diskSpikes = SpikeMarks(floor: 50e6),
                networkSpikes = SpikeMarks(floor: 10e6)
    /// The machine's last minute and when a snapshot is due (Phase 6 Step 7), on every reading as the warnings are.
    private var machineHistory = MachineHistory()
    private var snapshotTriggers = SnapshotTriggers()
    /// The Dock icon's level (Phase 6 Step 9), on every reading as the warnings are: one sysctl for memory pressure.
    private var dockLevel = DockLevel()

    init(topology: CoreTopology) { self.topology = topology }

    /// The machine's disk and network counters and one `nettop` sample (never a kept-alive one: plan v2), each
    /// diffed with the last successful read, as `main.swift` brackets its window. A failed read keeps that figure's
    /// last rates and names itself in the returned problems.
    mutating func readDiskAndNetwork() -> [String] {
        var problems: [String] = []
        do {
            diskReading.record(try MachineDiskReader.read(), measure: DiskActivity.usage)
        } catch {
            diskReading.record(nil, measure: DiskActivity.usage)
            problems.append("cannot read disk activity: \(error)")
        }
        do {
            networkReading.record(try MachineNetworkReader.read(), measure: NetworkActivity.usage)
        } catch {
            networkReading.record(nil, measure: NetworkActivity.usage)
            problems.append("cannot read network activity: \(error)")
        }
        do {
            let now = try NettopRunner.read()
            if let lastNettop {
                perProcessNetwork = NetworkActivity.perProcess(before: lastNettop, after: now)
                nettopSeconds = Double(now.uptimeNanoseconds &- lastNettop.uptimeNanoseconds) / 1e9
            }
            lastNettop = now
        } catch {
            // The rows keep the last rates, but the strip counts nothing this tick: the next read's diff spans it.
            nettopSeconds = nil
            problems.append("cannot read per-process network: \(error)")
        }
        return problems
    }

    /// Scans once; nil on the first scan or when the ticks gave no load yet. `load` is the tick window read
    /// just before, so the rows and the total cover the same second. The subjects in `ignoring` raise no warning line.
    /// `watcher` holds the warning engine and the pause ledger the loop drives (Phase 7 Step 1), so the warnings the
    /// window shows are the watcher's own.
    mutating func next(load: CPULoad?, ignoring: Set<Warning.Subject>, watcher: inout WatcherModel) throws -> ProcessRefresh? {
        defer { refresh += 1 }
        var problems = readDiskAndNetwork()
        let memorySample = readMemory(problems: &problems)
        let memory = memorySample?.usage
        let available = memorySample?.available
        readKernelTask(problems: &problems)
        let scan = try ProcessReaders.sample(workingDirectories: true, keptArguments: &arguments)
        if descriptions == nil { descriptions = DescriptionSources.load(for: scan) } else { descriptions?.extend(for: scan) }
        guard let window = scanner.next(scan), let load else { return nil }
        let describe = descriptions.map { sources in { sources.describe(pid: $0, name: $1, path: $2) } }
        let rows = try ProcessSample.usage(before: window.before, after: window.after, cpuCount: load.perCPU.count,
                                           kernelTask: kernelTask.latest, describe: describe, network: perProcessNetwork)
        let resolver = resolvers.next()
        if tmuxPanes == nil || refresh % Self.tmuxRefreshInterval == 0 { tmuxPanes = SystemReaders.tmuxPanes() }
        let logins = Set(SessionGroups.terminalLogins(rows))
        let ttys = terminalNames.values(for: scan.processes.filter { logins.contains($0.pid) },
                                        read: SystemReaders.ttyName(pid:))
        let sources = SessionSources.assemble(rows: rows, sample: scan, registry: SystemReaders.sessionRegistry(),
                                              tmuxPanes: tmuxPanes ?? [:], ttyName: { ttys[$0] }, ownUID: getuid())
        let grouped = orphanGroups.assign(rows, workingDirectories: scan.workingDirectories,
                                          repoOfDirectory: resolver.repo(forDirectory:),
                                          repoOfExecutable: resolver.repo(forExecutable:), sources: sources)
        let commands = CommandGroups.assign(grouped.rows, arguments: scan.arguments)
        // A machine rate kept from an earlier refresh still sizes the lift; none read yet lifts by memory and CPU only.
        let out = CatchAllBreakout.apply(
            rows: commands.rows, repoGroups: grouped.repoGroups, sessionGroups: grouped.sessionGroups,
            thresholds: CatchAllBreakout.Thresholds(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                                                    machineDiskBytesPerSecond: disk?.rate.totalBytesPerSecond,
                                                    machineNetworkBytesPerSecond: network?.rate.totalBytesPerSecond))
        let loadAverage = SystemReaders.loadAverage()
        let launches = LaunchRate(before: window.before, after: window.after)
        let seconds = Double(window.after.uptimeNanoseconds &- window.before.uptimeNanoseconds) / 1e9
        func makeSnapshot(warnings: [Warning]?) throws -> Snapshot {
            try Snapshot(topology: topology, load: load, intervalSeconds: seconds, processes: out.rows,
                         repoGroups: out.repoGroups, sessionGroups: out.sessionGroups, commandGroups: commands.groups,
                         disk: disk, network: network, loadAverage: loadAverage, launches: launches, warnings: warnings,
                         memory: available)
        }
        let snapshot = try makeSnapshot(warnings: nil)
        let end = Double(window.after.uptimeNanoseconds) / 1e9
        let (inForce, level) = judge(end: end, seconds: seconds, load: load, snapshot: snapshot, out: out,
                                     commands: commands.groups, loadAverage: loadAverage, available: available,
                                     ignoring: ignoring, watcher: &watcher)
        feedSpikes(end: end, load: load, disk: disk, network: network, rows: out.rows)
        // The snapshot log (Phase 6 Step 7): the snapshot itself is built and written off this loop (`SnapshotStore`).
        let shown = try makeSnapshot(warnings: inForce)
        let (now, trigger, dock) = advance(end: end, seconds: seconds, load: load, shown: shown, inForce: inForce)
        return ProcessRefresh(rows: out.rows, repoGroups: out.repoGroups, sessionGroups: out.sessionGroups,
                              commandGroups: commands.groups, unattributedCpuPercent: snapshot.unattributedCpuPercent,
                              kernelTaskAge: kernelTask.ageSeconds(atNanoseconds: DispatchTime.now().uptimeNanoseconds),
                              disk: disk, network: network, intervalSeconds: seconds, tickDisk: tickDisk,
                              tickNetwork: tickNetwork, unattributedDisk: snapshot.unattributedDisk,
                              unattributedHint: snapshot.unattributedHint,
                              diskWindow: diskWindow, networkWindow: networkWindow, nettopSeconds: nettopSeconds,
                              memory: memory, resourceLevel: level, loadAverage: loadAverage,
                              launches: launches, problems: problems,
                              warnings: inForce, raised: watcher.raisedSubjects,
                              spikes: Spikes(cpu: cpuSpikes.marks, disk: diskSpikes.marks, network: networkSpikes.marks),
                              end: end, dock: dock,
                              snapshotInput: SnapshotInput(snapshot: shown, scan: scan, history: machineHistory.points, end: now),
                              snapshotTrigger: trigger)
    }

    /// `top` is supplementary: a launch, exit or parse failure must not discard this tick's process scan.
    private mutating func readKernelTask(problems: inout [String]) {
        if let pendingTop {
            self.pendingTop = nil
            let result = Result { try pendingTop.finish() }
            if let problem = kernelTask.record(result, atNanoseconds: DispatchTime.now().uptimeNanoseconds) {
                problems.append(problem)
            }
        }
        guard ProcessReaders.KernelTaskSchedule.isDue(refresh: refresh) else { return }
        do {
            pendingTop = try ProcessReaders.KernelTaskSampler.start(interval: 1)
        } catch {
            problems.append("cannot start kernel_task reading: \(error)")
        }
    }

    /// The tick's one memory read, for all three consumers (Delphi 40d78a09): the Memory column, the live status and
    /// the level engine's floor. A failed read names its reason and leaves both figures nil — neither is fabricated.
    private func readMemory(problems: inout [String]) -> (available: AvailableMemory, usage: MemoryUsage)? {
        do {
            return try SystemReaders.memorySample()
        } catch {
            problems.append("cannot read memory: \(error)")
            return nil
        }
    }

    /// The warnings in force and the fixed level, from one tick: the same window the rows cover, carrying the two
    /// figures the levels judge, so no second threshold is computed here. While resource alerts are off, the engine
    /// evaluates nothing and names no level — never `normal`.
    private mutating func judge(end: Double, seconds: Double, load: CPULoad, snapshot: Snapshot,
                                out: (rows: [ProcessUsage], repoGroups: [RepoGroup], sessionGroups: [SessionGroup]),
                                commands: [CommandGroup], loadAverage: LoadAverage?, available: AvailableMemory?,
                                ignoring: Set<Warning.Subject>, watcher: inout WatcherModel)
        -> (inForce: [Warning], level: ResourceLevel?) {
        let tick = WarningTick(end: end, seconds: seconds, cpus: load.perCPU.count,
                               unattributedCpuPercent: snapshot.unattributedCpuPercent, loadAverage: loadAverage,
                               split: load.split, rows: out.rows, commandGroups: commands, repoGroups: out.repoGroups,
                               sessionGroups: out.sessionGroups, cpuPercent: load.total, memory: available)
        let inForce = watcher.warnings(tick, ignoring: ignoring)
        let calibration = ResourceCalibration.read { UserDefaults.standard.object(forKey: $0) }
        if levels.calibration != calibration { levels = ResourceLevelEngine(calibration: calibration) }
        return (inForce, levels.next(tick)?.level)
    }

    /// This tick's spike marks on the three graphs, each naming the process that moved the figure most.
    private mutating func feedSpikes(end: Double, load: CPULoad, disk: DiskUsage?, network: NetworkUsage?,
                                     rows: [ProcessUsage]) {
        cpuSpikes.next(end: end, value: load.total, top: SpikeMarks.top(rows, by: \.totalCpuPercent))
        if let disk {
            diskSpikes.next(end: end, value: Double(disk.rate.totalBytesPerSecond),
                            top: SpikeMarks.top(rows, by: { Double($0.disk?.rate.totalBytesPerSecond ?? 0) },
                                                text: { RateHistory.rateText(UInt64($0)) }))
        }
        if let network {
            networkSpikes.next(end: end, value: Double(network.rate.totalBytesPerSecond),
                               top: SpikeMarks.top(rows, by: { Double($0.network?.rate.totalBytesPerSecond ?? 0) },
                                                   text: { RateHistory.rateText(UInt64($0)) }))
        }
    }

    /// The minute's history, the snapshot trigger and the Dock step for this tick, in the order the loop ran them.
    private mutating func advance(end: Double, seconds: Double, load: CPULoad, shown: Snapshot, inForce: [Warning])
        -> (now: Double, trigger: SnapshotTrigger?, dock: DockLevel.State) {
        let now = Date().timeIntervalSince1970
        machineHistory.append(MachinePoint(snapshot: shown, end: now))
        let peaks = [("CPU", cpuSpikes), ("Disk", diskSpikes), ("Network", networkSpikes)].compactMap { graph, spikes in
            spikes.marks.last.flatMap { $0.end == end ? [graph, $0.name].compactMap { $0 }.joined(separator: " ") : nil }
        }
        let trigger = snapshotTriggers.next(end: end, warnings: inForce, peaks: peaks)
        let dock = dockLevel.next(end: end, seconds: seconds, cpuPercent: load.total, pressure: MemoryPressure.read())
        return (now, trigger, dock)
    }
}
