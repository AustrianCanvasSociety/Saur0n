// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the window's graph row (Backlog window-graph-area-space) — used memory as Activity Monitor's "Memory Used"
// adds it up (active + wired + compressed pages), its minute of history as a share of physical memory, the five
// largest processes by memory for the Memory graph's strip, and which of the row's three graphs is open, at most one.
// Method: hand-built page counts, table lines built in code, presses in sequence.

private let gib: UInt64 = 1 << 30

@Test func usedMemoryIsActiveWiredAndCompressedPages() {
    // 16 KB pages, as Apple silicon has them.
    let usage = MemoryUsage(activePages: 2_000_000, wiredPages: 500_000, compressedPages: 250_000, pageSize: 16_384,
                            physicalBytes: 128 * gib)
    #expect(usage.usedBytes == 2_750_000 * 16_384)
    #expect(abs(usage.percent - 100 * Double(2_750_000 * 16_384) / Double(128 * gib)) < 1e-9)
}

@Test func memoryTextReadsUsedOfPhysicalInBinaryGigabytes() {
    // 57.2 G used of 128 G: as the Memory column, in binary units (Activity Monitor's 128 GB on a 128 GiB Mac).
    let used = UInt64(57.2 * Double(gib) / 16_384)
    let usage = MemoryUsage(activePages: used, wiredPages: 0, compressedPages: 0, pageSize: 16_384,
                            physicalBytes: 128 * gib)
    #expect(usage.text == "Memory 57.2 G of 128 G")
    let small = MemoryUsage(activePages: 0, wiredPages: 0, compressedPages: 0, pageSize: 16_384, physicalBytes: 8 * gib)
    #expect(small.text == "Memory 0.0 G of 8 G")
}

@Test func usedMemoryNeverReadsAbovePhysical() {
    let usage = MemoryUsage(activePages: 10, wiredPages: 0, compressedPages: 0, pageSize: 1, physicalBytes: 5)
    #expect(usage.percent == 100)
    #expect(MemoryUsage(activePages: 1, wiredPages: 0, compressedPages: 0, pageSize: 1, physicalBytes: 0).percent == 0)
}

@Test func thisMacsMemoryReadsSomeUsedOfItsPhysical() throws {
    let usage = try SystemReaders.memoryUsage()
    #expect(usage.physicalBytes == ProcessInfo.processInfo.physicalMemory)
    #expect(usage.usedBytes > 0 && usage.usedBytes <= usage.physicalBytes)
}

@Test func memoryHistoryKeepsAMinuteOfShares() {
    var history = MemoryHistory()
    #expect(history.percent.isEmpty && history.latest == nil)
    for pages in 1...61 {
        history.append(MemoryUsage(activePages: UInt64(pages), wiredPages: 0, compressedPages: 0, pageSize: 1,
                                   physicalBytes: 100))
    }
    #expect(history.percent.count == CPUHistory.capacity)
    #expect(history.percent.first == 2 && history.percent.last == 61)
    #expect(history.latest?.usedBytes == 61)
}

@Test func largestByMemoryAreTheFiveBiggestUnderTheirGroups() {
    func usage(_ pid: Int32, _ bytes: UInt64) -> ProcessUsage {
        var row = ProcessUsage(pid: pid, ppid: 1, uid: 501, user: "alice", path: nil, name: "p\(pid)", cpuPercent: 0,
                               residentBytes: bytes, source: .libproc)
        row.startMicroseconds = 1_000
        return row
    }
    // Seven processes in two groups, one with no memory read; two tie at 300 (pid ascending).
    let rows = [usage(1, 100), usage(2, 700), usage(3, 300), usage(4, 0), usage(5, 300), usage(6, 900), usage(7, 50)]
    let groups = [
        RepoGroup(name: "alpha", root: "/work/alpha", cpuPercent: 0, exitedChildrenCpuPercent: 0, residentBytes: 1_100,
                  pids: [1, 2, 3, 4]),
        RepoGroup(name: "beta", root: "/work/beta", cpuPercent: 0, exitedChildrenCpuPercent: 0, residentBytes: 1_250,
                  pids: [5, 6, 7]),
    ]
    let lines = ProcessTable.lines(rows: rows, repoGroups: groups, sessionGroups: [], grouping: .repo,
                                   unattributedCpuPercent: 0)
    let top = TopMovers.largest(lines, by: \.residentBytes)
    #expect(top.map(\.id.pid) == [6, 2, 3, 5, 1])
    #expect(top.map(\.group) == ["beta", "alpha", "alpha", "beta", "alpha"])
    #expect(top.first?.bytes == 900 && top.first?.name == "p6")
    #expect(TopMovers.largest([], by: \.residentBytes).isEmpty)
}

@Test func atMostOneGraphIsOpenAndPressingTheOpenOneClosesIt() {
    var open = OpenGraph.none
    open.press(.cpu)
    #expect(open == .cpu)
    open.press(.memory)
    #expect(open == .memory)
    open.press(.memory)
    #expect(open == .none)
    open.press(.diskNetwork)
    #expect(open == .diskNetwork)
}

@Test func theOpenGraphIsSavedByNameAndAnythingElseReadsNone() {
    #expect(OpenGraph.allCases.map(\.rawValue) == ["none", "cpu", "memory", "disk-network"])
    #expect(OpenGraph(saved: "disk-network") == .diskNetwork)
    #expect(OpenGraph(saved: "bogus") == OpenGraph.none)
    #expect(OpenGraph(saved: nil) == OpenGraph.none)
}
