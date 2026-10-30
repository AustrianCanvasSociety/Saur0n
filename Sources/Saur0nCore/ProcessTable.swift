// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The window's process table as pure lines (the user's mockup E): one line per group, its members under it,
/// "Unattributed CPU" last. Built each refresh from the same rows and groups the CLI prints, in the CLI's
/// order by default; SwiftUI keeps each line by its `id`, so a row that lives on is updated in place.
public enum ProcessTable {
    public enum Grouping: String, CaseIterable, Sendable {
        case repo, session, command
    }

    /// A process across refreshes: a reused pid with a new start time is a new row.
    public struct RowID: Hashable, Sendable {
        public let pid: Int32
        public let startMicroseconds: UInt64
    }

    public enum Column: String, Sendable {
        case pid, user, cpu, memory, disk, network, session, name
    }

    /// The value columns' widths in points, which the user drags (Backlog resizable-columns): today's fixed widths
    /// by default, each kept inside its limits. Name takes the rest of the table and never less than 148 pt, so the
    /// window's minimum width follows the sum and no sideways scroll bar appears (touchup 3).
    public struct ColumnWidths: Equatable, Sendable {
        public static let valueColumns: [Column] = [.pid, .user, .cpu, .memory, .disk, .network, .session]
        /// PID 40 (five digits), User 52, CPU 96 ("+0.7% exited" beside the figure), Memory 64 (its title beside a sort
        /// indicator), Disk and Network 64, Session 90.
        public static let defaults: [Column: Double] = [.pid: 40, .user: 52, .cpu: 96, .memory: 64, .disk: 64,
                                                        .network: 64, .session: 90]
        /// Narrow enough to hide what the user does not need, wide enough that the header still shows: Memory's
        /// 58 pt plus the table's 17 pt spacing is the 74 pt "Memory" needs beside a sort indicator.
        public static let limits: [Column: ClosedRange<Double>] = [
            .pid: 32...200, .user: 40...240, .cpu: 56...240, .memory: 58...200, .disk: 48...200, .network: 48...200,
            .session: 50...400,
        ]
        public static let nameFloor = 148.0
        /// What a row is wider than its columns: 17 pt of spacing for each of the eight columns and the outline
        /// column's 15 pt indentation, measured through accessibility (probe 2026-10-20), plus one point so a row never
        /// exceeds the view.
        public static let tableOverhead = 8 * 17 + 15 + 1.0
        /// The window's padding around the table, 16 pt a side.
        public static let windowPadding = 32.0

        private var widths: [Column: Double] = defaults

        public init() {}

        /// The widths `saved` holds (JSON, column name → points), each clamped to its limits; defaults for the rest,
        /// and for unreadable data.
        public init(saved: Data?) {
            guard let saved, let read = try? JSONDecoder().decode([String: Double].self, from: saved) else { return }
            for (key, width) in read { if let column = Column(rawValue: key) { set(column, width) } }
        }

        /// What `init(saved:)` reads back.
        public var saved: Data? {
            try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: widths.map { ($0.key.rawValue, $0.value) }))
        }

        public subscript(column: Column) -> Double { widths[column] ?? 0 }

        /// Sets a value column's width inside its limits; Name, which takes the remainder, is left alone.
        public mutating func set(_ column: Column, _ width: Double) {
            guard let limit = Self.limits[column] else { return }
            widths[column] = min(max(width, limit.lowerBound), limit.upperBound)
        }

        /// Name's right edge dragged to `wanted` in a table `tableWidth` wide (Backlog resizable-columns; the user,
        /// 2026-10-21: "name-PID does not work"): Name takes the remainder, so the value columns to its right give or
        /// take the difference evenly, each within its limits, a column at a limit leaving its share to the others — as
        /// AppKit's uniform column resizing does for the columns after a dragged one — and the table still fits.
        /// Name stays at or above its floor.
        public mutating func resizeName(to wanted: Double, tableWidth: Double) {
            var left = max(wanted, Self.nameFloor) - nameWidth(tableWidth: tableWidth)
            var free = Self.valueColumns
            while abs(left) > 1e-9, !free.isEmpty {
                let share = left / Double(free.count)
                var stillFree: [Column] = []
                for column in free {
                    let before = self[column]
                    set(column, before - share)
                    left -= before - self[column]
                    if self[column] == before - share { stillFree.append(column) }
                }
                free = stillFree
            }
        }

        /// The widest Name a drag can reach in a table `tableWidth` wide: every value column at its floor.
        public func nameWidthAtMost(tableWidth: Double) -> Double {
            let floors = Self.valueColumns.reduce(0) { $0 + (Self.limits[$1]?.lowerBound ?? 0) }
            return max(Self.nameFloor, tableWidth - floors - Self.tableOverhead)
        }

        public var total: Double { Self.valueColumns.reduce(0) { $0 + self[$1] } }

        /// Name's width in a table `tableWidth` wide.
        public func nameWidth(tableWidth: Double) -> Double {
            max(Self.nameFloor, tableWidth - total - Self.tableOverhead)
        }

        /// The narrowest window that still fits every column with Name at its floor: 802 pt at the defaults.
        public var windowMinWidth: Double { windowMinWidth(scroller: 0) }

        /// The same with a full-width vertical scroll bar `scroller` points wide beside the rows (macOS shows them while
        /// a mouse is connected, or always if the user chose so); overlay scroll bars take no width.
        public func windowMinWidth(scroller: Double) -> Double {
            total + Self.tableOverhead + Self.nameFloor + Self.windowPadding + scroller
        }
    }

    /// The column the table is sorted by. CPU, highest first, is the CLI's order.
    public struct Sort: Equatable, Sendable {
        public let column: Column
        public let ascending: Bool

        public init(column: Column, ascending: Bool) {
            self.column = column
            self.ascending = ascending
        }

        public static let cliOrder = Sort(column: .cpu, ascending: false)

        /// Name, PID, User and Session: values that do not move from one refresh to the next, so a refresh keeps the
        /// rows where they are (`lines(previous:)`); CPU, Memory, Disk and Network follow the figures.
        public var isFixed: Bool {
            switch column {
            case .name, .pid, .user, .session: true
            case .cpu, .memory, .disk, .network: false
            }
        }
    }

    public enum Kind: Sendable {
        case group, subgroup, process, unattributed
    }

    /// Which groups are open: each group's own default (repo and session groups open, catch-alls closed),
    /// or every group closed after Collapse all, or every group open after Expand all — groups that appear
    /// later follow the same rule — with the groups the user toggled since flipped from that base. A fold
    /// clears the toggles. Pure, so the window's button and the reader's checks share one rule.
    public struct Folding: Equatable, Sendable {
        public enum Mode: Sendable { case byDefault, allClosed, allOpen }

        public private(set) var mode = Mode.byDefault
        /// Group lines flipped from the base, by line id.
        public private(set) var toggled: Set<String> = []

        public init() {}

        public func isOpen(_ line: Line) -> Bool {
            let base = switch mode {
            case .byDefault: line.startsOpen
            case .allClosed: false
            case .allOpen: true
            }
            return base != toggled.contains(line.id)
        }

        public mutating func setOpen(_ line: Line, _ open: Bool) {
            guard open != isOpen(line) else { return }
            if toggled.contains(line.id) { toggled.remove(line.id) } else { toggled.insert(line.id) }
        }

        public mutating func collapseAll() { mode = .allClosed; toggled = [] }

        public mutating func expandAll() { mode = .allOpen; toggled = [] }

        /// Whether any group line is open: the button reads "Collapse all" then, "Expand all" otherwise.
        public func anyOpen(_ lines: [Line]) -> Bool { lines.contains { $0.kind == .group && isOpen($0) } }
    }

    public struct Line: Identifiable, Equatable, Sendable {
        /// Stable across refreshes: `group:<key>`, `subgroup:<group key>:app:<app>` /
        /// `subgroup:<group key>:command:<name>` / `subgroup:<group key>:other`,
        /// `process:<pid>:<start>`, `unattributed`.
        public let id: String
        /// The accessibility identifier `scripts/read-window.swift` reads: `group-<n>` (n = its place in the
        /// table, from 0), `subgroup-<n>-<m>` (m = its place among the group's sub-group lines, from 0),
        /// `process-<pid>`, `unattributed`; `gone-` before it on a greyed line.
        public internal(set) var identifier: String
        public let kind: Kind
        /// A group's title; a sub-group's app, command or "N other processes"; a process's raw name, escaped
        /// (`TextFormat.displaySafe`); "Unattributed CPU".
        public let name: String
        /// A process's app bundle (`ProcessUsage.app`); nil on other lines.
        public var app: String? = nil
        /// What the user calls it, with VM share and kernel_task's age; the age alone when unnamed.
        /// nil when neither a readable name nor an age is available; the unattributed line may carry its hint.
        public var readableName: String? = nil
        /// A linked worktree's folder name.
        public var worktree: String? = nil
        /// A process under launchd that does not lead its group (`ProcessUsage.orphaned`): its Name cell ends `[orphaned]`.
        public var orphaned = false
        /// Tree depth under its session (session view in the CLI's order); 0 otherwise.
        public var depth = 0
        /// A group's or sub-group's own + exited-children total; a process's own CPU; 0–100 of the whole machine.
        public let cpuPercent: Double
        /// A process's exited children (nil when unread); nil on other lines.
        public var exitedChildrenCpuPercent: Double? = nil
        /// What the CPU sort reads: a process's own + exited, `cpuPercent` on other lines, which already holds both.
        public var totalCpuPercent: Double { cpuPercent + (exitedChildrenCpuPercent ?? 0) }
        public var residentBytes: UInt64 = 0
        /// A process's disk rate (nil when its rusage is unreadable), a group's sum, the unattributed remainder.
        public var disk: DiskUsage? = nil
        /// A process's or a group's network rate; nil on the unattributed line, which has none (plan v2).
        public var network: NetworkUsage? = nil
        public var user: String? = nil
        public var pid: Int32? = nil
        /// A process line's pid and start time (the window's top movers key on it); nil on other lines.
        public var rowID: RowID? = nil
        public var session: String? = nil
        /// A group's or sub-group's process count; under a search, the processes shown (`filtered`).
        public var count: Int? = nil
        /// Under a search, a group's or sub-group's process count before the filter; nil otherwise.
        public var total: Int? = nil
        /// Groups open at launch: every repo and session group and the VMs; each grouping's two catch-alls, every
        /// sub-group and every command group (a few hundred on a machine) start closed (mockup E; Task Manager keeps an
        /// app's processes folded until opened).
        public var startsOpen = false
        public var children: [Line]? = nil
        /// A process the window paused and that still reads as stopped (Phase 5 Step 5): its row shows a "paused" badge.
        public var paused = false
        /// When a line whose process or group ended was first marked gone (`lines(now:)`'s clock); nil on a live line.
        /// Kept in place under a fixed sort for `goneSeconds`: its name greyed, its figures empty.
        public var goneSince: Double? = nil
        public var gone: Bool { goneSince != nil }
        /// On a group line, the warnings that pin it (their places in the engine's list, from 0); it then goes first
        /// under every sort and carries the warning badge (Phase 6 Step 6). Empty otherwise.
        public var warnings: [Int] = []

        /// Busy cells shaded by intensity (plan § Decisions, after Task Manager's Processes tab): 0 for none, else the
        /// step 1–4 the line's CPU (own + exited, share of the machine), Disk or Network figure reaches. Steps, not a
        /// value, so a cell redraws only when it crosses one. None on a greyed or the Unattributed line.
        public func shade(_ column: Column) -> Int {
            guard !gone, kind != .unattributed else { return 0 }
            let value: Double
            switch column {
            case .cpu: value = TextFormat.rounded(totalCpuPercent)
            case .disk: value = Double(diskBytesPerSecond)
            case .network: value = Double(networkBytesPerSecond)
            default: return 0
            }
            return ProcessTable.shadeSteps[column]?.lastIndex { value >= $0 }.map { $0 + 1 } ?? 0
        }

        /// A group's or sub-group's count as its Name cell shows it: "1 process", "12 processes", "3 of 12 processes"
        /// under a search.
        public var countText: String {
            let count = count ?? 0
            if let total { return "\(count) of \(total) process\(total == 1 ? "" : "es")" }
            return count == 1 ? "1 process" : "\(count) processes"
        }

        /// A process cell's accessibility identifier, `<prefix>-<pid>` (`name-42`, `cpu-42`); `gone-<prefix>-<pid>` on a
        /// greyed line, so a reused pid's live row and its greyed one never share one.
        public func cellIdentifier(_ prefix: String) -> String { (gone ? "gone-" : "") + "\(prefix)-\(pid ?? -1)" }

        /// The badge's accessibility identifier, `paused-<pid>`.
        public var pausedIdentifier: String { cellIdentifier("paused") }

        /// `42.3%`, as the CLI prints it.
        public var cpuText: String { gone ? "" : TextFormat.percentText(cpuPercent) }
        /// `+1.2% exited` when it shows above 0.0%, else empty (the CLI's EXITED cell).
        public var exitedText: String {
            guard !gone, let exited = exitedChildrenCpuPercent, TextFormat.rounded(exited) > 0 else { return "" }
            return "+\(TextFormat.percentText(exited)) exited"
        }
        public var memoryText: String { gone ? "" : ProcessSample.memoryText(residentBytes) }
        /// Read + write and in + out bytes per second: the Disk and Network columns' sort keys, 0 when unread.
        public var diskBytesPerSecond: UInt64 { disk?.rate.totalBytesPerSecond ?? 0 }
        public var networkBytesPerSecond: UInt64 { network?.rate.totalBytesPerSecond ?? 0 }
        /// `1.2 M/s`, as the CLI prints it; `—` for a process whose figure is unreadable; empty on the unattributed
        /// line without that figure.
        public var diskText: String { rateText(disk.map { $0.rate.totalBytesPerSecond }) }
        public var networkText: String { rateText(network.map { $0.rate.totalBytesPerSecond }) }

        func rateText(_ bytesPerSecond: UInt64?) -> String {
            guard !gone else { return "" }
            guard let bytesPerSecond else { return kind == .process ? "—" : "" }
            return TextFormat.bytesPerSecondText(bytesPerSecond)
        }
        /// Sort keys for the table's columns: "" / -1 where a line has no value.
        public var userText: String { user ?? "" }
        public var sessionText: String { session ?? "" }
        public var pidNumber: Int32 { pid ?? -1 }
    }

    public static func rowID(_ row: ProcessUsage) -> RowID { RowID(pid: row.pid, startMicroseconds: row.startMicroseconds) }

    /// Where each shading step starts: CPU in percent of the machine, Disk and Network in bytes a second (SI, as the
    /// cells show them). A first guess, tuned at the demo as the warning thresholds are.
    public static let shadeSteps: [Column: [Double]] = [.cpu: [5, 15, 30, 50],
                                                        .disk: [1e6, 10e6, 50e6, 200e6],
                                                        .network: [0.1e6, 1e6, 10e6, 50e6]]

    /// The table for `rows` under `grouping`'s groups (each from `RepoGroups.assign` / `SessionGroups.assign`,
    /// so already in the CLI's order), sorted by `sort`, then the unattributed line when given. `kernelTaskAge`
    /// (seconds since `top` read it) is added to kernel_task's readable name; the processes in `pausedPids` are marked
    /// paused. Under a fixed sort, `previous` (the table the last refresh built) keeps its order: lines that live on
    /// stay where they were, new ones take their sorted place, ended ones stay marked `gone` for `goneSeconds` from
    /// `now` (seconds on any steady clock) at the refresh that first marked them (`keepingOrder`). The groups that
    /// `warnings` pin go first under every sort, in the warnings' order (`pins`). `unattributedHint` (`Snapshot.unattributedHint`)
    /// is the unattributed line's readable name.
    public static func lines(rows: [ProcessUsage], repoGroups: [RepoGroup], sessionGroups: [SessionGroup],
                             commandGroups: [CommandGroup] = [], grouping: Grouping, sort: Sort = .cliOrder, unattributedCpuPercent: Double?,
                             unattributedHint: String? = nil, unattributedDisk: DiskRate? = nil, kernelTaskAge: Int? = nil,
                             pausedPids: Set<Int32> = [], now: Double = 0, previous: [Line] = [],
                             warnings: [Warning] = []) -> [Line] {
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func member(_ row: ProcessUsage, depth: Int) -> Line {
            var readable = ProcessSample.readableText(row)
            if row.pid == 0, let kernelTaskAge { readable = (readable.map { $0 + " · " } ?? "") + "read \(kernelTaskAge) s ago" }
            let key = rowID(row)
            var line = Line(id: "process:\(key.pid):\(key.startMicroseconds)", identifier: "process-\(row.pid)", kind: .process,
                        name: TextFormat.displaySafe(row.name), app: row.app, readableName: readable.map(TextFormat.displaySafe),
                        worktree: row.repo?.worktree.map { TextFormat.displaySafe(RepoResolver.basename($0)) },
                        orphaned: row.orphaned, depth: depth, cpuPercent: row.cpuPercent, exitedChildrenCpuPercent: row.exitedChildrenCpuPercent,
                        residentBytes: row.residentBytes, disk: row.disk, network: row.network,
                        user: TextFormat.displaySafe(row.user), pid: row.pid, rowID: key,
                        session: row.session.map { TextFormat.displaySafe($0.name) })
            line.paused = pausedPids.contains(row.pid)
            return line
        }
        /// `rank`: 0 a repo or session, 1 the VMs, 2 a catch-all — the order a header sort keeps.
        typealias Section = (key: String, name: String, title: String, total: Double, bytes: UInt64, disk: DiskUsage,
                             network: NetworkUsage, pids: [Int32], depths: [Int32: Int], rank: Int,
                             subgroups: [CatchAllBreakout.Subgroup])
        let sections: [Section]
        // One parent map for every group's depths, which only the CLI order shows.
        let parents = sort == .cliOrder && grouping != .repo ? CommandGroups.parents(rows) : [:]
        switch grouping {
        case .repo:
            sections = zip(repoGroups, ProcessSample.titles(repoGroups)).map { group, title in
                let rank = group.root != nil ? 0 : group.name == RepoGroups.vms ? 1 : 2
                return (group.root.map { "repo:" + $0 } ?? (rank == 1 ? "vms" : "catch-all:" + group.name), group.name,
                        title, group.totalCpuPercent, group.residentBytes, group.disk, group.network, group.pids, [:],
                        rank, group.subgroups)
            }
        case .session:
            sections = zip(sessionGroups, ProcessSample.titles(sessionGroups)).map { group, title in
                let rank = group.kind != nil ? 0 : group.name == SessionGroups.vms ? 1 : 2
                return (group.kind.map { "\($0.rawValue):\(group.id ?? "")" } ?? (rank == 1 ? "vms" : "catch-all:" + group.name),
                        group.name, title, group.totalCpuPercent, group.residentBytes, group.disk, group.network,
                        group.pids,
                        sort == .cliOrder && group.subgroups.isEmpty ? CommandGroups.depths(group.pids, parents: parents) : [:],
                        rank,
                        group.subgroups)
            }
        case .command:
            // No catch-alls and no VMs group: every group is a command, sorted by the column under a header sort.
            sections = commandGroups.map { group in
                ("command:" + group.name, group.name, TextFormat.copiesTitle(name: group.name, copies: group.copies),
                 group.totalCpuPercent, group.residentBytes, group.disk, group.network, group.pids,
                 sort == .cliOrder ? CommandGroups.depths(group.pids, parents: parents) : [:], 0, [])
            }
        }
        // Which section each warning pins: in its own grouping its group by name, else (or when that is not shown) the
        // section holding its busiest process; the Machine line none (plan § Decisions: "a warned group pins to the top").
        var pins: [String: [Int]] = [:]
        for (i, warning) in warnings.enumerated() {
            let own: Section? = switch (warning.subject, grouping) {
            case (.command(let key), .command): sections.first { $0.key == "command:" + key }
            case (.repo(let name), .repo), (.session(let name), .session): sections.first { $0.rank == 0 && $0.name == name }
            default: nil
            }
            guard warning.subject != .machine,
                  let section = own ?? warning.heaviest.flatMap({ pid in sections.first { $0.pids.contains(pid) } })
            else { continue }
            pins[section.key, default: []].append(i)
        }
        /// `lines` in the CLI's order, or by the column under a header sort, `last` kept at the end.
        func sorted(_ lines: [Line], keepingLast last: Line? = nil) -> [Line] {
            guard sort != .cliOrder else { return lines + (last.map { [$0] } ?? []) }
            return lines.enumerated().sorted { ordered($0.element, $1.element, by: sort, tie: $0.offset < $1.offset) }
                .map(\.element) + (last.map { [$0] } ?? [])
        }
        func subgroupLine(_ subgroup: CatchAllBreakout.Subgroup, groupKey: String) -> Line {
            let members = subgroup.pids.compactMap { byPid[$0].map { member($0, depth: 0) } }
            return Line(id: "subgroup:\(groupKey):" + (subgroup.kind == .other ? "other" : "\(subgroup.kind.rawValue):\(subgroup.name)"),
                        identifier: "", kind: .subgroup, name: TextFormat.displaySafe(subgroup.name),
                        cpuPercent: subgroup.totalCpuPercent, residentBytes: subgroup.residentBytes, disk: subgroup.disk,
                        network: subgroup.network, count: subgroup.pids.count, startsOpen: false,
                        children: sort == .cliOrder ? members : members.sorted { ordered($0, $1, by: sort) })
        }
        var groups = sections.map { section in
            var children: [Line]
            if section.subgroups.isEmpty {
                children = section.pids.compactMap { pid in byPid[pid].map { member($0, depth: section.depths[pid] ?? 0) } }
                if sort != .cliOrder { children.sort { ordered($0, $1, by: sort) } }
            } else {
                // A catch-all: its lifted sub-groups and bare rows, then the other line, which a sort keeps last.
                var lifted: [Line] = [], other: Line?
                for entry in CatchAllBreakout.entries(pids: section.pids, subgroups: section.subgroups) {
                    switch entry {
                    case .process(let pid): if let row = byPid[pid] { lifted.append(member(row, depth: 0)) }
                    case .subgroup(let subgroup) where subgroup.kind == .other:
                        other = subgroupLine(subgroup, groupKey: section.key)
                    case .subgroup(let subgroup): lifted.append(subgroupLine(subgroup, groupKey: section.key))
                    }
                }
                children = sorted(lifted, keepingLast: other)
            }
            var line = Line(id: "group:\(section.key)", identifier: "", kind: .group, name: section.title,
                            cpuPercent: section.total, residentBytes: section.bytes, disk: section.disk,
                            network: section.network, count: section.pids.count,
                            startsOpen: section.rank < 2 && grouping != .command, children: children)
            line.warnings = pins[section.key] ?? []
            return (rank: section.rank, line: line)
        }
        if sort != .cliOrder {
            // The VMs then the catch-alls stay last, as the CLI lists them; the repos or sessions go by the column.
            groups = groups.enumerated().sorted { a, b in
                if a.element.rank != b.element.rank { return a.element.rank < b.element.rank }
                if a.element.rank > 0 { return a.offset < b.offset }
                return ordered(a.element.line, b.element.line, by: sort, tie: a.offset < b.offset)
            }.map(\.element)
        }
        var groupLines = groups.map(\.line)
        if sort.isFixed {
            groupLines = keepingOrder(groupLines, previous: previous.filter { $0.kind != .unattributed }, now: now)
        }
        if !pins.isEmpty {
            let pinned = groupLines.filter { !$0.warnings.isEmpty }.sorted { ($0.warnings.first ?? 0) < ($1.warnings.first ?? 0) }
            groupLines = pinned + groupLines.filter { $0.warnings.isEmpty }
        }
        var out = groupLines.enumerated().map { n, line in
            var line = line
            line.identifier = (line.gone ? "gone-" : "") + "group-\(n)"
            var m = 0
            line.children = line.children?.map { child in
                guard child.kind == .subgroup else { return child }
                var child = child
                child.identifier = (child.gone ? "gone-" : "") + "subgroup-\(n)-\(m)"
                m += 1
                return child
            }
            return line
        }
        if let unattributedCpuPercent {
            out.append(Line(id: "unattributed", identifier: "unattributed", kind: .unattributed, name: "Unattributed CPU",
                            readableName: unattributedHint, cpuPercent: unattributedCpuPercent,
                            disk: unattributedDisk.map { DiskUsage(rate: $0, bytes: .zero) }))
        }
        return out
    }

    /// How long a greyed line stays: the graphs' minute.
    public static let goneSeconds: Double = 60

    /// `lines` (sorted) in `previous`'s order, at this level and under each line: a line still shown keeps its place
    /// and takes its new figures; one that ended stays where it was, marked `gone` with everything under it, until
    /// `goneSeconds` after `now` first marked it; a new one goes after the line it follows in `lines`, or first. With
    /// no `previous`, `lines` as they are. Greyed means ended: a line shown anywhere in `lines` (a process that moved
    /// group or sub-group) leaves no greyed copy, nor does a group with nothing greyed left under it. A sub-group never
    /// stays greyed: it also leaves when its app drops under the lift and folds into "N other processes" while still
    /// running (round 3 of the Phase 5 gate), so it leaves at once, with what ended under it.
    static func keepingOrder(_ lines: [Line], previous: [Line], now: Double) -> [Line] {
        func ids(_ lines: [Line]) -> [String] { lines.flatMap { [$0.id] + ids($0.children ?? []) } }
        return keepingOrder(lines, previous: previous, now: now, shown: Set(ids(lines)))
    }

    private static func keepingOrder(_ lines: [Line], previous: [Line], now: Double, shown: Set<String>) -> [Line] {
        guard !previous.isEmpty else { return lines }
        let current = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func gone(_ line: Line) -> Line? {
            let since = line.goneSince ?? now
            guard line.kind != .subgroup, !shown.contains(line.id), now - since < goneSeconds else { return nil }
            var line = line
            line.goneSince = since
            line.paused = false
            line.warnings = []
            if !line.identifier.hasPrefix("gone-") { line.identifier = "gone-" + line.identifier }
            if let children = line.children {
                line.children = children.compactMap(gone)
                if line.children?.isEmpty == true { return nil }
            }
            return line
        }
        var out = previous.compactMap { old in
            guard var line = current[old.id] else { return gone(old) }
            if let children = line.children {
                line.children = keepingOrder(children, previous: old.children ?? [], now: now, shown: shown)
            }
            return line
        }
        var placed = Set(out.map(\.id))
        for (i, line) in lines.enumerated() where !placed.contains(line.id) {
            let after = lines[..<i].last { placed.contains($0.id) }.flatMap { a in out.firstIndex { $0.id == a.id } }
            out.insert(line, at: after.map { $0 + 1 } ?? 0)
            placed.insert(line.id)
        }
        return out
    }

    /// The toolbar's search: the process lines whose name, readable name, pid, user, session, group title or sub-group
    /// name contains `text` (case-insensitive), under their group and sub-group lines, each counted "N of M"; a group
    /// or sub-group without a match is dropped, as is the unattributed line unless its name matches. Blank text keeps
    /// `lines` as they are.
    public static func filtered(_ lines: [Line], by text: String) -> [Line] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return lines }
        func has(_ value: String?) -> Bool { value?.range(of: needle, options: .caseInsensitive) != nil }
        /// `line` with only its matching processes, or nil; `titled` says a title above it already matched.
        func keep(_ line: Line, titled: Bool) -> Line? {
            switch line.kind {
            case .process:
                // A greyed line is no match: it ended (round 2 of the Phase 5 gate read "2 of 1 process").
                guard !line.gone else { return nil }
                let pid = line.pid.map(String.init)
                return titled || [line.name, line.readableName, pid, line.user, line.session].contains(where: has) ? line : nil
            case .unattributed:
                return has(line.name) ? line : nil
            case .group, .subgroup:
                let children = (line.children ?? []).compactMap { keep($0, titled: titled || has(line.name)) }
                guard !children.isEmpty else { return nil }
                var line = line
                line.total = line.count
                line.count = children.reduce(0) { $0 + ($1.kind == .process ? 1 : $1.count ?? 0) }
                line.children = children
                return line
            }
        }
        return lines.compactMap { keep($0, titled: false) }
    }

    /// The process lines under `line` (itself, for a process line) that are not greyed: what Quit, Force Quit, Pause and
    /// Resume act on. Empty for a line with only greyed lines under it, so its buttons are off.
    public static func liveProcesses(_ line: Line) -> [Line] {
        if line.kind == .process { return line.gone ? [] : [line] }
        return (line.children ?? []).flatMap(liveProcesses)
    }

    /// Each group line with every process under it as its children, sub-group lines dropped: what the strips read
    /// (`TopMovers.rows`), so a process under a catch-all's sub-group is still counted under its group's title.
    public static func flattened(_ lines: [Line]) -> [Line] {
        func processes(_ lines: [Line]) -> [Line] {
            lines.flatMap { $0.kind == .subgroup ? processes($0.children ?? []) : [$0] }
        }
        return lines.map { line in
            var line = line
            line.children = line.children.map(processes)
            return line
        }
    }

    /// Whether `a` goes before `b` under `sort`. Lines equal on the column tie on `tie` when given (group lines:
    /// their CLI order, which also covers PID, User and Session, where a group has no value), else on pid.
    static func ordered(_ a: Line, _ b: Line, by sort: Sort, tie: Bool? = nil) -> Bool {
        func compare<T: Comparable>(_ x: T, _ y: T) -> Bool? { x == y ? nil : (sort.ascending ? x < y : x > y) }
        let decided: Bool?
        switch sort.column {
        case .cpu: decided = compare(TextFormat.rounded(a.totalCpuPercent), TextFormat.rounded(b.totalCpuPercent))
        case .memory: decided = compare(a.residentBytes, b.residentBytes)
        case .disk: decided = compare(a.diskBytesPerSecond, b.diskBytesPerSecond)
        case .network: decided = compare(a.networkBytesPerSecond, b.networkBytesPerSecond)
        case .name: decided = compare(a.name.lowercased(), b.name.lowercased())
        case .user: decided = compare(a.user ?? "", b.user ?? "")
        case .session: decided = compare(a.session ?? "", b.session ?? "")
        case .pid: decided = compare(a.pid ?? -1, b.pid ?? -1)
        }
        if let decided { return decided }
        if let tie { return tie }
        return (a.pid ?? -1) < (b.pid ?? -1)
    }
}
