// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the approved v1 live-status contract (research/2026-10-28-live-status-contract.md) — one small document per
// completed watcher tick with the machine's own figures, published atomically at 0600, read back fresh, stale or
// unavailable by the contract's freshness rules. Method: the documentation-only fixture verbatim, samples built in
// code, and publications into temp folders only — never the real Application Support, snapshot or ledger paths.

/// The contract's documentation-only fixture, verbatim: illustrative values, not captured machine evidence.
private let fixture = """
{
  "schemaVersion": 1,
  "machine": "Pro",
  "sampledAt": "2026-10-28T12:00:00Z",
  "intervalSeconds": 1.2,
  "cpuPercent": 35.0,
  "memory": {
    "usedBytes": 17179869184,
    "physicalBytes": 34359738368,
    "usedPercent": 50.0
  },
  "disk": {"readBytesPerSecond": 1048576, "writeBytesPerSecond": 524288},
  "network": {"inBytesPerSecond": 262144, "outBytesPerSecond": 131072},
  "warningCount": 0,
  "resourceLevel": null
}
"""

/// 2026-10-28T12:00:00Z, the fixture's sample time.
private let fixtureEpoch = 1_793_188_800.0

private func fixtureData() -> Data { Data(fixture.utf8) }

/// The fixture's JSON as a dictionary, for comparing our encoding key by key (key order is not meaningful).
private func fixtureObject() throws -> NSDictionary {
    try #require(JSONSerialization.jsonObject(with: fixtureData()) as? NSDictionary)
}

private func encodedObject(_ status: ResourceStatus) throws -> NSDictionary {
    try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(status)) as? NSDictionary)
}

/// The JSON with every number as one Double, in sorted key order: a rate written `1048576` and one written
/// `1048576.0` compare equal, and only the contract's shape and values decide.
private func canonical(_ object: NSDictionary) throws -> String {
    func normalize(_ value: Any) -> Any {
        if let number = value as? NSNumber { return number.doubleValue }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(normalize) }
        if let array = value as? [Any] { return array.map(normalize) }
        return value
    }
    let data = try JSONSerialization.data(withJSONObject: normalize(object), options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

/// A sample with the fixture's figures, overridable field by field.
private func sample(sampledAt: Date = Date(timeIntervalSince1970: fixtureEpoch), intervalSeconds: Double = 1.2,
                    machine: String = "Pro", cpuPercent: Double? = 35, memory: MemoryUsage? = nil,
                    disk: DiskRate? = DiskRate(readBytesPerSecond: 1_048_576, writeBytesPerSecond: 524_288),
                    network: NetworkRate? = NetworkRate(inBytesPerSecond: 262_144, outBytesPerSecond: 131_072),
                    warningCount: Int? = 0, resourceLevel: ResourceStatus.Level? = nil) -> ResourceStatus.Sample {
    // The machine is a required input — no producer default can label another Mac as Pro.
    ResourceStatus.Sample(sampledAt: sampledAt, intervalSeconds: intervalSeconds, machine: machine,
                          cpuPercent: cpuPercent, memory: memory, disk: disk, network: network,
                          warningCount: warningCount, resourceLevel: resourceLevel)
}

private func document(_ sample: ResourceStatus.Sample) throws -> ResourceStatus {
    try #require(ResourceStatus(sample: sample))
}

/// A status for publication tests.
private func status(at epoch: Double, warnings: Int) throws -> ResourceStatus {
    try document(sample(sampledAt: Date(timeIntervalSince1970: epoch), warningCount: warnings))
}

private func temporaryFolder(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("saur0n-status-\(name)-\(UUID().uuidString)")
}

// MARK: - The approved fixture and the document

@Test func approvedFixtureReadsAsFresh() throws {
    let verdict = ResourceStatusReader.read(fixtureData(), now: Date(timeIntervalSince1970: fixtureEpoch + 5))
    guard case .fresh(let status, let age) = verdict else { Issue.record("not fresh: \(verdict)"); return }
    #expect(age == 5)
    #expect(status.schemaVersion == 1)
    #expect(status.machine == "Pro")
    #expect(status.sampledAt == Date(timeIntervalSince1970: fixtureEpoch))
    #expect(status.intervalSeconds == 1.2)
    #expect(status.cpuPercent == 35)
    #expect(status.memory == ResourceStatus.Memory(usedBytes: 17_179_869_184, physicalBytes: 34_359_738_368,
                                                   usedPercent: 50))
    #expect(status.disk == ResourceStatus.Disk(readBytesPerSecond: 1_048_576, writeBytesPerSecond: 524_288))
    #expect(status.network == ResourceStatus.Network(inBytesPerSecond: 262_144, outBytesPerSecond: 131_072))
    #expect(status.warningCount == 0)
    #expect(status.resourceLevel == nil)
}

@Test func approvedFixtureRoundTripsThroughEncoding() throws {
    let verdict = ResourceStatusReader.read(fixtureData(), now: Date(timeIntervalSince1970: fixtureEpoch))
    guard case .fresh(let status, _) = verdict else { Issue.record("not fresh: \(verdict)"); return }
    #expect(try canonical(encodedObject(status)) == canonical(try fixtureObject()))
}

@Test func fractionalRatesArePublishedAndRead() throws {
    // The contract's disk and network numbers are finite nonnegative numbers, not integers: a fractional rate is
    // read as is and published back unchanged.
    var object = try fixtureObject() as? [String: Any] ?? [:]
    object["disk"] = ["readBytesPerSecond": 1_048_576.5, "writeBytesPerSecond": 0] as [String: Any]
    object["network"] = ["inBytesPerSecond": 2_621.25, "outBytesPerSecond": 0.5] as [String: Any]
    let data = try JSONSerialization.data(withJSONObject: object)
    guard case .fresh(let status, _) = ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch))
    else { Issue.record("fractional rates refused"); return }
    #expect(status.disk == ResourceStatus.Disk(readBytesPerSecond: 1_048_576.5, writeBytesPerSecond: 0))
    #expect(status.network == ResourceStatus.Network(inBytesPerSecond: 2_621.25, outBytesPerSecond: 0.5))
    #expect(try ResourceStatusReader.read(JSONEncoder().encode(status), now: Date(timeIntervalSince1970: fixtureEpoch))
            == .fresh(status, age: 0))
}

@Test func aFractionalByteCountIsNotAMemoryFigure() throws {
    // usedBytes is an integer count; 4096.5 bytes is not a reading, so memory is unavailable and the rest stands.
    var object = try fixtureObject() as? [String: Any] ?? [:]
    object["memory"] = ["usedBytes": 4_096.5, "physicalBytes": 8_192, "usedPercent": 50.0] as [String: Any]
    let data = try JSONSerialization.data(withJSONObject: object)
    guard case .fresh(let status, _) = ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch))
    else { Issue.record("envelope refused"); return }
    #expect(status.memory == nil)
    #expect(status.cpuPercent == 35)
}

@Test func aByteCountBeyondUInt64IsNotAMemoryFigure() throws {
    // A finite count outside UInt64 is not a reading either: the envelope stays fresh, memory unavailable, and the
    // reader refuses it rather than converting it, which would trap.
    for field in ["usedBytes", "physicalBytes"] {
        var memory: [String: Any] = ["usedBytes": 4_096, "physicalBytes": 8_192, "usedPercent": 50.0]
        memory[field] = 1e30
        var object = try fixtureObject() as? [String: Any] ?? [:]
        object["memory"] = memory
        let data = try JSONSerialization.data(withJSONObject: object)
        guard case .fresh(let status, _) = ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch))
        else { Issue.record("envelope refused for \(field)"); return }
        #expect(status.memory == nil, "\(field) 1e30 was read")
    }
}

@Test func aLargeByteCountKeepsEveryDigit() throws {
    // Past 2^53 a Double would round: the counts decode as integers, every digit kept.
    var object = try fixtureObject() as? [String: Any] ?? [:]
    object["memory"] = ["usedBytes": 9_007_199_254_740_993 as UInt64,
                        "physicalBytes": 18_000_000_000_000_000_000 as UInt64,
                        "usedPercent": 50.0] as [String: Any]
    let data = try JSONSerialization.data(withJSONObject: object)
    guard case .fresh(let status, _) = ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch))
    else { Issue.record("envelope refused"); return }
    #expect(status.memory == ResourceStatus.Memory(usedBytes: 9_007_199_254_740_993,
                                                   physicalBytes: 18_000_000_000_000_000_000, usedPercent: 50))
}

@Test func everyKeyIsEmittedEvenWhenNull() throws {
    let encoded = try encodedObject(try document(sample(cpuPercent: nil, memory: nil, disk: nil, network: nil,
                                                       warningCount: nil)))
    let keys = ["schemaVersion", "machine", "sampledAt", "intervalSeconds", "cpuPercent", "memory", "disk",
                "network", "warningCount", "resourceLevel"]
    #expect(Set(encoded.allKeys as? [String] ?? []) == Set(keys))
    for key in ["cpuPercent", "memory", "disk", "network", "warningCount", "resourceLevel"] {
        #expect(encoded[key] is NSNull, "\(key) is not an explicit null")
    }
    #expect(encoded["intervalSeconds"] as? Double == 1.2)
}

@Test func sampledAtIsWholeSecondUTC() throws {
    // 2026-10-28T12:00:00.750Z: published as the fixture's own second, never the fraction.
    let status = try document(sample(sampledAt: Date(timeIntervalSince1970: fixtureEpoch + 0.75)))
    #expect(try encodedObject(status)["sampledAt"] as? String == "2026-10-28T12:00:00Z")
}

@Test func memoryUsesPagesTimesPageSize() throws {
    // Active + wired + compressed pages, times the kernel's page size; the share of physical capped at 100.
    let memory = MemoryUsage(activePages: 4_000, wiredPages: 3_000, compressedPages: 1_000, pageSize: 16_384,
                             physicalBytes: 34_359_738_368)
    let status = try document(sample(memory: memory))
    #expect(status.memory?.usedBytes == 8_000 * 16_384)
    #expect(status.memory?.physicalBytes == 34_359_738_368)
    #expect(status.memory?.usedPercent == 100 * Double(8_000 * 16_384) / 34_359_738_368)

    let tiny = MemoryUsage(activePages: 30_000_000, wiredPages: 0, compressedPages: 0, pageSize: 16_384,
                           physicalBytes: 34_359_738_368)
    #expect(try document(sample(memory: tiny)).memory?.usedPercent == 100)
}

@Test func unreadableMemoryIsNullNotAZero() throws {
    // No physical memory read is a positive denominator; the metric is published null, never 0.
    let none = MemoryUsage(activePages: 1, wiredPages: 0, compressedPages: 0, pageSize: 16_384, physicalBytes: 0)
    #expect(try document(sample(memory: none)).memory == nil)
}

@Test func failedReadsAreNullNotTheKeptFigures() throws {
    // The window keeps its last disk and network rates on a failed read; the status takes this tick's only.
    let status = try document(sample(cpuPercent: nil, memory: nil, disk: nil, network: nil, warningCount: nil))
    #expect(status.disk == nil)
    #expect(status.network == nil)
    #expect(status.cpuPercent == nil)
    #expect(status.memory == nil)
    #expect(status.warningCount == nil)
    #expect(try encodedObject(status)["disk"] is NSNull)
}

@Test func outOfRangeMetricsBecomeNull() throws {
    #expect(try document(sample(cpuPercent: 100)).cpuPercent == 100)
    #expect(try document(sample(cpuPercent: .nan)).cpuPercent == nil)
    #expect(try document(sample(cpuPercent: .infinity)).cpuPercent == nil)
    #expect(try document(sample(cpuPercent: -0.5)).cpuPercent == nil)
    #expect(try document(sample(cpuPercent: 100.5)).cpuPercent == nil)
    #expect(try document(sample(warningCount: -1)).warningCount == nil)
}

@Test func anUnusableIntervalProducesNoDocument() throws {
    // Without a positive finite interval the tick cannot make a valid document: nothing is published, so no
    // timestamp advances over a sampling gap.
    for interval in [0, -1, Double.nan, .infinity] {
        #expect(ResourceStatus(sample: sample(intervalSeconds: interval)) == nil, "interval \(interval)")
    }
}

@Test func resourceLevelStaysNullUntilCalibrated() throws {
    // The reserved vocabulary encodes; every production path passes nothing yet.
    let level = try document(sample(resourceLevel: .triage))
    #expect(try encodedObject(level)["resourceLevel"] as? String == "triage")
    #expect(try document(sample()).resourceLevel == nil)
    #expect(ResourceStatus.Level.allCases.map(\.rawValue) == ["normal", "notice", "triage", "critical"])
}

// MARK: - The reader's freshness rules

@Test func ageIsRecomputedOnEveryRead() throws {
    let published = try status(at: fixtureEpoch, warnings: 0)
    let data = try JSONEncoder().encode(published)
    #expect(ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch + 10))
            == .fresh(published, age: 10))
    // One millisecond past the cutoff the same bytes read stale; reading again recomputes, never freezes.
    guard case .stale(_, let age) = ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch + 10.001))
    else { Issue.record("not stale just past the cutoff"); return }
    #expect(abs(age - 10.001) < 1e-6)
    guard case .stale(_, let later) = ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch + 60))
    else { Issue.record("not stale a minute on"); return }
    #expect(later == 60)
}

@Test func futureDatedDocumentsAreUnavailable() throws {
    let data = try JSONEncoder().encode(status(at: fixtureEpoch, warnings: 0))
    #expect(ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch - 0.001))
            == .unavailable(.futureDated))
}

@Test func missingAndUnsupportedDocumentsAreUnavailable() throws {
    #expect(ResourceStatusReader.read(nil, now: Date()) == .unavailable(.missing))
    // An empty file is a document that starts but never finishes: malformed, not missing.
    #expect(ResourceStatusReader.read(Data(), now: Date()) == .unavailable(.malformed))
    var object = try fixtureObject() as? [String: Any] ?? [:]
    object["schemaVersion"] = 2
    let newer = try JSONSerialization.data(withJSONObject: object)
    #expect(ResourceStatusReader.read(newer, now: Date(timeIntervalSince1970: fixtureEpoch))
            == .unavailable(.unsupportedVersion(2)))
}

@Test func malformedDocumentsAreUnavailable() throws {
    // Truncated, missing a required key, not an object, a bad timestamp, no machine: all unavailable, never a guess.
    let truncated = fixtureData().prefix(80)
    #expect(ResourceStatusReader.read(Data(truncated), now: Date(timeIntervalSince1970: fixtureEpoch))
            == .unavailable(.malformed))
    for key in ["cpuPercent", "sampledAt", "intervalSeconds", "machine"] {
        var object = try fixtureObject() as? [String: Any] ?? [:]
        object.removeValue(forKey: key)
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch)) == .unavailable(.malformed),
                "missing \(key)")
    }
    for (key, value) in [("sampledAt", "yesterday"), ("machine", ""), ("schemaVersion", "one"), ("intervalSeconds", 0)] as [(String, Any)] {
        var object = try fixtureObject() as? [String: Any] ?? [:]
        object[key] = value
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch)) == .unavailable(.malformed),
                "bad \(key) = \(value)")
    }
    #expect(ResourceStatusReader.read(Data("[]".utf8), now: Date()) == .unavailable(.malformed))
}

@Test func fractionalTimestampsReadAsRFC3339() throws {
    // A future producer may keep sub-second precision; the reader accepts it rather than calling it malformed.
    var object = try fixtureObject() as? [String: Any] ?? [:]
    object["sampledAt"] = "2026-10-28T12:00:00.500Z"
    let data = try JSONSerialization.data(withJSONObject: object)
    guard case .fresh(let status, _) = ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch + 1))
    else { Issue.record("fractional timestamp refused"); return }
    #expect(status.sampledAt == Date(timeIntervalSince1970: fixtureEpoch + 0.5))
}

@Test func invalidMetricsReadAsUnavailableInAFreshEnvelope() throws {
    // The envelope stays fresh; a bad metric is unavailable, never shown as a number and never zeroed.
    var object = try fixtureObject() as? [String: Any] ?? [:]
    object["cpuPercent"] = 150.0
    object["disk"] = ["readBytesPerSecond": -1, "writeBytesPerSecond": 524_288] as [String: Any]
    object["memory"] = ["usedBytes": 4_096, "physicalBytes": 0, "usedPercent": 50.0] as [String: Any]
    let data = try JSONSerialization.data(withJSONObject: object)
    guard case .fresh(let status, _) = ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch))
    else { Issue.record("envelope refused"); return }
    #expect(status.cpuPercent == nil)
    #expect(status.disk == nil)
    #expect(status.memory == nil)
    #expect(status.network == ResourceStatus.Network(inBytesPerSecond: 262_144, outBytesPerSecond: 131_072))
    #expect(status.warningCount == 0)
}

@Test func aNullMetricStaysUnavailableInAFreshEnvelope() throws {
    var object = try fixtureObject() as? [String: Any] ?? [:]
    object["cpuPercent"] = NSNull()
    object["network"] = NSNull()
    let data = try JSONSerialization.data(withJSONObject: object)
    guard case .fresh(let status, _) = ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch))
    else { Issue.record("envelope refused"); return }
    #expect(status.cpuPercent == nil)
    #expect(status.network == nil)
}

// MARK: - Atomic publication

@Test func firstPublicationCreatesTheFileAt0600() throws {
    // No destination and neither folder exists yet: the producer makes them and publishes the first document.
    let root = temporaryFolder("first")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Saur0n/live-status.json")
    let producer = ResourceStatusProducer(url: url)
    let published = try status(at: fixtureEpoch, warnings: 0)
    try producer.publish(published)

    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    let read = ResourceStatusReader.read(try Data(contentsOf: url), now: Date(timeIntervalSince1970: fixtureEpoch))
    #expect(read == .fresh(published, age: 0))
    // The uniquely named sibling went with the rename: only the status is left.
    let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(names == ["live-status.json"])
}

@Test func laterPublicationsReplaceTheWholeDocument() throws {
    let root = temporaryFolder("replace")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("live-status.json")
    let producer = ResourceStatusProducer(url: url)
    let first = try status(at: fixtureEpoch, warnings: 0)
    try producer.publish(first)
    let replaced = try document(sample(sampledAt: Date(timeIntervalSince1970: fixtureEpoch + 1), intervalSeconds: 0.8,
                                       cpuPercent: 61, memory: nil, disk: nil, network: nil, warningCount: 2))
    try producer.publish(replaced)
    let data = try Data(contentsOf: url)
    guard case .fresh(let status, _) = ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch + 1))
    else { Issue.record("replaced document unreadable"); return }
    #expect(status.cpuPercent == 61)
    #expect(status.intervalSeconds == 0.8)
    #expect(status.warningCount == 2)
    #expect(status.disk == nil)
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(names == ["live-status.json"])
}

@Test func aFailedPublicationKeepsThePreviousDocument() throws {
    // The folder takes no new file: the write fails before the rename, and the last complete document and its
    // timestamp stay exactly as they were.
    let root = temporaryFolder("failure")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    let url = root.appendingPathComponent("live-status.json")
    let producer = ResourceStatusProducer(url: url)
    let first = try status(at: fixtureEpoch, warnings: 0)
    try producer.publish(first)
    let before = try Data(contentsOf: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

    let second = try status(at: fixtureEpoch + 1, warnings: 3)
    #expect(throws: (any Error).self) { try producer.publish(second) }
    let after = try Data(contentsOf: url)
    #expect(after == before)
    #expect(ResourceStatusReader.read(after, now: Date(timeIntervalSince1970: fixtureEpoch + 60)) == .stale(first, age: 60))
}

@Test func aReaderNeverSeesAPartialDocument() throws {
    // One writer replacing the document while a reader reads it: every read is the previous or the next complete
    // document, never a torn one, and the last write is what remains.
    let root = temporaryFolder("concurrent")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("live-status.json")
    let producer = ResourceStatusProducer(url: url)
    let first = try status(at: fixtureEpoch, warnings: 0)
    let last = try document(sample(sampledAt: Date(timeIntervalSince1970: fixtureEpoch + 200), warningCount: 7))
    try producer.publish(first)

    let written = DispatchSemaphore(value: 0)
    DispatchQueue(label: "saur0n.status.writer").async {
        for index in 0..<200 {
            let value = index == 199 ? last : (try? status(at: fixtureEpoch + Double(index), warnings: index % 5))
            if let value { try? producer.publish(value) }
        }
        written.signal()
    }
    var reads = 0
    while written.wait(timeout: .now()) == .timedOut {
        guard let data = try? Data(contentsOf: url) else { continue }
        reads += 1
        switch ResourceStatusReader.read(data, now: Date(timeIntervalSince1970: fixtureEpoch + 200)) {
        case .fresh, .stale: break
        case .unavailable(let reason): Issue.record("a reader saw \(reason)")
        }
    }
    #expect(reads > 0)
    let final = try Data(contentsOf: url)
    #expect(ResourceStatusReader.read(final, now: Date(timeIntervalSince1970: fixtureEpoch + 200)) == .fresh(last, age: 0))
}

@Test func theDefaultURLIsProducersOwnFileInApplicationSupport() {
    let home = URL(fileURLWithPath: "/fixtures/example")
    #expect(ResourceStatusProducer.defaultURL(home: home).path
            == "/fixtures/example/Library/Application Support/Saur0n/live-status.json")
    #expect(ResourceStatusProducer.defaultURL(home: home).lastPathComponent == "live-status.json")
}

// MARK: - The approved switches

/// A lookup over the values given, as `UserDefaults.standard.object(forKey:)` reads a defaults domain. The tests
/// never write a default: the switches are read from these dictionaries alone.
private func defaults(_ values: [String: Any]) -> (String) -> Any? { { values[$0] } }

@Test func liveStatusIsOffByDefault() {
    // Neither key set, as a Mac that has never been activated: no nickname, so nothing is published.
    #expect(LiveStatusSwitches.machine(defaults([:])) == nil)
}

@Test func theProNicknameAloneIsPermitted() {
    let values: [String: Any] = [LiveStatusSwitches.enabledKey: true, LiveStatusSwitches.machineKey: "Pro"]
    #expect(LiveStatusSwitches.machine(defaults(values)) == "Pro")
}

@Test func anotherNicknameStaysInert() {
    for nickname in ["pro", "PRO", "Pro ", " Pro", "Air", "Mini", ""] {
        let values: [String: Any] = [LiveStatusSwitches.enabledKey: true, LiveStatusSwitches.machineKey: nickname]
        #expect(LiveStatusSwitches.machine(defaults(values)) == nil, "\(nickname) was activated")
    }
}

@Test func aMissingNicknameStaysInert() {
    #expect(LiveStatusSwitches.machine(defaults([LiveStatusSwitches.enabledKey: true])) == nil)
}

@Test func theNicknameAloneStaysInert() {
    // The permitted nickname with the switch absent: nothing activates, so no Mac is labelled by name alone.
    #expect(LiveStatusSwitches.machine(defaults([LiveStatusSwitches.machineKey: "Pro"])) == nil)
}

@Test func theSwitchOffLeavesTheNicknameInert() {
    for off in [false, 0, "NO", "false", ""] as [Any] {
        let values: [String: Any] = [LiveStatusSwitches.enabledKey: off, LiveStatusSwitches.machineKey: "Pro"]
        #expect(LiveStatusSwitches.machine(defaults(values)) == nil, "switch \(off) activated")
    }
}

@Test func theSwitchReadsAsTheDefaultsReadIt() {
    // A value reads as `bool(forKey:)` reads it, so a launch argument (`-liveStatus.enabled YES`, a string in the
    // argument domain) switches publication on for that process alone, without a defaults write.
    for on in [true, 1, "YES", "true", "1"] as [Any] {
        let values: [String: Any] = [LiveStatusSwitches.enabledKey: on, LiveStatusSwitches.machineKey: "Pro"]
        #expect(LiveStatusSwitches.machine(defaults(values)) == "Pro", "switch \(on) did not activate")
    }
    let unclear: [String: Any] = [LiveStatusSwitches.enabledKey: "maybe", LiveStatusSwitches.machineKey: "Pro"]
    #expect(LiveStatusSwitches.machine(defaults(unclear)) == nil)
}
