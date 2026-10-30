// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the machine's and each process's network in and out rates, the VM row carrying its Lima network helper's,
// summed into groups, with no remainder line. Method: recorded `nettop` blocks and interface listings (this Mac's
// `en0`, tunnels, AirDrop links, a bridge) through the pure rules, and hand-built rows through the adoption, the
// groupings and the snapshot.

private let second: UInt64 = 1_000_000_000

@Suite struct NetworkActivityTests {

// MARK: nettop blocks

/// Two `nettop -P -x -L 1 -n -J bytes_in,bytes_out` reads one second apart, shaped as recorded 2026-10-21 and cut to
/// a few processes: `curl` opened its socket between them, `gone` closed its sockets.
private let first = """
,bytes_in,bytes_out,
kernel_task.0,5305592603,11028957961,
limactl.1186,13661311938,28745962,
com.apple.WebKit.Networking.1234,1000,2000,
gone.77,500,600,

"""
private let second1 = """
,bytes_in,bytes_out,
kernel_task.0,5305592603,11028957961,
limactl.1186,13661316034,28746474,
com.apple.WebKit.Networking.1234,1100,2000,
curl.555,700000,300,

"""

private func reads(apart nanoseconds: UInt64) throws -> (NettopRead, NettopRead) {
    (try NettopRead(text: first, uptimeNanoseconds: 10 * second),
     try NettopRead(text: second1, uptimeNanoseconds: 10 * second + nanoseconds))
}

@Test func parsesTwoReadsIntoPerPidDeltas() throws {
    let (before, after) = try reads(apart: second)
    let usage = NetworkActivity.perProcess(before: before, after: after)
    #expect(usage[1186] == NetworkUsage(rate: NetworkRate(inBytesPerSecond: 4_096, outBytesPerSecond: 512),
                                        bytes: NetworkBytes(received: 13_661_316_034, sent: 28_746_474)))
    #expect(usage[1234] == NetworkUsage(rate: NetworkRate(inBytesPerSecond: 100, outBytesPerSecond: 0),
                                        bytes: NetworkBytes(received: 1_100, sent: 2_000)))
    #expect(usage[0]?.rate == .zero)
    #expect(Set(usage.keys) == [0, 1186, 1234, 555])
}

@Test func rateIsOverTheReadsOwnStamps() throws {
    let (before, after) = try reads(apart: 2 * second)
    #expect(NetworkActivity.perProcess(before: before, after: after)[1186]?.rate
                == NetworkRate(inBytesPerSecond: 2_048, outBytesPerSecond: 256))
}

@Test func counterThatFellReadsZero() {
    let before = NettopRead(counters: [9: NetworkBytes(received: 900, sent: 900)], uptimeNanoseconds: second)
    let after = NettopRead(counters: [9: NetworkBytes(received: 100, sent: 1_000)], uptimeNanoseconds: 2 * second)
    #expect(NetworkActivity.perProcess(before: before, after: after)[9]?.rate
                == NetworkRate(inBytesPerSecond: 0, outBytesPerSecond: 100))
}

@Test func nameWithDotsStillYieldsTrailingPid() {
    let blocks = NettopParser.blocks(",bytes_in,bytes_out,\ncom.apple.WebKit.Networking.1234,10,20,\n")
    #expect(blocks == [[1234: NetworkBytes(received: 10, sent: 20)]])
}

@Test func pidInFirstReadOnlyIsDropped() throws {
    let (before, after) = try reads(apart: second)
    #expect(NetworkActivity.perProcess(before: before, after: after)[77] == nil)
}

@Test func pidListedOnlyInSecondReadRatesItsBytes() throws {
    let (before, after) = try reads(apart: second)
    let usage = NetworkActivity.perProcess(before: before, after: after)
    #expect(usage[555] == NetworkUsage(rate: NetworkRate(inBytesPerSecond: 700_000, outBytesPerSecond: 300),
                                       bytes: NetworkBytes(received: 700_000, sent: 300)))
}

@Test func kernelTaskRowKeepsPidZero() {
    #expect(NettopParser.blocks(",bytes_in,bytes_out,\nkernel_task.0,5,6,\n") == [[0: NetworkBytes(received: 5, sent: 6)]])
}

@Test func malformedRowsAreSkipped() {
    let text = ",bytes_in,bytes_out,\nfoo,1,2,\nbar.12,x,y,\nbaz.13,3,4,\n"
    #expect(NettopParser.blocks(text) == [[13: NetworkBytes(received: 3, sent: 4)]])
}

@Test func nameWithCommasSpacesAndNonASCIIKeepsItsBytesOnItsPid() {
    // The counters are the two right-hand columns; the name before them may hold commas (`Foo, Inc.ä`).
    let text = ",bytes_in,bytes_out,\nFoo, Inc.ä.1234,10,20,\nResilio Sync.1045,30,40,\na.5, b.6,50,60,\n"
    #expect(NettopParser.blocks(text) == [[1234: NetworkBytes(received: 10, sent: 20),
                                            1045: NetworkBytes(received: 30, sent: 40),
                                            6: NetworkBytes(received: 50, sent: 60)]])
}

@Test func pidListedTwiceInABlockSums() {
    let text = ",bytes_in,bytes_out,\nfoo.9,1,2,\nfoo-helper.9,10,20,\n"
    #expect(NettopParser.blocks(text) == [[9: NetworkBytes(received: 11, sent: 22)]])
}

@Test func readWithoutABlockIsAnError() {
    #expect(throws: NetworkActivityError.unreadable) { try NettopRead(text: "", uptimeNanoseconds: second) }
    #expect(throws: NetworkActivityError.unreadable) { try NettopRead(text: "kernel_task.0,5,6,\n", uptimeNanoseconds: second) }
}

// MARK: machine

@Test func onlyPhysicalInterfacesAreSummed() {
    func bytes(_ received: UInt64, _ sent: UInt64) -> NetworkBytes { NetworkBytes(received: received, sent: sent) }
    let interfaces: [(name: String, bytes: NetworkBytes)] = [
        ("en0", bytes(100, 200)), ("en7", bytes(1, 1)), ("lo0", bytes(5_000, 5_000)), ("utun3", bytes(7, 7)),
        ("awdl0", bytes(9, 9)), ("bridge0", bytes(11, 11)), ("anpi0", bytes(13, 13)), ("ap1", bytes(15, 15)),
        ("llw0", bytes(17, 17)), ("en", bytes(19, 19)), ("enx1", bytes(21, 21)),
    ]
    #expect(NetworkActivity.physical(interfaces) == bytes(101, 201))
}

@Test func interfaceGoneBetweenReadsDoesNotGoNegative() {
    let before = NetworkActivity.physical([("en0", NetworkBytes(received: 1_000, sent: 1_000)),
                                           ("en7", NetworkBytes(received: 500, sent: 500))])
    let after = NetworkActivity.physical([("en0", NetworkBytes(received: 1_200, sent: 1_600))])
    #expect(NetworkActivity.rate(before: before, after: after, nanoseconds: second)
                == NetworkRate(inBytesPerSecond: 0, outBytesPerSecond: 100))
}

@Test func zeroElapsedReadsZero() {
    #expect(NetworkActivity.rate(before: .zero, after: NetworkBytes(received: 10, sent: 10), nanoseconds: 0) == .zero)
}

@Test func counterWentBackwardsReadsZero() {
    let rate = NetworkActivity.rate(before: NetworkBytes(received: 5_000, sent: 5_000),
                                    after: NetworkBytes(received: 4_000, sent: 6_000), nanoseconds: 2 * second)
    #expect(rate == NetworkRate(inBytesPerSecond: 0, outBytesPerSecond: 500))
}

@Test func machineRateUsesTheReadsOwnStamps() {
    let usage = NetworkActivity.usage(before: MachineNetworkSample(bytes: .zero, uptimeNanoseconds: 10 * second),
                                      after: MachineNetworkSample(bytes: NetworkBytes(received: 3_000, sent: 1_500),
                                                                  uptimeNanoseconds: 13 * second))
    #expect(usage == NetworkUsage(rate: NetworkRate(inBytesPerSecond: 1_000, outBytesPerSecond: 500),
                                  bytes: NetworkBytes(received: 3_000, sent: 1_500)))
}

// MARK: VMs

private let usernetArgv = ["/opt/homebrew/bin/limactl", "usernet", "-p", "/fixtures/alice/.colima/_lima/_networks/user-v2/usernet_user-v2.pid",
                           "-e", "/fixtures/alice/.colima/_lima/_networks/user-v2/user-v2_ep.sock", "--subnet", "192.0.2.0/24"]

private func limaConfig(networks: [String]) -> String {
    "vmType: vz\nnetworks:\n" + networks.map { "    - lima: \($0)\n" }.joined() + "provision:\n    - mode: system\n"
}

private func vmRow(_ pid: Int32, _ name: String) -> ProcessUsage {
    var row = ProcessUsage(pid: pid, ppid: 1, uid: 501, user: "alice", path: "/System/Library/Frameworks/Virtualization.framework/"
                           + "Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/"
                           + "com.apple.Virtualization.VirtualMachine", name: "com.apple.Virtualization.VirtualMachine",
                           cpuPercent: 0, residentBytes: 1024, source: .libproc, network: .zero)
    row.vm = VMUsage(name: name, vcpus: 4, shareOfAllotted: 0)
    row.readableName = "VM: \(name) · 4 cores"
    return row
}

private func helperRow(_ network: NetworkUsage) -> ProcessUsage {
    ProcessUsage(pid: 1186, ppid: 1, uid: 501, user: "alice", path: "/opt/homebrew/bin/limactl", name: "limactl",
                 cpuPercent: 0, residentBytes: 1024, source: .libproc, network: network)
}

private let helperTraffic = NetworkUsage(rate: NetworkRate(inBytesPerSecond: 1_000, outBytesPerSecond: 50),
                                         bytes: NetworkBytes(received: 9_000, sent: 900))

@Test func vmRowAdoptsItsUsernetHelper() {
    let configs = ["/fixtures/alice/.colima/_lima/colima/lima.yaml": limaConfig(networks: ["user-v2"])]
    let rows = VirtualMachines.adoptLimaNetworks([vmRow(39377, "colima"), helperRow(helperTraffic)],
                                                 argv: { $0 == 1186 ? usernetArgv : nil }, limaConfig: { configs[$0] })
    #expect(rows.first { $0.pid == 39377 }?.network == helperTraffic)
    #expect(rows.first { $0.pid == 1186 }?.network == .zero)
    #expect(rows.first { $0.pid == 1186 }?.readableName == nil)
}

@Test func sharedHelperStaysOnItsOwnRow() {
    let configs = ["/fixtures/alice/.colima/_lima/colima/lima.yaml": limaConfig(networks: ["user-v2"]),
                   "/fixtures/alice/.colima/_lima/colima-ci/lima.yaml": limaConfig(networks: ["user-v2"])]
    let rows = VirtualMachines.adoptLimaNetworks([vmRow(70957, "colima-ci"), vmRow(39377, "colima"), helperRow(helperTraffic)],
                                                 argv: { $0 == 1186 ? usernetArgv : nil }, limaConfig: { configs[$0] })
    let helper = rows.first { $0.pid == 1186 }
    #expect(helper?.network == helperTraffic)
    #expect(helper?.readableName == "Lima network user-v2 · shared by colima, colima-ci")
    #expect(rows.filter { $0.vm != nil }.map(\.network) == [.zero, .zero])
}

@Test func vmOnAnotherNetworkLeavesTheHelperAlone() {
    let configs = ["/fixtures/alice/.colima/_lima/colima/lima.yaml": limaConfig(networks: ["shared"])]
    let rows = VirtualMachines.adoptLimaNetworks([vmRow(39377, "colima"), helperRow(helperTraffic)],
                                                 argv: { $0 == 1186 ? usernetArgv : nil }, limaConfig: { configs[$0] })
    #expect(rows.first { $0.pid == 1186 }?.network == helperTraffic)
    #expect(rows.first { $0.pid == 39377 }?.network == .zero)
}

@Test func limaNetworksLineScan() {
    #expect(VirtualMachines.limaNetworks(config: "networks:\n    - lima: user-v2\n") == ["user-v2"])
    #expect(VirtualMachines.limaNetworks(config: limaConfig(networks: ["a", "b"])) == ["a", "b"])
    #expect(VirtualMachines.limaNetworks(config: "vmType: vz\nprovision:\n    - mode: system\n") == [])
    // A `lima:` key outside the networks block is not a network.
    #expect(VirtualMachines.limaNetworks(config: "networks: []\nmounts:\n    - lima: nope\n") == [])
}

@Test func usernetArgvNamesItsNetworkAndLimaHome() {
    let found = VirtualMachines.usernet(argv: usernetArgv)
    #expect(found?.home == "/fixtures/alice/.colima/_lima")
    #expect(found?.network == "user-v2")
    #expect(VirtualMachines.usernet(argv: ["/opt/homebrew/bin/limactl", "hostagent", "--pidfile",
                                           "/fixtures/alice/.colima/_lima/colima/ha.pid", "colima"]) == nil)
}

// MARK: rows, groups, snapshot

private func row(_ pid: Int32, uid: UInt32 = 501, network: NetworkUsage?) -> ProcessUsage {
    ProcessUsage(pid: pid, ppid: 1, uid: uid, user: uid == 0 ? "root" : "alice", path: nil, name: "proc",
                 cpuPercent: 0, residentBytes: 1024, source: uid == 0 ? .ps : .libproc, network: network)
}

private func network(_ received: UInt64, _ sent: UInt64) -> NetworkUsage {
    NetworkUsage(rate: NetworkRate(inBytesPerSecond: received, outBytesPerSecond: sent),
                 bytes: NetworkBytes(received: received * 10, sent: sent * 10))
}

private let noSessions = SessionSources(registry: [], startSeconds: [:], environmentSessionIDs: [:], tmuxPanes: [:], tty: [:],
                                        ownUID: 501)

@Test func groupSumsByRepoAndSession() {
    let rows = [row(10, network: network(100, 200)), row(11, network: network(300, 400))]
    let repo = RepoInfo(name: "alpha", root: "/work/alpha", worktree: nil)
    let grouped = RepoGroups.assign(rows, workingDirectories: [10: "/work/alpha", 11: "/work/alpha"],
                                    repoOfDirectory: { _ in repo }, repoOfExecutable: { _ in nil })
    #expect(grouped.groups.map(\.network) == [network(400, 600)])
    let sessions = SessionGroups.assign(rows, sources: noSessions)
    #expect(sessions.groups.map(\.network) == [network(400, 600)])
}

@Test func rowNotListedByNettopIsZero() throws {
    let process = ProcessIdentity(pid: 42, ppid: 1, uid: 501, user: "alice", startMicroseconds: 1, comm: "proc", path: nil)
    let before = ProcessListSample(uptimeNanoseconds: second, processes: [process],
                                   taskInfo: [42: ProcessCounters(cpuNanoseconds: 0, residentBytes: 1)], ps: [:])
    let after = ProcessListSample(uptimeNanoseconds: 2 * second, processes: before.processes,
                                  taskInfo: [42: ProcessCounters(cpuNanoseconds: 0, residentBytes: 1)], ps: [:])
    let listed = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil, network: [7: network(1, 1)])
    #expect(listed.first?.network == .zero)
    let unlisted = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil)
    #expect(unlisted.first?.network == nil)
}

@Test func rowsExceedingMachineTotalAreNotClipped() throws {
    let rows = [row(10, network: network(3_000, 3_000)), row(11, network: network(2_000, 2_000))]
    let groups = RepoGroups.assign(rows, workingDirectories: [:], repoOfDirectory: { _ in nil }, repoOfExecutable: { _ in nil }).groups
    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1), load: CPULoad(perCPU: [0], total: 0),
                                intervalSeconds: 1, processes: rows, repoGroups: groups, network: network(1_000, 1_000))
    #expect(snapshot.processes?.map(\.network) == [network(3_000, 3_000), network(2_000, 2_000)])
    #expect(!snapshot.table().contains("Unattributed network"))
    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    #expect(!object.keys.contains { $0.lowercased().contains("unattributednetwork") })
    let processes = try #require(object["processes"] as? [[String: Any]])
    #expect(processes.compactMap { ($0["network"] as? [String: Any])?["inBytesPerSecond"] as? Int } == [3_000, 2_000])
}

@Test func tableShowsNetworkColumnAndHeaderLine() throws {
    let rows = [row(10, network: network(1_000_000, 234_567)), row(1, uid: 0, network: .zero)]
    let groups = RepoGroups.assign(rows, workingDirectories: [10: "/x"], repoOfDirectory: { _ in nil },
                                   repoOfExecutable: { _ in nil }).groups
    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1), load: CPULoad(perCPU: [0], total: 0),
                                intervalSeconds: 1, processes: rows, repoGroups: groups,
                                network: network(1_200_000, 340_000))
    let lines = snapshot.table().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines[1] == "Network  In 1.2 M/s  Out 340.0 K/s")
    #expect(lines.contains("    PID   PPID  USER     CPU   MEM        NET  NAME"))
    #expect(lines.contains("Not in a repo  0.0%  1.0K  1.2 M/s  1 process"))
    #expect(lines.contains("     10      1  alice   0.0%  1.0K    1.2 M/s  proc"))
    #expect(lines.contains("      1      1  root    0.0%  1.0K          0  proc"))
    #expect(!lines.contains { $0.hasPrefix("Unattributed network") })
    // With disk too: Disk's line, then Network's; NET after DISK.
    var both = rows
    both[0].disk = DiskUsage(rate: DiskRate(readBytesPerSecond: 5_000, writeBytesPerSecond: 0), bytes: .zero)
    let withDisk = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1), load: CPULoad(perCPU: [0], total: 0),
                                intervalSeconds: 1, processes: both,
                                repoGroups: RepoGroups.assign(both, workingDirectories: [10: "/x"], repoOfDirectory: { _ in nil },
                                                              repoOfExecutable: { _ in nil }).groups,
                                disk: .zero, network: network(1_200_000, 340_000))
    let diskLines = withDisk.table().split(separator: "\n").map(String.init)
    #expect(diskLines[1].hasPrefix("Disk  "))
    #expect(diskLines[2] == "Network  In 1.2 M/s  Out 340.0 K/s")
    #expect(diskLines.contains("    PID   PPID  USER     CPU   MEM       DISK        NET  NAME"))
    #expect(diskLines.contains("     10      1  alice   0.0%  1.0K    5.0 K/s    1.2 M/s  proc"))
    // No network read at all: no header line and no column.
    let plain = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1), load: CPULoad(perCPU: [0], total: 0),
                             intervalSeconds: 1, processes: [row(1, uid: 0, network: nil)])
    #expect(!plain.table().contains("Network"))
    #expect(!plain.table().contains("NET"))
}

@Test func jsonCarriesNetwork() throws {
    let rows = [row(10, network: network(100, 200)), row(11, network: nil)]
    let groups = RepoGroups.assign(rows, workingDirectories: [10: "/x"], repoOfDirectory: { _ in nil },
                                   repoOfExecutable: { _ in nil }).groups
    let sessions = SessionGroups.assign(rows, sources: noSessions).groups
    let before = MachineNetworkSample(bytes: .zero, uptimeNanoseconds: second, epochSeconds: 1_700_000_000.25)
    let after = MachineNetworkSample(bytes: NetworkBytes(received: 4, sent: 2), uptimeNanoseconds: 3 * second,
                                     epochSeconds: 1_700_000_002.5)
    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1), load: CPULoad(perCPU: [0], total: 0),
                                intervalSeconds: 2, processes: rows, repoGroups: groups, sessionGroups: sessions,
                                network: NetworkActivity.usage(before: before, after: after),
                                networkWindow: NetworkWindow(before: before, after: after))
    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    let keys: Set<String> = ["inBytesPerSecond", "outBytesPerSecond", "inBytes", "outBytes"]
    let top = try #require(object["network"] as? [String: Any])
    #expect(Set(top.keys) == keys.union(["windowStart", "windowEnd"]))
    #expect(top["windowStart"] as? Double == 1_700_000_000.25)
    #expect(top["windowEnd"] as? Double == 1_700_000_002.5)
    #expect(top["inBytesPerSecond"] as? Int == 2)
    #expect(top["outBytes"] as? Int == 2)
    let processes = try #require(object["processes"] as? [[String: Any]])
    #expect(Set(try #require(processes[0]["network"] as? [String: Any]).keys) == keys)
    #expect(processes[1]["network"] is NSNull)
    for name in ["repoGroups", "sessionGroups"] {
        let group = try #require((object[name] as? [[String: Any]])?.first?["network"] as? [String: Any])
        #expect(Set(group.keys) == keys)
    }
}

}
