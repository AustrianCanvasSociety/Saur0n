// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit

/// Byte totals stay at the representable ceiling rather than wrapping into small readings.
func byteSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : sum
}

/// Bytes read and written, cumulative: since boot for the machine, since start for a process.
public struct DiskBytes: Equatable, Sendable {
    public var read: UInt64
    public var written: UInt64

    public init(read: UInt64, written: UInt64) {
        self.read = read
        self.written = written
    }

    public static let zero = DiskBytes(read: 0, written: 0)
}

/// Bytes per second over one window, rounded to whole bytes.
public struct DiskRate: Equatable, Sendable, Encodable {
    public var readBytesPerSecond: UInt64
    public var writeBytesPerSecond: UInt64

    public init(readBytesPerSecond: UInt64, writeBytesPerSecond: UInt64) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }

    public static let zero = DiskRate(readBytesPerSecond: 0, writeBytesPerSecond: 0)

    /// Read plus write: what the DISK column shows.
    public var totalBytesPerSecond: UInt64 { byteSum(readBytesPerSecond, writeBytesPerSecond) }
}

/// A rate over the last window and the cumulative bytes at its end: the JSON's `disk` on the snapshot, each
/// process and each group.
public struct DiskUsage: Equatable, Sendable, Encodable {
    public var readBytesPerSecond: UInt64
    public var writeBytesPerSecond: UInt64
    public var readBytes: UInt64
    public var writeBytes: UInt64

    public init(rate: DiskRate, bytes: DiskBytes) {
        readBytesPerSecond = rate.readBytesPerSecond
        writeBytesPerSecond = rate.writeBytesPerSecond
        readBytes = bytes.read
        writeBytes = bytes.written
    }

    public static let zero = DiskUsage(rate: .zero, bytes: .zero)

    public var rate: DiskRate { DiskRate(readBytesPerSecond: readBytesPerSecond, writeBytesPerSecond: writeBytesPerSecond) }
}

/// The machine's counters at one moment, stamped in uptime nanoseconds (for the rate) and in seconds
/// since the epoch (for a check lining the window up with another tool's seconds).
public struct MachineSample<Bytes: Equatable & Sendable>: Equatable, Sendable {
    public let bytes: Bytes
    public let uptimeNanoseconds: UInt64
    public let epochSeconds: Double
    var sources: [String: Bytes]?

    public init(bytes: Bytes, uptimeNanoseconds: UInt64, epochSeconds: Double = 0) {
        self.bytes = bytes
        self.uptimeNanoseconds = uptimeNanoseconds
        self.epochSeconds = epochSeconds
    }

    /// Difference each continuing source before summing; a new source or a reset adds nothing.
    func delta(since before: Self, counter: (Bytes) -> UInt64) -> UInt64 {
        func increase(_ old: Bytes, _ new: Bytes) -> UInt64 {
            let start = counter(old), end = counter(new)
            return end >= start ? end - start : 0
        }
        guard let old = before.sources, let current = sources else { return increase(before.bytes, bytes) }
        return current.reduce(0) { total, entry in
            guard let previous = old[entry.key] else { return total }
            return byteSum(total, increase(previous, entry.value))
        }
    }
}

/// Keeps the last successful rate for display, but only a fresh rate feeds a graph or a tick's live status.
/// A failed read leaves the baseline untouched, so recovery measures the whole gap once.
public struct RateReading<Bytes: Equatable & Sendable, Usage: Sendable>: Sendable {
    private var last: MachineSample<Bytes>?
    public private(set) var latest: Usage?
    public private(set) var tick: Usage?
    public private(set) var window: SampleWindow?

    public init() {}

    public mutating func record(_ sample: MachineSample<Bytes>?,
                                measure: (MachineSample<Bytes>, MachineSample<Bytes>) -> Usage) {
        tick = nil
        guard let sample else { return }
        if let last {
            let usage = measure(last, sample)
            latest = usage
            tick = usage
            window = SampleWindow(before: last, after: sample)
        }
        last = sample
    }
}

/// The machine's block-storage counters and their stamps.
public typealias MachineDiskSample = MachineSample<DiskBytes>

/// When the machine's two reads were taken, in seconds since the epoch.
public struct SampleWindow: Equatable, Sendable {
    public let start: Double
    public let end: Double

    public init<Bytes>(before: MachineSample<Bytes>, after: MachineSample<Bytes>) {
        start = before.epochSeconds
        end = after.epochSeconds
    }
}

/// The JSON's `disk.windowStart` and `disk.windowEnd`.
public typealias DiskWindow = SampleWindow

/// One `IOBlockStorageDriver` as the registry lists it: the classes of every service above it, nearest first,
/// and its `Statistics` byte counters.
public struct BlockStorageDriver: Equatable, Sendable {
    public let ancestorClasses: [String]
    public let bytes: DiskBytes
    let bsdName: String?

    public init(ancestorClasses: [String], bytes: DiskBytes) {
        self.init(ancestorClasses: ancestorClasses, bytes: bytes, bsdName: nil)
    }

    init(ancestorClasses: [String], bytes: DiskBytes, bsdName: String?) {
        self.ancestorClasses = ancestorClasses
        self.bytes = bytes
        self.bsdName = bsdName
    }
}

public enum DiskActivityError: Error, Equatable, Sendable {
    case unreadable
}

/// Disk figures as pure rules over counter reads; `MachineDiskReader` and `ProcessReaders` take the reads.
public enum DiskActivity {
    /// The services a disk image's driver sits under. Its bytes reach a physical disk too, so counting them
    /// would count them twice (research 2026-10-20 § Q1). A mounted image's driver sits on an `AppleDiskImageDevice`
    /// under `AppleDiskImagesController` (registry, 2026-10-21).
    static let diskImageClasses: Set<String> = ["AppleDiskImageDevice", "AppleDiskImagesController"]

    /// The bytes of every driver with no disk image above it.
    public static func physical(_ drivers: [BlockStorageDriver]) -> DiskBytes {
        drivers.filter(isPhysical)
            .reduce(DiskBytes.zero) { DiskBytes(read: byteSum($0.read, $1.bytes.read), written: byteSum($0.written, $1.bytes.written)) }
    }

    static func isPhysical(_ driver: BlockStorageDriver) -> Bool {
        driver.ancestorClasses.allSatisfy { !diskImageClasses.contains($0) }
    }

    /// Bytes per second from `before` to `after` over `nanoseconds`; a counter that went backwards, or no time
    /// elapsed, reads 0.
    public static func rate(before: DiskBytes, after: DiskBytes, nanoseconds: UInt64) -> DiskRate {
        DiskRate(readBytesPerSecond: ProcessSample.perSecond(before.read, after.read, nanoseconds: nanoseconds),
                 writeBytesPerSecond: ProcessSample.perSecond(before.written, after.written, nanoseconds: nanoseconds))
    }

    /// The machine's rate between two reads, over their own stamps, and its counters at the second.
    public static func usage(before: MachineDiskSample, after: MachineDiskSample) -> DiskUsage {
        let elapsed = ProcessSample.elapsedNanoseconds(before: before.uptimeNanoseconds, after: after.uptimeNanoseconds)
        let moved = DiskBytes(read: after.delta(since: before, counter: \.read),
                              written: after.delta(since: before, counter: \.written))
        return DiskUsage(rate: rate(before: .zero, after: moved, nanoseconds: elapsed), bytes: after.bytes)
    }

    /// Rates and cumulative bytes summed over the rows that have them; an unreadable row adds 0.
    public static func sum(_ rows: [DiskUsage?]) -> DiskUsage {
        rows.compactMap { $0 }.reduce(DiskUsage.zero) { total, row in
            DiskUsage(rate: DiskRate(readBytesPerSecond: byteSum(total.readBytesPerSecond, row.readBytesPerSecond),
                                     writeBytesPerSecond: byteSum(total.writeBytesPerSecond, row.writeBytesPerSecond)),
                      bytes: DiskBytes(read: byteSum(total.readBytes, row.readBytes), written: byteSum(total.writeBytes, row.writeBytes)))
        }
    }

    /// The machine's rate less the readable rows' rates, each direction floored at 0: mostly root's and other
    /// users' processes, whose disk Saur0n cannot read.
    public static func unattributed(machine: DiskRate, rows: [DiskUsage?]) -> DiskRate {
        let held = sum(rows)
        func rest(_ total: UInt64, _ part: UInt64) -> UInt64 { total > part ? total - part : 0 }
        return DiskRate(readBytesPerSecond: rest(machine.readBytesPerSecond, held.readBytesPerSecond),
                        writeBytesPerSecond: rest(machine.writeBytesPerSecond, held.writeBytesPerSecond))
    }
}

/// Thin reader over the IO registry's block-storage drivers; the physical-driver rule is `DiskActivity.physical`.
public enum MachineDiskReader {
    /// The physical drivers' counters now. `listing` is the registry by default; nil from it, or no physical driver
    /// at all, is `DiskActivityError.unreadable`.
    public static func read(listing: () -> [BlockStorageDriver]? = drivers) throws -> MachineDiskSample {
        guard let drivers = listing(), drivers.contains(where: DiskActivity.isPhysical) else { throw DiskActivityError.unreadable }
        let physical = drivers.filter(DiskActivity.isPhysical)
        var sample = MachineDiskSample(bytes: DiskActivity.physical(drivers), uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                       epochSeconds: Date().timeIntervalSince1970)
        if physical.allSatisfy({ $0.bsdName != nil }) {
            sample.sources = physical.reduce(into: [:]) { sources, driver in
                if let name = driver.bsdName { sources[name] = driver.bytes }
            }
        }
        return sample
    }

    static func bytes(statistics: [String: Any]) -> DiskBytes? {
        guard let read = statistics["Bytes (Read)"] as? UInt64,
              let written = statistics["Bytes (Write)"] as? UInt64 else { return nil }
        return DiskBytes(read: read, written: written)
    }

    /// Every `IOBlockStorageDriver` with a `Statistics` dictionary, its ancestors' classes up the service plane;
    /// nil when the registry cannot be searched or a driver's byte counters cannot be read.
    public static func drivers() -> [BlockStorageDriver]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var out: [BlockStorageDriver] = []
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            guard let raw = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue(), let statistics = raw as? [String: Any],
                  let bytes = bytes(statistics: statistics) else { return nil }
            let name = IORegistryEntrySearchCFProperty(driver, kIOServicePlane, "BSD Name" as CFString,
                                                       kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) as? String
            let entry = BlockStorageDriver(ancestorClasses: ancestorClasses(driver), bytes: bytes, bsdName: name)
            if DiskActivity.isPhysical(entry), name == nil {
                continue // No named media is available to compare with another reading.
            }
            out.append(entry)
        }
        return out
    }

    /// The class of every service above `entry` in the service plane, nearest first.
    static func ancestorClasses(_ entry: io_registry_entry_t) -> [String] {
        var classes: [String] = []
        var current = entry
        IOObjectRetain(current)
        while true {
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard result == KERN_SUCCESS, parent != 0 else { return classes }
            var name = [CChar](repeating: 0, count: 128)
            if IOObjectGetClass(parent, &name) == KERN_SUCCESS {
                classes.append(SystemReaders.cString(name))
            }
            current = parent
        }
    }
}
