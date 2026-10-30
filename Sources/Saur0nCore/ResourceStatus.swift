// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The approved v1 live-status document for Olympus (`research/2026-10-28-live-status-contract.md`): one small
/// document per completed watcher tick, with the machine's own figures — never a process list, an argument or a
/// control surface. Saur0n is the only sampler; a same-user reader on the producer's Mac reads the file.
///
/// Every key is always present, a metric the tick could not read is an explicit null, and an older metric is never
/// reused under a newer timestamp. `resourceLevel` is null until the resource-level engine is calibrated.
public struct ResourceStatus: Equatable, Sendable {
    /// The contract's reserved level values, supplied only by the calibrated resource-level engine. Nested so the
    /// engine's own `ResourceLevel` maps onto it explicitly rather than being replaced by a second alarm vocabulary.
    public enum Level: String, Sendable, CaseIterable {
        case normal, notice, triage, critical
    }

    /// (active + wired + compressed pages) × page size against physical memory — the window's display definition,
    /// not the fixed-level alert denominator, kernel pressure or a time to floor.
    public struct Memory: Equatable, Sendable, Codable {
        public let usedBytes: UInt64
        public let physicalBytes: UInt64
        public let usedPercent: Double

        public init(usedBytes: UInt64, physicalBytes: UInt64, usedPercent: Double) {
            self.usedBytes = usedBytes
            self.physicalBytes = physicalBytes
            self.usedPercent = usedPercent
        }
    }

    /// The machine's own rates from physical-storage totals, not sums of process rows. Numbers, not integers: a
    /// rate may be fractional.
    public struct Disk: Equatable, Sendable, Codable {
        public let readBytesPerSecond: Double
        public let writeBytesPerSecond: Double

        public init(readBytesPerSecond: Double, writeBytesPerSecond: Double) {
            self.readBytesPerSecond = readBytesPerSecond
            self.writeBytesPerSecond = writeBytesPerSecond
        }
    }

    /// The machine's own rates from physical-interface totals, not sums of process rows.
    public struct Network: Equatable, Sendable, Codable {
        public let inBytesPerSecond: Double
        public let outBytesPerSecond: Double

        public init(inBytesPerSecond: Double, outBytesPerSecond: Double) {
            self.inBytesPerSecond = inBytesPerSecond
            self.outBytesPerSecond = outBytesPerSecond
        }
    }

    /// The version this producer writes and this reader supports; another version is unavailable, not normal.
    public static let supportedSchemaVersion = 1
    /// A document older than this on the reader's clock is stale (the contract's display freshness, not a warning
    /// hold, acknowledgement deadline, drop-back margin or pause trigger).
    public static let freshSeconds: TimeInterval = 10

    public let schemaVersion: Int
    /// The Mac's nickname — never a hostname, address or home-directory identifier.
    public let machine: String
    /// The completed reading's time, to the second, UTC RFC 3339.
    public let sampledAt: Date
    /// The interval the CPU and rate figures were measured over: positive and finite, never an assumption that a
    /// tick took one second.
    public let intervalSeconds: Double
    public let cpuPercent: Double?
    public let memory: Memory?
    public let disk: Disk?
    public let network: Network?
    public let warningCount: Int?
    public let resourceLevel: Level?

    init(machine: String, sampledAt: Date, intervalSeconds: Double, cpuPercent: Double?, memory: Memory?,
         disk: Disk?, network: Network?, warningCount: Int?, resourceLevel: Level?) {
        schemaVersion = Self.supportedSchemaVersion
        self.machine = machine
        self.sampledAt = sampledAt
        self.intervalSeconds = intervalSeconds
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.disk = disk
        self.network = network
        self.warningCount = warningCount
        self.resourceLevel = resourceLevel
    }
}

// MARK: - One watcher tick

extension ResourceStatus {
    /// One completed watcher tick's readings, as the existing sampling path has them. Each metric is what this tick
    /// read: pass nil for one whose read failed, never the window's kept figure.
    public struct Sample: Sendable {
        public var sampledAt: Date
        public var intervalSeconds: Double
        public var machine: String
        public var cpuPercent: Double?
        public var memory: MemoryUsage?
        public var disk: DiskRate?
        public var network: NetworkRate?
        public var warningCount: Int?
        public var resourceLevel: Level?

        public init(sampledAt: Date, intervalSeconds: Double, machine: String, cpuPercent: Double? = nil,
                    memory: MemoryUsage? = nil, disk: DiskRate? = nil, network: NetworkRate? = nil,
                    warningCount: Int? = nil, resourceLevel: Level? = nil) {
            self.sampledAt = sampledAt
            self.intervalSeconds = intervalSeconds
            self.machine = machine
            self.cpuPercent = cpuPercent
            self.memory = memory
            self.disk = disk
            self.network = network
            self.warningCount = warningCount
            self.resourceLevel = resourceLevel
        }
    }

    /// A tick's document; nil when it cannot make a valid one — no positive finite interval or no machine — so a
    /// gap publishes nothing and no timestamp advances over it.
    public init?(sample: Sample) {
        guard let interval = Self.validInterval(sample.intervalSeconds), !sample.machine.isEmpty else { return nil }
        self.init(machine: sample.machine, sampledAt: Self.wholeSecond(sample.sampledAt), intervalSeconds: interval,
                  cpuPercent: Self.validCPU(sample.cpuPercent), memory: sample.memory.flatMap(Self.memory(from:)),
                  disk: sample.disk.map { Disk(readBytesPerSecond: Double($0.readBytesPerSecond),
                                               writeBytesPerSecond: Double($0.writeBytesPerSecond)) },
                  network: sample.network.map { Network(inBytesPerSecond: Double($0.inBytesPerSecond),
                                                        outBytesPerSecond: Double($0.outBytesPerSecond)) },
                  warningCount: sample.warningCount.flatMap { $0 >= 0 ? $0 : nil },
                  resourceLevel: sample.resourceLevel)
    }

    /// The reader's `PhysicalBytes` rule: no positive denominator, no memory figure — null, never a zero share.
    static func memory(from usage: MemoryUsage) -> Memory? {
        guard usage.physicalBytes > 0, usage.percent.isFinite else { return nil }
        return Memory(usedBytes: usage.usedBytes, physicalBytes: usage.physicalBytes, usedPercent: usage.percent)
    }

    static func validInterval(_ seconds: Double) -> Double? {
        seconds.isFinite && seconds > 0 ? seconds : nil
    }

    static func validCPU(_ percent: Double?) -> Double? {
        guard let percent, percent.isFinite, (0...100).contains(percent) else { return nil }
        return percent
    }

    /// The document's timestamp has whole seconds, as the approved fixture's has: truncation can only make a
    /// document read older, never younger.
    static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

// MARK: - JSON

/// A document that cannot be read as the contract says: a broken shape, or a version this reader does not know.
enum DecodeFailure: Error {
    case malformed
    case unsupportedVersion(Int)
}

extension ResourceStatus: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, machine, sampledAt, intervalSeconds, cpuPercent, memory, disk, network, warningCount,
             resourceLevel
    }

    /// Every key is written: a nil metric is a JSON null, not an absent key.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(machine, forKey: .machine)
        try container.encode(Self.timestamp(sampledAt), forKey: .sampledAt)
        try container.encode(intervalSeconds, forKey: .intervalSeconds)
        try container.encode(cpuPercent, forKey: .cpuPercent)
        try container.encode(memory, forKey: .memory)
        try container.encode(disk, forKey: .disk)
        try container.encode(network, forKey: .network)
        try container.encode(warningCount, forKey: .warningCount)
        try container.encode(resourceLevel?.rawValue, forKey: .resourceLevel)
    }

    /// The contract's reading rules: required keys and a supported version, else the document is unreadable.
    /// A metric whose value is wrong — out of range, not a number where one is required, a fractional byte count —
    /// reads as unavailable while the envelope stays fresh; a null metric stays unavailable the same way.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard CodingKeys.allCases.allSatisfy(container.contains) else { throw DecodeFailure.malformed }
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.supportedSchemaVersion else { throw DecodeFailure.unsupportedVersion(version) }
        let machine = try container.decode(String.self, forKey: .machine)
        guard !machine.isEmpty else { throw DecodeFailure.malformed }
        guard let sampledAt = Self.date(from: try container.decode(String.self, forKey: .sampledAt)) else {
            throw DecodeFailure.malformed
        }
        let interval = try container.decode(Double.self, forKey: .intervalSeconds)
        guard let intervalSeconds = Self.validInterval(interval) else { throw DecodeFailure.malformed }
        // A metric of the wrong type reads as unavailable, as an out-of-range one does; the envelope stays fresh.
        func metric<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(type, forKey: key)) ?? nil
        }
        self.init(machine: machine, sampledAt: sampledAt, intervalSeconds: intervalSeconds,
                  cpuPercent: Self.validCPU(metric(Double.self, .cpuPercent)),
                  memory: metric(Memory.self, .memory), disk: metric(Disk.self, .disk),
                  network: metric(Network.self, .network),
                  warningCount: metric(Int.self, .warningCount).flatMap { $0 >= 0 ? $0 : nil },
                  // An unknown level is unavailable, never read as normal: deriving an alarm is Olympus's to avoid.
                  resourceLevel: metric(String.self, .resourceLevel).flatMap(Level.init(rawValue:)))
    }
}

extension ResourceStatus.CodingKeys: CaseIterable {}

extension ResourceStatus.Memory {
    enum CodingKeys: String, CodingKey { case usedBytes, physicalBytes, usedPercent }

    /// Byte counts are nonnegative integers decoded as `UInt64`, so a fractional, negative or out-of-range count is
    /// refused by the decode itself — never converted through a Double, which rounds past 2^53 and traps beyond
    /// `UInt64.max`; physical memory is positive, a share outside 0…100 is not a share.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let used = try container.decode(UInt64.self, forKey: .usedBytes)
        let physical = try container.decode(UInt64.self, forKey: .physicalBytes)
        let percent = try container.decode(Double.self, forKey: .usedPercent)
        guard physical > 0, percent.isFinite, (0...100).contains(percent) else { throw DecodeFailure.malformed }
        self.init(usedBytes: used, physicalBytes: physical, usedPercent: percent)
    }
}

extension ResourceStatus.Disk {
    enum CodingKeys: String, CodingKey { case readBytesPerSecond, writeBytesPerSecond }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let read = try container.decode(Double.self, forKey: .readBytesPerSecond)
        let write = try container.decode(Double.self, forKey: .writeBytesPerSecond)
        guard read.isFinite, read >= 0, write.isFinite, write >= 0 else { throw DecodeFailure.malformed }
        self.init(readBytesPerSecond: read, writeBytesPerSecond: write)
    }
}

extension ResourceStatus.Network {
    enum CodingKeys: String, CodingKey { case inBytesPerSecond, outBytesPerSecond }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let inbound = try container.decode(Double.self, forKey: .inBytesPerSecond)
        let outbound = try container.decode(Double.self, forKey: .outBytesPerSecond)
        guard inbound.isFinite, inbound >= 0, outbound.isFinite, outbound >= 0 else { throw DecodeFailure.malformed }
        self.init(inBytesPerSecond: inbound, outBytesPerSecond: outbound)
    }
}

extension ResourceStatus {
    /// UTC RFC 3339, whole seconds — the approved fixture's shape.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// RFC 3339 with or without fractional seconds (another producer may keep them); nil when it is not a time.
    static func date(from text: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.timeZone = TimeZone(secondsFromGMT: 0)
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = precise.date(from: text) { return date }
        let whole = ISO8601DateFormatter()
        whole.timeZone = TimeZone(secondsFromGMT: 0)
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: text)
    }
}

// MARK: - The reader's freshness rules

/// What a reader of the published file sees, by the contract's rules: fresh within 10 seconds of a valid sample
/// not in the future, stale past it, unavailable when the document cannot be trusted at all. Age is recomputed on
/// every read; nothing here refreshes `sampledAt` or freezes a stale flag.
public enum ResourceStatusReader {
    public enum Unavailable: Equatable, Sendable {
        case missing, malformed
        case unsupportedVersion(Int)
        case futureDated
    }

    public enum Verdict: Equatable, Sendable {
        case fresh(ResourceStatus, age: TimeInterval)
        case stale(ResourceStatus, age: TimeInterval)
        case unavailable(Unavailable)
    }

    public static func read(_ data: Data?, now: Date) -> Verdict {
        guard let data else { return .unavailable(.missing) }
        let status: ResourceStatus
        do {
            status = try JSONDecoder().decode(ResourceStatus.self, from: data)
        } catch let failure as DecodeFailure {
            switch failure {
            case .malformed: return .unavailable(.malformed)
            case .unsupportedVersion(let version): return .unavailable(.unsupportedVersion(version))
            }
        } catch {
            return .unavailable(.malformed)
        }
        let age = now.timeIntervalSince(status.sampledAt)
        guard age >= 0 else { return .unavailable(.futureDated) }
        return age <= ResourceStatus.freshSeconds ? .fresh(status, age: age) : .stale(status, age: age)
    }
}

// MARK: - Publication

/// One writer for `~/Library/Application Support/Saur0n/live-status.json`: the complete document goes into a
/// uniquely named sibling file created at 0600 and is renamed over the destination, so a reader sees an old or a
/// new complete document, never a truncated one — and a failed write leaves the previous document and its old
/// timestamp in place. The first publication needs no existing destination.
public struct ResourceStatusProducer: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case write(Int32)
        case rename(Int32)

        public var description: String {
            switch self {
            case .write(let code): "cannot write the live status: \(String(cString: strerror(code)))"
            case .rename(let code): "cannot rename the live status into place: \(String(cString: strerror(code)))"
            }
        }
    }

    public static let fileName = "live-status.json"

    /// The contract's path under the producer account's home. No environment override: the contract fixes it.
    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Saur0n/" + fileName)
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    public func publish(_ status: ResourceStatus) throws {
        let data = try JSONEncoder().encode(status)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(url.lastPathComponent + "." + UUID().uuidString + ".tmp")
        // Created 0600 in one call, so the document is never briefly readable by another account.
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Failure.write(errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            // Flushed before the rename, so a crash leaves the old document rather than an empty new one.
            guard fsync(descriptor) == 0 else { throw Failure.write(errno) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.rename(code)
        }
    }
}

// MARK: - The approved switches

/// The live status's switches, source only: the switch is off by default and the only nickname the approved contract
/// permits is `Pro`, so a Mac with the switch off, the nickname missing or another nickname writes nothing and is
/// never labelled as another one. Switching it on is the runtime hold's decision, not this code's.
public struct LiveStatusSwitches: Sendable {
    public static let enabledKey = "liveStatus.enabled"
    public static let machineKey = "liveStatus.machine"
    /// The one nickname the contract permits.
    public static let permittedMachine = "Pro"

    /// The nickname to publish under — `Pro` — or nil while the switch is off or the nickname is not exactly it.
    /// `lookup` is `UserDefaults.standard.object(forKey:)` in the app; a value reads as `bool(forKey:)` reads it, so
    /// a launch argument switches publication on for that process alone, without a defaults write.
    public static func machine(_ lookup: (String) -> Any?) -> String? {
        guard flag(lookup(enabledKey)) == true,
              let nickname = lookup(machineKey) as? String, nickname == permittedMachine
        else { return nil }
        return permittedMachine
    }

    /// `ActingSwitches`'s rule, private there: a `Bool`, an `NSNumber` or a string as `boolValue` reads it.
    private static func flag(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String: NSString(string: value).boolValue
        default: nil
        }
    }
}
