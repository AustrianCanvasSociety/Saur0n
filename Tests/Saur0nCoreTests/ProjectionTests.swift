// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the memory projection (Phase 7 Step 2) — a nested-window least-squares decline of the available-page composite
// (free + inactive + speculative + purgeable) projected to max(4 GB, 12% of RAM), naming the process whose memory grew.
// Method: tick series built in code from the plan's floor and the 2026-10-25 crash's shape (research 2026-10-25). Every
// window, sample count and decline bar here is a TEST-ONLY setting: production ships no ETA windows until the user
// calibrates them.

private let gib: UInt64 = 1 << 30
private let physical = 64 * gib

/// TEST-ONLY: 60 s and 180 s trailing windows, ten samples, a decline of at least 1 MiB/s.
private let testConfig = MemoryProjection.Config(windows: [60, 180], minimumSamples: 10,
                                                 minimumDeclineBytesPerSecond: Double(1 << 20))

/// Available memory with `available` bytes available and no used pages.
private func memory(available: UInt64, swap: UInt64? = nil) -> AvailableMemory {
    AvailableMemory(freeBytes: available, inactiveBytes: 0, speculativeBytes: 0, purgeableBytes: 0,
                    activeBytes: 0, wiredBytes: 0, compressedBytes: 0, physicalBytes: physical, swapUsedBytes: swap)
}

/// A process row of `resident` bytes, not the user's own.
private func row(_ pid: Int32, _ name: String, resident: UInt64, cpu: Double = 0) -> ProcessUsage {
    ProcessUsage(pid: pid, ppid: 1, uid: 501, user: "user", path: "/usr/bin/" + name, name: name,
                 cpuPercent: cpu, residentBytes: resident, source: .libproc)
}

/// The floor the plan fixes: 4 GB, or 12% of physical memory, whichever is larger.
@Test func memoryFloorIsFourGigabytesOrTwelvePercent() {
    #expect(MemoryFloor.bytes(physicalBytes: 16 * gib) == 4 * gib)
    #expect(MemoryFloor.bytes(physicalBytes: 64 * gib) == 7 * gib + gib * 68 / 100)
    #expect(MemoryFloor.bytes(physicalBytes: 0) == 4 * gib)
}

/// The available composite is free + inactive + speculative + purgeable; used is active + wired + compressed.
@Test func availableCompositeSumsItsPages() {
    let memory = AvailableMemory(freeBytes: 1, inactiveBytes: 2, speculativeBytes: 3, purgeableBytes: 4,
                                 activeBytes: 5, wiredBytes: 6, compressedBytes: 7, physicalBytes: 100)
    #expect(memory.availableBytes == 10)
    #expect(memory.usedBytes == 18)
}

/// Both percentage bases divide by physical memory: the display one counts active, wired and compressed; the level one
/// counts everything not available.
@Test func usedPercentFollowsItsBasis() {
    let halfUsed = AvailableMemory(freeBytes: 10, inactiveBytes: 40, speculativeBytes: 0, purgeableBytes: 0,
                                   activeBytes: 30, wiredBytes: 10, compressedBytes: 10, physicalBytes: 100)
    #expect(halfUsed.usedPercent(.usedOfPhysical) == 50)
    #expect(halfUsed.usedPercent(.availableComplement) == 50)
    let cache = AvailableMemory(freeBytes: 10, inactiveBytes: 70, speculativeBytes: 0, purgeableBytes: 0,
                                activeBytes: 10, wiredBytes: 10, compressedBytes: 0, physicalBytes: 100)
    #expect(cache.usedPercent(.usedOfPhysical) == 20)
    #expect(cache.usedPercent(.availableComplement) == 20)
}

/// A fast grower's ETA is what is left above the floor divided by the fitted decline.
@Test func fastGrowerGetsItsTimeToFloor() {
    var projection = MemoryProjection(config: testConfig)
    let decline = 64.0 * Double(1 << 20)   // 64 MiB/s
    var eta: MemoryProjection.ETA?
    for second in 1...60 {
        let available = (30 * gib) - UInt64(decline * Double(second - 1))
        eta = projection.next(end: Double(second), memory: memory(available: available), rows: []).eta
    }
    let available = Double(30 * gib) - decline * 59
    let expected = (available - Double(MemoryFloor.bytes(physicalBytes: physical))) / decline
    #expect(abs((eta?.seconds ?? 0) - expected) < 2)
    #expect(eta?.window == 60)
}

/// A slow grower gets a longer ETA than a fast one, and no ETA below the decline bar.
@Test func slowGrowerGetsALongerETAAndAFlatOneGetsNone() {
    func eta(decline: Double) -> Double? {
        var projection = MemoryProjection(config: testConfig)
        var eta: MemoryProjection.ETA?
        for second in 1...60 {
            let available = (30 * gib) - UInt64(decline * Double(second - 1))
            eta = projection.next(end: Double(second), memory: memory(available: available), rows: []).eta
        }
        return eta?.seconds
    }
    let slow = eta(decline: 2.0 * Double(1 << 20))
    let fast = eta(decline: 64.0 * Double(1 << 20))
    let flat = eta(decline: 0)
    #expect(slow != nil && fast != nil && flat == nil)
    #expect((slow ?? 0) > (fast ?? 0))
}

/// Available memory that stays put has no crossing: a large, stable allocation is not a runway.
@Test func stableAvailableHasNoETA() {
    var projection = MemoryProjection(config: testConfig)
    var reading: MemoryProjection.Reading?
    for second in 1...120 {
        reading = projection.next(end: Double(second), memory: memory(available: gib * 9), rows: [])
    }
    #expect(reading?.eta == nil)
}

/// Below the floor the crossing has already happened: the ETA is zero.
@Test func belowTheFloorTheETAIsZero() {
    var projection = MemoryProjection(config: testConfig)
    var reading: MemoryProjection.Reading?
    for second in 1...20 {
        reading = projection.next(end: Double(second), memory: memory(available: 5 * gib), rows: [])
    }
    #expect(reading?.eta?.seconds == 0)
}

/// Nested windows: the shortest one with enough samples decides; without enough, the next one out is used.
@Test func nestedWindowsPickTheShortestWithEnoughSamples() {
    var short = MemoryProjection(config: testConfig)
    var long = MemoryProjection(config: MemoryProjection.Config(windows: [60, 180], minimumSamples: 80,
                                                                minimumDeclineBytesPerSecond: Double(1 << 20)))
    var shortETA: MemoryProjection.ETA?
    var longETA: MemoryProjection.ETA?
    for second in 1...100 {
        let available = (30 * gib) - UInt64(64.0 * Double(1 << 20) * Double(second - 1))
        shortETA = short.next(end: Double(second), memory: memory(available: available), rows: []).eta
        longETA = long.next(end: Double(second), memory: memory(available: available), rows: []).eta
    }
    #expect(shortETA?.window == 60)
    #expect(longETA?.window == 180)
}

/// The growth driver is the process whose resident memory grew most over the attribution window.
@Test func growthDriverIsTheBiggestGrower() {
    var projection = MemoryProjection(config: testConfig)
    var driver: MemoryProjection.GrowthDriver?
    for second in 1...40 {
        let available = (30 * gib) - UInt64(64.0 * Double(1 << 20) * Double(second - 1))
        let rows = [row(100, "node", resident: (1 + UInt64(second) / 8) * gib),
                    row(101, "claude", resident: 2 * gib)]
        driver = projection.next(end: Double(second), memory: memory(available: available), rows: rows).growthDriver
    }
    #expect(driver?.pid == 100)
    #expect(driver?.name == "node")
    #expect((driver?.growthBytes ?? 0) >= 4 * gib)
}

/// A recycled pid is a new process: the old process's growth is not credited to it.
@Test func aRecycledPIDStartsWithItsOwnGrowth() {
    var projection = MemoryProjection(config: testConfig)
    var driver: MemoryProjection.GrowthDriver?
    for second in 1...40 {
        let available = (30 * gib) - UInt64(64.0 * Double(1 << 20) * Double(second - 1))
        var grower = row(100, "node", resident: (1 + UInt64(second) / 8) * gib)
        grower.startMicroseconds = 1_000
        driver = projection.next(end: Double(second), memory: memory(available: available), rows: [grower]).growthDriver
    }
    #expect(driver?.pid == 100)
    var newcomer = row(100, "make", resident: 1 << 20)
    newcomer.startMicroseconds = 2_000
    let reading = projection.next(end: 41, memory: memory(available: (30 * gib) - UInt64(64.0 * Double(1 << 20) * 40)),
                                  rows: [newcomer])
    #expect(reading.eta != nil)
    #expect(reading.growthDriver == nil)
}

/// Without a projection there is no driver to name.
@Test func noETAHasNoGrowthDriver() {
    var projection = MemoryProjection(config: testConfig)
    var reading: MemoryProjection.Reading?
    for second in 1...40 {
        reading = projection.next(end: Double(second), memory: memory(available: gib * 9),
                                  rows: [row(100, "node", resident: UInt64(second) * (1 << 24))])
    }
    #expect(reading?.eta == nil)
    #expect(reading?.growthDriver == nil)
}

/// A tick whose memory could not be read projects nothing: a missing sample is not a fresh figure.
@Test func aMissingSampleProjectsNothing() {
    var projection = MemoryProjection(config: testConfig)
    var reading: MemoryProjection.Reading?
    for second in 1...40 {
        reading = projection.next(end: Double(second), memory: nil, rows: [])
    }
    #expect(reading?.eta == nil)
    #expect(reading?.growthDriver == nil)
}

/// A gap longer than every window drops what came before it.
@Test func aLongGapDropsOldSamples() {
    var projection = MemoryProjection(config: testConfig)
    for second in 1...40 {
        _ = projection.next(end: Double(second), memory: memory(available: (30 * gib) - UInt64(second) * (1 << 26)),
                            rows: [])
    }
    // One reading a minute later: the old samples are outside the 180 s window.
    let reading = projection.next(end: 400, memory: memory(available: 20 * gib), rows: [])
    #expect(reading.eta == nil)
}

/// One memory sample gives both figures from the same counters: the used bytes, the physical memory and the percentage
/// agree between the available-page value the floor projects and the used value the Memory column shows. A passive read
/// of the machine's counters, no sampling loop and no app or command line.
@Test func memorySampleGivesBothFiguresFromOneRead() throws {
    let sample = try SystemReaders.memorySample()
    #expect(sample.available.usedBytes == sample.usage.usedBytes)
    #expect(sample.available.physicalBytes == sample.usage.physicalBytes)
    #expect(sample.usage.physicalBytes == ProcessInfo.processInfo.physicalMemory)
    #expect(sample.available.usedPercent(.usedOfPhysical) == sample.usage.percent)
    #expect(sample.available.availableBytes > 0)
    #expect((0...100).contains(sample.usage.percent))
}
