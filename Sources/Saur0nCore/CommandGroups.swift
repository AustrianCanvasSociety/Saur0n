// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One command in the By command view (Phase 6 Step 4): every copy of one command key with what each copy owns.
public struct CommandGroup: Equatable, Sendable {
    /// The command key (`CommandGroups.key`).
    public let name: String
    /// The processes that start a copy of the key; what a script copy owns below it does not add to the count.
    public let copies: Int
    /// Sum of its rows' own CPU.
    public let cpuPercent: Double
    /// Sum of its rows' exited-children CPU (unread rows add 0).
    public let exitedChildrenCpuPercent: Double
    public let residentBytes: UInt64
    /// As `RepoGroup.disk`.
    public var disk: DiskUsage = .zero
    /// As `RepoGroup.network`.
    public var network: NetworkUsage = .zero
    /// In tree order: each copy, then what it owns depth-first (`CommandGroups.assign`).
    public internal(set) var pids: [Int32]
    /// The copy each owned member belongs to (the pid that starts it); a member absent here starts a copy.
    var copyOf: [Int32: Int32] = [:]

    /// What the group header shows and groups are ordered by, as `RepoGroup.totalCpuPercent`.
    public var totalCpuPercent: Double { cpuPercent + exitedChildrenCpuPercent }
}

extension CommandGroup: Encodable {
    enum CodingKeys: String, CodingKey {
        case name, copies, cpuPercent, exitedChildrenCpuPercent, residentBytes, disk, network, pids
    }

    /// The `repoGroups` shape plus `copies`, without `subgroups`: CPU figures to two decimals.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(copies, forKey: .copies)
        try container.encode(TextFormat.rounded(cpuPercent, places: 2), forKey: .cpuPercent)
        try container.encode(TextFormat.rounded(exitedChildrenCpuPercent, places: 2), forKey: .exitedChildrenCpuPercent)
        try container.encode(residentBytes, forKey: .residentBytes)
        try container.encode(disk, forKey: .disk)
        try container.encode(network, forKey: .network)
        try container.encode(pids, forKey: .pids)
    }
}

/// Processes grouped by the command they run (research 2026-10-22 § Q1 item 1): one group per command key — the
/// executable's name, or for a shell or interpreter the script it runs — so a script copying itself reads as
/// "that script × N". A script copy owns everything it starts down to an agent, as btop's `proc_aggregate` sums a
/// tree; a plain executable owns nothing below it, so a build's compilers read as `clang`, not `make` (the user,
/// 2026-10-23: "go with that"). The agents never form a key of their own while something started them. Pure.
public enum CommandGroups {
    /// Matched by program name, not path: the path carries Claude Code's version (plan § Decisions).
    public static let agents: Set<String> = ["claude", "codex", "cli-proxy-api"]

    /// The shells and interpreters keyed by the script they run.
    enum Interpreter { case shell, python, node, ruby, perl }

    /// `bash`, `python3.12`, `perl5.34`, `Python` (the framework build's name): the family, a version suffix ignored.
    static func interpreter(_ name: String) -> Interpreter? {
        let base = String(name.lowercased().reversed().drop { $0.isNumber || $0 == "." }.reversed())
        switch base {
        case "sh", "bash", "zsh": return .shell
        case "python": return .python
        case "node": return .node
        case "ruby": return .ruby
        case "perl": return .perl
        default: return nil
        }
    }

    /// A row's command key and whether it came from a script: the script's basename (python's `-m` module) when an
    /// interpreter runs one, else `name`. No script: an inline program (`-c`, `-e`), a bare or login shell, unread
    /// arguments (`argv` nil — other users' processes).
    static func command(name: String, argv: [String]?) -> (key: String, script: Bool) {
        guard let family = interpreter(name), let argv, argv.count > 1 else { return (name, false) }
        let inline: Set<String>, valued: Set<String>
        switch family {
        case .shell: (inline, valued) = (["-c", "-s"], ["-o", "+o", "-O", "+O", "--rcfile", "--init-file"])
        case .python: (inline, valued) = (["-c"], ["-W", "-X", "-Q"])
        case .node: (inline, valued) = (["-e", "-p", "-pe", "--eval", "--print"],
                                        ["-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions"])
        case .ruby: (inline, valued) = (["-e"], ["-I", "-r", "-C"])
        case .perl: (inline, valued) = (["-e", "-E"], ["-I", "-m", "-M"])
        }
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" {
                i += 1
                break
            }
            guard arg.count > 1, arg.hasPrefix("-") || (family == .shell && arg.hasPrefix("+")) else { break }
            if inline.contains(arg) { return (name, false) }
            // A shell's short-option cluster with `c` or `s` (`-lc`) is an inline program too.
            if family == .shell, !arg.hasPrefix("--"), arg.dropFirst().contains(where: { $0 == "c" || $0 == "s" }) {
                return (name, false)
            }
            if family == .python, arg.hasPrefix("-m"), !arg.hasPrefix("--") {
                let module = arg == "-m" ? (i + 1 < argv.count ? argv[i + 1] : "") : String(arg.dropFirst(2))
                return module.isEmpty ? (name, false) : (module, true)
            }
            i += valued.contains(arg) ? 2 : 1
        }
        guard i < argv.count, argv[i] != "-", let script = ProcessSample.basename(argv[i]), !script.isEmpty else {
            return (name, false)
        }
        return (script, true)
    }

    /// A row's command key (`command(name:argv:)`).
    public static func key(name: String, argv: [String]?) -> String { command(name: name, argv: argv).key }

    /// An agent by its program name or its key (`node …/claude` keys as `claude`).
    public static func isAgent(name: String, key: String) -> Bool { agents.contains(name) || agents.contains(key) }

    /// A login shell, as the bash manual defines one (Invoking Bash: "one whose first character of argument zero is
    /// '-', or one invoked with the --login option"): `-zsh`, `-/bin/zsh`, `zsh -l`, `bash --login`, `zsh -lc …`.
    /// Unread arguments read as none.
    static func isLoginShell(name: String, argv: [String]?) -> Bool {
        guard interpreter(name) == .shell, let argv, let zero = argv.first else { return false }
        if zero.hasPrefix("-") { return true }
        for arg in argv.dropFirst() {
            guard arg.count > 1, arg.hasPrefix("-"), arg != "--" else { break }
            if arg == "--login" || (!arg.hasPrefix("--") && arg.dropFirst().contains("l")) { return true }
        }
        return false
    }

    /// Each row's `command` and `usersOwn` set, and the groups: by shown total CPU (one decimal), highest first, then
    /// name, then first pid. Each row sits in exactly one group. A row starts a copy of its own key unless it is owned: by the
    /// copy that owns its parent when that copy is a script copy and the parent is not an agent. An agent never
    /// starts a copy while it has a parent other than launchd: it goes wherever its parent does; its children start
    /// their own. `arguments` are the closing sample's (`ProcessSnapshot.arguments`); a row without them keys by name.
    public static func assign(_ rows: [ProcessUsage],
                              arguments: [Int32: ProcessArguments]) -> (rows: [ProcessUsage], groups: [CommandGroup]) {
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var commands: [Int32: (key: String, script: Bool, agent: Bool)] = [:]
        for row in rows {
            let command = command(name: row.name, argv: arguments[row.pid]?.argv)
            commands[row.pid] = (command.key, command.script, isAgent(name: row.name, key: command.key))
        }
        let (owner, own) = ownership(rows, byPid: byPid, commands: commands) { arguments[$0]?.argv }

        var assigned: [ProcessUsage] = []
        var members: [String: [ProcessUsage]] = [:]
        var copies: [String: Int] = [:]
        var order: [String] = []
        for var row in rows {
            let key = commands[row.pid]?.key ?? row.name
            row.command = key
            row.usersOwn = own.contains(row.pid)
            assigned.append(row)
            let ownerPid = owner[row.pid] ?? row.pid
            let groupKey = commands[ownerPid]?.key ?? key
            if members[groupKey] == nil { order.append(groupKey) }
            members[groupKey, default: []].append(row)
            if ownerPid == row.pid { copies[groupKey, default: 0] += 1 }
        }
        let groups = order.map { key in
            let rows = members[key] ?? []
            let totals = GroupTotals(rows)
            return CommandGroup(name: key, copies: copies[key] ?? 0, cpuPercent: totals.cpuPercent,
                                exitedChildrenCpuPercent: totals.exitedChildrenCpuPercent,
                                residentBytes: totals.residentBytes, disk: totals.disk, network: totals.network,
                                pids: treeOrder(rows).map(\.pid),
                                copyOf: rows.reduce(into: [:]) { copyOf, row in
                                    if let start = owner[row.pid], start != row.pid { copyOf[row.pid] = start }
                                })
        }
        return (assigned, groups.sorted(by: shownBefore))
    }

    /// Each row's owner pid (itself when it starts a copy), and the user's own shells and sessions, which no warning
    /// line counts or holds and no warning action touches (the gate's round 5; research 2026-10-25 § B, 2026-10-26
    /// pause scope): every login shell; every interactive agent — one with a controlling terminal that no script copy
    /// started, a login shell's script aside (a runaway started from a terminal hands its terminal to its agents); an
    /// own agent's direct children, its tool calls' shells or the filter in front of them; and the shell such a filter
    /// runs. That is the boundary: the interactive root and its launch wrappers, not their subtrees. What a tool call
    /// runs below it starts copies of its own, attached or not, and counts.
    ///
    /// A row's owner follows from its parent's: a script copy owns what it starts down to an agent, except below one of
    /// the user's own wrappers, where only the shell it runs stays its member. A row's ownership depends on its ancestors
    /// alone, so both are settled lazily upward. A parent missing from the rows, pid ≤ 1 for an agent, or a pid met twice
    /// on the climb (a ppid loop) ends it.
    static func ownership(_ rows: [ProcessUsage], byPid: [Int32: ProcessUsage],
                          commands: [Int32: (key: String, script: Bool, agent: Bool)],
                          argv: (Int32) -> [String]?) -> (owner: [Int32: Int32], own: Set<Int32>) {
        var owners: [Int32: Int32] = [:]
        var known: [Int32: Bool] = [:]
        func login(_ pid: Int32) -> Bool { byPid[pid].map { isLoginShell(name: $0.name, argv: argv(pid)) } ?? false }
        /// The shell a wrapper runs: a shell with no script of its own, started directly by `copy`.
        func wrapped(_ row: ProcessUsage, by copy: Int32) -> Bool {
            row.ppid == copy && interpreter(row.name) == .shell && commands[row.pid]?.script != true
        }
        func owner(_ pid: Int32) -> Int32 {
            if let value = owners[pid] { return value }
            owners[pid] = pid  // under way: a loop back to it ends there
            guard let row = byPid[pid] else { return pid }
            let parent = row.ppid == pid ? nil : byPid[row.ppid]
            let value: Int32
            if commands[pid]?.agent == true {
                // Wherever its parent goes, unless that parent is launchd (or missing): then its own group.
                value = parent.flatMap { $0.pid > 1 ? owner($0.pid) : nil } ?? pid
            } else if let parent, commands[parent.pid]?.agent != true {
                let parentOwner = owner(parent.pid)
                value = commands[parentOwner]?.script == true && (!own(parentOwner) || wrapped(row, by: parentOwner))
                    ? parentOwner : pid
            } else {
                value = pid
            }
            owners[pid] = value
            return value
        }
        func own(_ pid: Int32) -> Bool {
            if let value = known[pid] { return value }
            known[pid] = false  // under way: a loop back to it ends there
            guard let row = byPid[pid] else { return false }
            let copy = owner(pid)
            let value = if login(pid) {
                true
            } else if commands[pid]?.agent == true, row.terminal, copy == pid || commands[copy]?.script != true || login(copy) {
                true
            } else if copy != pid {
                wrapped(row, by: copy) && own(copy)
            } else {
                row.ppid > 1 && row.ppid != pid && commands[row.ppid]?.agent == true && own(row.ppid)
            }
            known[pid] = value
            return value
        }
        let mine = Set(rows.map(\.pid).filter(own))
        return (Dictionary(rows.map { ($0.pid, owner($0.pid)) }, uniquingKeysWith: { a, _ in a }), mine)
    }

    /// A group's rows depth-first: each row under its parent when the parent is in the group; roots (the copies,
    /// and a copy nested under a namesake it does not belong to stays under it) by their subtree's own + exited CPU,
    /// siblings by their own + exited, then pid, as the session tree (`SessionGroups.treeOrder`). A ppid loop is
    /// broken at its lowest pid so every row is placed once.
    static func treeOrder(_ rows: [ProcessUsage]) -> [ProcessUsage] {
        let pids = Set(rows.map(\.pid))
        let byCPU: (ProcessUsage, ProcessUsage) -> Bool = { ($0.totalCpuPercent, $1.pid) > ($1.totalCpuPercent, $0.pid) }
        let children = Dictionary(grouping: rows.filter { $0.ppid != $0.pid && pids.contains($0.ppid) }, by: \.ppid)
            .mapValues { $0.sorted(by: byCPU) }
        func subtree(_ row: ProcessUsage) -> [ProcessUsage] {
            var placed: Set<Int32> = []
            var out: [ProcessUsage] = []
            func visit(_ row: ProcessUsage) {
                guard placed.insert(row.pid).inserted else { return }
                out.append(row)
                for child in children[row.pid] ?? [] { visit(child) }
            }
            visit(row)
            return out
        }
        typealias Root = (pid: Int32, tree: [ProcessUsage], total: Double)
        let roots: [Root] = rows.filter { $0.ppid == $0.pid || !pids.contains($0.ppid) }.map { root in
            let tree = subtree(root)
            let total: Double = tree.map(\.totalCpuPercent).reduce(0, +)
            return (root.pid, tree, TextFormat.rounded(total))
        }.sorted { (a: Root, b: Root) in a.total != b.total ? a.total > b.total : a.pid < b.pid }
        var placed: Set<Int32> = []
        var out: [ProcessUsage] = []
        for entry in roots {
            for row in entry.tree where placed.insert(row.pid).inserted { out.append(row) }
        }
        for row in rows.sorted(by: { $0.pid < $1.pid }) where !placed.contains(row.pid) {
            for row in subtree(row) where placed.insert(row.pid).inserted { out.append(row) }
        }
        return out
    }

    /// Each row's parent pid, built once per table (the window's refresh, the CLI's sample) for every group's `depths`.
    static func parents(_ rows: [ProcessUsage]) -> [Int32: Int32] {
        WorkCount.current.get()?.add(parentMaps: 1)
        return Dictionary(rows.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
    }

    /// Each pid's depth in a group's tree, for the indented table: `pids` in tree order (`CommandGroup.pids`,
    /// `SessionGroup.pids`), so a parent's depth is known before its children's; a root's parent is in no group of its.
    static func depths(_ pids: [Int32], parents: [Int32: Int32]) -> [Int32: Int] {
        var depth: [Int32: Int] = [:]
        for pid in pids {
            depth[pid] = parents[pid].flatMap { depth[$0] }.map { $0 + 1 } ?? 0
        }
        return depth
    }

    /// By header total (one decimal, as shown), then name, then first pid.
    static func shownBefore(_ a: CommandGroup, _ b: CommandGroup) -> Bool {
        let (x, y) = (TextFormat.rounded(a.totalCpuPercent), TextFormat.rounded(b.totalCpuPercent))
        if x != y { return x > y }
        if a.name != b.name { return a.name < b.name }
        return (a.pids.first ?? 0) < (b.pids.first ?? 0)
    }
}

/// The work the tests bound by count rather than by clock (the gate's round 2: a wall-clock bound fails on a busy CI
/// runner): parent maps built for tables, rows indexed by the warnings. Counted only inside a test's
/// `WorkCount.current.withValue`; nil, and free, everywhere else.
final class WorkCount: @unchecked Sendable {
    static let current = TaskLocal<WorkCount?>(wrappedValue: nil)

    private let lock = NSLock()
    private var counts = (parentMaps: 0, indexedRows: 0)

    var parentMaps: Int { lock.withLock { counts.parentMaps } }
    var indexedRows: Int { lock.withLock { counts.indexedRows } }

    func add(parentMaps: Int = 0, indexedRows: Int = 0) {
        lock.withLock {
            counts.parentMaps += parentMaps
            counts.indexedRows += indexedRows
        }
    }
}
