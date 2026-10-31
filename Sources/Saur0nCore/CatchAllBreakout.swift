// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What the catch-alls ("Not in a repo", "No session", "System and other users") show of what they hold (Phase 5
/// Step 4, research § Q3): processes under one outermost `.app` fold under one sub-group line named after the app,
/// as Task Manager folds an app's helpers; two or more processes in no app with one command key (the process name,
/// or the script a shell or interpreter runs: `CommandGroups.key`, Phase 6 Step 4) fold under one sub-group line
/// named after it, the copies of one command (Phase 6 Step 3), as Task Manager and Activity Monitor go by process
/// name; a sub-group or a bare process that holds at least 1% of the machine's memory, CPU (own +
/// exited), disk or network rate stands on its own line; everything else folds under one "N other processes" line.
/// Shares of the machine, not sizes, so one rule fits a 16 GB Air and a 128 GB Pro. The CLI and the window call it
/// once after the groups are made; application metadata is read at most once per candidate bundle per call.
public enum CatchAllBreakout {
    /// The machine's totals the lift is measured against. CPU needs none: 100% is the whole machine.
    public struct Thresholds: Equatable, Sendable {
        public let physicalMemoryBytes: UInt64
        /// The machine's read + write and in + out per second over the last tick; nil when unread (the lift then
        /// ignores that column).
        public let machineDiskBytesPerSecond: UInt64?
        public let machineNetworkBytesPerSecond: UInt64?

        public init(physicalMemoryBytes: UInt64, machineDiskBytesPerSecond: UInt64?, machineNetworkBytesPerSecond: UInt64?) {
            self.physicalMemoryBytes = physicalMemoryBytes
            self.machineDiskBytesPerSecond = machineDiskBytesPerSecond
            self.machineNetworkBytesPerSecond = machineNetworkBytesPerSecond
        }
    }

    /// One line under a catch-all: an app's processes, the copies of one command, or the folded rest.
    public struct Subgroup: Equatable, Sendable {
        public enum Kind: String, Sendable { case app, command, other }

        /// The app's name, the command's key, or "N other processes".
        public let name: String
        public let kind: Kind
        public let cpuPercent: Double
        public let exitedChildrenCpuPercent: Double
        public let residentBytes: UInt64
        public let disk: DiskUsage
        public let network: NetworkUsage
        /// In the group's order.
        public let pids: [Int32]

        /// What the line shows, as `RepoGroup.totalCpuPercent`.
        public var totalCpuPercent: Double { cpuPercent + exitedChildrenCpuPercent }
    }
}

extension CatchAllBreakout.Subgroup: Encodable {
    enum CodingKeys: String, CodingKey {
        case name, kind, cpuPercent, exitedChildrenCpuPercent, residentBytes, disk, network, pids
    }

    /// The group's shape: CPU figures to two decimals.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(TextFormat.rounded(cpuPercent, places: 2), forKey: .cpuPercent)
        try container.encode(TextFormat.rounded(exitedChildrenCpuPercent, places: 2), forKey: .exitedChildrenCpuPercent)
        try container.encode(residentBytes, forKey: .residentBytes)
        try container.encode(disk, forKey: .disk)
        try container.encode(network, forKey: .network)
        try container.encode(pids, forKey: .pids)
    }
}

extension CatchAllBreakout {

    /// The outermost application bundle, without its case-insensitive suffix. A nested helper belongs to the outer
    /// app; an ordinary folder named `.app` does not qualify without application metadata.
    public static func appName(ofPath path: String?) -> String? {
        appName(ofPath: path, isAppBundle: isApplicationBundle)
    }

    static func appName(ofPath path: String?, isAppBundle: (String) -> Bool) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/")
        for index in parts.indices where parts[index].count > 4 && parts[index].lowercased().hasSuffix(".app") {
            let root = "/" + parts[...index].joined(separator: "/")
            if isAppBundle(root) { return String(parts[index].dropLast(4)) }
        }
        return nil
    }

    private static func isApplicationBundle(_ root: String) -> Bool {
        guard let info = DescriptionSources.plistDictionary(root + "/Contents/Info.plist"),
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty else { return false }
        // Apple permits an absent package type, inferred from the extension, but an explicit non-app type is not one.
        return info["CFBundlePackageType"] == nil || info["CFBundlePackageType"] as? String == "APPL"
    }

    /// Whether figures stand on their own line: the shown CPU (one decimal) at least 1.0%, or the memory at least 1%
    /// of the machine's, or a disk or network rate above 0 at least 1% of the machine's same rate (a machine rate
    /// that is nil or 0 lifts nothing by that column).
    public static func lifted(cpuPercent: Double, residentBytes: UInt64, diskBytesPerSecond: UInt64?,
                              networkBytesPerSecond: UInt64?, thresholds: Thresholds) -> Bool {
        func share(_ part: UInt64?, of whole: UInt64?) -> Bool {
            guard let part, let whole, part > 0, whole > 0 else { return false }
            return Double(part) * 100 >= Double(whole)
        }
        return TextFormat.rounded(cpuPercent) >= 1
            || share(residentBytes, of: thresholds.physicalMemoryBytes)
            || share(diskBytesPerSecond, of: thresholds.machineDiskBytesPerSecond)
            || share(networkBytesPerSecond, of: thresholds.machineNetworkBytesPerSecond)
    }

    /// Sets each row's `app` and each catch-all's `subgroups`, and reorders a catch-all's `pids`: the lifted app and
    /// command sub-groups and bare rows first, by shown CPU (highest first), then name; then the other sub-group's. Inside a
    /// sub-group the group's own order holds (by CPU in the repo view, tree order in the session view). Repo,
    /// session and VMs groups keep `subgroups` empty.
    public static func apply(rows: [ProcessUsage], repoGroups: [RepoGroup], sessionGroups: [SessionGroup],
                             thresholds: Thresholds) -> (rows: [ProcessUsage], repoGroups: [RepoGroup], sessionGroups: [SessionGroup]) {
        apply(rows: rows, repoGroups: repoGroups, sessionGroups: sessionGroups, thresholds: thresholds,
              isAppBundle: isApplicationBundle)
    }

    static func apply(rows: [ProcessUsage], repoGroups: [RepoGroup], sessionGroups: [SessionGroup],
                      thresholds: Thresholds, isAppBundle: (String) -> Bool)
        -> (rows: [ProcessUsage], repoGroups: [RepoGroup], sessionGroups: [SessionGroup]) {
        var bundles: [String: Bool] = [:]
        let rows = rows.map { row in
            var row = row
            row.app = appName(ofPath: row.path) { root in
                if let cached = bundles[root] { return cached }
                let valid = isAppBundle(root)
                bundles[root] = valid
                return valid
            }
            return row
        }
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let repo = repoGroups.map { group in
            guard group.root == nil, group.name != RepoGroups.vms else { return group }
            var group = group
            (group.subgroups, group.pids) = breakOut(group.pids, byPid: byPid, thresholds: thresholds)
            return group
        }
        let session = sessionGroups.map { group in
            guard group.kind == nil, group.name != SessionGroups.vms else { return group }
            var group = group
            (group.subgroups, group.pids) = breakOut(group.pids, byPid: byPid, thresholds: thresholds)
            return group
        }
        return (rows, repo, session)
    }

    /// One catch-all's sub-groups and its reordered pids.
    static func breakOut(_ pids: [Int32], byPid: [Int32: ProcessUsage],
                         thresholds: Thresholds) -> (subgroups: [Subgroup], pids: [Int32]) {
        // Each app's rows, or the rows in no app under one command key (`CommandGroups.assign`; the process name when
        // unset), in the group's order of first appearance.
        var entries: [(app: String?, rows: [ProcessUsage])] = []
        var index: [String: Int] = [:]
        for row in pids.compactMap({ byPid[$0] }) {
            let key = row.app.map { "app:" + $0 } ?? "command:" + (row.command ?? row.name)
            if let i = index[key] {
                entries[i].rows.append(row)
            } else {
                index[key] = entries.count
                entries.append((row.app, [row]))
            }
        }
        // A command's one process is a bare row (nil), as before; two or more are its copies.
        let kinds: [Subgroup.Kind?] = entries.map { entry in
            if entry.app != nil { return .app }
            return entry.rows.count > 1 ? .command : nil
        }
        let sums = entries.indices.map {
            summed(name: entries[$0].app ?? entries[$0].rows[0].command ?? entries[$0].rows[0].name,
                   kind: kinds[$0] ?? .command, entries[$0].rows)
        }
        let up = sums.indices.filter { i in
            lifted(cpuPercent: sums[i].totalCpuPercent, residentBytes: sums[i].residentBytes,
                   diskBytesPerSecond: sums[i].disk.rate.totalBytesPerSecond,
                   networkBytesPerSecond: sums[i].network.rate.totalBytesPerSecond, thresholds: thresholds)
        }.sorted { a, b in
            let (x, y) = (TextFormat.rounded(sums[a].totalCpuPercent), TextFormat.rounded(sums[b].totalCpuPercent))
            if x != y { return x > y }
            if sums[a].name != sums[b].name { return sums[a].name < sums[b].name }
            return a < b
        }
        let liftedPids = Set(up.flatMap { sums[$0].pids })
        let folded = pids.filter { byPid[$0] != nil && !liftedPids.contains($0) }
        var subgroups = up.filter { kinds[$0] != nil }.map { sums[$0] }
        if !folded.isEmpty {
            let name = folded.count == 1 ? "1 other process" : "\(folded.count) other processes"
            subgroups.append(summed(name: name, kind: .other, folded.compactMap { byPid[$0] }))
        }
        return (subgroups, up.flatMap { sums[$0].pids } + folded)
    }

    /// One line directly under a catch-all: a sub-group, or a lifted bare process.
    public enum Entry: Equatable, Sendable {
        case subgroup(Subgroup)
        case process(Int32)
    }

    /// What sits directly under a group, in its `pids` order: each sub-group where its first pid falls, each lifted bare
    /// pid on its own, the other line last. A group without sub-groups lists its pids.
    public static func entries(pids: [Int32], subgroups: [Subgroup]) -> [Entry] {
        guard !subgroups.isEmpty else { return pids.map(Entry.process) }
        var owner: [Int32: Int] = [:]
        for (i, subgroup) in subgroups.enumerated() {
            for pid in subgroup.pids { owner[pid] = i }
        }
        var shown: Set<Int> = []
        var out: [Entry] = []
        for pid in pids {
            guard let i = owner[pid] else {
                out.append(.process(pid))
                continue
            }
            if subgroups[i].kind != .other, shown.insert(i).inserted { out.append(.subgroup(subgroups[i])) }
        }
        out += subgroups.filter { $0.kind == .other }.map(Entry.subgroup)
        return out
    }

    /// An app's or the other line's rows summed, as `RepoGroups.assign` sums a group.
    static func summed(name: String, kind: Subgroup.Kind, _ rows: [ProcessUsage]) -> Subgroup {
        Subgroup(name: name, kind: kind, cpuPercent: rows.map(\.cpuPercent).reduce(0, +),
                 exitedChildrenCpuPercent: rows.compactMap(\.exitedChildrenCpuPercent).reduce(0, +),
                 residentBytes: rows.map(\.residentBytes).reduce(0, &+),
                 disk: DiskActivity.sum(rows.map(\.disk)), network: NetworkActivity.sum(rows.map(\.network)),
                 pids: rows.map(\.pid))
    }
}
