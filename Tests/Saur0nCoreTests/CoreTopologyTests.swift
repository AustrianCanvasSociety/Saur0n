// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: CPU → core-type groups exactly as the Mac reports them, never guessed. Method: perf levels
// and registry letters recorded from M5 Max and pre-M5 chips, fed to `build` and to `read` with
// stubbed sysctl keys that can be set, absent or unreadable.

/// Perf levels from `(name, CPU count)` pairs, fastest first.
private func levels(_ specs: (String, Int)...) -> [PerfLevel] {
    specs.enumerated().map { PerfLevel(index: $0.offset, name: $0.element.0, logicalCPUCount: $0.element.1) }
}

/// Letters keyed by CPU index, built from `(letter, CPU range)` runs.
private func letters(_ runs: [(String, ClosedRange<Int>)]) -> [Int: String] {
    var out: [Int: String] = [:]
    for (letter, cpus) in runs { for cpu in cpus { out[cpu] = letter } }
    return out
}

@Test func m5MaxMapsSuperAndPerformance() throws {
    let topo = try CoreTopology.build(levels: levels(("Super", 6), ("Performance", 12)),
                                      clusterTypeByCPU: letters([("M", 0...11), ("P", 12...17)]))
    #expect(topo.cpusByLevel == [Array(12...17), Array(0...11)])
}

@Test func preM5ProMapsByCount() throws {
    let topo = try CoreTopology.build(levels: levels(("Performance", 8), ("Efficiency", 2)),
                                      clusterTypeByCPU: letters([("E", 0...1), ("P", 2...9)]))
    #expect(topo.cpusByLevel == [Array(2...9), [0, 1]])
}

@Test func countTieFallsBackToLetterRank() throws {
    let topo = try CoreTopology.build(levels: levels(("Performance", 4), ("Efficiency", 4)),
                                      clusterTypeByCPU: letters([("E", 0...3), ("P", 4...7)]))
    #expect(topo.cpusByLevel == [Array(4...7), Array(0...3)])
}

@Test func unknownLetterIsAnError() {
    #expect(throws: TopologyError.unknownClusterType("X")) {
        try CoreTopology.build(levels: levels(("Performance", 2)), clusterTypeByCPU: letters([("X", 0...1)]))
    }
}

@Test func letterWithNoMatchingLevelIsAnError() {
    #expect(throws: TopologyError.letterCountMismatch(letter: "P", cpus: 5)) {
        try CoreTopology.build(levels: levels(("Super", 6), ("Performance", 12)),
                               clusterTypeByCPU: letters([("M", 0...11), ("P", 12...16)]))
    }
}

@Test func levelWithNoLetterIsAnError() {
    #expect(throws: TopologyError.levelCountMismatch(level: "Super")) {
        try CoreTopology.build(levels: levels(("Super", 6), ("Performance", 12)),
                               clusterTypeByCPU: letters([("M", 0...11)]))
    }
}

@Test func emptyRegistryIsAnError() {
    #expect(throws: TopologyError.registryUnreadable) {
        try CoreTopology.build(levels: levels(("Performance", 4)), clusterTypeByCPU: [:])
    }
}

@Test func singleLevelMachine() {
    let topo = CoreTopology.singleLevel(logicalCPUCount: 4)
    #expect(topo.levels == [PerfLevel(index: 0, name: "CPU", logicalCPUCount: 4)])
    #expect(topo.cpusByLevel == [[0, 1, 2, 3]])
}

@Test func cpuRangesText() {
    #expect(CoreTopology.rangesText([0, 1, 2, 5, 7, 8]) == "0–2, 5, 7–8")
    #expect(CoreTopology.rangesText([]) == "")
}

// MARK: reading perf levels — absent vs unreadable

private struct UnreadableKey: Error {}

/// sysctl stubs answering by key: a key in `unreadable` throws, a key in neither map is absent.
private func read(ints: [String: Int], strings: [String: String] = [:], unreadable: Set<String> = [],
                  registry: [Int: String] = [:]) throws -> CoreTopology {
    try CoreTopology.read(sysctlInt: { key in
        if unreadable.contains(key) { throw UnreadableKey() }
        return ints[key]
    }, sysctlString: { strings[$0] }, clusterTypeByCPU: { registry })
}

@Test func unreadablePerfLevelThrows() {
    #expect(throws: TopologyError.unreadablePerfLevel(index: 1)) {
        try read(ints: ["hw.nperflevels": 2, "hw.perflevel0.logicalcpu_max": 6, "hw.perflevel1.logicalcpu_max": 12],
                 strings: ["hw.perflevel0.name": "Super"],
                 registry: letters([("M", 0...11), ("P", 12...17)]))
    }
    #expect(throws: TopologyError.unreadablePerfLevel(index: 0)) {
        try read(ints: ["hw.nperflevels": 1], strings: ["hw.perflevel0.name": "Performance"],
                 registry: letters([("P", 0...3)]))
    }
    #expect(throws: TopologyError.unreadablePerfLevel(index: 0)) {
        try read(ints: ["hw.nperflevels": 1], strings: ["hw.perflevel0.name": "Performance"],
                 unreadable: ["hw.perflevel0.logicalcpu_max"], registry: letters([("P", 0...3)]))
    }
}

@Test func readablePerfLevelsBuild() throws {
    let topo = try read(ints: ["hw.nperflevels": 2, "hw.perflevel0.logicalcpu_max": 6, "hw.perflevel1.logicalcpu_max": 12],
                        strings: ["hw.perflevel0.name": "Super", "hw.perflevel1.name": "Performance"],
                        registry: letters([("M", 0...11), ("P", 12...17)]))
    #expect(topo.levels.map(\.name) == ["Super", "Performance"])
    #expect(topo.cpusByLevel == [Array(12...17), Array(0...11)])
}

/// `_max` counts CPUs taken offline too, so the topology covers every CPU the tick list holds.
@Test func perfLevelsCountOfflineCPUs() throws {
    let topo = try read(ints: ["hw.nperflevels": 1, "hw.perflevel0.logicalcpu": 3, "hw.perflevel0.logicalcpu_max": 4],
                        strings: ["hw.perflevel0.name": "Performance"], registry: letters([("P", 0...3)]))
    #expect(topo.cpusByLevel == [[0, 1, 2, 3]])
    #expect(try read(ints: ["hw.logicalcpu": 3, "hw.logicalcpu_max": 4]) == CoreTopology.singleLevel(logicalCPUCount: 4))
}

@Test func noPerfLevelsIsSingleLevel() throws {
    #expect(try read(ints: ["hw.logicalcpu_max": 4]) == CoreTopology.singleLevel(logicalCPUCount: 4))
    #expect(try read(ints: ["hw.nperflevels": 0, "hw.logicalcpu_max": 4]) == CoreTopology.singleLevel(logicalCPUCount: 4))
}

/// Only an absent key or a 0 means no perf levels; a key that exists but cannot be read is an error.
@Test func unreadablePerfLevelCountThrows() {
    #expect(throws: TopologyError.unreadablePerfLevelCount) {
        try read(ints: ["hw.logicalcpu_max": 4], unreadable: ["hw.nperflevels"])
    }
    // A count no Mac reports is read as garbage, not looped over.
    #expect(throws: TopologyError.unreadablePerfLevelCount) {
        try read(ints: ["hw.nperflevels": 1 << 30, "hw.logicalcpu_max": 4])
    }
}

@Test func unreadableCPUCountThrows() {
    #expect(throws: TopologyError.unreadableCPUCount) { try read(ints: [:]) }
    #expect(throws: TopologyError.unreadableCPUCount) { try read(ints: [:], unreadable: ["hw.logicalcpu_max"]) }
    // Zero or a negative count would trap building the CPU range.
    #expect(throws: TopologyError.unreadableCPUCount) { try read(ints: ["hw.logicalcpu_max": 0]) }
    #expect(throws: TopologyError.unreadableCPUCount) { try read(ints: ["hw.logicalcpu_max": -1]) }
}

// MARK: registry entries

@Test func unreadableCPUEntryEmptiesTheRegistry() {
    let p = Data("P\0".utf8), e = Data("E\0".utf8)
    #expect(SystemReaders.clusterTypes([("cpu0", p), ("cpu1", e)]) == [0: "P", 1: "E"])
    // A CPU left out would shrink its group; an empty map is the registry-unreadable error instead.
    #expect(SystemReaders.clusterTypes([("cpu0", p), ("cpu1", nil)]) == [:])
    #expect(SystemReaders.clusterTypes([("cpu0", p), (nil, e)]) == [:])
    // Children that are not CPUs are not counted.
    #expect(SystemReaders.clusterTypes([("cpu0", p), ("cpu-map", nil)]) == [0: "P"])
}
