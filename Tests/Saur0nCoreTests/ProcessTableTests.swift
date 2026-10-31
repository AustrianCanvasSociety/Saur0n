// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the window's process table — rows that keep their identity across refreshes, group lines that sum
// their members, the CLI's order by default, a header sort, the by-session regroup — and the per-refresh
// pieces under it (one scan per refresh, kernel_task every 30th refresh with its age, descriptions read
// once). Method: hand-built scans and rows through the same functions the window calls.

private let second: UInt64 = 1_000_000_000

private func identity(_ pid: Int32, parent: Int32 = 1, start: UInt64 = 1_000, uid: UInt32 = 501,
                      path: String? = nil) -> ProcessIdentity {
    ProcessIdentity(pid: pid, ppid: parent, uid: uid, user: uid == 0 ? "root" : "alice", startMicroseconds: start,
                    comm: "proc\(pid)", path: path)
}

private func scan(at seconds: UInt64, _ processes: [ProcessIdentity], cpu: [Int32: UInt64],
                  children: [Int32: UInt64] = [:]) -> ProcessListSample {
    ProcessListSample(uptimeNanoseconds: seconds * second, processes: processes,
                      taskInfo: cpu.mapValues { ProcessCounters(cpuNanoseconds: $0, residentBytes: 4096) }, ps: [:],
                      childrenCPU: children)
}

private func row(_ pid: Int32, parent: Int32 = 1, uid: UInt32 = 501, cpu: Double, exited: Double? = nil,
                 rss: UInt64 = 1024, repo: String? = nil, session: SessionInfo? = nil,
                 disk: (read: UInt64, write: UInt64)? = nil, network: (in: UInt64, out: UInt64)? = nil) -> ProcessUsage {
    var usage = ProcessUsage(pid: pid, ppid: parent, uid: uid, user: uid == 0 ? "root" : "alice", path: nil,
                             name: "proc\(pid)", cpuPercent: cpu, residentBytes: rss, source: .libproc,
                             exitedChildrenCpuPercent: exited)
    usage.repo = repo.map { RepoInfo(name: $0, root: "/work/\($0)", worktree: nil) }
    usage.session = session
    usage.disk = disk.map { DiskUsage(rate: DiskRate(readBytesPerSecond: $0.read, writeBytesPerSecond: $0.write), bytes: .zero) }
    usage.network = network.map { NetworkUsage(rate: NetworkRate(inBytesPerSecond: $0.in, outBytesPerSecond: $0.out), bytes: .zero) }
    usage.startMicroseconds = 1_000
    return usage
}

/// Rows in repo `alpha` (pids 10, 11, 12), repo `beta` (20), not in a repo (30) and root's (40), grouped as the
/// CLI groups them, under sessions `line-a` (10, 11), `line-b` (12, 20) and none.
/// `edit` changes the rows and their working folders before they are grouped (a later refresh).
private func fixture(_ edit: (inout [ProcessUsage], inout [Int32: String]) -> Void = { _, _ in })
    -> (rows: [ProcessUsage], repo: [RepoGroup], session: [SessionGroup]) {
    let a = SessionInfo(name: "line-a", kind: .claude, id: "a"), b = SessionInfo(name: "line-b", kind: .claude, id: "b")
    // Disk: 12 unreadable (nil), root's 40 too; network: 11 and 40 have no sockets (zero).
    var rows = [row(10, cpu: 9, exited: 1, rss: 100, repo: "alpha", session: a, disk: (100, 50), network: (10, 0)),
                row(11, parent: 10, cpu: 2, rss: 200, repo: "alpha", session: a, disk: (0, 20), network: (0, 0)),
                row(12, cpu: 5, rss: 300, repo: "alpha", session: b, network: (40, 2)),
                row(20, cpu: 20, rss: 400, repo: "beta", session: b, disk: (1_000, 0), network: (500, 500)),
                row(30, cpu: 30, rss: 500, disk: (5, 0), network: (3, 0)),
                row(40, uid: 0, cpu: 40, rss: 600, network: (0, 0))]
    var dirs: [Int32: String] = [10: "/work/alpha", 11: "/work/alpha", 12: "/work/alpha", 20: "/work/beta", 30: "/tmp"]
    edit(&rows, &dirs)
    let grouped = RepoGroups.assign(rows, workingDirectories: dirs,
                                    repoOfDirectory: { dir in dir == "/tmp" ? nil : RepoInfo(name: RepoResolver.basename(dir), root: dir, worktree: nil) },
                                    repoOfExecutable: { _ in nil })
    let sessions = SessionGroups.assign(grouped.rows, sources: SessionSources(
        registry: [RegistryEntry(pid: 10, sessionId: "a", name: "line-a", cwd: nil, procStartSeconds: 0),
                   RegistryEntry(pid: 12, sessionId: "b", name: "line-b", cwd: nil, procStartSeconds: 0)],
        startSeconds: [10: 0, 12: 0], environmentSessionIDs: [20: "b"], tmuxPanes: [:], tty: [:], ownUID: 501))
    return (sessions.rows, grouped.groups, sessions.groups)
}

private func table(_ f: (rows: [ProcessUsage], repo: [RepoGroup], session: [SessionGroup]),
                   _ grouping: ProcessTable.Grouping = .repo, sort: ProcessTable.Sort = .cliOrder,
                   previous: [ProcessTable.Line] = [], now: Double = 0) -> [ProcessTable.Line] {
    ProcessTable.lines(rows: f.rows, repoGroups: f.repo, sessionGroups: f.session, grouping: grouping, sort: sort,
                       unattributedCpuPercent: 1.5, now: now, previous: previous)
}

/// Every line in `lines`, at every level.
private func allLines(_ lines: [ProcessTable.Line]) -> [ProcessTable.Line] {
    lines.flatMap { [$0] + allLines($0.children ?? []) }
}

// MARK: row identity

@Test func pidKeepsItsRowAcrossRefreshesAndAReusedPidGetsANewOne() throws {
    let s1 = scan(at: 1, [identity(42)], cpu: [42: 0])
    let s2 = scan(at: 2, [identity(42)], cpu: [42: second])
    let s3 = scan(at: 3, [identity(42)], cpu: [42: 2 * second])
    let s3Reused = scan(at: 3, [identity(42, start: 9_000)], cpu: [42: 0])   // pid 42 exited and was reused
    let first = try #require(ProcessSample.usage(before: s1, after: s2, cpuCount: 1, kernelTask: nil).first)
    let second = try #require(ProcessSample.usage(before: s2, after: s3, cpuCount: 1, kernelTask: nil).first)
    let reused = try #require(ProcessSample.usage(before: s2, after: s3Reused, cpuCount: 1, kernelTask: nil).first)
    #expect(ProcessTable.rowID(first) == ProcessTable.rowID(second))
    #expect(ProcessTable.rowID(reused) != ProcessTable.rowID(first))
    func line(_ row: ProcessUsage) -> String? {
        ProcessTable.lines(rows: [row], repoGroups: [RepoGroup(name: "x", root: "/x", cpuPercent: 0, exitedChildrenCpuPercent: 0,
                                                               residentBytes: 0, pids: [42])],
                           sessionGroups: [], grouping: .repo, unattributedCpuPercent: nil).first?.children?.first?.id
    }
    #expect(line(first) == line(second))
    #expect(line(reused) != line(first))
}

// MARK: groups, order, regroup

@Test func groupLinesSumTheirMembersOwnAndExitedCPUAndMemory() throws {
    let lines = table(fixture())
    let alpha = try #require(lines.first { $0.name == "alpha" })
    #expect(alpha.cpuPercent == 17)            // 9 + 1 exited + 2 + 5
    #expect(alpha.residentBytes == 600)
    #expect(alpha.count == 3)
    #expect(alpha.children?.map(\.pid) == [10, 11, 12])   // the group's order, as the CLI lists them
    #expect(alpha.children?.first?.exitedText == "+1.0% exited")
}

@Test func defaultOrderIsTheCLIsOrder() {
    let f = fixture()
    let lines = table(f)
    #expect(lines.map(\.name) == f.repo.map(\.name) + ["Unattributed CPU"])
    #expect(lines.map(\.name) == ["beta", "alpha", RepoGroups.notInARepo, RepoGroups.systemAndOtherUsers, "Unattributed CPU"])
    #expect(lines.map(\.identifier) == ["group-0", "group-1", "group-2", "group-3", "unattributed"])
    for (line, group) in zip(lines, f.repo) { #expect(line.children?.compactMap(\.pid) == group.pids) }
    // Repo and session groups start open, the catch-alls closed (mockup E).
    #expect(lines.prefix(4).map(\.startsOpen) == [true, true, false, false])
}

@Test func pickerRegroupsTheSameRowsBySession() throws {
    let f = fixture()
    let byRepo = table(f), bySession = table(f, .session)
    func ids(_ lines: [ProcessTable.Line]) -> Set<String> { Set(lines.flatMap { $0.children ?? [] }.map(\.id)) }
    #expect(ids(byRepo) == ids(bySession))
    #expect(bySession.map(\.name) == ["line-b", "line-a", SessionGroups.noSession, SessionGroups.systemAndOtherUsers,
                                      "Unattributed CPU"])
    // Tree order as the CLI: 11 is 10's child, one level down.
    let lineA = try #require(bySession.first { $0.name == "line-a" })
    #expect(lineA.children?.map(\.pid) == [10, 11])
    #expect(lineA.children?.map(\.depth) == [0, 1])
    #expect(byRepo.first { $0.name == "alpha" }?.children?.first?.session == "line-a")
}

/// Phase 6 Step 4: By command — a line per command titled "× N" from two copies, closed at start, each copy with what
/// it owns one level down under the CLI order and flat under a header sort, every group sorted by the column.
@Test func pickerRegroupsTheSameRowsByCommand() throws {
    func process(_ pid: Int32, _ name: String, parent: Int32 = 1, cpu: Double) -> ProcessUsage {
        var usage = ProcessUsage(pid: pid, ppid: parent, uid: 501, user: "alice", path: nil, name: name, cpuPercent: cpu,
                                 residentBytes: 1024, source: .libproc, exitedChildrenCpuPercent: 0)
        usage.startMicroseconds = 1_000
        return usage
    }
    let rows = [process(100, "bash", cpu: 0), process(101, "yes", parent: 100, cpu: 3), process(102, "bash", cpu: 0),
                process(103, "yes", parent: 102, cpu: 2), process(200, "Finder", cpu: 4), process(300, "zsh", cpu: 0.5)]
    let script = ProcessArguments(argv: ["/bin/bash", "/tmp/example/runaway.sh"], environment: [:])
    let commands = CommandGroups.assign(rows, arguments: [100: script, 102: script])
    func lines(_ sort: ProcessTable.Sort) -> [ProcessTable.Line] {
        ProcessTable.lines(rows: commands.rows, repoGroups: [], sessionGroups: [], commandGroups: commands.groups,
                           grouping: .command, sort: sort, unattributedCpuPercent: 1.5)
    }
    let cli = lines(.cliOrder)
    #expect(cli.map(\.name) == ["runaway.sh × 2", "Finder", "zsh", "Unattributed CPU"])
    #expect(cli.map(\.id) == ["group:command:runaway.sh", "group:command:Finder", "group:command:zsh", "unattributed"])
    #expect(cli.prefix(3).map(\.identifier) == ["group-0", "group-1", "group-2"])
    #expect(cli.prefix(3).allSatisfy { !$0.startsOpen })
    #expect(cli[0].count == 4)
    #expect(abs(cli[0].cpuPercent - 5) < 1e-9)
    #expect(cli[0].children?.map(\.pid) == [100, 101, 102, 103])
    #expect(cli[0].children?.map(\.depth) == [0, 1, 0, 1])
    // A header sort orders every group by the column (no catch-alls here) and drops the depths.
    let byName = lines(ProcessTable.Sort(column: .name, ascending: true))
    #expect(byName.map(\.name) == ["Finder", "runaway.sh × 2", "zsh", "Unattributed CPU"])
    #expect(byName[1].children?.map(\.depth) == [0, 0, 0, 0])
}

/// The gate's round 1 (F28): By command reads every group's depths from one parent map per refresh, not one per group —
/// the CLI order and depths as before, over 1,000 command groups. Counted, not timed (the gate's round 2: a wall-clock
/// bound fails on a busy CI runner).
@Test func byCommandBuildsOneParentMapPerRefresh() throws {
    func process(_ pid: Int32, _ name: String, parent: Int32 = 1, cpu: Double) -> ProcessUsage {
        ProcessUsage(pid: pid, ppid: parent, uid: 501, user: "alice", path: nil, name: name, cpuPercent: cpu,
                     residentBytes: 1024, source: .libproc, exitedChildrenCpuPercent: 0)
    }
    var rows: [ProcessUsage] = []
    var arguments: [Int32: ProcessArguments] = [:]
    for i in 0..<1_000 {
        let pid = Int32(10_000 + i * 2)
        rows += [process(pid, "bash", cpu: 0), process(pid + 1, "tool\(i)", parent: pid, cpu: 0.01)]
        arguments[pid] = ProcessArguments(argv: ["/bin/bash", "/tmp/example/job\(i).sh"], environment: [:])
    }
    let commands = CommandGroups.assign(rows, arguments: arguments)
    func lines() -> [ProcessTable.Line] {
        ProcessTable.lines(rows: commands.rows, repoGroups: [], sessionGroups: [], commandGroups: commands.groups,
                           grouping: .command, unattributedCpuPercent: nil)
    }
    let work = WorkCount()
    let table = WorkCount.current.withValue(work) { lines() }
    #expect(table.count == 1_000)
    #expect(table.allSatisfy { $0.children?.map(\.depth) == [0, 1] })
    #expect(table.map(\.name) == commands.groups.map(\.name))
    #expect(work.parentMaps == 1)
}

@Test func headerSortOrdersMembersAndGroupsWithCatchAllsAndUnattributedLast() throws {
    let f = fixture()
    for sort in [ProcessTable.Sort(column: .cpu, ascending: true), .init(column: .name, ascending: true),
                 .init(column: .pid, ascending: false), .init(column: .memory, ascending: true)] {
        let lines = table(f, sort: sort)
        #expect(lines.last?.kind == .unattributed)
        #expect(lines.suffix(3).dropLast().map(\.name) == [RepoGroups.notInARepo, RepoGroups.systemAndOtherUsers])
        #expect(lines.map(\.identifier).prefix(4) == ["group-0", "group-1", "group-2", "group-3"])
    }
    let byCpuUp = table(f, sort: .init(column: .cpu, ascending: true))
    #expect(byCpuUp.prefix(2).map(\.name) == ["alpha", "beta"])
    #expect(byCpuUp[0].children?.map(\.pid) == [11, 12, 10])
    let byPidDown = table(f, sort: .init(column: .pid, ascending: false))
    #expect(try #require(byPidDown.first { $0.name == "alpha" }).children?.map(\.pid) == [12, 11, 10])
    // Sorted by something else, session rows lose their tree depth.
    #expect(table(f, .session, sort: .init(column: .pid, ascending: true)).flatMap { $0.children ?? [] }.allSatisfy { $0.depth == 0 })
}

/// Phase 6 Step 3 (research 2026-10-22 Finding 1): a storm's parent, 0.2% itself and `+23% exited`, sorts at 23.2% —
/// between a 5% row and a 23.3% one — while its cells still read what it used itself and what its children did.
@Test func cpuSortUsesOwnPlusExitedCPU() throws {
    let f = fixture { rows, dirs in
        rows += [row(50, cpu: 0.2, exited: 23, repo: "storm"), row(51, cpu: 23.3, repo: "storm"),
                 row(52, cpu: 5, exited: nil, repo: "storm")]
        for pid: Int32 in [50, 51, 52] { dirs[pid] = "/work/storm" }
    }
    let storm = try #require(table(f, sort: .init(column: .cpu, ascending: true)).first { $0.name == "storm" })
    #expect(storm.children?.map(\.pid) == [52, 50, 51])
    let parent = try #require(storm.children?.first { $0.pid == 50 })
    #expect(parent.cpuText == "0.2%")
    #expect(parent.exitedText == "+23.0% exited")
    #expect(abs(parent.totalCpuPercent - 23.2) < 1e-9)
    #expect(storm.totalCpuPercent == storm.cpuPercent)    // a group line's figure already holds both
}

// MARK: disk and network (Phase 5 Step 3)

@Test func groupLinesSumTheirMembersDiskAndNetwork() throws {
    let f = fixture()
    let byRepo = table(f)
    let alpha = try #require(byRepo.first { $0.name == "alpha" })
    #expect(alpha.disk?.rate == DiskRate(readBytesPerSecond: 100, writeBytesPerSecond: 70))    // 12 unreadable adds 0
    #expect(alpha.diskBytesPerSecond == 170)
    #expect(alpha.network?.rate == NetworkRate(inBytesPerSecond: 50, outBytesPerSecond: 2))
    #expect(alpha.networkBytesPerSecond == 52)
    let bySession = table(f, .session)
    let lineB = try #require(bySession.first { $0.name == "line-b" })    // 12 and 20
    #expect(lineB.diskBytesPerSecond == 1_000)
    #expect(lineB.networkBytesPerSecond == 1_042)
    for lines in [byRepo, bySession] {
        for group in lines where group.kind == .group {
            #expect(group.diskBytesPerSecond == group.children?.map(\.diskBytesPerSecond).reduce(0, +), "\(group.name)")
            #expect(group.networkBytesPerSecond == group.children?.map(\.networkBytesPerSecond).reduce(0, +), "\(group.name)")
        }
    }
}

@Test func headerSortByDiskAndByNetworkOrdersGroupsThenMembersHighestFirst() throws {
    let f = fixture()
    let byDisk = table(f, sort: .init(column: .disk, ascending: false))
    #expect(byDisk.prefix(2).map(\.name) == ["beta", "alpha"])
    #expect(byDisk[1].children?.map(\.pid) == [10, 11, 12])         // 150, 20, unreadable as 0
    #expect(byDisk.suffix(3).dropLast().map(\.name) == [RepoGroups.notInARepo, RepoGroups.systemAndOtherUsers])
    let byDiskUp = table(f, sort: .init(column: .disk, ascending: true))
    #expect(byDiskUp.prefix(2).map(\.name) == ["alpha", "beta"])
    #expect(byDiskUp[0].children?.map(\.pid) == [12, 11, 10])
    let byNetwork = table(f, .session, sort: .init(column: .network, ascending: false))
    #expect(byNetwork.prefix(2).map(\.name) == ["line-b", "line-a"])
    #expect(byNetwork[0].children?.map(\.pid) == [20, 12])
    #expect(byNetwork.last?.kind == .unattributed)
}

@Test func unattributedLineCarriesTheDiskRemainderAndNoNetwork() throws {
    let f = fixture()
    let lines = ProcessTable.lines(rows: f.rows, repoGroups: f.repo, sessionGroups: f.session, grouping: .repo,
                                   unattributedCpuPercent: 1.5,
                                   unattributedDisk: DiskRate(readBytesPerSecond: 2_000_000, writeBytesPerSecond: 500_000))
    let unattributed = try #require(lines.last)
    #expect(unattributed.kind == .unattributed)
    #expect(unattributed.diskBytesPerSecond == 2_500_000)
    #expect(unattributed.diskText == "2.5 M/s")
    #expect(unattributed.network == nil && unattributed.networkText == "")
    #expect(table(f).last?.diskText == "")      // no disk remainder given
}

@Test func processRowWithoutDiskReadsDashAndSortsAsZero() throws {
    let lines = table(fixture())
    let alpha = try #require(lines.first { $0.name == "alpha" })
    let unreadable = try #require(alpha.children?.first { $0.pid == 12 })
    #expect(unreadable.disk == nil)
    #expect(unreadable.diskText == "—")
    #expect(unreadable.diskBytesPerSecond == 0)
}

@Test func diskAndNetworkTextOnEveryLineKind() throws {
    let lines = table(fixture())
    let beta = try #require(lines.first { $0.name == "beta" })
    #expect(beta.diskText == "1.0 K/s" && beta.networkText == "1.0 K/s")
    let member = try #require(beta.children?.first)
    #expect(member.diskText == "1.0 K/s" && member.networkText == "1.0 K/s")
    let quiet = try #require(lines.first { $0.name == "alpha" }?.children?.first { $0.pid == 11 })
    #expect(quiet.diskText == "20 B/s" && quiet.networkText == "0")
    let root = try #require(lines.first { $0.name == RepoGroups.systemAndOtherUsers })
    #expect(root.diskText == "0")       // a group of unreadable rows sums to zero
    #expect(root.children?.first?.diskText == "—")
}

@Test func noRowsLeavesOnlyTheUnattributedLine() {
    let lines = ProcessTable.lines(rows: [], repoGroups: [], sessionGroups: [], grouping: .repo, unattributedCpuPercent: 3)
    #expect(lines.map(\.kind) == [.unattributed])
    #expect(lines.first?.cpuText == "3.0%")
}

@Test func vmAndKernelTaskReadableText() throws {
    var vm = row(50, cpu: 10)
    vm.readableName = "VM: colima · 4 cores"
    vm.vm = VMUsage(name: "colima", vcpus: 4, shareOfAllotted: 45)
    var kernel = row(0, uid: 0, cpu: 2)
    kernel.readableName = "the macOS kernel"
    let group = RepoGroup(name: RepoGroups.systemAndOtherUsers, root: nil, cpuPercent: 12, exitedChildrenCpuPercent: 0,
                          residentBytes: 0, pids: [50, 0])
    let lines = ProcessTable.lines(rows: [vm, kernel], repoGroups: [group], sessionGroups: [], grouping: .repo,
                                   unattributedCpuPercent: nil, kernelTaskAge: 7)
    let members = try #require(lines.first?.children)
    #expect(members.map(\.readableName) == ["VM: colima · 4 cores · 45.0% of its cores", "the macOS kernel · read 7 s ago"])
}

@Test func unnamedKernelTaskStillShowsItsReadAge() throws {
    let kernel = row(0, uid: 0, cpu: 2)
    let group = RepoGroup(name: RepoGroups.systemAndOtherUsers, root: nil, cpuPercent: 2, exitedChildrenCpuPercent: 0,
                          residentBytes: 0, pids: [0])
    for age: Int? in [nil, 7] {
        let lines = ProcessTable.lines(rows: [kernel], repoGroups: [group], sessionGroups: [], grouping: .repo,
                                       unattributedCpuPercent: nil, kernelTaskAge: age)
        let member = try #require(lines.first?.children?.first)
        #expect(member.readableName == (age == nil ? nil : "read 7 s ago"))
    }
}

// MARK: per-refresh pieces

@Test func scanReusedAsTheNextStartGivesTheSameUsageAsTwoFreshScans() throws {
    let s1 = scan(at: 1, [identity(1), identity(2)], cpu: [1: 0, 2: 0])
    let s2 = scan(at: 2, [identity(1), identity(2)], cpu: [1: second / 2, 2: second / 4])
    let s3 = scan(at: 3, [identity(1), identity(3)], cpu: [1: second, 3: second / 10])
    var scanner = ProcessScanner()
    #expect(scanner.next(s1) == nil)
    var reused: [[ProcessUsage]] = []
    for s in [s2, s3] {
        let next = scanner.next(s)
        let window = try #require(next)
        reused.append(try ProcessSample.usage(before: window.before, after: window.after, cpuCount: 2, kernelTask: nil))
    }
    #expect(reused[0] == (try ProcessSample.usage(before: s1, after: s2, cpuCount: 2, kernelTask: nil)))
    #expect(reused[1] == (try ProcessSample.usage(before: s2, after: s3, cpuCount: 2, kernelTask: nil)))
}

@Test func kernelTaskReadEveryThirtiethRefreshAndItsAgeGrows() {
    // Every 30th, not 10th: one `top` reading costs 0.55–0.6 s of CPU (Phase 4 Step 3's overhead budget).
    #expect((0..<75).filter(ProcessReaders.KernelTaskSchedule.isDue) == [0, 30, 60])
    var schedule = ProcessReaders.KernelTaskSchedule()
    #expect(schedule.ageSeconds(atNanoseconds: 5 * second) == nil)
    schedule.record(KernelTaskSample(cpuPercentPerCore: 30, residentBytes: 1), atNanoseconds: 2 * second)
    #expect(schedule.ageSeconds(atNanoseconds: 2 * second) == 0)
    #expect(schedule.ageSeconds(atNanoseconds: 9 * second + 1) == 7)
    schedule.record(KernelTaskSample(cpuPercentPerCore: 10, residentBytes: 1), atNanoseconds: 12 * second)
    #expect(schedule.ageSeconds(atNanoseconds: 13 * second) == 1)
    #expect(schedule.latest?.cpuPercentPerCore == 10)
}

@Test func failedKernelTaskReadKeepsLastSampleAndItsAge() throws {
    enum ReadError: Error { case failed }
    var schedule = ProcessReaders.KernelTaskSchedule()
    #expect(schedule.record(.failure(ReadError.failed), atNanoseconds: second) != nil)
    #expect(schedule.latest == nil)
    #expect(schedule.ageSeconds(atNanoseconds: second) == nil)
    #expect(schedule.record(.success(KernelTaskSample(cpuPercentPerCore: 30, residentBytes: 1)),
                            atNanoseconds: 2 * second) == nil)
    let problem = schedule.record(.failure(ReadError.failed), atNanoseconds: 5 * second)
    #expect(problem?.contains("cannot read kernel_task") == true)
    #expect(schedule.latest?.cpuPercentPerCore == 30)
    #expect(schedule.ageSeconds(atNanoseconds: 9 * second) == 7)
    #expect(schedule.record(.success(KernelTaskSample(cpuPercentPerCore: 10, residentBytes: 1)),
                            atNanoseconds: 12 * second) == nil)
    #expect(schedule.latest?.cpuPercentPerCore == 10)
    #expect(schedule.ageSeconds(atNanoseconds: 13 * second) == 1)
}

@Test func descriptionsReadOncePerNameAndExtendedForNewOnes() {
    var reads: [String] = []
    var sources = DescriptionSources(launchdLabels: [:], manPages: ["exampled": "/usr/share/man/man8/exampled.8",
                                                                    "otherd": "/usr/share/man/man8/otherd.8"])
    func extend(_ names: [String]) {
        let sample = ProcessListSample(uptimeNanoseconds: 1, processes: names.enumerated().map { i, name in
            ProcessIdentity(pid: Int32(i + 1), ppid: 1, uid: 0, user: "root", startMicroseconds: 1, comm: name,
                            path: "/usr/libexec/\(name)")
        }, taskInfo: [:], ps: [:])
        sources.extend(for: sample, oneLiner: { name, _ in reads.append(name); return ManLine(text: "\(name) text", scope: .system) },
                       bundleName: { _ in nil })
    }
    extend(["exampled"])
    extend(["exampled", "otherd"])
    #expect(reads == ["exampled", "otherd"])
    #expect(sources.describe(pid: 2, name: "otherd", path: "/usr/libexec/otherd") == "otherd text")
}

// MARK: - Folding (Phase 4 Step 4, touchup 5: Collapse all / Expand all)

private func group(_ id: String, startsOpen: Bool) -> ProcessTable.Line {
    ProcessTable.Line(id: "group:\(id)", identifier: "", kind: .group, name: id, cpuPercent: 0, count: 1,
                      startsOpen: startsOpen, children: [])
}

@Test func foldingStartsFromEachGroupsDefault() {
    let folding = ProcessTable.Folding()
    #expect(folding.isOpen(group("repo", startsOpen: true)))
    #expect(!folding.isOpen(group("catch-all", startsOpen: false)))
    #expect(folding.anyOpen([group("repo", startsOpen: true), group("catch-all", startsOpen: false)]))
}

@Test func collapseAllClosesEveryGroupIncludingLaterOnes() {
    var folding = ProcessTable.Folding()
    let repo = group("repo", startsOpen: true), catchAll = group("catch-all", startsOpen: false)
    folding.setOpen(catchAll, true)
    folding.collapseAll()
    #expect(!folding.isOpen(repo) && !folding.isOpen(catchAll))
    #expect(!folding.isOpen(group("appeared-later", startsOpen: true)))
    #expect(!folding.anyOpen([repo, catchAll]))
}

@Test func expandAllOpensEveryGroupCatchAllsIncluded() {
    var folding = ProcessTable.Folding()
    folding.expandAll()
    #expect(folding.isOpen(group("catch-all", startsOpen: false)))
    #expect(folding.isOpen(group("appeared-later", startsOpen: true)))
}

@Test func aSingleToggleOverridesTheFoldStateUntilTheNextFold() {
    var folding = ProcessTable.Folding()
    let repo = group("repo", startsOpen: true), other = group("other", startsOpen: true)
    folding.collapseAll()
    folding.setOpen(repo, true)
    #expect(folding.isOpen(repo) && !folding.isOpen(other))
    #expect(folding.anyOpen([repo, other]))          // the button reads Collapse all again
    folding.setOpen(repo, true)                      // already open: nothing changes
    #expect(folding.isOpen(repo))
    folding.collapseAll()                            // clears the single toggle too
    #expect(!folding.isOpen(repo))
    folding.expandAll()
    folding.setOpen(other, false)
    #expect(folding.anyOpen([repo, other]))          // one closed, the rest open: still Collapse all
}

@Test func anyOpenIgnoresLinesThatAreNotGroups() {
    let process = ProcessTable.Line(id: "process:1:1", identifier: "process-1", kind: .process, name: "p", cpuPercent: 0)
    #expect(!ProcessTable.Folding().anyOpen([process]))
}

// MARK: - Sub-groups under the catch-alls and the VMs group (Phase 5 Step 4)

private let bigMemory: UInt64 = 2 << 30

/// Repo `alpha` (10), a VM (50), and in "Not in a repo": Firefox (60 with 2 GiB, 61), a bare row at 3% CPU (62) and two
/// small ones (63, 64); root's 40 in "System and other users". Broken out on a 128 GiB machine.
/// `edit` changes the rows and their working folders before they are grouped (a later refresh).
private func firefox(_ pid: Int32, cpu: Double, rss: UInt64) -> ProcessUsage {
    let path = pid == 60 ? "/Applications/Firefox.app/Contents/MacOS/firefox"
        : "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container"
    return ProcessUsage(pid: pid, ppid: 1, uid: 501, user: "alice", path: path, name: "proc\(pid)", cpuPercent: cpu,
                        residentBytes: rss, source: .libproc)
}

private func brokenFixture(_ edit: (inout [ProcessUsage], inout [Int32: String]) -> Void = { _, _ in })
    -> (rows: [ProcessUsage], repo: [RepoGroup], session: [SessionGroup]) {
    var vm = row(50, cpu: 50, rss: 4_000)
    vm.vm = VMUsage(name: "colima", vcpus: 4, shareOfAllotted: 0)
    var rows = [row(10, cpu: 9, rss: 100), vm, firefox(60, cpu: 0.5, rss: bigMemory), firefox(61, cpu: 0.1, rss: 100),
                row(62, cpu: 3, rss: 1_000), row(63, cpu: 0.2, rss: 5_000), row(64, cpu: 0.1, rss: 50),
                row(40, uid: 0, cpu: 0.3, rss: 600)]
    var dirs: [Int32: String] = [10: "/work/alpha", 50: "/tmp", 60: "/tmp", 61: "/tmp", 62: "/tmp", 63: "/tmp", 64: "/tmp"]
    edit(&rows, &dirs)
    let grouped = RepoGroups.assign(rows, workingDirectories: dirs,
                                    repoOfDirectory: { $0 == "/work/alpha" ? RepoInfo(name: "alpha", root: $0, worktree: nil) : nil },
                                    repoOfExecutable: { _ in nil })
    let sessions = SessionGroups.assign(grouped.rows, sources: SessionSources(registry: [], startSeconds: [:],
                                                                              environmentSessionIDs: [:], tmuxPanes: [:],
                                                                              tty: [:], ownUID: 501))
    let out = CatchAllBreakout.apply(rows: sessions.rows, repoGroups: grouped.groups, sessionGroups: sessions.groups,
                                     thresholds: CatchAllBreakout.Thresholds(physicalMemoryBytes: 128 << 30,
                                                                             machineDiskBytesPerSecond: nil,
                                                                             machineNetworkBytesPerSecond: nil),
                                     isAppBundle: { _ in true })
    return (out.rows, out.repoGroups, out.sessionGroups)
}

@Test func subgroupLinesUnderACatchAllWithIdentifiers() throws {
    let lines = table(brokenFixture())
    #expect(lines.map(\.name) == ["alpha", RepoGroups.vms, RepoGroups.notInARepo, RepoGroups.systemAndOtherUsers,
                                  "Unattributed CPU"])
    let children = try #require(lines[2].children)
    #expect(children.map(\.kind) == [.process, .subgroup, .subgroup])
    #expect(children.map(\.name) == ["proc62", "Firefox", "2 other processes"])
    #expect(children.map(\.identifier) == ["process-62", "subgroup-2-0", "subgroup-2-1"])
    #expect(children.map(\.startsOpen) == [false, false, false])
    let firefox = children[1]
    #expect(firefox.id == "subgroup:catch-all:Not in a repo:app:Firefox")
    #expect(firefox.count == 2)
    #expect(firefox.residentBytes == bigMemory + 100)
    #expect(firefox.cpuText == "0.6%")
    #expect(firefox.children?.map(\.pid) == [60, 61])
    #expect(firefox.children?.map(\.app) == ["Firefox", "Firefox"])
    #expect(children[2].children?.map(\.pid) == [63, 64])
    #expect(children[0].app == nil)
    // Every group but a catch-all lists its processes directly.
    #expect(lines[1].children?.map(\.kind) == [.process])
    #expect(lines[3].children?.map(\.name) == ["1 other process"])
    #expect(lines[3].children?.first?.identifier == "subgroup-3-0")
}

@Test func subgroupsOpenAndCloseWithTheirCatchAllAndWithCollapseAll() throws {
    let lines = table(brokenFixture())
    let catchAll = lines[2]
    let firefox = try #require(catchAll.children?[1])
    var folding = ProcessTable.Folding()
    #expect(!folding.isOpen(catchAll) && !folding.isOpen(firefox))    // closed: its sub-groups are hidden with it
    folding.expandAll()
    #expect(folding.isOpen(catchAll) && folding.isOpen(firefox))
    folding.setOpen(firefox, false)
    #expect(folding.isOpen(catchAll) && !folding.isOpen(firefox))     // a toggle holds until the next fold
    folding.collapseAll()
    #expect(!folding.isOpen(firefox))
    folding.setOpen(firefox, true)
    #expect(!folding.anyOpen(lines))                                  // the button counts group lines only
    folding.expandAll()
    #expect(folding.isOpen(firefox))
}

@Test func headerSortOrdersLiftedEntriesAndKeepsOtherLast() throws {
    let fixture = brokenFixture()
    func catchAll(_ sort: ProcessTable.Sort) throws -> ProcessTable.Line {
        try #require(table(fixture, sort: sort).first { $0.name == RepoGroups.notInARepo })
    }
    let byMemory = try catchAll(ProcessTable.Sort(column: .memory, ascending: false))
    #expect(byMemory.children?.map(\.name) == ["Firefox", "proc62", "2 other processes"])
    #expect(byMemory.children?[2].children?.map(\.pid) == [63, 64])
    let byName = try catchAll(ProcessTable.Sort(column: .name, ascending: false))
    #expect(byName.children?.map(\.name) == ["proc62", "Firefox", "2 other processes"])
    #expect(byName.children?[1].children?.map(\.pid) == [61, 60])     // members by the column too
    #expect(byName.children?.map(\.identifier) == ["process-62", "subgroup-2-0", "subgroup-2-1"])
}

@Test func vmsGroupStartsOpenAndSitsBetweenReposAndCatchAlls() {
    let fixture = brokenFixture()
    for sort in [ProcessTable.Sort.cliOrder, ProcessTable.Sort(column: .cpu, ascending: false),
                 ProcessTable.Sort(column: .cpu, ascending: true)] {
        let lines = table(fixture, sort: sort)
        #expect(lines.map(\.name) == ["alpha", RepoGroups.vms, RepoGroups.notInARepo, RepoGroups.systemAndOtherUsers,
                                      "Unattributed CPU"])
        #expect(lines[1].id == "group:vms")
        #expect(lines[1].startsOpen)
    }
    let sessions = table(fixture, .session)
    #expect(sessions.map(\.name) == [SessionGroups.vms, SessionGroups.noSession, SessionGroups.systemAndOtherUsers,
                                     "Unattributed CPU"])
    #expect(sessions[1].children?.map(\.identifier) == ["process-10", "process-62", "subgroup-1-0", "subgroup-1-1"])
}

@Test func theStripsReadProcessesUnderSubgroups() {
    let flat = ProcessTable.flattened(table(brokenFixture()))
    #expect(flat[2].children?.map(\.pid) == [62, 60, 61, 63, 64])
    #expect(TopMovers.rows(flat, rate: { _ in 1 }).filter { $0.group == RepoGroups.notInARepo }.count == 5)
}

// MARK: - Stable rows under a fixed sort (Backlog stable-rows-under-fixed-sort)

@Test func nameAndPidAndUserAndSessionAreTheFixedSorts() {
    let fixed: [ProcessTable.Column] = [.name, .pid, .user, .session]
    for column in [ProcessTable.Column.name, .pid, .user, .session, .cpu, .memory, .disk, .network] {
        #expect(ProcessTable.Sort(column: column, ascending: true).isFixed == fixed.contains(column), "\(column)")
    }
}

@Test func fixedSortKeepsTheLastRefreshsOrderWhenFiguresMove() throws {
    // Under PID, groups have no value and tie on the CLI's order, which follows CPU: beta (20) before alpha (17).
    let byPid = ProcessTable.Sort(column: .pid, ascending: true)
    let before = table(fixture(), sort: byPid)
    #expect(before.prefix(2).map(\.name) == ["beta", "alpha"])
    // alpha's 10 now busier than beta: a fresh table puts alpha first; the next refresh keeps beta first.
    let busier = fixture { rows, _ in rows[0] = row(10, cpu: 50, rss: 100, repo: "alpha", session: rows[0].session) }
    #expect(table(busier, sort: byPid).prefix(2).map(\.name) == ["alpha", "beta"])
    let kept = table(busier, sort: byPid, previous: before)
    #expect(kept.map(\.id) == before.map(\.id))
    #expect(kept.map(\.identifier) == before.map(\.identifier))
    // The figures are the new refresh's.
    #expect(kept.first { $0.name == "alpha" }?.cpuPercent == 57)
}

@Test func aNewProcessTakesItsSortedPlaceUnderAFixedSort() throws {
    let byPid = ProcessTable.Sort(column: .pid, ascending: true)
    let before = table(fixture(), sort: byPid)
    let joined = fixture { rows, dirs in
        rows += [row(13, cpu: 1, repo: "alpha"), row(5, cpu: 1, repo: "alpha")]
        dirs[13] = "/work/alpha"; dirs[5] = "/work/alpha"
    }
    let alpha = try #require(table(joined, sort: byPid, previous: before).first { $0.name == "alpha" })
    #expect(alpha.children?.map(\.pid) == [5, 10, 11, 12, 13])
    #expect(alpha.children?.allSatisfy { !$0.gone } == true)
}

@Test func anExitedProcessKeepsItsLineMarkedGoneUntilAMinuteIsUpOrTheOrderIsRebuilt() throws {
    let byName = ProcessTable.Sort(column: .name, ascending: true)
    let before = table(fixture(), sort: byName)
    let exited = fixture { rows, _ in rows.removeAll { $0.pid == 11 || $0.pid == 20 } }
    let kept = table(exited, sort: byName, previous: before)
    let alpha = try #require(kept.first { $0.name == "alpha" })
    #expect(alpha.children?.map(\.pid) == [10, 11, 12])
    let gone = try #require(alpha.children?[1])
    #expect(gone.gone)
    #expect([gone.cpuText, gone.memoryText, gone.diskText, gone.networkText, gone.exitedText].joined().isEmpty)
    #expect(alpha.children?[0].gone == false)
    // beta's only process exited: the group line stays, gone, with its gone member.
    let beta = try #require(kept.first { $0.name == "beta" })
    #expect(beta.gone && beta.children?.allSatisfy { $0.gone } == true)
    #expect(kept.map(\.id) == before.map(\.id))
    // Still there on the refresh after, then gone once the table is built afresh (a sort change or a fold).
    let again = table(exited, sort: byName, previous: kept)
    #expect(again.first { $0.name == "alpha" }?.children?.map(\.pid) == [10, 11, 12])
    #expect(table(exited, sort: byName).first { $0.name == "alpha" }?.children?.map(\.pid) == [10, 12])
    #expect(table(exited, sort: byName).contains { $0.name == "beta" } == false)
}

@Test func greyedLinesLeaveAMinuteAfterTheRefreshThatFirstMarkedThem() throws {
    let byName = ProcessTable.Sort(column: .name, ascending: true)
    let before = table(fixture(), sort: byName, now: 90)
    let exited = fixture { rows, _ in rows.removeAll { $0.pid == 11 || $0.pid == 20 } }
    var shown = table(exited, sort: byName, previous: before, now: 100)    // 11 and beta first marked gone at 100 s
    #expect(shown.first { $0.name == "alpha" }?.children?.first { $0.pid == 11 }?.goneSince == 100)
    // Each refresh after keeps the first mark: at 159 s, 59 s on, both still there.
    for now in stride(from: 101.0, through: 159, by: 1) { shown = table(exited, sort: byName, previous: shown, now: now) }
    #expect(shown.first { $0.name == "alpha" }?.children?.map(\.pid) == [10, 11, 12])
    #expect(shown.first { $0.name == "beta" }?.goneSince == 100)
    // At 161 s, 61 s on, both left; the lines still shown keep their places.
    let after = table(exited, sort: byName, previous: shown, now: 161)
    #expect(after.first { $0.name == "alpha" }?.children?.map(\.pid) == [10, 12])
    #expect(after.contains { $0.name == "beta" } == false)
    #expect(allLines(after).allSatisfy { !$0.gone })
}

@Test func aProcessThatMovedGroupLeavesNoGreyedCopyBehind() throws {
    let byName = ProcessTable.Sort(column: .name, ascending: true)
    let before = table(fixture(), sort: byName)
    // 12 changed folder from alpha to beta; 20, beta's only process, to alpha: both still run, so nothing is greyed.
    let moved = fixture { _, dirs in dirs[12] = "/work/beta"; dirs[20] = "/work/alpha" }
    let after = table(moved, sort: byName, previous: before)
    #expect(allLines(after).allSatisfy { !$0.gone })
    let ids = allLines(after).filter { $0.kind == .process }.map(\.id)
    #expect(ids.count == Set(ids).count)    // each process shown once
    #expect(after.first { $0.name == "alpha" }?.children?.map(\.pid) == [10, 11, 20])
    #expect(after.first { $0.name == "beta" }?.children?.map(\.pid) == [12])
    // A group whose only process moved leaves at once, not greyed.
    let onlyMoved = table(fixture { _, dirs in dirs[20] = "/work/alpha" }, sort: byName, previous: before)
    #expect(onlyMoved.contains { $0.name == "beta" } == false && allLines(onlyMoved).allSatisfy { !$0.gone })
    // A group that ended while one of its processes moved out: greyed with only what ended.
    let movedAndExited = fixture { rows, dirs in rows.removeAll { $0.pid == 10 || $0.pid == 11 }; dirs[12] = "/work/beta" }
    let ended = table(movedAndExited, sort: byName, previous: before)
    let alpha = try #require(ended.first { $0.name == "alpha" })
    #expect(alpha.gone && alpha.children?.map(\.pid) == [10, 11])
    #expect(ended.first { $0.name == "beta" }?.children?.map(\.pid) == [12, 20])
    let backAgain = table(fixture(), sort: byName, previous: after)
    #expect(allLines(backAgain).filter { $0.pid == 12 }.map(\.gone) == [false])
}

@Test func aGroupWithOnlyGreyedLinesHasNoLiveProcesses() throws {
    let byName = ProcessTable.Sort(column: .name, ascending: true)
    let exited = fixture { rows, _ in rows.removeAll { $0.pid == 11 || $0.pid == 20 } }
    let kept = table(exited, sort: byName, previous: table(fixture(), sort: byName))
    let beta = try #require(kept.first { $0.name == "beta" })
    #expect(ProcessTable.liveProcesses(beta).isEmpty)
    let alpha = try #require(kept.first { $0.name == "alpha" })
    #expect(ProcessTable.liveProcesses(alpha).map(\.pid) == [10, 12])
    let members = try #require(alpha.children)
    #expect(ProcessTable.liveProcesses(members[1]).isEmpty)    // 11, greyed, alone
    #expect(ProcessTable.liveProcesses(members[0]).map(\.pid) == [10])
}

@Test func greyedLinesAreNoSearchMatches() throws {
    let byName = ProcessTable.Sort(column: .name, ascending: true)
    let exited = fixture { rows, _ in rows.removeAll { $0.pid == 11 || $0.pid == 20 } }
    let kept = table(exited, sort: byName, previous: table(fixture(), sort: byName))
    #expect(ProcessTable.filtered(kept, by: "proc11").isEmpty)
    #expect(ProcessTable.filtered(kept, by: "beta").isEmpty)
    // By the group's title, its live members only, counted against the processes it holds.
    let alpha = try #require(ProcessTable.filtered(kept, by: "alpha").first)
    #expect(alpha.children?.map(\.pid) == [10, 12])
    #expect(alpha.countText == "2 of 2 processes")
}

@Test func aReusedPidAndItsGreyedRowShareNoIdentifier() throws {
    let byName = ProcessTable.Sort(column: .name, ascending: true)
    let before = table(fixture(), sort: byName)
    // 11 exited and its pid went to a new process in alpha: one greyed row, one live, both pid 11.
    let reused = fixture { rows, _ in rows[1].startMicroseconds = 9_000 }
    let elevens = allLines(table(reused, sort: byName, previous: before)).filter { $0.pid == 11 }
    #expect(elevens.map(\.gone).sorted { !$0 && $1 } == [false, true])
    let live = try #require(elevens.first { !$0.gone })
    let greyed = try #require(elevens.first { $0.gone })
    #expect(live.identifier == "process-11" && greyed.identifier == "gone-process-11")
    for prefix in ["name", "cpu", "memory", "disk", "network", "user", "session", "readable-name", "worktree", "exited"] {
        #expect(live.cellIdentifier(prefix) == "\(prefix)-11")
        #expect(greyed.cellIdentifier(prefix) == "gone-\(prefix)-11")
    }
    // A greyed group line's identifier is marked too, so the reader never takes it for a live group.
    let exited = fixture { rows, _ in rows.removeAll { $0.pid == 20 } }
    let beta = try #require(table(exited, sort: byName, previous: before).first { $0.name == "beta" })
    #expect(beta.identifier.hasPrefix("gone-group-"))
}

@Test func aSubgroupThatLeavesLeavesAtOnceWithWhatEndedUnderIt() throws {
    // Round 3 of the Phase 5 gate: Firefox lifted at 1.1% CPU from its main (60) and a helper (61); the helper ends,
    // Firefox drops under the lift and its live main folds into "N other processes". No greyed "Firefox" line stays
    // reading "Firefox closed", and the ended helper is greyed nowhere.
    let byName = ProcessTable.Sort(column: .name, ascending: true)
    let small = { (rows: inout [ProcessUsage], _: inout [Int32: String]) in
        rows[2] = firefox(60, cpu: 0.5, rss: 100); rows[3] = firefox(61, cpu: 0.6, rss: 100)
    }
    let before = table(brokenFixture(small), sort: byName)
    #expect(allLines(before).contains { $0.id == "subgroup:catch-all:Not in a repo:app:Firefox" })
    let helperEnded = brokenFixture { rows, dirs in small(&rows, &dirs); rows.remove(at: 3) }
    let after = table(helperEnded, sort: byName, previous: before)
    #expect(allLines(after).contains { $0.name == "Firefox" } == false)
    #expect(allLines(after).allSatisfy { !$0.gone })
    #expect(allLines(after).filter { $0.pid == 60 }.map(\.gone) == [false])
    // The whole app ended: its sub-group leaves at once, nothing of it greyed.
    let appEnded = brokenFixture { rows, _ in rows.removeAll { $0.pid == 60 || $0.pid == 61 } }
    let quit = table(appEnded, sort: byName, previous: table(brokenFixture(), sort: byName))
    #expect(allLines(quit).contains { $0.name == "Firefox" || $0.pid == 60 || $0.pid == 61 } == false)
    #expect(allLines(quit).allSatisfy { !$0.gone })
}

@Test func aSubgroupStillShownKeepsItsEndedProcessesGreyed() throws {
    // Firefox stays lifted on its main's 2 GiB when a second helper (65) ends: greyed under the live Firefox line.
    let byName = ProcessTable.Sort(column: .name, ascending: true)
    let before = table(brokenFixture { rows, dirs in rows.append(firefox(65, cpu: 0.1, rss: 100)); dirs[65] = "/tmp" },
                       sort: byName)
    let after = table(brokenFixture(), sort: byName, previous: before)
    let catchAll = try #require(after.first { $0.name == RepoGroups.notInARepo })
    let shown = try #require(catchAll.children?.first { $0.name == "Firefox" })
    #expect(!shown.gone && shown.identifier == "subgroup-2-0")
    #expect(shown.children?.filter(\.gone).map(\.pid) == [65])
    #expect(ProcessTable.liveProcesses(shown).compactMap(\.pid).sorted() == [60, 61])
}

@Test func figureSortsFollowTheFiguresWhateverCameBefore() {
    let byCpu = ProcessTable.Sort(column: .cpu, ascending: false)
    let before = table(fixture(), sort: byCpu)
    let busier = fixture { rows, _ in
        rows[0] = row(10, cpu: 50, rss: 100, repo: "alpha", session: rows[0].session)
        rows.removeAll { $0.pid == 11 }
    }
    let after = table(busier, sort: byCpu, previous: before)
    #expect(after.prefix(2).map(\.name) == ["alpha", "beta"])
    #expect(after.first?.children?.map(\.pid) == [10, 12])
    #expect(after.allSatisfy { !$0.gone })
}

// MARK: - Resizable columns (Backlog resizable-columns)

@Test func defaultColumnWidthsAreTheFixedOnesAndGiveThe802PointMinimum() {
    let widths = ProcessTable.ColumnWidths()
    #expect(ProcessTable.ColumnWidths.valueColumns.map { widths[$0] } == [40, 52, 96, 64, 64, 64, 90])
    #expect(widths.total == 470)
    #expect(widths.windowMinWidth == 802)
    // The table is the window less its 32 pt padding: at the minimum Name has its 148 pt floor.
    #expect(widths.nameWidth(tableWidth: 770) == 148)
    #expect(widths.nameWidth(tableWidth: 1_000) == 378)
    #expect(widths.nameWidth(tableWidth: 500) == 148)
}

@Test func aWiderColumnRaisesTheMinimumAndWidthsStayInsideTheirLimits() {
    var widths = ProcessTable.ColumnWidths()
    widths.set(.pid, 120)
    #expect(widths[.pid] == 120)
    #expect(widths.windowMinWidth == 882)
    #expect(widths.nameWidth(tableWidth: 850) == 148)
    widths.set(.session, 10)
    #expect(widths[.session] == ProcessTable.ColumnWidths.limits[.session]?.lowerBound)
    widths.set(.cpu, 10_000)
    #expect(widths[.cpu] == ProcessTable.ColumnWidths.limits[.cpu]?.upperBound)
    // Name is not a value column: setting it changes nothing.
    let before = widths
    widths.set(.name, 300)
    #expect(widths == before)
}

@Test func aFullWidthScrollBarWidensTheMinimumByItsWidth() {
    // macOS shows full-width scroll bars (a mouse connected, or "Always"): the vertical bar's 15 pt come off the
    // table's width, so the window's minimum grows by them and Name keeps its floor.
    let widths = ProcessTable.ColumnWidths()
    #expect(widths.windowMinWidth(scroller: 15) == 817)
    #expect(widths.windowMinWidth(scroller: 0) == widths.windowMinWidth)
}

@Test func draggingNamesEdgeTradesWidthEvenlyWithTheValueColumns() {
    // A 1000 pt table: Name is 378 at the defaults. Dragged 35 pt wider, each of the seven value columns gives 5.
    var widths = ProcessTable.ColumnWidths()
    widths.resizeName(to: 413, tableWidth: 1_000)
    #expect(ProcessTable.ColumnWidths.valueColumns.map { widths[$0] } == [35, 47, 91, 59, 59, 59, 85])
    #expect(widths.nameWidth(tableWidth: 1_000) == 413)
    #expect(widths.windowMinWidth == 767)
    // Dragged back narrower, they take it back evenly.
    widths.resizeName(to: 378, tableWidth: 1_000)
    #expect(widths == ProcessTable.ColumnWidths())
}

@Test func aColumnAtItsLimitLeavesTheRestOfANameDragToTheOthers() {
    // 70 pt wider: PID can give only 8 (to its 32 pt floor) and Memory 6 (to 58); the other five give the rest.
    var widths = ProcessTable.ColumnWidths()
    widths.resizeName(to: 448, tableWidth: 1_000)
    #expect(widths[.pid] == 32 && widths[.memory] == 58)
    #expect(abs(widths.nameWidth(tableWidth: 1_000) - 448) < 1e-9)
    #expect(abs(widths.total - 400) < 1e-9)
}

@Test func nameNeverDropsBelowItsFloorNorTakesMoreThanTheColumnsCanGive() {
    var widths = ProcessTable.ColumnWidths()
    widths.resizeName(to: 50, tableWidth: 1_000)
    #expect(abs(widths.nameWidth(tableWidth: 1_000) - ProcessTable.ColumnWidths.nameFloor) < 1e-9)
    // Every value column at its floor (332 pt together): Name can grow to 1000 − 332 − 152 and no further.
    widths.resizeName(to: 5_000, tableWidth: 1_000)
    let floors = ProcessTable.ColumnWidths.valueColumns.map { ProcessTable.ColumnWidths.limits[$0]!.lowerBound }
    #expect(ProcessTable.ColumnWidths.valueColumns.map { widths[$0] } == floors)
    #expect(widths.nameWidth(tableWidth: 1_000) == 1_000 - 332 - ProcessTable.ColumnWidths.tableOverhead)
}

@Test func columnWidthsRoundTripThroughTheirSavedFormAndIgnoreWhatTheyDoNotKnow() throws {
    var widths = ProcessTable.ColumnWidths()
    widths.set(.memory, 100)
    let saved = try #require(widths.saved)
    #expect(ProcessTable.ColumnWidths(saved: saved) == widths)
    // Unknown keys, a missing column and an out-of-range width: defaults and limits win.
    let odd = Data(#"{"memory": 5000, "bogus": 3}"#.utf8)
    let read = ProcessTable.ColumnWidths(saved: odd)
    #expect(read[.memory] == ProcessTable.ColumnWidths.limits[.memory]?.upperBound)
    #expect(read[.pid] == 40)
    #expect(ProcessTable.ColumnWidths(saved: Data("not json".utf8)) == ProcessTable.ColumnWidths())
    #expect(ProcessTable.ColumnWidths(saved: nil) == ProcessTable.ColumnWidths())
}

// MARK: - Search (Backlog window-search)

@Test func searchKeepsMatchingRowsUnderTheirGroupsWithNOfMCounts() throws {
    let lines = table(fixture())
    // "PROC1" matches proc10, proc11, proc12 by name (case-insensitive), all in alpha.
    let found = ProcessTable.filtered(lines, by: "PROC1")
    #expect(found.map(\.name) == ["alpha"])
    let alpha = try #require(found.first)
    #expect(alpha.children?.map(\.pid) == [10, 11, 12])
    #expect(alpha.count == 3 && alpha.total == 3)
    #expect(alpha.countText == "3 of 3 processes")
    // By pid text: "20" matches beta's 20 only, the count reading 1 of 1.
    #expect(ProcessTable.filtered(lines, by: "20").map(\.name) == ["beta"])
    // By user: root's 40 under System and other users.
    let root = ProcessTable.filtered(lines, by: "root")
    #expect(root.map(\.name) == [RepoGroups.systemAndOtherUsers])
    #expect(root.first?.children?.map(\.pid) == [40])
    // By session: line-b holds 12 (alpha) and 20 (beta); alpha shows 1 of 3.
    let lineB = ProcessTable.filtered(lines, by: "line-b")
    #expect(lineB.map(\.name) == ["beta", "alpha"])
    #expect(lineB.last?.children?.map(\.pid) == [12])
    #expect(lineB.last?.countText == "1 of 3 processes")
    // By group title: every member of the group stays.
    #expect(ProcessTable.filtered(lines, by: "alph").first?.children?.map(\.pid) == [10, 11, 12])
    // Nothing matches: an empty table; empty or blank text: the table as it was.
    #expect(ProcessTable.filtered(lines, by: "no-such-process").isEmpty)
    #expect(ProcessTable.filtered(lines, by: "") == lines)
    #expect(ProcessTable.filtered(lines, by: "  ") == lines)
    #expect(lines.first?.countText == "1 process")
}

@Test func searchReadsReadableNamesAndSubgroupMembers() throws {
    let lines = table(brokenFixture())
    // brokenFixture's catch-all sub-groups: a member matched by name keeps its sub-group line, counted.
    let catchAll = try #require(lines.first { $0.name == RepoGroups.notInARepo })
    let subgroup = try #require(catchAll.children?.first { $0.kind == .subgroup && ($0.children?.count ?? 0) > 1 })
    let member = try #require(subgroup.children?.first)
    let found = ProcessTable.filtered(lines, by: member.name)
    let group = try #require(found.first { $0.name == RepoGroups.notInARepo })
    let shownSubgroup = try #require(group.children?.first { $0.id == subgroup.id })
    #expect(shownSubgroup.children?.map(\.pid).contains(member.pid) == true)
    #expect(shownSubgroup.total == subgroup.count)
    // A readable name matches: the VM row (pid 50) named as the readers name a Lima VM.
    var named = brokenFixture()
    named.rows = named.rows.map { var row = $0; if row.pid == 50 { row.readableName = "Lima VM colima" }; return row }
    let withNames = table(named)
    let vm = try #require(withNames.flatMap { $0.children ?? [] }.first { $0.pid == 50 })
    #expect(ProcessTable.filtered(withNames, by: "COLIMA").flatMap { $0.children ?? [] }.map(\.id) == [vm.id])
}

// MARK: warned groups pinned (Phase 6 Step 6)

private func warning(_ subject: Warning.Subject, pids: [Int32], heaviest: Int32?) -> Warning {
    Warning(subject: subject, name: "\(subject)", since: 0, cpuPercent: 1,
            conditions: [.group(percent: 30, seconds: 600)], pids: pids, heaviest: heaviest)
}

private func pinned(_ f: (rows: [ProcessUsage], repo: [RepoGroup], session: [SessionGroup]),
                    _ grouping: ProcessTable.Grouping = .repo, sort: ProcessTable.Sort = .cliOrder,
                    warnings: [Warning], previous: [ProcessTable.Line] = []) -> [ProcessTable.Line] {
    ProcessTable.lines(rows: f.rows, repoGroups: f.repo, sessionGroups: f.session, grouping: grouping, sort: sort,
                       unattributedCpuPercent: 1.5, previous: previous, warnings: warnings)
}

@Test func warnedGroupPinsUnderEverySort() throws {
    let f = fixture()
    let columns: [ProcessTable.Column] = [.cpu, .memory, .disk, .network, .name, .pid, .user, .session]
    let sorts = [ProcessTable.Sort.cliOrder] + columns.flatMap { [ProcessTable.Sort(column: $0, ascending: true),
                                                                  ProcessTable.Sort(column: $0, ascending: false)] }
    for name in ["alpha", "beta"] {
        let warned = warning(.repo(name), pids: [], heaviest: nil)
        for sort in sorts {
            let lines = pinned(f, sort: sort, warnings: [warned])
            #expect(lines.first?.name == name, "\(name) under \(sort)")
            #expect(lines.first?.warnings == [0] && lines.first?.identifier == "group-0")
            #expect(lines.dropFirst().allSatisfy { $0.warnings.isEmpty })
            #expect(lines.last?.kind == .unattributed)
        }
        // A fixed sort holding an order that had it last still puts it first.
        let byName = ProcessTable.Sort(column: .name, ascending: false)
        var previous = table(f, sort: byName)
        if let i = previous.firstIndex(where: { $0.name == name }) { previous.append(previous.remove(at: i)) }
        let held = pinned(f, sort: byName, warnings: [warned], previous: previous)
        #expect(held.first?.name == name, "\(name) under a held order")
    }
}

@Test func warningInAnotherGroupingPinsTheGroupOfItsHeaviestProcess() throws {
    let f = fixture()
    // A command warning under By repo: pid 20 is beta's; a second warning on beta pins it once.
    let command = warning(.command("tool"), pids: [12, 20], heaviest: 20)
    let session = warning(.session("line-b"), pids: [12, 20], heaviest: 20)
    let lines = pinned(f, warnings: [command, session])
    #expect(lines.first?.name == "beta" && lines.first?.warnings == [0, 1])
    #expect(lines.filter { !$0.warnings.isEmpty }.count == 1)
    // In its own grouping the session warning pins its session group by name.
    let bySession = pinned(f, .session, warnings: [session])
    #expect(bySession.first?.name == "line-b" && bySession.first?.warnings == [0])
}

@Test func machineWarningPinsNothingAndSearchStillFilters() throws {
    let f = fixture()
    let machine = Warning(subject: .machine, name: "Machine", since: 0, cpuPercent: 0,
                          conditions: [.unattributed(percent: 20)])
    #expect(pinned(f, warnings: [machine]).allSatisfy { $0.warnings.isEmpty })
    #expect(pinned(f, warnings: [machine]).map(\.name) == table(f).map(\.name))
    let lines = pinned(f, warnings: [warning(.repo("beta"), pids: [], heaviest: nil)])
    #expect(ProcessTable.filtered(lines, by: "proc10").map(\.name) == ["alpha"])
}

// MARK: busy cells shaded by step (Phase 6 Step 6)

@Test func busyCellsShadeInFourSteps() throws {
    func line(cpu: Double = 0, exited: Double? = nil, disk: UInt64? = nil, network: UInt64? = nil,
              kind: ProcessTable.Kind = .process) -> ProcessTable.Line {
        var line = ProcessTable.Line(id: "x", identifier: "x", kind: kind, name: "x", cpuPercent: cpu)
        line.exitedChildrenCpuPercent = exited
        line.disk = disk.map { DiskUsage(rate: DiskRate(readBytesPerSecond: $0, writeBytesPerSecond: 0), bytes: .zero) }
        line.network = network.map { NetworkUsage(rate: NetworkRate(inBytesPerSecond: 0, outBytesPerSecond: $0), bytes: .zero) }
        return line
    }
    #expect([0, 4.9, 5, 14.9, 15, 30, 49.9, 50, 100].map { line(cpu: $0).shade(.cpu) } == [0, 0, 1, 1, 2, 3, 3, 4, 4])
    #expect(line(cpu: 3, exited: 2).shade(.cpu) == 1, "own + exited")
    let mb: UInt64 = 1_000_000
    #expect([0, mb - 1, mb, 10 * mb, 50 * mb, 200 * mb].map { line(disk: $0).shade(.disk) } == [0, 0, 1, 2, 3, 4])
    #expect([0, mb / 10, mb, 10 * mb, 50 * mb].map { line(network: $0).shade(.network) } == [0, 1, 2, 3, 4])
    #expect(line(cpu: 60, kind: .group).shade(.cpu) == 4)
    #expect(line(cpu: 60, kind: .unattributed).shade(.cpu) == 0)
    var gone = line(cpu: 60)
    gone.goneSince = 0
    #expect(gone.shade(.cpu) == 0)
    #expect(line(cpu: 60).shade(.memory) == 0, "only CPU, Disk and Network shade")
}
