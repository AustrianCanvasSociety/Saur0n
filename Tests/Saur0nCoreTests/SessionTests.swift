// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Fixture registries and process tables for the session resolver (research/2026-10-18-phase3-open.md § Q3).
// Start times are whole seconds; `procStart` strings are their UTC ctime form.

private let start: UInt64 = 1_792_371_881  // Mon Oct 19 01:04:41 2026 UTC
private let startText = "Mon Oct 19 01:04:41 2026"

private func row(_ pid: Int32, parent: Int32 = 1, uid: UInt32 = 501, cpu: Double = 0, rss: UInt64 = 1024,
                 name: String = "proc", path: String? = nil) -> ProcessUsage {
    ProcessUsage(pid: pid, ppid: parent, uid: uid, user: uid == 0 ? "root" : "alice", path: path, name: name,
                 cpuPercent: cpu, residentBytes: rss, source: .libproc)
}

private func entry(_ pid: Int32, id: String, name: String? = nil, cwd: String = "/work/alpha",
                   procStart: String = startText) -> Data {
    var object: [String: Any] = ["pid": pid, "sessionId": id, "cwd": cwd, "procStart": procStart, "kind": "interactive"]
    if let name { object["name"] = name }
    return try! JSONSerialization.data(withJSONObject: object)
}

private func sources(_ rows: [ProcessUsage], registry: [Data] = [], env: [Int32: String] = [:],
                     tmux: [Int32: String] = [:], tty: [Int32: String] = [:],
                     starts: [Int32: UInt64] = [:]) -> SessionSources {
    var startSeconds = Dictionary(rows.map { ($0.pid, start) }, uniquingKeysWith: { a, _ in a })
    startSeconds.merge(starts) { _, new in new }
    return SessionSources(registry: registry.compactMap(RegistryEntry.parse), startSeconds: startSeconds,
                          environmentSessionIDs: env, tmuxPanes: tmux, tty: tty, ownUID: 501)
}

private func names(_ result: (rows: [ProcessUsage], groups: [SessionGroup])) -> [Int32: String] {
    Dictionary(result.rows.map { ($0.pid, $0.session?.name ?? "-") }, uniquingKeysWith: { a, _ in a })
}

private let idA = "aaaaaaaa-1111-4111-8111-111111111111"
private let idB = "bbbbbbbb-2222-4222-8222-222222222222"
private let idDead = "dddddddd-0000-4000-8000-000000000000"

@Test func registryEntryParses() throws {
    let parsed = try #require(RegistryEntry.parse(entry(10, id: idA, name: "line-a")))
    #expect(parsed == RegistryEntry(pid: 10, sessionId: idA, name: "line-a", cwd: "/work/alpha", procStartSeconds: start))
    // A single-digit day, space-padded as ctime pads it.
    #expect(RegistryEntry.parse(entry(10, id: idA, procStart: "Thu Oct  1 00:00:00 2026"))?.procStartSeconds == 1_790_812_800)
}

@Test func registryStartTimeParsing() {
    #expect(RegistryEntry.startSeconds("Mon Oct 19 01:04:41 2026") == 1_792_371_881)
    #expect(RegistryEntry.startSeconds("Thu Jan  1 00:00:00 1970") == 0)
    #expect(RegistryEntry.startSeconds("Tue Feb 29 12:00:00 2028") == 1_835_438_400)    // a leap day
    // Dates the old formatter refused, and text around a date, are not start times.
    #expect(RegistryEntry.startSeconds("Mon Feb 30 00:00:00 2026") == nil)
    #expect(RegistryEntry.startSeconds("Mon Oct 19 24:00:00 2026") == nil)
    #expect(RegistryEntry.startSeconds("Mon Oct 19 01:04:41 2026 extra") == nil)
    #expect(RegistryEntry.startSeconds("Wed Dec 31 23:59:59 1969") == nil)
    #expect(RegistryEntry.startSeconds("") == nil)
}

@Test func nearestRegisteredAncestor() {
    // claude A (10) → zsh (11) → claude B (12) → cargo (13) → test binary (14).
    let rows = [row(10, name: "claude"), row(11, parent: 10, name: "zsh"), row(12, parent: 11, name: "claude"),
                row(13, parent: 12, name: "cargo"), row(14, parent: 13, name: "astar-1f2e")]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(10, id: idA, name: "line-a"),
                                                                              entry(12, id: idB, name: "line-b")]))
    #expect(names(result) == [10: "line-a", 11: "line-a", 12: "line-b", 13: "line-b", 14: "line-b"])
    #expect(result.rows.first { $0.pid == 14 }?.session == SessionInfo(name: "line-b", kind: .claude, id: idB))
}

@Test func tmuxLineWithADeadEnvId() {
    // tmux server (20, launchd's) → pane shell (21) → claude (22), registered; both carry a dead id.
    // Pane 23 is a plain shell. The claude line is its own session; the plain pane is the tmux session.
    let rows = [row(20, name: "tmux"), row(21, parent: 20, name: "zsh"), row(22, parent: 21, name: "claude"),
                row(23, parent: 20, name: "zsh")]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(22, id: idA, name: "orch-line")],
                                                             env: [21: idDead, 22: idDead, 23: idDead],
                                                             tmux: [21: "orch-line", 23: "scratch"]))
    #expect(names(result) == [20: "-", 21: "orch-line", 22: "orch-line", 23: "scratch"])
    #expect(result.rows.first { $0.pid == 21 }?.session?.kind == .tmux)
    #expect(result.rows.first { $0.pid == 22 }?.session?.kind == .claude)
}

@Test func orphanUnderLaunchdTiedByEnvId() {
    // An app a session launched, re-parented to launchd: tied by its env id; its child with no env inherits.
    let rows = [row(30, name: "claude"), row(31, name: "SomeApp"), row(32, parent: 31, name: "helper")]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(30, id: idA, name: "line-a")],
                                                             env: [31: idA]))
    #expect(names(result) == [30: "line-a", 31: "line-a", 32: "line-a"])
}

@Test func reusedPidIsNotThatSession() {
    // The registry's pid 40 now belongs to a process started later: not that session, by ancestry or env id.
    let rows = [row(40, name: "zsh"), row(41, parent: 40, name: "vim"), row(42, name: "other")]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(40, id: idA, name: "gone")],
                                                             env: [42: idA], starts: [40: start + 600]))
    #expect(names(result) == [40: "-", 41: "-", 42: "-"])
    #expect(result.groups.map(\.name) == [SessionGroups.noSession])
}

@Test func scrubbedEnvironmentDescendantByAncestry() {
    let rows = [row(50, name: "claude"), row(51, parent: 50, name: "env"), row(52, parent: 51, name: "make")]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(50, id: idA, name: "line-a")]))
    #expect(names(result)[52] == "line-a")
}

@Test func missingOrMalformedRegistry() {
    let rows = [row(60, name: "claude"), row(61, parent: 60, name: "zsh")]
    let bad = [Data("not json".utf8), Data(#"{"pid": 60, "sessionId": "x"}"#.utf8),
               Data(#"{"pid": "60", "sessionId": "x", "procStart": "Mon Oct 19 01:04:41 2026"}"#.utf8),
               entry(60, id: idA, procStart: "yesterday")]
    #expect(bad.compactMap(RegistryEntry.parse).isEmpty)
    for registry in [[], bad] {
        let result = SessionGroups.assign(rows, sources: sources(rows, registry: registry, tmux: [61: "work"]))
        #expect(names(result) == [60: "-", 61: "work"])
    }
}

@Test func registryEntryWithoutAName() {
    let rows = [row(70, name: "claude")]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(70, id: idA, cwd: "/work/alpha.wt/fix")]))
    #expect(result.rows[0].session == SessionInfo(name: "fix aaaaaaaa", kind: .claude, id: idA))
}

@Test func tmuxPanesParse() {
    #expect(SessionGroups.parseTmuxPanes("21 orch line\n23 scratch\n\nbad\n-4 neg\n24 \n") == [21: "orch line", 23: "scratch"])
}

@Test func rootLoginUnderATerminalTab() {
    // Terminal (80) → root login (81) → zsh (82) → vim (83). Terminal itself has no session.
    // A login that launchd started (84) is not a terminal tab.
    let rows = [row(80, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
                row(81, parent: 80, uid: 0, name: "login", path: "/usr/bin/login"), row(82, parent: 81, name: "zsh"),
                row(83, parent: 82, name: "vim"), row(84, uid: 0, name: "login", path: "/usr/bin/login"),
                row(85, parent: 80, uid: 0, name: "login", path: "/usr/bin/login")]
    #expect(SessionGroups.terminalLogins(rows) == [81, 85])
    let result = SessionGroups.assign(rows, sources: sources(rows, tty: [81: "ttys003"]))
    #expect(names(result) == [80: "-", 81: "Terminal ttys003", 82: "Terminal ttys003", 83: "Terminal ttys003",
                              84: "-", 85: "Terminal login 85"])
    #expect(result.rows.first { $0.pid == 83 }?.session == SessionInfo(name: "Terminal ttys003", kind: .terminal, id: "ttys003"))
    #expect(result.rows.first { $0.pid == 85 }?.session?.id == "login-85")
    // Root's processes with no session go with other users'; the user's own with none in "No session".
    #expect(result.groups.suffix(2).map(\.name) == [SessionGroups.noSession, SessionGroups.systemAndOtherUsers])
    #expect(result.groups.last?.pids == [84])
}

@Test func treeOrderSessionCargoTestBinaries() {
    // claude (90) → zsh (91) → cargo (92) → two test binaries; a sibling of cargo under zsh.
    let rows = [row(93, parent: 92, cpu: 5, name: "astar-1"), row(94, parent: 92, cpu: 9, name: "graph-2"),
                row(95, parent: 91, cpu: 7, name: "rg"), row(92, parent: 91, cpu: 1, name: "cargo"),
                row(90, cpu: 2, name: "claude"), row(91, parent: 90, name: "zsh")]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(90, id: idA, name: "line-a")]))
    let group = result.groups[0]
    #expect(group.pids == [90, 91, 95, 92, 94, 93])
    #expect(CommandGroups.depths(group.pids, parents: CommandGroups.parents(result.rows))
            == [90: 0, 91: 1, 95: 2, 92: 2, 94: 3, 93: 3])
    // The CLI's `--by session` table reads them from one parent map a sample (the gate's round 2), indented as before.
    let work = WorkCount()
    let table = WorkCount.current.withValue(work) {
        ProcessSample.table(result.rows, sessionGroups: result.groups, by: .session)
    }
    #expect(work.parentMaps == 1)
    // Each member's line by its pid, in order, and the spaces before its name.
    let members = table.split(separator: "\n").compactMap { line -> (pid: Int32, indent: Int)? in
        guard let pid = line.split(separator: " ").first.flatMap({ Int32($0) }),
              let name = rows.first(where: { $0.pid == pid })?.name,
              let at = line.range(of: " " + name, options: .backwards) else { return nil }
        return (pid, line[..<at.lowerBound].reversed().prefix { $0 == " " }.count)
    }
    #expect(members.map(\.pid) == [90, 91, 95, 92, 94, 93])
    #expect(members.map { ($0.indent - (members.first?.indent ?? 0)) / 2 } == [0, 1, 2, 2, 3, 3])
}

/// Phase 6 Step 3: siblings go by their own plus exited CPU — a storm parent at 0.2% `+23% exited` before a 5% sibling.
@Test func treeOrdersSiblingsByOwnPlusExitedCPU() {
    var storm = row(92, parent: 90, cpu: 0.2, name: "storm.sh")
    storm.exitedChildrenCpuPercent = 23
    let rows = [row(91, parent: 90, cpu: 5, name: "rg"), storm, row(90, cpu: 2, name: "claude")]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(90, id: idA, name: "line-a")]))
    #expect(result.groups[0].pids == [90, 92, 91])
}

@Test func groupsTotalsOrderAndSharedNames() {
    let rows = [row(100, cpu: 1, rss: 10, name: "claude"), row(101, parent: 100, cpu: 2, rss: 20),
                row(102, cpu: 4, rss: 40, name: "claude"), row(103, cpu: 8), row(104, uid: 0, cpu: 16)]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(100, id: idA, name: "same"),
                                                                              entry(102, id: idB, name: "same")]))
    #expect(result.groups.map(\.name) == ["same", "same", SessionGroups.noSession, SessionGroups.systemAndOtherUsers])
    #expect(result.groups.map(\.id) == [idB, idA, nil, nil])
    #expect(result.groups[1].cpuPercent == 3 && result.groups[1].residentBytes == 30)
    // Each pid in exactly one group.
    #expect(result.groups.flatMap(\.pids).sorted() == rows.map(\.pid).sorted())
}

@Test func sharedSessionTitlesReachCLIAndWindow() {
    let rows = [row(100, cpu: 3), row(101, cpu: 2), row(102, cpu: 1)]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(100, id: idA, name: "same"),
        entry(101, id: idB, name: "same"), entry(102, id: "unique-session", name: "unique")]))
    let titles = ["same (\(idA))", "same (\(idB))", "unique"]
    #expect(result.groups.map(\.name) == ["same", "same", "unique"])
    #expect(ProcessSample.titles(result.groups) == titles)
    let cli = ProcessSample.table(result.rows, sessionGroups: result.groups, by: .session)
    for title in titles { #expect(cli.contains(title)) }
    let window = ProcessTable.lines(rows: result.rows, repoGroups: [], sessionGroups: result.groups,
                                    grouping: .session, unattributedCpuPercent: nil)
    #expect(window.filter { $0.kind == .group }.map(\.name) == titles)
}

@Test func ppidLoopEndsTheWalk() {
    let rows = [row(110, parent: 111), row(111, parent: 110)]
    let result = SessionGroups.assign(rows, sources: sources(rows))
    #expect(names(result) == [110: "-", 111: "-"])
}

/// The CLI and the window share one assembly: from the closing scan's start times and environments, the
/// registry files, tmux panes and each terminal tab's tty, it gives the sources the CLI used to build inline,
/// and so the same sessions.
@Test func sharedAssemblyGivesTheCLIsSessions() throws {
    // claude A (10, registered) → its test run (11, carrying A's id); a tmux pane (20); a terminal tab's root
    // login (30) under its app (5) → shell (31).
    let rows = [row(10, name: "claude"), row(11, parent: 10), row(20), row(5, name: "Ghostty"),
                row(30, parent: 5, uid: 0, name: "login", path: "/usr/bin/login"), row(31, parent: 30)]
    let sample = ProcessListSample(
        uptimeNanoseconds: 1,
        processes: rows.map { ProcessIdentity(pid: $0.pid, ppid: $0.ppid, uid: $0.uid, user: $0.user,
                                              startMicroseconds: start * 1_000_000 + 250_000, comm: $0.name, path: $0.path) },
        taskInfo: [:], ps: [:],
        arguments: [11: ProcessArguments(argv: ["test"], environment: ["CLAUDE_CODE_SESSION_ID": idA])])
    var asked: [Int32] = []
    let assembled = SessionSources.assemble(rows: rows, sample: sample, registry: [entry(10, id: idA, name: "line-a")],
                                            tmuxPanes: [20: "work"], ttyName: { asked.append($0); return "ttys004" },
                                            ownUID: 501)
    #expect(asked == [30])
    #expect(assembled.startSeconds == Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, start) }))
    #expect(assembled.environmentSessionIDs == [11: idA])
    #expect(assembled.tty == [30: "ttys004"])
    let inline = sources(rows, registry: [entry(10, id: idA, name: "line-a")], env: [11: idA], tmux: [20: "work"],
                         tty: [30: "ttys004"])
    #expect(SessionGroups.assign(rows, sources: assembled).groups == SessionGroups.assign(rows, sources: inline).groups)
    #expect(names(SessionGroups.assign(rows, sources: assembled)) == [10: "line-a", 11: "line-a", 20: "work",
                                                                      5: "-", 30: "Ghostty ttys004", 31: "Ghostty ttys004"])
}

// MARK: - Orphans tied back through their process group (Phase 6 Step 8)

/// A row in process group `group`, marked orphaned as `ProcessSample.usage` marks one: own user, under launchd, not
/// leading its group.
private func grouped(_ pid: Int32, group: Int32, parent: Int32 = 1, uid: UInt32 = 501, cpu: Double = 0,
                     name: String = "proc", started: UInt64 = start) -> ProcessUsage {
    var usage = row(pid, parent: parent, uid: uid, cpu: cpu, name: name)
    usage.processGroup = group
    usage.orphaned = Orphans.isOrphan(uid: uid, ppid: parent, pid: pid, processGroup: group, ownUID: 501)
    usage.startMicroseconds = started * 1_000_000
    return usage
}

/// The 2026-10-22 shape: a session's Bash call (its shell 100 leads group 100) `nohup`s a copy and is still running;
/// the copy (101) is launchd's, keeps group 100 and carries no readable environment (`/bin/bash`, probe 2026-10-24).
@Test func orphanJoinsItsLeadersSession() {
    let rows = [row(90, name: "claude"), grouped(100, group: 100, parent: 90, name: "bash"),
                grouped(101, group: 100, name: "bash")]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(90, id: idA, name: "line-a")]))
    #expect(names(result) == [90: "line-a", 100: "line-a", 101: "line-a"])
    #expect(result.rows.filter(\.orphaned).map(\.pid) == [101])
    #expect(result.groups.map(\.name) == ["line-a"])
}

/// The leader (200) has exited: the group's other members stand in, an orphan tied by its own environment included,
/// so its `/bin` sibling joins it.
@Test func orphanWhoseLeaderExitedJoinsTheGroupsOtherMembers() {
    let rows = [row(90, name: "claude"), grouped(201, group: 200, name: "sleep", started: start + 1),
                grouped(202, group: 200, name: "bash", started: start + 2)]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(90, id: idA, name: "line-a")],
                                                             env: [202: idA]))
    #expect(names(result) == [90: "line-a", 201: "line-a", 202: "line-a"])
    #expect(result.rows.filter(\.orphaned).map(\.pid) == [201, 202])
}

/// launchd's own agents and apps lead their own groups; root's and other users' processes are never orphans — even
/// in a group whose leader has a session.
@Test func launchdAgentsStayPut() {
    let rows = [row(90, name: "claude"), grouped(100, group: 100, parent: 90, name: "bash"),
                grouped(300, group: 300, name: "SetStoreUpdateService"), grouped(301, group: 301, name: "Firefox"),
                grouped(302, group: 100, uid: 0, name: "rootd"), grouped(304, group: 100, uid: 502, name: "theirs")]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(90, id: idA, name: "line-a")]))
    #expect(names(result) == [90: "line-a", 100: "line-a", 300: "-", 301: "-", 302: "-", 304: "-"])
    #expect(result.rows.filter(\.orphaned).isEmpty)
}

@Test func orphansOwnEnvironmentIdWinsOverItsLeader() {
    let rows = [row(90, name: "claude"), row(91, name: "claude"), grouped(100, group: 100, parent: 90, name: "bash"),
                grouped(101, group: 100, name: "node")]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(90, id: idA, name: "line-a"),
                                                                              entry(91, id: idB, name: "line-b")],
                                                             env: [101: idB]))
    #expect(names(result)[101] == "line-b")
}

/// The copy's busy child is not itself an orphan (its parent lives) and goes with the copy; only the copy is marked.
@Test func orphansChildInheritsThroughTheOrphan() {
    let rows = [row(90, name: "claude"), grouped(100, group: 100, parent: 90, name: "bash"),
                grouped(401, group: 100, name: "bash"), grouped(402, group: 100, parent: 401, cpu: 9, name: "yes")]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(90, id: idA, name: "line-a")]))
    #expect(names(result)[402] == "line-a")
    #expect(result.rows.filter(\.orphaned).map(\.pid) == [401])
}

/// At rest (probe 2026-10-24): zsh workers whose leader has exited and no member with a session stay in "No session",
/// marked all the same.
@Test func orphansWithNoTiedMemberStayInNoSession() {
    let rows = [grouped(10881, group: 10880, name: "zsh"), grouped(10882, group: 10880, name: "zsh")]
    let result = SessionGroups.assign(rows, sources: sources(rows))
    #expect(names(result) == [10881: "-", 10882: "-"])
    #expect(result.groups.map(\.name) == [SessionGroups.noSession])
    #expect(result.rows.allSatisfy { $0.orphaned })
}

/// The group joined carries the orphan's CPU, so the session goes first under the CPU order.
@Test func orphansCPUMovesItsGroup() {
    let rows = [row(90, cpu: 1, name: "claude"), row(91, cpu: 5, name: "claude"),
                grouped(100, group: 100, parent: 90, name: "bash"), grouped(101, group: 100, cpu: 30, name: "bash")]
    let result = SessionGroups.assign(rows, sources: sources(rows, registry: [entry(90, id: idA, name: "line-a"),
                                                                              entry(91, id: idB, name: "line-b")]))
    #expect(result.groups.map(\.name) == ["line-a", "line-b"])
    #expect(result.groups[0].cpuPercent == 31)
}

/// The repo view: an orphan takes its leader's repo over its own throwaway `/tmp` one; with a leader in no repo it keeps
/// its own; a stand-in member's repo when the leader has exited.
@Test func orphanJoinsItsLeadersRepo() {
    let rows = [grouped(100, group: 100, parent: 90, name: "bash"), grouped(101, group: 100, name: "bash"),
                grouped(110, group: 110, parent: 90, name: "zsh"), grouped(111, group: 110, name: "bash"),
                grouped(121, group: 120, name: "sleep"), grouped(122, group: 120, name: "bash")]
    let folders: [Int32: String] = [100: "/work/alpha", 101: "/tmp/copy-1", 110: "/", 111: "/tmp/copy-2",
                                    121: "/", 122: "/work/alpha"]
    let result = RepoGroups.assign(rows, workingDirectories: folders,
                                   repoOfDirectory: { path in
                                       path == "/" ? nil : RepoInfo(name: RepoResolver.basename(path), root: path, worktree: nil)
                                   },
                                   repoOfExecutable: { _ in nil })
    let repos = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.pid, $0.repo?.name ?? "-") })
    #expect(repos == [100: "alpha", 101: "alpha", 110: "-", 111: "copy-2", 121: "alpha", 122: "alpha"])
}

private func rememberedGroups(_ rows: [ProcessUsage], memory: inout KeptOrphanGroups,
                              folders: [Int32: String] = [:], tmux: [Int32: String] = [:])
    -> (rows: [ProcessUsage], repoGroups: [RepoGroup], sessionGroups: [SessionGroup]) {
    memory.assign(rows, workingDirectories: folders,
                  repoOfDirectory: { $0.hasPrefix("/work/") ? RepoInfo(name: RepoResolver.basename($0), root: $0, worktree: nil) : nil },
                  repoOfExecutable: { _ in nil }, sources: sources(rows, tmux: tmux))
}

@Test(arguments: [1, 2]) func orphanMemorySurvivesTheLaunchingShell(copies: Int) {
    var memory = KeptOrphanGroups()
    let shell = grouped(100, group: 100, parent: 90, name: "bash")
    let children = (1...copies).map { grouped(Int32(100 + $0), group: 100, parent: 100, name: "bash") }
    let before = rememberedGroups([shell] + children, memory: &memory,
                                  folders: [100: "/work/alpha"], tmux: [100: "line-a"])
    #expect(before.rows.allSatisfy { !$0.orphaned && $0.session?.id == "line-a" && $0.repo?.name == "alpha" })
    let orphans = children.map { grouped($0.pid, group: 100, name: "bash") }
    // A child in a different process group inherits through the remembered orphan too.
    let rows = orphans + [grouped(200, group: 200, parent: 101, cpu: 7)]
    let after = rememberedGroups(rows, memory: &memory, folders: [101: "/tmp/copy"])
    #expect(after.rows.allSatisfy { $0.session?.id == "line-a" && $0.repo?.name == "alpha" })
    #expect(after.rows.filter(\.orphaned).map(\.pid) == orphans.map(\.pid))
    #expect(after.repoGroups.count == 1 && after.repoGroups[0].pids.count == rows.count)
    #expect(after.sessionGroups.count == 1 && after.sessionGroups[0].cpuPercent == 7)
    // The one-shot CLI has no history: it still uses only members in this scan.
    #expect(SessionGroups.assign(orphans, sources: sources(orphans)).rows.allSatisfy { $0.session == nil })
    #expect(RepoGroups.assign(orphans, workingDirectories: [:], repoOfDirectory: { _ in nil },
                             repoOfExecutable: { _ in nil }).rows.allSatisfy { $0.repo == nil })
    // Retain through another scan with only an orphan, not only through the shell's exit.
    #expect(rememberedGroups([orphans[0]], memory: &memory).rows[0].repo?.name == "alpha")
    _ = rememberedGroups([], memory: &memory)
    #expect(memory.remembered.isEmpty)
    let reused = rememberedGroups([orphans[0]], memory: &memory)
    #expect(reused.rows[0].session == nil && reused.rows[0].repo == nil)
}

@Test func orphanMemoryUsesLiveOwnershipBeforeRememberedOwnership() {
    var memory = KeptOrphanGroups()
    let shell = grouped(100, group: 100, parent: 90)
    _ = rememberedGroups([shell], memory: &memory, folders: [100: "/work/alpha"], tmux: [100: "line-a"])
    let orphan = grouped(101, group: 100)
    let live = rememberedGroups([orphan, shell], memory: &memory,
                                folders: [100: "/work/beta"], tmux: [100: "line-b"])
    #expect(live.rows[0].session?.id == "line-b" && live.rows[0].repo?.name == "beta")
    let after = rememberedGroups([orphan], memory: &memory)
    #expect(after.rows[0].session?.id == "line-b" && after.rows[0].repo?.name == "beta")
    let ownSession = rememberedGroups([orphan], memory: &memory, tmux: [101: "line-c"])
    #expect(ownSession.rows[0].session?.id == "line-c")
    // A live member without the leader still overrides the remembered tie.
    let member = grouped(102, group: 100, parent: 90)
    let sibling = rememberedGroups([orphan, member], memory: &memory,
                                   folders: [102: "/work/gamma"], tmux: [102: "line-d"])
    #expect(sibling.rows[0].session?.id == "line-d" && sibling.rows[0].repo?.name == "gamma")
}

@Test func orphanMemoryKeepsOnlyKnownOwnGroupsAndEvictsIndependently() {
    var memory = KeptOrphanGroups()
    let rows = [grouped(100, group: 100, parent: 90), grouped(200, group: 200, parent: 90),
                grouped(300, group: 300), grouped(400, group: 400, uid: 0),
                grouped(500, group: 500, uid: 502), row(600)]
    _ = rememberedGroups(rows, memory: &memory, folders: [200: "/work/alpha", 400: "/work/root", 500: "/work/theirs"],
                         tmux: [100: "line-a", 400: "root", 500: "theirs", 600: "no-group"])
    #expect(Set(memory.remembered.keys) == [100, 200])
    let remaining = [grouped(101, group: 100), grouped(201, group: 200)]
    let both = rememberedGroups(remaining, memory: &memory)
    #expect(both.rows[0].session?.id == "line-a" && both.rows[0].repo == nil)
    #expect(both.rows[1].session == nil && both.rows[1].repo?.name == "alpha")
    _ = rememberedGroups([remaining[1]], memory: &memory)
    #expect(Set(memory.remembered.keys) == [200])
    let reused = rememberedGroups(remaining, memory: &memory)
    #expect(reused.rows[0].session == nil && reused.rows[1].repo?.name == "alpha")
}

/// The scan's process group rides onto the row, and the row is marked orphaned from it.
@Test func processGroupCarriedOntoRows() throws {
    func identity(_ pid: Int32, ppid: Int32, uid: UInt32 = 501, group: Int32?) -> ProcessIdentity {
        ProcessIdentity(pid: pid, ppid: ppid, uid: uid, user: "alice", startMicroseconds: 1, comm: "p", path: nil,
                        processGroup: group)
    }
    let identities = [identity(100, ppid: 90, group: 100), identity(101, ppid: 1, group: 100),
                      identity(102, ppid: 1, group: 102), identity(103, ppid: 1, uid: 0, group: 100),
                      identity(104, ppid: 1, group: nil)]
    let counters = Dictionary(uniqueKeysWithValues: identities.map {
        ($0.pid, ProcessCounters(cpuNanoseconds: 0, residentBytes: 1))
    })
    let before = ProcessListSample(uptimeNanoseconds: 1, processes: identities, taskInfo: counters, ps: [:])
    let after = ProcessListSample(uptimeNanoseconds: 1_000_000_001, processes: identities, taskInfo: counters, ps: [:])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil, ownUID: 501)
    let byPid = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
    #expect(byPid[100]?.processGroup == 100 && byPid[104]?.processGroup == nil)
    #expect(rows.filter(\.orphaned).map(\.pid) == [101])
}

/// What is new under launchd: processes under launchd started in the minute before the scan (`> end - 60`, as the
/// snapshot's "Under 1 min"), any user's; the most common name when one repeats.
@Test func launchdNewcomersCountAndMostCommon() {
    let end = Double(start) + 100
    let rows = [grouped(1, group: 1, parent: 0, name: "launchd", started: start - 1000),
                grouped(10, group: 5, name: "sleep", started: start + 90), grouped(11, group: 5, name: "sleep", started: start + 41),
                grouped(12, group: 12, uid: 0, name: "bash", started: start + 50),
                grouped(13, group: 13, name: "sleep", started: start + 40),
                grouped(14, group: 5, parent: 10, name: "sleep", started: start + 95)]
    #expect(LaunchdNewcomers.of(rows, end: end) == LaunchdNewcomers(count: 3, mostCommon: .init(name: "sleep", count: 2)))
    #expect(LaunchdNewcomers.of(Array(rows.prefix(1)), end: end) == LaunchdNewcomers(count: 0, mostCommon: nil))
    #expect(LaunchdNewcomers.of([rows[1], rows[3]], end: end) == LaunchdNewcomers(count: 2, mostCommon: nil))
    // Two names tied: the first by name.
    #expect(LaunchdNewcomers.of([rows[1], rows[2], rows[3], rows[3]], end: end).mostCommon?.name == "bash")
}

/// The Unattributed line names what is new under launchd from 5.0% shown; JSON keeps `newUnderLaunchd` whenever the
/// rows were grouped and the scan's time is known, and every row's `orphaned`.
@Test func unattributedLineCarriesTheHint() throws {
    let levels = [PerfLevel(index: 0, name: "Performance", logicalCPUCount: 1)]
    let topology = try CoreTopology.build(levels: levels, clusterTypeByCPU: [0: "P"])
    let end = Double(start) + 100
    let copies = (0..<40).map { grouped(500 + $0, group: 499, name: "sleep", started: start + 70) }
    let rows = copies + [grouped(600, group: 600, name: "bash", started: start + 70)]
    let repos = RepoGroups.assign(rows, workingDirectories: [:], repoOfDirectory: { _ in nil }, repoOfExecutable: { _ in nil })
    let launches = LaunchRate(before: PidReading(pid: 100, uptimeNanoseconds: 0, epochSeconds: end - 1),
                              after: PidReading(pid: 700, uptimeNanoseconds: 1_000_000_000, epochSeconds: end))
    func snapshot(total: Double, launches: LaunchRate?) throws -> Snapshot {
        try Snapshot(topology: topology, load: CPULoad(perCPU: [total], total: total), intervalSeconds: 1,
                     processes: repos.rows, repoGroups: repos.groups, launches: launches)
    }
    let hint = "41 processes under launchd started in the last minute, most common: sleep × 40"
    #expect(try snapshot(total: 5.0, launches: launches).table().hasSuffix("Unattributed CPU  5.0%  — " + hint))
    #expect(try snapshot(total: 4.94, launches: launches).table().hasSuffix("Unattributed CPU  4.9%"))
    #expect(try snapshot(total: 30, launches: nil).table().hasSuffix("Unattributed CPU  30.0%"))
    #expect(TextFormat.launchdHint(LaunchdNewcomers(count: 1, mostCommon: nil), unattributedCpuPercent: 9)
            == "1 process under launchd started in the last minute")
    #expect(TextFormat.launchdHint(LaunchdNewcomers(count: 0, mostCommon: nil), unattributedCpuPercent: 9) == nil)

    let object = try #require(JSONSerialization.jsonObject(with: snapshot(total: 2, launches: launches).json()) as? [String: Any])
    let newcomers = try #require(object["newUnderLaunchd"] as? [String: Any])
    #expect(newcomers["count"] as? Int == 41)
    #expect((newcomers["mostCommon"] as? [String: Any])?["name"] as? String == "sleep")
    let processes = try #require(object["processes"] as? [[String: Any]])
    #expect(processes.filter { $0["orphaned"] as? Bool == true }.count == 40)
    #expect(processes.filter { $0["orphaned"] as? Bool == false }.count == 1)
    let quiet = try #require(JSONSerialization.jsonObject(with: snapshot(total: 2, launches: nil).json()) as? [String: Any])
    #expect(quiet["newUnderLaunchd"] == nil)
    let none = try #require(JSONSerialization.jsonObject(with: Snapshot(
        topology: topology, load: CPULoad(perCPU: [2], total: 2), intervalSeconds: 1, processes: [rows[40]],
        repoGroups: repos.groups, launches: launches).json()) as? [String: Any])
    #expect((none["newUnderLaunchd"] as? [String: Any])?["mostCommon"] is NSNull)
}

/// The CLI table tags an orphan after its name; the window's line carries the mark and the Unattributed line the hint.
@Test func orphanMarkedInTheTableAndTheWindow() {
    let rows = [grouped(101, group: 100, name: "bash"), grouped(102, group: 102, name: "agent")]
    let repos = RepoGroups.assign(rows, workingDirectories: [:], repoOfDirectory: { _ in nil }, repoOfExecutable: { _ in nil })
    let table = ProcessSample.table(repos.rows, groups: repos.groups)
    #expect(table.contains("  bash  [orphaned]"))
    #expect(!table.contains("agent  [orphaned]"))
    let lines = ProcessTable.lines(rows: repos.rows, repoGroups: repos.groups, sessionGroups: [], grouping: .repo,
                                   unattributedCpuPercent: 12, unattributedHint: "2 processes under launchd …")
    let members = lines.flatMap { $0.children ?? [] }
    #expect(members.first { $0.pid == 101 }?.orphaned == true)
    #expect(members.first { $0.pid == 102 }?.orphaned == false)
    #expect(lines.last?.kind == .unattributed && lines.last?.readableName == "2 processes under launchd …")
}
