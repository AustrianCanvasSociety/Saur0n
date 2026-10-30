// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the user quits, force-quits, pauses or resumes a process from the window knowing what goes down with it
// (Phase 5 Step 5) — everything under it in the tree by kind, the processes connected to a port it listens on, the
// row looked up again by pid and start time before any signal, children before parents, EPERM offered to the
// administrator. Method: recorded trees and socket listings built in code with documentation values; the signals go
// through a stub that records them.

private func row(_ pid: Int32, _ name: String, parent: Int32 = 1, uid: UInt32 = 501, start: UInt64? = nil,
                 path: String? = nil, readable: String? = nil, app: String? = nil, session: SessionInfo? = nil,
                 vm: String? = nil) -> ProcessUsage {
    var usage = ProcessUsage(pid: pid, ppid: parent, uid: uid, user: uid == 0 ? "root" : "user", path: path ?? "/usr/bin/\(name)",
                             name: name, cpuPercent: 0, residentBytes: 0, source: .libproc)
    usage.readableName = readable
    usage.app = app
    usage.session = session
    usage.vm = vm.map { VMUsage(name: $0, vcpus: 4, shareOfAllotted: 0) }
    usage.startMicroseconds = start ?? UInt64(pid) * 1000
    return usage
}

private func identity(_ row: ProcessUsage, start: UInt64? = nil) -> ProcessIdentity {
    ProcessIdentity(pid: row.pid, ppid: row.ppid, uid: row.uid, user: row.user,
                    startMicroseconds: start ?? row.startMicroseconds, comm: row.name, path: row.path)
}

/// Records every signal and app call in order; `refuse` pids throw EPERM.
private final class Recorder: ProcessSignaller, @unchecked Sendable {
    var calls: [String] = []
    var refuse: Set<Int32> = []

    func signal(_ sig: Int32, to pid: Int32) throws {
        if refuse.contains(pid) { throw ProcessControlError.permissionDenied }
        calls.append("\(sig) \(pid)")
    }

    func terminator(_ answer: Bool?) -> AppTerminator {
        AppTerminator(terminate: { [self] pid in calls.append("terminate \(pid)"); return answer },
                      forceTerminate: { [self] pid in calls.append("forceTerminate \(pid)"); return answer })
    }
}

private let session = SessionInfo(name: "saur0n 0123abcd", kind: .claude, id: "0123abcd-0000")

/// A terminal tab: login → zsh → claude (a session) → bash → swift test; pids 100–104.
private let terminalTree: [ProcessUsage] = [
    row(100, "login", parent: 90, uid: 0, path: "/usr/bin/login"),
    row(101, "zsh", parent: 100, path: "/bin/zsh"),
    row(102, "claude", parent: 101, session: session),
    row(103, "bash", parent: 102, path: "/bin/bash", session: session),
    row(104, "swift-test", parent: 103, readable: "test runner: swift", session: session),
]

// MARK: - DoD

@Test func dependantsOfATerminalRowAreEveryShellAndSessionUnderIt() {
    let dependants = ProcessControl.dependants(of: [100], rows: terminalTree)
    #expect(dependants.map(\.pid) == [101, 102, 103, 104])
    #expect(dependants.map(\.kind) == [.shell, .claudeSession, .shell, .testRun])
    #expect(dependants[1].name == "saur0n 0123abcd")    // a session by its name
    #expect(dependants[3].name == "swift-test (test runner: swift)")
    #expect(ProcessControl.summary(dependants) == "Also ends 4: 1 Claude Code session, 1 test run, 2 shells")
}

/// The proxy listens on 127.0.0.1:8021 and ::1.8021 (as `nettop -x -L 1 -n -J state` printed it, probe 2026-10-21);
/// three sessions hold a connection to it, one of them twice; a fourth talks to another port.
private let proxyListing = """
    ,state,
    launchd.1,,
    tcp4 127.0.0.1:631<->*:*,Listen,
    cli-proxy.500,,
    tcp4 127.0.0.1:8021<->*:*,Listen,
    tcp6 ::1.8021<->*.*,Listen,
    tcp4 127.0.0.1:8021<->127.0.0.1:50001,Established,
    tcp4 127.0.0.1:8021<->127.0.0.1:50002,Established,
    tcp4 192.0.2.10:50100<->198.51.100.20:443,Established,
    claude.600,,
    tcp4 127.0.0.1:50001<->127.0.0.1:8021,Established,
    tcp4 127.0.0.1:50003<->127.0.0.1:8021,Established,
    claude.601,,
    tcp4 127.0.0.1:50002<->127.0.0.1:8021,Established,
    claude.602,,
    tcp6 ::1.50004<->::1.8021,Established,
    claude.603,,
    tcp4 127.0.0.1:50005<->127.0.0.1:9000,Established,
    curl.604,,
    tcp4 192.0.2.30:50006<->198.51.100.20:8021,Established,

    """

@Test func aProxyWithNoChildrenListsItsConnectedProcessesUnderUsedBy() throws {
    let listing = try SocketListing(text: proxyListing)
    let rows = [row(500, "cli-proxy"), row(600, "claude", session: session), row(601, "claude"), row(603, "claude")]
    let usedBy = ProcessControl.usedBy(500, listing: listing, rows: rows)
    #expect(usedBy.map(\.pid) == [600, 601, 602])
    #expect(usedBy.map(\.kind) == [.claudeSession, .process, .process])
    #expect(usedBy.map(\.name) == ["saur0n 0123abcd", "claude", "claude"])    // 602 is not a row: its nettop name
    #expect(ProcessControl.dependants(of: [500], rows: rows).isEmpty)
}

@Test func aStandaloneProcessListsNothing() throws {
    let rows = [row(700, "sleep"), row(701, "zsh")]
    let listing = try SocketListing(text: proxyListing)
    #expect(ProcessControl.dependants(of: [700], rows: rows).isEmpty)
    #expect(ProcessControl.usedBy(700, listing: listing, rows: rows).isEmpty)
    #expect(ProcessControl.summary([]) == "")
    #expect(ProcessControl.confirmTitle(action: .quit, dependantCount: 0) == "Quit")
}

@Test func anAppRowTerminatesAndABareProcessIsSignalled() {
    let app = row(800, "Firefox", app: "Firefox"), bare = row(801, "sleep")
    #expect(ProcessControl.means(for: .quit, row: app) == .terminateApp)
    #expect(ProcessControl.means(for: .forceQuit, row: app) == .forceTerminateApp)
    #expect(ProcessControl.means(for: .quit, row: bare) == .signal(SIGTERM))
    #expect(ProcessControl.means(for: .forceQuit, row: bare) == .signal(SIGKILL))
    for target in [app, bare] {
        #expect(ProcessControl.means(for: .pause, row: target) == .signal(SIGSTOP))
        #expect(ProcessControl.means(for: .resume, row: target) == .signal(SIGCONT))
    }
}

@Test func aPidWhoseStartTimeChangedIsRefusedAndNothingIsSignalled() {
    let target = row(900, "sleep")
    let reused = identity(target, start: target.startMicroseconds + 1)
    #expect(ProcessControl.verify(ProcessTable.rowID(target), in: [reused]) == nil)
    #expect(ProcessControl.verify(ProcessTable.rowID(target), in: [identity(target)]) == identity(target))
    let recorder = Recorder()
    let outcomes = ProcessControl.perform(.quit, on: [target], current: [reused], signaller: recorder,
                                          terminator: recorder.terminator(nil))
    #expect(recorder.calls.isEmpty)
    #expect(outcomes == [ProcessControl.Outcome(pid: 900, result: .failure(.reused))])
    #expect(ProcessControl.message(.reused, name: "sleep", pid: 900) == "pid 900 now belongs to another process")
}

@Test func aGroupSignalsChildrenBeforeParents() {
    // 10 → 11 → 13, 10 → 12; given in any order, each child before its parent (siblings by pid), the target last.
    let rows = [row(10, "bash"), row(11, "bash", parent: 10), row(12, "sleep", parent: 10), row(13, "sleep", parent: 11)]
    #expect(ProcessControl.order([10, 11, 12, 13], rows: rows) == [13, 11, 12, 10])
    #expect(ProcessControl.order([12, 10], rows: rows) == [12, 10])
    let recorder = Recorder()
    let outcomes = ProcessControl.perform(.forceQuit, on: rows.reversed(), current: rows.map { identity($0) },
                                          signaller: recorder, terminator: recorder.terminator(nil))
    #expect(recorder.calls == ["\(SIGKILL) 13", "\(SIGKILL) 11", "\(SIGKILL) 12", "\(SIGKILL) 10"])
    #expect(outcomes.map(\.pid) == [13, 11, 12, 10])
}

@Test(arguments: [ProcessControl.Action.pause, .quit, .forceQuit, .resume])
func aSparedWrapperDoesNotBreakChildrenFirstSignalOrder(_ action: ProcessControl.Action) {
    var rows = [row(900, "bash"), row(901, "claude", parent: 900), row(902, "worker", parent: 901)]
    rows[1].usersOwn = true
    let reach = ProcessControl.select([rows[0]], rows: rows, ownPid: own,
                                      sparing: ProcessControl.barSparing(exempt: []))
    let targets = reach.targets + ProcessControl.resolve(reach.alsoEnds, in: rows)
    #expect(targets.map(\.pid) == [900, 902])
    #expect(ProcessControl.order([900, 902], rows: rows) == [902, 900])
    let recorder = Recorder()
    let outcomes = ProcessControl.perform(action, on: targets, current: rows.map { identity($0) },
                                          signaller: recorder, terminator: recorder.terminator(nil), ownPid: own)
    #expect(outcomes.map(\.pid) == [902, 900])
    #expect(recorder.calls == ["\(action.signal) 902", "\(action.signal) 900"])
}

@Test(arguments: [ProcessControl.Action.pause, .quit, .forceQuit, .resume])
func sharedActionsKeepTheExistingBranchAndSiblingOrder(_ action: ProcessControl.Action) {
    let rows = [row(10, "bash"), row(11, "bash", parent: 10), row(12, "sleep", parent: 10), row(13, "sleep", parent: 11)]
    let recorder = Recorder()
    let outcomes = ProcessControl.perform(action, on: rows.reversed(), current: rows.map { identity($0) },
                                          signaller: recorder, terminator: recorder.terminator(nil))
    #expect(outcomes.map(\.pid) == [13, 11, 12, 10])
    #expect(recorder.calls == [13, 11, 12, 10].map { "\(action.signal) \($0)" })
}

@Test func orderingEndsAnUnselectedParentLoopWithoutAddingItsPids() {
    let rows = [row(900, "bash", parent: 901), row(901, "wrapper", parent: 902), row(902, "wrapper", parent: 901)]
    #expect(ProcessControl.order([900], rows: rows) == [900])
}

@Test func permissionDeniedMapsToTheAdministratorOffer() {
    let recorder = Recorder()
    recorder.refuse = [1000]
    let rows = [row(1000, "sleep", uid: 0), row(1001, "sleep")]
    let outcomes = ProcessControl.perform(.quit, on: rows, current: rows.map { identity($0) }, signaller: recorder,
                                          terminator: recorder.terminator(nil))
    // Continues past the refusal.
    #expect(outcomes == [ProcessControl.Outcome(pid: 1000, result: .failure(.permissionDenied)),
                         ProcessControl.Outcome(pid: 1001, result: .success(()))])
    #expect((try? ProcessControl.administratorCommand(signal: SIGTERM, pid: 123)) == "kill -TERM 123")
    #expect((try? ProcessControl.administratorCommand(signal: SIGKILL, pid: 123)) == "kill -KILL 123")
    #expect((try? ProcessControl.administratorCommand(signal: SIGSTOP, pid: 7)) == "kill -STOP 7")
    #expect((try? ProcessControl.administratorCommand(signal: SIGCONT, pid: 7)) == "kill -CONT 7")
}

@Test func aStoppedStatusReadsAsPaused() {
    let rows = [row(1100, "yes"), row(1101, "sleep")]
    let group = RepoGroup(name: "demo", root: "/tmp/demo", cpuPercent: 0, exitedChildrenCpuPercent: 0, residentBytes: 0,
                          pids: [1100, 1101])
    let lines = ProcessTable.lines(rows: rows, repoGroups: [group], sessionGroups: [], grouping: .repo,
                                   unattributedCpuPercent: nil, pausedPids: [1100])
    let members = lines.first?.children ?? []
    #expect(members.map(\.paused) == [true, false])
    #expect(members.first?.pausedIdentifier == "paused-1100")
    // The process status: this process runs, a stopped child reads as paused, a pid that is gone reads nil.
    #expect(ProcessControl.isStopped(getpid()) == false)
    #expect(ProcessControl.isStopped(Int32.max) == nil)
}

@Test func aStoppedChildReadsAsPausedFromItsStatus() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
    #expect(kill(child.processIdentifier, SIGSTOP) == 0)
    var stopped: Bool?
    for _ in 0..<50 {
        stopped = ProcessControl.isStopped(child.processIdentifier)
        if stopped == true { break }
        usleep(20_000)
    }
    #expect(stopped == true)
    #expect(kill(child.processIdentifier, SIGCONT) == 0)
    for _ in 0..<50 {
        stopped = ProcessControl.isStopped(child.processIdentifier)
        if stopped == false { break }
        usleep(20_000)
    }
    #expect(stopped == false)
}

@Test func anActionWhileTheRefreshIsPausedStillUsesFreshRows() {
    // The window's last refresh still shows 1200; the fresh process list no longer has it.
    let shown = [row(1200, "sleep"), row(1201, "sleep")]
    let fresh = [identity(shown[1])]
    let recorder = Recorder()
    let outcomes = ProcessControl.perform(.quit, on: shown, current: fresh, signaller: recorder,
                                          terminator: recorder.terminator(nil))
    #expect(recorder.calls == ["\(SIGTERM) 1201"])
    #expect(outcomes.first == ProcessControl.Outcome(pid: 1200, result: .failure(.gone)))
    #expect(ProcessControl.message(.gone, name: "sleep", pid: 1200) == "sleep (pid 1200) is gone")
}

@Test func socketListingParsesTheRecordedNettopBlocks() throws {
    let listing = try SocketListing(text: proxyListing + "garbage line\ntcp4 no-arrow,Listen,\n")
    #expect(listing.sockets[1] == [Socket(proto: "tcp4", local: "127.0.0.1:631", remote: "*:*", state: "Listen")])
    #expect(listing.sockets[500]?.count == 5)
    #expect(listing.sockets[500]?[1] == Socket(proto: "tcp6", local: "::1.8021", remote: "*.*", state: "Listen"))
    #expect(listing.sockets[602] == [Socket(proto: "tcp6", local: "::1.50004", remote: "::1.8021", state: "Established")])
    #expect(listing.sockets[604]?.count == 1)
    // A UDP socket has no state.
    let udp = try SocketListing(text: "mDNSResponder.400,,\nudp4 *:5353<->*:*,,\n")
    #expect(udp.sockets[400] == [Socket(proto: "udp4", local: "*:5353", remote: "*:*", state: "")])
    #expect(throws: NetworkActivityError.unreadable) { try SocketListing(text: ",state,\ntcp4 1.2.3.4:1<->*:*,Listen,\n") }
}

/// A name holding commas, dots, spaces and a non-ASCII letter (the gate's live reproduction): its sockets stay on its pid.
@Test func socketListingReadsAProcessLineFromTheRight() throws {
    let listing = try SocketListing(text: """
        ,state,
        Foo, Inc.ä.1800,,
        tcp4 127.0.0.1:8030<->*:*,Listen,
        Resilio Sync.1801,,
        tcp4 127.0.0.1:50020<->127.0.0.1:8030,Established,
        5,6.1802,,
        udp4 *:5353<->*:*,,
        """)
    #expect(listing.names == [1800: "Foo, Inc.ä", 1801: "Resilio Sync", 1802: "5,6"])
    #expect(listing.sockets[1800] == [Socket(proto: "tcp4", local: "127.0.0.1:8030", remote: "*:*", state: "Listen")])
    #expect(listing.sockets[1801]?.first?.state == "Established")
    #expect(listing.sockets[1802] == [Socket(proto: "udp4", local: "*:5353", remote: "*:*", state: "")])
    #expect(listing.sockets[5] == nil && listing.sockets[6] == nil)
    #expect(ProcessControl.usedBy(1800, listing: listing, rows: []).map(\.pid) == [1801])
}

// MARK: - Never signalled: kernel_task, launchd, Saur0n itself

/// Saur0n's pid in these trees.
private let own: Int32 = 1500

@Test func kernelTaskLaunchdAndSaur0nItselfAreRefusedAndNeverSignalled() {
    let rows = [row(0, "kernel_task", parent: 0, uid: 0), row(1, "launchd", parent: 0, uid: 0), row(own, "Saur0nApp")]
    for action in [ProcessControl.Action.quit, .forceQuit, .pause, .resume] {
        let recorder = Recorder()
        let outcomes = ProcessControl.perform(action, on: rows, current: rows.map { identity($0) }, signaller: recorder,
                                              terminator: recorder.terminator(true), ownPid: own)
        #expect(recorder.calls.isEmpty)
        #expect(outcomes.map(\.pid).sorted() == [0, 1, own])
        #expect(outcomes.allSatisfy { if case .failure(.refused) = $0.result { true } else { false } })
    }
    // `kill(2)` reads pid -1 as every process and a negative pid as a process group.
    #expect(ProcessControl.refusal(-1, ownPid: own) != nil)
    #expect(ProcessControl.refusal(-500, ownPid: own) != nil)
    #expect(ProcessControl.refusal(0, ownPid: own) == "kernel_task and launchd can't be ended")
    #expect(ProcessControl.refusal(1, ownPid: own) == "kernel_task and launchd can't be ended")
    #expect(ProcessControl.refusal(own, ownPid: own) == "Saur0n itself is left running")
    #expect(ProcessControl.refusal(2, ownPid: own) == nil)
    #expect(ProcessControl.message(.refused(reason: "Saur0n itself is left running"), name: "Saur0nApp", pid: own)
            == "Saur0nApp (pid \(own)): Saur0n itself is left running")
}

@Test func theAdministratorCommandIsNeverBuiltForARefusedPid() {
    for pid: Int32 in [0, 1, -1, own] {
        #expect(throws: ProcessControlError.self) {
            try ProcessControl.administratorCommand(signal: SIGTERM, pid: pid, ownPid: own)
        }
    }
    #expect((try? ProcessControl.administratorCommand(signal: SIGTERM, pid: 123, ownPid: own)) == "kill -TERM 123")
}

@Test(arguments: [Int32(0), 1, own])
func anAdministratorBatchReportsRefusedPidsWithoutRunningAPartialCommand(_ pid: Int32) {
    let refused = row(pid, "protected")
    let batch = ProcessControl.AdministratorBatch(signal: SIGTERM, rows: [row(123, "sleep"), refused], ownPid: own)
    #expect(batch.command == nil)
    let reason = ProcessControl.refusal(pid, ownPid: own)!
    #expect(batch.error == ProcessControl.message(.refused(reason: reason), name: refused.name, pid: pid))
}

@Test func anAdministratorBatchExplainsAnEmptySelection() {
    let batch = ProcessControl.AdministratorBatch(signal: SIGTERM, rows: [], ownPid: own)
    #expect(batch.command == nil)
    #expect(batch.error == "no processes remain for the administrator action")
}

@Test func anAdministratorBatchKeepsEveryAllowedCommand() {
    let batch = ProcessControl.AdministratorBatch(signal: SIGSTOP, rows: [row(123, "sleep"), row(124, "sleep")],
                                                  ownPid: own)
    #expect(batch.command == "kill -STOP 123; kill -STOP 124")
    #expect(batch.error == nil)
}

@Test func aGroupHoldingSaur0nDropsItAndSignalsTheRest() {
    // A repo group: zsh 1600 → swift-run 1601 → Saur0nApp (own) → nettop 1502; and sleep 1602 beside them.
    let rows = [row(1600, "zsh"), row(1601, "swift-run", parent: 1600), row(own, "Saur0nApp", parent: 1601),
                row(1602, "sleep", parent: 1600)]
    let selection = ProcessControl.select(rows, rows: rows, ownPid: own)
    #expect(selection.targets.map(\.pid) == [1600, 1601, 1602])
    #expect(selection.alsoEnds.isEmpty)
    #expect(selection.left == ["Saur0n itself is left running"])
    let recorder = Recorder()
    _ = ProcessControl.perform(.quit, on: selection.targets, current: rows.map { identity($0) }, signaller: recorder,
                               terminator: recorder.terminator(nil), ownPid: own)
    #expect(recorder.calls == ["\(SIGTERM) 1601", "\(SIGTERM) 1602", "\(SIGTERM) 1600"])
    // Saur0n under a quit shell: it is left out of "Also ends" too.
    let underShell = ProcessControl.select([rows[0]], rows: rows, ownPid: own)
    #expect(underShell.alsoEnds.map(\.pid) == [1601, 1602])
    #expect(underShell.left == ["Saur0n itself is left running"])
}

@Test(arguments: [ProcessControl.Action.quit, .forceQuit, .pause, .resume])
func aShellHoldingSaur0nDoesNotReachItsHelpers(_ action: ProcessControl.Action) {
    let rows = [row(1600, "zsh"), row(own, "Saur0nApp", parent: 1600),
                row(1502, "nettop", parent: own), row(1503, "helper", parent: 1502),
                row(1602, "sleep", parent: 1600)]
    let selection = ProcessControl.select([rows[0]], rows: rows, ownPid: own)
    #expect(selection.targets.map(\.pid) == [1600])
    #expect(selection.alsoEnds.map(\.pid) == [1602])
    #expect(selection.left == ["Saur0n itself is left running"])
    let targets = selection.targets + ProcessControl.resolve(selection.alsoEnds, in: rows)
    let recorder = Recorder()
    _ = ProcessControl.perform(action, on: targets, current: rows.map { identity($0) }, signaller: recorder,
                               terminator: recorder.terminator(nil), ownPid: own)
    #expect(recorder.calls == ["\(action.signal) 1602", "\(action.signal) 1600"])
    // Listing a tree without selecting an action still describes all its descendants.
    #expect(ProcessControl.dependants(of: [1600], rows: rows).map(\.pid) == [own, 1502, 1503, 1602])
}

@Test func anExplicitlySelectedMonitorHelperStillReachesItsOwnChildren() {
    let rows = [row(1600, "zsh"), row(own, "Saur0nApp", parent: 1600),
                row(1502, "nettop", parent: own), row(1503, "helper", parent: 1502)]
    let selection = ProcessControl.select([rows[0], rows[2]], rows: rows, ownPid: own)
    #expect(selection.targets.map(\.pid) == [1600, 1502])
    #expect(selection.alsoEnds.map(\.pid) == [1503])
    #expect(selection.left == ["Saur0n itself is left running"])
}

@Test func aCatchAllHoldingKernelTaskAndLaunchdDropsBoth() {
    // "Also ends" from kernel_task or launchd would list every process: they leave the targets before the walk.
    let rows = [row(0, "kernel_task", parent: 0, uid: 0), row(1, "launchd", parent: 0, uid: 0),
                row(1700, "sleep"), row(1701, "zsh"), row(1702, "sleep", parent: 1701)]
    let selection = ProcessControl.select([rows[0], rows[1], rows[2]], rows: rows, ownPid: own)
    #expect(selection.targets.map(\.pid) == [1700])
    #expect(selection.alsoEnds.isEmpty)
    #expect(selection.left == ["kernel_task and launchd can't be ended"])
    // Alone, nothing is left to act on: the window disables its buttons.
    let alone = ProcessControl.select([rows[0]], rows: rows, ownPid: own)
    #expect(alone.targets.isEmpty && alone.alsoEnds.isEmpty)
    #expect(ProcessControl.select([rows[2]], rows: rows, ownPid: own).left.isEmpty)
}

// MARK: - A warning's Stop and Pause leave the user's session standing (the 2026-10-26 batch)

/// The user's interactive session as a warning sees it: `claude` 800 with the filter 801 and its shell 802 (all
/// `usersOwn`), the workload below them (803, 804 with a child 805), and a login shell 810 beside them.
private func sessionRows() -> [ProcessUsage] {
    var rows = [row(810, "zsh"), row(800, "claude", parent: 810), row(801, "bash", parent: 800), row(802, "zsh", parent: 801),
                row(803, "node", parent: 802), row(804, "node", parent: 802), row(805, "esbuild", parent: 804)]
    for i in rows.indices where [810, 800, 801, 802].contains(rows[i].pid) { rows[i].usersOwn = true }
    return rows
}

private func spareTheSession(_ row: ProcessUsage) -> String? { row.usersOwn ? "your terminal session is left running" : nil }

@Test func aDependantKeepsTheStartTimeItWasListedWith() {
    let dependants = ProcessControl.dependants(of: [100], rows: terminalTree)
    #expect(dependants.map(\.startMicroseconds) == [101_000, 102_000, 103_000, 104_000])
}

@Test func sparingTheSessionDropsItsRootAndWrappersFromTargetsAndFromWhatGoesDownWithThem() {
    let rows = sessionRows()
    // A session warning names the whole group; the root, the filter, its shell and the login shell are not acted on.
    let selection = ProcessControl.select(rows, rows: rows, ownPid: own, sparing: spareTheSession)
    #expect(selection.targets.map(\.pid) == [803, 804, 805])
    #expect(selection.alsoEnds.isEmpty)
    #expect(selection.spared.map(\.pid) == [810, 800, 801, 802])
    #expect(selection.left == ["your terminal session is left running"])
    // A target whose parent is spared: the walk goes down, never up, so the parent stays out.
    let one = ProcessControl.select([rows[5]], rows: rows, ownPid: own, sparing: spareTheSession)
    #expect(one.targets.map(\.pid) == [804] && one.alsoEnds.map(\.pid) == [805] && one.spared.isEmpty)
}

@Test func aSparedProcessBelowATargetIsNotReintroducedAsADependant() {
    // The user's own interactive session started below the workload: a protected row under a target stays out of
    // "Also ends", and is named among the processes left running.
    var rows = [row(900, "run.sh", path: "/bin/bash"), row(901, "claude", parent: 900), row(902, "node", parent: 901)]
    rows[1].usersOwn = true
    let selection = ProcessControl.select([rows[0]], rows: rows, ownPid: own, sparing: spareTheSession)
    #expect(selection.targets.map(\.pid) == [900])
    #expect(selection.alsoEnds.map(\.pid) == [902])
    #expect(selection.spared.map(\.pid) == [901] && selection.left == ["your terminal session is left running"])
}

@Test func withoutSparingTheProcessMenuStillReachesEverythingUnderARow() {
    let rows = sessionRows()
    let selection = ProcessControl.select([rows[1]], rows: rows, ownPid: own)
    #expect(selection.targets.map(\.pid) == [800])
    #expect(selection.alsoEnds.map(\.pid) == [801, 802, 803, 804, 805])
    #expect(selection.spared.isEmpty && selection.left.isEmpty)
}

@Test func theSheetsDependantsResolveByPidAndStartTimeSoAReusedPidIsNotANewTarget() {
    let rows = sessionRows()
    let listed = ProcessControl.dependants(of: [803, 804], rows: rows)    // 805, with its start time
    // Later, pid 805 belongs to another process.
    var later = rows
    later[later.firstIndex { $0.pid == 805 }!].startMicroseconds = 999_000_000
    #expect(ProcessControl.resolve(listed, in: rows).map(\.pid) == [805])
    #expect(ProcessControl.resolve(listed, in: later).isEmpty)
    // A used-by entry known by pid alone (no start time) is never acted on.
    #expect(ProcessControl.resolve([ProcessControl.Dependant(pid: 803, name: "node", kind: .process)], in: rows).isEmpty)
}

@Test func aConfirmedStopSignalsOnlyTheFrozenIdentities() {
    let rows = sessionRows()
    let selection = ProcessControl.select([rows[5]], rows: rows, ownPid: own, sparing: spareTheSession)
    // 805 exited and its pid went to a new process by the time the user confirmed.
    var later = rows
    later[later.firstIndex { $0.pid == 805 }!].startMicroseconds = 999_000_000
    let recorder = Recorder()
    let outcomes = ProcessControl.perform(.quit, on: selection.targets + ProcessControl.resolve(selection.alsoEnds, in: later),
                                          current: later.map { identity($0) }, signaller: recorder,
                                          terminator: recorder.terminator(nil), ownPid: own)
    #expect(outcomes.map(\.pid) == [804])
    #expect(recorder.calls == ["\(SIGTERM) 804"])
}

// MARK: - Edges

@Test func aPpidLoopEndsTheDependantWalk() {
    let rows = [row(20, "a", parent: 21), row(21, "b", parent: 20), row(22, "c", parent: 21)]
    let dependants = ProcessControl.dependants(of: [20], rows: rows)
    #expect(dependants.map(\.pid) == [21, 22])
    #expect(ProcessControl.order([20, 21, 22], rows: rows).last == 20)
}

@Test func socketShapedProcessNamesKeepTheirOwnConnections() throws {
    let listing = try SocketListing(text: """
        listener.500,,
        tcp4 127.0.0.1:8021<->*:*,Listen,
        tcp4 a<->b.601,,
        tcp4 127.0.0.1:50001<->127.0.0.1:8021,Established,
        udp-helper a<->b.602,,
        udp4 127.0.0.1:50002<->127.0.0.1:8021,,
        """)
    #expect(listing.names == [500: "listener", 601: "tcp4 a<->b", 602: "udp-helper a<->b"])
    #expect(listing.sockets[500]?.count == 1)
    #expect(listing.sockets[602]?.first?.proto == "udp4")
    #expect(ProcessControl.usedBy(500, listing: listing, rows: []).map(\.pid) == [601])
}

@Test func usedByIgnoresConnectionsToOtherPorts() throws {
    let listing = try SocketListing(text: proxyListing)
    // 603 talks to 9000; 604 to 8021 on another host, not loopback nor the listener's address.
    let usedBy = ProcessControl.usedBy(500, listing: listing, rows: [])
    #expect(!usedBy.contains { $0.pid == 603 || $0.pid == 604 })
    // A process that listens on nothing is used by nobody.
    #expect(ProcessControl.usedBy(600, listing: listing, rows: []).isEmpty)
}

/// A listener on every address (`*:22`) is used by connections to any of this machine's own addresses — the ones its
/// sockets name as local — and over loopback; not by a connection to port 22 on another machine.
@Test func matchesWildcardListeners() throws {
    let listing = try SocketListing(text: """
        sshd.30,,
        tcp6 *.22<->*.*,Listen,
        tcp4 *:22<->*:*,Listen,
        tcp4 192.0.2.40:22<->192.0.2.40:50010,Established,
        ssh.31,,
        tcp4 192.0.2.40:50010<->192.0.2.40:22,Established,
        ssh.32,,
        tcp4 192.0.2.40:50011<->192.0.2.40:2222,Established,
        ssh.33,,
        tcp4 192.0.2.40:50012<->198.51.100.7:22,Established,
        ssh.34,,
        tcp6 ::1.50013<->::1.22,Established,
        """)
    #expect(ProcessControl.usedBy(30, listing: listing, rows: []).map(\.pid) == [31, 34])
}

@Test func confirmTitleCountsTargetsPlusDependants() {
    #expect(ProcessControl.confirmTitle(action: .quit, dependantCount: 2) == "Quit all 3")
    #expect(ProcessControl.confirmTitle(action: .forceQuit, dependantCount: 1) == "Force Quit all 2")
    #expect(ProcessControl.confirmTitle(action: .pause, dependantCount: 0) == "Pause")
    #expect(ProcessControl.confirmTitle(action: .resume, dependantCount: 0) == "Resume")
    #expect(ProcessControl.confirmTitle(action: .quit, targetCount: 4, dependantCount: 0) == "Quit all 4")
}

@Test func launchdManagedNeedsPpidOneAndALaunchctlRow() {
    let list = "PID\tStatus\tLabel\n-\t0\tcom.example.idle\n4321\t0\tcom.example.agent\n55\t-9\tcom.example.other\n"
    #expect(ProcessControl.launchdManaged(4321, ppid: 1, launchctlList: list))
    #expect(!ProcessControl.launchdManaged(4321, ppid: 99, launchctlList: list))
    #expect(!ProcessControl.launchdManaged(432, ppid: 1, launchctlList: list))
    #expect(!ProcessControl.launchdManaged(0, ppid: 1, launchctlList: list))
}

@Test func appTerminatorNilFallsBackToTheSignal() {
    let app = row(1300, "Helper", app: "Example")
    let current = [identity(app)]
    let recorder = Recorder()
    _ = ProcessControl.perform(.quit, on: [app], current: current, signaller: recorder, terminator: recorder.terminator(nil))
    #expect(recorder.calls == ["terminate 1300", "\(SIGTERM) 1300"])
    let answered = Recorder()
    _ = ProcessControl.perform(.forceQuit, on: [app], current: current, signaller: answered,
                               terminator: answered.terminator(true))
    #expect(answered.calls == ["forceTerminate 1300"])
    let refused = Recorder()
    let outcomes = ProcessControl.perform(.quit, on: [app], current: current, signaller: refused,
                                          terminator: refused.terminator(false))
    #expect(outcomes == [ProcessControl.Outcome(pid: 1300, result: .failure(.appRefused))])
}

@Test func anAppsOwnHelpersAreLeftToTheAppOnQuit() {
    // Quitting an app quits its helpers itself (File > Quit); pausing reaches each one.
    let rows = [row(1400, "Example", app: "Example"), row(1401, "Example Helper", parent: 1400, app: "Example"),
                row(1402, "sleep", parent: 1400)]
    let current = rows.map { identity($0) }
    let recorder = Recorder()
    _ = ProcessControl.perform(.quit, on: rows, current: current, signaller: recorder, terminator: recorder.terminator(true))
    #expect(recorder.calls == ["\(SIGTERM) 1402", "terminate 1400"])
    let pausing = Recorder()
    _ = ProcessControl.perform(.pause, on: rows, current: current, signaller: pausing, terminator: pausing.terminator(true))
    #expect(pausing.calls == ["\(SIGSTOP) 1401", "\(SIGSTOP) 1402", "\(SIGSTOP) 1400"])
}

@Test func aWarningBarSparesTheUsersSessionAndTheExemptedAppleServicesAndNothingElse() {
    var session = row(100, "zsh")
    session.usersOwn = true
    let service = row(200, "mdworker_shared"), worker = row(300, "worker.sh")
    let sparing = ProcessControl.barSparing(exempt: [200])
    #expect(sparing(session) == "your session and its launch wrappers are left running")
    #expect(sparing(service) == "Apple services are left running")
    #expect(sparing(worker) == nil)
    // A service not on the line's exempt list is a target like any other.
    #expect(ProcessControl.barSparing(exempt: [])(service) == nil)
}
