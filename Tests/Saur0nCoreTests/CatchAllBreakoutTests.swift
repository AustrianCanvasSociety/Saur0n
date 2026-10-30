// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the catch-alls break out what is large (Phase 5 Step 4) — processes under one app bundle fold under one
// sub-group line, a sub-group or a bare process that holds 1% of the machine's memory, CPU, disk or network stands
// on its own line, everything else folds under one "N other processes" line — and VMs get a group of their own in
// both views. Method: a catch-all shaped like this machine's (research 2026-10-20 § Q3: Firefox's 36 processes,
// Discord's 7, a Java process, a WebKit page, bare daemons, two VMs) built in code with documentation values.

private let gib: UInt64 = 1 << 30
private let mib: UInt64 = 1 << 20
private let firefox = "/Applications/Firefox.app/Contents/MacOS/"
private let discord = "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper"
private let vmPath = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
    + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

private func row(_ pid: Int32, _ path: String?, cpu: Double = 0, rss: UInt64, uid: UInt32 = 501, parent: Int32 = 1,
                 disk: UInt64? = nil, network: UInt64? = nil, vm: String? = nil) -> ProcessUsage {
    var usage = ProcessUsage(pid: pid, ppid: parent, uid: uid, user: uid == 0 ? "root" : "user", path: path,
                             name: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "proc\(pid)",
                             cpuPercent: cpu, residentBytes: rss, source: .libproc, exitedChildrenCpuPercent: 0)
    usage.disk = DiskUsage(rate: DiskRate(readBytesPerSecond: disk ?? 0, writeBytesPerSecond: 0), bytes: .zero)
    usage.network = NetworkUsage(rate: NetworkRate(inBytesPerSecond: network ?? 0, outBytesPerSecond: 0), bytes: .zero)
    usage.vm = vm.map { VMUsage(name: $0, vcpus: 4, shareOfAllotted: 0) }
    return usage
}

/// The user's own catch-all as research § Q3 found it: Firefox 36 rows / 10 GiB (pid 1000 the parent, 1.25 GiB; 35
/// helpers at 256 MiB), Discord 7 rows / 1.2 GiB at 0.3% CPU, a 1.5 GiB Java process, a 1.5 GiB WebKit page, 40 daemons
/// under 50 MiB, two VMs; and 20 root daemons, which have no readable working folder.
private func machine() -> [ProcessUsage] {
    var rows = [row(1000, firefox + "firefox", cpu: 0.8, rss: 5 * gib / 4)]
    rows += (1001...1035).map { row($0, firefox + "plugin-container.app/Contents/MacOS/plugin-container", cpu: 0.01,
                                    rss: 256 * mib, parent: 1000) }
    rows += (1100...1106).map { row($0, discord, cpu: 0.3 / 7, rss: 1_288_490_188 / 7) }
    rows.append(row(1200, "/Library/Java/JavaVirtualMachines/jdk.example/Contents/Home/bin/java", cpu: 0.1, rss: 3 * gib / 2))
    rows.append(row(1300, "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/"
                        + "com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", cpu: 0.2, rss: 3 * gib / 2))
    rows += (1400...1439).map { row($0, "/usr/libexec/daemon\($0)", cpu: 0.01, rss: 40 * mib) }
    rows.append(row(1500, vmPath, cpu: 6, rss: 16 * gib, vm: "colima"))
    rows.append(row(1501, vmPath, cpu: 2, rss: 15 * gib, vm: "colima-ci"))
    rows += (1600...1619).map { row($0, "/usr/libexec/rootd\($0)", cpu: 0.02, rss: 30 * mib, uid: 0) }
    return rows
}

private func byRepo(_ rows: [ProcessUsage]) -> (rows: [ProcessUsage], groups: [RepoGroup]) {
    // A row given a repo works in its root; the user's other rows in `/`, which is in no repo.
    let dirs = Dictionary(uniqueKeysWithValues: rows.filter { $0.uid == 501 }.map { ($0.pid, $0.repo?.root ?? "/") })
    return RepoGroups.assign(rows, workingDirectories: dirs,
                             repoOfDirectory: { $0 == "/work" ? RepoInfo(name: "work", root: "/work", worktree: nil) : nil },
                             repoOfExecutable: { _ in nil })
}

private func bySession(_ rows: [ProcessUsage]) -> (rows: [ProcessUsage], groups: [SessionGroup]) {
    SessionGroups.assign(rows, sources: SessionSources(registry: [], startSeconds: [:], environmentSessionIDs: [:],
                                                       tmuxPanes: [:], tty: [:], ownUID: 501))
}

private func thresholds(memory: UInt64 = 128 * gib, disk: UInt64? = nil, network: UInt64? = nil) -> CatchAllBreakout.Thresholds {
    CatchAllBreakout.Thresholds(physicalMemoryBytes: memory, machineDiskBytesPerSecond: disk, machineNetworkBytesPerSecond: network)
}

/// The machine's rows through both assigns and the break-out.
private func broken(_ rows: [ProcessUsage] = machine(), _ limits: CatchAllBreakout.Thresholds = thresholds())
    -> (rows: [ProcessUsage], repo: [RepoGroup], session: [SessionGroup]) {
    let repo = byRepo(rows)
    let session = bySession(repo.rows)
    let out = CatchAllBreakout.apply(rows: session.rows, repoGroups: repo.groups, sessionGroups: session.groups,
                                     thresholds: limits)
    return (out.rows, out.repoGroups, out.sessionGroups)
}

private func group(_ groups: [RepoGroup], _ name: String) throws -> RepoGroup {
    try #require(groups.first { $0.name == name })
}

// MARK: the app a process belongs to

@Test func outermostAppBundleNamesTheApp() {
    #expect(CatchAllBreakout.appName(ofPath: "/Applications/Outer.app/Contents/Frameworks/Middle.app/Contents/Helpers/"
                                     + "Inner.app/Contents/MacOS/inner") == "Outer")
    #expect(CatchAllBreakout.appName(ofPath: firefox + "plugin-container.app/Contents/MacOS/plugin-container") == "Firefox")
    #expect(CatchAllBreakout.appName(ofPath: "/usr/libexec/trustd") == nil)
    #expect(CatchAllBreakout.appName(ofPath: "/bin/zsh") == nil)
    #expect(CatchAllBreakout.appName(ofPath: nil) == nil)
    #expect(CatchAllBreakout.appName(ofPath: "/opt/tools/notes.application/bin/run") == nil)
}

// MARK: the lift

@Test func firefoxFoldsIntoOneSubgroupAndStandsOutByMemory() throws {
    let out = broken()
    let catchAll = try group(out.repo, RepoGroups.notInARepo)
    let first = try #require(catchAll.subgroups.first)
    #expect(first.name == "Firefox")
    #expect(first.kind == .app)
    #expect(first.pids.count == 36)
    #expect(first.residentBytes == 10 * gib)
    #expect(catchAll.pids.first == 1000)    // the lifted entries come first; Firefox has the most CPU
    #expect(out.rows.first { $0.pid == 1001 }?.app == "Firefox")
    #expect(out.rows.first { $0.pid == 1400 }?.app == nil)
}

@Test func aBareProcessStandsOutByMemoryOnOneMachineAndFoldsOnAnother() throws {
    let small = try group(broken().repo, RepoGroups.notInARepo)
    let other = try #require(small.subgroups.last)
    #expect(other.kind == .other)
    #expect(!other.pids.contains(1200))
    #expect(Array(small.pids.prefix(38)).contains(1200))

    let large = try group(broken(machine(), thresholds(memory: 256 * gib)).repo, RepoGroups.notInARepo)
    #expect(try #require(large.subgroups.last).pids.contains(1200))
}

@Test func aSubgroupBelowEveryThresholdFoldsUnderOther() throws {
    let catchAll = try group(broken().repo, RepoGroups.notInARepo)
    #expect(!catchAll.subgroups.contains { $0.name == "Discord" })
    let other = try #require(catchAll.subgroups.last)
    #expect(Set(1100...1106).isSubset(of: Set(other.pids)))
    #expect(Set(1400...1439).isSubset(of: Set(other.pids)))
    #expect(other.name == "47 other processes")
}

@Test func diskAndNetworkRatesLiftOncePresent() throws {
    var rows = machine()
    rows[rows.firstIndex { $0.pid == 1400 }!] = row(1400, "/usr/libexec/daemon1400", rss: 40 * mib, disk: 20_000_000)
    rows[rows.firstIndex { $0.pid == 1401 }!] = row(1401, "/usr/libexec/daemon1401", rss: 40 * mib, network: 20_000_000)
    func lifted(_ limits: CatchAllBreakout.Thresholds) throws -> Set<Int32> {
        let catchAll = try group(broken(rows, limits).repo, RepoGroups.notInARepo)
        return Set([1400, 1401]).subtracting(try #require(catchAll.subgroups.last).pids)
    }
    #expect(try lifted(thresholds(disk: 1_000_000_000, network: 1_000_000_000)) == [1400, 1401])
    #expect(try lifted(thresholds()) == [])
    #expect(try lifted(thresholds(disk: 3_000_000_000)) == [])    // 20 MB/s is under 1% of 3 GB/s
}

@Test func zeroMachineRateLiftsNothingByThatColumn() {
    #expect(!CatchAllBreakout.lifted(cpuPercent: 0, residentBytes: 0, diskBytesPerSecond: 1, networkBytesPerSecond: 1,
                                     thresholds: thresholds(disk: 0, network: 0)))
    #expect(!CatchAllBreakout.lifted(cpuPercent: 0.94, residentBytes: 0, diskBytesPerSecond: 0, networkBytesPerSecond: 0,
                                     thresholds: thresholds()))
    #expect(CatchAllBreakout.lifted(cpuPercent: 0.95, residentBytes: 0, diskBytesPerSecond: 0, networkBytesPerSecond: 0,
                                    thresholds: thresholds()))    // shows as 1.0%
}

// MARK: the other line and the group's order

@Test func theOtherLineCountsAndSumsItsRows() throws {
    var rows = machine()
    rows[rows.firstIndex { $0.pid == 1400 }!] = row(1400, "/usr/libexec/daemon1400", cpu: 0.01, rss: 40 * mib,
                                                    disk: 3_000, network: 500)
    let out = broken(rows)
    let catchAll = try group(out.repo, RepoGroups.notInARepo)
    let other = try #require(catchAll.subgroups.last)
    let members = rows.filter { other.pids.contains($0.pid) }
    #expect(members.count == 47)
    #expect(other.residentBytes == members.map(\.residentBytes).reduce(0, +))
    #expect(abs(other.cpuPercent - members.map(\.cpuPercent).reduce(0, +)) < 1e-9)
    #expect(other.disk.readBytesPerSecond == 3_000)
    #expect(other.network.inBytesPerSecond == 500)

    let lifted = catchAll.subgroups.filter { $0.kind == .app }
    let bare = out.rows.filter { catchAll.pids.contains($0.pid) && $0.app == nil && !other.pids.contains($0.pid) }
    #expect(lifted.map(\.residentBytes).reduce(0, +) + bare.map(\.residentBytes).reduce(0, +) + other.residentBytes
            == catchAll.residentBytes)
    #expect(Set(catchAll.pids).count == catchAll.pids.count)
}

@Test func catchAllPidsListLiftedEntriesFirstThenOther() throws {
    let catchAll = try group(broken().repo, RepoGroups.notInARepo)
    let other = try #require(catchAll.subgroups.last)
    // Firefox (0.8% + 35 × 0.01%), the WebKit page (0.2%), Java (0.1%); then the folded rest, in the group's order.
    #expect(Array(catchAll.pids.prefix(38)) == [1000] + Array(1001...1035) + [1300, 1200])
    #expect(Array(catchAll.pids.suffix(other.pids.count)) == other.pids)
    #expect(catchAll.pids.count == 85)
}

@Test func everyRowLiftedLeavesNoOtherLine() throws {
    let rows = [row(1, "/usr/libexec/big", cpu: 2, rss: 10, parent: 0), row(2, firefox + "firefox", cpu: 0, rss: 2 * gib)]
    let catchAll = try group(broken(rows).repo, RepoGroups.notInARepo)
    #expect(catchAll.subgroups.map(\.kind) == [.app])
    #expect(catchAll.pids == [1, 2])
}

@Test func oneRowCatchAllStillAppliesTheRule() throws {
    let quiet = try group(broken([row(1, "/usr/libexec/small", rss: 10)]).repo, RepoGroups.notInARepo)
    #expect(quiet.subgroups.map(\.name) == ["1 other process"])
    let app = try group(broken([row(1, firefox + "firefox", cpu: 3, rss: 10)]).repo, RepoGroups.notInARepo)
    #expect(app.subgroups.map(\.name) == ["Firefox"])
}

@Test func onlyCatchAllsCarrySubgroupsAndTheSessionViewToo() throws {
    var rows = machine()
    var inRepo = row(2000, firefox + "firefox", cpu: 5, rss: 4 * gib)
    inRepo.repo = RepoInfo(name: "work", root: "/work", worktree: nil)
    rows.append(inRepo)
    let out = broken(rows)
    let plain = out.repo.filter { $0.root != nil || $0.name == RepoGroups.vms }
    #expect(plain.count == 2)
    #expect(plain.allSatisfy { $0.subgroups.isEmpty })
    let noSession = try #require(out.session.first { $0.name == SessionGroups.noSession })
    #expect(noSession.subgroups.first?.name == "Firefox")
    let system = try #require(out.session.first { $0.name == SessionGroups.systemAndOtherUsers })
    #expect(system.subgroups.map(\.name) == ["20 other processes"])
}

// MARK: copies of one command (Phase 6 Step 3)

/// `count` app-less rows named `name` from pid `first`, each at `cpu`.
private func copies(_ name: String, _ count: Int32, from first: Int32, cpu: Double, rss: UInt64 = 2 * mib) -> [ProcessUsage] {
    (first..<first + count).map { row($0, "/bin/" + name, cpu: cpu, rss: rss) }
}

@Test func thirtyCopiesAtHalfAPercentLiftAsOneSubgroup() throws {
    let catchAll = try group(broken(machine() + copies("sh", 30, from: 3000, cpu: 0.5)).repo, RepoGroups.notInARepo)
    let sh = try #require(catchAll.subgroups.first)
    #expect(sh.name == "sh")
    #expect(sh.kind == .command)
    #expect(sh.pids == Array(3000..<3030))
    #expect(abs(sh.cpuPercent - 15) < 1e-9)
    #expect(Array(catchAll.pids.prefix(30)) == sh.pids)    // 15% comes before Firefox's 1.15%
    #expect(try #require(catchAll.subgroups.last).pids.allSatisfy { !sh.pids.contains($0) })
    let entries = CatchAllBreakout.entries(pids: catchAll.pids, subgroups: catchAll.subgroups)
    #expect(entries.filter { $0 == .subgroup(sh) }.count == 1)
    #expect(entries.first == .subgroup(sh))
}

/// Phase 6 Step 4: copies go by command key, so a script's `bash` copies and a test suite's `bash -c` children stand
/// on two lines, the script's named after it.
@Test func copiesOfOneShellSplitByTheScriptTheyRun() throws {
    let inline = copies("bash", 30, from: 3000, cpu: 0.5), scripted = copies("bash", 30, from: 4000, cpu: 0.5)
    var arguments: [Int32: ProcessArguments] = [:]
    for row in inline { arguments[row.pid] = ProcessArguments(argv: ["/bin/bash", "-c", "exit 0"], environment: [:]) }
    for row in scripted { arguments[row.pid] = ProcessArguments(argv: ["/bin/bash", "/tmp/example/runaway.sh"], environment: [:]) }
    let keyed = CommandGroups.assign(machine() + inline + scripted, arguments: arguments).rows
    let catchAll = try group(broken(keyed).repo, RepoGroups.notInARepo)
    let bash = try #require(catchAll.subgroups.first { $0.name == "bash" })
    let script = try #require(catchAll.subgroups.first { $0.name == "runaway.sh" })
    #expect(bash.kind == .command && script.kind == .command)
    #expect(bash.pids == inline.map(\.pid))
    #expect(script.pids == scripted.map(\.pid))
}

@Test func copiesCountTheirExitedChildrenTowardTheLift() throws {
    var rows = copies("worker", 3, from: 3000, cpu: 0)
    rows[0].exitedChildrenCpuPercent = 2
    let catchAll = try group(broken(machine() + rows).repo, RepoGroups.notInARepo)
    #expect(catchAll.subgroups.contains { $0.name == "worker" && $0.kind == .command && $0.totalCpuPercent == 2 })
}

@Test func oneCopyStaysABareProcess() throws {
    let catchAll = try group(broken(machine() + copies("lone", 1, from: 3000, cpu: 2)).repo, RepoGroups.notInARepo)
    #expect(!catchAll.subgroups.contains { $0.name == "lone" })
    #expect(catchAll.pids.first == 3000)
    #expect(CatchAllBreakout.entries(pids: catchAll.pids, subgroups: catchAll.subgroups).first == .process(3000))
}

@Test func copiesBelowTheLiftFoldIntoOther() throws {
    let catchAll = try group(broken(machine() + copies("idle", 30, from: 3000, cpu: 0.01)).repo, RepoGroups.notInARepo)
    #expect(!catchAll.subgroups.contains { $0.kind == .command })
    #expect(Set(3000..<3030).isSubset(of: Set(try #require(catchAll.subgroups.last).pids)))
}

@Test func appHelpersSharingANameStayInTheirApp() throws {
    // Firefox's 35 helpers are all `plugin-container`: one Firefox sub-group, no `plugin-container` command.
    let catchAll = try group(broken().repo, RepoGroups.notInARepo)
    #expect(!catchAll.subgroups.contains { $0.name == "plugin-container" })
    #expect(catchAll.subgroups.first { $0.name == "Firefox" }?.pids.count == 36)
}

@Test func anAppAndACommandOfOneNameKeepApartLines() throws {
    let rows = [row(1, firefox + "firefox", cpu: 3, rss: 10)] + copies("Firefox", 2, from: 3000, cpu: 2)
    let out = broken(rows)
    let catchAll = try group(out.repo, RepoGroups.notInARepo)
    #expect(catchAll.subgroups.map(\.kind) == [.command, .app])
    let lines = ProcessTable.lines(rows: out.rows, repoGroups: out.repo, sessionGroups: out.session, grouping: .repo,
                                   unattributedCpuPercent: nil)
    let ids = try #require(lines.first { $0.name == RepoGroups.notInARepo }).children?.map(\.id) ?? []
    #expect(ids == ["subgroup:catch-all:\(RepoGroups.notInARepo):command:Firefox",
                    "subgroup:catch-all:\(RepoGroups.notInARepo):app:Firefox"])
}

@Test func copiesSubgroupEncodesKindCommand() throws {
    let catchAll = try group(broken(copies("sh", 2, from: 3000, cpu: 1)).repo, RepoGroups.notInARepo)
    let json = try #require(String(data: JSONEncoder().encode(catchAll.subgroups[0]), encoding: .utf8))
    #expect(json.contains("\"kind\":\"command\""))
}

// MARK: the VMs group

@Test func vmsFormTheirOwnGroupInBothViews() throws {
    let repo = byRepo(machine())
    #expect(repo.groups.map(\.name) == [RepoGroups.vms, RepoGroups.notInARepo, RepoGroups.systemAndOtherUsers])
    let vms = try group(repo.groups, RepoGroups.vms)
    #expect(vms.pids == [1500, 1501])
    #expect(vms.root == nil)
    let session = bySession(repo.rows)
    #expect(session.groups.map(\.name) == [SessionGroups.vms, SessionGroups.noSession, SessionGroups.systemAndOtherUsers])
    #expect(session.groups.first?.kind == nil)

    // A VM tied to a repo stays in it; no VM, no group.
    let dirs: [Int32: String] = [1500: "/work", 1501: "/"]
    let tied = RepoGroups.assign(machine().filter { $0.vm != nil }, workingDirectories: dirs,
                                 repoOfDirectory: { $0 == "/work" ? RepoInfo(name: "work", root: "/work", worktree: nil) : nil },
                                 repoOfExecutable: { _ in nil })
    #expect(tied.groups.map(\.name) == ["work", RepoGroups.vms])
    #expect(!byRepo(machine().filter { $0.vm == nil }).groups.contains { $0.name == RepoGroups.vms })
}
