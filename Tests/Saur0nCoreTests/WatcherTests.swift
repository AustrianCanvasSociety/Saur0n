// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the always-on watcher (Phase 7 Step 1) — the warning engine runs from recorded ticks with no window anywhere,
// the acting switch is read on every tick, a would-have-acted lands with its figures where the snapshot log takes it
// while the rung's switch is off, acting calls the window's own Pause path, and the pause ledger resumes what it holds.
// Method: the 2026-10-22 storm's copies on recorded one-second ticks, a signaller that records, ledgers in temp folders.

private let cpus = 18
private let script = "/tmp/example/runaway.sh"
private let stormName = "runaway.sh × 30"

private func row(_ pid: Int32, _ name: String, parent: Int32 = 1, cpu: Double = 0) -> ProcessUsage {
    var row = ProcessUsage(pid: pid, ppid: parent, uid: 501, user: "user", path: "/usr/bin/" + name, name: name,
                           cpuPercent: cpu, residentBytes: 1 << 20, source: .libproc, exitedChildrenCpuPercent: 0)
    row.startMicroseconds = UInt64(pid) * 1_000
    return row
}

/// `count` copies of one script, each a `bash` running it at `cpuEach` of the machine, ending at `end`; a generation's
/// pids are distinct, as a storm's new copies are.
private func storm(_ end: Double, copies: Int = 30, cpuEach: Double = 0.5, generation: Int = 0,
                   script name: String = script) -> WarningTick {
    var rows: [ProcessUsage] = [], arguments: [Int32: ProcessArguments] = [:]
    for i in 0..<copies {
        let pid = Int32(10_000 + generation * 1_000 + i)
        rows.append(row(pid, "bash", cpu: cpuEach))
        arguments[pid] = ProcessArguments(argv: ["/bin/bash", name], environment: [:])
    }
    let commands = CommandGroups.assign(rows, arguments: arguments)
    return WarningTick(end: end, seconds: 1, cpus: cpus, unattributedCpuPercent: 5,
                       loadAverage: LoadAverage(oneMinute: 20, fiveMinutes: 20, fifteenMinutes: 20),
                       split: CPUSplit(user: 60, system: 20), rows: commands.rows, commandGroups: commands.groups,
                       repoGroups: [], sessionGroups: [])
}

/// A machine at rest: no copies anywhere.
private func rest(_ end: Double) -> WarningTick {
    WarningTick(end: end, seconds: 1, cpus: cpus, unattributedCpuPercent: 5,
                loadAverage: LoadAverage(oneMinute: 20, fiveMinutes: 20, fifteenMinutes: 20),
                split: CPUSplit(user: 20, system: 10), rows: [], commandGroups: [], repoGroups: [], sessionGroups: [])
}

/// Records every signal in order.
private final class Recorder: ProcessSignaller, @unchecked Sendable {
    var calls: [String] = []
    var refused: Set<Int32> = []

    func signal(_ sig: Int32, to pid: Int32) throws {
        if refused.contains(pid) { throw ProcessControlError.permissionDenied }
        calls.append("\(sig) \(pid)")
    }
}

private func identities(_ rows: [ProcessUsage]) -> [ProcessIdentity] {
    rows.map {
        ProcessIdentity(pid: $0.pid, ppid: $0.ppid, uid: $0.uid, user: $0.user,
                        startMicroseconds: $0.startMicroseconds, comm: $0.name, path: $0.path)
    }
}

/// A watcher driven over the storm's first seconds: the quiet machine, then the copies, until the warning fires.
private func raisedStorm() -> (watcher: WatcherModel, tick: WarningTick, warnings: [Warning]) {
    var watcher = WatcherModel()
    var warnings: [Warning] = []
    var last = storm(0)
    _ = watcher.warnings(rest(1))
    for t in 2...14 {
        last = storm(Double(t))
        warnings = watcher.warnings(last)
    }
    return (watcher, last, warnings)
}

// MARK: - Window pause state

@Test func watcherPauseShowsBadgesAndOneResumeReachesThePausedChildren() throws {
    let raised = raisedStorm()
    var watcher = raised.watcher
    let rows = raised.tick.rows + [row(20_000, "worker", parent: raised.tick.rows[0].pid)]
    let recorder = Recorder()
    recorder.refused = [raised.tick.rows[1].pid]
    let actions = watcher.decide(warnings: raised.warnings, rows: rows, switches: ActingSwitches(),
                                 current: { identities(rows) }, signaller: recorder, ownPid: 999)
    let subject = try #require(actions.first?.subject.key)
    let expected = Set(rows.filter { !recorder.refused.contains($0.pid) }.map(ProcessTable.rowID))
    var state = ProcessPauseState()
    state.recordWatcher(actions, rows: rows)
    #expect(state.rows == expected)
    #expect(state.barRows[subject] == expected)
    #expect(state.barPaused(subject))
    #expect(!state.barPaused("command:unrelated.sh"))

    let held = state.barRows[subject] ?? []
    let targets = rows.filter { held.contains(ProcessTable.rowID($0)) }
    recorder.calls = []
    let outcomes = ProcessControl.perform(.resume, on: targets, current: identities(rows), signaller: recorder,
                                          terminator: AppTerminator(terminate: { _ in nil }, forceTerminate: { _ in nil }),
                                          ownPid: 999)
    for outcome in outcomes {
        if case .success = outcome.result, let row = targets.first(where: { $0.pid == outcome.pid }) {
            state.record(.resume, row)
        }
    }
    state.barRows[subject] = nil
    #expect(Set(recorder.calls) == Set(targets.map { "\(SIGCONT) \($0.pid)" }))
    #expect(state.rows.isEmpty)
    #expect(!state.barPaused(subject))
}

@Test func watcherDryRunDoesNotMarkWindowRowsPaused() {
    let raised = raisedStorm()
    var watcher = raised.watcher
    let actions = watcher.decide(warnings: raised.warnings, rows: raised.tick.rows,
                                 switches: ActingSwitches(pauseCopies: false),
                                 current: { identities(raised.tick.rows) }, signaller: Recorder(), ownPid: 999)
    var state = ProcessPauseState()
    state.recordWatcher(actions, rows: raised.tick.rows)
    #expect(state.rows.isEmpty)
    #expect(state.barRows.isEmpty)
}

@Test func windowPauseBookkeepingKeepsItsExistingResumeAndRefreshBehaviour() {
    let first = row(100, "worker"), second = row(101, "worker"), third = row(102, "worker")
    var state = ProcessPauseState()
    state.record(.pause, first)
    state.record(.pause, second)
    state.record(.pause, third)
    state.barRows["command:work"] = state.rows
    state.record(.resume, first)
    state.record(.quit, second)
    state.record(.forceQuit, third)
    #expect(state.rows == Set([second, third].map(ProcessTable.rowID)))
    #expect(state.barPaused("command:work"))
    state.refresh { $0 == second.pid ? false : nil }
    #expect(state.rows.isEmpty)
    #expect(!state.barPaused("command:work"))
}

// MARK: - DoD

@Test func theLoopDrivesTheEngineOnRecordedTicksWithNoWindow() {
    // No AppKit in Saur0nCore at all: the engine, the decision and the ledger run on the loop's own thread, and the
    // window is only the front end (calibration locks 1 and 2).
    let raised = raisedStorm()
    let tick = raised.tick, warnings = raised.warnings
    #expect(warnings.count == 1)
    let warning = warnings.first
    #expect(warning?.subject == .command("runaway.sh"))
    #expect(warning?.name == stormName)
    #expect(warning?.conditions.contains { $0.kind == .copies } == true)
    #expect(warning?.pids == tick.rows.map(\.pid).sorted())
}

@Test func aWouldHaveActedLandsWhereTheSnapshotLogTakesItWithItsFigures() {
    let raised = raisedStorm()
    var watcher = raised.watcher
    let tick = raised.tick, warnings = raised.warnings
    let recorder = Recorder()
    let actions = watcher.decide(warnings: warnings, rows: tick.rows, switches: ActingSwitches(pauseCopies: false),
                                 current: { identities(tick.rows) }, signaller: recorder, ownPid: 999)
    #expect(recorder.calls.isEmpty)
    #expect(watcher.ledger.entries.isEmpty)
    let action = actions.first
    #expect(action?.acted == false && action?.paused == [])
    let detail = action?.detail ?? ""
    #expect(detail.hasPrefix(WatcherModel.wouldActPrefix))
    #expect(detail.contains(stormName))
    // The figures, as the warning bar's Details prints them, and why nothing was paused.
    #expect(detail.contains("copies 30"))
    #expect(detail.contains("up 30 in 5 min"))
    #expect(detail.contains("acting.pause.copies is off"))
    // The entry the log takes: the warning snapshot's reason and this detail.
    #expect(action?.trigger == SnapshotTrigger(reason: .warning, detail: detail))
}

@Test func actingOnACopiesStormPausesItsProcessesThroughTheWindowPausePath() {
    let raised = raisedStorm()
    var watcher = raised.watcher
    let tick = raised.tick, warnings = raised.warnings
    let recorder = Recorder()
    let actions = watcher.decide(warnings: warnings, rows: tick.rows, switches: ActingSwitches(pauseCopies: true),
                                 current: { identities(tick.rows) }, signaller: recorder, ownPid: 999,
                                 at: 1_000)
    let pids = tick.rows.map(\.pid).sorted()
    #expect(recorder.calls.count == pids.count)
    #expect(recorder.calls.allSatisfy { $0.hasPrefix("\(SIGSTOP) ") })
    #expect(Set(recorder.calls.compactMap { Int32($0.split(separator: " ")[1]) }) == Set(pids))
    #expect(actions.count == 1)
    #expect(actions.first?.acted == true && actions.first?.paused == pids)
    #expect(actions.first?.detail.hasPrefix(WatcherModel.actedPrefix) == true)
    #expect(actions.first?.detail.contains("paused 30 of 30") == true)
    // The ledger holds what it paused, each with the pid's start time, when and why.
    #expect(watcher.ledger.entries.count == 30)
    #expect(Set(watcher.ledger.entries.map(\.pid)) == Set(pids))
    #expect(watcher.ledger.entries.allSatisfy { $0.startMicroseconds == UInt64($0.pid) * 1_000 })
    #expect(watcher.ledger.entries.allSatisfy { $0.since == 1_000 && $0.subject == "command:runaway.sh" })
    #expect(watcher.ledger.entries.first?.reason.contains("copies 30") == true)
}

@Test func aShellStormPausesItsChildrenFirstAndPersistsEveryPausedProcess() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent(PauseLedger.fileName)
    let raised = raisedStorm()
    let shells = raised.tick.rows
    let children = shells.map { row($0.pid + 1_000, "worker", parent: $0.pid) }
    let grandchild = row(12_000, "compiler", parent: children[0].pid)
    let rows = shells + children + [grandchild]
    var watcher = WatcherModel(ledgerURL: url)
    let recorder = Recorder()
    let actions = watcher.decide(warnings: raised.warnings, rows: rows, switches: ActingSwitches(),
                                 current: { identities(rows) }, signaller: recorder, ownPid: 999, at: 1_000)
    let pids = Set(rows.map(\.pid))
    #expect(Set(actions.first?.paused ?? []) == pids)
    #expect(recorder.calls.count == 61)
    for child in children {
        let childIndex = try #require(recorder.calls.firstIndex(of: "\(SIGSTOP) \(child.pid)"))
        let shellIndex = try #require(recorder.calls.firstIndex(of: "\(SIGSTOP) \(child.ppid)"))
        #expect(childIndex < shellIndex)
    }
    #expect(recorder.calls.first == "\(SIGSTOP) 12000")
    #expect(actions.first?.detail.contains("paused 61 of 61") == true)
    let saved = PauseLedger.load(url)
    #expect(saved == watcher.ledger)
    #expect(Set(saved.entries.map(\.pid)) == pids)
    #expect(saved.entries.allSatisfy { $0.startMicroseconds == UInt64($0.pid) * 1_000 && $0.since == 1_000 })
    #expect(saved.entries.allSatisfy { $0.subject == "command:runaway.sh" && $0.reason.contains("copies 30") })
    var restarted = WatcherModel(ledgerURL: url)
    let resumed = try restarted.resumeOnStart(current: identities(rows), signaller: recorder)
    #expect(Set(resumed) == pids)
    #expect(PauseLedger.load(url).entries.isEmpty)
}

@Test func watcherDescendantsKeepTheIdentityGuardAndLedgerOnlySuccessfulStops() {
    let raised = raisedStorm()
    var watcher = raised.watcher
    let shells = raised.tick.rows
    let children = (0..<4).map { row(Int32(11_000 + $0), "worker", parent: shells[0].pid) }
    let rows = shells + children
    var reused = children[1]
    reused.startMicroseconds += 1
    let current = identities(shells + [reused, children[2], children[3]])
    let recorder = Recorder()
    recorder.refused = [children[2].pid]
    let actions = watcher.decide(warnings: raised.warnings, rows: rows, switches: ActingSwitches(),
                                 current: { current }, signaller: recorder, ownPid: 999)
    let expected = Set(shells.map(\.pid) + [children[3].pid])
    #expect(Set(actions.first?.paused ?? []) == expected)
    #expect(Set(watcher.ledger.entries.map(\.pid)) == expected)
    #expect(recorder.calls.count == 31)
    #expect(recorder.calls.first == "\(SIGSTOP) 11003")
}

@Test func watcherReachSparesSessionDescendantsAndAppleServices() {
    let shell = row(100, "bash")
    var wrapper = row(101, "claude", parent: shell.pid)
    wrapper.usersOwn = true
    let worker = row(102, "worker", parent: wrapper.pid)
    let own = row(999, "Saur0n", parent: shell.pid)
    let service = services(1, first: 20_000)[0]
    let rows = [shell, wrapper, worker, own, service]
    let warning = Warning(subject: .command("example"), name: "example", since: 0, cpuPercent: 3,
                          conditions: [.copies(count: 2, growth: 2, percent: 3)], pids: [shell.pid, service.pid])
    var watcher = WatcherModel()
    let recorder = Recorder()
    let actions = watcher.decide(warnings: [warning], rows: rows, switches: ActingSwitches(),
                                 current: { identities(rows) }, signaller: recorder, ownPid: own.pid)
    #expect(recorder.calls == ["\(SIGSTOP) 102", "\(SIGSTOP) 100"])
    #expect(actions.first?.paused == [102, 100])
    #expect(Set(watcher.ledger.entries.map(\.pid)) == [100, 102])
    #expect(actions.first?.detail.contains("1 Apple service left running") == true)
}

@Test func aWatcherRestartResumesEverythingTheLedgerHoldsPaused() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saur0n-watcher-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent(PauseLedger.fileName)
    let entries = [PauseLedger.Entry(pid: 200, startMicroseconds: 200_000, since: 900, subject: "command:runaway.sh",
                                     reason: "! runaway.sh × 30  copies 30"),
                   PauseLedger.Entry(pid: 201, startMicroseconds: 201_000, since: 900, subject: "command:runaway.sh",
                                     reason: "! runaway.sh × 30  copies 30")]
    try PauseLedger(entries: entries).save(url)
    let recorder = Recorder()
    // The next start reads the ledger, resumes the two processes by pid and start time, and leaves the file empty.
    var restarted = WatcherModel(ledgerURL: url)
    let resumed = try restarted.resumeOnStart(current: identities([row(200, "bash"), row(201, "bash")]), signaller: recorder)
    #expect(resumed == [200, 201])
    #expect(recorder.calls == ["\(SIGCONT) 200", "\(SIGCONT) 201"])
    #expect(PauseLedger.load(url).entries.isEmpty)
    #expect(restarted.ledger.entries.isEmpty)
}

// MARK: - Edge cases

@Test func aLedgerEntryWhosePidIsGoneOrReusedResumesNothing() {
    let recorder = Recorder()
    var ledger = PauseLedger(entries: [
        // Gone: no process list entry at all.
        PauseLedger.Entry(pid: 300, startMicroseconds: 300_000, since: 1, subject: "command:x", reason: "x"),
        // Reused: pid 301 is there, with another start time.
        PauseLedger.Entry(pid: 301, startMicroseconds: 301_000, since: 1, subject: "command:x", reason: "x"),
    ])
    let reused = row(301, "sleep")
    var differentStart = reused
    differentStart.startMicroseconds = 999_000
    let resumed = ledger.resumeAll(current: identities([differentStart]), signaller: recorder)
    #expect(resumed.isEmpty)
    #expect(recorder.calls.isEmpty)
    #expect(ledger.entries.isEmpty)
}

@Test func oneActionPerRaiseAndAFreshOneWhenTheWarningReturns() {
    var watcher = WatcherModel()
    let recorder = Recorder()
    _ = watcher.warnings(rest(1))
    var last = storm(2)
    for t in 2...14 {
        last = storm(Double(t))
        let warnings = watcher.warnings(last)
        // While the warning stays raised, only the first tick acts: the raise is logged once, not every second.
        let actions = watcher.decide(warnings: warnings, rows: last.rows, switches: ActingSwitches(pauseCopies: true),
                                     current: { identities(last.rows) }, signaller: recorder, ownPid: 999)
        if t >= 11 { #expect(actions.count == (t == 11 ? 1 : 0), "second \(t)") }
    }
    let first = recorder.calls.count
    #expect(first == 30)
    // Cleared, then raised again: a fresh action, a fresh 30 stops — a stopped process takes SIGSTOP again, no crash.
    for t in 15...25 { _ = watcher.warnings(rest(Double(t))) }
    for t in 26...40 {
        last = storm(Double(t), generation: 1)
        let warnings = watcher.warnings(last)
        _ = watcher.decide(warnings: warnings, rows: last.rows, switches: ActingSwitches(pauseCopies: true),
                           current: { identities(last.rows) }, signaller: recorder, ownPid: 999)
    }
    #expect(recorder.calls.count == 60)
}

@Test func aDefaultsChangeTakesEffectOnTheNextTick() {
    var watcher = WatcherModel()
    let recorder = Recorder()
    var defaults: [String: Any] = [ActingSwitches.pauseCopiesKey: false]
    _ = watcher.warnings(rest(1))
    var tick = storm(2)
    var warnings: [Warning] = []
    for t in 2...14 {
        tick = storm(Double(t))
        warnings = watcher.warnings(tick)
    }
    // Off: logged, nothing paused.
    var actions = watcher.decide(warnings: warnings, rows: tick.rows,
                                 switches: ActingSwitches.read { defaults[$0] }, current: { identities(tick.rows) },
                                 signaller: recorder, ownPid: 999)
    #expect(actions.first?.acted == false)
    #expect(recorder.calls.isEmpty)
    // Switched on while the storm runs: the next subject's raise — another script's copies — is paused at once.
    defaults[ActingSwitches.pauseCopiesKey] = true
    for t in 15...30 {
        tick = storm(Double(t), generation: 5, script: "/tmp/example/another.sh")
        warnings = watcher.warnings(tick)
    }
    actions = watcher.decide(warnings: warnings, rows: tick.rows,
                             switches: ActingSwitches.read { defaults[$0] }, current: { identities(tick.rows) },
                             signaller: recorder, ownPid: 999)
    #expect(actions.contains { $0.acted && $0.name == "another.sh × 30" })
    #expect(recorder.calls.count == 30)
}

@Test func theDefaultsKeepTheLockedSplitAndAnUnsetKeyKeepsItsDefault() {
    #expect(ActingSwitches() == ActingSwitches(pauseCopies: true, pauseMemory: false, throttle: false))
    #expect(ActingSwitches.read { _ in nil } == ActingSwitches(pauseCopies: true, pauseMemory: false, throttle: false))
    #expect(ActingSwitches.read { $0 == ActingSwitches.pauseMemoryKey ? true : nil }.pauseMemory)
    #expect(ActingSwitches().pauseCopies)
    // A launch argument is a string in the argument domain (`-acting.pause.copies NO`): it reads as `bool(forKey:)` does.
    #expect(ActingSwitches.read { $0 == ActingSwitches.pauseCopiesKey ? "NO" : nil } == ActingSwitches(pauseCopies: false))
    #expect(ActingSwitches.read { $0 == ActingSwitches.throttleKey ? "YES" : nil } == ActingSwitches(throttle: true))
    #expect(ActingSwitches.read { $0 == ActingSwitches.pauseMemoryKey ? NSNumber(value: 0) : nil }.pauseMemory == false)
}

@Test func theLedgerLivesBesideTheSnapshotLog() throws {
    let url = PauseLedger.defaultURL(environment: ["SAUR0N_SNAPSHOT_DIR": "/tmp/example/snapshots"])
    #expect(url.path == "/tmp/example/snapshots/\(PauseLedger.fileName)")
    // The user's own folder otherwise, in the log's.
    let home = URL(fileURLWithPath: "/fixtures/example")
    #expect(PauseLedger.defaultURL(environment: [:], home: home).path
        == "/fixtures/example/Library/Application Support/Saur0n/\(PauseLedger.fileName)")
    // A file that is absent or unreadable reads as none: a start never throws over a stale ledger.
    #expect(PauseLedger.load(nil).entries.isEmpty)
    #expect(PauseLedger.load(URL(fileURLWithPath: "/tmp/example/no-such-ledger.json")).entries.isEmpty)
    let entry = PauseLedger.Entry(pid: 400, startMicroseconds: 400_000, since: 5, subject: "command:x", reason: "x")
    var ledger = PauseLedger()
    ledger.add(entry)
    ledger.add(PauseLedger.Entry(pid: 400, startMicroseconds: 400_000, since: 6, subject: "command:x", reason: "y"))
    #expect(ledger.entries.count == 1 && ledger.entries.first?.since == 6)    // one entry a pid
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saur0n-ledger-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent(PauseLedger.fileName)
    try ledger.save(file)
    #expect(PauseLedger.load(file) == ledger)
}

// MARK: - Apple services are warned about and never paused on their own (the 2026-10-26 batch, ranks 1 and 3)

/// A tick of `rows` (with the arguments of the ones that run a script), ending at `end`.
private func tickOf(_ end: Double, _ rows: [ProcessUsage], _ arguments: [Int32: ProcessArguments] = [:]) -> WarningTick {
    let commands = CommandGroups.assign(rows, arguments: arguments)
    return WarningTick(end: end, seconds: 1, cpus: cpus, unattributedCpuPercent: 5,
                       loadAverage: LoadAverage(oneMinute: 20, fiveMinutes: 20, fifteenMinutes: 20),
                       split: CPUSplit(user: 60, system: 20), rows: commands.rows, commandGroups: commands.groups,
                       repoGroups: [], sessionGroups: [])
}

/// `count` copies of `name` from `path`, children of launchd with the platform bit set as Apple's own binaries carry
/// it, leading their own process group when `lead` (a launchd job does; an orphaned tool keeps its launcher's group), at
/// 0.75% of the machine each — the research's Spotlight burst. `scripts` gives each the arguments to run.
private func processes(_ count: Int, _ name: String, path: String, first: Int32, lead: Bool = true, platform: Bool = true,
                       argv: [String]? = nil) -> (rows: [ProcessUsage], arguments: [Int32: ProcessArguments]) {
    var rows: [ProcessUsage] = [], arguments: [Int32: ProcessArguments] = [:]
    for i in 0..<count {
        let pid = first + Int32(i)
        var process = ProcessUsage(pid: pid, ppid: 1, uid: 501, user: "user", path: path, name: name, cpuPercent: 0.75,
                                   residentBytes: 1 << 20, source: .libproc, exitedChildrenCpuPercent: 0)
        process.startMicroseconds = UInt64(pid) * 1_000
        process.processGroup = lead ? pid : 4_000
        process.platformBinary = platform
        rows.append(process)
        if let argv { arguments[pid] = ProcessArguments(argv: argv, environment: [:]) }
    }
    return (rows, arguments)
}

private let servicePath = "/System/Library/Frameworks/CoreServices.framework/Support/mdworker_shared"

/// `count` Apple services from `first`.
private func services(_ count: Int, first: Int32 = 20_000) -> [ProcessUsage] {
    processes(count, "mdworker_shared", path: servicePath, first: first).rows
}

/// `count` forged namesakes of the service from a temp folder, the platform bit clear.
private func forgeries(_ count: Int, first: Int32 = 21_000) -> [ProcessUsage] {
    processes(count, "mdworker_shared", path: "/tmp/example/mdworker_shared", first: first, platform: false).rows
}

/// A watcher driven over a quiet second and then 13 seconds of `rows`: the warnings in force and the last tick.
private typealias Run = (watcher: WatcherModel, tick: WarningTick, warnings: [Warning])

private func raised(_ rows: [ProcessUsage], _ arguments: [Int32: ProcessArguments] = [:]) -> Run {
    var watcher = WatcherModel()
    _ = watcher.warnings(rest(1))
    var tick = rest(1), warnings: [Warning] = []
    for t in 2...14 {
        tick = tickOf(Double(t), rows, arguments)
        warnings = watcher.warnings(tick)
    }
    return (watcher, tick, warnings)
}

private func decide(_ run: inout Run, _ recorder: Recorder, _ switches: ActingSwitches = ActingSwitches(),
                    rows: [ProcessUsage]? = nil) -> [WatcherModel.Action] {
    let rows = rows ?? run.tick.rows
    return run.watcher.decide(warnings: run.warnings, rows: rows, switches: switches,
                              current: { identities(rows) }, signaller: recorder, ownPid: 999)
}

private func stops(_ pids: Range<Int32>) -> Set<String> { Set(pids.map { "\(SIGSTOP) \($0)" }) }

@Test func theExemptionIsOnByDefaultAndReadFromItsKey() {
    #expect(ActingSwitches.exemptAppleKey == "acting.exempt.apple")
    #expect(ActingSwitches().exemptApple && ActingSwitches.read { _ in nil }.exemptApple)
    #expect(!ActingSwitches.read { $0 == ActingSwitches.exemptAppleKey ? false : nil }.exemptApple)
    #expect(!ActingSwitches.read { $0 == ActingSwitches.exemptAppleKey ? "NO" : nil }.exemptApple)
    // The other keys are untouched by it.
    #expect(ActingSwitches.read { $0 == ActingSwitches.exemptAppleKey ? false : nil }.pauseCopies)
}

@Test func appleServiceBurstFromZeroIsLoggedWouldActAndNeverPaused() {
    var run = raised(services(32))
    #expect(run.warnings.first?.name == "mdworker_shared × 32")
    let recorder = Recorder()
    let actions = decide(&run, recorder)
    #expect(recorder.calls.isEmpty && run.watcher.ledger.entries.isEmpty)
    #expect(actions.count == 1)
    let action = actions.first
    #expect(action?.acted == false && action?.paused == [])
    let detail = action?.detail ?? ""
    #expect(detail.hasPrefix(WatcherModel.wouldActPrefix))
    #expect(detail.contains("mdworker_shared × 32") && detail.contains("(not paused: Apple service)"))
    #expect(!detail.contains("paused 0 of 0"))
}

@Test func aMixedGroupPausesOnlyTheMembersThatAreNotAppleServices() {
    var run = raised(services(30) + forgeries(3))
    let recorder = Recorder()
    let action = decide(&run, recorder).first
    #expect(Set(recorder.calls) == stops(21_000..<21_003))
    #expect(action?.acted == true && action?.paused == [21_000, 21_001, 21_002])
    #expect(action?.detail.contains("paused 3 of 3") == true)
    #expect(action?.detail.contains("30 Apple services left running") == true)
    #expect(run.watcher.ledger.entries.map(\.pid).sorted() == [21_000, 21_001, 21_002])
}

@Test func tenSleepCopiesUnderLaunchdStillPause() {
    let sleeps = processes(40, "sleep", path: "/bin/sleep", first: 30_000, lead: false, argv: ["sleep", "600"])
    var run = raised(sleeps.rows, sleeps.arguments)
    let recorder = Recorder()
    let action = decide(&run, recorder).first
    #expect(action?.acted == true && recorder.calls.count == 40)
}

@Test func perlScriptCopiesKeyedByTheirScriptAreNotAnAppleService() {
    let perls = processes(40, "perl", path: "/usr/bin/perl", first: 30_000, argv: ["/usr/bin/perl", "build.pl"])
    var run = raised(perls.rows, perls.arguments)
    let recorder = Recorder()
    #expect(decide(&run, recorder).first?.acted == true)
    #expect(recorder.calls.count == 40)
}

@Test func aLaunchdJobRunningBinBashWithAScriptIsNotAnAppleService() {
    // Parent launchd, leading its own group, even a service path: bash running job.sh is a script, not the service.
    let jobs = processes(30, "bash", path: "/usr/libexec/job-runner", first: 30_000, argv: ["/bin/bash", "job.sh"])
    var run = raised(jobs.rows, jobs.arguments)
    let recorder = Recorder()
    #expect(decide(&run, recorder).first?.acted == true)
    #expect(recorder.calls.count == 30)
}

@Test func switchingTheExemptionOffPausesWhatWasWithheldOnceAndNothingTwice() {
    // Thirty services and three genuine copies in one warning: the three pause at the raise; the exemption goes off on
    // a later tick and the thirty pause then — the three are not paused again — and a further tick repeats nothing.
    var run = raised(services(30) + forgeries(3))
    let recorder = Recorder()
    _ = decide(&run, recorder)
    #expect(recorder.calls.count == 3)
    #expect(decide(&run, recorder).isEmpty && recorder.calls.count == 3)    // still exempt: nothing more
    let off = ActingSwitches(exemptApple: false)
    let actions = decide(&run, recorder, off)
    #expect(actions.count == 1 && actions.first?.acted == true && actions.first?.paused.count == 30)
    #expect(recorder.calls.count == 33)
    #expect(Set(recorder.calls.suffix(30)) == stops(20_000..<20_030))
    #expect(decide(&run, recorder, off).isEmpty && decide(&run, recorder).isEmpty && recorder.calls.count == 33)
    #expect(run.watcher.ledger.entries.count == 33)
}

@Test func anAllExemptWarningPausesOnTheTickTheExemptionGoesOff() {
    var run = raised(services(32))
    let recorder = Recorder()
    #expect(decide(&run, recorder).first?.acted == false)
    #expect(decide(&run, recorder).isEmpty && recorder.calls.isEmpty)
    let actions = decide(&run, recorder, ActingSwitches(exemptApple: false))
    #expect(actions.first?.acted == true && recorder.calls.count == 32)
    // Put back on: the paused stay as they are, nothing is signalled again.
    #expect(decide(&run, recorder).isEmpty && recorder.calls.count == 32)
}

@Test func anAppleServiceThatJoinsAWarningLateIsPausedWhenTheExemptionGoesOff() {
    var run = raised(services(32))
    let recorder = Recorder()
    _ = decide(&run, recorder)
    // Five more services join the same warning on a later tick, the exemption still on: nothing is signalled.
    let rows = services(32) + services(5, first: 20_100)
    run.tick = tickOf(15, rows)
    run.warnings = run.watcher.warnings(run.tick)
    #expect(decide(&run, recorder, rows: rows).isEmpty && recorder.calls.isEmpty)
    // The exemption goes off: the late five are paused with the first thirty-two, each once.
    let actions = decide(&run, recorder, ActingSwitches(exemptApple: false), rows: rows)
    #expect(actions.first?.acted == true && recorder.calls.count == 37)
    #expect(recorder.calls.contains("\(SIGSTOP) 20100"))
    #expect(decide(&run, recorder, ActingSwitches(exemptApple: false), rows: rows).isEmpty && recorder.calls.count == 37)
}

@Test func theExemptionOffFromTheStartPausesTheServicesAtTheRaise() {
    var run = raised(services(32))
    let recorder = Recorder()
    let action = decide(&run, recorder, ActingSwitches(exemptApple: false)).first
    #expect(action?.acted == true && recorder.calls.count == 32)
}

@Test func withTheRungOffAnAppleBurstIsOnlyLoggedAndTurningTheExemptionOffPausesNothing() {
    var run = raised(services(32))
    let recorder = Recorder()
    let dry = decide(&run, recorder, ActingSwitches(pauseCopies: false))
    #expect(dry.first?.acted == false && dry.first?.detail.contains("acting.pause.copies is off") == true)
    #expect(decide(&run, recorder, ActingSwitches(pauseCopies: true, exemptApple: false)).isEmpty)
    #expect(recorder.calls.isEmpty)
}

@Test func aPidReusedByAnotherProcessIsNotPausedWhenTheExemptionGoesOff() {
    var run = raised(services(32))
    let recorder = Recorder()
    _ = decide(&run, recorder)
    // Pid 20_005 now belongs to another process (a later start time, no platform bit): not the one that was withheld.
    var rows = run.tick.rows
    var reused = ProcessUsage(pid: 20_005, ppid: 1, uid: 501, user: "user", path: "/opt/example/bin/tool", name: "tool",
                              cpuPercent: 0.75, residentBytes: 1 << 20, source: .libproc, exitedChildrenCpuPercent: 0)
    reused.startMicroseconds = 999_000_000
    rows[rows.firstIndex { $0.pid == 20_005 }!] = reused
    _ = decide(&run, recorder, ActingSwitches(exemptApple: false), rows: rows)
    #expect(recorder.calls.count == 31)
    #expect(!recorder.calls.contains("\(SIGSTOP) 20005"))
}

@Test func theWatcherNeverSignalsAProtectedSessionProcess() {
    // Whatever a warning names, the user's interactive root and its wrappers (`usersOwn`) are not targets.
    var rows = (0..<3).map { row(Int32(40_000 + $0), "claude", cpu: 1) }
    rows[0].usersOwn = true
    let warning = Warning(subject: .command("example"), name: "example × 3", since: 0, cpuPercent: 3,
                          conditions: [.copies(count: 3, growth: 3, percent: 3)], pids: [40_000, 40_001, 40_002])
    var run: Run = (WatcherModel(), tickOf(1, rows), [warning])
    let recorder = Recorder()
    let action = decide(&run, recorder, rows: rows).first
    #expect(Set(recorder.calls) == stops(40_001..<40_003))
    #expect(action?.paused.sorted() == [40_001, 40_002])
}

// MARK: - The ledger survives what it cannot read or write (the step gate's finding, 2026-10-27)

private func scratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saur0n-watcher-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test func anUnreadableProcessListAtStartKeepsTheLedgerAndSignalsNothing() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent(PauseLedger.fileName)
    let entries = [PauseLedger.Entry(pid: 200, startMicroseconds: 200_000, since: 900, subject: "command:runaway.sh",
                                     reason: "! runaway.sh × 30  copies 30")]
    try PauseLedger(entries: entries).save(url)
    let recorder = Recorder()
    var restarted = WatcherModel(ledgerURL: url)
    let resumed = try restarted.resumeOnStart(current: nil, signaller: recorder)
    #expect(resumed.isEmpty && recorder.calls.isEmpty)
    // Nothing is known about those processes, so the record of them stays — in memory and on disk.
    #expect(restarted.ledger.entries == entries)
    #expect(PauseLedger.load(url).entries == entries)
}

@Test func aLedgerThatCannotBeWrittenIsReportedNotIgnored() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // A regular file where the ledger's folder should be: the write cannot succeed.
    let blocker = folder.appendingPathComponent("blocker")
    try Data().write(to: blocker)
    let url = blocker.appendingPathComponent(PauseLedger.fileName)

    var restarted = WatcherModel(ledgerURL: url)
    #expect(throws: (any Error).self) {
        try restarted.resumeOnStart(current: [], signaller: Recorder())
    }

    var watcher = WatcherModel(ledgerURL: url)
    var warnings: [Warning] = []
    var last = storm(0)
    _ = watcher.warnings(rest(1))
    for t in 2...14 {
        last = storm(Double(t))
        warnings = watcher.warnings(last)
    }
    let tick = last
    #expect(watcher.ledgerError == nil)
    _ = watcher.decide(warnings: warnings, rows: tick.rows, switches: ActingSwitches(pauseCopies: true),
                       current: { identities(tick.rows) }, signaller: Recorder(), ownPid: 999, at: 1_000)
    #expect(watcher.ledgerError != nil)
}
