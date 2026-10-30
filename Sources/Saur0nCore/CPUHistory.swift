// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Turns successive tick reads into loads: each read closes one interval and opens the next, so a refresh
/// costs one read.
public struct TickSampler: Sendable {
    var last: [CPUTicks]?

    public init() {}

    /// nil on the first read (no interval yet); afterwards the load since the previous read.
    public mutating func next(_ ticks: [CPUTicks]) throws -> CPULoad? {
        defer { last = ticks }
        guard let last else { return nil }
        return try CPULoad.compute(before: last, after: ticks)
    }
}

/// The window's load reads: retry topology after any failure and start a fresh interval on recovery.
public struct LoadSampler: Sendable {
    public private(set) var topology: CoreTopology?
    private var sampler = TickSampler()

    public init() {}

    /// A failed read throws for this tick only. The next call reads topology again; its ticks open a new window.
    public mutating func next(topology readTopology: () throws -> CoreTopology,
                              ticks readTicks: () throws -> [CPUTicks]) throws -> CPULoad? {
        do {
            let topology = try topology ?? readTopology()
            let ticks = try readTicks()
            let count = topology.cpusByLevel.joined().count
            guard ticks.count == count, topology.cpusByLevel.joined().allSatisfy(ticks.indices.contains) else {
                throw CPULoadError.topologyMismatch(topologyCPUs: count, sampledCPUs: ticks.count)
            }
            let load = try sampler.next(ticks)
            self.topology = topology
            return load
        } catch {
            topology = nil
            sampler = TickSampler()
            throw error
        }
    }
}

/// The last `capacity` loads, per CPU, per core type (the mean of its CPUs) and for the whole machine:
/// what the window's graphs and strips draw. Oldest point first.
public struct CPUHistory: Equatable, Sendable {
    /// One point a second: 60 seconds, as Task Manager's per-processor graphs (research 2026-10-19 Q3).
    public static let capacity = 60

    public let topology: CoreTopology
    /// `perCPU[n]` is CPU n's series.
    public private(set) var perCPU: [[Double]]
    /// `perLevel[i]` is `topology.levels[i]`'s series.
    public private(set) var perLevel: [[Double]]
    public private(set) var total: [Double] = []
    public private(set) var latest: CPULoad?

    public init(topology: CoreTopology) {
        self.topology = topology
        perCPU = Array(repeating: [], count: topology.cpusByLevel.joined().count)
        perLevel = Array(repeating: [], count: topology.levels.count)
    }

    /// Adds one point to every series. A load that does not cover the topology's CPUs is an error and
    /// changes nothing.
    public mutating func append(_ load: CPULoad) throws {
        guard load.perCPU.count == perCPU.count,
              topology.cpusByLevel.joined().allSatisfy(load.perCPU.indices.contains) else {
            throw CPULoadError.topologyMismatch(topologyCPUs: perCPU.count, sampledCPUs: load.perCPU.count)
        }
        for cpu in perCPU.indices { Self.push(load.perCPU[cpu], onto: &perCPU[cpu]) }
        for (i, cpus) in topology.cpusByLevel.enumerated() {
            let average = cpus.isEmpty ? 0 : cpus.map { load.perCPU[$0] }.reduce(0, +) / Double(cpus.count)
            Self.push(average, onto: &perLevel[i])
        }
        Self.push(load.total, onto: &total)
        latest = load
    }

    static func push<Value>(_ value: Value, onto series: inout [Value]) {
        series.append(value)
        if series.count > capacity { series.removeFirst(series.count - capacity) }
    }

    /// `42.3%`, as the CLI prints it.
    public static func percentText(_ percent: Double) -> String { TextFormat.percentText(percent) }

    /// Where a series of `pointCount` points starts on the graphs' 0…59 axis so that its newest point sits at
    /// the right edge (x = 59) and history extends left, as Activity Monitor's and Task Manager's graphs do:
    /// `capacity − pointCount`, never below 0; `capacity` (nothing to draw) for an empty series.
    public static func firstX(pointCount: Int) -> Int { max(0, capacity - pointCount) }
}

/// A 1–2–5 ladder; each caller keeps its own starting scale and multiplication's overflow rule.
private func graphCeiling<Value: Comparable>(_ value: Value, scale: Value,
                                             multiply: (Value, Int) -> Value?) -> Value? {
    var scale = scale
    while true {
        for step in [1, 2, 5] {
            guard let figure = multiply(scale, step) else { return nil }
            if figure >= value { return figure }
        }
        guard let next = multiply(scale, 10) else { return nil }
        scale = next
    }
}

/// The machine's disk (read, write) or network (in, out) rate over the last `CPUHistory.capacity` seconds, in
/// bytes per second: what the window's Disk and Network graphs draw. Oldest point first; x from `CPUHistory.firstX`.
public struct RateHistory: Equatable, Sendable {
    public private(set) var first: [UInt64] = []
    public private(set) var second: [UInt64] = []

    public init() {}

    public mutating func append(_ first: UInt64, _ second: UInt64) {
        CPUHistory.push(first, onto: &self.first)
        CPUHistory.push(second, onto: &self.second)
    }

    /// The graph's y ceiling: the largest point rounded up to 1, 2 or 5 × a power of ten, never under 1 MB/s,
    /// so an idle machine draws a flat line rather than its noise magnified.
    public static func ceiling(_ values: [UInt64]) -> UInt64 {
        graphCeiling(values.max() ?? 0, scale: 1_000_000) { scale, step in
            let (figure, overflow) = scale.multipliedReportingOverflow(by: UInt64(step))
            return overflow ? nil : figure
        } ?? .max
    }

    /// `1.2 M/s`, as the CLI prints a rate.
    public static func rateText(_ bytesPerSecond: UInt64) -> String { TextFormat.bytesPerSecondText(bytesPerSecond) }

    /// `512 M`: a minute's bytes in the strips.
    public static func bytesText(_ bytes: UInt64) -> String { TextFormat.bytesText(bytes) }
}

/// The 1-minute load average, the system share and processes launched a second over the last `CPUHistory.capacity`
/// seconds: the CPU graph's Load, User / System and Launched graphs. Oldest point first; a figure not read on a tick
/// adds no point, and the last one read stays shown. The 5- and 15-minute averages barely move inside a minute, so
/// they show as text only; user time is the total less system, so it needs no series of its own.
public struct LoadHistory: Equatable, Sendable {
    public private(set) var oneMinute: [Double] = []
    public private(set) var systemPercent: [Double] = []
    public private(set) var launchesPerSecond: [Double] = []
    public private(set) var latestLoad: LoadAverage?
    public private(set) var latestSplit: CPUSplit?
    public private(set) var latestLaunches: LaunchRate?

    public init() {}

    /// The Load graph's y ceiling: the CPU count (where its gridline sits), or past it the peak rounded up to a nice
    /// figure, so a load above the cores stays on the graph.
    public func loadCeiling(cpus: Int) -> Double {
        let peak = oneMinute.max() ?? 0
        return peak <= Double(cpus) ? Double(cpus) : Self.niceCeiling(peak)
    }

    /// The Launched graph's y ceiling: the peak rounded up to a nice figure, never under 10 a second.
    public var launchesCeiling: Double { max(10, Self.niceCeiling(launchesPerSecond.max() ?? 0)) }

    /// `value` rounded up to 1, 2 or 5 × a power of ten, as `RateHistory.ceiling` rounds; 1 for 1 or less.
    public static func niceCeiling(_ value: Double) -> Double {
        guard value > 1 else { return 1 }
        let scale = pow(10, floor(log10(value)))
        return graphCeiling(value, scale: scale) { $0 * Double($1) } ?? 10 * scale
    }

    public mutating func append(split: CPUSplit?, load: LoadAverage?, launches: LaunchRate?) {
        if let split {
            CPUHistory.push(split.system, onto: &systemPercent)
            latestSplit = split
        }
        if let load {
            CPUHistory.push(load.oneMinute, onto: &oneMinute)
            latestLoad = load
        }
        if let launches {
            CPUHistory.push(launches.perSecond, onto: &launchesPerSecond)
            latestLaunches = launches
        }
    }
}

/// The machine's used memory as Activity Monitor's "Memory Used" adds it up — active, wired and compressed pages —
/// against physical memory (Backlog window-graph-area-space). `SystemReaders.memoryUsage()` reads it.
public struct MemoryUsage: Equatable, Sendable {
    public let usedBytes: UInt64
    public let physicalBytes: UInt64

    public init(activePages: UInt64, wiredPages: UInt64, compressedPages: UInt64, pageSize: UInt64, physicalBytes: UInt64) {
        usedBytes = (activePages &+ wiredPages &+ compressedPages) &* pageSize
        self.physicalBytes = physicalBytes
    }

    /// Used as a share of physical, 0…100; 0 when physical memory reads 0.
    public var percent: Double {
        guard physicalBytes > 0 else { return 0 }
        return min(100, 100 * Double(usedBytes) / Double(physicalBytes))
    }

    /// "Memory 57.2 G of 128 G": binary gigabytes, as the Memory column counts (Activity Monitor's 128 GB on a 128 GiB
    /// Mac); used to one decimal, physical whole.
    public var text: String {
        let gib = Double(1 << 30)
        return String(format: "Memory %.1f G of %.0f G", TextFormat.rounded(Double(usedBytes) / gib),
                      (Double(physicalBytes) / gib).rounded())
    }
}

/// Used memory as a share of physical over the last `CPUHistory.capacity` seconds: the Memory sparkline and graph.
public struct MemoryHistory: Equatable, Sendable {
    public private(set) var percent: [Double] = []
    public private(set) var latest: MemoryUsage?

    public init() {}

    public mutating func append(_ usage: MemoryUsage) {
        CPUHistory.push(usage.percent, onto: &percent)
        latest = usage
    }

    /// `8.1G`, as the Memory column shows a process's: the Memory strip's figure.
    public static func bytesText(_ bytes: UInt64) -> String { ProcessSample.memoryText(bytes) }
}

/// Which of the graph row's three cells has its full graph open under the row: at most one (Backlog
/// window-graph-area-space). Saved by its raw value, as the Cores row's open state is.
public enum OpenGraph: String, CaseIterable, Sendable {
    case none, cpu, memory, diskNetwork = "disk-network"

    /// A saved value; anything unknown, or nothing, opens no graph.
    public init(saved: String?) { self = saved.flatMap(OpenGraph.init(rawValue:)) ?? .none }

    /// A cell pressed: its graph opens in place of any other; pressing the open one closes it.
    public mutating func press(_ cell: OpenGraph) { self = self == cell ? .none : cell }
}

/// One column of per-core strips: CPUs of one core type, at most `CoreColumns.perColumn` of them.
public struct CoreColumn: Equatable, Sendable {
    public let level: Int
    public let name: String
    public let cpus: [Int]
}

public enum CoreColumns {
    /// Six strips a column: 18 cores fit in three columns (the user's mockup E).
    public static let perColumn = 6

    /// Each core type's CPUs in sixes, core types in the order the Mac lists them.
    public static func layout(_ topology: CoreTopology, perColumn: Int = perColumn) -> [CoreColumn] {
        precondition(perColumn > 0, "a column holds at least one core")
        return zip(topology.levels, topology.cpusByLevel).flatMap { level, cpus in
            stride(from: 0, to: cpus.count, by: perColumn).map { start in
                CoreColumn(level: level.index, name: level.name, cpus: Array(cpus[start..<min(start + perColumn, cpus.count)]))
            }
        }
    }
}
