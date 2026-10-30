// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One CPU's cumulative tick counters as `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` reports them.
public struct CPUTicks: Equatable, Sendable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public enum CPULoadError: Error, Equatable, Sendable {
    case cpuCountChanged(before: Int, after: Int)
    case noTicksElapsed
    case topologyMismatch(topologyCPUs: Int, sampledCPUs: Int)
    case unreadable(kernReturn: Int32)
    /// `host_processor_info` returned fewer counters than its CPU count needs.
    case shortTickBuffer(values: Int, cpus: Int)
}

/// The whole-machine busy share split into user and system time, each a % of every CPU's ticks, so the two add up to
/// `CPULoad.total`. Nice time counts as user: it is user-mode time at a lowered priority (`CPU_STATE_NICE`), and
/// Activity Monitor's CPU tab shows only User, System and Idle.
public struct CPUSplit: Equatable, Sendable {
    public let user: Double
    public let system: Double

    public init(user: Double, system: Double) {
        self.user = user
        self.system = system
    }
}

/// Busy share over one interval. 100% = the CPU (or, for `total`, every CPU) busy throughout.
public struct CPULoad: Equatable, Sendable {
    /// Busy % per CPU, 0–100, indexed by CPU number.
    public let perCPU: [Double]
    /// Whole-machine busy %: summed busy ticks over summed ticks, so CPUs weigh by ticks elapsed.
    public let total: Double
    /// `total` as user and system time; `compute` always sets it, a load built by hand may leave it out.
    public let split: CPUSplit?

    public init(perCPU: [Double], total: Double, split: CPUSplit? = nil) {
        self.perCPU = perCPU
        self.total = total
        self.split = split
    }

    /// Busy = user + system + nice. Deltas wrap, so a counter that rolled over still reads true.
    /// A CPU with no ticks elapsed (parked) reads 0%; no ticks anywhere is an error, never a guess.
    public static func compute(before: [CPUTicks], after: [CPUTicks]) throws -> CPULoad {
        guard before.count == after.count else {
            throw CPULoadError.cpuCountChanged(before: before.count, after: after.count)
        }
        var perCPU: [Double] = []
        var systemSum: UInt64 = 0
        var busySum: UInt64 = 0
        var tickSum: UInt64 = 0
        for (b, a) in zip(before, after) {
            let system = UInt64(a.system &- b.system)
            let busy = UInt64(a.user &- b.user) + system + UInt64(a.nice &- b.nice)
            let ticks = busy + UInt64(a.idle &- b.idle)
            perCPU.append(ticks == 0 ? 0 : 100 * Double(busy) / Double(ticks))
            systemSum += system
            busySum += busy
            tickSum += ticks
        }
        guard tickSum > 0 else { throw CPULoadError.noTicksElapsed }
        let total = 100 * Double(busySum) / Double(tickSum)
        assert(perCPU.allSatisfy { (0...100).contains($0) } && (0...100).contains(total), "busy ticks never exceed ticks")
        let split = CPUSplit(user: 100 * Double(busySum - systemSum) / Double(tickSum),
                             system: 100 * Double(systemSum) / Double(tickSum))
        return CPULoad(perCPU: perCPU, total: total, split: split)
    }
}

/// The 1-, 5- and 15-minute load averages: runnable and running threads, averaged by the kernel, read with
/// `getloadavg` (`SystemReaders.loadAverage`). Shown against the CPU count, as `check_load --percpu` judges it.
public struct LoadAverage: Equatable, Sendable {
    public let oneMinute: Double
    public let fiveMinutes: Double
    public let fifteenMinutes: Double

    public init(oneMinute: Double, fiveMinutes: Double, fifteenMinutes: Double) {
        self.oneMinute = oneMinute
        self.fiveMinutes = fiveMinutes
        self.fifteenMinutes = fifteenMinutes
    }

    /// `5.12 4.80 4.31`: two decimals, 1, 5 and 15 minutes, as `uptime` prints them.
    public var text: String { [oneMinute, fiveMinutes, fifteenMinutes].map(TextFormat.loadText).joined(separator: " ") }
}

/// A pid the kernel handed out and when: the `/bin/ps` child Saur0n starts with each process sample, a free reading
/// of the pid counter. Uptime for the rate, epoch seconds for the JSON window (as `DiskWindow` stamps its reads).
public struct PidReading: Equatable, Sendable {
    public let pid: Int32
    public let uptimeNanoseconds: UInt64
    public let epochSeconds: Double

    public init(pid: Int32, uptimeNanoseconds: UInt64, epochSeconds: Double) {
        self.pid = pid
        self.uptimeNanoseconds = uptimeNanoseconds
        self.epochSeconds = epochSeconds
    }
}

/// Processes launched between two pid readings: the pid counter's advance. XNU hands out pids by stepping up from the
/// last one, `if (++pid >= PID_MAX) pid = 100` with `PID_MAX` 99999 (`bsd/kern/kern_fork.c`, read as a fact about
/// the platform), so pids run 100…99,998 and then wrap. Pids still in use are skipped, so the advance slightly
/// overstates the launches; Saur0n's own children (`ps`, `nettop`, `top`) count, as `top` counts itself.
public struct LaunchRate: Equatable, Sendable {
    public static let firstPid: Int32 = 100
    public static let lastPid: Int32 = 99_998

    public let count: Int
    public let first: PidReading
    public let last: PidReading

    /// nil unless time passed between the readings and both pids lie in the counter's range.
    public init?(before: PidReading, after: PidReading) {
        guard after.uptimeNanoseconds > before.uptimeNanoseconds,
              let count = Self.launches(from: before.pid, to: after.pid) else { return nil }
        self.count = count
        first = before
        last = after
    }

    /// Between two process samples' `ps` children; nil when either sample has none.
    public init?(before: ProcessListSample, after: ProcessListSample) {
        guard let first = before.psLaunch, let last = after.psLaunch else { return nil }
        self.init(before: first, after: last)
    }

    public var seconds: Double { Double(last.uptimeNanoseconds - first.uptimeNanoseconds) / 1e9 }
    public var perSecond: Double { Double(count) / seconds }

    /// Pids handed out after `from` up to and including `to`, across one wrap; nil for a pid outside 100…99,998
    /// (below 100 only before the first wrap, which a reading pair cannot place). Assumes under one full turn of the
    /// counter between the readings: about 100,000 launches in a second is far past any Mac's rate.
    public static func launches(from: Int32, to: Int32) -> Int? {
        let range = firstPid...lastPid
        guard range.contains(from), range.contains(to) else { return nil }
        return to >= from ? Int(to - from) : Int(lastPid - from) + Int(to - firstPid + 1)
    }
}

/// Topology plus one load sample, and the process list when one was taken: what `saur0n` prints.
public struct Snapshot: Sendable {
    public let topology: CoreTopology
    public let load: CPULoad
    public let intervalSeconds: Double
    public let processes: [ProcessUsage]?
    /// The process rows' repo groups (`RepoGroups.assign`), when they were grouped.
    public let repoGroups: [RepoGroup]?
    /// The process rows' session groups (`SessionGroups.assign`), when they were grouped.
    public let sessionGroups: [SessionGroup]?
    /// The process rows' command groups (`CommandGroups.assign`), when they were grouped.
    public let commandGroups: [CommandGroup]?
    /// The machine's disk rate over the window and its bytes since boot (`DiskActivity.usage`), when read.
    public let disk: DiskUsage?
    /// The machine's memory counters over the window (`SystemReaders.availableMemory`), when read: the available
    /// composite the memory floor projects, the used figures the live status carries, and swap.
    public let memory: AvailableMemory?
    /// When the machine's two disk reads were taken; JSON only, for the live check.
    public let diskWindow: DiskWindow?
    /// The machine's network rate over the window, physical interfaces only (`NetworkActivity.usage`), when read.
    /// Rows may sum past it (a tunnel daemon re-sends other rows' bytes): nothing is clipped, no remainder is shown.
    public let network: NetworkUsage?
    /// When the machine's two network reads were taken; JSON only, for the live check.
    public let networkWindow: NetworkWindow?
    /// The kernel's load averages at the end of the window (`SystemReaders.loadAverage`), when read.
    public let loadAverage: LoadAverage?
    /// Processes launched between the window's two `ps` starts, when both pids were read.
    public let launches: LaunchRate?
    /// The warnings in force after this window (`WarningEngine`), when the run keeps them; table only.
    public let warnings: [Warning]?

    /// Six `NN  100.0%` cells make a 77-column row with two-digit CPU numbers: inside an 80-column terminal.
    static let cpusPerRow = 6

    public init(topology: CoreTopology, load: CPULoad, intervalSeconds: Double,
                processes: [ProcessUsage]? = nil, repoGroups: [RepoGroup]? = nil,
                sessionGroups: [SessionGroup]? = nil, commandGroups: [CommandGroup]? = nil,
                disk: DiskUsage? = nil, diskWindow: DiskWindow? = nil,
                network: NetworkUsage? = nil, networkWindow: NetworkWindow? = nil,
                loadAverage: LoadAverage? = nil, launches: LaunchRate? = nil, warnings: [Warning]? = nil,
                memory: AvailableMemory? = nil) throws {
        let cpus = Array(topology.cpusByLevel.joined())
        guard cpus.count == load.perCPU.count, cpus.allSatisfy(load.perCPU.indices.contains) else {
            throw CPULoadError.topologyMismatch(topologyCPUs: cpus.count, sampledCPUs: load.perCPU.count)
        }
        self.topology = topology
        self.load = load
        self.intervalSeconds = intervalSeconds
        self.processes = processes
        self.repoGroups = repoGroups
        self.sessionGroups = sessionGroups
        self.commandGroups = commandGroups
        self.disk = disk
        self.diskWindow = diskWindow
        self.network = network
        self.networkWindow = networkWindow
        self.loadAverage = loadAverage
        self.launches = launches
        self.warnings = warnings
        self.memory = memory
    }

    /// The whole-machine CPU no group holds: the total less every row's own and exited-children CPU (each row
    /// sits in exactly one group, so this is the total less every group's header), floored at 0. Mostly
    /// children reaped by root's or other users' processes (launchd orphans), whose time Saur0n cannot read.
    /// nil unless the rows were grouped.
    public var unattributedCpuPercent: Double? {
        guard let processes, repoGroups != nil || sessionGroups != nil else { return nil }
        let held = processes.map { $0.cpuPercent + ($0.exitedChildrenCpuPercent ?? 0) }.reduce(0, +)
        return max(0, load.total - held)
    }

    /// What is new under launchd (`LaunchdNewcomers`), judged at the window's closing `ps` start: Unattributed CPU's
    /// likely source, named (Phase 6 Step 8). nil unless the rows were grouped and the launches read.
    public var newUnderLaunchd: LaunchdNewcomers? {
        guard let processes, repoGroups != nil || sessionGroups != nil, let launches else { return nil }
        return LaunchdNewcomers.of(processes, end: launches.last.epochSeconds)
    }

    /// The Unattributed line's hint (`TextFormat.launchdHint`), as the CLI prints it and the window shows it.
    public var unattributedHint: String? {
        unattributedCpuPercent.flatMap { TextFormat.launchdHint(newUnderLaunchd, unattributedCpuPercent: $0) }
    }

    /// The machine's disk rate no readable row holds (`DiskActivity.unattributed`), so the rows plus this make the
    /// machine's rate. nil unless the rows were grouped and the machine's disk was read.
    public var unattributedDisk: DiskRate? {
        guard let processes, let disk, repoGroups != nil || sessionGroups != nil else { return nil }
        return DiskActivity.unattributed(machine: disk.rate, rows: processes.map(\.disk))
    }

    func average(_ cpus: [Int]) -> Double {
        cpus.isEmpty ? 0 : cpus.map { load.perCPU[$0] }.reduce(0, +) / Double(cpus.count)
    }

    /// The total first, then each core-type group with its average and per-CPU load, six to a row.
    /// `columns` (a terminal's width) cuts each process row to fit; nil prints rows in full.
    /// `grouping` lists the processes under their repos (the default), their sessions or their commands. `members`, when
    /// given, prints only those process rows, every group header kept (`SnapshotRecord`).
    public func table(columns: Int? = nil, by grouping: ProcessTable.Grouping = .repo, members: Set<Int32>? = nil) -> String {
        var lines = [String(format: "CPU  %@ of the whole machine (%d CPUs, %.1f s sample)",
                            TextFormat.percentText(load.total), load.perCPU.count, intervalSeconds)]
        if let split = load.split {
            lines.append("  User \(TextFormat.percentText(split.user))  System \(TextFormat.percentText(split.system))")
        }
        if let loadAverage { lines.append("Load  \(loadAverage.text) (1, 5, 15 min) on \(load.perCPU.count) CPUs") }
        if let launches { lines.append("Launched  \(Self.launchesText(launches)) a second") }
        if let disk { lines.append("Disk  " + Self.readWriteText(disk.rate)) }
        if let network {
            lines.append("Network  In \(TextFormat.bytesPerSecondText(network.inBytesPerSecond))  "
                         + "Out \(TextFormat.bytesPerSecondText(network.outBytesPerSecond))")
        }
        if let memory { lines.append("Memory  " + TextFormat.availableMemoryText(memory)) }
        if let warnings, !warnings.isEmpty {
            lines.append("Warnings")
            lines += warnings.map { "  " + TextFormat.warningText($0) }
        }
        let nameWidth = topology.levels.map(\.name.count).max() ?? 0
        let cpuWidth = String(load.perCPU.count - 1).count
        for (level, cpus) in zip(topology.levels, topology.cpusByLevel) {
            let name = level.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            lines.append("\(name)  \(cpus.count) CPUs  (\(CoreTopology.rangesText(cpus)))  avg \(TextFormat.percentText(average(cpus)))")
            let cells = cpus.map { cpu in
                TextFormat.leftPad(String(cpu), cpuWidth) + "  " + TextFormat.leftPad(TextFormat.percentText(load.perCPU[cpu]), 6)
            }
            for start in stride(from: 0, to: cells.count, by: Self.cpusPerRow) {
                lines.append("  " + cells[start..<min(start + Self.cpusPerRow, cells.count)].joined(separator: "   "))
            }
        }
        if let processes {
            lines += ["", ProcessSample.table(processes, columns: columns, groups: repoGroups,
                                              sessionGroups: sessionGroups, commandGroups: commandGroups, by: grouping,
                                              members: members)]
        }
        if let unattributedCpuPercent {
            lines += ["", "Unattributed CPU  \(TextFormat.percentText(unattributedCpuPercent))"
                          + (unattributedHint.map { "  — " + $0 } ?? "")]
        }
        if let unattributedDisk { lines.append("Unattributed disk  " + Self.readWriteText(unattributedDisk)) }
        return lines.joined(separator: "\n")
    }

    /// Launches a second as a whole number: `120`.
    public static func launchesText(_ launches: LaunchRate) -> String { String(format: "%.0f", launches.perSecond) }

    /// `R 12.3 M/s  W 4.5 M/s`.
    static func readWriteText(_ rate: DiskRate) -> String {
        "R \(TextFormat.bytesPerSecondText(rate.readBytesPerSecond))  W \(TextFormat.bytesPerSecondText(rate.writeBytesPerSecond))"
    }

    /// `coreTypes[].{name,level,cpus}` (the CLI's first JSON shape, kept), plus per-group `busyPercent` (aligned
    /// with `cpus`) and `averageBusyPercent`, and top-level `totalBusyPercent`, `intervalSeconds`;
    /// `processes` only when a process list was taken, `repoGroups` / `sessionGroups` / `commandGroups` (Phase 6 Step 4)
    /// and `unattributedCpuPercent` (two decimals) only when it was grouped; `userBusyPercent` / `systemBusyPercent`,
    /// `loadAverage` and `launches` only when read (Phase 6 Step 2); `newUnderLaunchd` when both were (Phase 6 Step 8).
    public func json() throws -> Data {
        struct CoreType: Encodable {
            let name: String; let level: Int; let cpus: [Int]
            let busyPercent: [Double]; let averageBusyPercent: Double
        }
        struct Output: Encodable {
            let coreTypes: [CoreType]; let totalBusyPercent: Double; let intervalSeconds: Double
            let processes: [ProcessUsage]?; let repoGroups: [RepoGroup]?; let sessionGroups: [SessionGroup]?
            let commandGroups: [CommandGroup]?
            let unattributedCpuPercent: Double?
            let disk: MachineDisk?; let unattributedDisk: DiskRate?
            let network: MachineNetwork?
            let userBusyPercent, systemBusyPercent: Double?
            let loadAverage: Load?; let launches: Launches?
            let newUnderLaunchd: LaunchdNewcomers?
        }
        /// The snapshot's `loadAverage`, two decimals, with the CPU count it is judged against.
        struct Load: Encodable {
            let oneMinute, fiveMinutes, fifteenMinutes: Double
            let cpus: Int
        }
        /// The snapshot's `launches`: the count, its rate, and the two `ps` pids and starts it runs between.
        struct Launches: Encodable {
            let count: Int; let perSecond: Double
            let firstPid, lastPid: Int32
            let windowStart, windowEnd: Double
        }
        /// The snapshot's `network`, the same way.
        struct MachineNetwork: Encodable {
            let inBytesPerSecond, outBytesPerSecond, inBytes, outBytes: UInt64
            let windowStart, windowEnd: Double?
        }
        /// The snapshot's `disk`: a row's four keys, plus `windowStart` / `windowEnd` when the reads were stamped.
        struct MachineDisk: Encodable {
            let readBytesPerSecond, writeBytesPerSecond, readBytes, writeBytes: UInt64
            let windowStart, windowEnd: Double?
        }
        let output = Output(
            coreTypes: zip(topology.levels, topology.cpusByLevel).map { level, cpus in
                CoreType(name: level.name, level: level.index, cpus: cpus,
                         busyPercent: cpus.map { TextFormat.rounded(load.perCPU[$0]) },
                         averageBusyPercent: TextFormat.rounded(average(cpus)))
            },
            totalBusyPercent: TextFormat.rounded(load.total),
            intervalSeconds: intervalSeconds,
            processes: processes, repoGroups: repoGroups, sessionGroups: sessionGroups, commandGroups: commandGroups,
            unattributedCpuPercent: unattributedCpuPercent.map { TextFormat.rounded($0, places: 2) },
            disk: disk.map {
                MachineDisk(readBytesPerSecond: $0.readBytesPerSecond, writeBytesPerSecond: $0.writeBytesPerSecond,
                            readBytes: $0.readBytes, writeBytes: $0.writeBytes,
                            windowStart: diskWindow?.start, windowEnd: diskWindow?.end)
            },
            unattributedDisk: unattributedDisk,
            network: network.map {
                MachineNetwork(inBytesPerSecond: $0.inBytesPerSecond, outBytesPerSecond: $0.outBytesPerSecond,
                               inBytes: $0.inBytes, outBytes: $0.outBytes,
                               windowStart: networkWindow?.start, windowEnd: networkWindow?.end)
            },
            userBusyPercent: load.split.map { TextFormat.rounded($0.user) },
            systemBusyPercent: load.split.map { TextFormat.rounded($0.system) },
            loadAverage: loadAverage.map {
                Load(oneMinute: TextFormat.rounded($0.oneMinute, places: 2), fiveMinutes: TextFormat.rounded($0.fiveMinutes, places: 2),
                     fifteenMinutes: TextFormat.rounded($0.fifteenMinutes, places: 2), cpus: load.perCPU.count)
            },
            launches: launches.map {
                Launches(count: $0.count, perSecond: TextFormat.rounded($0.perSecond), firstPid: $0.first.pid,
                         lastPid: $0.last.pid, windowStart: $0.first.epochSeconds, windowEnd: $0.last.epochSeconds)
            },
            newUnderLaunchd: newUnderLaunchd)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(output)
    }
}
