// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One performance level as the system reports it (`hw.perflevelN`); index 0 is the fastest.
public struct PerfLevel: Equatable, Sendable {
    public let index: Int
    public let name: String
    public let logicalCPUCount: Int

    public init(index: Int, name: String, logicalCPUCount: Int) {
        self.index = index
        self.name = name
        self.logicalCPUCount = logicalCPUCount
    }
}

public enum TopologyError: Error, Equatable, Sendable {
    case unknownClusterType(String)
    case letterCountMismatch(letter: String, cpus: Int)
    case levelCountMismatch(level: String)
    case registryUnreadable
    case unreadablePerfLevel(index: Int)
    case unreadablePerfLevelCount
    case unreadableCPUCount
}

/// IO-registry `cluster-type` letters, fastest first. Both chip generations agree on the order
/// (M5+: P = Super, M = Performance, E = Efficiency; earlier: P = Performance, E = Efficiency), so a
/// count tie resolves without knowing the chip model.
enum ClusterLetter: String, CaseIterable, Comparable {
    case P, M, E

    static func < (a: ClusterLetter, b: ClusterLetter) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Which CPU indices belong to which performance level.
public struct CoreTopology: Equatable, Sendable {
    public let levels: [PerfLevel]
    /// `cpusByLevel[i]` holds the CPU indices of `levels[i]`, ascending.
    public let cpusByLevel: [[Int]]

    /// Maps each CPU's registry letter to a perf level: by matching CPU counts first, then by
    /// letter rank for levels whose counts tie. Never guesses — any leftover is an error.
    public static func build(levels: [PerfLevel], clusterTypeByCPU: [Int: String]) throws -> CoreTopology {
        guard !clusterTypeByCPU.isEmpty else { throw TopologyError.registryUnreadable }

        var cpusByLetter: [ClusterLetter: [Int]] = [:]
        for (cpu, raw) in clusterTypeByCPU.sorted(by: { $0.value < $1.value }) {
            guard let letter = ClusterLetter(rawValue: raw) else { throw TopologyError.unknownClusterType(raw) }
            cpusByLetter[letter, default: []].append(cpu)
        }

        let countOf = cpusByLetter.mapValues(\.count)
        var letterForLevel: [Int: ClusterLetter] = [:]
        var openLetters = cpusByLetter.keys.sorted()
        var openLevels = levels

        // Unique counts pair up directly.
        for letter in openLetters {
            let count = countOf[letter]!
            let sameCountLetters = openLetters.filter { countOf[$0] == count }
            let sameCountLevels = openLevels.filter { $0.logicalCPUCount == count }
            guard sameCountLetters.count == 1 else { continue }
            guard sameCountLevels.count == 1 else { continue }
            letterForLevel[sameCountLevels[0].index] = letter
            openLevels.removeAll { $0.index == sameCountLevels[0].index }
        }
        openLetters.removeAll { letterForLevel.values.contains($0) }

        // Ties (and leftovers): fastest letter to fastest level, counts must still agree.
        for (letter, level) in zip(openLetters, openLevels) {
            guard countOf[letter] == level.logicalCPUCount else {
                throw TopologyError.letterCountMismatch(letter: letter.rawValue, cpus: countOf[letter]!)
            }
            letterForLevel[level.index] = letter
        }
        if openLetters.count > openLevels.count {
            let letter = openLetters[openLevels.count]
            throw TopologyError.letterCountMismatch(letter: letter.rawValue, cpus: countOf[letter]!)
        }
        if openLevels.count > openLetters.count {
            throw TopologyError.levelCountMismatch(level: openLevels[openLetters.count].name)
        }

        let cpus = levels.map { cpusByLetter[letterForLevel[$0.index]!]!.sorted() }
        assert(Set(cpus.joined()).count == clusterTypeByCPU.count && cpus.joined().count == clusterTypeByCPU.count,
               "every CPU sits in exactly one group")
        return CoreTopology(levels: levels, cpusByLevel: cpus)
    }

    /// More perf levels than any Mac reports (Apple silicon has two; the registry knows three letters),
    /// with room to spare: a larger count is garbage.
    static let maxPerfLevels = 16

    /// Machines without perf levels (Intel, some VMs): one level holding every CPU.
    public static func singleLevel(logicalCPUCount: Int) -> CoreTopology {
        assert(logicalCPUCount > 0, "a machine has at least one CPU")
        return CoreTopology(levels: [PerfLevel(index: 0, name: "CPU", logicalCPUCount: logicalCPUCount)],
                            cpusByLevel: [Array(0..<logicalCPUCount)])
    }

    /// The topology from sysctl keys, with the reads passed in (`sysctlInt`: nil = key absent,
    /// throws = present but unreadable). No perf levels — `hw.nperflevels` absent (Intel, some VMs)
    /// or 0 — is a single level of `hw.logicalcpu_max` CPUs. A perf-level key that exists but cannot
    /// be read is an error, never one group; so is a level count above `maxPerfLevels`. Counts are
    /// `_max`, which keeps CPUs taken offline, so the groups cover every CPU in the tick list.
    static func read(sysctlInt: (String) throws -> Int?, sysctlString: (String) -> String?,
                     clusterTypeByCPU: () -> [Int: String]) throws -> CoreTopology {
        let levelCount: Int?
        do {
            levelCount = try sysctlInt("hw.nperflevels")
        } catch {
            throw TopologyError.unreadablePerfLevelCount
        }
        guard levelCount ?? 0 <= maxPerfLevels else { throw TopologyError.unreadablePerfLevelCount }
        guard let count = levelCount, count > 0 else {
            guard let cpus = try? sysctlInt("hw.logicalcpu_max"), cpus > 0 else { throw TopologyError.unreadableCPUCount }
            return singleLevel(logicalCPUCount: cpus)
        }
        var levels: [PerfLevel] = []
        for i in 0..<count {
            guard let name = sysctlString("hw.perflevel\(i).name"),
                  let cpus = try? sysctlInt("hw.perflevel\(i).logicalcpu_max") else {
                throw TopologyError.unreadablePerfLevel(index: i)
            }
            levels.append(PerfLevel(index: i, name: name, logicalCPUCount: cpus))
        }
        return try build(levels: levels, clusterTypeByCPU: clusterTypeByCPU())
    }

    /// `[0,1,2,5,7,8]` → `0–2, 5, 7–8`.
    static func rangesText(_ cpus: [Int]) -> String {
        var parts: [String] = []
        var i = 0
        while i < cpus.count {
            var j = i
            while j + 1 < cpus.count, cpus[j + 1] == cpus[j] + 1 { j += 1 }
            parts.append(i == j ? "\(cpus[i])" : "\(cpus[i])–\(cpus[j])")
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }
}
