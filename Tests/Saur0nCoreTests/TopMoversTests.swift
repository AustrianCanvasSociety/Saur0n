// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the strips under the window's Disk and Network graphs — the five processes that moved the most bytes in
// the last minute, by readable name and group, kept per process across refreshes (a reused pid is a new mover),
// with an exited process's bytes kept until they age out. Method: hand-built tick sequences.

private func id(_ pid: Int32, start: UInt64 = 1_000) -> ProcessTable.RowID {
    ProcessTable.RowID(pid: pid, startMicroseconds: start)
}

private func mover(_ pid: Int32, _ bytes: UInt64, start: UInt64 = 1_000, name: String? = nil, readable: String? = nil,
                   group: String = "alpha") -> TopMovers.Mover {
    TopMovers.Mover(id: id(pid, start: start), name: name ?? "proc\(pid)", readableName: readable, group: group, bytes: bytes)
}

@Test func minuteSumDropsTicksOlderThanSixty() {
    var movers = TopMovers()
    for _ in 1...61 { movers.tick([mover(10, 10)]) }
    #expect(TopMovers.window == 60)
    #expect(movers.top().map(\.bytes) == [600])
}

@Test func oneSecondBurstOutranksASteadyMoverUntilItAgesOut() {
    var movers = TopMovers()
    movers.tick([mover(1, 1_000), mover(2, 10)])
    for tick in 2...61 {
        movers.tick([mover(2, 10)])
        let top = movers.top()
        if tick <= 60 {
            #expect(top.first?.id.pid == 1, "tick \(tick)")
        } else {
            #expect(top.map(\.id.pid) == [2], "tick \(tick): the burst aged out")
            #expect(top.first?.bytes == 600)
        }
    }
}

@Test func exitedProcessKeepsItsBytesUntilTheyAgeOut() {
    var movers = TopMovers()
    for tick in 1...5 { movers.tick([mover(7, 100, name: tick == 5 ? "renamed" : "proc7", group: "g\(tick)")]) }
    for tick in 6...65 {
        movers.tick([])
        let top = movers.top()
        if tick < 65 {
            #expect(top.count == 1, "tick \(tick)")
            #expect(top.first?.name == "renamed" && top.first?.group == "g5")
        } else {
            #expect(top.isEmpty, "tick 65: the minute holds ticks 6–65 only")
        }
    }
    let late = movers.top()
    #expect(late.isEmpty)
}

@Test func tiesAndFewerThanFive() {
    var movers = TopMovers()
    movers.tick([mover(30, 50), mover(20, 50), mover(10, 80)])
    #expect(movers.top().map(\.id.pid) == [10, 20, 30])     // tie: pid ascending
    var many = TopMovers()
    many.tick((1...8).map { mover(Int32($0), UInt64($0) * 10) })
    #expect(TopMovers.count == 5)
    #expect(many.top().map(\.id.pid) == [8, 7, 6, 5, 4])
    var idle = TopMovers()
    idle.tick([mover(1, 0), mover(2, 0)])
    #expect(idle.top().isEmpty)
}

@Test func stripNamesTheReadableNameAndGroup() {
    var movers = TopMovers()
    movers.tick([mover(5, 900, name: "node", readable: "vitest · alpha", group: "alpha"),
                 mover(6, 800, name: "curl", group: "Not in a repo")])
    let top = movers.top()
    #expect(top[0] == mover(5, 900, name: "node", readable: "vitest · alpha", group: "alpha"))
    #expect(top[1].readableName == nil && top[1].name == "curl" && top[1].group == "Not in a repo")
    // pid 5 exits and is reused by a new process: two movers, not one summed.
    movers.tick([mover(5, 700, start: 9_000, name: "dd", group: "beta")])
    let after = movers.top()
    #expect(after.map(\.bytes) == [900, 800, 700])
    #expect(after[2].id == id(5, start: 9_000) && after[2].name == "dd")
}

@Test func zeroByteRowsNeverEnterTheStrip() {
    var movers = TopMovers()
    for _ in 1...10 { movers.tick([mover(1, 0), mover(2, 5)]) }
    #expect(movers.top().map(\.id.pid) == [2])
}

@Test func tableLinesFeedTheStripUnderTheirGroupTitles() {
    var usage = ProcessUsage(pid: 9, ppid: 1, uid: 501, user: "alice", path: nil, name: "dd", cpuPercent: 1,
                             residentBytes: 1, source: .libproc)
    usage.startMicroseconds = 4_000
    usage.disk = DiskUsage(rate: DiskRate(readBytesPerSecond: 0, writeBytesPerSecond: 300), bytes: .zero)
    let group = RepoGroup(name: "alpha", root: "/work/alpha", cpuPercent: 1, exitedChildrenCpuPercent: 0,
                          residentBytes: 1, pids: [9])
    let lines = ProcessTable.lines(rows: [usage], repoGroups: [group], sessionGroups: [], grouping: .repo,
                                   unattributedCpuPercent: 0, unattributedDisk: DiskRate(readBytesPerSecond: 5, writeBytesPerSecond: 0))
    let rows = TopMovers.rows(lines, rate: \.diskBytesPerSecond)
    #expect(rows == [mover(9, 300, start: 4_000, name: "dd", group: "alpha")])    // group and unattributed lines are not movers
    // A tick 1.2 s long holds 1.2 s of the rate.
    #expect(TopMovers.rows(lines, seconds: 1.2, rate: \.diskBytesPerSecond).map(\.bytes) == [360])
}

@Test func tickWithNoRowsAgesTheMinuteOut() {
    var movers = TopMovers()
    movers.tick([mover(1, 100)])
    for _ in 1...59 { movers.tick([]) }
    #expect(movers.top().map(\.bytes) == [100])
    movers.tick([])
    #expect(movers.top().isEmpty)
}
