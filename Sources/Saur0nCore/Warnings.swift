// SPDX-License-Identifier: GPL-3.0-or-later
import CoreFoundation
import Foundation

/// One closed sampling window as the warnings read it: when it ended and how long it was (seconds on one monotonic
/// clock), and the figures the table shows for it. A figure not read (nil) leaves its condition as it was.
public struct WarningTick: Sendable {
    public let end: Double
    public let seconds: Double
    public let cpus: Int
    public let unattributedCpuPercent: Double?
    public let loadAverage: LoadAverage?
    public let split: CPUSplit?
    /// After `CommandGroups.assign`, so each row carries its command key.
    public let rows: [ProcessUsage]
    public let commandGroups: [CommandGroup]
    public let repoGroups: [RepoGroup]
    public let sessionGroups: [SessionGroup]
    /// Whole-machine CPU, 0–100 (100 = every core busy), when read: the fixed levels judge their CPU bars on it.
    public let cpuPercent: Double?
    /// The machine's memory counters (`AvailableMemory`) when read: the memory floor and the memory bars.
    public let memory: AvailableMemory?

    public init(end: Double, seconds: Double, cpus: Int, unattributedCpuPercent: Double?, loadAverage: LoadAverage?,
                split: CPUSplit?, rows: [ProcessUsage], commandGroups: [CommandGroup], repoGroups: [RepoGroup],
                sessionGroups: [SessionGroup], cpuPercent: Double? = nil, memory: AvailableMemory? = nil) {
        self.end = end
        self.seconds = seconds
        self.cpus = cpus
        self.unattributedCpuPercent = unattributedCpuPercent
        self.loadAverage = loadAverage
        self.split = split
        self.rows = rows
        self.commandGroups = commandGroups
        self.repoGroups = repoGroups
        self.sessionGroups = sessionGroups
        self.cpuPercent = cpuPercent
        self.memory = memory
    }

    /// A snapshot's window, ending at `end`.
    public init(snapshot: Snapshot, end: Double) {
        self.init(end: end, seconds: snapshot.intervalSeconds, cpus: snapshot.load.perCPU.count,
                  unattributedCpuPercent: snapshot.unattributedCpuPercent, loadAverage: snapshot.loadAverage,
                  split: snapshot.load.split, rows: snapshot.processes ?? [], commandGroups: snapshot.commandGroups ?? [],
                  repoGroups: snapshot.repoGroups ?? [], sessionGroups: snapshot.sessionGroups ?? [],
                  cpuPercent: snapshot.load.total, memory: snapshot.memory)
    }
}

/// One runaway's warning line: the command or group it names and every condition that subject tripped, the
/// machine-wide ones joined to it (plan § Decisions: "one warning line per runaway").
public struct Warning: Equatable, Sendable {
    public enum Subject: Hashable, Sendable {
        case command(String), session(String), repo(String)
        /// Machine-wide conditions with no subject to join.
        case machine
    }

    public enum Kind: Sendable { case unattributed, copies, load, systemShare, group }

    public enum Condition: Equatable, Sendable {
        case unattributed(percent: Double)
        /// Copies now, how many more than the fewest in the last 5 minutes, and their CPU with what they started.
        case copies(count: Int, growth: Int, percent: Double)
        case load(oneMinute: Double, cpus: Int, rising: Bool)
        case systemShare(percent: Double)
        /// The group's own + exited CPU and how long it has been above the bar.
        case group(percent: Double, seconds: Double)

        public var kind: Kind {
            switch self {
            case .unattributed: .unattributed
            case .copies: .copies
            case .load: .load
            case .systemShare: .systemShare
            case .group: .group
            }
        }
    }

    public let subject: Subject
    /// As the line shows it: `run.sh × 75`, `build (session)`, `example (repo)`, `Machine`.
    public let name: String
    /// The earliest onset among its conditions.
    public internal(set) var since: Double
    /// The subject's own + exited CPU, with the commands joined to its line; 0 for the Machine line.
    public internal(set) var cpuPercent: Double
    public internal(set) var conditions: [Condition]
    /// The subject's processes, sorted (what the window's Pause and Stop act on), and the busiest of them (which group
    /// the warning pins in another grouping); empty and nil on the Machine line.
    /// `pids` leaves out the user's own interactive session and its launch wrappers (`ProcessUsage.usersOwn`): a warning
    /// names the workload below them, and Pause and Stop never reach them.
    public internal(set) var pids: [Int32]
    public internal(set) var heaviest: Int32?
    /// Those of `pids` that are Apple services (`ProcessUsage.isAppleService`): warned about, and withheld from
    /// automatic Pause while `acting.exempt.apple` is on.
    public internal(set) var appleServices: [Int32]

    public init(subject: Subject, name: String, since: Double, cpuPercent: Double, conditions: [Condition],
                pids: [Int32] = [], heaviest: Int32? = nil, appleServices: [Int32] = []) {
        self.subject = subject
        self.name = name
        self.since = since
        self.cpuPercent = cpuPercent
        self.conditions = conditions
        self.pids = pids
        self.heaviest = heaviest
        self.appleServices = appleServices
    }

    /// As the CLI prints it: `! run.sh × 75  copies 75, …; system 54.0% of CPU time`.
    public var text: String { TextFormat.warningText(self) }
}

extension Warning.Subject {
    /// The form the window's ignore list keeps: `command:<key>`, `session:<name>`, `repo:<name>`, `machine`.
    public var key: String {
        switch self {
        case .command(let key): "command:" + key
        case .session(let name): "session:" + name
        case .repo(let name): "repo:" + name
        case .machine: "machine"
        }
    }

    /// As Settings lists an ignored one, escaped: `run.sh (command)`, `build (session)`, `example (repo)`, `Machine`.
    public var title: String {
        switch self {
        case .command(let key): "\(TextFormat.displaySafe(key)) (command)"
        case .session(let name): "\(TextFormat.displaySafe(name)) (session)"
        case .repo(let name): "\(TextFormat.displaySafe(name)) (repo)"
        case .machine: "Machine"
        }
    }

    /// The subject `key` names; nil for anything else.
    public init?(key: String) {
        if key == "machine" { self = .machine; return }
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let value = String(key[key.index(after: colon)...])
        switch key[..<colon] {
        case "command": self = .command(value)
        case "session": self = .session(value)
        case "repo": self = .repo(value)
        default: return nil
        }
    }
}

extension Warning.Condition {
    /// As the CLI prints it: `copies 75, up 75 in 5 min, 41.2% with what they started`.
    public var text: String { TextFormat.conditionText(self) }
}

/// The starting figures (plan § Decisions; research 2026-10-22 § Q3), all in one place so tuning changes values only.
public struct WarningThresholds: Sendable {
    public var unattributedPercent = 15.0, unattributedHold = 10.0
    public var copies = 20, copiesGrowth = 20, copiesPercent = 5.0, copiesHold = 10.0
    public var copiesGrowthWindow = 300.0
    /// The 15-minute clause was dropped: at rest under a test run this Mac holds about 3 × (the user, 2026-10-23).
    public var loadPerCPU = 4.0, loadHold = 60.0
    public var systemPercent = 40.0, systemHold = 30.0
    public var groupPercent = 25.0, groupHold = 600.0
    /// A raised warning clears once its figure stays below 7/8 of its bar for `clearHold` seconds: netdata's
    /// hysteresis (`health.d/load.conf` raises at 200% of cores, clears below 175%) and its `delay: down`.
    public var clearRatio = 7.0 / 8, clearHold = 10.0
    /// A window starting more than this after the last one ended restarts every run (a read was missed).
    public var gap = 1.0

    public init() {}

    /// Under 7/8 of the copies bar a raised copies warning clears: 17 copies is the most that do, 18 the fewest kept.
    var copiesFloor: Int { Int((Double(copies) * clearRatio).rounded(.down)) }
    var copiesKept: Int { Int((Double(copies) * clearRatio).rounded(.up)) }
}

/// The warnings in force over a series of windows (Phase 6 Step 5). Each condition holds before it fires and clears
/// below a lower bar; a line is keyed by the command or group it names, so copies coming and going never add lines;
/// an agent is never the subject. Pure: state is a handful of runs plus the copy counts of the last 5 minutes, in
/// 10-second buckets, for commands with two or more copies, and when each copies line cleared in that time.
public struct WarningEngine: Sendable {
    public let thresholds: WarningThresholds

    /// One condition on one subject: the run above its bar, the run below its lower bar while raised.
    struct Hold: Sendable {
        var aboveSince: Double?
        var belowSince: Double?
        var raisedSince: Double?

        var raised: Bool { raisedSince != nil }
        var idle: Bool { aboveSince == nil && raisedSince == nil }

        /// `fire` gates the raise once the hold is met (the load's "and rising").
        mutating func step(start: Double, end: Double, above: Bool, belowClear: Bool, hold: Double, clearHold: Double,
                           fire: Bool = true) {
            let epsilon = 1e-6
            if raised {
                guard belowClear else {
                    belowSince = nil
                    return
                }
                let below = belowSince ?? start
                belowSince = below
                if end - below >= clearHold - epsilon { self = Hold() }
            } else if above {
                let since = aboveSince ?? start
                aboveSince = since
                if fire, end - since >= hold - epsilon {
                    raisedSince = since
                    aboveSince = nil
                }
            } else {
                aboveSince = nil
            }
        }

        mutating func restart() {
            aboveSince = nil
            belowSince = nil
        }
    }

    /// A subject's hold and what its line shows, kept from the last window it was seen in.
    struct Tracked: Sendable {
        var hold = Hold()
        var condition: Warning.Condition?
        var name = ""
        var cpuPercent = 0.0
        var members: Set<Int32> = []
        var heaviest: Int32?
    }

    var lastEnd: Double?
    var unattributed = Hold(), load = Hold(), system = Hold()
    var machineConditions: [Warning.Kind: Warning.Condition] = [:]
    /// The 1-minute load at each window's end over the last `loadHold` seconds and one before, for "rising".
    var loads: [(end: Double, value: Double)] = []
    var commands: [String: Tracked] = [:]
    var groups: [Warning.Subject: Tracked] = [:]
    /// The fewest copies seen per command in each 10-second bucket, newest last; a command missing from a bucket
    /// had one copy or none there and reads as none, so 30 new copies read "up 30" (a command that had one copy
    /// reads one too many, far under the growth bar).
    var buckets: [(index: Int, fewest: [String: Int])] = []
    /// When each command's copies warning last cleared, over the growth window.
    var cleared: [String: Double] = [:]

    public init(thresholds: WarningThresholds = WarningThresholds()) { self.thresholds = thresholds }

    /// The commands and groups whose warning is raised, ignored or not: an Ignore on a group lasts until its subject
    /// leaves this set (calibration 2026-10-23).
    public var raisedSubjects: Set<Warning.Subject> {
        Set(commands.filter { $0.value.hold.raised }.map { .command($0.key) }
            + groups.filter { $0.value.hold.raised }.map(\.key))
    }

    /// Reads one window; the warnings in force after it, the busiest subject first, the Machine line last. A subject in
    /// `ignoring` (the window's Ignore) is still followed, so it shows at once when no longer ignored, but its own
    /// conditions are left out: a group, or the copies of a command, that would have joined its line warn on their own
    /// figures, and the machine-wide conditions join the next line.
    public mutating func next(_ tick: WarningTick, ignoring: Set<Warning.Subject> = []) -> [Warning] {
        let start = tick.end - tick.seconds
        if let lastEnd, start > lastEnd + thresholds.gap {
            unattributed.restart(); load.restart(); system.restart()
            for key in commands.keys { commands[key]?.hold.restart() }
            for key in groups.keys { groups[key]?.hold.restart() }
        }
        lastEnd = tick.end
        // The rows by pid only when a command or group is near its bar or tracked: most windows need none.
        let groupBar = thresholds.groupPercent * thresholds.clearRatio
        let needed = !commands.isEmpty || !groups.isEmpty
            || tick.commandGroups.contains { $0.copies >= thresholds.copiesFloor }
            || tick.sessionGroups.contains { $0.totalCpuPercent > groupBar }
            || tick.repoGroups.contains { $0.totalCpuPercent > groupBar }
        let rows = Rows(needed ? tick.rows : [])
        stepMachine(tick, start: start)
        stepCopies(tick, start: start, rows: rows, ignoring: ignoring)
        stepGroups(tick, start: start, rows: rows)
        return lines(at: tick.end, ignoring: ignoring, rows: rows)
    }

    // MARK: the conditions

    mutating func stepMachine(_ tick: WarningTick, start: Double) {
        let t = thresholds
        if let percent = tick.unattributedCpuPercent {
            unattributed.step(start: start, end: tick.end, above: percent > t.unattributedPercent,
                              belowClear: percent < t.unattributedPercent * t.clearRatio, hold: t.unattributedHold,
                              clearHold: t.clearHold)
            machineConditions[.unattributed] = .unattributed(percent: percent)
        }
        if let average = tick.loadAverage {
            let value = average.oneMinute
            loads.append((tick.end, value))
            // Keep the newest reading at or before the hold's start, and everything after it.
            if let keep = loads.lastIndex(where: { $0.end <= tick.end - t.loadHold }) { loads.removeFirst(keep) }
            let rising = loads.count > 1 && value > loads[0].value
            let bar = t.loadPerCPU * Double(tick.cpus)
            load.step(start: start, end: tick.end, above: value > bar, belowClear: value < bar * t.clearRatio,
                      hold: t.loadHold, clearHold: t.clearHold, fire: rising)
            machineConditions[.load] = .load(oneMinute: value, cpus: tick.cpus, rising: rising)
        }
        if let split = tick.split {
            system.step(start: start, end: tick.end, above: split.system > t.systemPercent,
                        belowClear: split.system < t.systemPercent * t.clearRatio, hold: t.systemHold,
                        clearHold: t.clearHold)
            machineConditions[.systemShare] = .systemShare(percent: split.system)
        }
    }

    /// Copies of one command key, growing, busy (plan § Decisions). An agent's key is never the subject; an agent's
    /// CPU counts toward a script's copies, not a plain command's (a swarm's `zsh -c` wrappers; the user,
    /// 2026-10-23: "yes"). A copy started through an agent by a copy of a script command with as many copies as a raised
    /// line keeps joins that command's line, raised or not (`Joins`; the gate's rounds 2 and 5): its processes and CPU
    /// go there, so the line raises and clears on them (round 3) and names the script from its first warning. The
    /// user's own shells and sessions count toward no line (`ProcessUsage.usersOwn`). A command whose copies joined
    /// another line warns only on its other copies' figures: a raise they no longer meet alone ends at once, so no line
    /// is left of them. A line cleared in the last 5 minutes comes back on its count and CPU alone, without the growth:
    /// a runaway whose work paused (a rate limit, a long model turn, Pause then Resume) in a storm older than that.
    mutating func stepCopies(_ tick: WarningTick, start: Double, rows: Rows, ignoring: Set<Warning.Subject>) {
        let t = thresholds
        let joins = Joins(tick.commandGroups, rows: rows, kept: t.copiesKept, ignoring: ignoring)
        cleared = cleared.filter { tick.end - $0.value <= t.copiesGrowthWindow }
        let figures = tick.commandGroups.map { group in
            (group: group, copies: group.copies - (joins.copiesOut[group.name] ?? 0), out: joins.out[group.name])
        }
        recordCopies(Dictionary(figures.filter { $0.copies >= 2 }.map { ($0.group.name, $0.copies) }, uniquingKeysWith: max),
                     end: tick.end)
        for (group, copies, out) in figures where copies >= t.copiesFloor || commands[group.name] != nil {
            guard !CommandGroups.agents.contains(group.name) else { continue }
            let pids = out.map { out in group.pids.filter { !out.contains($0) } } ?? group.pids
            let total = out == nil ? group.totalCpuPercent : rows.total(pids)
            let script = rows.runsScript(group.name, pids: group.pids)
            let joined = joins.cpu[group.name] ?? 0
            let percent = rows.counted(pids, total: total, script: script) + joined
            let growth = copies - baseline(group.name)
            let above = copies >= t.copies && (growth >= t.copiesGrowth || cleared[group.name] != nil)
                && percent >= t.copiesPercent
            if joins.joinedAway.contains(group.name), !above {
                commands[group.name] = nil
                continue
            }
            var tracked = commands[group.name] ?? Tracked()
            guard above || !tracked.hold.idle else { continue }
            let raised = tracked.hold.raised
            tracked.hold.step(start: start, end: tick.end, above: above,
                              belowClear: Double(copies) < Double(t.copies) * t.clearRatio
                                  || percent < t.copiesPercent * t.clearRatio,
                              hold: t.copiesHold, clearHold: t.clearHold)
            if raised, !tracked.hold.raised { cleared[group.name] = tick.end }
            tracked.condition = .copies(count: copies, growth: growth, percent: percent)
            tracked.name = TextFormat.copiesTitle(name: group.name, copies: copies)
            if tracked.hold.raised {
                let carried = joins.carried[group.name] ?? []
                tracked.cpuPercent = total + joined
                tracked.members = Set(pids + carried)
                tracked.heaviest = rows.heaviest(pids + carried)
            }
            commands[group.name] = tracked
        }
        // A command gone this window counts as no copies.
        let present = commands.isEmpty ? [] : Set(tick.commandGroups.map(\.name))
        for (key, var tracked) in commands where !present.contains(key) {
            let raised = tracked.hold.raised
            tracked.hold.step(start: start, end: tick.end, above: false, belowClear: true, hold: t.copiesHold,
                              clearHold: t.clearHold)
            if raised, !tracked.hold.raised { cleared[key] = tick.end }
            tracked.condition = .copies(count: 0, growth: 0, percent: 0)
            tracked.name = TextFormat.copiesTitle(name: key, copies: 0)
            commands[key] = tracked
        }
        commands = commands.filter { !$0.value.hold.idle }
    }

    /// Which members leave their own command's figures this window (the 2026-10-22 shape: script copies → headless
    /// `claude` → tool shells → `node build.js`, research 2026-10-25 § A and § B). The user's own shells and sessions
    /// leave every figure. The targets are the script commands with `kept` or more copies of their own, counted before
    /// any join, so they need no raised state and one pass settles them. A copy climbs past agents, plain commands and
    /// other commands' copies — the tool shells (`zsh -c`) are the same command as the login shells — to the first
    /// target's member, and joins that member's copy's line, or the line that copy joins in turn. A target met before
    /// any agent, an ignored target, one of the user's own, launchd, a missing row or a loop ends the climb with the
    /// copy kept.
    struct Joins {
        /// Per command, its members out of its own figures (joining another line, or the user's own) and how many
        /// copies that is; the commands with members joining another line.
        var out: [String: Set<Int32>] = [:]
        var copiesOut: [String: Int] = [:]
        var joinedAway: Set<String> = []
        /// Per target, the members joining its line and their own + exited CPU.
        var carried: [String: [Int32]] = [:]
        var cpu: [String: Double] = [:]

        init(_ groups: [CommandGroup], rows: Rows, kept: Int, ignoring: Set<Warning.Subject>) {
            guard !rows.byPid.isEmpty else { return }
            for group in groups {
                for pid in group.pids where rows.byPid[pid]?.usersOwn == true {
                    out[group.name, default: []].insert(pid)
                    if group.copyOf[pid] == nil { copiesOut[group.name, default: 0] += 1 }
                }
            }
            var owner: [Int32: (key: String, copy: Int32, ignored: Bool)] = [:]
            for group in groups where group.copies - (copiesOut[group.name] ?? 0) >= kept
                && !CommandGroups.agents.contains(group.name) && rows.runsScript(group.name, pids: group.pids) {
                let ignored = ignoring.contains(.command(group.name))
                for pid in group.pids where rows.byPid[pid]?.usersOwn != true {
                    owner[pid] = (group.name, group.copyOf[pid] ?? pid, ignored)
                }
            }
            guard !owner.isEmpty else { return }
            var settled: [Int32: String?] = [:]
            /// The line the copy `copy` of `key` joins; nil when it keeps its own.
            func line(_ copy: Int32, _ key: String) -> String? {
                if let known = settled[copy] { return known }
                settled[copy] = .some(nil)  // under way: a ppid loop back to it ends there
                var throughAgent = false
                var seen: Set<Int32> = [copy]
                var current = rows.byPid[copy]?.ppid ?? 0
                var found: String?
                while current > 1, seen.insert(current).inserted, let row = rows.byPid[current], !row.usersOwn {
                    if CommandGroups.isAgent(name: row.name, key: row.command ?? row.name) { throughAgent = true }
                    if let met = owner[current], met.key != key {
                        if throughAgent, !met.ignored { found = line(met.copy, met.key) ?? met.key }
                        break
                    }
                    current = row.ppid
                }
                settled[copy] = .some(found)
                return found
            }
            for group in groups where !CommandGroups.agents.contains(group.name) {
                for pid in group.pids where rows.byPid[pid]?.usersOwn != true {
                    let copy = group.copyOf[pid] ?? pid
                    guard let target = line(copy, group.name) else { continue }
                    out[group.name, default: []].insert(pid)
                    joinedAway.insert(group.name)
                    if copy == pid { copiesOut[group.name, default: 0] += 1 }
                    carried[target, default: []].append(pid)
                    cpu[target, default: 0] += rows.byPid[pid]?.totalCpuPercent ?? 0
                }
            }
        }
    }

    /// Records this window's copy counts (`counts`: commands with two or more copies of their own) in its bucket and
    /// drops buckets past the growth window.
    mutating func recordCopies(_ counts: [String: Int], end: Double) {
        let index = Int((end / 10).rounded(.down))
        if buckets.last?.index == index {
            var fewest = buckets[buckets.count - 1].fewest
            for key in fewest.keys where counts[key] == nil { fewest[key] = 0 }
            for (key, count) in counts { fewest[key] = min(fewest[key] ?? 0, count) }
            buckets[buckets.count - 1].fewest = fewest
        } else {
            buckets.append((index, counts))
        }
        let oldest = index - Int((thresholds.copiesGrowthWindow / 10).rounded(.up)) + 1
        buckets.removeAll { $0.index < oldest }
    }

    /// The fewest copies of `key` over the growth window (the window's own bucket included).
    func baseline(_ key: String) -> Int { buckets.map { $0.fewest[key] ?? 0 }.min() ?? 0 }

    /// One repo or session group above its bar for 10 minutes; the VMs group and the catch-alls (no root, no kind)
    /// are never the subject.
    mutating func stepGroups(_ tick: WarningTick, start: Double, rows: Rows) {
        let t = thresholds
        typealias Candidate = (subject: Warning.Subject, name: String, cpu: Double, pids: [Int32])
        let candidates: [Candidate] =
            tick.sessionGroups.filter { $0.kind != nil }.map { (.session($0.name), $0.name, $0.totalCpuPercent, $0.pids) }
            + tick.repoGroups.filter { $0.root != nil }.map { (.repo($0.name), $0.name, $0.totalCpuPercent, $0.pids) }
        var seen: Set<Warning.Subject> = []
        for candidate in candidates {
            seen.insert(candidate.subject)
            let above = candidate.cpu > t.groupPercent
            var tracked = groups[candidate.subject] ?? Tracked()
            guard above || !tracked.hold.idle else { continue }
            tracked.hold.step(start: start, end: tick.end, above: above,
                              belowClear: candidate.cpu < t.groupPercent * t.clearRatio, hold: t.groupHold,
                              clearHold: t.clearHold)
            let kind = if case .session = candidate.subject { "session" } else { "repo" }
            tracked.name = "\(TextFormat.displaySafe(candidate.name)) (\(kind))"
            tracked.cpuPercent = candidate.cpu
            if let since = tracked.hold.raisedSince {
                // The group's figure counts everything in it; what the warning names, and Pause and Stop reach, is its
                // workload — not the user's interactive session and its launch wrappers (`usersOwn`).
                let workload = candidate.pids.filter { rows.byPid[$0]?.usersOwn != true }
                tracked.condition = .group(percent: candidate.cpu, seconds: tick.end - since)
                tracked.members = Set(workload)
                tracked.heaviest = rows.heaviest(workload)
            }
            groups[candidate.subject] = tracked
        }
        for (subject, var tracked) in groups where !seen.contains(subject) {
            tracked.hold.step(start: start, end: tick.end, above: false, belowClear: true, hold: t.groupHold,
                              clearHold: t.clearHold)
            if let since = tracked.hold.raisedSince { tracked.condition = .group(percent: 0, seconds: tick.end - since) }
            tracked.cpuPercent = 0
            groups[subject] = tracked
        }
        groups = groups.filter { !$0.value.hold.idle }
    }

    // MARK: one line per runaway

    /// Command lines first, each carrying the copies that joined it (`Joins`), then session and repo trips — each
    /// joining a line that holds its heaviest process, or whose heaviest process it holds — then the machine-wide
    /// conditions on the busiest line, else on one Machine line. Ignored subjects add nothing.
    func lines(at end: Double, ignoring: Set<Warning.Subject> = [], rows: Rows) -> [Warning] {
        struct Line {
            var warning: Warning
            var members: Set<Int32>
            var heaviest: Int32?
        }
        var lines: [Line] = []
        let raisedCommands = commands.filter { $0.value.hold.raised && !ignoring.contains(.command($0.key)) }
        for (key, tracked) in raisedCommands.sorted(by: { ($0.value.cpuPercent, $1.key) > ($1.value.cpuPercent, $0.key) }) {
            guard let condition = tracked.condition, let since = tracked.hold.raisedSince else { continue }
            lines.append(Line(warning: Warning(subject: .command(key), name: tracked.name, since: since,
                                               cpuPercent: tracked.cpuPercent, conditions: [condition]),
                              members: tracked.members, heaviest: tracked.heaviest))
        }
        func rank(_ subject: Warning.Subject) -> Int { if case .session = subject { 0 } else { 1 } }
        let raisedGroups = groups.filter { $0.value.hold.raised && !ignoring.contains($0.key) }.sorted { a, b in
            rank(a.key) != rank(b.key) ? rank(a.key) < rank(b.key)
                : (a.value.cpuPercent, b.value.name) > (b.value.cpuPercent, a.value.name)
        }
        for (subject, tracked) in raisedGroups {
            guard let condition = tracked.condition, let since = tracked.hold.raisedSince else { continue }
            if let i = lines.firstIndex(where: { line in
                line.heaviest.map(tracked.members.contains) == true || tracked.heaviest.map(line.members.contains) == true
            }) {
                lines[i].warning.conditions.append(condition)
                lines[i].warning.since = min(lines[i].warning.since, since)
            } else {
                lines.append(Line(warning: Warning(subject: subject, name: tracked.name, since: since,
                                                   cpuPercent: tracked.cpuPercent, conditions: [condition]),
                                  members: tracked.members, heaviest: tracked.heaviest))
            }
        }
        var warnings = lines.map { line in
            var warning = line.warning
            warning.pids = line.members.sorted()
            warning.heaviest = line.heaviest
            warning.appleServices = warning.pids.filter { rows.byPid[$0]?.isAppleService == true }
            return warning
        }.sorted { $0.cpuPercent > $1.cpuPercent }
        let machine: [(Hold, Warning.Kind)] = [(unattributed, .unattributed), (load, .load), (system, .systemShare)]
        let raised = machine.compactMap { hold, kind in
            hold.raisedSince.flatMap { since in machineConditions[kind].map { (since, $0) } }
        }
        if !raised.isEmpty {
            let since = raised.map(\.0).min() ?? end
            if warnings.isEmpty {
                warnings.append(Warning(subject: .machine, name: "Machine", since: since, cpuPercent: 0,
                                        conditions: raised.map(\.1)))
            } else {
                warnings[0].conditions += raised.map(\.1)
                warnings[0].since = min(warnings[0].since, since)
            }
        }
        return warnings
    }

    /// The window's rows by pid, for the few groups over a bar.
    struct Rows {
        let byPid: [Int32: ProcessUsage]

        init(_ rows: [ProcessUsage]) {
            WorkCount.current.get()?.add(indexedRows: rows.count)
            byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        }

        /// Whether the copies of command `key` (its members `pids`) run a script: a member keyed `key` by its arguments.
        func runsScript(_ key: String, pids: [Int32]) -> Bool {
            pids.contains { pid in byPid[pid].map { $0.command == key && $0.name != key } ?? false }
        }

        /// The own + exited CPU of `pids`.
        func total(_ pids: [Int32]) -> Double { pids.compactMap { byPid[$0]?.totalCpuPercent }.reduce(0, +) }

        /// `total`, a command's members' own + exited CPU, less its agents' when its copies run no script.
        func counted(_ pids: [Int32], total: Double, script: Bool) -> Double {
            guard !script else { return total }
            let agents = pids.compactMap { byPid[$0] }.filter { CommandGroups.isAgent(name: $0.name, key: $0.command ?? $0.name) }
            return total - agents.map(\.totalCpuPercent).reduce(0, +)
        }

        /// The busiest of `pids` by own + exited CPU, the first on a tie; the first pid when none is a row.
        func heaviest(_ pids: [Int32]) -> Int32? {
            var best: ProcessUsage?
            for pid in pids {
                guard let row = byPid[pid] else { continue }
                if best.map({ row.totalCpuPercent > $0.totalCpuPercent }) ?? true { best = row }
            }
            return best?.pid ?? pids.first
        }
    }
}

// MARK: resource levels and the memory floor (Phase 7 Step 2)

/// The fixed resource levels, low to high (plan § Decisions). `normal` is a calibrated engine's quiet reading and is
/// never what an uncalibrated one reports: an unavailable level is nil.
public enum ResourceLevel: String, CaseIterable, Comparable, Sendable {
    case normal, notice, triage, critical

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (Self.allCases.firstIndex(of: lhs) ?? 0) < (Self.allCases.firstIndex(of: rhs) ?? 0)
    }
}

/// One bar's settings. The plan fixes only the bar itself; the hold and the drop-back margin are pending calibration,
/// so a band without them keeps its level unevaluated and the reading's `level` nil.
public struct LevelBand: Equatable, Sendable {
    public let percent: Double
    /// Seconds at or above `percent` before the level raises.
    public let hold: Double?
    /// Percentage points below `percent` at which a raised level clears — the margin against flapping.
    public let dropBack: Double?

    public init(percent: Double, hold: Double? = nil, dropBack: Double? = nil) {
        self.percent = percent
        self.hold = hold
        self.dropBack = dropBack
    }

    public var isCalibrated: Bool { hold != nil && dropBack != nil }
}

/// The fixed levels' and the memory floor's settings. Optional knobs leave their part unevaluated; `pending`
/// evaluates nothing, reports no level and requests no pause. The approved provisional settings stay switched off
/// until activation is separately approved (plan § Step 2).
public struct ResourceCalibration: Equatable, Sendable {
    /// The percentage the bars judge memory on; nil leaves memory unevaluated.
    public let basis: MemoryPercentBasis?
    public let notice, triage, critical: LevelBand
    /// Seconds whole-machine CPU must stay at or above a bar (plan: "CPU levels count only when sustained").
    public let cpuSustain: Double?
    /// The memory floor's projection settings; nil leaves the time-to-floor warning unevaluated. Independent of the
    /// fixed levels: either can be configured without the other.
    public let eta: MemoryProjection.Config?

    public init(basis: MemoryPercentBasis? = nil, notice: LevelBand = LevelBand(percent: 80),
                triage: LevelBand = LevelBand(percent: 90), critical: LevelBand = LevelBand(percent: 95),
                cpuSustain: Double? = nil, eta: MemoryProjection.Config? = nil) {
        self.basis = basis
        self.notice = notice
        self.triage = triage
        self.critical = critical
        self.cpuSustain = cpuSustain
        self.eta = eta
    }

    /// Nothing evaluated while resource alerts are off, or a calibration is still pending.
    public static let pending = ResourceCalibration()

    /// Provisional starting values from research/2026-10-29-step2-calibration-proposal.md, approved for source only
    /// on 2026-10-29 (Delphi 2f37c2a3). Activation needs a separate yes after a demo; this value enables nothing itself.
    public static let provisional = ResourceCalibration(
        basis: .usedOfPhysical,
        notice: LevelBand(percent: 80, hold: 10, dropBack: 5),
        triage: LevelBand(percent: 90, hold: 5, dropBack: 5),
        critical: LevelBand(percent: 95, hold: 2, dropBack: 3),
        cpuSustain: 30,
        eta: MemoryProjection.Config(windows: [60, 180], minimumSamples: 10,
                                     minimumDeclineBytesPerSecond: 1_048_576))

    public static let enabledKey = "resource.levels.enabled"

    /// The app's defaults lookup, injectable like `ActingSwitches.read`. Only a Bool true selects the provisional
    /// settings: missing, false, strings and numbers all leave evaluation off. CFBoolean also covers stored Bools
    /// bridged by UserDefaults, without accepting NSNumber's integer 1 as true.
    public static func read(_ lookup: (String) -> Any?) -> ResourceCalibration {
        guard let value = lookup(enabledKey) as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(),
              value.boolValue else { return .pending }
        return .provisional
    }

    /// Every bar's figure is judged only when the basis, both timings of every band and the CPU sustain are set.
    public var levelsCalibrated: Bool {
        basis != nil && cpuSustain != nil && [notice, triage, critical].allSatisfy(\.isCalibrated)
    }
}

/// A process as a level names it: its identity by pid and start time, and the figures that made it a consumer.
public struct ResourceConsumer: Equatable, Sendable {
    public let pid: Int32
    public let startMicroseconds: UInt64
    public let name: String
    public let residentBytes: UInt64
    public let cpuPercent: Double

    public init(row: ProcessUsage) {
        pid = row.pid
        startMicroseconds = row.startMicroseconds
        name = row.name
        residentBytes = row.residentBytes
        cpuPercent = row.totalCpuPercent
    }
}

/// A held level's change this tick, on the resource that made it.
public struct LevelTransition: Equatable, Sendable {
    public enum Cause: String, Equatable, Sendable { case memory, cpu }

    public let from: ResourceLevel
    public let to: ResourceLevel
    public let cause: Cause
    /// The figure that made the level: memory or CPU percent.
    public let percent: Double
}

/// The pause a critical level proposes — never one it performs. The target is the biggest consumer by identity, even
/// when it is one Step 3 will protect: protection and the verified sweep decide, and nothing here signals anything.
public struct PauseRequest: Equatable, Sendable {
    public let target: ResourceConsumer
    public let level: ResourceLevel
    /// The level's figures, as the evidence records them.
    public let reason: String
}

/// One tick's resource reading: the held level (nil while the fixed levels are pending), the ETA beside it, and the
/// consumers a notice or a request names.
public struct ResourceReading: Equatable, Sendable {
    public let end: Double
    /// The highest held level; nil while the fixed levels are uncalibrated, never guessed as `normal`.
    public let level: ResourceLevel?
    /// The level changes this tick, one per resource that changed.
    public let transitions: [LevelTransition]
    public let memoryPercent: Double?
    public let cpuPercent: Double?
    public let eta: MemoryProjection.ETA?
    public let growthDriver: MemoryProjection.GrowthDriver?
    /// At a notice and above: the five processes costing the driving resource most, biggest first.
    public let topConsumers: [ResourceConsumer]
    /// At a triage and above: the proposed target, named without any action.
    public let triageTarget: ResourceConsumer?
    /// Only at a critical level, and only as a proposal.
    public let pauseRequest: PauseRequest?

    /// As the CLI prints it: the level and its figures, then the ETA, the notice's consumers, the triage's target or
    /// the critical request.
    public var text: String { TextFormat.resourceText(self) }

    /// What the CLI prints while resource alerts are off: unavailable, never normal (plan § Step 2).
    public static let unavailableText = "Levels  unavailable — resource alerts off"
}

/// The fixed levels' engine and the memory floor's, side by side but independent (plan § Decisions): each bar holds on
/// its own figures, CPU only when sustained, and the ETA never raises a level or proposes a pause. Pure: state is each
/// bar's hold and the projection's recent samples.
public struct ResourceLevelEngine: Sendable {
    public let calibration: ResourceCalibration
    private var memoryHolds = ResourceLevelEngine.holds()
    private var cpuHolds = ResourceLevelEngine.holds()
    private var memoryLevel: ResourceLevel = .normal
    private var cpuLevel: ResourceLevel = .normal
    private var lastEnd: Double?
    private var projection: MemoryProjection?

    public init(calibration: ResourceCalibration = .pending) {
        self.calibration = calibration
        projection = calibration.eta.map(MemoryProjection.init(config:))
    }

    private static func holds() -> [ResourceLevel: WarningEngine.Hold] {
        Dictionary(uniqueKeysWithValues: [ResourceLevel.notice, .triage, .critical].map { ($0, WarningEngine.Hold()) })
    }

    /// Reads one window; nil when neither the levels nor the ETA are calibrated (nothing usable to report).
    public mutating func next(_ tick: WarningTick) -> ResourceReading? {
        guard calibration.levelsCalibrated || projection != nil else { return nil }
        let start = tick.end - tick.seconds
        if let lastEnd, start > lastEnd + 1 {
            memoryHolds = Self.holds()
            cpuHolds = Self.holds()
            memoryLevel = .normal
            cpuLevel = .normal
        }
        lastEnd = tick.end
        let memoryPercent = tick.memory.flatMap { memory in calibration.basis.map { memory.usedPercent($0) } }
        var transitions: [LevelTransition] = []
        if calibration.levelsCalibrated {
            var memoryHoldsLocal = memoryHolds
            var cpuHoldsLocal = cpuHolds
            let memory = step(percent: memoryPercent, end: tick.end, start: start, fixedHold: nil,
                              holds: &memoryHoldsLocal)
            let cpu = step(percent: tick.cpuPercent, end: tick.end, start: start, fixedHold: calibration.cpuSustain,
                           holds: &cpuHoldsLocal)
            memoryHolds = memoryHoldsLocal
            cpuHolds = cpuHoldsLocal
            transitions += change(from: memoryLevel, to: memory, cause: .memory, percent: memoryPercent)
            transitions += change(from: cpuLevel, to: cpu, cause: .cpu, percent: tick.cpuPercent)
            memoryLevel = memory
            cpuLevel = cpu
        }
        let level = calibration.levelsCalibrated ? max(memoryLevel, cpuLevel) : nil
        let projected = projection?.next(end: tick.end, memory: tick.memory, rows: tick.rows)
        let named = consumers(level: level, tick: tick, memoryPercent: memoryPercent)
        return ResourceReading(end: tick.end, level: level, transitions: transitions, memoryPercent: memoryPercent,
                               cpuPercent: tick.cpuPercent, eta: projected?.eta,
                               growthDriver: projected?.growthDriver, topConsumers: named.consumers,
                               triageTarget: named.triage, pauseRequest: named.request)
    }

    /// One resource's three bands, each with its own hold; the highest band raised.
    private mutating func step(percent: Double?, end: Double, start: Double, fixedHold: Double?,
                               holds: inout [ResourceLevel: WarningEngine.Hold]) -> ResourceLevel {
        guard let percent else { return holds.filter { $0.value.raised }.map(\.key).max() ?? .normal }
        let bands: [(ResourceLevel, LevelBand)] = [(.notice, calibration.notice), (.triage, calibration.triage),
                                                   (.critical, calibration.critical)]
        var highest: ResourceLevel = .normal
        for (level, band) in bands {
            guard let hold = fixedHold ?? band.hold, let dropBack = band.dropBack, var state = holds[level] else {
                continue
            }
            state.step(start: start, end: end, above: percent >= band.percent,
                       belowClear: percent < band.percent - dropBack, hold: hold, clearHold: 0)
            holds[level] = state
            if state.raised { highest = max(highest, level) }
        }
        return highest
    }

    private func change(from: ResourceLevel, to: ResourceLevel, cause: LevelTransition.Cause,
                        percent: Double?) -> [LevelTransition] {
        guard from != to else { return [] }
        return [LevelTransition(from: from, to: to, cause: cause, percent: percent ?? 0)]
    }

    /// The consumers a level names: the five biggest on the driving resource, the target, and the critical request.
    private func consumers(level: ResourceLevel?, tick: WarningTick,
                           memoryPercent: Double?) -> (consumers: [ResourceConsumer], triage: ResourceConsumer?,
                                                       request: PauseRequest?) {
        guard let level, level >= .notice else { return ([], nil, nil) }
        let byMemory = memoryLevel >= cpuLevel
        let ordered = tick.rows.sorted { a, b in
            if byMemory {
                if a.residentBytes != b.residentBytes { return a.residentBytes > b.residentBytes }
            } else if a.totalCpuPercent != b.totalCpuPercent {
                return a.totalCpuPercent > b.totalCpuPercent
            }
            return a.pid < b.pid
        }
        let ranked = ordered.prefix(5).map(ResourceConsumer.init(row:))
        guard let target = ranked.first else { return ([], nil, nil) }
        let triage = level >= .triage ? target : nil
        guard level == .critical else { return (ranked, triage, nil) }
        let cause = byMemory ? "memory" : "cpu"
        let percent = byMemory ? memoryPercent : tick.cpuPercent
        let figure = percent.map(TextFormat.percentText) ?? "unread"
        return (ranked, triage, PauseRequest(target: target, level: .critical,
                                             reason: "\(level.rawValue) by \(cause) \(figure)"))
    }
}

/// The bar above the window's table (Phase 6 Step 6): one line per warning, in the engine's order.
public enum WarningBar {
    public struct Line: Identifiable, Equatable, Sendable {
        /// The subject's key: a line keeps its place and state while its warning lasts.
        public let id: String
        /// `warning-<i>`; the line's buttons and conditions add to it (`warning-details-<i>`, `warning-condition-<i>-<j>`).
        public let identifier: String
        /// The warning's name (`run.sh × 75`), which the Stop sheet's title carries.
        public let name: String
        /// `! <name>  <first condition>`, with `(+N more)` when there are more.
        public let text: String
        /// Every condition with its figures, as Details shows them.
        public let conditions: [String]
        /// The table line the warning pins, which Details selects; nil when it pins none.
        public let group: String?
        /// What Pause and Stop act on: the warning's workload, less the Apple services while `acting.exempt.apple` is on.
        public let pids: [Int32]
        /// What Ignore keeps; nil on the Machine line, which cannot be ignored.
        public let ignoreKey: String?
        /// The Apple services the exemption leaves out of `pids`: still on the line, never paused by it.
        public let exempt: [Int32]
        /// Why Pause and Stop leave them: "Apple service — not paused"; nil when none is exempt.
        public let note: String?
        /// Whether Pause and Stop have processes to act on.
        public var actionable: Bool { !pids.isEmpty }
    }

    /// The bar's lines for `warnings`, each naming the line of `table` it pinned (`ProcessTable.Line.warnings`). With
    /// `exemptApple` on, a line's Apple services stay named on it (its `note`) but are not what its buttons act on —
    /// the same eligibility the watcher uses, so what the bar says is not paused is what the watcher left running.
    public static func lines(_ warnings: [Warning], table: [ProcessTable.Line], exemptApple: Bool = true) -> [Line] {
        warnings.enumerated().map { i, warning in
            let conditions = warning.conditions.map(\.text)
            let more = conditions.count > 1 ? " (+\(conditions.count - 1) more)" : ""
            let exempt = exemptApple ? warning.appleServices : []
            let skipped = Set(exempt)
            let note = exempt.isEmpty ? nil
                : (exempt.count == 1 ? "Apple service" : "\(exempt.count) Apple services") + " — not paused"
            return Line(id: warning.subject.key, identifier: "warning-\(i)", name: warning.name,
                        text: "! \(warning.name)  \(conditions.first ?? "")\(more)", conditions: conditions,
                        group: table.first { $0.warnings.contains(i) }?.id,
                        pids: warning.pids.filter { !skipped.contains($0) },
                        ignoreKey: warning.subject == .machine ? nil : warning.subject.key, exempt: exempt, note: note)
        }
    }
}

/// Spike marks on one graph (plan § Decisions: "spikes are marked, runaways are warned"): a second whose figure is at
/// least twice the median of the minute before it and at least `floor` above that median, named for the top process
/// at that second; at most one mark per `spacing` seconds; kept while its second is on the 60-second graph. Raises
/// nothing.
public struct SpikeMarks: Sendable {
    public struct Mark: Equatable, Sendable {
        public let end: Double
        public let value: Double
        /// `node 48.0%`; nil when no process was read.
        public let name: String?
    }

    /// The time of day with seconds, in the Mac's own clock setting: AM/PM after it on a 12-hour clock (an hour after
    /// midnight and one after noon both read 12), none on a 24-hour one — `Date.FormatStyle`'s `.hour()` default.
    public static func clock(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute().second())
    }

    public let floor: Double
    public let window = 60.0, spacing = 10.0, history = 10
    public private(set) var marks: [Mark] = []
    var values: [(end: Double, value: Double)] = []

    public init(floor: Double) { self.floor = floor }

    /// Reads the figure of the second ending at `end`, with the top process's text.
    public mutating func next(end: Double, value: Double, top: String?) {
        values.removeAll { $0.end <= end - window }
        marks.removeAll { $0.end <= end - window }
        defer { values.append((end, value)) }
        guard values.count >= history else { return }
        let sorted = values.map(\.value).sorted()
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        guard value >= 2 * median, value - median >= floor else { return }
        if let last = marks.last, end - last.end < spacing { return }
        marks.append(Mark(end: end, value: value, name: top))
    }

    /// Where one name sits on a graph's plot: its row from the top, its left edge and its width in points.
    public struct NameSlot: Equatable, Sendable {
        public let row: Int
        public let x: Double
        public let width: Double
    }

    /// Where each spike's name goes on a plot `width` wide (the gate's round 1: names drawn over the title and each
    /// other), in the order given: from its rule's x `xs[i]`, `widths[i]` wide as drawn and cut to the plot, moved left
    /// to end at the plot's right edge when it would pass it (as Swift Charts' `AnnotationOverflowResolution` fits an
    /// annotation to the plot), on the first of `rows` rows where it keeps `gap` from every name placed; nil when no
    /// row has room (the list under the graph still names it).
    public static func nameSlots(xs: [Double], widths: [Double], width: Double, rows: Int, gap: Double = 6) -> [NameSlot?] {
        var taken: [[ClosedRange<Double>]] = Array(repeating: [], count: max(rows, 0))
        return zip(xs, widths).map { x, drawn in
            let w = min(drawn, width)
            let left = max(0, min(x, width - w))
            let span = (left - gap)...(left + w + gap)
            guard let row = taken.indices.first(where: { !taken[$0].contains { $0.overlaps(span) } }) else { return nil }
            taken[row].append(left...(left + w))
            return NameSlot(row: row, x: left, width: w)
        }
    }

    /// The row with the most of `key`, as `<name> <figure>` — the figure as a percent unless `text` writes it; nil when
    /// no row has any.
    public static func top(_ rows: [ProcessUsage], by key: (ProcessUsage) -> Double,
                           text: ((Double) -> String)? = nil) -> String? {
        guard let row = rows.max(by: { key($0) < key($1) }), key(row) > 0 else { return nil }
        return "\(TextFormat.displaySafe(row.name)) \(text?(key(row)) ?? TextFormat.percentText(key(row)))"
    }
}
