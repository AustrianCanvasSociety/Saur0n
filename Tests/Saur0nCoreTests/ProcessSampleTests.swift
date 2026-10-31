// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: every process's CPU as a share of the whole machine over one window, its name, and the
// table and JSON rows. Method: two hand-built process-list samples (task info, ps rows, top's
// kernel_task) through `ProcessSample.usage`, plus the ps / top / KERN_PROCARGS2 parsers fed
// recorded and malformed output.

private let second: UInt64 = 1_000_000_000

private func identity(_ pid: Int32, parent: Int32 = 1, start: UInt64 = 1_000, user: String = "user",
                      comm: String = "proc", path: String? = nil) -> ProcessIdentity {
    ProcessIdentity(pid: pid, ppid: parent, uid: 501, user: user, startMicroseconds: start, comm: comm, path: path)
}

private func counters(_ cpu: UInt64, rss: UInt64 = 4096) -> ProcessCounters {
    ProcessCounters(cpuNanoseconds: cpu, residentBytes: rss)
}

private func sample(at uptime: UInt64, _ processes: [ProcessIdentity],
                    taskInfo: [Int32: ProcessCounters] = [:], ps: [Int32: PSRow] = [:],
                    children: [Int32: UInt64] = [:], rusage: [Int32: UInt64] = [:]) -> ProcessListSample {
    ProcessListSample(uptimeNanoseconds: uptime, processes: processes, taskInfo: taskInfo, ps: ps, childrenCPU: children,
                      rusageCPU: rusage)
}

// MARK: share math and lifecycle

@Test func elapsedNanosecondsFloorsNonAdvancingClocks() {
    #expect(ProcessSample.elapsedNanoseconds(before: 10, after: 25) == 15)
    #expect(ProcessSample.elapsedNanoseconds(before: 0, after: 0) == 0)
    #expect(ProcessSample.elapsedNanoseconds(before: 10, after: 10) == 0)
    #expect(ProcessSample.elapsedNanoseconds(before: 25, after: 10) == 0)
    #expect(ProcessSample.elapsedNanoseconds(before: .max, after: 0) == 0)
    #expect(ProcessSample.elapsedNanoseconds(before: 0, after: .max) == .max)
}

@Test func shareOverCPUCount() throws {
    let before = sample(at: 10 * second, [identity(42)], taskInfo: [42: counters(5 * second)])
    let after = sample(at: 11 * second, [identity(42)], taskInfo: [42: counters(7 * second)])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 18, kernelTask: nil)
    #expect(rows.count == 1)
    #expect(abs(rows[0].cpuPercent - 100.0 * 2 / 18) < 1e-9)    // 11.1%
    #expect(rows[0].source == .libproc)
}

/// The controlling terminal rides on the process table's read (the gate's round 5, rule B): no read of its own.
@Test func theTerminalComesFromTheTableRead() throws {
    let shell = ProcessIdentity(pid: 42, ppid: 1, uid: 501, user: "user", startMicroseconds: 1_000, comm: "zsh",
                                path: nil, terminal: true)
    let before = sample(at: 0, [shell, identity(43)], taskInfo: [42: counters(0), 43: counters(0)])
    let after = sample(at: second, [shell, identity(43)], taskInfo: [42: counters(0), 43: counters(0)])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 4, kernelTask: nil)
    #expect(rows.map(\.terminal) == [true, false])
}

@Test func processExitedBetweenSamples() throws {
    let before = sample(at: 0, [identity(1), identity(2)], taskInfo: [1: counters(0), 2: counters(0)])
    let after = sample(at: second, [identity(1)], taskInfo: [1: counters(0)])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 4, kernelTask: nil)
    #expect(rows.map(\.pid) == [1])
}

@Test func pidReuse() throws {
    let before = sample(at: 0, [identity(7, start: 100)], taskInfo: [7: counters(50 * second)])
    let after = sample(at: second, [identity(7, start: 900)], taskInfo: [7: counters(second / 2)])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil)
    #expect(rows[0].cpuPercent == 50)    // its own half second, not the old process's time
}

@Test func epermRoutesToPs() throws {
    let before = sample(at: 0, [identity(396, user: "root")],
                        ps: [396: PSRow(counters: counters(10 * second, rss: 100), comm: "mds")])
    let after = sample(at: second, [identity(396, user: "root")],
                       ps: [396: PSRow(counters: counters(10 * second + second / 4, rss: 186_000_000), comm: "mds")])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 2, kernelTask: nil)
    #expect(rows[0].source == .ps)
    #expect(rows[0].cpuPercent == 12.5)
    #expect(rows[0].residentBytes == 186_000_000)
}

@Test func libprocPreferredOverPs() throws {
    let before = sample(at: 0, [identity(9)], taskInfo: [9: counters(0)], ps: [9: PSRow(counters: counters(0), comm: "x")])
    let after = sample(at: second, [identity(9)], taskInfo: [9: counters(second)],
                       ps: [9: PSRow(counters: counters(second / 2), comm: "x")])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil)
    #expect(rows[0].source == .libproc)
    #expect(rows[0].cpuPercent == 100)
}

@Test func kernelTaskFromTop() throws {
    let kernel = identity(0, start: 0, user: "root", comm: "kernel_task")
    let before = sample(at: 0, [kernel])
    let after = sample(at: second, [kernel])
    let top = KernelTaskSample(cpuPercentPerCore: 36, residentBytes: 34 << 20)
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 18, kernelTask: top)
    #expect(rows[0].source == .top)
    #expect(rows[0].cpuPercent == 2)
    #expect(rows[0].residentBytes == 34 << 20)
    #expect(rows[0].name == "kernel_task")
}

@Test func newProcessInsideWindow() throws {
    let before = sample(at: 0, [])
    let after = sample(at: 2 * second, [identity(55)], taskInfo: [55: counters(second)])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil)
    #expect(rows[0].cpuPercent == 50)
}

@Test func timeWentBackwards() throws {
    let before = sample(at: 0, [identity(3)], taskInfo: [3: counters(9 * second)])
    let after = sample(at: second, [identity(3)], taskInfo: [3: counters(8 * second)])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil)
    #expect(rows[0].cpuPercent == 0)
}

// MARK: per-process sample times

@Test func stalledReadUsesItsOwnWindow() throws {
    // The closing scan starts at 1 s but reaches pid 8 only at 3 s: its 3 s of CPU ran over its own 3 s, one core busy.
    let before = ProcessListSample(uptimeNanoseconds: 0, processes: [identity(8)], taskInfo: [8: counters(0)], ps: [:],
                                   readAt: ReadTimes(taskInfo: [8: 0]))
    let after = ProcessListSample(uptimeNanoseconds: second, processes: [identity(8)], taskInfo: [8: counters(3 * second)],
                                  ps: [:], readAt: ReadTimes(taskInfo: [8: 3 * second]))
    let row = try usage(8, ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil))
    #expect(row.cpuPercent == 100)    // not 300: the shared 1 s window would read three cores' worth
}

@Test func psRowsUseThePsRunsOwnTime() throws {
    let ps0: [Int32: PSRow] = [5: PSRow(counters: counters(0), comm: "")]
    let ps1: [Int32: PSRow] = [5: PSRow(counters: counters(second), comm: "")]
    let before = ProcessListSample(uptimeNanoseconds: 0, processes: [identity(5)], taskInfo: [:], ps: ps0,
                                   readAt: ReadTimes(ps: 0))
    let after = ProcessListSample(uptimeNanoseconds: second, processes: [identity(5)], taskInfo: [:], ps: ps1,
                                  readAt: ReadTimes(ps: 4 * second))
    let row = try usage(5, ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil))
    #expect(row.source == .ps)
    #expect(row.cpuPercent == 25)    // 1 s over the 4 s between the two ps runs
}

@Test func vmShareUsesItsOwnThreadReadTimes() throws {
    let path = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
    let vm = identity(70, path: path)
    let before = ProcessListSample(uptimeNanoseconds: 0, processes: [vm], taskInfo: [70: counters(0)], ps: [:],
                                   vms: [70: VMSample(name: "dev", vcpus: 4, vcpuNanoseconds: 0)],
                                   readAt: ReadTimes(taskInfo: [70: 0], vm: [70: 0]))
    let after = ProcessListSample(uptimeNanoseconds: second, processes: [vm], taskInfo: [70: counters(6 * second)], ps: [:],
                                  vms: [70: VMSample(name: "dev", vcpus: 4, vcpuNanoseconds: 6 * second)],
                                  readAt: ReadTimes(taskInfo: [70: 3 * second], vm: [70: 3 * second]))
    let row = try usage(70, ProcessSample.usage(before: before, after: after, cpuCount: 18, kernelTask: nil))
    let share = try #require(row.vm?.shareOfAllotted)
    #expect(abs(share - 50) < 1e-9)    // 6 s over 3 s of 4 vCPUs, not 150% over the shared 1 s
    #expect(abs(row.cpuPercent - 100.0 * 6 / (3 * 18)) < 1e-9)
}

@Test func exitedChildrenUseTheRusageReadTimes() throws {
    let before = ProcessListSample(uptimeNanoseconds: 0, processes: [identity(100)], taskInfo: [100: counters(0)], ps: [:],
                                   childrenCPU: [100: 0], readAt: ReadTimes(rusage: [100: 0]))
    let after = ProcessListSample(uptimeNanoseconds: second, processes: [identity(100)], taskInfo: [100: counters(0)],
                                  ps: [:], childrenCPU: [100: 2 * second], readAt: ReadTimes(rusage: [100: 2 * second]))
    let row = try usage(100, ProcessSample.usage(before: before, after: after, cpuCount: 4, kernelTask: nil))
    #expect(row.exitedChildrenCpuPercent == 25)    // 2 s over its own 2 s of 4 CPUs
}

@Test func newProcessCountsFromTheOpeningScan() throws {
    let before = sample(at: 0, [])
    let after = ProcessListSample(uptimeNanoseconds: second, processes: [identity(55)], taskInfo: [55: counters(second)],
                                  ps: [:], readAt: ReadTimes(taskInfo: [55: 2 * second]))
    let row = try usage(55, ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil))
    #expect(row.cpuPercent == 50)    // 1 s over the 2 s from the opening scan to its read
}

// MARK: CPU of children that exited in the window

/// The row for `pid` in `rows`.
private func usage(_ pid: Int32, _ rows: [ProcessUsage]) throws -> ProcessUsage {
    try #require(rows.first { $0.pid == pid })
}

@Test func exitedChildrenCPUChargedToSurvivingParent() throws {
    let before = sample(at: 0, [identity(100)], taskInfo: [100: counters(0)], children: [100: second])
    let after = sample(at: second, [identity(100)], taskInfo: [100: counters(second / 4)],
                       children: [100: second + second / 2])
    let parent = try usage(100, ProcessSample.usage(before: before, after: after, cpuCount: 4, kernelTask: nil))
    #expect(parent.cpuPercent == 6.25)    // its own CPU, unchanged
    #expect(parent.exitedChildrenCpuPercent == 12.5)
}

@Test func longLivedChildCountsOnlyItsInWindowPart() throws {
    // Child 101 had used 0.8 s itself and reaped 0.1 s of its own children before the window; it
    // ran 0.1 s more and was reaped by 100 inside it. 100's children time grows by all 1.0 s.
    let before = sample(at: 0, [identity(100), identity(101, parent: 100)],
                        taskInfo: [100: counters(0), 101: counters(8 * second / 10)],
                        children: [100: 0, 101: second / 10])
    let after = sample(at: second, [identity(100)], taskInfo: [100: counters(0)], children: [100: second])
    let parent = try usage(100, ProcessSample.usage(before: before, after: after, cpuCount: 4, kernelTask: nil))
    #expect(abs(try #require(parent.exitedChildrenCpuPercent) - 2.5) < 1e-9)
}

@Test func exitedGrandchildStartIsSubtractedToo() throws {
    // tmux 100 → pane shell 101 → long session 102 (900 s before the window). Inside it, 102 exits and
    // 101 reaps it, then 101 exits and 100 reaps it: 100's children time grows by 102's whole life.
    // Only the 0.5 s 102 and 101 used inside the window is charged (live run 2026-10-19: tmux read 1551%).
    let before = sample(at: 0, [identity(100), identity(101, parent: 100), identity(102, parent: 101)],
                        taskInfo: [100: counters(0), 101: counters(second), 102: counters(900 * second)],
                        children: [100: 0, 101: 0, 102: 0])
    let after = sample(at: second, [identity(100)], taskInfo: [100: counters(0)],
                       children: [100: 901 * second + second / 2])
    let parent = try usage(100, ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil))
    #expect(parent.exitedChildrenCpuPercent == 50)
}

@Test func exitedChildStartReadFromPsWhenTaskInfoFails() throws {
    // A setuid child (no task info): its start-of-window CPU comes from ps.
    let before = sample(at: 0, [identity(100), identity(102, parent: 100)], taskInfo: [100: counters(0)],
                        ps: [102: PSRow(counters: counters(second / 2), comm: "sudo")], children: [100: 0])
    let after = sample(at: second, [identity(100)], taskInfo: [100: counters(0)], children: [100: second])
    let parent = try usage(100, ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil))
    #expect(parent.exitedChildrenCpuPercent == 50)
}

@Test func exitedChildStartReadFromRusageFirst() throws {
    // The start reading is the child's own rusage time, read with its collected time in the scan's first
    // pass; task info, read later in the scan, may be missing (the child exited) or later than it.
    let before = sample(at: 0, [identity(100), identity(102, parent: 100)], taskInfo: [100: counters(0)],
                        children: [100: 0, 102: 0], rusage: [100: 0, 102: second / 2])
    let after = sample(at: second, [identity(100)], taskInfo: [100: counters(0)], children: [100: second])
    let parent = try usage(100, ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil))
    #expect(parent.exitedChildrenCpuPercent == 50)
}

@Test func childReapedMidScanIsChargedOnlyItsInWindowPart() throws {
    // Live 2026-10-19: cargo 100's test binary 101 (7.7 s used) was listed by the closing scan, then exited and
    // was reaped before the scan read cargo, whose counter already held 101's whole life; 101 was taken as
    // alive and cargo charged all 8.8 s (exited CPU 347% of the machine). The reader drops a process that was
    // gone by its rusage read, so the closing sample holds no 101: only its 1.1 s in the window is charged,
    // and the window after charges nothing for it.
    let start = sample(at: 0, [identity(100), identity(101, parent: 100)],
                       taskInfo: [100: counters(0), 101: counters(77 * second / 10)],
                       children: [100: 79 * second, 101: 0], rusage: [100: 0, 101: 77 * second / 10])
    let listed = [identity(100), identity(101, parent: 100)]
    let closing = sample(at: second, ProcessReaders.present(listed, me: 501, rusageRead: [100], exists: { $0 != 101 }),
                         taskInfo: [100: counters(0)], children: [100: 878 * second / 10], rusage: [100: 0])
    let next = sample(at: 2 * second, [identity(100)], taskInfo: [100: counters(0)], children: [100: 878 * second / 10],
                      rusage: [100: 0])
    let first = try usage(100, ProcessSample.usage(before: start, after: closing, cpuCount: 1, kernelTask: nil))
    #expect(abs(try #require(first.exitedChildrenCpuPercent) - 110) < 1e-6)
    let then = try usage(100, ProcessSample.usage(before: closing, after: next, cpuCount: 1, kernelTask: nil))
    #expect(then.exitedChildrenCpuPercent == 0)
}

@Test func presentKeepsWhatTheRusagePassCouldNotRead() {
    // Only an own process the rusage pass missed and that no longer exists is dropped: a live one it could not
    // read stays, and other users' processes (never read) stay.
    let processes = [identity(100), identity(101), identity(102),
                     ProcessIdentity(pid: 396, ppid: 1, uid: 0, user: "root", startMicroseconds: 1, comm: "mds", path: nil)]
    let kept = ProcessReaders.present(processes, me: 501, rusageRead: [100], exists: { $0 != 101 })
    #expect(kept.map(\.pid) == [100, 102, 396])
}

@Test func reusedChildPidCountsAsExited() throws {
    // 101 at the start was 100's child; the 101 at the end is another process (new start time).
    let before = sample(at: 0, [identity(100), identity(101, parent: 100, start: 5)],
                        taskInfo: [100: counters(0), 101: counters(second / 4)], children: [100: 0])
    let after = sample(at: second, [identity(100), identity(101, parent: 1, start: 900)],
                       taskInfo: [100: counters(0), 101: counters(0)], children: [100: second, 101: 0])
    let parent = try usage(100, ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil))
    #expect(parent.exitedChildrenCpuPercent == 75)
}

@Test func exitedParentContributesNothing() throws {
    // 100 and its child both exit with nonzero time. launchd's own CPU is readable through ps;
    // neither their own time nor their reaped-children time may be added to its row.
    let launchd = ProcessIdentity(pid: 1, ppid: 0, uid: 0, user: "root", startMicroseconds: 1, comm: "launchd", path: nil)
    let before = sample(at: 0, [launchd, identity(100), identity(101, parent: 100)],
                        taskInfo: [100: counters(second / 4), 101: counters(second / 2)],
                        ps: [1: PSRow(counters: counters(0), comm: "launchd")],
                        children: [100: 2 * second, 101: second])
    let after = sample(at: second, [launchd], ps: [1: PSRow(counters: counters(second / 10), comm: "launchd")])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil)
    #expect(rows.map(\.pid) == [1])
    #expect(rows[0].cpuPercent == 10)
    #expect(rows[0].exitedChildrenCpuPercent == nil)
    #expect(rows[0].totalCpuPercent == 10)
}

@Test func otherUsersParentsReadNothing() throws {
    let root = ProcessIdentity(pid: 396, ppid: 1, uid: 0, user: "root", startMicroseconds: 1, comm: "mds", path: nil)
    let before = sample(at: 0, [root, identity(100)], taskInfo: [100: counters(0)],
                        ps: [396: PSRow(counters: counters(0), comm: "mds")], children: [100: second])
    let after = sample(at: second, [root, identity(100)], taskInfo: [100: counters(0)],
                       ps: [396: PSRow(counters: counters(0), comm: "mds")], children: [100: second])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil)
    #expect(try usage(396, rows).exitedChildrenCpuPercent == nil)
    #expect(try usage(100, rows).exitedChildrenCpuPercent == 0)    // read, nothing exited
}

@Test func exitedChildrenEdgeCases() throws {
    // 200 new in the window: all its children time is in-window. 201 unread at the start: no window.
    // 202's counter went backwards: 0. 203's subtraction would pass its delta: floored at 0.
    let before = sample(at: 0, [identity(201), identity(202), identity(203), identity(204, parent: 203)],
                        taskInfo: [201: counters(0), 202: counters(0), 203: counters(0), 204: counters(3 * second)],
                        children: [202: 5 * second, 203: 0])
    let after = sample(at: second, [identity(200), identity(201), identity(202), identity(203)],
                       taskInfo: [200: counters(0), 201: counters(0), 202: counters(0), 203: counters(0)],
                       children: [200: second / 2, 201: second, 202: 4 * second, 203: second])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil)
    #expect(try usage(200, rows).exitedChildrenCpuPercent == 50)
    #expect(try usage(201, rows).exitedChildrenCpuPercent == nil)
    #expect(try usage(202, rows).exitedChildrenCpuPercent == 0)
    #expect(try usage(203, rows).exitedChildrenCpuPercent == 0)
}

@Test func sortOrder() throws {
    let pids: [Int32] = [30, 10, 20, 40]
    let cpu: [Int32: UInt64] = [30: second / 10, 10: second / 10, 20: second / 2, 40: 0]
    let before = sample(at: 0, pids.map { identity($0) }, taskInfo: Dictionary(uniqueKeysWithValues: pids.map { ($0, counters(0)) }))
    let after = sample(at: second, pids.map { identity($0) },
                       taskInfo: Dictionary(uniqueKeysWithValues: pids.map { ($0, counters(cpu[$0]!)) }))
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil)
    #expect(rows.map(\.pid) == [20, 10, 30, 40])
}

/// Phase 6 Step 3: a storm's parent, 0.2% itself and +23% exited, sorts at 23.2% — after a 23.3% row, before a 5% one.
@Test func rowsSortByOwnPlusExitedCPU() throws {
    let pids: [Int32] = [51, 50, 52]
    let cpu: [Int32: UInt64] = [50: second / 500, 51: second / 20, 52: 233 * second / 1_000]
    let before = sample(at: 0, pids.map { identity($0) }, taskInfo: Dictionary(uniqueKeysWithValues: pids.map { ($0, counters(0)) }),
                        children: [50: 0])
    let after = sample(at: second, pids.map { identity($0) },
                       taskInfo: Dictionary(uniqueKeysWithValues: pids.map { ($0, counters(cpu[$0]!)) }),
                       children: [50: 23 * second / 100])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil)
    #expect(rows.map(\.pid) == [52, 50, 51])
    let parent = try usage(50, rows)
    #expect(abs(parent.cpuPercent - 0.2) < 1e-9)
    #expect(abs(parent.totalCpuPercent - 23.2) < 1e-9)
}

@Test func nameFromPathThenPCommThenPsComm() throws {
    let procs = [identity(1, comm: "short", path: "/usr/libexec/logd"),
                 identity(2, comm: "Google Chrome He"),
                 identity(3, comm: "")]
    let ps: [Int32: PSRow] = [1: PSRow(counters: counters(0), comm: "/elsewhere/other"),
                              2: PSRow(counters: counters(0), comm: "/Applications/Google Chrome.app/Google Chrome Helper"),
                              3: PSRow(counters: counters(0), comm: "/usr/sbin/argv0")]
    let rows = try ProcessSample.usage(before: sample(at: 0, procs, ps: ps), after: sample(at: second, procs, ps: ps),
                                       cpuCount: 1, kernelTask: nil)
    #expect(rows.map(\.name) == ["logd", "Google Chrome He", "argv0"])
}

/// A zombie has no executable path and `ps` shows `<defunct>`; the kernel still knows its short name.
@Test func noPathNamedByPComm() throws {
    let procs = [identity(8, comm: "cmux")]
    let ps: [Int32: PSRow] = [8: PSRow(counters: counters(0), comm: "<defunct>")]
    let rows = try ProcessSample.usage(before: sample(at: 0, procs, ps: ps), after: sample(at: second, procs, ps: ps),
                                       cpuCount: 1, kernelTask: nil)
    #expect(rows.map(\.name) == ["cmux"])
}

@Test func noTimeElapsedIsAnError() {
    let s = sample(at: second, [identity(1)], taskInfo: [1: counters(0)])
    #expect(throws: ProcessSampleError.noTimeElapsed) {
        try ProcessSample.usage(before: s, after: s, cpuCount: 1, kernelTask: nil)
    }
}

@Test func machTimebaseConversion() {
    let timebase = MachTimebase(numer: 125, denom: 3)
    #expect(timebase.nanoseconds(3) == 125)
    #expect(timebase.nanoseconds(24_000_000) == 1_000_000_000)    // one second of 24 MHz ticks
    #expect(MachTimebase(numer: 1, denom: 1).nanoseconds(777) == 777)
}

@Test func timebaseReadsMachTimebaseInfo() throws {
    let timebase = try MachTimebase { info in
        info = mach_timebase_info_data_t(numer: 125, denom: 3)
        return KERN_SUCCESS
    }
    #expect(timebase == MachTimebase(numer: 125, denom: 3))
}

// MARK: tool runs

/// A failing tool's error carries what it printed on stderr; its runs leave nothing new in the temp folder. Only files
/// that appear during these runs count: the folder is the user's, shared with every other Saur0n process, and one
/// stopped between `mkstemp` and `unlink` leaves its file there (Phase 6 Step 3 gate, 2026-10-23). A file caught inside
/// another process's mkstemp→unlink window (a parallel test, the app refreshing once a second) vanishes within
/// microseconds while a true leftover never does, so the after-listing re-lists before failing (flake, 2026-10-25).
@Test func failedCommandKeepsItsStderr() throws {
    func scratchFiles() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("saur0n-stderr.") })
    }
    let before = try scratchFiles()
    let command = try ProcessReaders.Command(path: "/bin/sh", arguments: ["-c", "echo partial; echo 'ps: bad option' >&2; exit 3"]).start()
    #expect(throws: ProcessReadError.command(path: "/bin/sh", status: 3, stderr: "ps: bad option")) {
        try ProcessReaders.run(command)
    }
    let ok = try ProcessReaders.run(ProcessReaders.Command(path: "/bin/sh", arguments: ["-c", "echo fine"]).start())
    #expect(ok == "fine\n")
    var strays = try scratchFiles().subtracting(before)
    for _ in 0 ..< 10 where !strays.isEmpty {
        Thread.sleep(forTimeInterval: 0.05)
        strays = try scratchFiles().subtracting(before)
    }
    #expect(strays.isEmpty)
}

/// A hung tool (here `sleep 30`) is killed at the deadline and the read throws, so the refresh moves on.
@Test func hungCommandTimesOutAndIsKilled() throws {
    let command = try ProcessReaders.Command(path: "/bin/sleep", arguments: ["30"]).start()
    let pid = command.process.processIdentifier
    // Uptime, the runner's own clock: the wall clock runs on while the Mac sleeps (an 8-minute sleep inside this test
    // failed it, 2026-10-26).
    let started = DispatchTime.now().uptimeNanoseconds
    #expect(throws: ProcessReadError.timedOut(path: "/bin/sleep", seconds: 0.5)) {
        try ProcessReaders.run(command, timeout: 0.5)
    }
    #expect(DispatchTime.now().uptimeNanoseconds - started < 5_000_000_000)
    #expect(!command.process.isRunning)
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    // The default deadline is 5 s.
    #expect(ProcessReaders.timeout == 5)
}

@Test func exitedCommandDoesNotWaitForAnotherStdoutWriter() throws {
    let command = ProcessReaders.Command(path: "/bin/sh", arguments: ["-c", "echo fine"])
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
    holder.arguments = ["30"]
    holder.standardOutput = FileHandle(fileDescriptor: dup(command.stdout.fileHandleForWriting.fileDescriptor), closeOnDealloc: true)
    try holder.run()
    defer {
        if holder.isRunning { kill(holder.processIdentifier, SIGKILL) }
        holder.waitUntilExit()
    }
    let started = try command.start()
    #expect(try ProcessReaders.run(started, timeout: 0.2) == "fine\n")
    #expect(holder.isRunning)
}

@Test func completedCommandAtItsDeadlineKeepsAllOutput() throws {
    let command = try ProcessReaders.Command(path: "/bin/sh", arguments: ["-c", "echo fine"]).start()
    command.process.waitUntilExit()
    #expect(try ProcessReaders.run(command, timeout: 0) == "fine\n")
}

@Test func killedCommandDoesNotWaitForeverForAnExitNotification() throws {
    let command = ProcessReaders.Command(path: "/bin/sleep", arguments: ["30"])
    command.process.terminationHandler = nil
    let started = try command.start()
    let exited = command.exited
    let finished = DispatchSemaphore(value: 0)
    // Release the old unbounded wait if the regression returns, without relying on the pool's workers.
    Thread.detachNewThread {
        if finished.wait(timeout: .now() + 2) == .timedOut { exited.signal() }
    }
    defer { finished.signal() }
    let began = DispatchTime.now().uptimeNanoseconds
    #expect(throws: ProcessReadError.timedOut(path: "/bin/sleep", seconds: 0.1)) {
        try ProcessReaders.run(started, timeout: 0.1)
    }
    #expect(DispatchTime.now().uptimeNanoseconds - began < 1_500_000_000)
    #expect(!command.process.isRunning)
}

private final class BlockedPoolWorkers: @unchecked Sendable {
    let started = DispatchGroup()
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let count: Int
    private var released = false
    private var holding = 0

    init(count: Int) {
        self.count = count
        for _ in 0 ..< count { started.enter() }
    }

    func hold() {
        lock.lock()
        holding += 1
        started.leave()
        lock.unlock()
        // Each worker bounds its own wait; a queued fallback can itself starve behind the held workers.
        _ = gate.wait(timeout: .now() + 30)
        lock.lock()
        holding -= 1
        lock.unlock()
    }

    var heldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return released ? 0 : holding
    }

    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        lock.unlock()
        for _ in 0 ..< count { gate.signal() }
    }
}

/// A pool-task stdout read must wait for held workers; a dedicated-thread read must not. Prepare output before
/// holding one worker per core, then release them only after the read. Allow 20 s for the shared pool to start
/// workers; their own 30 s bounds leave room for the 3 s read without burning CPU or timing success by a cutoff.
@Test func commandIsReadWhileEveryWorkerThreadIsBusy() async throws {
    let count = ProcessInfo.processInfo.activeProcessorCount
    let reading: (output: Result<String, Error>, held: Int, started: Bool,
                  workers: [Task<Void, Never>]) = await withCheckedContinuation { done in
        Thread.detachNewThread {
            let command: ProcessReaders.Command
            do {
                command = try ProcessReaders.Command(path: "/bin/sh", arguments: ["-c", "echo fine"]).start()
                command.process.waitUntilExit()
            } catch {
                done.resume(returning: (.failure(error), 0, true, []))
                return
            }
            let held = BlockedPoolWorkers(count: count)
            let workers = (0 ..< count).map { _ in
                Task.detached(priority: .medium) { held.hold() }
            }
            guard held.started.wait(timeout: .now() + 20) == .success else {
                held.release()
                done.resume(returning: (.success(""), 0, false, workers))
                return
            }
            let output = Result { try ProcessReaders.run(command, timeout: 3) }
            // Inspect here: resuming the test itself needs a pool worker, which release frees.
            let stillHeld = held.heldCount
            held.release()
            done.resume(returning: (output, stillHeld, true, workers))
        }
    }
    for worker in reading.workers { await worker.value }
    try #require(reading.started, "Busy-worker precondition failed: not all \(count) workers started within 20 s")
    #expect(try reading.output.get() == "fine\n")
    #expect(reading.held == count)
}

@Test func launchFailureSaysWhy() {
    do {
        _ = try ProcessReaders.Command(path: "/nonexistent/example-tool", arguments: []).start()
        Issue.record("launched a missing tool")
    } catch ProcessReadError.launch(let path, let reason) {
        #expect(path == "/nonexistent/example-tool")
        #expect(!reason.isEmpty)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func timebaseZeroDenominatorThrows() {
    #expect(throws: ProcessReadError.timebase(kernReturn: KERN_FAILURE)) {
        try MachTimebase { info in
            info = mach_timebase_info_data_t(numer: 1, denom: 0)
            return KERN_SUCCESS
        }
    }
    #expect(throws: ProcessReadError.timebase(kernReturn: KERN_INVALID_ARGUMENT)) {
        try MachTimebase { _ in KERN_INVALID_ARGUMENT }
    }
}

// MARK: table and JSON

private let fixtureRows = [
    ProcessUsage(pid: 1221, ppid: 1, uid: 501, user: "alice", path: "/System/Library/Frameworks/Virtualization.framework/com.apple.Virtualization.VirtualMachine",
                 name: "com.apple.Virtualization.VirtualMachine", cpuPercent: 11.164, residentBytes: 8_700_000_000, source: .libproc),
    ProcessUsage(pid: 0, ppid: 0, uid: 0, user: "root", path: nil, name: "kernel_task",
                 cpuPercent: 3.1, residentBytes: 34 << 20, source: .top),
    ProcessUsage(pid: 396, ppid: 1, uid: 0, user: "root", path: "/System/Library/mds", name: "mds",
                 cpuPercent: 100, residentBytes: 900, source: .ps),
]

/// One level of two CPUs, with processes.
private func snapshotWithProcesses() throws -> Snapshot {
    try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 2), load: CPULoad(perCPU: [10, 30], total: 20),
                 intervalSeconds: 1, processes: fixtureRows)
}

@Test func tableLayout() throws {
    #expect(try snapshotWithProcesses().table() == """
    CPU  20.0% of the whole machine (2 CPUs, 1.0 s sample)
    CPU  2 CPUs  (0–1)  avg 20.0%
      0   10.0%   1   30.0%

        PID   PPID  USER     CPU   MEM  NAME
       1221      1  alice  11.2%  8.1G  com.apple.Virtualization.VirtualMachine
          0      0  root    3.1%   34M  kernel_task
        396      1  root  100.0%  900B  mds
    """)
}

@Test func longUserNamesOverflowTheirRowOnly() {
    let rows = [ProcessUsage(pid: 1, ppid: 0, uid: 0, user: "root", path: nil, name: "launchd",
                             cpuPercent: 0.1, residentBytes: 1024, source: .ps),
                ProcessUsage(pid: 91735, ppid: 1, uid: 245, user: "_installcoordinationd", path: nil, name: "pkd",
                             cpuPercent: 0, residentBytes: 4096, source: .ps)]
    #expect(ProcessSample.table(rows) == """
        PID   PPID  USER            CPU   MEM  NAME
          1      0  root           0.1%  1.0K  launchd
      91735      1  _installcoordinationd   0.0%  4.0K  pkd
    """)
}

/// A name holding a newline would forge a second row; an ANSI escape would recolour the terminal.
private let controlRows = [
    ProcessUsage(pid: 5, ppid: 1, uid: 501, user: "root", path: nil, name: "zz\nfake",
                 cpuPercent: 0, residentBytes: 4096, source: .ps),
    ProcessUsage(pid: 6, ppid: 1, uid: 501, user: "ev\u{7}l", path: nil, name: "ee\u{1B}[31mRED",
                 cpuPercent: 0, residentBytes: 4096, source: .ps),
]

@Test func tableEscapesControlCharacters() throws {
    let table = ProcessSample.table(controlRows)
    #expect(table.split(separator: "\n").count == 3)
    #expect(table.contains(#"zz\x0Afake"#))
    #expect(table.contains(#"ee\x1B[31mRED"#))
    #expect(!table.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" })

    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1),
                                load: CPULoad(perCPU: [0], total: 0), intervalSeconds: 1, processes: controlRows)
    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    let processes = try #require(object["processes"] as? [[String: Any]])
    #expect(processes.map { $0["name"] as? String } == ["zz\nfake", "ee\u{1B}[31mRED"])
    #expect(processes.map { $0["user"] as? String } == ["root", "ev\u{7}l"])
}

/// USER pads to the escaped width (`ev\x07l` is 7 wide), so CPU stays in one column.
@Test func escapeKeepsColumnsAligned() {
    #expect(ProcessSample.table(controlRows) == #"""
        PID   PPID  USER       CPU   MEM  NAME
          5      1  root      0.0%  4.0K  zz\x0Afake
          6      1  ev\x07l   0.0%  4.0K  ee\x1B[31mRED
    """#)
}

@Test func c1ControlEscaped() {
    #expect(TextFormat.displaySafe("a\u{85}b") == #"a\x85b"#)
    #expect(TextFormat.displaySafe("\u{0}\t\u{7F}\u{9F}") == #"\x00\x09\x7F\x9F"#)
    #expect(TextFormat.displaySafe("Café 日本 (Renderer)") == "Café 日本 (Renderer)")
}

/// U+202E would show `exe.png` for `gnp.exe`; a line separator would break the row.
@Test func formatCharactersAndSeparatorsEscaped() {
    #expect(TextFormat.displaySafe("a\u{202E}gnp.exe") == #"a\"# + "u202Egnp.exe")
    #expect(TextFormat.displaySafe("x\u{200B}y\u{2028}z\u{2029}") == ["x", "u200By", "u2028z", "u2029"].joined(separator: #"\"#))
    #expect(TextFormat.displaySafe("tag\u{E0001}") == #"tag\U000E0001"#)
}

/// A literal `\x0A` in a name must not read like the escape of a newline.
@Test func backslashEscaped() {
    #expect(TextFormat.displaySafe(#"zz\x0Afake"#) == #"zz\\x0Afake"#)
    #expect(TextFormat.displaySafe("zz\nfake") == #"zz\x0Afake"#)
}

/// Cut to the terminal's width, a name padded to wrap cannot fake a row on the next line.
@Test func tableRowsFitTheTerminal() {
    let forged = String(repeating: " ", count: 60) + "  4242      1  root   99.0%  1.0G  fake"
    let rows = [ProcessUsage(pid: 7, ppid: 1, uid: 501, user: "user", path: nil, name: "a" + forged,
                             cpuPercent: 0, residentBytes: 4096, source: .ps)]
    let lines = ProcessSample.table(rows, columns: 80).split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 2)
    #expect(lines.allSatisfy { $0.count <= 80 })
    #expect(!lines[1].contains("fake"))
    #expect(ProcessSample.table(rows).contains("fake"))
}

@Test func fittedCountsWideCharactersTwice() {
    #expect(TextFormat.fitted("abcdef", columns: 4) == "abcd")
    #expect(TextFormat.fitted("日本語", columns: 5) == "日本")
    #expect(TextFormat.fitted("ab", columns: 4) == "ab")
}

@Test func fittedCountsEveryScalarOfACharacter() {
    // One Character with many combining marks or an emoji modifier: a terminal may draw each part.
    let stacked = "a" + String(repeating: "\u{0301}", count: 20)
    #expect(TextFormat.fitted(stacked + "b", columns: 4) == "")
    #expect(TextFormat.fitted("x" + stacked, columns: 21) == "x")
    #expect(TextFormat.fitted("\u{1F44D}\u{1F3FD}z", columns: 4) == "\u{1F44D}\u{1F3FD}")
    #expect(TextFormat.fitted("\u{1F44D}\u{1F3FD}", columns: 3) == "")
}

@Test func memoryText() {
    #expect(ProcessSample.memoryText(0) == "0B")
    #expect(ProcessSample.memoryText(1023) == "1023B")
    #expect(ProcessSample.memoryText(1536) == "1.5K")
    #expect(ProcessSample.memoryText(181_328 * 1024) == "177M")
    #expect(ProcessSample.memoryText(1023 * 1024 * 1024 + 900 * 1024) == "1.0G")    // 1023.9M rounds into G
    let gib: UInt64 = 1024 * 1024 * 1024
    #expect(ProcessSample.memoryText(gib * 994 / 100) == "9.9G")
    #expect(ProcessSample.memoryText((gib * 995 + 99) / 100) == "10G")    // first byte at or above 9.95 GiB
    #expect(ProcessSample.memoryText(gib * 999 / 100) == "10G")
    #expect(ProcessSample.memoryText(10 * gib) == "10G")
}

@Test func jsonKeepsEarlierKeys() throws {
    let object = try #require(JSONSerialization.jsonObject(with: snapshotWithProcesses().json()) as? [String: Any])
    #expect(Set(object.keys) == ["coreTypes", "totalBusyPercent", "intervalSeconds", "processes"])
    let coreType = try #require((object["coreTypes"] as? [[String: Any]])?.first)
    #expect(Set(coreType.keys) == ["name", "level", "cpus", "busyPercent", "averageBusyPercent"])

    let processes = try #require(object["processes"] as? [[String: Any]])
    #expect(processes.map { $0["pid"] as? Int } == [1221, 0, 396])
    // Phase 1–3 keys kept; Step 3 adds `exitedChildrenCpuPercent`, null when unread; Phase 5 Step 1 `disk`, the same;
    // Step 2 `network`, null when no `nettop` map was given; Step 4 `app`; Phase 6 Step 8 `orphaned`, always there.
    #expect(Set(processes[0].keys) == ["pid", "ppid", "uid", "user", "path", "app", "name", "readableName", "cpuPercent",
                                       "exitedChildrenCpuPercent", "residentBytes", "source", "vm", "repo", "session",
                                       "orphaned", "disk", "network"])
    #expect(processes[0]["orphaned"] as? Bool == false)
    #expect(processes[0]["exitedChildrenCpuPercent"] is NSNull)
    #expect(processes[0]["disk"] is NSNull)
    #expect(processes[0]["network"] is NSNull)
    #expect(processes[0]["readableName"] is NSNull)
    #expect(processes[0]["vm"] is NSNull)
    #expect(processes[0]["repo"] is NSNull)
    #expect(processes[0]["session"] is NSNull)
    #expect(processes[0]["cpuPercent"] as? Double == 11.16)    // two decimals in JSON; the table shows 11.2%
    #expect(processes[0]["residentBytes"] as? Int == 8_700_000_000)
    #expect(processes[1]["path"] is NSNull)
    #expect(processes.map { $0["source"] as? String } == ["libproc", "top", "ps"])
}

// MARK: repo groups

private let repoA = RepoInfo(name: "alpha", root: "/work/alpha", worktree: nil)
private let repoAWorktree = RepoInfo(name: "alpha", root: "/work/alpha", worktree: "/work/alpha.wt/fix")
private let repoB = RepoInfo(name: "beta", root: "/work/beta", worktree: nil)

private func row(_ pid: Int32, parent: Int32 = 1, uid: UInt32 = 501, cpu: Double = 0, exited: Double? = nil,
                 rss: UInt64 = 1024, path: String? = nil, name: String = "proc") -> ProcessUsage {
    ProcessUsage(pid: pid, ppid: parent, uid: uid, user: uid == 0 ? "root" : "alice", path: path, name: name,
                 cpuPercent: cpu, residentBytes: rss, source: .libproc, exitedChildrenCpuPercent: exited)
}

/// Folders under a fake repo's root (or its worktree) resolve to it; nothing else does.
private func fakeRepo(_ folder: String) -> RepoInfo? {
    [repoAWorktree, repoA, repoB].first { folder.hasPrefix($0.worktree ?? $0.root) }
}

private func assign(_ rows: [ProcessUsage], cwd: [Int32: String]) -> (rows: [ProcessUsage], groups: [RepoGroup]) {
    RepoGroups.assign(rows, workingDirectories: cwd, repoOfDirectory: fakeRepo,
                      repoOfExecutable: { fakeRepo(($0 as NSString).deletingLastPathComponent) })
}

@Test func repoFromWorkingDirectoryThenExecutable() {
    let result = assign([row(10), row(11, path: "/work/beta/.build/debug/tool"), row(12, path: "/bin/zsh"),
                         row(13)],
                        cwd: [10: "/work/alpha/src", 11: "/", 12: "/fixtures/alice", 13: "/work/alpha.wt/fix/deep"])
    #expect(result.rows.map(\.repo) == [repoA, repoB, nil, repoAWorktree])
    #expect(result.groups.map(\.name) == ["alpha", "beta", RepoGroups.notInARepo])
    // The main checkout and its linked worktree are one group.
    #expect(result.groups[0].pids == [10, 13])
}

@Test func unreadableWorkingDirectoryInheritsUpTheParents() {
    // 20 (own, in alpha) → 21 (root, setuid, no cwd) → 22 (root, no cwd): both inherit alpha.
    // 30 (root, parent launchd, no cwd): its executable has no repo → System and other users.
    // 31 (root, no cwd) runs a binary built in beta: beta.
    let rows = [row(20), row(21, parent: 20, uid: 0), row(22, parent: 21, uid: 0), row(30, uid: 0, path: "/usr/libexec/d"),
                row(31, uid: 0, path: "/work/beta/bin/tool"), row(1, parent: 0, uid: 0, path: "/sbin/launchd")]
    let result = assign(rows, cwd: [20: "/work/alpha"])
    #expect(result.rows.map(\.repo) == [repoA, repoA, repoA, nil, repoB, nil])
    #expect(result.groups.map(\.name) == ["alpha", "beta", RepoGroups.systemAndOtherUsers])
    #expect(result.groups.last?.pids == [30, 1])
}

@Test func parentLoopEnds() {
    let result = assign([row(40, parent: 41, uid: 0), row(41, parent: 40, uid: 0)], cwd: [:])
    #expect(result.rows.map(\.repo) == [nil, nil])
    #expect(result.groups.map(\.pids) == [[40, 41]])
}

@Test func groupTotalsAndOrder() {
    let rows = [row(50, cpu: 9, rss: 100), row(51, cpu: 4, rss: 10), row(52, cpu: 3, rss: 1), row(53, cpu: 2, rss: 1),
                row(54, cpu: 1, rss: 5), row(55, uid: 0, cpu: 0.5, rss: 7)]
    // Repos by total (beta 7, alpha 3); the catch-alls go last even when busier ("Not in a repo" 9).
    let result = assign(rows, cwd: [50: "/", 51: "/work/beta", 52: "/work/beta/x", 53: "/work/alpha", 54: "/work/alpha"])
    #expect(result.groups.map(\.name) == ["beta", "alpha", RepoGroups.notInARepo, RepoGroups.systemAndOtherUsers])
    #expect(result.groups.map(\.cpuPercent) == [7, 3, 9, 0.5])
    #expect(result.groups.map(\.residentBytes) == [11, 6, 100, 7])
    // Every pid in exactly one group.
    #expect(result.groups.flatMap(\.pids).sorted() == rows.map(\.pid).sorted())
}

@Test func groupTotalsIncludeExitedChildren() {
    // alpha: own 5, exited 0; beta: own 2 + 4.5 exited from a shell's hooks → beta's 6.5 goes first.
    let rows = [row(90, cpu: 5, exited: 0), row(91, cpu: 1, exited: 4.5, name: "zsh"), row(92, cpu: 1),
                row(93, uid: 0, cpu: 0.5)]
    let result = assign(rows, cwd: [90: "/work/alpha", 91: "/work/beta", 92: "/work/beta"])
    #expect(result.groups.map(\.name) == ["beta", "alpha", RepoGroups.systemAndOtherUsers])
    #expect(result.groups.map(\.cpuPercent) == [2, 5, 0.5])    // own CPU only, as before
    #expect(result.groups.map(\.exitedChildrenCpuPercent) == [4.5, 0, 0])

    let sessions = SessionGroups.assign(result.rows, sources: SessionSources(
        registry: [], startSeconds: [:], environmentSessionIDs: [:], tmuxPanes: [90: "one", 91: "two"], tty: [:], ownUID: 501))
    #expect(sessions.groups.map(\.name) == ["two", "one", SessionGroups.noSession, SessionGroups.systemAndOtherUsers])
    #expect(sessions.groups.map(\.cpuPercent) == [1, 5, 1, 0.5])
    #expect(sessions.groups.map(\.exitedChildrenCpuPercent) == [4.5, 0, 0, 0])
}

@Test func groupedTable() throws {
    let rows = [row(60, cpu: 12, rss: 2 << 20, name: "cargo"), row(61, parent: 60, cpu: 30, rss: 1 << 20, name: "astar-0123456789abcdef"),
                row(62, cpu: 1, name: "zsh"), row(63, uid: 0, cpu: 0.2, name: "launchd")]
    var result = assign(rows, cwd: [60: "/work/alpha.wt/fix", 61: "/work/alpha", 62: "/"])
    result.rows[1].readableName = "test: astar · alpha"
    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 2),
                                load: CPULoad(perCPU: [40, 50], total: 45), intervalSeconds: 1,
                                processes: result.rows, repoGroups: result.groups)
    #expect(snapshot.table() == """
    CPU  45.0% of the whole machine (2 CPUs, 1.0 s sample)
    CPU  2 CPUs  (0–1)  avg 45.0%
      0   40.0%   1   50.0%

        PID   PPID  USER     CPU   MEM  NAME
    alpha  42.0%  3.0M  2 processes
         60      1  alice  12.0%  2.0M  cargo  [worktree fix]
         61     60  alice  30.0%  1.0M  astar-0123456789abcdef  (test: astar · alpha)
    Not in a repo  1.0%  1.0K  1 process
         62      1  alice   1.0%  1.0K  zsh
    System and other users  0.2%  1.0K  1 process
         63      1  root    0.2%  1.0K  launchd

    Unattributed CPU  1.8%
    """)
}

@Test func groupHeadersShowRootsWhenNamesCollideAndEscape() {
    let other = RepoInfo(name: "alpha", root: "/clones/alpha", worktree: nil)
    let evil = RepoInfo(name: "ev\u{1B}[2Jil", root: "/work/ev", worktree: "/work/ev.wt/x\ny")
    let rows = [row(70, cpu: 2), row(71, cpu: 1), row(72)]
    let result = RepoGroups.assign(rows, workingDirectories: [70: "a", 71: "b", 72: "c"],
                                   repoOfDirectory: { ["a": repoA, "b": other, "c": evil][$0] },
                                   repoOfExecutable: { _ in nil })
    let table = ProcessSample.table(result.rows, groups: result.groups)
    #expect(table.contains("alpha (/work/alpha)  2.0%"))
    #expect(table.contains("alpha (/clones/alpha)  1.0%"))
    #expect(table.contains(#"ev\x1B[2Jil  0.0%"#))
    #expect(table.contains(#"[worktree x\x0Ay]"#))
    #expect(!table.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" })
}

@Test func repoJSON() throws {
    let result = assign([row(80, cpu: 1.234), row(81, cpu: 2), row(82, uid: 0)],
                        cwd: [80: "/work/alpha.wt/fix", 81: "/work/alpha"])
    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1),
                                load: CPULoad(perCPU: [0], total: 0), intervalSeconds: 1,
                                processes: result.rows, repoGroups: result.groups)
    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    #expect(Set(object.keys) == ["coreTypes", "totalBusyPercent", "intervalSeconds", "processes", "repoGroups",
                                 "unattributedCpuPercent"])
    let processes = try #require(object["processes"] as? [[String: Any]])
    let first = try #require(processes[0]["repo"] as? [String: Any])
    #expect(Set(first.keys) == ["name", "root", "worktree"])
    #expect(first["worktree"] as? String == "/work/alpha.wt/fix")
    #expect((processes[1]["repo"] as? [String: Any])?["worktree"] is NSNull)
    #expect(processes[2]["repo"] is NSNull)
    let groups = try #require(object["repoGroups"] as? [[String: Any]])
    #expect(Set(groups[0].keys) == ["name", "cpuPercent", "exitedChildrenCpuPercent", "residentBytes", "disk", "network",
                                    "pids", "subgroups"])
    #expect(groups.map { $0["name"] as? String } == ["alpha", RepoGroups.systemAndOtherUsers])
    #expect(groups[0]["cpuPercent"] as? Double == 3.23)
    #expect(groups[0]["pids"] as? [Int] == [80, 81])
}

// MARK: readable names

@Test func usageCarriesReadableName() throws {
    let test = identity(42, comm: "astar-f93bb998ee", path: "/w/target/debug/deps/astar-f93bb998ee1a2b3c")
    let plain = identity(43, path: "/usr/bin/plain")
    let before = sample(at: 10 * second, [test, plain], taskInfo: [42: counters(0), 43: counters(0)])
    let after = ProcessListSample(uptimeNanoseconds: 11 * second, processes: [test, plain],
                                  taskInfo: [42: counters(second), 43: counters(0)], ps: [:],
                                  arguments: [42: ProcessArguments(argv: ["astar"], environment: ["CARGO_PKG_NAME": "my-crate"])])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil)
    #expect(rows.map(\.readableName) == ["test: astar · my-crate", nil])

    let table = ProcessSample.table(rows)
    #expect(table.contains("astar-f93bb998ee1a2b3c  (test: astar · my-crate)"))
    #expect(table.hasSuffix("  plain"))

    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1),
                                load: CPULoad(perCPU: [100], total: 100), intervalSeconds: 1, processes: rows)
    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    let processes = try #require(object["processes"] as? [[String: Any]])
    #expect(processes[0]["readableName"] as? String == "test: astar · my-crate")
    #expect(processes[1]["readableName"] is NSNull)
}

@Test func readableNameEscapesControlCharacters() {
    let rows = [ProcessUsage(pid: 7, ppid: 1, uid: 501, user: "u", path: nil, name: "n", cpuPercent: 0,
                             residentBytes: 0, source: .libproc, readableName: "test: a\nb")]
    #expect(ProcessSample.table(rows).hasSuffix(#"n  (test: a\x0Ab)"#))
}

// MARK: KERN_PROCARGS2 buffer

/// argc, exec path, NUL padding, argv strings, environment strings — as the kernel lays them out.
private func procArgs(argc: Int32, exec: String = "/w/bin/tool", padding: Int = 3, strings: [String]) -> [UInt8] {
    var bytes = withUnsafeBytes(of: argc) { Array($0) }
    bytes += Array(exec.utf8) + [0] + [UInt8](repeating: 0, count: padding)
    for s in strings { bytes += Array(s.utf8) + [0] }
    return bytes
}

@Test func procArgsLayout() {
    let bytes = procArgs(argc: 2, strings: ["tool", "--quiet", "CARGO_PKG_NAME=my-crate", "NOEQUALS", "A=1", "A=2", "B=x=y"])
    #expect(ProcessSample.parseProcArgs(bytes, keeping: nil) == ProcessArguments(
        argv: ["tool", "--quiet"], environment: ["CARGO_PKG_NAME": "my-crate", "A": "1", "B": "x=y"]))
}

@Test func procArgsKeepOnlyTheEnvironmentKeysUsed() {
    let bytes = procArgs(argc: 2, strings: ["tool", "--quiet", "HOME=/fixtures/u", "CARGO_PKG_NAME=my-crate",
                                            "CLAUDE_CODE_SESSION_ID=abc", "NODE_TEST_CONTEXT=child-v8", "PATH=/bin"])
    #expect(ProcessSample.parseProcArgs(bytes) == ProcessArguments(
        argv: ["tool", "--quiet"],
        environment: ["CARGO_PKG_NAME": "my-crate", "CLAUDE_CODE_SESSION_ID": "abc", "NODE_TEST_CONTEXT": "child-v8"]))
}

@Test func procArgsStopAtEmptyString() {
    let bytes = procArgs(argc: 1, strings: ["tool", "A=1", "", "B=2"])
    #expect(ProcessSample.parseProcArgs(bytes, keeping: nil)?.environment == ["A": "1"])
}

// MARK: Facts kept from a process's launch

private func launched(_ pid: Int32, start: UInt64 = 1, path: String? = "/w/bin/tool", execed: Bool = true) -> ProcessIdentity {
    ProcessIdentity(pid: pid, ppid: 1, uid: 501, user: "u", startMicroseconds: start, comm: "tool", path: path,
                    execed: execed)
}

/// A reader that counts its calls per pid and answers "<pid>#<call>".
private final class CountingReader {
    var calls: [Int32: Int] = [:]
    func read(_ pid: Int32) -> String? {
        calls[pid, default: 0] += 1
        return "\(pid)#\(calls[pid]!)"
    }
}

@Test func keptFactIsReadOncePerProcessAcrossRefreshes() {
    var kept = KeptPerProcess<String>()
    let reader = CountingReader()
    for _ in 0..<3 {
        #expect(kept.values(for: [launched(10), launched(11)], read: reader.read) == [10: "10#1", 11: "11#1"])
    }
    #expect(reader.calls == [10: 1, 11: 1])
}

@Test func keptFactIsReadAgainForAReusedPidOrANewExecutable() {
    var kept = KeptPerProcess<String>()
    let reader = CountingReader()
    _ = kept.values(for: [launched(10), launched(11)], read: reader.read)
    let next = kept.values(for: [launched(10, start: 2), launched(11, path: "/w/bin/other")], read: reader.read)
    #expect(next == [10: "10#2", 11: "11#2"])
}

@Test func keptFactIsNotKeptBeforeTheProcessExecs() {
    // Between fork and exec a child carries its parent's path and arguments under its own pid and start time.
    var kept = KeptPerProcess<String>()
    let reader = CountingReader()
    _ = kept.values(for: [launched(10, execed: false)], read: reader.read)
    #expect(kept.values(for: [launched(10, execed: false)], read: reader.read) == [10: "10#2"])
    #expect(kept.values(for: [launched(10)], read: reader.read) == [10: "10#3"])
    #expect(kept.values(for: [launched(10)], read: reader.read) == [10: "10#3"])
}

@Test func keptFactRetriesAFailedRead() {
    var kept = KeptPerProcess<String>()
    var calls = 0
    let failing: (Int32) -> String? = { _ in calls += 1; return calls == 1 ? nil : "read" }
    #expect(kept.values(for: [launched(10)], read: failing) == [:])
    #expect(kept.values(for: [launched(10)], read: failing) == [10: "read"])
    #expect(kept.values(for: [launched(10)], read: failing) == [10: "read"])
    #expect(calls == 2)
}

@Test func keptFactLeavesWithItsProcess() {
    var kept = KeptPerProcess<String>()
    let reader = CountingReader()
    _ = kept.values(for: (1...100).map { launched($0) }, read: reader.read)
    #expect(kept.count == 100)
    _ = kept.values(for: [launched(7)], read: reader.read)
    #expect(kept.count == 1)
    #expect(kept.values(for: [launched(8)], read: reader.read) == [8: "8#2"])
}

@Test(arguments: ["sh", "bash", "zsh", "python3.12", "Python", "node", "ruby", "perl5.34"])
func keptArgumentsFollowSameInterpreterReexec(name: String) throws {
    let process = identity(42, comm: name, path: "/w/bin/\(name)")
    var kept = KeptPerProcess<ProcessArguments>()
    let firstBytes = procArgs(argc: 3, strings: [name, "-c", "exec \(name) run.sh", "CLAUDE_CODE_SESSION_ID=before"])
    let nextBytes = procArgs(argc: 2, strings: [name, "run.sh", "CLAUDE_CODE_SESSION_ID=after"])
    var calls = 0
    func read(_ pid: Int32) -> ProcessArguments? {
        calls += 1
        return ProcessSample.parseProcArgs(calls == 1 ? firstBytes : nextBytes)
    }
    let before = ProcessListSample(uptimeNanoseconds: 0, processes: [process], taskInfo: [42: counters(0)], ps: [:],
                                   arguments: kept.arguments(for: [process], read: read))
    let after = ProcessListSample(uptimeNanoseconds: second, processes: [process], taskInfo: [42: counters(second)], ps: [:],
                                  arguments: kept.arguments(for: [process], read: read))
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 4, kernelTask: nil)
    let grouped = CommandGroups.assign(rows, arguments: after.arguments)
    #expect(calls == 2)
    #expect(after.arguments[42]?.environment["CLAUDE_CODE_SESSION_ID"] == "after")
    #expect(grouped.rows.first?.command == "run.sh")
    #expect(grouped.groups.first?.name == "run.sh")
}

@Test func keptArgumentsStillCacheOtherExecutables() {
    var kept = KeptPerProcess<ProcessArguments>()
    let processes = [launched(10), launched(11, path: "/w/bin/clang")]
    var calls = 0
    for _ in 0..<3 {
        let arguments = kept.arguments(for: processes) { _ in
            calls += 1
            return ProcessArguments(argv: ["tool", "arg"], environment: [:])
        }
        #expect(arguments.count == 2)
    }
    #expect(calls == 2)
}

@Test func keptArgumentsDoNotReuseStaleShellArgumentsWhenARefreshFails() {
    var kept = KeptPerProcess<ProcessArguments>()
    let process = launched(10, path: "/bin/bash")
    let args = ProcessArguments(argv: ["bash", "first.sh"], environment: [:])
    #expect(kept.arguments(for: [process]) { _ in args } == [10: args])
    #expect(kept.arguments(for: [process]) { _ in nil }.isEmpty)
    #expect(kept.arguments(for: [process]) { _ in args } == [10: args])
}

@Test func keptArgumentsUseCommWhenTheExecutablePathIsUnreadable() {
    var kept = KeptPerProcess<ProcessArguments>()
    let process = identity(42, comm: "Python")
    var calls = 0
    for _ in 0..<2 {
        _ = kept.arguments(for: [process]) { _ in
            calls += 1
            return ProcessArguments(argv: ["python", "run.py"], environment: [:])
        }
    }
    #expect(calls == 2)
}

@Test func keptShellTerminalNamesStayCached() {
    var kept = KeptPerProcess<String>()
    let reader = CountingReader()
    for _ in 0..<3 {
        #expect(kept.values(for: [launched(10, path: "/bin/zsh")], read: reader.read) == [10: "10#1"])
    }
    #expect(reader.calls == [10: 1])
}

@Test func procArgsNoEnvironment() {
    #expect(ProcessSample.parseProcArgs(procArgs(argc: 1, padding: 0, strings: ["tool"]))
            == ProcessArguments(argv: ["tool"], environment: [:]))
}

@Test func procArgsMalformed() {
    #expect(ProcessSample.parseProcArgs([]) == nil)
    #expect(ProcessSample.parseProcArgs([1, 0, 0]) == nil)
    #expect(ProcessSample.parseProcArgs(procArgs(argc: -1, strings: ["tool"])) == nil)
    #expect(ProcessSample.parseProcArgs(procArgs(argc: 3, strings: ["tool", "x"])) == nil)
    #expect(ProcessSample.parseProcArgs(procArgs(argc: Int32.max, strings: [])) == nil)
    // An unterminated exec path or argv invalidates the buffer; only a final environment string is dropped.
    #expect(ProcessSample.parseProcArgs([0, 0, 0, 0] + Array("/bin/tool".utf8)) == nil)
    var cutArgv = procArgs(argc: 2, strings: ["tool", "arg"])
    cutArgv.removeLast()
    #expect(ProcessSample.parseProcArgs(cutArgv) == nil)
    var cut = procArgs(argc: 1, strings: ["tool", "A=1"])
    cut.removeLast()
    #expect(ProcessSample.parseProcArgs(cut) == ProcessArguments(argv: ["tool"], environment: [:]))
}

@Test func snapshotWithoutProcessesOmitsKey() throws {
    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1),
                                load: CPULoad(perCPU: [5], total: 5), intervalSeconds: 1)
    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    #expect(object["processes"] == nil)
}

// MARK: ps and top parsers

@Test func psParsingWithSpaces() throws {
    let output = """
        1  43:12.67  26544 /sbin/launchd
      396  68:16.40 181328 /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds
    20431   0:01.23  51200 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)

    """
    let rows = try ProcessSample.parsePS(output)
    #expect(rows.count == 3)
    #expect(rows[396] == PSRow(counters: ProcessCounters(cpuNanoseconds: 4_096_400_000_000, residentBytes: 181_328 * 1024),
                               comm: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds"))
    #expect(rows[20431]?.comm == "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
    #expect(rows[20431]?.counters == ProcessCounters(cpuNanoseconds: 1_230_000_000, residentBytes: 51_200 * 1024))
    #expect(rows[1]?.counters.cpuNanoseconds == 2_592_670_000_000)
}

@Test func psParsingWithoutComm() throws {
    // What `ProcessReaders.psRows` asks for: pid, time and rss only.
    let rows = try ProcessSample.parsePS("    1  43:12.67  26544\n  396  68:16.40 181328\n")
    #expect(rows[1] == PSRow(counters: ProcessCounters(cpuNanoseconds: 2_592_670_000_000, residentBytes: 26_544 * 1024), comm: ""))
    #expect(rows[396]?.counters.residentBytes == 181_328 * 1024)
}

@Test func psUnparsableLineIsAnError() {
    #expect(throws: ProcessSampleError.unparsable(source: .ps, line: "  12  soon  100 x")) {
        try ProcessSample.parsePS("  12  soon  100 x\n")
    }
}

@Test func psTimeFormats() {
    #expect(ProcessSample.psTimeNanoseconds("0:01.23") == 1_230_000_000)
    #expect(ProcessSample.psTimeNanoseconds("223:18.46") == 13_398_460_000_000)
    #expect(ProcessSample.psTimeNanoseconds("1:02:03.50") == 3_723_500_000_000)
    #expect(ProcessSample.psTimeNanoseconds("12.5") == 12_500_000_000)
    #expect(ProcessSample.psTimeNanoseconds("1:xx.00") == nil)
    #expect(ProcessSample.psTimeNanoseconds("") == nil)
}

@Test func psTimeRejectsNonFinite() {
    for text in ["inf", "nan", "1e300", "1:inf", "1e300:00"] {
        #expect(ProcessSample.psTimeNanoseconds(text) == nil, "\(text)")
    }
    // Double alone reads hex, a sign and stray dots; ps prints none of them.
    for text in ["0x1A", "+5", "1:+2.00", "-0", "1.2.3", ".5", "5.", "1::2", " 5"] {
        #expect(ProcessSample.psTimeNanoseconds(text) == nil, "\(text)")
    }
    #expect(throws: ProcessSampleError.unparsable(source: .ps, line: "   12  inf  100 x")) {
        try ProcessSample.parsePS("   12  inf  100 x\n")
    }
    // rss is KB: UInt64.max KB has no byte count.
    #expect(throws: ProcessSampleError.unparsable(source: .ps, line: "   12  0:01.00  18446744073709551615 x")) {
        try ProcessSample.parsePS("   12  0:01.00  18446744073709551615 x\n")
    }
}

@Test func topFieldsRejectMalformed() {
    for line in ["0   nan  34M", "0   -1  34M", "0   1.0  -5K", "0   1.0  1e30T", "0   1.0  nanM"] {
        #expect(throws: ProcessSampleError.unparsable(source: .top, line: line)) {
            try ProcessSample.parseTopKernelTask("PID %CPU MEM\n\(line)\n")
        }
    }
    for text in ["-5K", "1e30T", "nanM", "infG"] {
        #expect(ProcessSample.topBytes(text) == nil, "\(text)")
    }
    #expect(ProcessSample.topBytes("1.5K") == 1536)
}

/// Bad cached top data must not discard the independently measured process rows.
@Test func invalidKernelTaskKeepsOtherProcessRows() throws {
    let processes = [identity(0, path: nil), identity(42)]
    let s = sample(at: 10 * second, processes, taskInfo: [42: counters(0)])
    let t = sample(at: 11 * second, processes, taskInfo: [42: counters(second)])
    for cpu in [1e300, 1.7e308, 201, -.infinity, .infinity, .nan, -1] {
        let rows = try ProcessSample.usage(before: s, after: t, cpuCount: 2,
                                           kernelTask: KernelTaskSample(cpuPercentPerCore: cpu, residentBytes: 0))
        #expect(rows.map(\.pid) == [42])
        #expect(rows.map(\.cpuPercent) == [50])
    }
    let rows = try ProcessSample.usage(before: s, after: t, cpuCount: 2,
                                       kernelTask: KernelTaskSample(cpuPercentPerCore: 200, residentBytes: 0))
    #expect(rows.map(\.cpuPercent) == [100, 50])
}

/// `top -l 2 -s 1 -pid 0 -stats pid,cpu,mem`, header block trimmed; the first sample covers no window.
private let topPid0Output = """
PID %CPU MEM
0   0.0  34M
Processes: 1165 total, 4 running, 1161 sleeping, 6890 threads
CPU usage: 27.17% user, 4.73% sys, 68.9% idle

PID %CPU MEM
0   8.4  34M-

"""

@Test func topPid0Parsing() throws {
    let kernel = try ProcessSample.parseTopKernelTask(topPid0Output)
    #expect(kernel == KernelTaskSample(cpuPercentPerCore: 8.4, residentBytes: 34 << 20))
}

@Test func topWithoutPid0IsAnError() {
    #expect(throws: ProcessSampleError.missingKernelTask) {
        try ProcessSample.parseTopKernelTask("PID %CPU MEM\n")
    }
}

@Test func topMemoryUnits() {
    #expect(ProcessSample.topBytes("34M-") == 34 << 20)
    #expect(ProcessSample.topBytes("1536K+") == 1536 << 10)
    #expect(ProcessSample.topBytes("2G") == 2 << 30)
    #expect(ProcessSample.topBytes("512B") == 512)
    #expect(ProcessSample.topBytes("12Q") == nil)
}

/// Rows 120–122 grouped by repo and by session: 120 in a Claude Code session, 121 in a tmux session
/// whose name runs past the column, 122 in none.
private func sessioned() -> (rows: [ProcessUsage], repoGroups: [RepoGroup], sessionGroups: [SessionGroup]) {
    let repos = assign([row(120, cpu: 3, name: "claude"), row(121, cpu: 2, name: "zsh"), row(122, cpu: 1, name: "vim")],
                       cwd: [120: "/work/alpha", 121: "/work/alpha", 122: "/work/beta"])
    let registry = RegistryEntry(pid: 120, sessionId: "aaaaaaaa-1111-4111-8111-111111111111", name: "orch-line",
                                 cwd: "/work/alpha", procStartSeconds: 1_000)
    let sessions = SessionGroups.assign(repos.rows, sources: SessionSources(
        registry: [registry], startSeconds: [120: 1_000, 121: 1_000, 122: 1_000], environmentSessionIDs: [:],
        tmuxPanes: [121: "a-very-long-tmux-session-name"], tty: [:], ownUID: 501))
    return (sessions.rows, repos.groups, sessions.groups)
}

@Test func sessionColumnInTheRepoTable() {
    let (rows, repoGroups, sessionGroups) = sessioned()
    let lines = ProcessSample.table(rows, groups: repoGroups, sessionGroups: sessionGroups)
        .split(separator: "\n").map(String.init)
    #expect(lines == ["    PID   PPID  USER     CPU   MEM  SESSION                   NAME",
                      "alpha  5.0%  2.0K  2 processes",
                      "    120      1  alice   3.0%  1.0K  orch-line                 claude",
                      "    121      1  alice   2.0%  1.0K  a-very-long-tmux-sessio…  zsh",
                      "beta  1.0%  1.0K  1 process",
                      "    122      1  alice   1.0%  1.0K  -                         vim"])
    // With no session groups the table is Step 1's.
    #expect(!ProcessSample.table(rows, groups: repoGroups).contains("SESSION"))
}

@Test func sessionJSON() throws {
    let (rows, repoGroups, sessionGroups) = sessioned()
    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1),
                                load: CPULoad(perCPU: [0], total: 0), intervalSeconds: 1,
                                processes: rows, repoGroups: repoGroups, sessionGroups: sessionGroups)
    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    #expect(Set(object.keys) == ["coreTypes", "totalBusyPercent", "intervalSeconds", "processes", "repoGroups", "sessionGroups",
                                 "unattributedCpuPercent"])
    let processes = try #require(object["processes"] as? [[String: Any]])
    let session = try #require(processes[0]["session"] as? [String: String])
    #expect(session == ["name": "orch-line", "kind": "claude", "id": "aaaaaaaa-1111-4111-8111-111111111111"])
    #expect((processes[1]["session"] as? [String: String])?["kind"] == "tmux")
    #expect(processes[2]["session"] is NSNull)
    let groups = try #require(object["sessionGroups"] as? [[String: Any]])
    #expect(groups.map { Set($0.keys) } == Array(repeating: ["name", "cpuPercent", "exitedChildrenCpuPercent", "residentBytes", "disk",
                                                             "network", "pids", "subgroups"], count: 3))
    #expect(groups.map { $0["name"] as? String } == ["orch-line", "a-very-long-tmux-session-name", SessionGroups.noSession])
    #expect(groups.map { $0["pids"] as? [Int] } == [[120], [121], [122]])
}

@Test func jsonCarriesAppAndSubgroups() throws {
    func process(_ pid: Int32, _ path: String, cpu: Double) -> ProcessUsage {
        ProcessUsage(pid: pid, ppid: 1, uid: 501, user: "alice", path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                     cpuPercent: cpu, residentBytes: 1024, source: .libproc)
    }
    let rows = [process(130, "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container",
                        cpu: 2.5),
                process(131, "/usr/libexec/trustd", cpu: 0.1), process(132, "/usr/bin/vim", cpu: 0.2)]
    let grouped = assign(rows, cwd: [130: "/tmp", 131: "/tmp", 132: "/work/alpha"])
    let out = CatchAllBreakout.apply(rows: grouped.rows, repoGroups: grouped.groups, sessionGroups: [],
                                     thresholds: CatchAllBreakout.Thresholds(physicalMemoryBytes: 1 << 37,
                                                                             machineDiskBytesPerSecond: nil,
                                                                             machineNetworkBytesPerSecond: nil),
                                     isAppBundle: { _ in true })
    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1),
                                load: CPULoad(perCPU: [0], total: 0), intervalSeconds: 1,
                                processes: out.rows, repoGroups: out.repoGroups)
    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    let processes = try #require(object["processes"] as? [[String: Any]])
    #expect(processes.map { $0["app"] as? String } == ["Firefox", nil, nil])
    #expect(processes[1]["app"] is NSNull)
    let groups = try #require(object["repoGroups"] as? [[String: Any]])
    #expect(groups.map { $0["name"] as? String } == ["alpha", RepoGroups.notInARepo])
    #expect((groups[0]["subgroups"] as? [Any])?.isEmpty == true)
    let subgroups = try #require(groups[1]["subgroups"] as? [[String: Any]])
    #expect(subgroups.map { $0["kind"] as? String } == ["app", "other"])
    #expect(subgroups.map { $0["name"] as? String } == ["Firefox", "1 other process"])
    #expect(Set(subgroups[0].keys) == ["name", "kind", "cpuPercent", "exitedChildrenCpuPercent", "residentBytes", "disk",
                                       "network", "pids"])
    #expect(subgroups[0]["cpuPercent"] as? Double == 2.5)
    #expect(subgroups.map { $0["pids"] as? [Int] } == [[130], [131]])
    #expect(groups[1]["pids"] as? [Int] == [130, 131])

    let lines = ProcessSample.table(out.rows, groups: out.repoGroups).split(separator: "\n").map(String.init)
    #expect(lines == ["    PID   PPID  USER     CPU   MEM  NAME",
                      "alpha  0.2%  1.0K  1 process",
                      "    132      1  alice   0.2%  1.0K  vim",
                      "Not in a repo  2.6%  2.0K  2 processes",
                      "  Firefox  2.5%  1.0K  1 process",
                      "    130      1  alice   2.5%  1.0K    plugin-container",
                      "  1 other process  0.1%  1.0K  1 process",
                      "    131      1  alice   0.1%  1.0K    trustd"])
}
