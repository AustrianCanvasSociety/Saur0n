// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the By command view (Phase 6 Step 4) — one group per command key, the script's name for a shell or
// interpreter running one, a copy count, a script copy owning everything it starts down to an agent, a plain
// executable owning nothing below it, the agents never forming the key while something started them, each process in
// exactly one group. Method: recorded shapes built in code (research 2026-10-22: the 75 copies, each over a headless
// `claude`), documentation paths only.

private let script = "/tmp/example/runaway.sh"

private func row(_ pid: Int32, _ name: String, parent: Int32 = 1, cpu: Double = 0, exited: Double = 0,
                 uid: UInt32 = 501) -> ProcessUsage {
    ProcessUsage(pid: pid, ppid: parent, uid: uid, user: uid == 0 ? "root" : "user", path: "/usr/bin/" + name,
                 name: name, cpuPercent: cpu, residentBytes: 1 << 20, source: .libproc, exitedChildrenCpuPercent: exited)
}

private func args(_ argv: String...) -> ProcessArguments { ProcessArguments(argv: argv, environment: [:]) }

private typealias Arguments = [Int32: ProcessArguments]

private func group(_ groups: [CommandGroup], _ name: String) throws -> CommandGroup {
    try #require(groups.first { $0.name == name })
}

/// Every row sits in exactly one group, and the groups' sums are the rows'.
private func expectPartition(_ rows: [ProcessUsage], _ groups: [CommandGroup]) {
    let pids = groups.flatMap(\.pids)
    #expect(pids.count == rows.count)
    #expect(Set(pids) == Set(rows.map(\.pid)))
    let rowsTotal = rows.map(\.totalCpuPercent).reduce(0, +)
    #expect(abs(groups.map(\.totalCpuPercent).reduce(0, +) - rowsTotal) < 1e-9)
}

@Test(arguments: [false, true]) func groupTotalsKeepUnreadFieldsAndWrappingSums(overflow: Bool) throws {
    let base: UInt64 = overflow ? .max : 100
    var first = ProcessUsage(pid: 100, ppid: 1, uid: 501, user: "user", path: nil, name: "worker",
                             cpuPercent: 0.125, residentBytes: base, source: .libproc,
                             exitedChildrenCpuPercent: 0.5)
    first.disk = DiskUsage(rate: DiskRate(readBytesPerSecond: base, writeBytesPerSecond: base),
                           bytes: DiskBytes(read: base, written: base))
    first.network = NetworkUsage(rate: NetworkRate(inBytesPerSecond: base, outBytesPerSecond: base),
                                 bytes: NetworkBytes(received: base, sent: base))
    var second = ProcessUsage(pid: 101, ppid: 1, uid: 501, user: "user", path: nil, name: "worker",
                              cpuPercent: 0.25, residentBytes: 10, source: .libproc)
    second.disk = DiskUsage(rate: DiskRate(readBytesPerSecond: 11, writeBytesPerSecond: 12),
                            bytes: DiskBytes(read: 13, written: 14))
    second.network = NetworkUsage(rate: NetworkRate(inBytesPerSecond: 21, outBytesPerSecond: 22),
                                  bytes: NetworkBytes(received: 23, sent: 24))
    let third = ProcessUsage(pid: 102, ppid: 1, uid: 501, user: "user", path: nil, name: "worker",
                             cpuPercent: 0.0625, residentBytes: 1, source: .libproc,
                             exitedChildrenCpuPercent: 0.25)
    let rows = [first, second, third]
    let command = try #require(CommandGroups.assign(rows, arguments: [:]).groups.first)
    let session = try #require(SessionGroups.assign(rows, sources: SessionSources(
        registry: [], startSeconds: [:], environmentSessionIDs: [:], tmuxPanes: [:], tty: [:], ownUID: 501)).groups.first)
    let repo = try #require(RepoGroups.assign(rows, workingDirectories: [:],
                                            repoOfDirectory: { _ in nil }, repoOfExecutable: { _ in nil }).groups.first)
    for (cpu, exited, memory, disk, network) in [
        (command.cpuPercent, command.exitedChildrenCpuPercent, command.residentBytes, command.disk, command.network),
        (session.cpuPercent, session.exitedChildrenCpuPercent, session.residentBytes, session.disk, session.network),
        (repo.cpuPercent, repo.exitedChildrenCpuPercent, repo.residentBytes, repo.disk, repo.network)
    ] {
        #expect(cpu == 0.4375 && exited == 0.75)
        #expect(memory == (overflow ? 10 : 111))
        #expect(disk == DiskUsage(rate: DiskRate(readBytesPerSecond: overflow ? 10 : 111,
                                               writeBytesPerSecond: overflow ? 11 : 112),
                                  bytes: DiskBytes(read: overflow ? 12 : 113, written: overflow ? 13 : 114)))
        #expect(network == NetworkUsage(rate: NetworkRate(inBytesPerSecond: overflow ? 20 : 121,
                                                         outBytesPerSecond: overflow ? 21 : 122),
                                        bytes: NetworkBytes(received: overflow ? 22 : 123, sent: overflow ? 23 : 124)))
    }
}

// MARK: the command key

@Test func keyIsTheScriptAnInterpreterRuns() {
    func key(_ name: String, _ argv: [String]?) -> String { CommandGroups.key(name: name, argv: argv) }
    #expect(key("bash", ["/bin/bash", script, "--fast"]) == "runaway.sh")
    #expect(key("sh", ["/bin/sh", "-x", "./a/b.sh", "x"]) == "b.sh")
    #expect(key("bash", ["bash", "-o", "pipefail", "run.sh"]) == "run.sh")
    #expect(key("bash", ["bash", "--", "script.sh"]) == "script.sh")
    #expect(key("bash", ["bash", "-lc", "echo hi"]) == "bash")
    #expect(key("zsh", ["/bin/zsh", "-c", "-l", "source x && eval y"]) == "zsh")
    #expect(key("zsh", ["-zsh"]) == "zsh")
    #expect(key("bash", ["bash", "-s"]) == "bash")
    #expect(key("python3.12", ["python3.12", "-m", "pytest", "-q"]) == "pytest")
    #expect(key("python3", ["python3", "-mhttp.server"]) == "http.server")
    #expect(key("python3", ["python3", "-W", "ignore", "/opt/tool.py"]) == "tool.py")
    #expect(key("python3", ["python3", "-c", "print(1)"]) == "python3")
    #expect(key("Python", ["/Library/Frameworks/Python.framework/Python", "serve.py"]) == "serve.py")
    #expect(key("node", ["node", "--require", "x", "server.js"]) == "server.js")
    #expect(key("node", ["node", "-e", "1"]) == "node")
    #expect(key("node", ["node"]) == "node")
    #expect(key("perl5.34", ["perl5.34", "-e", "print 1"]) == "perl5.34")
    #expect(key("perl", ["perl", "-Ilib", "run.pl"]) == "run.pl")
    #expect(key("ruby", ["ruby", "-I", "lib", "run.rb"]) == "run.rb")
    #expect(key("bash", ["bash", "-"]) == "bash")
    // Unread arguments (other users' processes) and a program that is no interpreter key by name.
    #expect(key("bash", nil) == "bash")
    #expect(key("git", ["git", "status"]) == "git")
    #expect(key("bashful", ["bashful", "x.sh"]) == "bashful")
}

@Test func agentsMatchByProgramNameOrKey() {
    #expect(CommandGroups.isAgent(name: "claude", key: "claude"))
    #expect(CommandGroups.isAgent(name: "node", key: "claude"))
    #expect(CommandGroups.isAgent(name: "codex", key: "codex"))
    #expect(CommandGroups.isAgent(name: "cli-proxy-api", key: "cli-proxy-api"))
    #expect(!CommandGroups.isAgent(name: "claudette", key: "claudette"))
}

// MARK: the step's named cases

@Test func seventyFiveCopiesOverABusyChildAreOneGroup() throws {
    var rows: [ProcessUsage] = []
    var arguments: [Int32: ProcessArguments] = [:]
    for i in Int32(0)..<75 {
        rows.append(row(1000 + i, "bash"))
        arguments[1000 + i] = args("/bin/bash", script)
        rows.append(row(2000 + i, "yes", parent: 1000 + i, cpu: 0.3))
    }
    rows.append(row(3000, "WindowServer", cpu: 4))
    let out = CommandGroups.assign(rows, arguments: arguments)
    let first = try #require(out.groups.first)
    #expect(first.name == "runaway.sh")
    #expect(first.copies == 75)
    #expect(first.pids.count == 150)
    #expect(abs(first.totalCpuPercent - 22.5) < 1e-9)
    #expect(!out.groups.contains { $0.name == "yes" })
    // Each copy, then what it owns.
    #expect(Array(first.pids.prefix(2)) == [1000, 2000])
    expectPartition(rows, out.groups)
    #expect(out.rows.first { $0.pid == 2000 }?.command == "yes")
    #expect(out.rows.first { $0.pid == 1000 }?.command == "runaway.sh")
}

@Test func testSuiteBashChildrenStayApartFromAScriptsCopies() throws {
    var rows = [row(500, "cargo", cpu: 1)]
    var arguments: [Int32: ProcessArguments] = [500: args("cargo", "test")]
    for i in Int32(0)..<300 {
        rows.append(row(600 + i, "bash", parent: 500, cpu: 0.01))
        arguments[600 + i] = args("/bin/bash", "-c", "exit 0")
    }
    for i in Int32(0)..<20 {
        rows.append(row(1000 + i, "bash", cpu: 0.05))
        arguments[1000 + i] = args("/bin/bash", script)
    }
    let out = CommandGroups.assign(rows, arguments: arguments)
    #expect(try group(out.groups, "bash").copies == 300)
    #expect(try group(out.groups, "runaway.sh").copies == 20)
    #expect(try group(out.groups, "cargo").copies == 1)
    #expect(try group(out.groups, "cargo").pids == [500])
    expectPartition(rows, out.groups)
}

@Test func aDescendantIsCountedOnce() throws {
    let rows = [row(100, "bash"), row(101, "bash", parent: 100), row(102, "yes", parent: 101, cpu: 5, exited: 1)]
    let arguments: Arguments = [100: args("bash", script), 101: args("bash", script)]
    let out = CommandGroups.assign(rows, arguments: arguments)
    #expect(out.groups.count == 1)
    let only = try group(out.groups, "runaway.sh")
    #expect(only.copies == 1)
    #expect(only.pids == [100, 101, 102])
    #expect(abs(only.totalCpuPercent - 6) < 1e-9)
    expectPartition(rows, out.groups)
}

/// The 2026-10-22 runaway: 75 copies of the check under launchd, 69 of them over a headless `claude`, each `claude`
/// with one live tool call.
@Test func theRunawayGroupsAsTheScriptWithItsAgentsInside() throws {
    var rows: [ProcessUsage] = []
    var arguments: [Int32: ProcessArguments] = [:]
    for i in Int32(0)..<75 {
        rows.append(row(10_000 + i, "bash"))
        arguments[10_000 + i] = args("/bin/bash", "/opt/example/hooks/shell-prefix-check.sh")
        guard i < 69 else { continue }
        rows.append(row(20_000 + i, "claude", parent: 10_000 + i, cpu: 0.19, exited: 0.1))
        arguments[20_000 + i] = args("claude", "-p", "check")
        rows.append(row(30_000 + i, "zsh", parent: 20_000 + i, cpu: 0.01))
        arguments[30_000 + i] = args("/bin/zsh", "-c", "-l", "eval x")
    }
    let out = CommandGroups.assign(rows, arguments: arguments)
    let check = try group(out.groups, "shell-prefix-check.sh")
    #expect(out.groups.first?.name == "shell-prefix-check.sh")
    #expect(check.copies == 75)
    #expect(check.pids.count == 75 + 69)
    #expect(abs(check.totalCpuPercent - 69 * 0.29) < 1e-9)
    #expect(!out.groups.contains { $0.name == "claude" })
    #expect(try group(out.groups, "zsh").copies == 69)
    expectPartition(rows, out.groups)
}

@Test func aSessionsOwnClaudeKeepsItsBusyChildAsItsOwnCommand() throws {
    let rows = [row(200, "login", uid: 0), row(201, "zsh", parent: 200), row(202, "claude", parent: 201, cpu: 2),
                row(203, "cargo", parent: 202, cpu: 40)]
    let arguments: Arguments = [201: args("-zsh"), 202: args("claude"), 203: args("cargo", "build")]
    let out = CommandGroups.assign(rows, arguments: arguments)
    #expect(out.groups.first?.name == "cargo")
    #expect(try group(out.groups, "cargo").totalCpuPercent == 40)
    let zsh = try group(out.groups, "zsh")
    #expect(zsh.pids == [201, 202])
    #expect(zsh.copies == 1)
    #expect(zsh.totalCpuPercent == 2)
    #expect(!out.groups.contains { $0.name == "claude" })
    expectPartition(rows, out.groups)
}

// MARK: edges

@Test func anAgentWithNoStarterFormsItsOwnGroup() throws {
    // `claude` under launchd, a sub-agent under it, and `codex` under launchd too.
    let rows = [row(1, "launchd", parent: 0, uid: 0), row(300, "claude", cpu: 1), row(301, "claude", parent: 300, cpu: 2),
                row(302, "git", parent: 301, cpu: 3), row(400, "codex", cpu: 1)]
    let out = CommandGroups.assign(rows, arguments: [:])
    let claude = try group(out.groups, "claude")
    #expect(claude.pids == [300, 301])
    #expect(claude.copies == 1)
    #expect(try group(out.groups, "git").pids == [302])
    #expect(try group(out.groups, "codex").copies == 1)
    #expect(try group(out.groups, "launchd").pids == [1])
    expectPartition(rows, out.groups)
}

@Test func anAgentUnderAnAgentGoesWithTheFirstNonAgentAbove() throws {
    let rows = [row(100, "bash"), row(101, "node", parent: 100, cpu: 1), row(102, "codex", parent: 101, cpu: 2),
                row(103, "cli-proxy-api", parent: 102, cpu: 3), row(104, "make", parent: 103, cpu: 4)]
    let arguments: Arguments = [100: args("bash", script), 101: args("node", "/opt/claude-code/2.1.0/claude")]
    let out = CommandGroups.assign(rows, arguments: arguments)
    #expect(try group(out.groups, "runaway.sh").pids == [100, 101, 102, 103])
    #expect(try group(out.groups, "make").pids == [104])
    expectPartition(rows, out.groups)
}

@Test func aPlainExecutableOwnsNothingBelowIt() throws {
    let rows = [row(100, "make", cpu: 0.1), row(101, "clang", parent: 100, cpu: 50), row(102, "clang", parent: 100, cpu: 50),
                row(103, "bash", parent: 100), row(104, "yes", parent: 103, cpu: 10)]
    let arguments: Arguments = [103: args("bash", "gen.sh")]
    let out = CommandGroups.assign(rows, arguments: arguments)
    #expect(out.groups.map(\.name) == ["clang", "gen.sh", "make"])
    #expect(try group(out.groups, "clang").copies == 2)
    #expect(try group(out.groups, "gen.sh").pids == [103, 104])
    expectPartition(rows, out.groups)
}

@Test func aLoopOrAMissingParentEndsTheClimb() throws {
    // 700 ↔ 701 name each other as parent (a pid reused mid-read); 800's parent is not in the rows.
    let rows = [row(700, "bash", parent: 701), row(701, "yes", parent: 700, cpu: 1), row(800, "yes", parent: 9999),
                row(0, "kernel_task", parent: 0, cpu: 3, uid: 0)]
    let out = CommandGroups.assign(rows, arguments: [700: args("bash", script)])
    expectPartition(rows, out.groups)
    #expect(try group(out.groups, "kernel_task").pids == [0])
    #expect(try group(out.groups, "yes").pids.contains(800))
}

// MARK: the user's own shells and sessions (the gate's round 5, rule B)

@Test func aLoginShellIsDashArgumentZeroOrTheLoginOption() {
    func login(_ name: String, _ argv: [String]?) -> Bool { CommandGroups.isLoginShell(name: name, argv: argv) }
    #expect(login("zsh", ["-zsh"]) && login("zsh", ["-/bin/zsh"]) && login("bash", ["bash", "--login"]))
    #expect(login("zsh", ["zsh", "-l", "/tmp/example/open.zsh"]) && login("bash", ["bash", "-lc", "make"]))
    #expect(!login("zsh", ["/bin/zsh", "-c", "git status"]) && !login("bash", ["/bin/bash", script, "-l"]))
    #expect(!login("zsh", ["zsh"]) && !login("zsh", nil) && !login("claude", ["-claude"]))
}

/// Login shells, an interactive `claude` and its tool calls (the filter with what its copy owns, a bare `zsh -c`) are the
/// user's own; a build a bare tool shell runs starts a copy of its own and is not. A runaway started from a terminal
/// hands the terminal to its copies' agents, which stay the runaway's, and so do their tool calls.
@Test func theUsersOwnShellsAndSessions() {
    func tty(_ row: ProcessUsage) -> ProcessUsage {
        var row = row
        row.terminal = true
        return row
    }
    let rows = [
        tty(row(100, "zsh")), tty(row(101, "claude", parent: 100)),
        row(102, "bash", parent: 101), row(103, "zsh", parent: 102), row(104, "node", parent: 103),
        row(105, "zsh", parent: 101), row(106, "node", parent: 105),
        tty(row(200, "zsh", parent: 100)), tty(row(201, "claude", parent: 200)),
        tty(row(300, "bash", parent: 100)), tty(row(301, "claude", parent: 300)), row(302, "zsh", parent: 301),
        row(400, "zsh"),
    ]
    let arguments: Arguments = [
        100: args("-zsh"), 101: args("claude"), 102: args("bash", "/tmp/example/shell-prefix-filter.sh"),
        103: args("/bin/zsh", "-c", "node build.js"), 104: args("node", "/tmp/example/build.js"),
        105: args("/bin/zsh", "-c", "node build.js"), 106: args("node", "/tmp/example/build.js"),
        200: args("zsh", "-l", "/tmp/example/open.zsh"), 201: args("claude"),
        300: args("/bin/bash", script), 301: args("claude", "-p", "check"), 302: args("/bin/zsh", "-c", "make"),
        400: args("/bin/zsh", "-c", "sleep 9"),
    ]
    let out = CommandGroups.assign(rows, arguments: arguments)
    // The boundary is the interactive root and its launch wrappers (the filter, the shell it runs, a bare tool shell);
    // what a wrapper starts below that, `node build.js` under the filter's shell (104), is workload.
    #expect(Set(out.rows.filter(\.usersOwn).map(\.pid)) == [100, 101, 102, 103, 105, 200, 201])
}

/// An interactive `claude` (101, on a terminal under a login shell 100), the filter in front of its tool calls (102) with
/// the shell it runs (103) — and `workers` copies of `worker.sh` that shell started, attached to the session.
private func attachedFanOut(workers: Int = 30, alive: Bool = true) -> (rows: [ProcessUsage], arguments: Arguments) {
    func tty(_ row: ProcessUsage) -> ProcessUsage {
        var row = row
        row.terminal = true
        return row
    }
    var rows = [tty(row(100, "zsh")), tty(row(101, "claude", parent: 100)), row(102, "bash", parent: 101),
                row(103, "zsh", parent: 102)]
    var arguments: Arguments = [100: args("-zsh"), 101: args("claude"), 102: args("bash", "/tmp/example/shell-prefix-filter.sh"),
                                103: args("/bin/zsh", "-c", "./fan-out.sh")]
    if !alive { rows = rows.filter { $0.pid >= 200 } }
    for i in 0..<workers {
        let pid = Int32(200 + i)
        // Alive: attached to the tool shell. Not: the shell is gone and launchd holds them.
        rows.append(row(pid, "bash", parent: alive ? 103 : 1, cpu: 0.5))
        arguments[pid] = args("/bin/bash", "/tmp/example/worker.sh")
    }
    return (rows, arguments)
}

@Test func attachedFanOutBelowTheToolShellCountsAsCopiesOfItsOwn() throws {
    let fan = attachedFanOut()
    let out = CommandGroups.assign(fan.rows, arguments: fan.arguments)
    #expect(Set(out.rows.filter(\.usersOwn).map(\.pid)) == [100, 101, 102, 103])
    let workers = try group(out.groups, "worker.sh")
    #expect(workers.copies == 30)
    #expect(workers.pids.count == 30)
    // The filter's group holds the filter and the shell it ran, no more.
    #expect(try group(out.groups, "shell-prefix-filter.sh").pids == [102, 103])
    expectPartition(fan.rows, out.groups)
}

@Test func theSameFanOutOrphanedIsTheSameWorkload() throws {
    let fan = attachedFanOut(alive: false)
    let out = CommandGroups.assign(fan.rows, arguments: fan.arguments)
    #expect(out.rows.filter(\.usersOwn).isEmpty)
    #expect(try group(out.groups, "worker.sh").copies == 30)
}

@Test func aWrapperLoopAndAMissingParentStillEndTheClimb() {
    // 300 ↔ 301 name each other as parent below an interactive claude's filter; 302's parent is not in the rows.
    var claude = row(101, "claude", parent: 100)
    claude.terminal = true
    let rows = [claude, row(102, "bash", parent: 101), row(300, "zsh", parent: 301), row(301, "zsh", parent: 300),
                row(302, "node", parent: 9_999)]
    let arguments: Arguments = [101: args("claude"), 102: args("bash", "/tmp/example/shell-prefix-filter.sh"),
                                300: args("zsh", "-c", "x"), 301: args("zsh", "-c", "y"), 302: args("node", "/tmp/example/a.js")]
    let out = CommandGroups.assign(rows, arguments: arguments)
    expectPartition(rows, out.groups)
    #expect(Set(out.rows.filter(\.usersOwn).map(\.pid)) == [101, 102])
}

@Test func groupsAndCopiesGoByWhatTheyHold() throws {
    // Two copies: one over a busy child, one idle; a group tie at 2.0% goes by name.
    let rows = [row(100, "bash"), row(101, "yes", parent: 100, cpu: 3), row(102, "bash", cpu: 0.5),
                row(103, "sleep", parent: 100), row(200, "beta", cpu: 2), row(300, "alpha", cpu: 2)]
    let arguments: Arguments = [100: args("bash", script), 102: args("bash", script)]
    let out = CommandGroups.assign(rows, arguments: arguments)
    #expect(out.groups.map(\.name) == ["runaway.sh", "alpha", "beta"])
    let copies = try group(out.groups, "runaway.sh")
    #expect(copies.pids == [100, 101, 103, 102])
    let depths = CommandGroups.depths(copies.pids, parents: CommandGroups.parents(rows))
    #expect(depths == [100: 0, 101: 1, 103: 1, 102: 0])
}

@Test func depthsFromOneParentMapMatchEachGroupsOwn() throws {
    // The gate's runaway shape (round 1, F28): script copies over `claude` over `node build.js`, a plain `make` over
    // its compilers, and a nested copy — every group's depths read from one parent map built once; the CLI's
    // `--by command` table from one map a sample (round 2), in the same order and indents as each group's own map gave.
    var rows = [row(100, "make", cpu: 0.1), row(101, "clang", parent: 100, cpu: 50), row(102, "clang", parent: 100, cpu: 40)]
    var arguments: Arguments = [:]
    for i in 0..<3 {
        let pid = Int32(1_000 + i * 4)
        rows += [row(pid, "bash"), row(pid + 1, "claude", parent: pid, cpu: 0.2), row(pid + 2, "node", parent: pid + 1, cpu: 5),
                 row(pid + 3, "sleep", parent: pid + 2)]
        arguments[pid] = args("bash", script)
        arguments[pid + 2] = args("node", "/tmp/example/build.js")
    }
    let out = CommandGroups.assign(rows, arguments: arguments)
    let parents = CommandGroups.parents(rows)
    #expect(out.groups.map(\.name) == ["clang", "build.js", "runaway.sh", "make"])
    #expect(CommandGroups.depths(try group(out.groups, "runaway.sh").pids, parents: parents)
            == [1_000: 0, 1_001: 1, 1_004: 0, 1_005: 1, 1_008: 0, 1_009: 1])
    #expect(CommandGroups.depths(try group(out.groups, "build.js").pids, parents: parents)
            == [1_002: 0, 1_003: 1, 1_006: 0, 1_007: 1, 1_010: 0, 1_011: 1])

    let work = WorkCount()
    let table = WorkCount.current.withValue(work) {
        ProcessSample.table(out.rows, commandGroups: out.groups, by: .command)
    }
    #expect(work.parentMaps == 1)
    // Each member's line, in order: its pid and its name's indent (two spaces a level).
    let members = table.split(separator: "\n").compactMap { line -> (Int32, Int)? in
        guard let pid = line.split(separator: " ").first.flatMap({ Int32($0) }),
              let name = out.rows.first(where: { $0.pid == pid })?.name,
              let at = line.range(of: " " + name, options: .backwards) else { return nil }
        let indent = line[..<at.lowerBound].reversed().prefix { $0 == " " }.count
        return (pid, indent)
    }
    let expected = out.groups.flatMap { group in
        let depths = CommandGroups.depths(group.pids, parents: CommandGroups.parents(rows.filter { group.pids.contains($0.pid) }))
        return group.pids.map { ($0, depths[$0] ?? 0) }
    }
    #expect(members.map(\.0) == expected.map(\.0))
    let base = members.first.map(\.1) ?? 0
    #expect(members.map { ($0.1 - base) / 2 } == expected.map(\.1))
}

@Test func commandGroupJSONIsTheRepoShapePlusCopies() throws {
    let out = CommandGroups.assign([row(100, "bash", cpu: 0.123), row(101, "yes", parent: 100, cpu: 1, exited: 0.456)],
                                   arguments: [100: args("bash", script)])
    let data = try JSONEncoder().encode(try #require(out.groups.first))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["name", "copies", "cpuPercent", "exitedChildrenCpuPercent", "residentBytes", "disk",
                                 "network", "pids"])
    #expect(object["name"] as? String == "runaway.sh")
    #expect(object["copies"] as? Int == 1)
    #expect(object["cpuPercent"] as? Double == 1.12)
    #expect(object["exitedChildrenCpuPercent"] as? Double == 0.46)
    #expect(object["pids"] as? [Int] == [100, 101])
}
