// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The machine's memory counters as the floor warning and the live status read them, from one
/// `host_statistics64(HOST_VM_INFO64)` read: the pages the floor counts as available, the pages the Memory column
/// counts as used, and swap as a confirmer of pressure (never a veto) — plan § Decisions, "Memory-floor warning stays
/// early".
public struct AvailableMemory: Equatable, Sendable {
    public let freeBytes, inactiveBytes, speculativeBytes, purgeableBytes: UInt64
    public let activeBytes, wiredBytes, compressedBytes: UInt64
    public let physicalBytes: UInt64
    /// Used swap from `vm.swapusage`; nil when it could not be read.
    public let swapUsedBytes: UInt64?

    public init(freeBytes: UInt64, inactiveBytes: UInt64, speculativeBytes: UInt64, purgeableBytes: UInt64,
                activeBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64, physicalBytes: UInt64,
                swapUsedBytes: UInt64? = nil) {
        self.freeBytes = freeBytes
        self.inactiveBytes = inactiveBytes
        self.speculativeBytes = speculativeBytes
        self.purgeableBytes = purgeableBytes
        self.activeBytes = activeBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.physicalBytes = physicalBytes
        self.swapUsedBytes = swapUsedBytes
    }

    /// The same figures from page counts and the kernel's page size.
    public init(freePages: UInt64, inactivePages: UInt64, speculativePages: UInt64, purgeablePages: UInt64,
                activePages: UInt64, wiredPages: UInt64, compressedPages: UInt64, pageSize: UInt64,
                physicalBytes: UInt64, swapUsedBytes: UInt64? = nil) {
        self.init(freeBytes: freePages &* pageSize, inactiveBytes: inactivePages &* pageSize,
                  speculativeBytes: speculativePages &* pageSize, purgeableBytes: purgeablePages &* pageSize,
                  activeBytes: activePages &* pageSize, wiredBytes: wiredPages &* pageSize,
                  compressedBytes: compressedPages &* pageSize, physicalBytes: physicalBytes,
                  swapUsedBytes: swapUsedBytes)
    }

    /// Free + inactive + speculative + purgeable: what the time-to-floor projection runs down, and what is left when it
    /// reaches zero (plan § Decisions).
    public var availableBytes: UInt64 { freeBytes &+ inactiveBytes &+ speculativeBytes &+ purgeableBytes }
    /// Active + wired + compressed: Activity Monitor's "Memory Used", as the Memory column shows it.
    public var usedBytes: UInt64 { activeBytes &+ wiredBytes &+ compressedBytes }

    /// `usedPercent` of physical memory on `basis`, 0–100; 0 when physical memory reads 0.
    public func usedPercent(_ basis: MemoryPercentBasis) -> Double {
        guard physicalBytes > 0 else { return 0 }
        let used = switch basis {
        case .usedOfPhysical: Double(usedBytes)
        case .availableComplement: Double(physicalBytes) - min(Double(availableBytes), Double(physicalBytes))
        }
        return min(100, max(0, 100 * used / Double(physicalBytes)))
    }
}

/// How the fixed levels turn memory into a percentage. Which one applies is not decided: it is part of Step 2's
/// pending calibration (plan § Decisions: "define the fixed-level memory percentage and its denominator").
public enum MemoryPercentBasis: String, CaseIterable, Equatable, Sendable {
    /// Active, wired and compressed pages over physical — the figure the Memory column shows.
    case usedOfPhysical
    /// Physical memory less the available composite (free + inactive + speculative + purgeable), over physical.
    case availableComplement
}

/// The floor the projection runs to: 4 GB, or 12% of physical memory, whichever is larger (plan § Decisions).
public enum MemoryFloor {
    public static let minimumBytes: UInt64 = 4 << 30
    public static let physicalFraction = 0.12

    public static func bytes(physicalBytes: UInt64) -> UInt64 {
        max(minimumBytes, UInt64(Double(physicalBytes) * physicalFraction))
    }
}

/// The memory floor's projection (Phase 7 Step 2): a least-squares line through the available-page composite over the
/// last of several nested windows, projected to the floor; and the process whose resident memory grew most since it was
/// first seen in the longest window, so the warning names its driver. Pure: state is the recent samples and one
/// first/last reading per process still running.
public struct MemoryProjection: Sendable {
    /// The projection's settings. Every value is pending calibration (plan § Decisions: "select … the ETA window
    /// details"), so production ships `ResourceCalibration.pending`, which has no projection at all.
    public struct Config: Equatable, Sendable {
        /// Trailing windows in seconds, shortest first, each nested in the next: the shortest with enough samples
        /// decides.
        public let windows: [Double]
        public let minimumSamples: Int
        /// A decline shallower than this is noise, not a runway.
        public let minimumDeclineBytesPerSecond: Double

        public init(windows: [Double], minimumSamples: Int, minimumDeclineBytesPerSecond: Double) {
            self.windows = windows
            self.minimumSamples = minimumSamples
            self.minimumDeclineBytesPerSecond = minimumDeclineBytesPerSecond
        }
    }

    /// `seconds` until available memory reaches the floor (0 once it is below it); the window the fit used and its
    /// decline in bytes a second.
    public struct ETA: Equatable, Sendable {
        public let seconds: Double
        public let window: Double
        public let declineBytesPerSecond: Double
        public let floorBytes: UInt64
        public let availableBytes: UInt64
    }

    /// The process that grew most over `window` seconds; its identity is the row's pid and start time.
    public struct GrowthDriver: Equatable, Sendable {
        public let pid: Int32
        public let startMicroseconds: UInt64
        public let name: String
        public let growthBytes: UInt64
        public let window: Double
    }

    public struct Reading: Equatable, Sendable {
        public let eta: ETA?
        /// Named only when there is an ETA: the driver explains the decline.
        public let growthDriver: GrowthDriver?
    }

    public let config: Config
    private var samples: [(end: Double, available: UInt64, physical: UInt64)] = []
    private var growth: [Int32: Growth] = [:]

    /// A running process's resident memory when it was first seen in the longest window and at the latest tick.
    private struct Growth {
        let start: UInt64
        let name: String
        let firstEnd: Double
        let firstBytes: UInt64
        var lastBytes: UInt64
    }

    public init(config: Config) {
        self.config = config
    }

    /// Reads one tick's memory and rows. A nil memory leaves the series as it was and projects nothing.
    public mutating func next(end: Double, memory: AvailableMemory?, rows: [ProcessUsage]) -> Reading {
        guard let memory else { return Reading(eta: nil, growthDriver: nil) }
        step(end: end, memory: memory, rows: rows)
        let eta = eta(end: end)
        return Reading(eta: eta, growthDriver: eta.flatMap { _ in driver(end: end) })
    }

    private mutating func step(end: Double, memory: AvailableMemory, rows: [ProcessUsage]) {
        samples.append((end, memory.availableBytes, memory.physicalBytes))
        let oldest = end - (config.windows.max() ?? 0)
        samples.removeAll { $0.end < oldest }
        let present = Set(rows.map(\.pid))
        growth = growth.filter { present.contains($0.key) && $0.value.firstEnd >= oldest }
        for row in rows {
            // A pid the system recycled is a new process: its growth starts now, not at the old process's first sighting.
            guard var entry = growth[row.pid], entry.start == row.startMicroseconds else {
                growth[row.pid] = Growth(start: row.startMicroseconds, name: row.name, firstEnd: end,
                                         firstBytes: row.residentBytes, lastBytes: row.residentBytes)
                continue
            }
            entry.lastBytes = row.residentBytes
            growth[row.pid] = entry
        }
    }

    /// The shortest nested window with enough samples and a real decline; below the floor, zero.
    private func eta(end: Double) -> ETA? {
        guard let newest = samples.last else { return nil }
        let floor = MemoryFloor.bytes(physicalBytes: newest.physical)
        guard newest.available > floor else {
            return ETA(seconds: 0, window: config.windows.first ?? 0, declineBytesPerSecond: 0, floorBytes: floor,
                       availableBytes: newest.available)
        }
        for window in config.windows {
            let points = samples.filter { $0.end >= end - window }
            guard points.count >= config.minimumSamples, let first = points.first,
                  first.end < newest.end, let slope = Self.slope(points) else { continue }
            guard slope <= -config.minimumDeclineBytesPerSecond else { continue }
            let seconds = (Double(newest.available) - Double(floor)) / -slope
            return ETA(seconds: seconds, window: window, declineBytesPerSecond: -slope, floorBytes: floor,
                       availableBytes: newest.available)
        }
        return nil
    }

    /// The least-squares slope of available bytes a second; nil when every sample shares one time.
    static func slope(_ points: [(end: Double, available: UInt64, physical: UInt64)]) -> Double? {
        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.end } / count
        let meanY = points.reduce(0) { $0 + Double($1.available) } / count
        var numerator = 0.0, denominator = 0.0
        for point in points {
            let dx = point.end - meanX
            numerator += dx * (Double(point.available) - meanY)
            denominator += dx * dx
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    /// The biggest resident-memory growth since its process was first seen in the longest window; the span that growth
    /// covers, which can be shorter when the process started later.
    private func driver(end: Double) -> GrowthDriver? {
        let best = growth
            .filter { $0.value.lastBytes > $0.value.firstBytes }
            .max { ($0.value.lastBytes - $0.value.firstBytes) < ($1.value.lastBytes - $1.value.firstBytes) }
        guard let best else { return nil }
        return GrowthDriver(pid: best.key, startMicroseconds: best.value.start, name: best.value.name,
                            growthBytes: best.value.lastBytes - best.value.firstBytes,
                            window: end - best.value.firstEnd)
    }
}
