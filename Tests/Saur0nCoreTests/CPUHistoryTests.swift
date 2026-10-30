// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: what the window draws — 60 seconds of per-core, per-type and whole-machine load, refreshed from
// successive tick reads, and the per-core strips laid out in columns of at most six under their core type.
// Method: hand-built ticks, loads and topologies (M5 Max, a chip with Efficiency cores, one level).

private let m5Max = CoreTopology(
    levels: [PerfLevel(index: 0, name: "Super", logicalCPUCount: 6),
             PerfLevel(index: 1, name: "Performance", logicalCPUCount: 12)],
    cpusByLevel: [Array(12...17), Array(0...11)])

/// `n` CPUs with the same counters.
private func ticks(_ n: Int, user: UInt32 = 0, idle: UInt32 = 0) -> [CPUTicks] {
    Array(repeating: CPUTicks(user: user, system: 0, idle: idle, nice: 0), count: n)
}

/// An M5 Max load: Performance CPUs at `performance`, Super CPUs at `superCores`.
private func m5MaxLoad(performance: Double, superCores: Double) -> CPULoad {
    let perCPU = Array(repeating: performance, count: 12) + Array(repeating: superCores, count: 6)
    return CPULoad(perCPU: perCPU, total: perCPU.reduce(0, +) / 18)
}

@Test func emptyHistoryHasNoPoints() {
    let history = CPUHistory(topology: m5Max)
    #expect(history.total.isEmpty)
    #expect(history.perCPU.count == 18 && history.perCPU.allSatisfy(\.isEmpty))
    #expect(history.perLevel.count == 2 && history.perLevel.allSatisfy(\.isEmpty))
    #expect(history.latest == nil)
}

@Test func oneRefreshAddsOnePointPerCoreAndType() throws {
    var history = CPUHistory(topology: m5Max)
    let load = m5MaxLoad(performance: 10, superCores: 95)
    try history.append(load)
    #expect(history.perCPU.map(\.count) == Array(repeating: 1, count: 18))
    #expect(history.perCPU[0] == [10] && history.perCPU[12] == [95])
    #expect(history.perLevel == [[95], [10]])
    #expect(history.total == [load.total])
    #expect(history.latest == load)
}

@Test func typeAverageIsTheMeanOfItsCores() throws {
    var history = CPUHistory(topology: m5Max)
    var perCPU = Array(repeating: 10.0, count: 18)
    perCPU[12] = 35; perCPU[13] = 15    // Super: 35, 15 and four at 10 → 90 / 6 = 15
    try history.append(CPULoad(perCPU: perCPU, total: 12))
    #expect(history.perLevel == [[15], [10]])
    #expect(history.total == [12])
}

@Test func historyKeepsTheLastSixtyPoints() throws {
    var history = CPUHistory(topology: m5Max)
    for second in 0...60 {
        try history.append(m5MaxLoad(performance: Double(second), superCores: 0))
    }
    #expect(CPUHistory.capacity == 60)
    #expect(history.perCPU[0].count == 60 && history.perCPU[0].first == 1 && history.perCPU[0].last == 60)
    #expect(history.perLevel[1].count == 60 && history.perLevel[1].first == 1)
    #expect(history.total.count == 60)
}

@Test func cpuCountChangeBetweenReadsIsAnError() throws {
    var sampler = TickSampler()
    _ = try sampler.next(ticks(18, idle: 1))
    #expect(throws: CPULoadError.cpuCountChanged(before: 18, after: 17)) {
        try sampler.next(ticks(17, idle: 2))
    }
    var history = CPUHistory(topology: m5Max)
    #expect(throws: CPULoadError.topologyMismatch(topologyCPUs: 18, sampledCPUs: 17)) {
        try history.append(CPULoad(perCPU: Array(repeating: 0, count: 17), total: 0))
    }
    #expect(history.total.isEmpty)
}

@Test func historyRejectsInvalidCPUIndicesWithoutChangingPoints() throws {
    let level = PerfLevel(index: 0, name: "Performance", logicalCPUCount: 2)
    for cpus in [[0, 2], [-1, 1]] {
        var history = CPUHistory(topology: CoreTopology(levels: [level], cpusByLevel: [cpus]))
        let before = history
        #expect(throws: CPULoadError.topologyMismatch(topologyCPUs: 2, sampledCPUs: 2)) {
            try history.append(CPULoad(perCPU: [10, 20], total: 15))
        }
        #expect(history == before)
    }
}

@Test func loadSamplerRetriesFailedTopologyAndKeepsSuccessfulTopology() throws {
    var sampler = LoadSampler()
    #expect(throws: TopologyError.unreadableCPUCount) {
        try sampler.next(topology: { throw TopologyError.unreadableCPUCount }, ticks: { ticks(18) })
    }
    #expect(sampler.topology == nil)
    #expect(try sampler.next(topology: { m5Max }, ticks: { ticks(18) }) == nil)
    #expect(sampler.topology == m5Max)
    let load = try sampler.next(topology: { throw TopologyError.registryUnreadable },
                                ticks: { ticks(18, user: 50, idle: 50) })
    #expect(load?.total == 50)
}

@Test func loadSamplerRetriesMismatchedCountsAndIndices() throws {
    let smaller = CoreTopology(levels: [PerfLevel(index: 0, name: "Performance", logicalCPUCount: 2)],
                               cpusByLevel: [[0, 1]])
    for initial in [m5Max, CoreTopology(levels: smaller.levels, cpusByLevel: [[0, 2]])] {
        var sampler = LoadSampler()
        #expect(throws: CPULoadError.self) {
            try sampler.next(topology: { initial }, ticks: { ticks(2) })
        }
        #expect(sampler.topology == nil)
        #expect(try sampler.next(topology: { smaller }, ticks: { ticks(2, user: 80) }) == nil)
        let reading = try sampler.next(topology: { smaller }, ticks: { ticks(2, user: 90, idle: 10) })
        let load = try #require(reading)
        #expect(load.total == 50)
        var history = CPUHistory(topology: try #require(sampler.topology))
        try history.append(load)
        #expect(history.total == [50])
    }
}

@Test func loadSamplerReopensTheWindowAfterAFailedTick() throws {
    var sampler = LoadSampler()
    _ = try sampler.next(topology: { m5Max }, ticks: { ticks(18) })
    _ = try sampler.next(topology: { m5Max }, ticks: { ticks(18, user: 10) })
    #expect(throws: TopologyError.unreadableCPUCount) {
        try sampler.next(topology: { m5Max }, ticks: { throw TopologyError.unreadableCPUCount })
    }
    #expect(sampler.topology == nil)
    #expect(try sampler.next(topology: { m5Max }, ticks: { ticks(18, user: 80) }) == nil)
    #expect(try sampler.next(topology: { m5Max }, ticks: { ticks(18, user: 90, idle: 10) })?.total == 50)
}

@Test func samplerFirstReadGivesNoLoad() throws {
    var sampler = TickSampler()
    #expect(try sampler.next(ticks(2, user: 0, idle: 0)) == nil)
    // 50 busy of 100, then (closing read reused as the opening read) 100 busy of 100.
    #expect(try sampler.next(ticks(2, user: 50, idle: 50))
            == CPULoad(perCPU: [50, 50], total: 50, split: CPUSplit(user: 50, system: 0)))
    #expect(try sampler.next(ticks(2, user: 150, idle: 50))
            == CPULoad(perCPU: [100, 100], total: 100, split: CPUSplit(user: 100, system: 0)))
}

@Test func columnsOnM5Max() {
    let columns = CoreColumns.layout(m5Max)
    #expect(columns == [
        CoreColumn(level: 0, name: "Super", cpus: Array(12...17)),
        CoreColumn(level: 1, name: "Performance", cpus: Array(0...5)),
        CoreColumn(level: 1, name: "Performance", cpus: Array(6...11)),
    ])
}

@Test func columnsWithEfficiencyCores() {
    let topology = CoreTopology(
        levels: [PerfLevel(index: 0, name: "Performance", logicalCPUCount: 4),
                 PerfLevel(index: 1, name: "Efficiency", logicalCPUCount: 6)],
        cpusByLevel: [Array(6...9), Array(0...5)])
    #expect(CoreColumns.layout(topology) == [
        CoreColumn(level: 0, name: "Performance", cpus: Array(6...9)),
        CoreColumn(level: 1, name: "Efficiency", cpus: Array(0...5)),
    ])
}

@Test func columnsOfATenCoreLevel() {
    let topology = CoreTopology(levels: [PerfLevel(index: 0, name: "Performance", logicalCPUCount: 10)],
                                cpusByLevel: [Array(0...9)])
    #expect(CoreColumns.layout(topology).map(\.cpus) == [Array(0...5), Array(6...9)])
}

@Test func columnsOnASingleLevelMachine() {
    #expect(CoreColumns.layout(.singleLevel(logicalCPUCount: 8)) == [
        CoreColumn(level: 0, name: "CPU", cpus: Array(0...5)),
        CoreColumn(level: 0, name: "CPU", cpus: [6, 7]),
    ])
}

@Test func percentTextMatchesTheCLI() {
    #expect(CPUHistory.percentText(42.345) == "42.3%")
    #expect(CPUHistory.percentText(100) == "100.0%")
}

// Phase 4 Step 4, touchup 1: the graphs plot the newest second at the right edge and the history extends
// left over a fixed 60 s, so a series of n points starts at x = 60 − n and its last point is always at 59.
@Test func newestPointSitsAtTheRightEdge() {
    #expect(CPUHistory.firstX(pointCount: 60) == 0)
    #expect(CPUHistory.firstX(pointCount: 36) == 24)
    #expect(CPUHistory.firstX(pointCount: 1) == 59)
    #expect(CPUHistory.firstX(pointCount: 0) == 60)     // nothing to draw
    #expect(CPUHistory.firstX(pointCount: 61) == 0)     // never negative
    for n in [1, 36, 60] {
        #expect(CPUHistory.firstX(pointCount: n) + n - 1 == CPUHistory.capacity - 1)
    }
}

// Phase 5 Step 3: the machine's disk (read, write) and network (in, out) graphs keep 60 seconds as the CPU
// graphs do, under a y ceiling that is a round figure and never under 1 MB/s, so an idle graph stays flat.

@Test func rateHistoriesKeepSixtyPoints() {
    var history = RateHistory()
    for second in UInt64(1)...70 { history.append(second, second * 10) }
    #expect(history.first.count == 60 && history.second.count == 60)
    #expect(history.first.first == 11 && history.first.last == 70)
    #expect(history.second.first == 110 && history.second.last == 700)
}

@Test func emptyRateHistoryDrawsNothingUnderTheFloorCeiling() {
    let history = RateHistory()
    #expect(history.first.isEmpty && history.second.isEmpty)
    #expect(CPUHistory.firstX(pointCount: history.first.count) == 60)
    #expect(RateHistory.ceiling(history.first + history.second) == 1_000_000)
}

@Test func ceilingIsANiceFigureNeverUnderOneMegabyte() {
    #expect(RateHistory.ceiling([0]) == 1_000_000)
    #expect(RateHistory.ceiling([]) == 1_000_000)
    #expect(RateHistory.ceiling([1_000_000]) == 1_000_000)
    #expect(RateHistory.ceiling([1_234_567]) == 2_000_000)
    #expect(RateHistory.ceiling([3, 7_000_000]) == 10_000_000)
    #expect(RateHistory.ceiling([40_000_000, 12]) == 50_000_000)
    #expect(RateHistory.ceiling([5_000_000_001]) == 10_000_000_000)
    #expect(RateHistory.ceiling([UInt64.max]) == UInt64.max)     // no overflow
}

@Test func graphCeilingsKeepExactBoundariesAndOverflow() {
    for edge: UInt64 in [1_000_000, 2_000_000, 5_000_000, 10_000_000, 10_000_000_000_000_000_000] {
        #expect(RateHistory.ceiling([edge - 1]) == edge)
        #expect(RateHistory.ceiling([edge]) == edge)
        #expect(RateHistory.ceiling([edge + 1]) > edge)
    }
    #expect(RateHistory.ceiling([10_000_000_000_000_000_001]) == .max)
    for edge in [1.0, 2, 5, 10, 100, 1e19] {
        #expect(LoadHistory.niceCeiling(edge.nextDown) == edge)
        #expect(LoadHistory.niceCeiling(edge) == edge)
        #expect(LoadHistory.niceCeiling(edge.nextUp) > edge)
    }
    #expect(LoadHistory.niceCeiling(.nan) == 1)
    #expect(LoadHistory.niceCeiling(-.infinity) == 1)
    #expect(LoadHistory.niceCeiling(.greatestFiniteMagnitude) == .infinity)
    #expect(LoadHistory.niceCeiling(.infinity) == .infinity)
}

@Test func bytesTextForTheStrips() {
    #expect(TextFormat.bytesText(0) == "0")
    #expect(TextFormat.bytesText(999) == "999 B")
    #expect(TextFormat.bytesText(1_000) == "1.0 K")
    #expect(TextFormat.bytesText(536_870_912) == "537 M")    // 512 MiB, as dd writes it
    #expect(TextFormat.bytesText(512_000_000) == "512 M")
    #expect(TextFormat.bytesText(1_234_000_000) == "1.2 G")
    #expect(TextFormat.bytesText(9_960_000) == "10 M")       // rounds past 9.9 to a whole number
    #expect(TextFormat.bytesText(999_600) == "1.0 M")        // rounds to 1000 K: the next unit
    #expect(RateHistory.bytesText(1_000) == "1.0 K")
    #expect(RateHistory.rateText(1_200_000) == "1.2 M/s")
}

private func launches(_ count: Int32) -> LaunchRate? {
    LaunchRate(before: PidReading(pid: 1_000, uptimeNanoseconds: 0, epochSeconds: 0),
               after: PidReading(pid: 1_000 + count, uptimeNanoseconds: 1_000_000_000, epochSeconds: 1))
}

@Test func loadHistoryKeepsSixtySeconds() {
    var history = LoadHistory()
    for i in 0...60 {
        history.append(split: CPUSplit(user: 10, system: Double(i)),
                       load: LoadAverage(oneMinute: Double(i), fiveMinutes: 1, fifteenMinutes: 1),
                       launches: launches(Int32(i)))
    }
    #expect(history.oneMinute == (1...60).map(Double.init))
    #expect(history.systemPercent == (1...60).map(Double.init))
    #expect(history.launchesPerSecond == (1...60).map(Double.init))
    #expect(history.latestLoad?.oneMinute == 60 && history.latestSplit?.system == 60 && history.latestLaunches?.count == 60)
}

@Test func loadHistorySkipsUnreadFigures() {
    var history = LoadHistory()
    history.append(split: CPUSplit(user: 10, system: 5), load: LoadAverage(oneMinute: 3, fiveMinutes: 2, fifteenMinutes: 1),
                   launches: launches(40))
    history.append(split: CPUSplit(user: 12, system: 6), load: nil, launches: nil)
    #expect(history.systemPercent == [5, 6])
    #expect(history.oneMinute == [3] && history.launchesPerSecond == [40])
    // The figures last read stay shown.
    #expect(history.latestLoad?.oneMinute == 3 && history.latestLaunches?.count == 40)
}

@Test func loadAndLaunchCeilings() {
    #expect(LoadHistory.niceCeiling(0) == 1 && LoadHistory.niceCeiling(1) == 1)
    #expect(LoadHistory.niceCeiling(1.2) == 2 && LoadHistory.niceCeiling(4.1) == 5 && LoadHistory.niceCeiling(7) == 10)
    #expect(LoadHistory.niceCeiling(96) == 100 && LoadHistory.niceCeiling(100) == 100 && LoadHistory.niceCeiling(1_357) == 2_000)
    var history = LoadHistory()
    #expect(history.loadCeiling(cpus: 18) == 18 && history.launchesCeiling == 10)
    history.append(split: nil, load: LoadAverage(oneMinute: 12, fiveMinutes: 9, fifteenMinutes: 9), launches: launches(439))
    #expect(history.loadCeiling(cpus: 18) == 18 && history.launchesCeiling == 500)
    // The incident's 96 on 18 cores stays on the graph.
    history.append(split: nil, load: LoadAverage(oneMinute: 96, fiveMinutes: 71, fifteenMinutes: 41), launches: nil)
    #expect(history.loadCeiling(cpus: 18) == 100)
}
