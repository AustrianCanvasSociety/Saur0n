// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3
import Testing
@testable import Saur0nCore

// Goal: the snapshot log (Phase 6 Step 7) — a snapshot on each warning and each peak keeps the machine, its last
// minute and the rows with the aggregates as shown, in a size-capped SQLite log, oldest dropped first; `saur0n
// snapshot <time>` reads the latest at or before a time. Method: a snapshot built in code (6 CPUs in two core types,
// 12 repos, a catch-all with an app and a folded rest, a storm of copies, a warning), logs in temp folders only.

private let topology = CoreTopology(
    levels: [PerfLevel(index: 0, name: "Super", logicalCPUCount: 2),
             PerfLevel(index: 1, name: "Performance", logicalCPUCount: 4)],
    cpusByLevel: [[4, 5], [0, 1, 2, 3]])
private let epoch = 1_792_850_000.0    // 2026-10-24, the time the snapshots are taken at
private let script = "/tmp/example/storm.sh"

private func row(_ pid: Int32, _ name: String, parent: Int32 = 1, cpu: Double = 0, user: String = "user",
                 startedAgo: Double = 3_600) -> ProcessUsage {
    var row = ProcessUsage(pid: pid, ppid: parent, uid: user == "root" ? 0 : 501, user: user, path: "/usr/bin/" + name,
                           name: name, cpuPercent: cpu, residentBytes: 1 << 20, source: .libproc,
                           exitedChildrenCpuPercent: 0)
    row.startMicroseconds = UInt64((epoch - startedAgo) * 1_000_000)
    return row
}

private func repo(_ name: String, _ rows: [ProcessUsage], subgroups: [CatchAllBreakout.Subgroup] = []) -> RepoGroup {
    RepoGroup(name: name, root: subgroups.isEmpty ? "/work/" + name : nil,
              cpuPercent: rows.map(\.cpuPercent).reduce(0, +), exitedChildrenCpuPercent: 0,
              residentBytes: UInt64(rows.count) << 20, pids: rows.map(\.pid), subgroups: subgroups)
}

private func subgroup(_ name: String, _ kind: CatchAllBreakout.Subgroup.Kind, _ rows: [ProcessUsage]) -> CatchAllBreakout.Subgroup {
    CatchAllBreakout.Subgroup(name: name, kind: kind, cpuPercent: rows.map(\.cpuPercent).reduce(0, +),
                              exitedChildrenCpuPercent: 0, residentBytes: UInt64(rows.count) << 20, disk: .zero,
                              network: .zero, pids: rows.map(\.pid))
}

/// 12 repos of 3 rows each (repo i's `node<i>` rows at 12 - i % of CPU each), a catch-all of an app's 2 rows and 15
/// folded others, and 30 copies of a script under launchd, each over a busy child, started under a minute ago. By
/// session the catch-all comes first, then one session per repo; by command each repo's command is its own group.
private struct Fixture {
    var rows: [ProcessUsage] = []
    var repos: [RepoGroup] = []
    var sessions: [SessionGroup] = []
    var arguments: [Int32: ProcessArguments] = [:]
    var folders: [Int32: String] = [:]
    var processGroups: [Int32: Int32] = [:]

    init() {
        var perRepo: [SessionGroup] = []
        for i in 0..<12 {
            let members = (0..<3).map { row(Int32(1_000 + i * 10 + $0), "node\(i)", cpu: Double(12 - i)) }
            rows += members
            repos.append(repo("repo\(i)", members))
            perRepo.append(SessionGroup(name: "s\(i)", kind: .claude, id: "s\(i)", cpuPercent: Double(3 * (12 - i)),
                                        exitedChildrenCpuPercent: 0, residentBytes: 3 << 20, pids: members.map(\.pid)))
            for member in members { folders[member.pid] = "/work/repo\(i)" }
        }
        let app = (0..<2).map { row(Int32(3_000 + $0), "Firefox", cpu: 0.5) }
        let others = (0..<15).map { row(Int32(3_100 + $0), "daemon\($0)", cpu: Double($0) / 10, user: "root") }
        var storm: [ProcessUsage] = []
        for i in 0..<30 {
            let copy = Int32(5_000 + i * 2)
            storm.append(row(copy, "bash", startedAgo: 30))
            storm.append(row(copy + 1, "perl", parent: copy, cpu: 0.4, startedAgo: 29))
            arguments[copy] = ProcessArguments(argv: ["/bin/bash", script], environment: [:])
            arguments[copy + 1] = ProcessArguments(argv: ["perl", "-e", "1 while 1"], environment: [:])
            processGroups[copy] = copy
            processGroups[copy + 1] = copy
        }
        rows += app + others + storm
        let catchAll = [subgroup("Firefox", .app, app), subgroup("bash", .command, storm),
                        subgroup("15 other processes", .other, others)]
        let outside = app + others + storm
        repos.append(repo("Not in a repo", outside, subgroups: catchAll))
        sessions = [SessionGroup(name: "No session", kind: nil, id: nil,
                                 cpuPercent: outside.map(\.cpuPercent).reduce(0, +), exitedChildrenCpuPercent: 0,
                                 residentBytes: UInt64(outside.count) << 20, pids: outside.map(\.pid), subgroups: catchAll)]
            + perRepo
        for row in rows where processGroups[row.pid] == nil { processGroups[row.pid] = row.pid }
    }

    var warning: Warning {
        Warning(subject: .command(script), name: "storm.sh × 30", since: 100, cpuPercent: 12,
                conditions: [.copies(count: 30, growth: 30, percent: 12)],
                pids: rows.filter { $0.pid >= 5_000 }.map(\.pid).sorted())
    }

    func snapshot(warnings: [Warning]? = nil) throws -> Snapshot {
        let commands = CommandGroups.assign(rows, arguments: arguments)
        let load = CPULoad(perCPU: [90, 80, 70, 60, 100, 100], total: 83.3, split: CPUSplit(user: 40, system: 43.3))
        return try Snapshot(topology: topology, load: load, intervalSeconds: 1, processes: commands.rows,
                            repoGroups: repos, sessionGroups: sessions, commandGroups: commands.groups,
                            loadAverage: LoadAverage(oneMinute: 41.2, fiveMinutes: 20, fifteenMinutes: 9),
                            warnings: warnings)
    }

    func input(warnings: [Warning]? = nil, history: [MachinePoint] = [], end: Double = epoch) throws -> SnapshotInput {
        let identities = rows.map {
            ProcessIdentity(pid: $0.pid, ppid: $0.ppid, uid: $0.uid, user: $0.user, startMicroseconds: $0.startMicroseconds,
                            comm: $0.name, path: $0.path, processGroup: processGroups[$0.pid])
        }
        return SnapshotInput(snapshot: try snapshot(warnings: warnings), identities: identities, arguments: arguments,
                             folders: folders, history: history, end: end)
    }
}

/// A folder of its own under the temp folder, removed after `body`.
private func withTempFolder<T>(_ body: (URL) throws -> T) throws -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saur0n-snapshots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try body(folder)
}

private func history(seconds: Int = 75, end: Double = epoch) throws -> [MachinePoint] {
    let fixture = Fixture()
    var history = MachineHistory()
    for s in 0..<seconds {
        history.append(MachinePoint(snapshot: try fixture.snapshot(), end: end - Double(seconds - 1 - s)))
    }
    return history.points
}

private func record(at takenAt: Double = epoch, reason: SnapshotRecord.Reason = .warning) throws -> SnapshotRecord {
    let fixture = Fixture()
    return SnapshotRecord(try fixture.input(warnings: [fixture.warning], history: try history(end: takenAt), end: takenAt),
                          reason: reason, detail: "storm.sh × 30")
}

@Test func snapshotRoundTripsThroughTheLog() throws {
    let original = try record()
    try withTempFolder { folder in
        let log = try SnapshotLog(url: folder.appendingPathComponent(SnapshotLog.fileName))
        let entry = try log.write(original)
        #expect(entry.takenAt == epoch && entry.reason == .warning && entry.detail == "storm.sh × 30")
        #expect(entry.cpuPercent == 83.3 && entry.processes == original.machine.processes && entry.bytes > 0)
        let reopened = try SnapshotLog(url: folder.appendingPathComponent(SnapshotLog.fileName), readOnly: true)
        #expect(try reopened.entries() == [entry])
        #expect(try reopened.record(entry.id) == original)
    }
}

@Test func capDropsTheOldestFirst() throws {
    try withTempFolder { folder in
        let url = folder.appendingPathComponent(SnapshotLog.fileName)
        let probe = try SnapshotLog(url: url)
        let size = try probe.write(try record(at: epoch - 100)).bytes
        // Room for three bodies (each about the same size), not four.
        let log = try SnapshotLog(url: url, cap: size * 3 + size / 2)
        for i in 1...4 { try log.write(try record(at: epoch + Double(i))) }
        let entries = try log.entries()
        #expect(entries.map(\.takenAt) == [epoch + 2, epoch + 3, epoch + 4])
        #expect(entries.map(\.bytes).reduce(0, +) <= log.cap)
    }
}

@Test func theLogLivesInApplicationSupportAndTestsWriteOnlyUnderTemp() throws {
    let home = URL(fileURLWithPath: "/fixtures/example")
    #expect(SnapshotLog.defaultURL(environment: [:], home: home).path
            == "/fixtures/example/Library/Application Support/Saur0n/snapshots.sqlite")
    #expect(SnapshotLog.defaultURL(environment: ["SAUR0N_SNAPSHOT_DIR": "/tmp/example"], home: home).path
            == "/tmp/example/snapshots.sqlite")
    let real = SnapshotLog.defaultURL()
    let existedBefore = FileManager.default.fileExists(atPath: real.path)
    try withTempFolder { folder in
        let url = folder.appendingPathComponent("nested/" + SnapshotLog.fileName)
        try SnapshotLog(url: url).write(try record())
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    if !existedBefore { #expect(!FileManager.default.fileExists(atPath: real.path)) }
}

@Test func captureKeepsTopGroupsWholeAndCountsTheRest() throws {
    let fixture = Fixture()
    let kept = SnapshotRecord.kept(try fixture.snapshot(warnings: [fixture.warning]))
    // The first 10 repos whole; repos 10 and 11 by their header only.
    for i in 0..<10 { #expect(kept.isSuperset(of: (0..<3).map { Int32(1_000 + i * 10 + $0) })) }
    #expect(kept.isDisjoint(with: (0..<3).flatMap { [Int32(1_100 + $0), Int32(1_110 + $0)] }))
    // The catch-all: the app's and the copies' rows, and its 10 busiest folded rows.
    #expect(kept.isSuperset(of: [3_000, 3_001]))
    let copies: [Int32] = (5_000..<5_060).map { Int32($0) }
    #expect(kept.isSuperset(of: copies))
    #expect(kept.intersection((0..<15).map { Int32(3_100 + $0) }) == Set((5..<15).map { Int32(3_100 + $0) }))
}

@Test func capturedTablesKeepEveryHeaderAndTheUnattributedLine() throws {
    let fixture = Fixture()
    let snapshot = try fixture.snapshot(warnings: [fixture.warning])
    let record = SnapshotRecord(try fixture.input(warnings: [fixture.warning]), reason: .warning, detail: "")
    let dropped = Set(fixture.rows.map(\.pid)).subtracting(SnapshotRecord.kept(snapshot)).map { String($0) }
    for grouping in ProcessTable.Grouping.allCases {
        let full = snapshot.table(by: grouping).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stored = try #require(record.tables[grouping.rawValue])
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The full table less the dropped rows' lines (each starts with its pid, right-aligned in 7): every header,
        // machine line and the Unattributed line as they were, in order.
        let pidColumn = { (line: String) in line.prefix(7).trimmingCharacters(in: .whitespaces) }
        #expect(stored == full.filter { !dropped.contains(pidColumn($0)) })
        #expect(stored.contains { $0.hasPrefix("Unattributed CPU") })
        #expect(stored.count < full.count)
    }
    let command = try #require(record.tables["command"])
    #expect(command.contains("storm.sh × 30  "))
    #expect(command.contains("Warnings\n  ! storm.sh × 30"))
}

@Test func recordKeepsTheRowsFieldsAndTheMachine() throws {
    let fixture = Fixture()
    let record = SnapshotRecord(try fixture.input(warnings: [fixture.warning], history: try history()),
                                reason: .warning, detail: "storm.sh × 30")
    let copy = try #require(record.rows.first { $0.pid == 5_000 })
    #expect(copy.parent == 1 && copy.processGroup == 5_000 && copy.arguments == ["/bin/bash", script])
    #expect(copy.command == "storm.sh" && copy.repo == "Not in a repo" && copy.session == "No session")
    #expect(copy.startedAt == epoch - 30)
    let node = try #require(record.rows.first { $0.pid == 1_000 })
    #expect(node.folder == "/work/repo0" && node.cpuPercent == 12)
    #expect(record.machine.processes == fixture.rows.count)
    #expect(record.machine.young == 60)
    #expect(record.machine.coreTypes.map(\.name) == ["Super", "Performance"])
    #expect(record.machine.coreTypes.map(\.averagePercent) == [100, 75])
    #expect(record.machine.loadAverage == [41.2, 20, 9])
    #expect(record.machine.warnings == [fixture.warning.text])
    #expect(record.history.count == 60)
}

@Test func longArgumentsAreCutAtThePathLimit() {
    let path = "/" + String(repeating: "a", count: 1_023)
    #expect(SnapshotRecord.clipped(path) == path)
    let inline = String(repeating: "x", count: 33_000)
    #expect(SnapshotRecord.clipped(inline).count == 1_024 && SnapshotRecord.clipped(inline).hasSuffix("…"))
}

@Test func historyKeepsTheLastMinute() throws {
    let points = try history(seconds: 75)
    #expect(points.count == 60)
    #expect(points.first?.end == epoch - 59 && points.last?.end == epoch)
    #expect(points.last?.young == 60 && points.last?.processes == Fixture().rows.count)
}

@Test func triggersSpaceOutPeaksAndRepeatWarningsAfterFiveMinutes() throws {
    let fixture = Fixture()
    var triggers = SnapshotTriggers()
    #expect(triggers.next(end: 0, warnings: [], peaks: []) == nil)
    #expect(triggers.next(end: 1, warnings: [], peaks: ["CPU node 48.0%"]) == SnapshotTrigger(reason: .peak, detail: "CPU node 48.0%"))
    // A burst: one peak snapshot a minute.
    for s in 2..<61 { #expect(triggers.next(end: Double(s), warnings: [], peaks: ["CPU node 48.0%"]) == nil) }
    #expect(triggers.next(end: 61, warnings: [], peaks: ["Disk dd 400 M/s"])?.reason == .peak)
    // A warning on entry, then held: again only 5 minutes on.
    #expect(triggers.next(end: 62, warnings: [fixture.warning], peaks: [])
            == SnapshotTrigger(reason: .warning, detail: "storm.sh × 30"))
    for s in 63..<362 { #expect(triggers.next(end: Double(s), warnings: [fixture.warning], peaks: []) == nil) }
    #expect(triggers.next(end: 362, warnings: [fixture.warning], peaks: [])?.reason == .warning)
    // Cleared and back within the 5 minutes: none.
    #expect(triggers.next(end: 400, warnings: [], peaks: []) == nil)
    #expect(triggers.next(end: 420, warnings: [fixture.warning], peaks: []) == nil)
}

@Test func timesParseAsLocalClockTimeAndPickTheLatestAtOrBefore() throws {
    let zone = try #require(TimeZone(identifier: "Europe/Berlin"))
    let now = try #require(SnapshotTime.parse("2026-10-24 18:00:00", now: Date(), timeZone: zone))
    let today = Date(timeIntervalSince1970: now)
    // Without seconds a time covers its whole minute; with them, its second.
    #expect(SnapshotTime.parse("14:03", now: today, timeZone: zone) == SnapshotTime.parse("2026-10-24 14:03:59", now: today, timeZone: zone))
    #expect(SnapshotTime.parse("2026-10-24 14:03:07", now: today, timeZone: zone)
            == SnapshotTime.parse("2026-10-24 14:03:06", now: today, timeZone: zone)! + 1)
    #expect(SnapshotTime.parse("2026-10-24T14:03:07", now: today, timeZone: zone)
            == SnapshotTime.parse("14:03:07", now: today, timeZone: zone))
    #expect(SnapshotTime.parse("9:05", now: today, timeZone: zone) != nil)
    for bad in ["25:00", "14:3", "yesterday", "2026-02-30 10:00", "14:03:61", ""] {
        #expect(SnapshotTime.parse(bad, now: today, timeZone: zone) == nil, "\(bad)")
    }
    let text = SnapshotTime.text(now, timeZone: zone)
    #expect(text == "2026-10-24 18:00:00")
    let entries = [10.0, 20, 30].map {
        SnapshotLog.Entry(id: Int64($0), takenAt: $0, reason: .peak, detail: "", cpuPercent: 0, unattributedPercent: nil,
                          processes: 0, bytes: 0)
    }
    #expect(SnapshotLog.entry(atOrBefore: 25, in: entries)?.takenAt == 20)
    #expect(SnapshotLog.entry(atOrBefore: 30, in: entries)?.takenAt == 30)
    #expect(SnapshotLog.entry(atOrBefore: 9, in: entries) == nil)
}

@Test func aNewerFormatIsRefusedAndAnEmptyLogListsNothing() throws {
    try withTempFolder { folder in
        let url = folder.appendingPathComponent(SnapshotLog.fileName)
        let entries = try SnapshotLog(url: url).entries()
        #expect(entries.isEmpty)
        // As a newer Saur0n would leave it.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version = \(SnapshotLog.format + 1)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(throws: SnapshotLogError.newerFormat(SnapshotLog.format + 1)) { try SnapshotLog(url: url, readOnly: true) }
    }
}

@Test func printedSnapshotHeadsTheStoredTableWithItsTimeAndLastMinute() throws {
    let zone = try #require(TimeZone(identifier: "UTC"))
    let text = try record().text(by: .command, timeZone: zone)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.first == "Snapshot \(SnapshotTime.text(epoch, timeZone: zone)) (warning: storm.sh × 30)")
    #expect(lines.contains("Last minute (every 10 s, oldest first)"))
    #expect(lines.contains { $0.hasPrefix("  CPU ") && $0.contains("83.3%") })
    #expect(text.contains("storm.sh × 30  "))
    #expect(text.contains("Unattributed CPU"))
}
