// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What started a process: a Claude Code session, a tmux session, or a terminal tab.
public enum SessionKind: String, Encodable, Sendable {
    case claude, tmux, terminal
}

/// A process's session as Saur0n shows it: the label, what kind, and an id that tells two of the same label apart
/// (Claude Code's session id, the tmux session's name, the terminal tab's tty, else `login-<pid>`).
public struct SessionInfo: Equatable, Encodable, Sendable {
    public let name: String
    public let kind: SessionKind
    public let id: String

    public init(name: String, kind: SessionKind, id: String) {
        self.name = name
        self.kind = kind
        self.id = id
    }
}

/// One `~/.claude/sessions/<pid>.json` file: the fields Saur0n reads. Undocumented Claude Code state —
/// research/2026-10-18-phase3-open.md § Q3.
public struct RegistryEntry: Equatable, Sendable {
    public let pid: Int32
    public let sessionId: String
    public let name: String?
    public let cwd: String?
    /// The registered process's start time, whole seconds since the epoch.
    public let procStartSeconds: UInt64

    public init(pid: Int32, sessionId: String, name: String?, cwd: String?, procStartSeconds: UInt64) {
        self.pid = pid
        self.sessionId = sessionId
        self.name = name
        self.cwd = cwd
        self.procStartSeconds = procStartSeconds
    }

    /// nil unless the file is a JSON object with a positive `pid` that fits Int32, a non-empty `sessionId` and a `procStart`
    /// in UTC ctime form (`Mon Oct 19 01:04:41 2026`); a file Saur0n can't read is skipped, never an error.
    public static func parse(_ data: Data) -> RegistryEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int, let id = object["sessionId"] as? String, !id.isEmpty,
              let started = (object["procStart"] as? String).flatMap(startSeconds),
              let pid32 = Int32(exactly: pid), pid32 > 0 else { return nil }
        return RegistryEntry(pid: pid32, sessionId: id, name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                             cwd: object["cwd"] as? String, procStartSeconds: started)
    }

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let weekdays: Set<Substring> = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// The ctime form read by hand (English names, as ctime writes them in any locale) and `timegm`, not a
    /// `DateFormatter` per entry: the window parses the whole registry every second, and building the formatters
    /// was most of `SessionSources.read` (profile 2026-10-19). A date `timegm` had to normalise (Feb 30, hour 24)
    /// is rejected, as the formatter rejected it.
    static func startSeconds(_ text: String) -> UInt64? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 5, weekdays.contains(parts[0]), let month = months.firstIndex(of: String(parts[1])),
              let day = Int32(parts[2]), let year = Int(parts[4]), year >= 1970,
              let tmYear = Int32(exactly: year - 1900) else { return nil }
        let clock = parts[3].split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 3, clock.allSatisfy({ $0.count == 2 }),
              let hour = Int32(clock[0]), let minute = Int32(clock[1]), let second = Int32(clock[2]) else { return nil }
        var parsed = tm()
        (parsed.tm_year, parsed.tm_mon, parsed.tm_mday) = (tmYear, Int32(month), day)
        (parsed.tm_hour, parsed.tm_min, parsed.tm_sec) = (hour, minute, second)
        var normalised = parsed
        let seconds = timegm(&normalised)
        guard seconds >= 0, (normalised.tm_year, normalised.tm_mon, normalised.tm_mday, normalised.tm_hour,
                             normalised.tm_min, normalised.tm_sec)
                == (parsed.tm_year, parsed.tm_mon, parsed.tm_mday, parsed.tm_hour, parsed.tm_min, parsed.tm_sec)
        else { return nil }
        return UInt64(seconds)
    }
}

/// Everything the session resolver reads, gathered by the thin readers (`SystemReaders`).
public struct SessionSources: Sendable {
    public let registry: [RegistryEntry]
    /// Each pid's start time, whole seconds since the epoch.
    public let startSeconds: [Int32: UInt64]
    /// The user's own processes' `CLAUDE_CODE_SESSION_ID`.
    public let environmentSessionIDs: [Int32: String]
    /// tmux pane pid → tmux session name.
    public let tmuxPanes: [Int32: String]
    /// Terminal-tab `login` pid → its tty (`SessionGroups.terminalLogins`).
    public let tty: [Int32: String]
    public let ownUID: UInt32

    public init(registry: [RegistryEntry], startSeconds: [Int32: UInt64], environmentSessionIDs: [Int32: String],
                tmuxPanes: [Int32: String], tty: [Int32: String], ownUID: UInt32) {
        self.registry = registry
        self.startSeconds = startSeconds
        self.environmentSessionIDs = environmentSessionIDs
        self.tmuxPanes = tmuxPanes
        self.tty = tty
        self.ownUID = ownUID
    }

    /// The sources for `rows` (repo grouping is not needed) from the closing scan `sample` and what the readers gave:
    /// start times and `CLAUDE_CODE_SESSION_ID`s from the scan, and the tty of each terminal tab's `login`
    /// (`SessionGroups.terminalLogins`) through `ttyName`. Shared by the CLI and the window.
    public static func assemble(rows: [ProcessUsage], sample: ProcessListSample, registry: [Data],
                                tmuxPanes: [Int32: String], ttyName: (Int32) -> String?, ownUID: UInt32) -> SessionSources {
        SessionSources(
            registry: registry.compactMap(RegistryEntry.parse),
            startSeconds: Dictionary(sample.processes.map { ($0.pid, $0.startMicroseconds / 1_000_000) },
                                     uniquingKeysWith: { a, _ in a }),
            environmentSessionIDs: sample.arguments.compactMapValues { $0.environment["CLAUDE_CODE_SESSION_ID"] },
            tmuxPanes: tmuxPanes,
            tty: Dictionary(SessionGroups.terminalLogins(rows).compactMap { pid in ttyName(pid).map { (pid, $0) } },
                            uniquingKeysWith: { a, _ in a }),
            ownUID: ownUID)
    }

    /// `assemble` with this Mac's registry, tmux panes and ttys. Never fails: a missing registry or tmux just
    /// leaves those sessions out.
    public static func read(rows: [ProcessUsage], sample: ProcessListSample) -> SessionSources {
        assemble(rows: rows, sample: sample, registry: SystemReaders.sessionRegistry(),
                 tmuxPanes: SystemReaders.tmuxPanes(), ttyName: SystemReaders.ttyName(pid:), ownUID: getuid())
    }
}

/// One group of the session view: a session, the VMs, or one of the two catch-alls.
public struct SessionGroup: Equatable, Sendable {
    public let name: String
    /// nil for the VMs group and the catch-alls.
    public let kind: SessionKind?
    public let id: String?
    /// Sum of its rows' own CPU.
    public let cpuPercent: Double
    /// Sum of its rows' exited-children CPU (unread rows add 0).
    public let exitedChildrenCpuPercent: Double
    public let residentBytes: UInt64
    /// As `RepoGroup.disk`.
    public var disk: DiskUsage = .zero
    /// As `RepoGroup.network`.
    public var network: NetworkUsage = .zero
    /// In tree order (`SessionGroups.assign`); a catch-all's lifted entries first (`CatchAllBreakout.apply`).
    public internal(set) var pids: [Int32]
    /// As `RepoGroup.subgroups`.
    public internal(set) var subgroups: [CatchAllBreakout.Subgroup] = []

    /// What the group header shows and groups are ordered by, as `RepoGroup.totalCpuPercent`.
    public var totalCpuPercent: Double { cpuPercent + exitedChildrenCpuPercent }
}

extension SessionGroup: Encodable {
    enum CodingKeys: String, CodingKey {
        case name, cpuPercent, exitedChildrenCpuPercent, residentBytes, disk, network, pids, subgroups
    }

    /// The `repoGroups` shape: CPU figures to two decimals.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(TextFormat.rounded(cpuPercent, places: 2), forKey: .cpuPercent)
        try container.encode(TextFormat.rounded(exitedChildrenCpuPercent, places: 2), forKey: .exitedChildrenCpuPercent)
        try container.encode(residentBytes, forKey: .residentBytes)
        try container.encode(disk, forKey: .disk)
        try container.encode(network, forKey: .network)
        try container.encode(pids, forKey: .pids)
        try container.encode(subgroups, forKey: .subgroups)
    }
}

public enum SessionGroups {
    public static let vms = RepoGroups.vms
    public static let noSession = "No session"
    public static let systemAndOtherUsers = RepoGroups.systemAndOtherUsers

    /// Each row's session and the groups they form (research § Q3). For each row, the nearest
    /// ancestor-or-self that is (a) a live registered Claude Code process, else (b) carries a live session's
    /// `CLAUDE_CODE_SESSION_ID`, else (c) a tmux pane, else (d) a terminal tab's `login`. A registry entry
    /// is live only when its pid's start time matches `procStart` — a reused pid is not that session, and
    /// ids the registry lacks (the tmux server's inherited one) are ignored. The ancestry walk crosses
    /// other users' processes, so one with no readable environment takes its parent's session.
    /// When none of those names one, a row under an orphan (`ProcessUsage.orphaned`, itself included) takes the session
    /// its group's stand-ins get by them (`Orphans.StandIns`; Phase 6 Step 8) — never through a second group.
    /// Groups go by shown total CPU (own plus exited children), then the VMs with no session, the user's own
    /// unsessioned rows, other users' last; each group's `pids` in tree order, the rows in the order given.
    public static func assign(_ rows: [ProcessUsage], sources: SessionSources) -> (rows: [ProcessUsage], groups: [SessionGroup]) {
        assign(rows, sources: sources, remembered: [:])
    }

    static func assign(_ rows: [ProcessUsage], sources: SessionSources, remembered: [Int32: Orphans.Ownership])
        -> (rows: [ProcessUsage], groups: [SessionGroup]) {
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let live = Dictionary(sources.registry.filter { sources.startSeconds[$0.pid] == $0.procStartSeconds }
                                  .map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let liveByID = Dictionary(live.values.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, b in a.pid < b.pid ? a : b })
        let logins = Set(terminalLogins(rows))
        let standIns = Orphans.StandIns(rows)

        /// The nearest ancestor-or-self of `pid` that `match` names a value for; a ppid loop ends the walk.
        func nearest<T>(_ pid: Int32, _ match: (ProcessUsage) -> T?) -> T? {
            var seen: Set<Int32> = []
            var current = byPid[pid]
            while let row = current, seen.insert(row.pid).inserted {
                if let found = match(row) { return found }
                current = row.ppid == row.pid ? nil : byPid[row.ppid]
            }
            return nil
        }
        var byAncestry: [Int32: SessionInfo?] = [:]
        func ancestrySession(_ pid: Int32) -> SessionInfo? {
            if let known = byAncestry[pid] { return known }
            let found = nearest(pid) { live[$0.pid].map(claude) }
                ?? nearest(pid) { sources.environmentSessionIDs[$0.pid].flatMap { liveByID[$0] }.map(claude) }
                ?? nearest(pid) { row in sources.tmuxPanes[row.pid].map { SessionInfo(name: $0, kind: .tmux, id: $0) } }
                ?? nearest(pid) { row in
                    guard logins.contains(row.pid) else { return nil }
                    let app = byPid[row.ppid]?.name ?? "terminal"
                    if let tty = sources.tty[row.pid] { return SessionInfo(name: "\(app) \(tty)", kind: .terminal, id: tty) }
                    return SessionInfo(name: "\(app) login \(row.pid)", kind: .terminal, id: "login-\(row.pid)")
                }
            byAncestry[pid] = found
            return found
        }
        func session(_ pid: Int32) -> SessionInfo? {
            ancestrySession(pid) ?? nearest(pid) { $0.orphaned ? $0 : nil }.flatMap { orphan in
                standIns.of(orphan).lazy.compactMap { ancestrySession($0.pid) }.first
                    ?? orphan.processGroup.flatMap { remembered[$0]?.session }
            }
        }

        var assigned: [ProcessUsage] = []
        var members: [String: (info: SessionInfo?, name: String, rows: [ProcessUsage])] = [:]
        var order: [String] = []
        for var row in rows {
            row.session = session(row.pid)
            let key: String, name: String
            if let info = row.session {
                (key, name) = ("\(info.kind.rawValue):\(info.id)", info.name)
            } else if row.vm != nil {
                (key, name) = ("vms", vms)
            } else {
                name = row.uid == sources.ownUID ? noSession : systemAndOtherUsers
                key = "catch-all:" + name
            }
            if members[key] == nil { order.append(key) }
            members[key, default: (row.session, name, [])].rows.append(row)
            assigned.append(row)
        }
        let groups = order.compactMap { members[$0] }.map { member in
            let totals = GroupTotals(member.rows)
            return SessionGroup(name: member.name, kind: member.info?.kind, id: member.info?.id,
                                cpuPercent: totals.cpuPercent, exitedChildrenCpuPercent: totals.exitedChildrenCpuPercent,
                                residentBytes: totals.residentBytes, disk: totals.disk, network: totals.network,
                                pids: treeOrder(member.rows).map(\.row.pid))
        }
        return (assigned, groups.sorted(by: shownBefore))
    }

    static func claude(_ entry: RegistryEntry) -> SessionInfo {
        let short = String(entry.sessionId.prefix(8))
        let label = entry.name
            ?? entry.cwd.flatMap(ProcessSample.basename).map { "\($0) \(short)" }
            ?? short
        return SessionInfo(name: label, kind: .claude, id: entry.sessionId)
    }

    /// Root `login` processes a terminal app started (not launchd): one per terminal tab.
    public static func terminalLogins(_ rows: [ProcessUsage]) -> [Int32] {
        rows.filter { $0.uid == 0 && $0.ppid > 1 && ($0.path == "/usr/bin/login" || ($0.path == nil && $0.name == "login")) }
            .map(\.pid)
    }

    /// `tmux list-panes -a -F '#{pane_pid} #{session_name}'` → pane pid → session name; malformed lines skipped.
    public static func parseTmuxPanes(_ output: String) -> [Int32: String] {
        var panes: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            guard let space = line.firstIndex(of: " "), let pid = Int32(line[..<space]), pid > 0 else { continue }
            let name = String(line[line.index(after: space)...])
            if !name.isEmpty { panes[pid] = name }
        }
        return panes
    }

    /// Rows whose parent is in the group are placed under it, depth-first; the rest are roots. Roots and
    /// siblings go by own + exited CPU, then pid. A ppid loop inside the group (a pid reused mid-read) is broken at
    /// its lowest pid so every row is placed once.
    static func treeOrder(_ rows: [ProcessUsage]) -> [(row: ProcessUsage, depth: Int)] {
        let pids = Set(rows.map(\.pid))
        let byCPU: (ProcessUsage, ProcessUsage) -> Bool = { ($0.totalCpuPercent, $1.pid) > ($1.totalCpuPercent, $0.pid) }
        let children = Dictionary(grouping: rows.filter { $0.ppid != $0.pid && pids.contains($0.ppid) }, by: \.ppid)
            .mapValues { $0.sorted(by: byCPU) }
        var placed: Set<Int32> = []
        var out: [(row: ProcessUsage, depth: Int)] = []
        func visit(_ row: ProcessUsage, _ depth: Int) {
            guard placed.insert(row.pid).inserted else { return }
            out.append((row, depth))
            for child in children[row.pid] ?? [] { visit(child, depth + 1) }
        }
        for root in rows.filter({ $0.ppid == $0.pid || !pids.contains($0.ppid) }).sorted(by: byCPU) { visit(root, 0) }
        for row in rows.sorted(by: { $0.pid < $1.pid }) where !placed.contains(row.pid) { visit(row, 0) }
        return out
    }

    /// Sessions by header total (own plus exited-children CPU, one decimal, as shown), then name and id;
    /// then "VMs", "No session", "System and other users".
    static func shownBefore(_ a: SessionGroup, _ b: SessionGroup) -> Bool {
        func rank(_ g: SessionGroup) -> Int { g.kind != nil ? 0 : g.name == vms ? 1 : g.name == noSession ? 2 : 3 }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        let (x, y) = (TextFormat.rounded(a.totalCpuPercent), TextFormat.rounded(b.totalCpuPercent))
        if x != y { return x > y }
        return (a.name, a.id ?? "") < (b.name, b.id ?? "")
    }
}

/// The window remembers one ownership tie per own-user process group with a known repo or session, before a
/// launching shell exits. An empty group is forgotten on that scan; the CLI keeps its same-scan-only rule.
public struct KeptOrphanGroups {
    private(set) var remembered: [Int32: Orphans.Ownership] = [:]

    public init() {}

    /// Group this scan using live ties first, remembered ties only for orphans without a live tied stand-in.
    /// Keep the latest non-nil repo and session independently, preferring a leader over the other members.
    public mutating func assign(_ rows: [ProcessUsage], workingDirectories: [Int32: String],
                                repoOfDirectory: (String) -> RepoInfo?, repoOfExecutable: (String) -> RepoInfo?,
                                sources: SessionSources)
        -> (rows: [ProcessUsage], repoGroups: [RepoGroup], sessionGroups: [SessionGroup]) {
        let liveGroups = Set(rows.compactMap(\.processGroup))
        remembered = remembered.filter { liveGroups.contains($0.key) }
        let repos = RepoGroups.assign(rows, workingDirectories: workingDirectories,
                                      repoOfDirectory: repoOfDirectory, repoOfExecutable: repoOfExecutable,
                                      remembered: remembered)
        let sessions = SessionGroups.assign(repos.rows, sources: sources, remembered: remembered)
        let ownGroups = Orphans.StandIns(sessions.rows.filter { $0.uid == sources.ownUID })
        for (group, members) in ownGroups.members {
            let leader = members.first { $0.pid == group }
            let repo = leader?.repo ?? members.lazy.compactMap(\.repo).first ?? remembered[group]?.repo
            let session = leader?.session ?? members.lazy.compactMap(\.session).first ?? remembered[group]?.session
            if repo != nil || session != nil { remembered[group] = (repo, session) }
        }
        return (sessions.rows, repos.groups, sessions.groups)
    }
}

/// Orphans tied back through their process group (Phase 6 Step 8). `nohup … &` leaves its process under launchd once
/// the launching shell exits, but the process keeps that shell's group (research 2026-10-22 finding 4). The
/// environment tie cannot catch most of them: Apple's own programs (`/bin/bash`, `/bin/sleep`) read back with no
/// environment at all (probe 2026-10-24).
enum Orphans {
    typealias Ownership = (repo: RepoInfo?, session: SessionInfo?)
    /// An own-user process under launchd that does not lead its own process group. launchd starts each job as its
    /// group's leader, so its agents, apps and services never match; root's and other users' processes never do (probe
    /// 2026-10-24: all 180 under launchd lead their group).
    static func isOrphan(uid: UInt32, ppid: Int32, pid: Int32, processGroup: Int32?, ownUID: UInt32) -> Bool {
        guard let processGroup else { return false }
        return uid == ownUID && ppid == 1 && processGroup != pid
    }

    /// The rows that speak for an orphan's group: its leader when the scan lists it, else the group's other members,
    /// earliest started first, then by pid. A process group id is not reused while the group lives (POSIX.1-2017
    /// XBD § 4.14), so a member in the same scan is in the same group.
    struct StandIns {
        let members: [Int32: [ProcessUsage]]

        init(_ rows: [ProcessUsage]) {
            members = Dictionary(grouping: rows.filter { $0.processGroup != nil }, by: { $0.processGroup ?? 0 })
                .mapValues { $0.sorted { ($0.startMicroseconds, $0.pid) < ($1.startMicroseconds, $1.pid) } }
        }

        func of(_ orphan: ProcessUsage) -> [ProcessUsage] {
            guard let group = orphan.processGroup, let rows = members[group] else { return [] }
            if let leader = rows.first(where: { $0.pid == group }) { return [leader] }
            return rows.filter { $0.pid != orphan.pid }
        }
    }
}

/// What is new under launchd (Phase 6 Step 8): every process under launchd, any user's, started in the minute before
/// the scan, and the most common name among them when one repeats. Only the processes alive at the scan count, so a
/// copy that lived a few milliseconds between scans is missed: a floor, never an overcount.
public struct LaunchdNewcomers: Equatable, Encodable, Sendable {
    public struct Name: Equatable, Encodable, Sendable {
        public let name: String
        public let count: Int

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    public let count: Int
    public let mostCommon: Name?

    public init(count: Int, mostCommon: Name?) {
        self.count = count
        self.mostCommon = mostCommon
    }

    /// `end` is the scan's time in epoch seconds; a process counts when it started after `end` − 60, as a snapshot's
    /// "Under 1 min" (`MachinePoint.young`). Names tied at the top go by name.
    public static func of(_ rows: [ProcessUsage], end: Double) -> LaunchdNewcomers {
        let new = rows.filter { $0.ppid == 1 && Double($0.startMicroseconds) / 1e6 > end - MachineHistory.seconds }
        let counts = Dictionary(new.map { ($0.name, 1) }, uniquingKeysWith: +)
        let top = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }
        return LaunchdNewcomers(count: new.count,
                                mostCommon: top.flatMap { $0.value > 1 ? Name(name: $0.key, count: $0.value) : nil })
    }

    enum CodingKeys: String, CodingKey { case count, mostCommon }

    /// `mostCommon` is null, never omitted, when no name repeats.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        try container.encode(mostCommon, forKey: .mostCommon)
    }
}
