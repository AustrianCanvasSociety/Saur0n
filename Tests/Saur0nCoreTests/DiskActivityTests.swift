// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the machine's and each process's disk read and write rates, summed into groups, and the remainder no
// readable row holds. Method: recorded counter pairs and driver listings (this Mac's NVMe namespace, an SD-card
// slot, two disk images) through the pure rules, and hand-built rows through the groupings and the snapshot.

private let second: UInt64 = 1_000_000_000

// MARK: rates

@Test func rateFromTwoReads() {
    let rate = DiskActivity.rate(before: DiskBytes(read: 1_000, written: 2_000), after: DiskBytes(read: 3_000, written: 2_500),
                                 nanoseconds: 2 * second)
    #expect(rate == DiskRate(readBytesPerSecond: 1_000, writeBytesPerSecond: 250))
}

@Test func rateCounterStillIsZero() {
    let bytes = DiskBytes(read: 7_000, written: 9_000)
    #expect(DiskActivity.rate(before: bytes, after: bytes, nanoseconds: second) == .zero)
}

@Test func counterWentBackwardsReadsZero() {
    let rate = DiskActivity.rate(before: DiskBytes(read: 5_000, written: 5_000), after: DiskBytes(read: 4_000, written: 6_000),
                                 nanoseconds: second)
    #expect(rate == DiskRate(readBytesPerSecond: 0, writeBytesPerSecond: 1_000))
}

@Test func zeroElapsedReadsZero() {
    #expect(DiskActivity.rate(before: .zero, after: DiskBytes(read: 10, written: 10), nanoseconds: 0) == .zero)
}

@Test func machineRateUsesTheReadsOwnStamps() {
    let usage = DiskActivity.usage(before: MachineDiskSample(bytes: .zero, uptimeNanoseconds: 10 * second),
                                   after: MachineDiskSample(bytes: DiskBytes(read: 3_000, written: 1_500),
                                                            uptimeNanoseconds: 13 * second))
    #expect(usage == DiskUsage(rate: DiskRate(readBytesPerSecond: 1_000, writeBytesPerSecond: 500),
                               bytes: DiskBytes(read: 3_000, written: 1_500)))
}

@Test func rateReadingFailureKeepsDisplayButAddsNoGraphPoint() {
    var reading = RateReading<DiskBytes, DiskUsage>()
    var history = RateHistory()
    for tick in 0...4 {
        let sample = tick == 2 || tick == 3 ? nil : MachineDiskSample(
            bytes: DiskBytes(read: UInt64(tick) * 100, written: UInt64(tick) * 200),
            uptimeNanoseconds: UInt64(tick) * second, epochSeconds: Double(tick))
        reading.record(sample, measure: DiskActivity.usage)
        if let fresh = reading.tick { history.append(fresh.readBytesPerSecond, fresh.writeBytesPerSecond) }
        if tick == 2 || tick == 3 {
            #expect(reading.tick == nil)
            #expect(reading.latest?.readBytesPerSecond == 100)
            #expect(reading.window?.end == 1)
        }
    }
    #expect(history.first == [100, 100])
    #expect(history.second == [200, 200])
    #expect(reading.latest?.readBytes == 400)
    #expect(reading.window?.start == 1)
    #expect(reading.window?.end == 4)
}

@Test func rateReadingFailureBeforeBaselineDoesNotInventTraffic() {
    var reading = RateReading<NetworkBytes, NetworkUsage>()
    reading.record(nil, measure: NetworkActivity.usage)
    #expect(reading.latest == nil)
    #expect(reading.tick == nil)
    reading.record(MachineNetworkSample(bytes: NetworkBytes(received: 500, sent: 1_000),
                                       uptimeNanoseconds: second), measure: NetworkActivity.usage)
    #expect(reading.latest == nil)
    #expect(reading.window == nil)
    reading.record(nil, measure: NetworkActivity.usage)
    reading.record(MachineNetworkSample(bytes: NetworkBytes(received: 1_100, sent: 1_300),
                                       uptimeNanoseconds: 4 * second), measure: NetworkActivity.usage)
    #expect(reading.tick?.rate == NetworkRate(inBytesPerSecond: 200, outBytesPerSecond: 100))
}

@Test func diskSumsSaturateWithoutWrapping() {
    let high = DiskUsage(rate: DiskRate(readBytesPerSecond: .max - 1, writeBytesPerSecond: .max),
                         bytes: DiskBytes(read: .max - 1, written: .max))
    let small = DiskUsage(rate: DiskRate(readBytesPerSecond: 2, writeBytesPerSecond: 1),
                          bytes: DiskBytes(read: 2, written: 1))
    let sum = DiskActivity.sum([nil, high, small])
    #expect(sum.readBytesPerSecond == .max)
    #expect(sum.writeBytesPerSecond == .max)
    #expect(sum.readBytes == .max)
    #expect(sum.writeBytes == .max)
    #expect(high.rate.totalBytesPerSecond == .max)
    #expect(DiskActivity.unattributed(machine: DiskRate(readBytesPerSecond: 10, writeBytesPerSecond: 10),
                                    rows: [high, small]) == .zero)
    let drivers = [high, small].map { BlockStorageDriver(ancestorClasses: [], bytes: DiskBytes(read: $0.readBytes,
                                                                                           written: $0.writeBytes)) }
    #expect(DiskActivity.physical(drivers) == DiskBytes(read: .max, written: .max))
    #expect(DiskRate(readBytesPerSecond: .max - 1, writeBytesPerSecond: 1).totalBytesPerSecond == .max)
}

private func namedDiskSample(_ counters: [(String, UInt64, UInt64)], tick: UInt64) throws -> MachineDiskSample {
    let read = try MachineDiskReader.read(listing: {
        counters.map { BlockStorageDriver(ancestorClasses: [], bytes: DiskBytes(read: $0.1, written: $0.2), bsdName: $0.0) }
    })
    var sample = MachineDiskSample(bytes: read.bytes, uptimeNanoseconds: tick * second)
    sample.sources = read.sources
    return sample
}

@Test func diskSourceChurnKeepsOnlyContinuingTraffic() throws {
    let listings: [[(String, UInt64, UInt64)]] = [
        [("disk0", 100, 200), ("disk7", 10_000, 20_000)],
        [("disk0", 300, 600)],
        [("disk8", 90_000, 80_000), ("disk0", 500, 1_000)],
        [("disk0", 700, 1_400), ("disk8", 90_100, 5)],
        [("disk9", 900_000, 800_000)],
    ]
    let samples = try listings.enumerated().map { try namedDiskSample($0.element, tick: UInt64($0.offset) * 2) }
    let rates = zip(samples, samples.dropFirst()).map { DiskActivity.usage(before: $0, after: $1).rate }
    #expect(rates == [DiskRate(readBytesPerSecond: 100, writeBytesPerSecond: 200),
                      DiskRate(readBytesPerSecond: 100, writeBytesPerSecond: 200),
                      DiskRate(readBytesPerSecond: 150, writeBytesPerSecond: 200), .zero])
    #expect(DiskActivity.usage(before: samples[1], after: samples[2]).readBytes == 90_500)
    #expect(DiskActivity.usage(before: samples[1], after: samples[1]).rate == .zero)
}

@Test func diskSourceDeltasSurviveSaturatedAggregateCounters() throws {
    let before = try namedDiskSample([("disk0", .max - 10, 0), ("disk7", 20, 0)], tick: 0)
    let after = try namedDiskSample([("disk7", 40, 0), ("disk0", .max, 0)], tick: 1)
    #expect(before.bytes.read == .max)
    #expect(after.bytes.read == .max)
    #expect(DiskActivity.usage(before: before, after: after).readBytesPerSecond == 30)
}

// MARK: physical drivers

/// The block-storage drivers of the Mac the step was built on (registry, 2026-10-21; counters made small): the
/// internal NVMe namespace, the SD-card slot (empty), a USB drive and two mounted disk images, ancestors nearest
/// first, cut to four.
private let recordedDrivers = [
    BlockStorageDriver(ancestorClasses: ["IOEmbeddedNVMeBlockDevice", "AppleANS3CGv2Controller", "RTBuddyService", "RTBuddy"],
                       bytes: DiskBytes(read: 10, written: 20)),
    BlockStorageDriver(ancestorClasses: ["AppleSDXCBlockStorageDevice", "AppleSDXCSlot", "AppleSDXC", "IOPCIDevice"],
                       bytes: .zero),
    BlockStorageDriver(ancestorClasses: ["IOBlockStorageServices", "IOSCSIPeripheralDeviceType00", "IOSCSILogicalUnitNub",
                                         "IOUSBMassStorageDriver"], bytes: DiskBytes(read: 1, written: 2)),
    BlockStorageDriver(ancestorClasses: ["AppleDiskImageDevice", "AppleDiskImagesController", "IOResources",
                                         "IOPlatformExpertDevice"], bytes: DiskBytes(read: 5, written: 5)),
    BlockStorageDriver(ancestorClasses: ["AppleDiskImageDevice", "AppleDiskImagesController", "IOResources",
                                         "IOPlatformExpertDevice"], bytes: DiskBytes(read: 7, written: 3)),
]

@Test func onlyPhysicalDriversAreSummed() {
    #expect(DiskActivity.physical(recordedDrivers) == DiskBytes(read: 11, written: 22))
}

@Test func diskStatisticsRequireBothByteCounters() {
    #expect(MachineDiskReader.bytes(statistics: ["Bytes (Read)": NSNumber(value: 10),
                                                "Bytes (Write)": NSNumber(value: 20)]) == DiskBytes(read: 10, written: 20))
    #expect(MachineDiskReader.bytes(statistics: ["Bytes (Read)": NSNumber(value: 0),
                                                "Bytes (Write)": NSNumber(value: 0)]) == .zero)
    #expect(MachineDiskReader.bytes(statistics: [:]) == nil)
    #expect(MachineDiskReader.bytes(statistics: ["Bytes (Read)": NSNumber(value: 10)]) == nil)
    #expect(MachineDiskReader.bytes(statistics: ["Bytes (Write)": NSNumber(value: 20)]) == nil)
    #expect(MachineDiskReader.bytes(statistics: ["Bytes (Read)": "10", "Bytes (Write)": NSNumber(value: 20)]) == nil)
    #expect(MachineDiskReader.bytes(statistics: ["Bytes (Read)": NSNumber(value: -1),
                                                "Bytes (Write)": NSNumber(value: 20)]) == nil)
}

@Test func unreadableMachineCountersIsAnError() throws {
    #expect(throws: DiskActivityError.unreadable) { try MachineDiskReader.read(listing: { nil }) }
    // Only disk images: nothing physical was read.
    #expect(throws: DiskActivityError.unreadable) { try MachineDiskReader.read(listing: { Array(recordedDrivers.suffix(2)) }) }
    #expect(try MachineDiskReader.read(listing: { recordedDrivers }).bytes == DiskBytes(read: 11, written: 22))
}

// MARK: rows, groups, remainder

private func identity(_ pid: Int32, uid: UInt32 = 501, start: UInt64 = 1_000) -> ProcessIdentity {
    ProcessIdentity(pid: pid, ppid: 1, uid: uid, user: uid == 0 ? "root" : "alice", startMicroseconds: start,
                    comm: "proc", path: nil)
}

private func sample(at uptime: UInt64, _ processes: [ProcessIdentity], taskInfo: [Int32: ProcessCounters] = [:],
                    ps: [Int32: PSRow] = [:], disk: [Int32: DiskBytes] = [:],
                    rusageAt: [Int32: UInt64] = [:]) -> ProcessListSample {
    ProcessListSample(uptimeNanoseconds: uptime, processes: processes, taskInfo: taskInfo, ps: ps, diskBytes: disk,
                      readAt: ReadTimes(rusage: rusageAt))
}

private let busy = ProcessCounters(cpuNanoseconds: 0, residentBytes: 4096)

@Test func processRateOverItsOwnRusageReads() throws {
    let before = sample(at: 0, [identity(10)], taskInfo: [10: busy], disk: [10: DiskBytes(read: 0, written: 1_000)],
                        rusageAt: [10: second])
    let after = sample(at: 2 * second, [identity(10)], taskInfo: [10: busy], disk: [10: DiskBytes(read: 4_000, written: 3_000)],
                       rusageAt: [10: 3 * second])
    let row = try #require(ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil).first)
    #expect(row.disk == DiskUsage(rate: DiskRate(readBytesPerSecond: 2_000, writeBytesPerSecond: 1_000),
                                  bytes: DiskBytes(read: 4_000, written: 3_000)))
}

@Test func newInWindowRatesZeroKeepsCumulative() throws {
    let after = sample(at: 2 * second, [identity(10)], taskInfo: [10: busy], disk: [10: DiskBytes(read: 4_000, written: 3_000)])
    let row = try #require(ProcessSample.usage(before: sample(at: 0, []), after: after, cpuCount: 1, kernelTask: nil).first)
    #expect(row.disk == DiskUsage(rate: .zero, bytes: DiskBytes(read: 4_000, written: 3_000)))
}

@Test func unreadableRowHasNoDisk() throws {
    let root = identity(1, uid: 0)
    let ps = [Int32(1): PSRow(counters: busy, comm: "launchd")]
    let rows = try ProcessSample.usage(before: sample(at: 0, [root], ps: ps), after: sample(at: second, [root], ps: ps),
                                       cpuCount: 1, kernelTask: nil)
    #expect(rows.map(\.source) == [.ps])
    #expect(rows.first?.disk == nil)
    // An own process whose task info failed but whose rusage read: still a ps row, still no disk figure.
    let own = identity(10)
    let ownPS = [Int32(10): PSRow(counters: busy, comm: "proc")]
    let bytes = [Int32(10): DiskBytes(read: 1, written: 2)]
    let ownRows = try ProcessSample.usage(before: sample(at: 0, [own], ps: ownPS, disk: bytes),
                                          after: sample(at: second, [own], ps: ownPS, disk: bytes), cpuCount: 1, kernelTask: nil)
    #expect(ownRows.map(\.source) == [.ps])
    #expect(ownRows.first?.disk == nil)
}

private func row(_ pid: Int32, uid: UInt32 = 501, disk: DiskUsage?) -> ProcessUsage {
    ProcessUsage(pid: pid, ppid: 1, uid: uid, user: uid == 0 ? "root" : "alice", path: nil, name: "proc",
                 cpuPercent: 0, residentBytes: 1024, source: disk == nil ? .ps : .libproc, disk: disk)
}

private func disk(_ read: UInt64, _ write: UInt64) -> DiskUsage {
    DiskUsage(rate: DiskRate(readBytesPerSecond: read, writeBytesPerSecond: write), bytes: DiskBytes(read: read * 10, written: write * 10))
}

private let noSessions = SessionSources(registry: [], startSeconds: [:], environmentSessionIDs: [:], tmuxPanes: [:], tty: [:],
                                        ownUID: 501)

@Test func groupSumsByRepoAndSession() {
    let rows = [row(10, disk: disk(100, 200)), row(11, disk: disk(300, 400))]
    let repo = RepoInfo(name: "alpha", root: "/work/alpha", worktree: nil)
    let grouped = RepoGroups.assign(rows, workingDirectories: [10: "/work/alpha", 11: "/work/alpha"],
                                    repoOfDirectory: { _ in repo }, repoOfExecutable: { _ in nil })
    #expect(grouped.groups.map(\.disk) == [disk(400, 600)])
    let sessions = SessionGroups.assign(rows, sources: noSessions)
    #expect(sessions.groups.map(\.disk) == [disk(400, 600)])
}

@Test func unreadableRowIsZeroInItsGroup() {
    let rows = [row(1, uid: 0, disk: nil), row(2, uid: 0, disk: disk(5, 7))]
    let grouped = RepoGroups.assign(rows, workingDirectories: [:], repoOfDirectory: { _ in nil }, repoOfExecutable: { _ in nil })
    #expect(grouped.groups.map(\.disk) == [disk(5, 7)])
}

@Test func unattributedRemainder() throws {
    let machine = DiskUsage(rate: DiskRate(readBytesPerSecond: 1_000, writeBytesPerSecond: 1_000), bytes: .zero)
    let rows = [row(10, disk: disk(500, 1_000)), row(11, disk: disk(100, 200)), row(1, uid: 0, disk: nil)]
    #expect(DiskActivity.unattributed(machine: machine.rate, rows: rows.map(\.disk))
                == DiskRate(readBytesPerSecond: 400, writeBytesPerSecond: 0))
    let topology = CoreTopology.singleLevel(logicalCPUCount: 1)
    let load = CPULoad(perCPU: [0], total: 0)
    let grouped = try Snapshot(topology: topology, load: load, intervalSeconds: 1, processes: rows,
                               repoGroups: RepoGroups.assign(rows, workingDirectories: [:], repoOfDirectory: { _ in nil },
                                                             repoOfExecutable: { _ in nil }).groups, disk: machine)
    #expect(grouped.unattributedDisk == DiskRate(readBytesPerSecond: 400, writeBytesPerSecond: 0))
    let ungrouped = try Snapshot(topology: topology, load: load, intervalSeconds: 1, processes: rows, disk: machine)
    #expect(ungrouped.unattributedDisk == nil)
}

// MARK: text

@Test func bytesPerSecondText() {
    #expect(TextFormat.bytesPerSecondText(0) == "0")
    #expect(TextFormat.bytesPerSecondText(999) == "999 B/s")
    #expect(TextFormat.bytesPerSecondText(1_000) == "1.0 K/s")
    #expect(TextFormat.bytesPerSecondText(850_000) == "850.0 K/s")
    #expect(TextFormat.bytesPerSecondText(1_234_567) == "1.2 M/s")
    #expect(TextFormat.bytesPerSecondText(999_960) == "1.0 M/s")
    #expect(TextFormat.bytesPerSecondText(3_400_000_000) == "3.4 G/s")
}

@Test func tableShowsDiskColumnAndHeaderLine() throws {
    let rows = [row(10, disk: disk(1_000_000, 234_567)), row(1, uid: 0, disk: nil)]
    let groups = RepoGroups.assign(rows, workingDirectories: [10: "/x"], repoOfDirectory: { _ in nil },
                                   repoOfExecutable: { _ in nil }).groups
    let machine = DiskUsage(rate: DiskRate(readBytesPerSecond: 12_300_000, writeBytesPerSecond: 4_500_000), bytes: .zero)
    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1), load: CPULoad(perCPU: [0], total: 0),
                                intervalSeconds: 1, processes: rows, repoGroups: groups, disk: machine)
    let lines = snapshot.table().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines[1] == "Disk  R 12.3 M/s  W 4.5 M/s")
    #expect(lines.contains("    PID   PPID  USER     CPU   MEM       DISK  NAME"))
    #expect(lines.contains("Not in a repo  0.0%  1.0K  1.2 M/s  1 process"))
    #expect(lines.contains("     10      1  alice   0.0%  1.0K    1.2 M/s  proc"))
    #expect(lines.contains("      1      1  root    0.0%  1.0K          —  proc"))
    #expect(lines.last == "Unattributed disk  R 11.3 M/s  W 4.3 M/s")
    // Ungrouped: no remainder line; no disk read at all: no header line and no column.
    let plain = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1), load: CPULoad(perCPU: [0], total: 0),
                             intervalSeconds: 1, processes: [row(1, uid: 0, disk: nil)])
    #expect(!plain.table().contains("Disk"))
    #expect(!plain.table().contains("DISK"))
}

@Test func jsonCarriesTheMachineReadTimes() throws {
    let before = MachineDiskSample(bytes: .zero, uptimeNanoseconds: second, epochSeconds: 1_700_000_000.25)
    let after = MachineDiskSample(bytes: DiskBytes(read: 2, written: 4), uptimeNanoseconds: 3 * second,
                                  epochSeconds: 1_700_000_002.5)
    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1), load: CPULoad(perCPU: [0], total: 0),
                                intervalSeconds: 2, disk: DiskActivity.usage(before: before, after: after),
                                diskWindow: DiskWindow(before: before, after: after))
    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    let disk = try #require(object["disk"] as? [String: Any])
    #expect(disk["windowStart"] as? Double == 1_700_000_000.25)
    #expect(disk["windowEnd"] as? Double == 1_700_000_002.5)
    #expect(disk["writeBytesPerSecond"] as? Int == 2)
    // The rows' and groups' disk carry no window: only the machine's reads are stamped.
    #expect(!snapshot.table().contains("window"))
}

@Test func jsonCarriesDisk() throws {
    let rows = [row(10, disk: disk(100, 200)), row(1, uid: 0, disk: nil)]
    let groups = RepoGroups.assign(rows, workingDirectories: [10: "/x"], repoOfDirectory: { _ in nil },
                                   repoOfExecutable: { _ in nil }).groups
    let sessions = SessionGroups.assign(rows, sources: noSessions).groups
    let machine = DiskUsage(rate: DiskRate(readBytesPerSecond: 1_000, writeBytesPerSecond: 1_000),
                            bytes: DiskBytes(read: 5, written: 6))
    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1), load: CPULoad(perCPU: [0], total: 0),
                                intervalSeconds: 1, processes: rows, repoGroups: groups, sessionGroups: sessions,
                                disk: machine)
    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    let keys: Set<String> = ["readBytesPerSecond", "writeBytesPerSecond", "readBytes", "writeBytes"]
    let top = try #require(object["disk"] as? [String: Any])
    #expect(Set(top.keys) == keys)
    #expect(top["writeBytes"] as? Int == 6)
    let rest = try #require(object["unattributedDisk"] as? [String: Any])
    #expect(rest as NSDictionary == ["readBytesPerSecond": 900, "writeBytesPerSecond": 800] as NSDictionary)
    let processes = try #require(object["processes"] as? [[String: Any]])
    #expect(Set(try #require(processes[0]["disk"] as? [String: Any]).keys) == keys)
    #expect(processes[1]["disk"] is NSNull)
    for name in ["repoGroups", "sessionGroups"] {
        let group = try #require((object[name] as? [[String: Any]])?.first?["disk"] as? [String: Any])
        #expect(Set(group.keys) == keys)
    }
}
