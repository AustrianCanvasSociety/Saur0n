// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The strip under the window's Disk or Network graph: the `count` processes that moved the most bytes over the
/// last `window` refreshes (the user's "strip", 2026-10-20), fed one tick a refresh with each row's bytes in
/// that second. A process is its `ProcessTable.RowID`, so a reused pid is a new mover; one that exited keeps its
/// bytes, under the name and group of its last tick, until they age out. Pure: the window keeps one per column
/// and grouping.
public struct TopMovers: Equatable, Sendable {
    /// One minute at one refresh a second, as the graphs above the strips.
    public static let window = CPUHistory.capacity
    public static let count = 5

    /// A row as the strip shows it: as a tick's input, `bytes` is that second's; from `top()`, the minute's.
    public struct Mover: Equatable, Sendable {
        public let id: ProcessTable.RowID
        public let name: String
        public let readableName: String?
        /// Its group's title as the table shows it under the current grouping.
        public let group: String
        public let bytes: UInt64

        public init(id: ProcessTable.RowID, name: String, readableName: String?, group: String, bytes: UInt64) {
            self.id = id
            self.name = name
            self.readableName = readableName
            self.group = group
            self.bytes = bytes
        }
    }

    /// Each kept tick's non-zero bytes, oldest first.
    private var ticks: [[ProcessTable.RowID: UInt64]] = []
    /// The kept ticks summed per row, and each summed row as its last tick named it.
    private var sums: [ProcessTable.RowID: UInt64] = [:]
    private var labels: [ProcessTable.RowID: Mover] = [:]

    public init() {}

    /// Records one refresh. A row absent from it adds 0; every call counts toward the window, an empty one too.
    public mutating func tick(_ rows: [Mover]) {
        var bytes: [ProcessTable.RowID: UInt64] = [:]
        for row in rows {
            if row.bytes > 0 { bytes[row.id, default: 0] &+= row.bytes }
            if row.bytes > 0 || sums[row.id] != nil { labels[row.id] = row }
        }
        for (id, value) in bytes { sums[id, default: 0] &+= value }
        ticks.append(bytes)
        if ticks.count > Self.window {
            for (id, value) in ticks.removeFirst() {
                let left = (sums[id] ?? 0) &- value
                if left == 0 {
                    sums[id] = nil
                    labels[id] = nil
                } else {
                    sums[id] = left
                }
            }
        }
    }

    /// One tick's input from the table's lines: each process line under its group line's title, with its `rate`
    /// times the tick's `seconds` as its bytes. The refresh sleeps a second after its reads, so a tick is a little
    /// longer than one; counting a second would lose the rest from the minute.
    public static func rows(_ lines: [ProcessTable.Line], seconds: Double = 1,
                            rate: (ProcessTable.Line) -> UInt64) -> [Mover] {
        lines.flatMap { group in
            (group.children ?? []).compactMap { line in
                line.rowID.map { Mover(id: $0, name: line.name, readableName: line.readableName, group: group.name,
                                       bytes: ProcessSample.roundedUInt64(Double(rate(line)) * max(0, seconds)) ?? 0) }
            }
        }
    }

    /// The Memory graph's strip: the `count` largest processes now by `size` (resident memory), under their group
    /// lines' titles, as `top()` orders them; none with 0 bytes. Pass flattened lines, so sub-groups' members count.
    public static func largest(_ lines: [ProcessTable.Line], by size: (ProcessTable.Line) -> UInt64) -> [Mover] {
        ranked(rows(lines, rate: size).filter { $0.bytes > 0 }, bytes: \.bytes, id: \.id)
    }

    /// The minute's top movers: bytes descending, then pid ascending; none with 0 bytes.
    public func top() -> [Mover] {
        Self.ranked(sums, bytes: \.value, id: \.key).compactMap { id, bytes in
            labels[id].map { Mover(id: id, name: $0.name, readableName: $0.readableName, group: $0.group, bytes: bytes) }
        }
    }

    private static func ranked<Rows: Sequence>(_ rows: Rows, bytes: (Rows.Element) -> UInt64,
                                               id: (Rows.Element) -> ProcessTable.RowID) -> [Rows.Element] {
        Array(rows.sorted { a, b in
            if bytes(a) != bytes(b) { return bytes(a) > bytes(b) }
            if id(a).pid != id(b).pid { return id(a).pid < id(b).pid }
            return id(a).startMicroseconds < id(b).startMicroseconds
        }.prefix(count))
    }
}
