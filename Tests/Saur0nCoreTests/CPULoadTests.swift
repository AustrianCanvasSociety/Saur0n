// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: CPU load as a share of the whole machine (100% = every core busy) and the table and JSON
// that show it. Method: hand-built tick counters, wraps and parked CPUs included, through
// `CPULoad.compute` and `Snapshot`.

/// `n` CPUs with the same counters.
private func ticks(_ n: Int, user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0) -> [CPUTicks] {
    Array(repeating: CPUTicks(user: user, system: system, idle: idle, nice: nice), count: n)
}

@Test func idleMachineReadsZero() throws {
    let load = try CPULoad.compute(before: ticks(4, user: 50, idle: 1000),
                                   after: ticks(4, user: 50, idle: 1100))
    #expect(load.perCPU == [0, 0, 0, 0])
    #expect(load.total == 0)
}

@Test func saturatedMachineReadsHundred() throws {
    let load = try CPULoad.compute(before: ticks(4, user: 100, system: 20, idle: 500),
                                   after: ticks(4, user: 170, system: 50, idle: 500))
    #expect(load.perCPU == [100, 100, 100, 100])
    #expect(load.total == 100)
}

/// M5 Max shape: CPUs 12–17 (Super) carry the VMs at 95% busy over 200 ticks; CPUs 0–11
/// (Performance) are 10% busy over 100 ticks. Uneven tick counts make the tick-weighted
/// total differ from the mean of per-CPU percentages.
@Test func mixedM5MaxSample() throws {
    let before = ticks(18, user: 1000, system: 500, idle: 9000, nice: 10)
    var after = before
    for cpu in 0...11 {
        after[cpu] = CPUTicks(user: 1006, system: 503, idle: 9090, nice: 11)    // 10 busy of 100
    }
    for cpu in 12...17 {
        after[cpu] = CPUTicks(user: 1150, system: 540, idle: 9010, nice: 10)    // 190 busy of 200
    }
    let load = try CPULoad.compute(before: before, after: after)

    #expect(load.perCPU == Array(repeating: 10, count: 12) + Array(repeating: 95, count: 6))
    // (12·10 + 6·190) / (12·100 + 6·200) = 1260 / 2400 = 52.5%; the mean of percentages would be 38.3%.
    #expect(load.total == 52.5)
}

@Test func counterWrapYieldsTrueDelta() throws {
    let before = [CPUTicks(user: UInt32.max - 10, system: 0, idle: 0, nice: 0)]
    let after = [CPUTicks(user: 20, system: 0, idle: 31, nice: 0)]
    let load = try CPULoad.compute(before: before, after: after)
    #expect(load.perCPU == [50])
    #expect(load.total == 50)
}

@Test func cpuCountChangeIsAnError() {
    #expect(throws: CPULoadError.cpuCountChanged(before: 18, after: 17)) {
        try CPULoad.compute(before: ticks(18, idle: 1), after: ticks(17, idle: 2))
    }
}

@Test func noTicksElapsedIsAnError() {
    let sample = ticks(4, user: 10, idle: 100)
    #expect(throws: CPULoadError.noTicksElapsed) {
        try CPULoad.compute(before: sample, after: sample)
    }
}

@Test func parkedCPUReadsZero() throws {
    let before = ticks(3, user: 10, idle: 100)
    var after = ticks(3, user: 60, idle: 150)
    after[1] = before[1]
    let load = try CPULoad.compute(before: before, after: after)
    #expect(load.perCPU == [50, 0, 50])
    #expect(load.total == 50)
}

@Test func niceCountsAsBusy() throws {
    let load = try CPULoad.compute(before: ticks(2, idle: 100, nice: 5),
                                   after: ticks(2, idle: 100, nice: 25))
    #expect(load.perCPU == [100, 100])
    #expect(load.total == 100)
}

/// Two levels: Super = CPU 2, Performance = CPUs 0–1.
private func smallSnapshot() throws -> Snapshot {
    let levels = [PerfLevel(index: 0, name: "Super", logicalCPUCount: 1),
                  PerfLevel(index: 1, name: "Performance", logicalCPUCount: 2)]
    let topo = try CoreTopology.build(levels: levels, clusterTypeByCPU: [0: "M", 1: "M", 2: "P"])
    let load = CPULoad(perCPU: [12.34, 100.0 / 3, 95], total: 46.789)
    return try Snapshot(topology: topo, load: load, intervalSeconds: 1)
}

@Test func snapshotJSONKeepsCoreTypeKeys() throws {
    let json = String(decoding: try smallSnapshot().json(), as: UTF8.self)
    let expected = """
    {
      "coreTypes" : [
        {
          "averageBusyPercent" : 95,
          "busyPercent" : [
            95
          ],
          "cpus" : [
            2
          ],
          "level" : 0,
          "name" : "Super"
        },
        {
          "averageBusyPercent" : 22.8,
          "busyPercent" : [
            12.3,
            33.3
          ],
          "cpus" : [
            0,
            1
          ],
          "level" : 1,
          "name" : "Performance"
        }
      ],
      "intervalSeconds" : 1,
      "totalBusyPercent" : 46.8
    }
    """
    #expect(json == expected)
}

@Test func snapshotTable() throws {
    #expect(try smallSnapshot().table() == """
    CPU  46.8% of the whole machine (3 CPUs, 1.0 s sample)
    Super        1 CPUs  (2)  avg 95.0%
      2   95.0%
    Performance  2 CPUs  (0–1)  avg 22.8%
      0   12.3%   1   33.3%
    """)
}

@Test func snapshotTableWrapsSixCPUsPerRow() throws {
    let topo = CoreTopology.singleLevel(logicalCPUCount: 12)
    let load = CPULoad(perCPU: Array(repeating: 100, count: 12), total: 100)
    #expect(try Snapshot(topology: topo, load: load, intervalSeconds: 2).table() == """
    CPU  100.0% of the whole machine (12 CPUs, 2.0 s sample)
    CPU  12 CPUs  (0–11)  avg 100.0%
       0  100.0%    1  100.0%    2  100.0%    3  100.0%    4  100.0%    5  100.0%
       6  100.0%    7  100.0%    8  100.0%    9  100.0%   10  100.0%   11  100.0%
    """)
}

/// The core-type lines on the M5 Max shape, as `Snapshot` prints them.
@Test func snapshotKeepsCoreTypeLines() throws {
    let levels = [PerfLevel(index: 0, name: "Super", logicalCPUCount: 6),
                  PerfLevel(index: 1, name: "Performance", logicalCPUCount: 12)]
    var registry: [Int: String] = [:]
    for cpu in 0...17 { registry[cpu] = cpu < 12 ? "M" : "P" }
    let topo = try CoreTopology.build(levels: levels, clusterTypeByCPU: registry)
    let snapshot = try Snapshot(topology: topo, load: CPULoad(perCPU: Array(repeating: 0, count: 18), total: 0),
                                intervalSeconds: 1)

    let lines = snapshot.table().split(separator: "\n").map(String.init)
    #expect(lines.contains("Super        6 CPUs  (12–17)  avg 0.0%"))
    #expect(lines.contains("Performance  12 CPUs  (0–11)  avg 0.0%"))

    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    let coreTypes = try #require(object["coreTypes"] as? [[String: Any]])
    #expect(coreTypes.map { $0["name"] as? String } == ["Super", "Performance"])
    #expect(coreTypes.map { $0["level"] as? Int } == [0, 1])
    #expect(coreTypes.map { $0["cpus"] as? [Int] } == [Array(12...17), Array(0...11)])
}

/// Grouping adds `repoGroups` and group headers; the total and core-type lines stay first and unchanged.
@Test func snapshotWithRepoGroupsKeepsItsFirstLines() throws {
    let rows = [ProcessUsage(pid: 7, ppid: 1, uid: 501, user: "alice", path: nil, name: "swift-build",
                             cpuPercent: 25, residentBytes: 1024, source: .libproc)]
    let groups = RepoGroups.assign(rows, workingDirectories: [7: "/work/saur0n"],
                                   repoOfDirectory: { _ in RepoInfo(name: "saur0n", root: "/work/saur0n", worktree: nil) },
                                   repoOfExecutable: { _ in nil })
    let plain = try smallSnapshot()
    let grouped = try Snapshot(topology: plain.topology, load: plain.load, intervalSeconds: 1,
                               processes: groups.rows, repoGroups: groups.groups)
    let lines = grouped.table().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(Array(lines.prefix(5)) == plain.table().split(separator: "\n").map(String.init))
    #expect(lines.suffix(5) == ["    PID   PPID  USER     CPU   MEM  NAME",
                                "saur0n  25.0%  1.0K  1 process",
                                "      7      1  alice  25.0%  1.0K  swift-build",
                                "",
                                "Unattributed CPU  21.8%"])

    let object = try #require(JSONSerialization.jsonObject(with: grouped.json()) as? [String: Any])
    #expect(Set(object.keys) == ["coreTypes", "totalBusyPercent", "intervalSeconds", "processes", "repoGroups",
                                 "unattributedCpuPercent"])
    #expect(object["totalBusyPercent"] as? Double == 46.8)
}

/// `--by session`: the same rows under session headers, in tree order with NAME indented; the first
/// lines unchanged; the JSON the same as the repo view's.
@Test func snapshotBySessionInTreeOrder() throws {
    func row(_ pid: Int32, _ parent: Int32, _ cpu: Double, _ name: String, uid: UInt32 = 501) -> ProcessUsage {
        ProcessUsage(pid: pid, ppid: parent, uid: uid, user: uid == 0 ? "root" : "alice", path: nil, name: name,
                     cpuPercent: cpu, residentBytes: 1024, source: .libproc)
    }
    let rows = [row(13, 12, 9, "astar-1f2e"), row(12, 11, 1, "cargo"), row(10, 1, 2, "claude"), row(11, 10, 0, "zsh"),
                row(20, 1, 4, "Finder"), row(1, 0, 0.5, "launchd", uid: 0)]
    let sessions = SessionGroups.assign(rows, sources: SessionSources(
        registry: [RegistryEntry(pid: 10, sessionId: "aaaaaaaa-1111", name: "orch-line", cwd: nil, procStartSeconds: 5)],
        startSeconds: [10: 5], environmentSessionIDs: [:], tmuxPanes: [:], tty: [:], ownUID: 501))
    let plain = try smallSnapshot()
    let snapshot = try Snapshot(topology: plain.topology, load: plain.load, intervalSeconds: 1,
                                processes: sessions.rows, repoGroups: [], sessionGroups: sessions.groups)
    let lines = snapshot.table(by: .session).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(Array(lines.prefix(5)) == plain.table().split(separator: "\n").map(String.init))
    #expect(lines.suffix(12) == ["    PID   PPID  USER     CPU   MEM  NAME",
                                 "orch-line  12.0%  4.0K  4 processes",
                                 "     10      1  alice   2.0%  1.0K  claude",
                                 "     11     10  alice   0.0%  1.0K    zsh",
                                 "     12     11  alice   1.0%  1.0K      cargo",
                                 "     13     12  alice   9.0%  1.0K        astar-1f2e",
                                 "No session  4.0%  1.0K  1 process",
                                 "     20      1  alice   4.0%  1.0K  Finder",
                                 "System and other users  0.5%  1.0K  1 process",
                                 "      1      0  root    0.5%  1.0K  launchd",
                                 "",
                                 "Unattributed CPU  30.3%"])
    #expect(try snapshot.json() == Snapshot(topology: plain.topology, load: plain.load, intervalSeconds: 1,
                                            processes: sessions.rows, repoGroups: [],
                                            sessionGroups: sessions.groups).json())
}

/// `--by command` (Phase 6 Step 4): a header per command, "× N" from two copies, each copy with what it owns indented
/// under it, the SESSION column kept; the first lines unchanged; JSON `commandGroups` with `copies`.
@Test func snapshotByCommandListsCopiesWithWhatTheyOwn() throws {
    func row(_ pid: Int32, _ parent: Int32, _ cpu: Double, _ name: String, uid: UInt32 = 501) -> ProcessUsage {
        ProcessUsage(pid: pid, ppid: parent, uid: uid, user: uid == 0 ? "root" : "alice", path: nil, name: name,
                     cpuPercent: cpu, residentBytes: 1024, source: .libproc)
    }
    let rows = [row(100, 1, 0, "bash"), row(101, 100, 3, "yes"), row(102, 1, 0, "bash"), row(103, 102, 2, "yes"),
                row(20, 1, 4, "Finder"), row(1, 0, 0.5, "launchd", uid: 0)]
    let script = ProcessArguments(argv: ["/bin/bash", "/tmp/example/runaway.sh"], environment: [:])
    let sessions = SessionGroups.assign(rows, sources: SessionSources(registry: [], startSeconds: [:], environmentSessionIDs: [:],
                                                                      tmuxPanes: [:], tty: [:], ownUID: 501))
    let commands = CommandGroups.assign(sessions.rows, arguments: [100: script, 102: script])
    let plain = try smallSnapshot()
    let snapshot = try Snapshot(topology: plain.topology, load: plain.load, intervalSeconds: 1, processes: commands.rows,
                                repoGroups: [], sessionGroups: sessions.groups, commandGroups: commands.groups)
    let lines = snapshot.table(by: .command).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(Array(lines.prefix(5)) == plain.table().split(separator: "\n").map(String.init))
    #expect(lines.suffix(12) == ["    PID   PPID  USER     CPU   MEM  SESSION  NAME",
                                 "runaway.sh × 2  5.0%  4.0K  4 processes",
                                 "    100      1  alice   0.0%  1.0K  -        bash",
                                 "    101    100  alice   3.0%  1.0K  -          yes",
                                 "    102      1  alice   0.0%  1.0K  -        bash",
                                 "    103    102  alice   2.0%  1.0K  -          yes",
                                 "Finder  4.0%  1.0K  1 process",
                                 "     20      1  alice   4.0%  1.0K  -        Finder",
                                 "launchd  0.5%  1.0K  1 process",
                                 "      1      0  root    0.5%  1.0K  -        launchd",
                                 "",
                                 "Unattributed CPU  37.3%"])
    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    let groups = try #require(object["commandGroups"] as? [[String: Any]])
    #expect(groups.map { $0["name"] as? String } == ["runaway.sh", "Finder", "launchd"])
    #expect(groups.map { $0["copies"] as? Int } == [2, 1, 1])
    #expect(groups.first?["pids"] as? [Int] == [100, 101, 102, 103])
    #expect(object["sessionGroups"] != nil && object["repoGroups"] != nil)
}

@Test func tickBufferDecodesPerCPU() throws {
    // CPU_STATE_USER, SYSTEM, IDLE, NICE per CPU.
    let info: [integer_t] = [1, 2, 3, 4, 10, 20, 30, 40]
    let ticks = try info.withUnsafeBufferPointer { try SystemReaders.cpuTicks($0, cpuCount: 2) }
    #expect(ticks == [CPUTicks(user: 1, system: 2, idle: 3, nice: 4), CPUTicks(user: 10, system: 20, idle: 30, nice: 40)])
}

@Test func shortTickBufferThrows() {
    let info = [integer_t](repeating: 0, count: 2 * Int(CPU_STATE_MAX) - 1)
    #expect(throws: CPULoadError.shortTickBuffer(values: 2 * Int(CPU_STATE_MAX) - 1, cpus: 2)) {
        try info.withUnsafeBufferPointer { try SystemReaders.cpuTicks($0, cpuCount: 2) }
    }
}

// MARK: unattributed CPU (Phase 3 Step 3)

/// Snapshot over `smallSnapshot`'s load (total 46.789) with `rows` grouped by repo, all in one repo.
private func grouped(_ rows: [ProcessUsage], total: Double = 46.789) throws -> Snapshot {
    let plain = try smallSnapshot()
    let groups = RepoGroups.assign(rows, workingDirectories: Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, "/w") }),
                                   repoOfDirectory: { _ in RepoInfo(name: "w", root: "/w", worktree: nil) },
                                   repoOfExecutable: { _ in nil })
    return try Snapshot(topology: plain.topology, load: CPULoad(perCPU: plain.load.perCPU, total: total),
                        intervalSeconds: 1, processes: groups.rows, repoGroups: groups.groups)
}

private func usageRow(_ pid: Int32, cpu: Double, exited: Double?) -> ProcessUsage {
    ProcessUsage(pid: pid, ppid: 1, uid: 501, user: "alice", path: nil, name: "zsh", cpuPercent: cpu,
                 residentBytes: 1024, source: .libproc, exitedChildrenCpuPercent: exited)
}

@Test func unattributedIsTotalMinusGroups() throws {
    let snapshot = try grouped([usageRow(1, cpu: 20, exited: 5), usageRow(2, cpu: 5, exited: nil)], total: 40)
    #expect(snapshot.unattributedCpuPercent == 10)
    // Groups plus the unattributed line make the whole-machine line.
    let groups = try #require(snapshot.repoGroups)
    #expect(abs(groups.map(\.totalCpuPercent).reduce(0, +) + 10 - snapshot.load.total) < 1e-9)
}

@Test func unattributedFlooredAtZero() throws {
    #expect(try grouped([usageRow(1, cpu: 30, exited: 15)], total: 40).unattributedCpuPercent == 0)
}

@Test func unattributedOnlyWhenGrouped() throws {
    #expect(try smallSnapshot().unattributedCpuPercent == nil)
    let object = try #require(JSONSerialization.jsonObject(with: smallSnapshot().json()) as? [String: Any])
    #expect(object["unattributedCpuPercent"] == nil)
}

@Test func unattributedInTableAndJSON() throws {
    let snapshot = try grouped([usageRow(1, cpu: 20, exited: 6.25), usageRow(2, cpu: 5, exited: 0)])
    let lines = snapshot.table().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // The exited figure sits after the row's own CPU; the header totals both; the line after the groups is the rest.
    #expect(lines.suffix(6) == ["    PID   PPID  USER     CPU                 MEM  NAME",
                                "w  31.3%  2.0K  2 processes",
                                "      1      1  alice  20.0%  +6.3% exited  1.0K  zsh",
                                "      2      1  alice   5.0%                1.0K  zsh",
                                "",
                                "Unattributed CPU  15.5%"])
    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    #expect(Set(object.keys) == ["coreTypes", "totalBusyPercent", "intervalSeconds", "processes", "repoGroups",
                                 "unattributedCpuPercent"])
    #expect(object["unattributedCpuPercent"] as? Double == 15.54)
    let groups = try #require(object["repoGroups"] as? [[String: Any]])
    #expect(groups[0]["cpuPercent"] as? Double == 25)
    #expect(groups[0]["exitedChildrenCpuPercent"] as? Double == 6.25)
    let processes = try #require(object["processes"] as? [[String: Any]])
    #expect(processes.map { $0["exitedChildrenCpuPercent"] as? Double } == [6.25, 0])
}

@Test func snapshotRejectsTopologyLoadMismatch() throws {
    let topo = CoreTopology.singleLevel(logicalCPUCount: 4)
    let load = CPULoad(perCPU: [0, 0, 0], total: 0)
    #expect(throws: CPULoadError.topologyMismatch(topologyCPUs: 4, sampledCPUs: 3)) {
        try Snapshot(topology: topo, load: load, intervalSeconds: 1)
    }
}

// Phase 6 Step 2: the user / system split, the load average and processes launched a second, in the header and JSON.

@Test func splitFromRecordedTicks() throws {
    // CPU 0: 30 user, 10 system, 5 nice of 100; CPU 1: 0 user, 40 system of 100.
    let before = [CPUTicks(user: 100, system: 50, idle: 1000, nice: 7), CPUTicks(user: 10, system: 20, idle: 500, nice: 0)]
    let after = [CPUTicks(user: 130, system: 60, idle: 1055, nice: 12), CPUTicks(user: 10, system: 60, idle: 560, nice: 0)]
    let load = try CPULoad.compute(before: before, after: after)
    let split = try #require(load.split)
    #expect(split.user == 17.5)      // (30 + 5 nice) / 200
    #expect(split.system == 25)      // (10 + 40) / 200
    #expect(abs(split.user + split.system - load.total) < 1e-9)
}

@Test func launchesWithoutWrap() {
    #expect(LaunchRate.launches(from: 1_000, to: 1_120) == 120)
}

@Test func launchesAcrossTheWrap() {
    // XNU: `if (++pid >= PID_MAX) pid = 100`, PID_MAX 99999 — 99,998 is the last pid handed out, then 100.
    #expect(LaunchRate.launches(from: 99_990, to: 105) == 14)     // 99,991…99,998, then 100…105
    #expect(LaunchRate.launches(from: 99_998, to: 100) == 1)
}

@Test func launchesFromSamePid() {
    #expect(LaunchRate.launches(from: 500, to: 500) == 0)
}

@Test func launchesRefuseOutOfRangePids() {
    #expect(LaunchRate.launches(from: 50, to: 120) == nil)
    #expect(LaunchRate.launches(from: 1_000, to: 99_999) == nil)
}

private func pid(_ pid: Int32, at seconds: Double) -> PidReading {
    PidReading(pid: pid, uptimeNanoseconds: UInt64(seconds * 1e9), epochSeconds: 1_700_000_000 + seconds)
}

@Test func launchRatePerSecond() throws {
    let oneSecond = try #require(LaunchRate(before: pid(1_000, at: 10), after: pid(1_120, at: 11)))
    #expect(oneSecond.count == 120 && oneSecond.perSecond == 120)
    let twoSeconds = try #require(LaunchRate(before: pid(1_000, at: 10), after: pid(1_120, at: 12)))
    #expect(twoSeconds.perSecond == 60)
}

@Test func launchRateNeedsElapsedTime() {
    #expect(LaunchRate(before: pid(1_000, at: 10), after: pid(1_120, at: 10)) == nil)
    #expect(LaunchRate(before: pid(1_000, at: 10), after: pid(1_120, at: 9)) == nil)
    #expect(LaunchRate(before: pid(50, at: 10), after: pid(1_120, at: 11)) == nil)
}

@Test func loadTextTwoDecimals() {
    let load = LoadAverage(oneMinute: 41, fiveMinutes: 71.004, fifteenMinutes: 96.3)
    #expect(load.text == "41.00 71.00 96.30")
}

/// `smallSnapshot` with the split, a load average and a launch rate.
private func machineSnapshot() throws -> Snapshot {
    let levels = [PerfLevel(index: 0, name: "Super", logicalCPUCount: 1),
                  PerfLevel(index: 1, name: "Performance", logicalCPUCount: 2)]
    let topo = try CoreTopology.build(levels: levels, clusterTypeByCPU: [0: "M", 1: "M", 2: "P"])
    let load = CPULoad(perCPU: [12.34, 100.0 / 3, 95], total: 46.789, split: CPUSplit(user: 30.06, system: 16.729))
    return try Snapshot(topology: topo, load: load, intervalSeconds: 1,
                        loadAverage: LoadAverage(oneMinute: 5.123, fiveMinutes: 4.8, fifteenMinutes: 4.305),
                        launches: LaunchRate(before: pid(99_990, at: 10), after: pid(105, at: 12)))
}

@Test func headerShowsSplitLoadAndLaunches() throws {
    let lines = try machineSnapshot().table().split(separator: "\n").map(String.init)
    #expect(Array(lines.prefix(5)) == ["CPU  46.8% of the whole machine (3 CPUs, 1.0 s sample)",
                                       "  User 30.1%  System 16.7%",
                                       "Load  5.12 4.80 4.31 (1, 5, 15 min) on 3 CPUs",
                                       "Launched  7 a second",
                                       "Super        1 CPUs  (2)  avg 95.0%"])
}

@Test func jsonCarriesSplitLoadAndLaunches() throws {
    let object = try #require(JSONSerialization.jsonObject(with: machineSnapshot().json()) as? [String: Any])
    #expect(object["userBusyPercent"] as? Double == 30.1)
    #expect(object["systemBusyPercent"] as? Double == 16.7)
    let load = try #require(object["loadAverage"] as? [String: Any])
    #expect(load["oneMinute"] as? Double == 5.12 && load["fiveMinutes"] as? Double == 4.8)
    #expect(load["fifteenMinutes"] as? Double == 4.31 && load["cpus"] as? Int == 3)
    let launches = try #require(object["launches"] as? [String: Any])
    #expect(launches["count"] as? Int == 14 && launches["perSecond"] as? Double == 7)
    #expect(launches["firstPid"] as? Int == 99_990 && launches["lastPid"] as? Int == 105)
    #expect(launches["windowStart"] as? Double == 1_700_000_010 && launches["windowEnd"] as? Double == 1_700_000_012)
}

@Test func headerLeavesOutUnreadFigures() throws {
    let object = try #require(JSONSerialization.jsonObject(with: smallSnapshot().json()) as? [String: Any])
    #expect(object["userBusyPercent"] == nil && object["systemBusyPercent"] == nil)
    #expect(object["loadAverage"] == nil && object["launches"] == nil)
}
