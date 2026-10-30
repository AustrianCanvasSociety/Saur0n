// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3

/// One second of the machine as a snapshot's last minute keeps it (Phase 6 Step 7; research 2026-10-22 § Q2: "the
/// minute before it … so the snapshot shows the climb"). `end` is epoch seconds.
public struct MachinePoint: Codable, Equatable, Sendable {
    public let end: Double
    public let cpuPercent: Double
    /// Each core type's average, in the topology's level order.
    public let coreTypePercents: [Double]
    public let userPercent: Double?
    public let systemPercent: Double?
    public let loadOneMinute: Double?
    public let launchesPerSecond: Double?
    public let processes: Int
    /// Processes started in the minute before `end`.
    public let young: Int
    public let diskBytesPerSecond: UInt64?
    public let networkBytesPerSecond: UInt64?

    public init(snapshot: Snapshot, end: Double) {
        let rows = snapshot.processes ?? []
        self.end = end
        cpuPercent = snapshot.load.total
        coreTypePercents = snapshot.topology.cpusByLevel.map(snapshot.average)
        userPercent = snapshot.load.split?.user
        systemPercent = snapshot.load.split?.system
        loadOneMinute = snapshot.loadAverage?.oneMinute
        launchesPerSecond = snapshot.launches?.perSecond
        processes = rows.count
        young = rows.filter { Double($0.startMicroseconds) / 1e6 > end - MachineHistory.seconds }.count
        diskBytesPerSecond = snapshot.disk?.rate.totalBytesPerSecond
        networkBytesPerSecond = snapshot.network?.rate.totalBytesPerSecond
    }
}

/// The last 60 seconds of `MachinePoint`s, kept by the window's refresh loop: one point a second, a handful of numbers.
public struct MachineHistory: Sendable {
    public static let seconds = 60.0
    public private(set) var points: [MachinePoint] = []

    public init() {}

    public mutating func append(_ point: MachinePoint) {
        points.removeAll { $0.end <= point.end - Self.seconds }
        points.append(point)
    }
}

/// What a snapshot is taken from: one refresh's full snapshot (rows, groups, warnings, load average, launches), what
/// the scan read beside the rows (held as the scan has them, so keeping an input each second costs no copy), and the
/// last minute. Built on the refresh loop, turned into a record off it.
public struct SnapshotInput: Sendable {
    public let snapshot: Snapshot
    /// The scan's process list, for each process's group.
    public let identities: [ProcessIdentity]
    /// The user's own processes' arguments and working folders.
    public let arguments: [Int32: ProcessArguments]
    public let folders: [Int32: String]
    public let history: [MachinePoint]
    /// Epoch seconds.
    public let end: Double

    public init(snapshot: Snapshot, identities: [ProcessIdentity], arguments: [Int32: ProcessArguments],
                folders: [Int32: String], history: [MachinePoint], end: Double) {
        self.snapshot = snapshot
        self.identities = identities
        self.arguments = arguments
        self.folders = folders
        self.history = history
        self.end = end
    }

    public init(snapshot: Snapshot, scan: ProcessListSample, history: [MachinePoint], end: Double) {
        self.init(snapshot: snapshot, identities: scan.processes, arguments: scan.arguments,
                  folders: scan.workingDirectories, history: history, end: end)
    }
}

/// One snapshot as the log keeps it: the machine, its last minute, the kept rows with what links them, and the process
/// table as `saur0n` printed it By repo, By session and By command — the aggregates as shown, never re-derived (research
/// § Q2: "A snapshot should not need re-deriving to be read").
public struct SnapshotRecord: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case warning, peak, manual, resource }

    /// Disk read and write, or network in and out, in bytes a second.
    public struct ByteRates: Codable, Equatable, Sendable {
        public let read: UInt64
        public let written: UInt64

        init(_ disk: DiskRate) { (read, written) = (disk.readBytesPerSecond, disk.writeBytesPerSecond) }
        init(_ network: NetworkRate) { (read, written) = (network.inBytesPerSecond, network.outBytesPerSecond) }
    }

    public struct CoreType: Codable, Equatable, Sendable {
        public let name: String
        public let cpus: [Int]
        public let busyPercent: [Double]
        public let averagePercent: Double
    }

    public struct Machine: Codable, Equatable, Sendable {
        public let cpus: Int
        public let coreTypes: [CoreType]
        public let cpuPercent: Double
        public let userPercent: Double?
        public let systemPercent: Double?
        /// 1, 5 and 15 minutes.
        public let loadAverage: [Double]?
        public let launchesPerSecond: Double?
        public let processes: Int
        public let young: Int
        public let disk: ByteRates?
        public let network: ByteRates?
        public let unattributedCpuPercent: Double?
        public let unattributedDisk: ByteRates?
        /// The warnings in force, as the CLI prints them.
        public let warnings: [String]
    }

    public struct Row: Codable, Equatable, Sendable {
        public let pid: Int32
        public let parent: Int32
        public let processGroup: Int32?
        /// Epoch seconds.
        public let startedAt: Double
        public let user: String
        public let name: String
        public let readableName: String?
        public let path: String?
        /// The user's own processes only.
        public let arguments: [String]?
        public let folder: String?
        public let cpuPercent: Double
        public let exitedCpuPercent: Double?
        public let residentBytes: UInt64
        public let disk: ByteRates?
        public let network: ByteRates?
        /// The repo, session and command group the row sits in.
        public let repo: String?
        public let session: String?
        public let command: String?
    }

    /// Full rows for the first `topGroups` groups of each grouping; a catch-all among them keeps its folded rest's
    /// `catchAllRows` busiest rows.
    public static let topGroups = 10, catchAllRows = 10

    /// Epoch seconds.
    public let takenAt: Double
    public let reason: Reason
    /// What took it: the warned subjects (`run.sh × 30`), the spike (`CPU node 48.0%`), empty for Snapshot now.
    public let detail: String
    public let machine: Machine
    public let history: [MachinePoint]
    public let rows: [Row]
    /// `Snapshot.table()` as printed, keyed by `ProcessTable.Grouping`'s raw value, the kept rows only.
    public let tables: [String: String]

    public init(_ input: SnapshotInput, reason: Reason, detail: String) {
        let snapshot = input.snapshot
        let all = snapshot.processes ?? []
        let kept = Self.kept(snapshot)
        let load = snapshot.load
        takenAt = input.end
        self.reason = reason
        self.detail = detail
        let point = MachinePoint(snapshot: snapshot, end: input.end)
        machine = Machine(
            cpus: load.perCPU.count,
            coreTypes: zip(snapshot.topology.levels, snapshot.topology.cpusByLevel).map { level, cpus in
                CoreType(name: level.name, cpus: cpus, busyPercent: cpus.map { load.perCPU[$0] },
                         averagePercent: snapshot.average(cpus))
            },
            cpuPercent: load.total, userPercent: load.split?.user, systemPercent: load.split?.system,
            loadAverage: snapshot.loadAverage.map { [$0.oneMinute, $0.fiveMinutes, $0.fifteenMinutes] },
            launchesPerSecond: snapshot.launches?.perSecond, processes: all.count, young: point.young,
            disk: snapshot.disk.map { ByteRates($0.rate) }, network: snapshot.network.map { ByteRates($0.rate) },
            unattributedCpuPercent: snapshot.unattributedCpuPercent, unattributedDisk: snapshot.unattributedDisk.map(ByteRates.init),
            warnings: (snapshot.warnings ?? []).map(\.text))
        history = input.history
        func names(_ groups: [(name: String, pids: [Int32])]) -> [Int32: String] {
            Dictionary(groups.flatMap { group in group.pids.map { ($0, group.name) } }, uniquingKeysWith: { a, _ in a })
        }
        let repos = names((snapshot.repoGroups ?? []).map { ($0.name, $0.pids) })
        let sessions = names((snapshot.sessionGroups ?? []).map { ($0.name, $0.pids) })
        let commands = names((snapshot.commandGroups ?? []).map { ($0.name, $0.pids) })
        let processGroups = Dictionary(input.identities.compactMap { p in p.processGroup.map { (p.pid, $0) } },
                                       uniquingKeysWith: { a, _ in a })
        rows = all.filter { kept.contains($0.pid) }.map { row in
            Row(pid: row.pid, parent: row.ppid, processGroup: processGroups[row.pid],
                startedAt: Double(row.startMicroseconds) / 1e6, user: row.user, name: row.name,
                readableName: row.readableName, path: row.path,
                arguments: input.arguments[row.pid]?.argv.map(Self.clipped),
                folder: input.folders[row.pid], cpuPercent: row.cpuPercent, exitedCpuPercent: row.exitedChildrenCpuPercent,
                residentBytes: row.residentBytes, disk: row.disk.map { ByteRates($0.rate) },
                network: row.network.map { ByteRates($0.rate) },
                repo: repos[row.pid], session: sessions[row.pid], command: commands[row.pid])
        }
        tables = Dictionary(uniqueKeysWithValues: ProcessTable.Grouping.allCases.map {
            ($0.rawValue, snapshot.table(by: $0, members: kept))
        })
    }

    /// An argument as kept: whole up to `PATH_MAX` (1,024, `sys/syslimits.h`), so a script's path always survives;
    /// longer ones — a script passed inline, `perl -e '…'` of 33 KB on this Mac (2026-10-24) — cut, ending in "…".
    static func clipped(_ argument: String) -> String {
        argument.count <= Int(PATH_MAX) ? argument : argument.prefix(Int(PATH_MAX) - 1) + "…"
    }

    /// The rows a snapshot keeps whole: every warned subject's processes, and the first `topGroups` groups of each
    /// grouping, a catch-all among them less its folded rest beyond the `catchAllRows` busiest.
    public static func kept(_ snapshot: Snapshot) -> Set<Int32> {
        let cpu = Dictionary((snapshot.processes ?? []).map { ($0.pid, $0.totalCpuPercent) }, uniquingKeysWith: { a, _ in a })
        var kept = Set((snapshot.warnings ?? []).flatMap(\.pids))
        func keep(_ pids: [Int32], _ subgroups: [CatchAllBreakout.Subgroup]) {
            let folded = Set(subgroups.filter { $0.kind == .other }.flatMap(\.pids))
            kept.formUnion(pids.filter { !folded.contains($0) })
            let busiest = folded.sorted { (cpu[$0] ?? 0) != (cpu[$1] ?? 0) ? (cpu[$0] ?? 0) > (cpu[$1] ?? 0) : $0 < $1 }
            kept.formUnion(busiest.prefix(catchAllRows))
        }
        for group in (snapshot.repoGroups ?? []).prefix(topGroups) { keep(group.pids, group.subgroups) }
        for group in (snapshot.sessionGroups ?? []).prefix(topGroups) { keep(group.pids, group.subgroups) }
        for group in (snapshot.commandGroups ?? []).prefix(topGroups) { keep(group.pids, []) }
        return kept
    }

    /// What `saur0n snapshot <time>` prints: when and why, the last minute every 10 s, then the stored table for
    /// `grouping`, each line cut to `columns` when given.
    public func text(by grouping: ProcessTable.Grouping = .repo, columns: Int? = nil, timeZone: TimeZone = .current) -> String {
        let why = detail.isEmpty ? reason.rawValue : "\(reason.rawValue): \(detail)"
        var lines = ["Snapshot \(SnapshotTime.text(takenAt, timeZone: timeZone)) (\(why))"]
        // Every 10th point back from the last, oldest first: 0, −10 … −50 s.
        let points = stride(from: history.count - 1, through: 0, by: -10).reversed().map { history[$0] }
        if !points.isEmpty {
            lines.append("Last minute (every 10 s, oldest first)")
            func line(_ label: String, _ value: (MachinePoint) -> String?) {
                let values = points.map { TextFormat.leftPad(value($0) ?? "-", 8) }
                lines.append("  " + label.padding(toLength: 14, withPad: " ", startingAt: 0) + values.joined())
            }
            line("CPU") { TextFormat.percentText($0.cpuPercent) }
            for (i, coreType) in machine.coreTypes.enumerated() {
                line(coreType.name) { $0.coreTypePercents.indices.contains(i) ? TextFormat.percentText($0.coreTypePercents[i]) : nil }
            }
            line("User") { $0.userPercent.map(TextFormat.percentText) }
            line("System") { $0.systemPercent.map(TextFormat.percentText) }
            line("Load (1 min)") { $0.loadOneMinute.map(TextFormat.loadText) }
            line("Launched/s") { $0.launchesPerSecond.map { String(format: "%.0f", $0) } }
            line("Processes") { String($0.processes) }
            line("Under 1 min") { String($0.young) }
        }
        lines += ["", tables[grouping.rawValue] ?? ""]
        let text = lines.joined(separator: "\n")
        guard let columns else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { TextFormat.fitted(String($0), columns: columns) }.joined(separator: "\n")
    }
}

/// What takes a snapshot this second, if anything.
public struct SnapshotTrigger: Equatable, Sendable {
    public let reason: SnapshotRecord.Reason
    public let detail: String

    public init(reason: SnapshotRecord.Reason, detail: String) {
        self.reason = reason
        self.detail = detail
    }

    /// A fixed resource level's transition (Phase 7 Step 2), recorded through the same log as a warning's. It is only a
    /// trigger: the watcher's existing snapshot spacing still decides when a snapshot is taken.
    public static func resource(_ transition: LevelTransition) -> SnapshotTrigger {
        SnapshotTrigger(reason: .resource,
                        detail: "\(transition.to.rawValue) by \(transition.cause.rawValue) "
                            + TextFormat.percentText(transition.percent))
    }
}

/// When the refresh loop takes a snapshot (calibration 2026-10-24): on a new spike mark (Step 6's rule) at most once a
/// minute — each snapshot carries the whole last minute —; when a warning subject enters the warnings in force, and
/// again for it only `warningRepeat` seconds on; one snapshot a second at most, a warning's taking the second.
public struct SnapshotTriggers: Sendable {
    public var peakSpacing = 60.0, warningRepeat = 300.0
    var lastPeak: Double?
    var lastWarned: [Warning.Subject: Double] = [:]

    public init() {}

    /// `end` is the loop's monotonic seconds; `warnings` the ones in force, ignored ones left out; `peaks` the text of
    /// the spike marks this second added.
    public mutating func next(end: Double, warnings: [Warning], peaks: [String]) -> SnapshotTrigger? {
        lastWarned = lastWarned.filter { end - $0.value < warningRepeat }
        let due = warnings.filter { lastWarned[$0.subject] == nil }
        let peakDue = !peaks.isEmpty && (lastPeak.map { end - $0 >= peakSpacing } ?? true)
        for warning in due { lastWarned[warning.subject] = end }
        if !due.isEmpty {
            if !peaks.isEmpty { lastPeak = end }
            return SnapshotTrigger(reason: .warning, detail: due.map(\.name).joined(separator: "; "))
        }
        guard peakDue else { return nil }
        lastPeak = end
        return SnapshotTrigger(reason: .peak, detail: peaks.joined(separator: "; "))
    }
}

/// `saur0n snapshot <time>`'s time: local clock time, `HH:MM` or `HH:MM:SS` today, or `YYYY-MM-DD HH:MM[:SS]` (or with
/// `T`), as `sar -s` takes clock time. A time without seconds covers its whole minute, one with them its second.
public enum SnapshotTime {
    /// The last instant `text` covers, in epoch seconds; nil when it is not one of the forms above or names no real time.
    public static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Double? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0 == "T" })
        guard (1...2).contains(parts.count), let clock = parts.last else { return nil }
        var wanted = calendar.dateComponents([.year, .month, .day], from: now)
        if parts.count == 2 {
            let date = parts[0].split(separator: "-", omittingEmptySubsequences: false)
            guard date.count == 3, let year = number(date[0], 4...4), let month = number(date[1], 2...2),
                  let day = number(date[2], 2...2) else { return nil }
            wanted = DateComponents(year: year, month: month, day: day)
        }
        let time = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(time.count), let hour = number(time[0], 1...2), let minute = number(time[1], 2...2),
              hour < 24, minute < 60 else { return nil }
        let second = time.count == 3 ? number(time[2], 2...2) : 59
        guard let second, second < 60 else { return nil }
        wanted.hour = hour
        wanted.minute = minute
        wanted.second = second
        // A date the calendar rolls over (February 30th) names no real time.
        guard let date = calendar.date(from: wanted),
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                == DateComponents(year: wanted.year, month: wanted.month, day: wanted.day, hour: hour, minute: minute,
                                  second: second) else { return nil }
        return date.timeIntervalSince1970 + 0.999
    }

    /// `2026-10-24 14:03:07` in `timeZone`.
    public static func text(_ epoch: Double, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    static func number(_ text: Substring, _ digits: ClosedRange<Int>) -> Int? {
        guard digits.contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }
}

public enum SnapshotLogError: Error, Equatable, CustomStringConvertible {
    case sqlite(String)
    /// The file was written by a newer Saur0n: refused, never misread.
    case newerFormat(Int32)
    case unreadableBody(Int64)

    public var description: String {
        switch self {
        case .sqlite(let message): message
        case .newerFormat(let version): "the log is format \(version), newer than this saur0n reads (\(SnapshotLog.format))"
        case .unreadableBody(let id): "snapshot \(id) cannot be read"
        }
    }
}

/// The snapshot log: one SQLite row per snapshot — summary columns and one zlib-compressed JSON body — under a size cap,
/// oldest dropped first (calibration 2026-10-24; the user: "One row per snapshot: summary columns plus one compressed
/// JSON body"). The system's SQLite through `import SQLite3`, no package. Written by the window only, off its refresh
/// loop; read by `saur0n snapshots` and `saur0n snapshot <time>`.
public final class SnapshotLog {
    /// A snapshot's summary columns: what `saur0n snapshots` lists without unpacking a body.
    public struct Entry: Codable, Equatable, Sendable {
        public let id: Int64
        public let takenAt: Double
        public let reason: SnapshotRecord.Reason
        public let detail: String
        public let cpuPercent: Double
        public let unattributedPercent: Double?
        public let processes: Int
        /// The compressed body's size.
        public let bytes: Int

        public init(id: Int64, takenAt: Double, reason: SnapshotRecord.Reason, detail: String, cpuPercent: Double,
                    unattributedPercent: Double?, processes: Int, bytes: Int) {
            self.id = id
            self.takenAt = takenAt
            self.reason = reason
            self.detail = detail
            self.cpuPercent = cpuPercent
            self.unattributedPercent = unattributedPercent
            self.processes = processes
            self.bytes = bytes
        }

        /// `2026-10-24 14:03:07  warning  run.sh × 30  CPU 96.1%  Unattributed 41.2%  1804 processes  38.0 KB`.
        public func text(timeZone: TimeZone = .current) -> String { TextFormat.snapshotEntryText(self, timeZone: timeZone) }
    }

    public static let fileName = "snapshots.sqlite"
    public static let format: Int32 = 1
    /// 200 MB, about 1,500–2,000 snapshots at the 100–140 KB measured (calibration 2026-10-24, raised from 50 MB after
    /// that measurement; the user: "yes").
    public static let defaultCap = 200_000_000
    /// Points the app and the CLI at another folder (the live check's), as `SAUR0N_TEST_LOCK_NAMES` does for the lock.
    public static let directoryVariable = "SAUR0N_SNAPSHOT_DIR"

    /// `~/Library/Application Support/Saur0n/snapshots.sqlite` (Apple's File System Programming Guide places
    /// app-created support data there), or `SAUR0N_SNAPSHOT_DIR`'s folder.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let folder = environment[directoryVariable], !folder.isEmpty {
            return URL(fileURLWithPath: folder).appendingPathComponent(fileName)
        }
        return home.appendingPathComponent("Library/Application Support/Saur0n").appendingPathComponent(fileName)
    }

    /// The latest entry taken at or before `time` (epoch seconds), as git's `<ref>@{<date>}` reads a ref's value then.
    public static func entry(atOrBefore time: Double, in entries: [Entry]) -> Entry? {
        entries.filter { $0.takenAt <= time }.max { ($0.takenAt, $0.id) < ($1.takenAt, $1.id) }
    }

    public let url: URL
    public let cap: Int
    private let db: OpaquePointer
    private var version: Int32 = 0

    /// Opens the log, creating its folder and file unless `readOnly`.
    public init(url: URL, cap: Int = defaultCap, readOnly: Bool = false) throws {
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(url.path)"
            sqlite3_close(handle)
            throw SnapshotLogError.sqlite(message)
        }
        db = handle
        self.url = url
        self.cap = cap
        // The window may be writing while the CLI reads.
        sqlite3_busy_timeout(db, 2_000)
        version = Int32(try query("PRAGMA user_version") { sqlite3_column_int($0, 0) }.first ?? 0)
        guard version <= Self.format else { throw SnapshotLogError.newerFormat(version) }
        if version == 0 && !readOnly {
            // auto_vacuum before any table, so the file shrinks as rows are dropped.
            try execute("""
                PRAGMA auto_vacuum = FULL;
                BEGIN;
                CREATE TABLE snapshots (
                    id INTEGER PRIMARY KEY,
                    taken_at REAL NOT NULL,
                    reason TEXT NOT NULL,
                    detail TEXT NOT NULL,
                    cpu_percent REAL NOT NULL,
                    unattributed_percent REAL,
                    processes INTEGER NOT NULL,
                    bytes INTEGER NOT NULL,
                    body BLOB NOT NULL
                );
                CREATE INDEX snapshots_taken_at ON snapshots(taken_at);
                PRAGMA user_version = \(Self.format);
                COMMIT;
                """)
            version = Self.format
        }
    }

    deinit { sqlite3_close(db) }

    /// Writes `record`, then drops the oldest snapshots until the bodies fit under the cap; the newest is always kept.
    @discardableResult
    public func write(_ record: SnapshotRecord) throws -> Entry {
        let json = try JSONEncoder().encode(record)
        let body = try (json as NSData).compressed(using: .zlib) as Data
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                INSERT INTO snapshots (taken_at, reason, detail, cpu_percent, unattributed_percent, processes, bytes, body)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, record.takenAt)
            sqlite3_bind_text(statement, 2, record.reason.rawValue, -1, Self.transient)
            sqlite3_bind_text(statement, 3, record.detail, -1, Self.transient)
            sqlite3_bind_double(statement, 4, record.machine.cpuPercent)
            if let unattributed = record.machine.unattributedCpuPercent {
                sqlite3_bind_double(statement, 5, unattributed)
            } else {
                sqlite3_bind_null(statement, 5)
            }
            sqlite3_bind_int64(statement, 6, Int64(record.machine.processes))
            sqlite3_bind_int64(statement, 7, Int64(body.count))
            _ = body.withUnsafeBytes { sqlite3_bind_blob(statement, 8, $0.baseAddress, Int32(body.count), Self.transient) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            let id = sqlite3_last_insert_rowid(db)
            let sizes = try query("SELECT id, bytes FROM snapshots ORDER BY taken_at DESC, id DESC") {
                (sqlite3_column_int64($0, 0), Int(sqlite3_column_int64($0, 1)))
            }
            var total = 0
            var dropped: [Int64] = []
            for (index, (id, bytes)) in sizes.enumerated() {
                total += bytes
                if index > 0 && total > cap { dropped.append(id) }
            }
            if !dropped.isEmpty {
                try execute("DELETE FROM snapshots WHERE id IN (\(dropped.map(String.init).joined(separator: ",")))")
            }
            try execute("COMMIT")
            return Entry(id: id, takenAt: record.takenAt, reason: record.reason, detail: record.detail,
                         cpuPercent: record.machine.cpuPercent, unattributedPercent: record.machine.unattributedCpuPercent,
                         processes: record.machine.processes, bytes: body.count)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Every snapshot's summary, oldest first.
    public func entries() throws -> [Entry] {
        guard version > 0 else { return [] }
        return try query("""
            SELECT id, taken_at, reason, detail, cpu_percent, unattributed_percent, processes, bytes
            FROM snapshots ORDER BY taken_at, id
            """) { statement in
            Entry(id: sqlite3_column_int64(statement, 0), takenAt: sqlite3_column_double(statement, 1),
                  reason: SnapshotRecord.Reason(rawValue: Self.text(statement, 2)) ?? .manual,
                  detail: Self.text(statement, 3), cpuPercent: sqlite3_column_double(statement, 4),
                  unattributedPercent: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 5),
                  processes: Int(sqlite3_column_int64(statement, 6)), bytes: Int(sqlite3_column_int64(statement, 7)))
        }
    }

    /// The snapshot `id` names, unpacked.
    public func record(_ id: Int64) throws -> SnapshotRecord {
        let statement = try prepare("SELECT body FROM snapshots WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
            throw SnapshotLogError.unreadableBody(id)
        }
        let body = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        guard let json = try? (body as NSData).decompressed(using: .zlib) as Data,
              let record = try? JSONDecoder().decode(SnapshotRecord.self, from: json) else {
            throw SnapshotLogError.unreadableBody(id)
        }
        return record
    }

    // SQLite copies the bound text and blob before the call returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private func error() -> SnapshotLogError { .sqlite(String(cString: sqlite3_errmsg(db))) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }

    private func query<T>(_ sql: String, _ row: (OpaquePointer) -> T) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(row(statement))
            case SQLITE_DONE: return rows
            default: throw error()
            }
        }
    }
}
