// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the warnings (Phase 6 Step 5) — five conditions, each held before it fires and cleared below 7/8 of its bar,
// one line per runaway keyed by the command or group it names, machine-wide conditions joined to it, an agent never
// the subject. Method: tick series built in code from the research probe's and the incident's figures
// (research 2026-10-22 § The live probe, § What the incident looked like) on an 18-CPU machine, one tick a second.

private let cpus = 18
private let script = "/tmp/example/shell-prefix-check.sh"

private func row(_ pid: Int32, _ name: String, parent: Int32 = 1, cpu: Double = 0, exited: Double = 0,
                 terminal: Bool = false) -> ProcessUsage {
    var row = ProcessUsage(pid: pid, ppid: parent, uid: 501, user: "user", path: "/usr/bin/" + name, name: name,
                           cpuPercent: cpu, residentBytes: 1 << 20, source: .libproc, exitedChildrenCpuPercent: exited)
    row.terminal = terminal
    return row
}

/// An agent at 2.6% of a core, the least any `claude` on the research Mac averaged over a minute (research
/// 2026-10-25 § Trigger 2), as a share of the machine.
private let quietAgent = 2.6 / Double(cpus)

private func args(_ argv: String...) -> ProcessArguments { ProcessArguments(argv: argv, environment: [:]) }

/// A process set: its rows and their arguments.
private struct Processes {
    var rows: [ProcessUsage] = []
    var arguments: [Int32: ProcessArguments] = [:]

    mutating func add(_ row: ProcessUsage, _ argv: ProcessArguments? = nil) {
        rows.append(row)
        if let argv { arguments[row.pid] = argv }
    }
}

private func session(_ name: String, _ cpu: Double, pids: [Int32] = [], kind: SessionKind? = .claude) -> SessionGroup {
    SessionGroup(name: name, kind: kind, id: kind == nil ? nil : name, cpuPercent: cpu, exitedChildrenCpuPercent: 0,
                 residentBytes: 0, pids: pids)
}

private func repo(_ name: String, _ cpu: Double, pids: [Int32] = [], root: String? = "/work/example") -> RepoGroup {
    RepoGroup(name: name, root: root, cpuPercent: cpu, exitedChildrenCpuPercent: 0, residentBytes: 0, pids: pids)
}

/// One window ending at `t`, `span` long.
private func tick(_ t: Double, span: Double = 1, unattributed: Double? = 5.6, load: Double? = 53.6,
                  system: Double? = 22, processes: Processes = Processes(), repos: [RepoGroup] = [],
                  sessions: [SessionGroup] = []) -> WarningTick {
    let commands = CommandGroups.assign(processes.rows, arguments: processes.arguments)
    return WarningTick(end: t, seconds: span, cpus: cpus, unattributedCpuPercent: unattributed,
                       loadAverage: load.map { LoadAverage(oneMinute: $0, fiveMinutes: $0, fifteenMinutes: $0) },
                       split: system.map { CPUSplit(user: 100 - $0, system: $0) }, rows: commands.rows,
                       commandGroups: commands.groups, repoGroups: repos, sessionGroups: sessions)
}

/// The probe's rest under another line's test run: copies of Apple services and shells under launchd at 0%.
private func rest() -> Processes {
    var p = Processes()
    var pid: Int32 = 2_000
    for (name, count) in [("SetStoreUpdateService", 44), ("cat", 23), ("distnoted", 21)] {
        for _ in 0..<count {
            p.add(row(pid, name))
            pid += 1
        }
    }
    for _ in 0..<30 {
        p.add(row(pid, "zsh", terminal: true), args("-zsh"))
        pid += 1
    }
    return p
}

/// The 2026-10-22 shape at second `t` of the storm: `count` copies of the script under launchd, each over a headless
/// `claude` (the incident's 13.2% over 69 of them); every 20 s a new generation of pids replaces the last.
private func storm(_ count: Int, generation: Int, cpuEach: Double = 13.2 / 69) -> Processes {
    var p = rest()
    for i in 0..<count {
        let pid = Int32(10_000 + generation * 1_000 + i * 2)
        p.add(row(pid, "bash"), args("/bin/bash", script))
        p.add(row(pid + 1, "claude", parent: pid, cpu: cpuEach), args("claude", "-p", "check"))
    }
    return p
}

/// The gate's runaway (round 1, F43): `count` copies of the script, each over a headless `claude` running a busy
/// `node build.js`; past the first `underClaude` copies, build.js is started under launchd instead.
private func buildStorm(_ count: Int, underClaude: Int? = nil) -> Processes {
    var p = rest()
    for i in 0..<count {
        let pid = Int32(10_000 + i * 3)
        p.add(row(pid, "bash"), args("/bin/bash", script))
        p.add(row(pid + 1, "claude", parent: pid, cpu: 13.2 / 69), args("claude", "-p", "check"))
        p.add(row(pid + 2, "node", parent: i < (underClaude ?? count) ? pid + 1 : 1, cpu: 0.5),
              args("node", "/tmp/example/build.js"))
    }
    return p
}

/// The gate's runaway through an agent's tool shells (round 2): `count` copies of the script, each over a headless
/// `claude` whose tool call runs `zsh -c` — behind `bash shell-prefix-filter.sh` when `filter`, as on this Mac — over a
/// busy `node build.js`; each tool shell carries what its finished commands used (`toolExited`, exited CPU), each agent
/// uses `agentCpu`.
private func toolStorm(_ count: Int, filter: Bool = false, toolExited: Double = 0.3,
                       agentCpu: Double = 13.2 / 69) -> Processes {
    var p = rest()
    for i in 0..<count {
        let pid = Int32(10_000 + i * 5)
        p.add(row(pid, "bash"), args("/bin/bash", script))
        p.add(row(pid + 1, "claude", parent: pid, cpu: agentCpu), args("claude", "-p", "check"))
        if filter { p.add(row(pid + 2, "bash", parent: pid + 1), args("bash", "/tmp/example/shell-prefix-filter.sh")) }
        p.add(row(pid + 3, "zsh", parent: filter ? pid + 2 : pid + 1, exited: toolExited),
              args("/bin/zsh", "-c", "node /tmp/example/build.js"))
        p.add(row(pid + 4, "node", parent: pid + 3, cpu: 0.5), args("node", "/tmp/example/build.js"))
    }
    return p
}

/// `toolStorm` with its tool calls stopped: each agent waiting on the model, its tool shells and what they ran gone.
private func withoutToolCalls(_ p: Processes) -> Processes {
    var p = p
    p.rows = p.rows.filter { $0.pid < 10_000 || ($0.pid - 10_000) % 5 < 2 }
    return p
}

/// `toolStorm` with its script copies killed from a terminal: the agents, now under launchd, work on.
private func copiesKilled(_ p: Processes) -> Processes {
    var p = p
    p.rows = p.rows.filter { $0.pid < 10_000 || ($0.pid - 10_000) % 5 != 0 }
        .map { $0.name == "claude" && $0.pid >= 10_000 ? row($0.pid, "claude", cpu: $0.cpuPercent) : $0 }
    return p
}

/// The login shells `rest()` holds: `-zsh` under launchd at 0%, each with a terminal.
private let loginShells = Set((2_088 as Int32)..<2_118)

/// The user's own session: their interactive `claude` (with a terminal) under login shell 2088 running three tool calls,
/// each a `zsh -c` — behind `bash shell-prefix-filter.sh` when `filter` — at rest; pids 3000–3006.
private let userSession = Set((3_000 as Int32)..<3_007)

private func addUserSession(_ p: inout Processes, filter: Bool) {
    p.add(row(3_000, "claude", parent: 2_088, cpu: 1, terminal: true), args("claude"))
    for i in 0..<3 {
        let pid = Int32(3_001 + i * 2)
        if filter { p.add(row(pid, "bash", parent: 3_000), args("bash", "/tmp/example/shell-prefix-filter.sh")) }
        p.add(row(pid + 1, "zsh", parent: filter ? pid : 3_000), args("/bin/zsh", "-c", "git status"))
    }
}

private func subjects(_ warnings: [Warning]) -> [Warning.Subject] { warnings.map(\.subject) }

private func has(_ warning: Warning, _ kind: Warning.Kind) -> Bool { warning.conditions.contains { $0.kind == kind } }

// MARK: the step's cases

@Test func stormBFiresUnattributedAfterTenSeconds() {
    var engine = WarningEngine()
    for t in 1...60 { #expect(engine.next(tick(Double(t), unattributed: t % 2 == 0 ? 5.6 : 4.5)).isEmpty) }
    for s in 1...18 {
        let warnings = engine.next(tick(Double(60 + s), unattributed: s % 2 == 0 ? 22.3 : 25.0, load: 59.5))
        if s < 10 {
            #expect(warnings.isEmpty, "second \(s)")
        } else {
            #expect(subjects(warnings) == [.machine], "second \(s)")
            #expect(warnings.first?.conditions.map(\.kind) == [.unattributed])
        }
    }
}

@Test func restingTestRunFiresNone() {
    var engine = WarningEngine()
    let processes = rest()
    for t in 1...300 {
        let load = [52.8, 53.6, 58.8, 63.0][t % 4]
        let busy = [56.0, 68.0, 80.0][t % 3]
        let warnings = engine.next(tick(Double(t), unattributed: t % 2 == 0 ? 5.6 : 4.5, load: load, system: 22,
                                        processes: processes, repos: [repo("example-repo", busy)],
                                        sessions: [session("test-run", busy)]))
        #expect(warnings.isEmpty, "second \(t): \(warnings.map(\.subject))")
    }
}

@Test func warningClearsOnlyBelowItsLowerBar() {
    var engine = WarningEngine()
    var t = 0.0
    func next(_ unattributed: Double) -> [Warning] {
        t += 1
        return engine.next(tick(t, unattributed: unattributed))
    }
    for _ in 1...10 { _ = next(25) }
    #expect(subjects(next(25)) == [.machine])
    for s in 1...60 { #expect(subjects(next(14)) == [.machine], "14% second \(s)") }
    for s in 1...9 { #expect(subjects(next(13)) == [.machine], "13% second \(s)") }
    #expect(next(13).isEmpty)
}

@Test func seventyFiveCopiesGiveOneWarningNamingTheScript() {
    var engine = WarningEngine()
    for t in 1...60 { _ = engine.next(tick(Double(t), processes: rest())) }
    var fired = false
    for s in 1...900 {
        let t = 60 + s
        let count = s <= 60 ? s * 75 / 60 : 70 + [-10, 0, 10, 5][s % 4]
        let load = min(96, 41 + Double(s) * 0.1)
        let warnings = engine.next(tick(Double(t), unattributed: 20, load: load, system: 54,
                                        processes: storm(count, generation: s / 20)))
        #expect(warnings.count <= 1, "second \(s): \(warnings.map(\.subject))")
        if warnings.contains(where: { has($0, .copies) }) { fired = true }
        guard fired else { continue }
        #expect(warnings.count == 1, "second \(s)")
        guard let warning = warnings.first else { continue }
        #expect(warning.subject == .command("shell-prefix-check.sh"))
        #expect(warning.name == "shell-prefix-check.sh × \(count)")
        #expect(has(warning, .copies) && has(warning, .systemShare) && has(warning, .unattributed))
        if s >= 400 { #expect(has(warning, .load)) }
    }
    #expect(fired)
}

@Test func swarmOfClaudeWithNoScriptGivesNoCopiesWarning() {
    // The driver (`bun`) → `zsh -c '… exec claude-max …'` → `claude` (research 2026-10-19-swarm-members), under a lead
    // session's `claude`; and the same members straight under launchd.
    func members(_ count: Int, underLaunchd: Bool) -> Processes {
        var p = rest()
        p.add(row(300, "zsh"), args("-zsh"))
        p.add(row(400, "claude", parent: 300), args("claude"))
        p.add(row(500, "bun", parent: 400), args("bun", "/opt/swarm/src/swarm/cli.ts", "run"))
        for i in 0..<count {
            let pid = Int32(600 + i * 2)
            if underLaunchd {
                p.add(row(pid + 1, "claude", cpu: 2), args("claude", "-p", "brief"))
            } else {
                p.add(row(pid, "zsh", parent: 500), args("zsh", "-c", "source wrappers.zsh; exec claude-max \"$@\""))
                p.add(row(pid + 1, "claude", parent: pid, cpu: 2), args("claude", "-p", "brief"))
            }
        }
        return p
    }
    for underLaunchd in [false, true] {
        var engine = WarningEngine()
        for t in 1...30 { _ = engine.next(tick(Double(t), processes: members(0, underLaunchd: underLaunchd))) }
        for s in 1...120 {
            let warnings = engine.next(tick(Double(30 + s), processes: members(min(30, s), underLaunchd: underLaunchd)))
            #expect(!warnings.contains { has($0, .copies) }, "second \(s), under launchd \(underLaunchd)")
            #expect(!subjects(warnings).contains(.command("zsh")) && !subjects(warnings).contains(.command("claude")))
        }
    }
}

// MARK: the conditions' edges

@Test func copiesNeedCountGrowthAndCPU() {
    func run(_ processes: (Int) -> Processes) -> Bool {
        var engine = WarningEngine()
        var fired = false
        for t in 1...120 where engine.next(tick(Double(t), processes: processes(t))).contains(where: { has($0, .copies) }) {
            fired = true
        }
        return fired
    }
    func copies(_ count: Int, cpuEach: Double) -> Processes {
        var p = Processes()
        for i in 0..<count {
            p.add(row(Int32(10_000 + i * 2), "bash"), args("/bin/bash", script))
            p.add(row(Int32(10_001 + i * 2), "perl", parent: Int32(10_000 + i * 2), cpu: cpuEach), args("perl", "-e", "1"))
        }
        return p
    }
    #expect(!run { _ in copies(30, cpuEach: 0.2) }, "flat since the first tick")
    #expect(!run { t in copies(t < 30 ? 0 : 30, cpuEach: 4.0 / 30) }, "30 new copies at 4%")
    #expect(!run { t in copies(t < 30 ? 0 : 19, cpuEach: 2) }, "19 new copies at 38%")
    #expect(run { t in copies(t < 30 ? 0 : 30, cpuEach: 0.2) }, "30 new copies at 6%")
}

@Test func newCopiesGrowFromNone() {
    var engine = WarningEngine()
    for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
    var last: [Warning] = []
    for t in 21...40 { last = engine.next(tick(Double(t), processes: storm(30, generation: 0))) }
    guard case .copies(let count, let growth, let percent) = last.first?.conditions.first(where: { $0.kind == .copies }) else {
        Issue.record("no copies condition")
        return
    }
    #expect(count == 30 && growth == 30)
    #expect(abs(percent - 30 * 13.2 / 69) < 1e-9)
}

@Test func copiesStayWarnedOnceGrowthStops() {
    var engine = WarningEngine()
    _ = engine.next(tick(1, processes: rest()))
    for t in 2...600 {
        let warnings = engine.next(tick(Double(t), processes: storm(75, generation: 0)))
        if t >= 12 { #expect(warnings.contains { has($0, .copies) }, "second \(t)") }
    }
}

@Test func copiesClearBelowSeventeenAndAHalf() {
    var engine = WarningEngine()
    _ = engine.next(tick(1, processes: rest()))
    // Half a point a copy, so 17 and 18 copies stay above the CPU part's lower bar (4.375%).
    func copies(_ count: Int) -> Processes { storm(count, generation: 0, cpuEach: 0.5) }
    for t in 2...20 { _ = engine.next(tick(Double(t), processes: copies(75))) }
    for t in 21...60 { #expect(!engine.next(tick(Double(t), processes: copies(18))).isEmpty) }
    for t in 61...69 { #expect(!engine.next(tick(Double(t), processes: copies(17))).isEmpty) }
    #expect(engine.next(tick(70, processes: copies(17))).isEmpty)
}

@Test func loadFiresAfterSixtySecondsRising() {
    var falling = WarningEngine()
    for t in 1...120 { #expect(falling.next(tick(Double(t), load: 90 - Double(t) * 0.1)).isEmpty) }
    var rising = WarningEngine()
    for t in 1...59 { #expect(rising.next(tick(Double(t), load: 73 + Double(t) * 0.1)).isEmpty) }
    let fired = rising.next(tick(60, load: 79))
    #expect(subjects(fired) == [.machine] && fired.first.map { has($0, .load) } == true)
    // Clears below 3.5 × 18 = 63 after 10 s below it.
    for t in 61...100 { #expect(!rising.next(tick(Double(t), load: 64)).isEmpty) }
    for t in 101...109 { #expect(!rising.next(tick(Double(t), load: 62)).isEmpty) }
    #expect(rising.next(tick(110, load: 62)).isEmpty)
}

@Test func systemShareFiresAtThirtySeconds() {
    var engine = WarningEngine()
    for t in 1...29 { #expect(engine.next(tick(Double(t), system: 41)).isEmpty) }
    #expect(engine.next(tick(30, system: 41)).first?.conditions.map(\.kind) == [.systemShare])
}

@Test func groupFiresAtTenMinutesNeverForVMsOrCatchAlls() {
    var engine = WarningEngine()
    let others = [repo(RepoGroups.vms, 90, root: nil), repo(RepoGroups.notInARepo, 90, root: nil),
                  repo(RepoGroups.systemAndOtherUsers, 90, root: nil)]
    let otherSessions = [session(SessionGroups.vms, 90, kind: nil), session(SessionGroups.noSession, 90, kind: nil)]
    for t in 1...599 {
        #expect(engine.next(tick(Double(t), sessions: [session("long-build", 30)] + otherSessions)).isEmpty, "second \(t)")
    }
    let fired = engine.next(tick(600, sessions: [session("long-build", 30)] + otherSessions))
    #expect(subjects(fired) == [.session("long-build")])
    #expect(fired.first?.name == "long-build (session)")
    var catchAlls = WarningEngine()
    for t in 1...900 { #expect(catchAlls.next(tick(Double(t), repos: others, sessions: otherSessions)).isEmpty) }
}

// MARK: one line per runaway

@Test func groupsJoinTheCommandLineAndEachOther() {
    var engine = WarningEngine()
    _ = engine.next(tick(1, processes: rest()))
    var last: [Warning] = []
    for t in 2...700 {
        let p = storm(75, generation: 0)
        let pids = p.rows.filter { $0.pid >= 10_000 }.map(\.pid)
        last = engine.next(tick(Double(t), processes: p, repos: [repo("tmp-repo", 30, pids: pids)],
                                sessions: [session("lead", 30, pids: pids)]))
    }
    #expect(subjects(last) == [.command("shell-prefix-check.sh")])
    #expect(last.first?.conditions.filter { $0.kind == .group }.count == 2)

    // No command line: the repo and the session over the same processes give one line, named by the session.
    var groups = WarningEngine()
    var line: [Warning] = []
    let p = rest()
    for t in 1...600 {
        line = groups.next(tick(Double(t), processes: p, repos: [repo("example-repo", 30, pids: [2_000, 2_001])],
                                sessions: [session("build", 30, pids: [2_000])]))
    }
    #expect(subjects(line) == [.session("build")])
}

@Test func aCommandStartedThroughAnAgentByEveryCopyJoinsTheScriptLine() {
    var engine = WarningEngine()
    _ = engine.next(tick(1, processes: rest()))
    let p = buildStorm(75)
    var last: [Warning] = []
    for t in 2...30 { last = engine.next(tick(Double(t), processes: p)) }
    #expect(subjects(last) == [.command("shell-prefix-check.sh")])
    guard let line = last.first else { return }
    #expect(line.name == "shell-prefix-check.sh × 75")
    #expect(line.conditions.filter { $0.kind == .copies }.count == 1, "build.js's copies join it, raising nothing")
    let builds = p.rows.filter { $0.name == "node" }.map(\.pid)
    #expect(Set(builds).isSubset(of: line.pids))
    #expect(line.heaviest.map(builds.contains) == true, "a busy build.js")
    #expect(abs(line.cpuPercent - 75 * (13.2 / 69 + 0.5)) < 1e-9)
}

@Test func aCommandStartedUnderOnlySomeCopiesKeepsItsOwnLine() {
    var engine = WarningEngine()
    _ = engine.next(tick(1, processes: rest()))
    var last: [Warning] = []
    for t in 2...30 { last = engine.next(tick(Double(t), processes: buildStorm(75, underClaude: 40))) }
    #expect(Set(subjects(last)) == [.command("shell-prefix-check.sh"), .command("build.js")])
}

/// The gate's round 2: the stock Mac's shape — each tool call a `zsh -c` under `claude`, the same command as the login
/// shells, busy enough with its finished commands to warn on its own — gives one line naming the script, carrying the
/// tool shells and build.js; and the same behind this Mac's `bash shell-prefix-filter.sh`, with the user's own session
/// running three tool calls of its own at rest.
@Test func aRunawayThroughAnAgentsToolShellsGivesOneLine() {
    for filter in [false, true] {
        var engine = WarningEngine()
        for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
        var p = toolStorm(30, filter: filter)
        if filter {
            // The user's own `claude` under a login shell, each tool call behind the filter.
            p.add(row(3_000, "claude", parent: 2_088), args("claude"))
            for i in 0..<3 {
                let pid = Int32(3_001 + i * 2)
                p.add(row(pid, "bash", parent: 3_000), args("bash", "/tmp/example/shell-prefix-filter.sh"))
                p.add(row(pid + 1, "zsh", parent: pid), args("/bin/zsh", "-c", "git status"))
            }
        }
        var last: [Warning] = []
        for t in 21...60 {
            last = engine.next(tick(Double(t), processes: p))
            if t >= 32 { #expect(last.count == 1, "filter \(filter), second \(t): \(subjects(last))") }
        }
        #expect(subjects(last) == [.command("shell-prefix-check.sh")], "filter \(filter)")
        guard let line = last.first else { continue }
        #expect(line.name == "shell-prefix-check.sh × 30")
        let tools = p.rows.filter { $0.pid >= 10_000 && ($0.name == "zsh" || $0.name == "node") }.map(\.pid)
        #expect(tools.count == 60 && Set(tools).isSubset(of: line.pids), "the tool shells' and build.js's pids")
        #expect(line.pids.allSatisfy { $0 >= 10_000 }, "nothing of the user's own session")
        #expect(abs(line.cpuPercent - 30 * (13.2 / 69 + 0.3 + 0.5)) < 1e-9)
    }
}

/// The gate's round 2: thirty login shells opened beside the runaway — the tool shells' command, grown by 30 — stay
/// off its line and raise no line of their own.
@Test func loginShellsBesideARunawayStayOffItsLine() {
    var engine = WarningEngine()
    for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
    var p = toolStorm(30)
    for i in 0..<30 { p.add(row(Int32(4_000 + i), "zsh"), args("-zsh")) }
    var last: [Warning] = []
    for t in 21...60 { last = engine.next(tick(Double(t), processes: p)) }
    #expect(subjects(last) == [.command("shell-prefix-check.sh")])
    #expect(last.first.map { $0.pids.allSatisfy { !loginShells.contains($0) && !(4_000..<4_030).contains($0) } } == true)
}

/// The gate's round 2: a command with copies under the runaway and outside it — the outside copies warn only on their
/// own figures: ten stay under the bar, thirty-five meet it alone and their line names only them.
@Test func copiesOutsideTheRunawayWarnOnTheirOwnFigures() {
    func run(underClaude: Int) -> [Warning] {
        var engine = WarningEngine()
        _ = engine.next(tick(1, processes: rest()))
        var last: [Warning] = []
        for t in 2...30 { last = engine.next(tick(Double(t), processes: buildStorm(75, underClaude: underClaude))) }
        return last
    }
    #expect(subjects(run(underClaude: 65)) == [.command("shell-prefix-check.sh")], "ten outside, under the bar")
    let both = run(underClaude: 40)
    let builds = buildStorm(75, underClaude: 40).rows.filter { $0.name == "node" }
    let outside = Set(builds.filter { $0.ppid == 1 }.map(\.pid)), inside = Set(builds.filter { $0.ppid != 1 }.map(\.pid))
    guard let own = both.first(where: { $0.subject == .command("build.js") }),
          let script = both.first(where: { $0.subject == .command("shell-prefix-check.sh") }) else {
        Issue.record("two lines: \(subjects(both))")
        return
    }
    #expect(own.name == "build.js × 35" && Set(own.pids) == outside)
    #expect(inside.isSubset(of: script.pids) && outside.isDisjoint(with: script.pids))
}

/// A command started through the script's agents never warns before the script (the gate's round 5, rule A; round 3
/// had build.js warn first while the agents idled): its copies count toward the script from the first window. With the
/// script ignored, its copies warn on their own.
@Test func aCommandStartedThroughAScriptsAgentsNeverWarnsFirst() {
    func processes(_ t: Int) -> Processes {
        var p = buildStorm(75)
        if t < 25 { p.rows = p.rows.map { $0.name == "claude" ? row($0.pid, "claude", parent: $0.ppid) : $0 } }
        return p
    }
    var engine = WarningEngine()
    _ = engine.next(tick(1, processes: rest()))
    for t in 2...60 {
        let last = engine.next(tick(Double(t), processes: processes(t)))
        #expect(subjects(last) == (t < 11 ? [] : [.command("shell-prefix-check.sh")]), "second \(t)")
    }

    var ignoring = WarningEngine()
    let ignored: Set<Warning.Subject> = [.command("shell-prefix-check.sh")]
    _ = ignoring.next(tick(1, processes: rest()), ignoring: ignored)
    var last: [Warning] = []
    for t in 2...40 { last = ignoring.next(tick(Double(t), processes: buildStorm(75)), ignoring: ignored) }
    #expect(subjects(last) == [.command("build.js")])
    #expect(last.first?.name == "build.js × 75")
}

/// The gate's round 3: the runaway's line raises and clears on everything it took in. The headless agents go quiet
/// waiting on their tool calls (about 0.05% each) while the builds work on: one line throughout, never cleared, never
/// two, its condition showing the line's own figure.
@Test func aRunawayLineHoldsWhileItsAgentsWaitOnTheirTools() {
    for filter in [false, true] {
        var engine = WarningEngine()
        for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
        var raised = false
        for t in 21...90 {
            let p = toolStorm(30, filter: filter, agentCpu: t <= 45 ? 13.2 / 69 : 0.05)
            let last = engine.next(tick(Double(t), processes: p))
            raised = raised || !last.isEmpty
            guard raised else { continue }
            #expect(subjects(last) == [.command("shell-prefix-check.sh")], "filter \(filter), second \(t)")
            if let line = last.first, case .copies(_, _, let percent)? = line.conditions.first {
                #expect(abs(percent - line.cpuPercent) < 1e-9, "filter \(filter), second \(t)")
            }
        }
        #expect(raised, "filter \(filter)")
    }
}

/// Copies started one a second beside the user's own `claude` and the thirty login shells. Round 3 had the tool shells'
/// command warn first, holding the login shells; with rules A and B (the gate's round 5) the login shells and the
/// user's session count as no copies, and the tool shells count toward the script once it has 18 copies: the only
/// line ever raised is the script's, holding none of them.
@Test func aRunawayGrowingBesideTheUsersShellsGivesOnlyItsLine() {
    func processes(_ copies: Int) -> Processes {
        var p = toolStorm(copies)
        addUserSession(&p, filter: false)
        return p
    }
    var engine = WarningEngine()
    for t in 1...20 { _ = engine.next(tick(Double(t), processes: processes(0))) }
    var scriptUp = false
    for t in 21...80 {
        let last = engine.next(tick(Double(t), processes: processes(min(30, t - 20))))
        scriptUp = scriptUp || !last.isEmpty
        #expect(last.allSatisfy { $0.subject == .command("shell-prefix-check.sh") }, "second \(t): \(subjects(last))")
        #expect(usersOwnOnALine(last).isEmpty, "second \(t)")
    }
    #expect(scriptUp)
}

/// The gate's round 3: the builds count toward the script's line from the first window, the agents idling (round 3
/// had build.js warn first; round 5, rule A), then every build ends inside the line's clear hold: no empty build.js line
/// beside the script's; with the agents stopped too, the Dock's badge goes off with the script's line.
@Test func aFullyJoinedCommandLeavesNoEmptyLineAsItEnds() {
    func processes(_ t: Int, agentsStop: Bool) -> Processes {
        var p = buildStorm(75)
        let agentCpu = t < 25 || (agentsStop && t >= 38) ? 0 : 13.2 / 69
        p.rows = p.rows.filter { t < 38 || $0.name != "node" }
            .map { $0.name == "claude" ? row($0.pid, "claude", parent: $0.ppid, cpu: agentCpu) : $0 }
        return p
    }
    for agentsStop in [false, true] {
        var engine = WarningEngine()
        _ = engine.next(tick(1, processes: rest()))
        var last: [Warning] = []
        for t in 2...70 {
            last = engine.next(tick(Double(t), processes: processes(t, agentsStop: agentsStop)))
            if t == 21 { #expect(subjects(last) == [.command("shell-prefix-check.sh")], "the script first") }
            guard t >= 35 else { continue }
            #expect(last.allSatisfy { $0.subject == .command("shell-prefix-check.sh") && !$0.pids.isEmpty },
                    "agents stop \(agentsStop), second \(t): \(subjects(last))")
            if agentsStop, t >= 48 { #expect(!DockLevel.badge(last, ignoring: []), "second \(t)") }
        }
        #expect(subjects(last) == (agentsStop ? [] : [.command("shell-prefix-check.sh")]), "agents stop \(agentsStop)")
    }
}

/// The gate's round 3: behind the filter, its copies busy with the builds while the agents idle, then the agents work.
/// Round 3 had the filter's command warn first; with rule A (round 5) its copies count toward the script from the
/// first window: one line, the script's, with the user's own session behind the filter left off it.
@Test func aToolCallFilterNeverWarnsInItsScriptsPlace() {
    func processes(_ t: Int) -> Processes {
        var p = toolStorm(t <= 20 ? 0 : 30, filter: true, agentCpu: t < 40 ? 0 : 13.2 / 69)
        addUserSession(&p, filter: true)
        return p
    }
    var engine = WarningEngine()
    var last: [Warning] = []
    for t in 1...80 {
        last = engine.next(tick(Double(t), processes: processes(t)))
        #expect(last.allSatisfy { $0.subject == .command("shell-prefix-check.sh") }, "second \(t): \(subjects(last))")
        if t == 39 { #expect(subjects(last) == [.command("shell-prefix-check.sh")], "the script first") }
        guard t >= 50 else { continue }
        #expect(subjects(last) == [.command("shell-prefix-check.sh")], "second \(t)")
        #expect(last.allSatisfy { $0.pids.allSatisfy { !userSession.contains($0) } }, "second \(t)")
    }
}

/// The lines in force that hold a login shell or a pid of the user's own session, as the bar's Pause and Stop see them.
private func usersOwnOnALine(_ warnings: [Warning]) -> [String] {
    WarningBar.lines(warnings, table: []).filter { $0.pids.contains { loginShells.contains($0) || userSession.contains($0) } }
        .map(\.name)
}

/// The gate's round 5 (research 2026-10-25 § Item 3, rule A): 25 copies whose agents idle at 2.6% of a core never
/// carry 5% of the machine alone, so the tool shells' `zsh` (or the filter) and `build.js` warned in the script's
/// place, the `zsh` line holding the login shells. The work counts toward the script before it raises: the only line
/// ever raised names it.
@Test func aRunawayWithQuietAgentsWarnsUnderItsScript() {
    for filter in [false, true] {
        var engine = WarningEngine()
        for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
        var p = toolStorm(25, filter: filter, agentCpu: quietAgent)
        addUserSession(&p, filter: filter)
        var last: [Warning] = []
        for t in 21...90 {
            last = engine.next(tick(Double(t), processes: p))
            #expect(last.allSatisfy { $0.subject == .command("shell-prefix-check.sh") },
                    "filter \(filter), second \(t): \(subjects(last))")
            #expect(usersOwnOnALine(last).isEmpty, "filter \(filter), second \(t)")
        }
        #expect(last.map(\.name) == ["shell-prefix-check.sh × 25"], "filter \(filter)")
        #expect(last.first.map { abs($0.cpuPercent - 25 * (quietAgent + 0.3 + 0.5)) < 1e-9 } == true)
    }
}

/// Rule A with the targets counted before any join: on the storm's first window, nothing raised yet, the script's
/// figure already carries the work its agents started, and no other command is followed; no settling pass is needed.
@Test func aScriptCountsItsAgentsWorkBeforeItRaises() {
    var engine = WarningEngine()
    _ = engine.next(tick(1, processes: rest()))
    _ = engine.next(tick(2, processes: toolStorm(25, filter: true, agentCpu: quietAgent)))
    #expect(engine.raisedSubjects.isEmpty)
    guard case .copies(let count, _, let percent)? = engine.commands["shell-prefix-check.sh"]?.condition else {
        Issue.record("the script is not followed: \(engine.commands.keys.sorted())")
        return
    }
    #expect(count == 25 && abs(percent - 25 * (quietAgent + 0.3 + 0.5)) < 1e-9)
    #expect(engine.commands.keys.sorted() == ["shell-prefix-check.sh"])
}

/// A deferred gate item: two scripts recursing through agents — each `outer.sh` copy's agent starts an `inner.sh`
/// whose own agent runs the tool calls. One line, the outer script's, carrying everything below it.
@Test func aScriptStartedThroughAnotherScriptsAgentsJoinsItsLine() {
    var p = rest()
    for i in 0..<25 {
        let pid = Int32(10_000 + i * 6)
        p.add(row(pid, "bash"), args("/bin/bash", "/tmp/example/outer.sh"))
        p.add(row(pid + 1, "claude", parent: pid, cpu: quietAgent), args("claude", "-p", "outer"))
        p.add(row(pid + 2, "bash", parent: pid + 1), args("/bin/bash", "/tmp/example/inner.sh"))
        p.add(row(pid + 3, "claude", parent: pid + 2, cpu: quietAgent), args("claude", "-p", "inner"))
        p.add(row(pid + 4, "zsh", parent: pid + 3, exited: 0.3), args("/bin/zsh", "-c", "node /tmp/example/build.js"))
        p.add(row(pid + 5, "node", parent: pid + 4, cpu: 0.5), args("node", "/tmp/example/build.js"))
    }
    var engine = WarningEngine()
    for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
    var last: [Warning] = []
    for t in 21...60 {
        last = engine.next(tick(Double(t), processes: p))
        #expect(last.allSatisfy { $0.subject == .command("outer.sh") }, "second \(t): \(subjects(last))")
    }
    #expect(last.first?.pids == p.rows.filter { $0.pid >= 10_000 }.map(\.pid).sorted())
}

/// Rule A through a pause: every tool call of a 25-copy runaway with quiet agents stops from second 361 to 375 of a
/// storm older than 5 minutes; the tool shells never warn as `zsh`, the filter or `build.js`.
@Test func aPauseInAnOldStormRaisesNoOtherLine() {
    for filter in [false, true] {
        var engine = WarningEngine()
        for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
        for t in 21...420 {
            let storm = toolStorm(25, filter: filter, agentCpu: quietAgent)
            var p = (361...375).contains(t) ? withoutToolCalls(storm) : storm
            addUserSession(&p, filter: filter)
            let last = engine.next(tick(Double(t), processes: p))
            #expect(last.allSatisfy { $0.subject == .command("shell-prefix-check.sh") },
                    "filter \(filter), second \(t): \(subjects(last))")
        }
    }
}

/// Rule D: the same pause clears the script's line — its idle agents carry 3.6% of the machine, under 4.4% — and it
/// comes back on its count and CPU alone, the storm being too old to grow by 20, within 10 s of the work's return.
@Test func aRunawayLineReturnsAfterAPauseInAnOldStorm() {
    var engine = WarningEngine()
    for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
    var clearedInThePause = false
    for t in 21...420 {
        let storm = toolStorm(25, filter: true, agentCpu: quietAgent)
        let last = engine.next(tick(Double(t), processes: (361...375).contains(t) ? withoutToolCalls(storm) : storm))
        if (361...385).contains(t), last.isEmpty { clearedInThePause = true }
        if (40...360).contains(t) || t >= 386 {
            #expect(subjects(last) == [.command("shell-prefix-check.sh")], "second \(t)")
        }
    }
    #expect(clearedInThePause)
}

/// Rule D lasts 5 minutes: a line cleared longer ago than that needs its growth again.
@Test func aClearedLineStaysClearedAfterFiveMinutes() {
    var engine = WarningEngine()
    for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
    for t in 21...720 {
        let storm = toolStorm(25, filter: true, agentCpu: quietAgent)
        let last = engine.next(tick(Double(t), processes: (361...680).contains(t) ? withoutToolCalls(storm) : storm))
        if t >= 372 { #expect(last.isEmpty, "second \(t): \(subjects(last))") }
    }
}

/// Rule B (research 2026-10-25 § B): the runaway's copies gone and its headless agents under launchd, working on,
/// beside the thirty login shells and the user's own session. No line, so no Pause or Stop, holds a login shell or a
/// pid of the user's session; what is left warns only as the orphaned work's own commands.
@Test func loginShellsAndTheUsersSessionsNeverOnALine() {
    for filter in [false, true] {
        var engine = WarningEngine()
        for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
        var p = copiesKilled(toolStorm(25, filter: filter))
        addUserSession(&p, filter: filter)
        for t in 21...90 {
            let last = engine.next(tick(Double(t), processes: p))
            #expect(usersOwnOnALine(last).isEmpty, "filter \(filter), second \(t): \(usersOwnOnALine(last))")
            #expect(last.allSatisfy { $0.pids.allSatisfy { $0 >= 10_000 } }, "filter \(filter), second \(t)")
        }
    }
}

/// Rule B the other way: a runaway started by hand from a login shell hands its terminal to its copies and their
/// agents. They are not the user's own: one line, the script's, all 30 copies and their work on it, the shell off it.
@Test func aRunawayStartedFromATerminalStillWarns() {
    var p = rest()
    for i in 0..<30 {
        let pid = Int32(10_000 + i * 5)
        p.add(row(pid, "bash", parent: 2_088, terminal: true), args("/bin/bash", script))
        p.add(row(pid + 1, "claude", parent: pid, cpu: quietAgent, terminal: true), args("claude", "-p", "check"))
        p.add(row(pid + 3, "zsh", parent: pid + 1, exited: 0.3), args("/bin/zsh", "-c", "node /tmp/example/build.js"))
        p.add(row(pid + 4, "node", parent: pid + 3, cpu: 0.5), args("node", "/tmp/example/build.js"))
    }
    var engine = WarningEngine()
    for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
    var last: [Warning] = []
    for t in 21...60 { last = engine.next(tick(Double(t), processes: p)) }
    #expect(last.map(\.name) == ["shell-prefix-check.sh × 30"])
    #expect(last.first?.pids == p.rows.filter { $0.pid >= 10_000 }.map(\.pid).sorted())
}

/// Rule B on the research's run 3: busy agents (8% of a core each) raise the script's line, the copies are killed while
/// the agents work on, then the work ends. At no second does a line hold a login shell or the user's interactive
/// `claude` and its tool calls.
@Test func killedCopiesLeaveNoLineOfTheUsersShells() {
    for filter in [false, true] {
        var engine = WarningEngine()
        for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
        var raised = false
        for t in 21...150 {
            let storm = toolStorm(25, filter: filter, agentCpu: 8 / Double(cpus))
            var p = t <= 60 ? storm : t <= 120 ? copiesKilled(storm) : rest()
            addUserSession(&p, filter: filter)
            let last = engine.next(tick(Double(t), processes: p))
            raised = raised || last.contains { $0.subject == .command("shell-prefix-check.sh") }
            #expect(usersOwnOnALine(last).isEmpty, "filter \(filter), second \(t): \(usersOwnOnALine(last))")
        }
        #expect(raised, "filter \(filter)")
    }
}

@Test func twoUnrelatedCommandsGiveTwoLines() {
    var engine = WarningEngine()
    _ = engine.next(tick(1, processes: rest()))
    var p = storm(75, generation: 0)
    for i in 0..<30 {
        let pid = Int32(50_000 + i * 2)
        p.add(row(pid, "bash"), args("/bin/bash", "/tmp/example/other.sh"))
        p.add(row(pid + 1, "perl", parent: pid, cpu: 0.3), args("perl", "-e", "1"))
    }
    var last: [Warning] = []
    for t in 2...30 { last = engine.next(tick(Double(t), processes: p)) }
    #expect(Set(subjects(last)) == [.command("shell-prefix-check.sh"), .command("other.sh")])
}

@Test func machineConditionsJoinTheBusiestLineElseShareOne() {
    var engine = WarningEngine()
    var last: [Warning] = []
    for t in 1...600 {
        last = engine.next(tick(Double(t), unattributed: 20, sessions: [session("small", 26, pids: [1]),
                                                                         session("big", 40, pids: [2])]))
    }
    #expect(subjects(last) == [.session("big"), .session("small")])
    #expect(last.first.map { has($0, .unattributed) } == true)
    #expect(last.last.map { has($0, .unattributed) } == false)

    var alone = WarningEngine()
    for t in 1...40 { last = alone.next(tick(Double(t), unattributed: 20, system: 45)) }
    #expect(subjects(last) == [.machine])
    #expect(last.first?.conditions.map(\.kind) == [.unattributed, .systemShare])
}

// MARK: time

@Test func holdsRunOnElapsedTime() {
    var engine = WarningEngine()
    #expect(subjects(engine.next(tick(10, span: 10, unattributed: 20))) == [.machine], "one 10-s window")

    var gap = WarningEngine()
    for t in 1...6 { _ = gap.next(tick(Double(t), unattributed: 20)) }
    for t in 9...17 { #expect(gap.next(tick(Double(t), unattributed: 20)).isEmpty, "the gap restarted the run") }
    #expect(!gap.next(tick(18, unattributed: 20)).isEmpty)

    var unread = WarningEngine()
    for t in 1...29 { _ = unread.next(tick(Double(t), system: 45)) }
    #expect(unread.next(tick(30, system: nil)).isEmpty)
    #expect(!unread.next(tick(31, system: 45)).isEmpty, "an unread figure keeps the run")
}

/// The per-tick work, counted rather than timed (the gate's round 2: a wall-clock bound fails on a busy CI runner): over
/// 1,000 command groups at rest no tick indexes the rows; with a runaway raised each tick indexes them once, not once
/// a group.
@Test func perTickWorkStaysSmall() {
    var p = Processes()
    for i in 0..<1_000 {
        p.add(row(Int32(100_000 + i * 2), "tool\(i)"))
        p.add(row(Int32(100_001 + i * 2), "tool\(i)", parent: Int32(100_000 + i * 2), cpu: 0.01))
    }
    func with(_ more: Processes) -> Processes {
        Processes(rows: p.rows + more.rows, arguments: p.arguments.merging(more.arguments) { a, _ in a })
    }
    let quiet = (1...60).map { _ in p }
    let runaway = (1...60).map { $0 <= 20 ? with(rest()) : with(toolStorm(30, filter: true)) }
    for (tag, series, indexed) in [("at rest", quiet, 0), ("a runaway", runaway, runaway.map(\.rows.count).reduce(0, +))] {
        let ticks = series.enumerated().map { tick(Double($0.offset + 1), processes: $0.element) }
        var engine = WarningEngine()
        let work = WorkCount()
        let last = WorkCount.current.withValue(work) { ticks.map { engine.next($0) }.last }
        #expect(work.indexedRows == indexed, "\(tag)")
        #expect(work.parentMaps == 0, "\(tag)")
        if indexed > 0 { #expect(last.map(subjects) == [.command("shell-prefix-check.sh")]) }
    }
}

// MARK: the window's ignore list and bar (Phase 6 Step 6)

@Test func ignoreSuppressesByCommandKey() {
    var engine = WarningEngine()
    let ignored: Set<Warning.Subject> = [.command("shell-prefix-check.sh")]
    func storms(_ t: Int) -> Processes {
        var p = storm(t < 20 ? 0 : 75, generation: 0)
        for i in 0..<(t < 20 ? 0 : 30) {
            let pid = Int32(50_000 + i * 2)
            p.add(row(pid, "bash"), args("/bin/bash", "/tmp/example/other.sh"))
            p.add(row(pid + 1, "perl", parent: pid, cpu: 0.3), args("perl", "-e", "1"))
        }
        return p
    }
    var last: [Warning] = []
    for t in 1...60 {
        last = engine.next(tick(Double(t), unattributed: 20, system: 54, processes: storms(t)), ignoring: ignored)
    }
    #expect(subjects(last) == [.command("other.sh")])
    // The machine-wide conditions join the line left, not the ignored one.
    #expect(last.first.map { has($0, .unattributed) && has($0, .systemShare) } == true)
    // Un-ignored, the held warning shows at once.
    let shown = engine.next(tick(61, unattributed: 20, system: 54, processes: storms(61)))
    #expect(Set(subjects(shown)) == [.command("shell-prefix-check.sh"), .command("other.sh")])

    // Every line ignored: the machine-wide conditions stand on the Machine line.
    var alone = WarningEngine()
    for t in 1...60 {
        last = alone.next(tick(Double(t), unattributed: 20, processes: storm(t < 20 ? 0 : 75, generation: 0)),
                          ignoring: ignored)
    }
    #expect(subjects(last) == [.machine])
}

@Test func ignoringACommandKeepsTheGroupWarningsJoinedToIt() {
    var engine = WarningEngine()
    _ = engine.next(tick(1, processes: rest()))
    var last: [Warning] = []
    let p = storm(75, generation: 0)
    let pids = p.rows.filter { $0.pid >= 10_000 }.map(\.pid)
    for t in 2...700 {
        last = engine.next(tick(Double(t), processes: p, repos: [repo("tmp-repo", 30, pids: pids)],
                                sessions: [session("lead", 30, pids: pids)]),
                           ignoring: [.command("shell-prefix-check.sh")])
    }
    // The session's line, the repo joined to it; the ignored command's copies condition gone.
    #expect(subjects(last) == [.session("lead")])
    #expect(last.first?.conditions.map(\.kind) == [.group, .group])

    // Ignoring the session instead drops only its condition from the command's line.
    var other = WarningEngine()
    _ = other.next(tick(1, processes: rest()))
    for t in 2...700 {
        last = other.next(tick(Double(t), processes: p, repos: [repo("tmp-repo", 30, pids: pids)],
                               sessions: [session("lead", 30, pids: pids)]), ignoring: [.session("lead")])
    }
    #expect(subjects(last) == [.command("shell-prefix-check.sh")])
    #expect(last.first?.conditions.map(\.kind) == [.copies, .group])
}

@Test func raisedSubjectsIncludeIgnoredOnesUntilTheyClear() {
    // Ignore on a group warning lasts until that warning clears (calibration 2026-10-23): the window reads it here.
    var engine = WarningEngine()
    let ignored: Set<Warning.Subject> = [.session("build")]
    for t in 1...600 { _ = engine.next(tick(Double(t), sessions: [session("build", 30, pids: [1])]), ignoring: ignored) }
    #expect(engine.raisedSubjects == [.session("build")])
    for t in 601...609 { _ = engine.next(tick(Double(t), sessions: [session("build", 10, pids: [1])]), ignoring: ignored) }
    #expect(engine.raisedSubjects == [.session("build")], "still above its clearing hold")
    _ = engine.next(tick(610, sessions: [session("build", 10, pids: [1])]), ignoring: ignored)
    #expect(engine.raisedSubjects.isEmpty)
}

// MARK: the session boundary and the Apple services (the 2026-10-26 batch)

/// The user's interactive session (`addUserSession` with its filter: claude 3000, the filter 3001, its shell 3002) with
/// `count` copies of `worker.sh` attached under that shell, each busy at `cpuEach`, pids from 4000.
private func attachedFanOut(_ count: Int, cpuEach: Double = 0.5) -> Processes {
    var p = rest()
    addUserSession(&p, filter: true)
    for i in 0..<count {
        p.add(row(Int32(4_000 + i), "bash", parent: 3_002, cpu: cpuEach), args("/bin/bash", "/tmp/example/worker.sh"))
    }
    return p
}

/// The protected pids of `attachedFanOut`: the interactive root and its launch wrappers, plus the login shells.
private let protectedByTheSession: Set<Int32> = [3_000, 3_001, 3_002]

@Test func anAttachedFanOutUnderTheUsersSessionWarnsWithoutTheSessionsRootOrWrappers() {
    var engine = WarningEngine()
    for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
    var last: [Warning] = []
    for t in 21...60 { last = engine.next(tick(Double(t), processes: attachedFanOut(30))) }
    let workers = (4_000 as Int32)..<4_030
    #expect(last.map(\.name) == ["worker.sh × 30"])
    #expect(last.first?.pids == Array(workers))
    #expect(last.allSatisfy { Set($0.pids).isDisjoint(with: protectedByTheSession.union(loginShells)) })
}

@Test func theSameFanOutOrphanedWarnsAsTheSameLine() {
    var p = attachedFanOut(30)
    p.rows = p.rows.map { $0.pid >= 4_000 ? row($0.pid, "bash", cpu: $0.cpuPercent) : $0 }    // the shell is gone: launchd's
    var engine = WarningEngine()
    for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
    var last: [Warning] = []
    for t in 21...60 { last = engine.next(tick(Double(t), processes: p)) }
    #expect(last.map(\.name) == ["worker.sh × 30"])
    #expect(last.first?.pids == Array((4_000 as Int32)..<4_030))
}

@Test func aSessionWarningActsOnTheWorkloadAndNotTheSessionsRoot() {
    // The session's own group is over the bar for ten minutes; its warning's processes leave out the interactive root,
    // the filter and the shell it runs, and the login shell, and keep what ran below them.
    let p = attachedFanOut(5, cpuEach: 1)
    let group = session("build", 30, pids: [2_088] + [3_000, 3_001, 3_002, 4_000, 4_001, 4_002, 4_003, 4_004])
    var engine = WarningEngine()
    var last: [Warning] = []
    for t in 1...600 { last = engine.next(tick(Double(t), processes: p, sessions: [group])) }
    let warning = last.first { $0.subject == .session("build") }
    #expect(warning?.pids == [4_000, 4_001, 4_002, 4_003, 4_004])
    #expect(warning?.heaviest.map { (4_000...4_004).contains($0) } == true)
}

/// An Apple service as the kernel reports it, `mdworker_shared`-shaped: platform bit, a service path, launchd's child
/// leading its own group (`copies` of it at 0.75% each, the research's Spotlight burst).
private func appleBurst(_ count: Int, firstPid: Int32 = 6_000, platform: Bool = true,
                        path: String = "/System/Library/Frameworks/CoreServices.framework/Support/mdworker_shared") -> Processes {
    var p = Processes()
    for i in 0..<count {
        let pid = firstPid + Int32(i)
        var service = ProcessUsage(pid: pid, ppid: 1, uid: 501, user: "user", path: path, name: "mdworker_shared",
                                   cpuPercent: 0.75, residentBytes: 1 << 20, source: .libproc, exitedChildrenCpuPercent: 0)
        service.processGroup = pid
        service.platformBinary = platform
        p.add(service)
    }
    return p
}

@Test func anAppleBurstStillWarnsAndNamesWhichProcessesAreAppleServices() {
    var engine = WarningEngine()
    var last: [Warning] = []
    for t in 1...5 { _ = engine.next(tick(Double(t), processes: rest())) }
    for t in 6...25 { last = engine.next(tick(Double(t), processes: appleBurst(32))) }
    let warning = last.first
    #expect(warning?.name == "mdworker_shared × 32")
    #expect(warning?.pids.count == 32)
    #expect(warning?.appleServices == warning?.pids)
}

@Test func aMixedLineNamesOnlyItsAppleServices() {
    var p = appleBurst(30)
    p.rows += appleBurst(3, firstPid: 7_000, platform: false, path: "/tmp/example/mdworker_shared").rows    // forged namesakes
    var engine = WarningEngine()
    var last: [Warning] = []
    for t in 1...5 { _ = engine.next(tick(Double(t), processes: rest())) }
    for t in 6...25 { last = engine.next(tick(Double(t), processes: p)) }
    let warning = last.first
    #expect(warning?.pids.count == 33)
    #expect(warning?.appleServices == Array((6_000 as Int32)..<6_030))
}

@Test func theBarNamesTheExemptionAndActsOnlyOnTheOthers() {
    let copies = Warning.Condition.copies(count: 33, growth: 33, percent: 24)
    let warning = Warning(subject: .command("mdworker_shared"), name: "mdworker_shared × 33", since: 0, cpuPercent: 24,
                          conditions: [copies], pids: [10, 11, 12, 13], heaviest: 10, appleServices: [10, 11, 12])
    let all = Warning(subject: .command("mdworker_shared"), name: "mdworker_shared × 3", since: 0, cpuPercent: 2,
                      conditions: [copies], pids: [10, 11, 12], heaviest: 10, appleServices: [10, 11, 12])
    let one = Warning(subject: .command("mdworker_shared"), name: "mdworker_shared × 1", since: 0, cpuPercent: 1,
                      conditions: [copies], pids: [10], heaviest: 10, appleServices: [10])
    let plain = Warning(subject: .command("run.sh"), name: "run.sh × 30", since: 0, cpuPercent: 24, conditions: [copies],
                        pids: [20, 21])
    // The exemption on (the default): the line says so, and its Pause and Stop reach only what is not exempt.
    let on = WarningBar.lines([warning, all, one, plain], table: [])
    #expect(on[0].pids == [13] && on[0].exempt == [10, 11, 12] && on[0].note == "3 Apple services — not paused")
    #expect(on[0].actionable)
    #expect(on[1].pids.isEmpty && !on[1].actionable && on[1].note == "3 Apple services — not paused")
    #expect(on[2].note == "Apple service — not paused" && on[2].pids.isEmpty)
    #expect(on[3].pids == [20, 21] && on[3].note == nil && on[3].exempt.isEmpty)
    // The text a line keeps is unchanged.
    #expect(on[0].text == "! mdworker_shared × 33  copies 33, up 33 in 5 min, 24.0% with what they started")
    // The exemption off: no note, every process is the line's to act on.
    let off = WarningBar.lines([warning, all], table: [], exemptApple: false)
    #expect(off[0].pids == [10, 11, 12, 13] && off[0].note == nil && off[0].exempt.isEmpty)
    #expect(off[1].pids == [10, 11, 12] && off[1].actionable)
}

@Test func theStormsOfOrdinaryToolsAreNeverMarkedAppleServices() {
    var engine = WarningEngine()
    for t in 1...20 { _ = engine.next(tick(Double(t), processes: rest())) }
    var last: [Warning] = []
    let p = storm(30, generation: 0)
    for t in 21...60 { last = engine.next(tick(Double(t), processes: p)) }
    #expect(!last.isEmpty && last.allSatisfy { $0.appleServices.isEmpty })
}

@Test func warningsCarryTheirProcesses() {
    var engine = WarningEngine()
    _ = engine.next(tick(1, processes: rest()))
    var last: [Warning] = []
    let p = storm(30, generation: 0)
    for t in 2...20 { last = engine.next(tick(Double(t), processes: p)) }
    let copies = p.rows.filter { $0.pid >= 10_000 }.map(\.pid)
    #expect(last.first?.pids == copies.sorted())
    #expect(last.first?.heaviest.map { copies.contains($0) && $0 % 2 == 1 } == true, "a busy claude, not a copy")
}

@Test func subjectKeysRoundTrip() {
    let subjects: [Warning.Subject] = [.command("a:b.sh"), .session("build"), .repo("example"), .machine]
    #expect(subjects.map(\.key) == ["command:a:b.sh", "session:build", "repo:example", "machine"])
    #expect(subjects.map { Warning.Subject(key: $0.key) } == subjects)
    #expect(Warning.Subject(key: "unknown:x") == nil && Warning.Subject(key: "") == nil)
}

@Test func barHoldsOneLinePerWarning() {
    let warnings = [
        Warning(subject: .command("run.sh"), name: "run.sh × 75", since: 0, cpuPercent: 41, conditions: [
            .copies(count: 75, growth: 75, percent: 41.2), .systemShare(percent: 54),
        ], pids: [10, 11], heaviest: 11),
        Warning(subject: .machine, name: "Machine", since: 0, cpuPercent: 0, conditions: [.unattributed(percent: 25)]),
    ]
    var group = ProcessTable.Line(id: "group:command:run.sh", identifier: "group-0", kind: .group, name: "run.sh × 75",
                                  cpuPercent: 41)
    group.warnings = [0]
    let bar = WarningBar.lines(warnings, table: [group])
    #expect(bar.count == 2)
    #expect(bar.map(\.identifier) == ["warning-0", "warning-1"])
    #expect(bar[0].text == "! run.sh × 75  copies 75, up 75 in 5 min, 41.2% with what they started (+1 more)")
    #expect(bar[0].conditions == ["copies 75, up 75 in 5 min, 41.2% with what they started", "system 54.0% of CPU time"])
    #expect(bar[0].group == "group:command:run.sh" && bar[0].pids == [10, 11])
    #expect(bar[0].ignoreKey == "command:run.sh" && bar[0].actionable)
    #expect(bar[1].text == "! Machine  Unattributed CPU 25.0%")
    #expect(bar[1].group == nil && bar[1].ignoreKey == nil && !bar[1].actionable)
    #expect(WarningBar.lines([], table: [group]).isEmpty)

    // The 75-copy storm with copies coming and going keeps one bar line.
    var engine = WarningEngine()
    for t in 1...60 { _ = engine.next(tick(Double(t), processes: rest())) }
    for s in 1...200 {
        let count = s <= 60 ? s * 75 / 60 : 70 + [-10, 0, 10, 5][s % 4]
        let lines = WarningBar.lines(engine.next(tick(Double(60 + s), unattributed: 20,
                                                     processes: storm(count, generation: s / 20))), table: [])
        #expect(lines.count <= 1, "second \(s)")
    }
}

// MARK: spikes (Phase 6 Step 6)

@Test func spikesNeedTwiceTheMedianPastAFloor() {
    func run(_ values: [Double], floor: Double = 25) -> [SpikeMarks.Mark] {
        var spikes = SpikeMarks(floor: floor)
        for (i, value) in values.enumerated() { spikes.next(end: Double(i + 1), value: value, top: "top\(i)") }
        return spikes.marks
    }
    #expect(run(Array(repeating: 20, count: 120)).isEmpty, "a flat minute")
    let burst = Array(repeating: 20.0, count: 30) + [70] + Array(repeating: 20.0, count: 5)
    #expect(run(burst).map(\.end) == [31] && run(burst).first?.name == "top30")
    #expect(run(Array(repeating: 20.0, count: 30) + [40]).isEmpty, "twice the median, under the floor")
    #expect(run(Array(repeating: 2.0, count: 30) + [26]).isEmpty, "over twice the median, but only 24 points over it")
    #expect(run(Array(repeating: 20.0, count: 30) + [70, 20, 20, 75]).count == 1, "one mark per 10 s")
    #expect(run(Array(repeating: 20.0, count: 30) + [70] + Array(repeating: 20.0, count: 11) + [75]).count == 2)
    #expect(run(Array(repeating: 0.0, count: 5) + [90]).isEmpty, "under 10 s of history")
    // A mark leaves with its second, a minute on.
    var spikes = SpikeMarks(floor: 25)
    for t in 1...30 { spikes.next(end: Double(t), value: 20, top: nil) }
    spikes.next(end: 31, value: 70, top: "node")
    for t in 32...90 { spikes.next(end: Double(t), value: 20, top: nil) }
    #expect(spikes.marks.count == 1)
    spikes.next(end: 92, value: 20, top: nil)
    #expect(spikes.marks.isEmpty)
}

@Test func spikeNamesNeverOverlap() {
    // The user's find (gate round 1): two names 10 s apart on a 140 pt plot ran into each other.
    typealias Slot = SpikeMarks.NameSlot
    let slots = SpikeMarks.nameSlots(xs: [130, 100, 20], widths: [200, 60, 50], width: 140, rows: 2)
    #expect(slots == [Slot(row: 0, x: 0, width: 140), Slot(row: 1, x: 80, width: 60), Slot(row: 1, x: 20, width: 50)])
    #expect(SpikeMarks.nameSlots(xs: [10, 12, 14], widths: [30, 30, 30], width: 140, rows: 2)
            == [Slot(row: 0, x: 10, width: 30), Slot(row: 1, x: 12, width: 30), nil], "no row left: the list names it")
    #expect(SpikeMarks.nameSlots(xs: [0, 40], widths: [30, 30], width: 140, rows: 1).allSatisfy { $0?.row == 0 })
    #expect(SpikeMarks.nameSlots(xs: [5], widths: [10], width: 140, rows: 0) == [nil])
}

@Test func topProcessNamesTheSpike() {
    let rows = [row(1, "idle", cpu: 1), row(2, "node", cpu: 30, exited: 18), row(3, "make", cpu: 40)]
    #expect(SpikeMarks.top(rows, by: \.totalCpuPercent) == "node 48.0%")
    #expect(SpikeMarks.top([], by: \.totalCpuPercent) == nil)
}

// MARK: text

@Test func warningLinesInTheTable() throws {
    let topology = try CoreTopology.build(levels: [PerfLevel(index: 0, name: "Performance", logicalCPUCount: 2)],
                                          clusterTypeByCPU: [0: "P", 1: "P"])
    let load = CPULoad(perCPU: [50, 50], total: 50, split: CPUSplit(user: 40, system: 10))
    let quiet = try Snapshot(topology: topology, load: load, intervalSeconds: 1)
    #expect(!quiet.table().contains("Warnings"))
    let warnings = [
        Warning(subject: .command("run.sh"), name: "run.sh × 75", since: 0, cpuPercent: 41.2, conditions: [
            .copies(count: 75, growth: 75, percent: 41.23),
            .load(oneMinute: 96, cpus: 18, rising: true),
            .systemShare(percent: 54),
        ]),
        Warning(subject: .session("build"), name: "build (session)", since: 0, cpuPercent: 30,
                conditions: [.group(percent: 31.5, seconds: 754)]),
        Warning(subject: .machine, name: "Machine", since: 0, cpuPercent: 0, conditions: [.unattributed(percent: 25)]),
    ]
    let table = try Snapshot(topology: topology, load: load, intervalSeconds: 1, warnings: warnings).table()
    let lines = table.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let start = try #require(lines.firstIndex(of: "Warnings"))
    #expect(lines[start - 1].hasPrefix("  User "))
    #expect(Array(lines[start + 1...start + 3]) == [
        "  ! run.sh × 75  copies 75, up 75 in 5 min, 41.2% with what they started; "
            + "load 96.00 on 18 CPUs (5.3 ×), rising; system 54.0% of CPU time",
        "  ! build (session)  31.5% for 12 min",
        "  ! Machine  Unattributed CPU 25.0%",
    ])
    #expect(lines[start + 4].hasPrefix("Performance"))
}

// The spike time under a graph follows the Mac's clock setting and keeps its AM/PM on a 12-hour clock
// (Backlog spike-time-12-hour-clock: "Spike 12:57:09" read alike at 00:57 and 12:57).
@Test func spikeClockShowsAMPMUnderATwelveHourLocale() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let night = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 57, second: 9)))
    let noon = night.addingTimeInterval(12 * 3600)

    let nightUS = SpikeMarks.clock(night, locale: Locale(identifier: "en_US"), timeZone: utc)
    let noonUS = SpikeMarks.clock(noon, locale: Locale(identifier: "en_US"), timeZone: utc)
    #expect(nightUS.contains("AM") && nightUS.contains("12:57:09"))
    #expect(noonUS.contains("PM") && noonUS.contains("12:57:09"))
    #expect(SpikeMarks.clock(night, locale: Locale(identifier: "en_GB"), timeZone: utc) == "00:57:09")
    #expect(SpikeMarks.clock(noon, locale: Locale(identifier: "en_GB"), timeZone: utc) == "12:57:09")
}

// MARK: resource levels (Phase 7 Step 2)

// Goal: the fixed 80/90/95 levels and the memory ETA beside them — independently held, a drop-back below each bar,
// CPU counted only when sustained, a notice listing consumers at 80, a named target with no pause at 90, and a
// proposed candidate pause at 95. Method: tick series built in code; every hold, drop-back and sustain here is
// TEST-ONLY, pending the user's calibration. The plan fixes the three bars, not the timings.

private let rGib: UInt64 = 1 << 30
private let rPhysical: UInt64 = 64 * rGib

/// TEST-ONLY calibration: 80/90/95 held ten seconds, dropping back three points, CPU sustained ten seconds.
private func testLevels(basis: MemoryPercentBasis = .usedOfPhysical,
                        eta: MemoryProjection.Config? = nil) -> ResourceCalibration {
    ResourceCalibration(basis: basis,
                        notice: LevelBand(percent: 80, hold: 10, dropBack: 3),
                        triage: LevelBand(percent: 90, hold: 10, dropBack: 3),
                        critical: LevelBand(percent: 95, hold: 10, dropBack: 3),
                        cpuSustain: 10, eta: eta)
}

/// TEST-ONLY projection settings: 60 s and 180 s windows, ten samples, a decline of at least 1 MiB/s.
private let testETA = MemoryProjection.Config(windows: [60, 180], minimumSamples: 10,
                                              minimumDeclineBytesPerSecond: Double(1 << 20))

/// Memory with `percent` of physical memory used on the given basis. Pages are whole, so a percent that does not divide
/// the machine evenly (95% of 64 GiB is not a whole byte count) is rounded up: a test at a bar is at the bar, never a
/// rounding sliver under it.
private func levelMemory(usedPercent percent: Double,
                         basis: MemoryPercentBasis = .usedOfPhysical) -> AvailableMemory {
    let used = UInt64((Double(rPhysical) * percent / 100).rounded(.up))
    switch basis {
    case .usedOfPhysical:
        return AvailableMemory(freeBytes: rPhysical - used, inactiveBytes: 0, speculativeBytes: 0, purgeableBytes: 0,
                               activeBytes: used, wiredBytes: 0, compressedBytes: 0, physicalBytes: rPhysical)
    case .availableComplement:
        return AvailableMemory(freeBytes: rPhysical - used, inactiveBytes: 0, speculativeBytes: 0, purgeableBytes: 0,
                               activeBytes: 0, wiredBytes: 0, compressedBytes: 0, physicalBytes: rPhysical)
    }
}

/// Memory with `available` bytes available and the rest held as active pages.
private func levelMemory(available: UInt64) -> AvailableMemory {
    AvailableMemory(freeBytes: available, inactiveBytes: 0, speculativeBytes: 0, purgeableBytes: 0,
                    activeBytes: rPhysical - available, wiredBytes: 0, compressedBytes: 0, physicalBytes: rPhysical)
}

private func levelRow(_ pid: Int32, _ name: String, resident: UInt64, cpu: Double = 0, own: Bool = false) -> ProcessUsage {
    var row = ProcessUsage(pid: pid, ppid: 1, uid: 501, user: "user", path: "/usr/bin/" + name, name: name,
                           cpuPercent: cpu, residentBytes: resident, source: .libproc)
    row.usersOwn = own
    return row
}

/// A one-second window ending at `t` with whole-machine CPU and a memory sample.
private func levelTick(_ t: Double, memory: AvailableMemory?, cpu: Double? = 20,
                       rows: [ProcessUsage] = []) -> WarningTick {
    let commands = CommandGroups.assign(rows, arguments: [:])
    return WarningTick(end: t, seconds: 1, cpus: cpus, unattributedCpuPercent: 5.6, loadAverage: nil, split: nil,
                       rows: commands.rows, commandGroups: commands.groups, repoGroups: [], sessionGroups: [],
                       cpuPercent: cpu, memory: memory)
}

/// The user's provisional starting values (research 2026-10-29), including the independent ETA, survive selection.
@Test func provisionalCalibrationMatchesApprovedProposal() {
    let expected = ResourceCalibration(
        basis: .usedOfPhysical,
        notice: LevelBand(percent: 80, hold: 10, dropBack: 5),
        triage: LevelBand(percent: 90, hold: 5, dropBack: 5),
        critical: LevelBand(percent: 95, hold: 2, dropBack: 3),
        cpuSustain: 30,
        eta: MemoryProjection.Config(windows: [60, 180], minimumSamples: 10,
                                     minimumDeclineBytesPerSecond: 1_048_576))
    #expect(ResourceCalibration.provisional == expected)
    let selected = ResourceCalibration.read { _ in true }
    #expect(selected == expected)
    #expect(selected.levelsCalibrated)
    #expect(ResourceCalibration(basis: selected.basis, notice: selected.notice, triage: selected.triage,
                                critical: selected.critical, cpuSustain: selected.cpuSustain,
                                eta: selected.eta) == expected)
}

/// An unset, false or non-Bool setting cannot activate the provisional calibration; a stored Bool can.
@Test func resourceCalibrationSwitchRequiresAnExplicitBoolean() {
    #expect(ResourceCalibration.enabledKey == "resource.levels.enabled")
    #expect(ResourceCalibration.read { _ in nil } == .pending)
    let rejected: [Any] = [false, "true", "YES", 1, 1.0, NSNumber(value: 1), [true]]
    for value in rejected {
        #expect(ResourceCalibration.read { _ in value } == .pending)
    }
    #expect(ResourceCalibration.read { key in
        key == ResourceCalibration.enabledKey ? true : nil
    } == .provisional)
    #expect(ResourceCalibration.read { _ in NSNumber(value: true) } == .provisional)
}

/// Default-off evaluation emits neither levels, ETA nor requests, even with a consumer at 99% and sustained CPU.
@Test func resourceCalibrationSwitchOffEvaluatesNothing() {
    for value: Bool? in [nil, false] {
        var engine = ResourceLevelEngine(calibration: .read { _ in value })
        let rows = [levelRow(100, "node", resident: 8 * rGib, cpu: 99)]
        for t in 1...60 {
            #expect(engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 99),
                                          cpu: 99, rows: rows)) == nil)
        }
    }
    #expect(ResourceReading.unavailableText == "Levels  unavailable — resource alerts off")
}

/// Each approved memory band waits its own 10/5/2 seconds and clears strictly below its 75/85/92% boundary.
@Test(arguments: [ResourceLevel.notice, .triage, .critical])
func provisionalMemoryBandsHoldAndDropBack(_ level: ResourceLevel) {
    let calibration = ResourceCalibration.read { _ in true }
    let band = switch level {
    case .normal, .notice: calibration.notice
    case .triage: calibration.triage
    case .critical: calibration.critical
    }
    let hold = Int(band.hold ?? 0)
    #expect(hold > 1)
    guard hold > 1, let margin = band.dropBack else { return }
    var engine = ResourceLevelEngine(calibration: calibration)
    let rows = [levelRow(100, "node", resident: 8 * rGib)]
    for t in 1..<hold {
        let reading = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: band.percent), rows: rows))
        #expect(reading?.level == .normal)
        #expect(reading?.pauseRequest == nil)
    }
    let raised = engine.next(levelTick(Double(hold), memory: levelMemory(usedPercent: band.percent), rows: rows))
    #expect(raised?.level == level)
    #expect((raised?.pauseRequest != nil) == (level == .critical))
    let boundary = band.percent - margin
    #expect(engine.next(levelTick(Double(hold + 1), memory: levelMemory(usedPercent: boundary)))?.level == level)
    let cleared = engine.next(levelTick(Double(hold + 2), memory: levelMemory(usedPercent: boundary - 0.01)))
    #expect((cleared?.level ?? .critical) < level)
    #expect(cleared?.pauseRequest == nil)
}

/// CPU uses the approved 30-second sustain at every band, not that band's shorter memory hold.
@Test(arguments: [ResourceLevel.notice, .triage, .critical])
func provisionalCPUBandsRequireThirtySeconds(_ level: ResourceLevel) {
    let percent: Double = switch level {
    case .normal, .notice: 80
    case .triage: 90
    case .critical: 95
    }
    var engine = ResourceLevelEngine(calibration: .read { _ in true })
    for t in 1...29 {
        #expect(engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 40), cpu: percent))?.level == .normal)
    }
    #expect(engine.next(levelTick(30, memory: levelMemory(usedPercent: 40), cpu: percent))?.level == level)
}

/// The provisional ETA qualifies at ten declining readings; it is independent of levels and never requests pause.
@Test func provisionalETAUsesItsApprovedMinimumSamples() {
    var engine = ResourceLevelEngine(calibration: .read { _ in true })
    for t in 1...9 {
        let memory = levelMemory(available: 30 * rGib - UInt64(t) * (1 << 26))
        #expect(engine.next(levelTick(Double(t), memory: memory))?.eta == nil)
    }
    let reading = engine.next(levelTick(10, memory: levelMemory(available: 30 * rGib - 10 * (1 << 26))))
    #expect(reading?.eta?.window == 60)
    #expect(reading?.level == .normal)
    #expect(reading?.pauseRequest == nil)
}

/// Nothing calibrated is nothing to report: not a quiet machine, an unevaluated one. 99% used and 100% CPU included.
@Test func anUncalibratedEngineReportsNothing() {
    var engine = ResourceLevelEngine(calibration: .pending)
    var reading: ResourceReading?
    for t in 1...30 {
        reading = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 99), cpu: 100))
    }
    #expect(reading == nil)
}

/// A configured ETA is reported while the fixed levels stay pending: the level stays nil, never normal.
@Test func anETAReportsWhileTheLevelsArePending() {
    let pending = ResourceCalibration(basis: .usedOfPhysical, eta: testETA)
    var engine = ResourceLevelEngine(calibration: pending)
    var reading: ResourceReading?
    for t in 1...60 {
        reading = engine.next(levelTick(Double(t), memory: levelMemory(available: (30 * rGib) - UInt64(t) * (1 << 26))))
    }
    #expect(reading != nil)
    #expect(reading?.level == nil)
    #expect(reading?.eta != nil)
    #expect(reading?.pauseRequest == nil)
    #expect(reading?.text.hasPrefix("Levels  unavailable (levels not calibrated)") == true)
}

/// Each bar is held: nine seconds at 81% is not the notice, the tenth is.
@Test func noticeHoldsBeforeItFires() {
    var engine = ResourceLevelEngine(calibration: testLevels())
    var level = ResourceLevel.normal
    for t in 1...9 {
        level = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 81)))?.level ?? .normal
    }
    #expect(level == .normal)
    #expect(engine.next(levelTick(10, memory: levelMemory(usedPercent: 81)))?.level == .notice)
}

/// The bars hold independently: 85% raises the notice and not the triage; a jump to 95% then holds its own.
@Test func eachLevelHoldsOnItsOwn() {
    var engine = ResourceLevelEngine(calibration: testLevels())
    var reading: ResourceReading?
    for t in 1...20 {
        reading = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 85)))
    }
    #expect(reading?.level == .notice)
    for t in 21...29 {
        reading = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 95)))
    }
    #expect(reading?.level == .notice)
    reading = engine.next(levelTick(30, memory: levelMemory(usedPercent: 95)))
    #expect(reading?.level == .critical)
}

/// A raised level clears only below its bar less the drop-back margin: 78% keeps the notice, 76% clears it.
@Test func dropBackClearsOnlyBelowTheMargin() {
    var engine = ResourceLevelEngine(calibration: testLevels())
    for t in 1...10 { _ = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 81))) }
    #expect(engine.next(levelTick(11, memory: levelMemory(usedPercent: 78)))?.level == .notice)
    #expect(engine.next(levelTick(12, memory: levelMemory(usedPercent: 76)))?.level == .normal)
}

/// A level that dropped can raise again, and the new raise is a transition.
@Test func aDroppedLevelCanRaiseAgain() {
    var engine = ResourceLevelEngine(calibration: testLevels())
    for t in 1...10 { _ = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 81))) }
    _ = engine.next(levelTick(11, memory: levelMemory(usedPercent: 70)))
    var reading: ResourceReading?
    for t in 12...21 {
        reading = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 81)))
    }
    #expect(reading?.level == .notice)
    #expect(reading?.transitions.contains { $0.to == .notice } == true)
}

/// A brief CPU spike is not a level; the same CPU held for the sustain is.
@Test func aBriefCPUSpikeDoesNotRaise() {
    var engine = ResourceLevelEngine(calibration: testLevels())
    var level = ResourceLevel.normal
    for t in 1...4 {
        level = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 40), cpu: 99))?.level ?? .normal
    }
    for t in 5...12 {
        level = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 40), cpu: 10))?.level ?? .normal
    }
    #expect(level == .normal)
}

@Test func sustainedCPURaisesALevel() {
    var engine = ResourceLevelEngine(calibration: testLevels())
    var level = ResourceLevel.normal
    for t in 1...10 {
        level = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 40), cpu: 85))?.level ?? .normal
    }
    #expect(level == .notice)
}

/// An unread figure is not a fresh one: a bound the figures have not moved keeps the levels where they were and the
/// reading reports no figure, rather than a made-up 0% or a quiet drop to normal.
@Test func unreadFiguresKeepTheirLevelsAndStayNil() {
    var memoryBound = ResourceLevelEngine(calibration: testLevels())
    for t in 1...10 { _ = memoryBound.next(levelTick(Double(t), memory: levelMemory(usedPercent: 81))) }
    let blind = memoryBound.next(levelTick(11, memory: nil, cpu: 20))
    #expect(blind?.level == .notice)
    #expect(blind?.memoryPercent == nil)
    #expect(blind?.cpuPercent == 20)
    let dark = memoryBound.next(levelTick(12, memory: nil, cpu: nil))
    #expect(dark?.level == .notice)
    #expect(dark?.memoryPercent == nil)
    #expect(dark?.cpuPercent == nil)
    #expect(dark?.transitions.isEmpty == true)
    #expect(memoryBound.next(levelTick(13, memory: levelMemory(usedPercent: 76)))?.level == .normal)

    var cpuBound = ResourceLevelEngine(calibration: testLevels())
    var reading: ResourceReading?
    for t in 1...10 {
        reading = cpuBound.next(levelTick(Double(t), memory: levelMemory(usedPercent: 40), cpu: 96))
    }
    #expect(reading?.level == .critical)
    let noCPU = cpuBound.next(levelTick(11, memory: levelMemory(usedPercent: 40), cpu: nil))
    #expect(noCPU?.level == .critical)
    #expect(noCPU?.cpuPercent == nil)
    #expect(noCPU?.memoryPercent != nil)
}

/// A held memory-critical request keeps its target but never invents a percentage for an unread sample.
@Test func criticalRequestWithUnreadMemoryKeepsItsTarget() {
    var engine = ResourceLevelEngine(calibration: testLevels())
    let rows = [levelRow(100, "node", resident: 8 * rGib, cpu: 5),
                levelRow(101, "claude", resident: 2 * rGib, cpu: 30)]
    for t in 1...9 {
        let reading = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 96), rows: rows))
        #expect(reading?.pauseRequest == nil)
    }
    let critical = engine.next(levelTick(10, memory: levelMemory(usedPercent: 96), rows: rows))
    #expect(critical?.pauseRequest?.reason == "critical by memory 96.0%")
    let unread = engine.next(levelTick(11, memory: nil, rows: rows))
    #expect(unread?.level == .critical)
    #expect(unread?.memoryPercent == nil)
    #expect(unread?.transitions.isEmpty == true)
    #expect(unread?.triageTarget?.pid == 100)
    #expect(unread?.pauseRequest?.target == critical?.pauseRequest?.target)
    #expect(unread?.pauseRequest?.reason == "critical by memory unread")
}

/// A held CPU-critical request keeps its target but never invents a percentage for an unread sample.
@Test func criticalRequestWithUnreadCPUKeepsItsTarget() {
    var engine = ResourceLevelEngine(calibration: testLevels())
    let rows = [levelRow(100, "node", resident: 1 * rGib, cpu: 30),
                levelRow(101, "claude", resident: 9 * rGib, cpu: 5)]
    for t in 1...9 {
        let reading = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 40), cpu: 96, rows: rows))
        #expect(reading?.pauseRequest == nil)
    }
    let critical = engine.next(levelTick(10, memory: levelMemory(usedPercent: 40), cpu: 96, rows: rows))
    #expect(critical?.pauseRequest?.reason == "critical by cpu 96.0%")
    let unread = engine.next(levelTick(11, memory: levelMemory(usedPercent: 40), cpu: nil, rows: rows))
    #expect(unread?.level == .critical)
    #expect(unread?.cpuPercent == nil)
    #expect(unread?.transitions.isEmpty == true)
    #expect(unread?.triageTarget?.pid == 100)
    #expect(unread?.pauseRequest?.target == critical?.pauseRequest?.target)
    #expect(unread?.pauseRequest?.reason == "critical by cpu unread")
}

/// 90 names the proposed target and never asks for a pause.
@Test func triageNamesItsTargetAndNeverRequestsPause() {
    var engine = ResourceLevelEngine(calibration: testLevels())
    let rows = [levelRow(100, "node", resident: 8 * rGib), levelRow(101, "claude", resident: 2 * rGib)]
    var reading: ResourceReading?
    for t in 1...10 {
        reading = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 91), rows: rows))
    }
    #expect(reading?.level == .triage)
    #expect(reading?.triageTarget?.pid == 100)
    #expect(reading?.pauseRequest == nil)
}

/// 95 proposes the biggest consumer — by identity, even when it is the user's own session, which Step 3's protection
/// decides about. The engine never selects a substitute.
@Test func criticalProposesOnlyTheBiggestConsumer() {
    var engine = ResourceLevelEngine(calibration: testLevels())
    let rows = [levelRow(100, "claude", resident: 8 * rGib, own: true), levelRow(101, "node", resident: 2 * rGib)]
    var reading: ResourceReading?
    for t in 1...10 {
        reading = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 96), rows: rows))
    }
    #expect(reading?.level == .critical)
    #expect(reading?.pauseRequest?.target.pid == 100)
}

/// The notice lists the busiest consumers by resident memory, biggest first.
@Test func noticeListsTheTopConsumers() {
    var engine = ResourceLevelEngine(calibration: testLevels())
    let rows = [levelRow(100, "node", resident: 2 * rGib), levelRow(101, "claude", resident: 8 * rGib),
                levelRow(102, "swift-frontend", resident: 4 * rGib)]
    var reading: ResourceReading?
    for t in 1...10 {
        reading = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 81), rows: rows))
    }
    #expect(reading?.topConsumers.map(\.pid) == [101, 102, 100])
}

/// An ETA is a warning, not a request: steep decline stays below every level with no pause proposed.
@Test func anETAIsNotAPauseRequest() {
    var engine = ResourceLevelEngine(calibration: testLevels(eta: testETA))
    var reading: ResourceReading?
    for t in 1...60 {
        reading = engine.next(levelTick(Double(t), memory: levelMemory(available: (30 * rGib) - UInt64(t) * (1 << 26))))
    }
    #expect(reading?.eta != nil)
    #expect(reading?.level == .normal)
    #expect(reading?.pauseRequest == nil)
}

/// The calibration picks the percentage: the same sample reads 81% on the available-composite basis and 0% used.
@Test func theCalibrationsBasisSelectsThePercent() {
    let memory = AvailableMemory(freeBytes: rPhysical * 19 / 100, inactiveBytes: 0, speculativeBytes: 0,
                                 purgeableBytes: 0, activeBytes: 0, wiredBytes: 0, compressedBytes: 0,
                                 physicalBytes: rPhysical)
    var composite = ResourceLevelEngine(calibration: testLevels(basis: .availableComplement))
    var display = ResourceLevelEngine(calibration: testLevels())
    var compositeLevel = ResourceLevel.normal
    var displayLevel = ResourceLevel.normal
    for t in 1...10 {
        compositeLevel = composite.next(levelTick(Double(t), memory: memory))?.level ?? .normal
        displayLevel = display.next(levelTick(Double(t), memory: memory))?.level ?? .normal
    }
    #expect(compositeLevel == .notice)
    #expect(displayLevel == .normal)
}

/// A level change carries its figures as a snapshot trigger, so the watcher's existing snapshot spacing applies.
@Test func aLevelChangeHasItsSnapshotTrigger() {
    var engine = ResourceLevelEngine(calibration: testLevels())
    var reading: ResourceReading?
    for t in 1...10 { reading = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 81))) }
    let trigger = reading?.transitions.first.map(SnapshotTrigger.resource)
    #expect(trigger?.reason == .resource)
    #expect(trigger?.detail.contains("notice") == true)
}

/// A CPU-driven critical level proposes the busiest CPU process.
@Test func criticalByCPUProposesTheBusiestCPUProcess() {
    var engine = ResourceLevelEngine(calibration: testLevels())
    let rows = [levelRow(100, "node", resident: 1 * rGib, cpu: 30), levelRow(101, "claude", resident: 9 * rGib, cpu: 5)]
    var reading: ResourceReading?
    for t in 1...10 {
        reading = engine.next(levelTick(Double(t), memory: levelMemory(usedPercent: 40), cpu: 96, rows: rows))
    }
    #expect(reading?.level == .critical)
    #expect(reading?.pauseRequest?.target.pid == 100)
}
