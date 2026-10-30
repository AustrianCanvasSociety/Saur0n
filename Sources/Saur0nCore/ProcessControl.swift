// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Why a signal or an app quit did not happen.
public enum ProcessControlError: Error, Equatable, Sendable {
    /// EPERM: root's or another user's process; the administrator path can still reach it.
    case permissionDenied
    /// The pid is no longer in the process list (ESRCH, or missing from the fresh list).
    case gone
    /// The pid is in the list with another start time: a new process took it.
    case reused
    /// `NSRunningApplication.terminate()` / `forceTerminate()` returned false.
    case appRefused
    /// Never signalled from the window: kernel_task, launchd or Saur0n itself (`ProcessControl.refusal`).
    case refused(reason: String)
    case failed(errno: Int32)
}

/// Sends one signal to one pid; the window uses `KillSignaller`, the tests a recorder.
public protocol ProcessSignaller: Sendable {
    func signal(_ sig: Int32, to pid: Int32) throws
}

/// `kill(2)`, its errno named: EPERM → `.permissionDenied`, ESRCH → `.gone`, else `.failed`.
public struct KillSignaller: ProcessSignaller {
    public init() {}

    public func signal(_ sig: Int32, to pid: Int32) throws {
        guard kill(pid, sig) != 0 else { return }
        let error = errno
        switch error {
        case EPERM: throw ProcessControlError.permissionDenied
        case ESRCH: throw ProcessControlError.gone
        default: throw ProcessControlError.failed(errno: error)
        }
    }
}

/// An app's Quit and Force Quit as the window runs them (`NSRunningApplication.terminate()` / `forceTerminate()`):
/// each returns nil when no running application has that pid (a helper inside a bundle), so the signal is sent
/// instead, else whether the app took the request.
public struct AppTerminator {
    public let terminate: (Int32) -> Bool?
    public let forceTerminate: (Int32) -> Bool?

    public init(terminate: @escaping (Int32) -> Bool?, forceTerminate: @escaping (Int32) -> Bool?) {
        self.terminate = terminate
        self.forceTerminate = forceTerminate
    }
}

/// Quit, Force Quit, Pause and Resume from the window as pure rules (Phase 5 Step 5): which means a row gets, what
/// goes down with it, the order a group is signalled in, the pid-and-start guard, the administrator command. Signals
/// go through `ProcessSignaller`, apps through `AppTerminator`, so the tests stub both. Research 2026-10-20 § Q2.
public enum ProcessControl {
    public enum Action: String, Sendable {
        case quit, forceQuit, pause, resume

        /// The button and sheet wording: Activity Monitor's "Quit" / "Force Quit"; htop's SIGSTOP / SIGCONT as
        /// "Pause" / "Resume".
        public var title: String {
            switch self {
            case .quit: "Quit"
            case .forceQuit: "Force Quit"
            case .pause: "Pause"
            case .resume: "Resume"
            }
        }

        /// Quit, Force Quit, Pause or Resume as the signal sent when no app takes it.
        public var signal: Int32 {
            switch self {
            case .quit: SIGTERM
            case .forceQuit: SIGKILL
            case .pause: SIGSTOP
            case .resume: SIGCONT
            }
        }
    }

    public enum Means: Equatable, Sendable {
        case terminateApp, forceTerminateApp, signal(Int32)
    }

    /// An app row quits as the app (File > Quit: it may save; Activity Monitor's Quit), every other row by signal;
    /// Pause and Resume are signals for every row.
    public static func means(for action: Action, row: ProcessUsage) -> Means {
        switch (action, row.app != nil) {
        case (.quit, true): .terminateApp
        case (.forceQuit, true): .forceTerminateApp
        default: .signal(action.signal)
        }
    }

    // MARK: - The guard

    /// Why `pid` is never signalled from the window, else nil. kernel_task (0) and launchd (1): Activity Monitor
    /// greys out Quit for them, and `kill(2)` reads 0 as the caller's own process group, -1 as every process and a
    /// negative pid as a process group. Saur0n itself (`ownPid`): ending it midway would leave the rest of a group
    /// unsignalled, pausing it would freeze the window with no way back.
    public static func refusal(_ pid: Int32, ownPid: Int32) -> String? {
        if pid <= 1 { return "kernel_task and launchd can't be ended" }
        if pid == ownPid { return "Saur0n itself is left running" }
        return nil
    }

    /// What an action on `selected` reaches: the targets and what goes down with them, the refused pids dropped from
    /// both (before the walk, so "Also ends" from launchd never lists every process), and one sheet line per reason a
    /// pid was dropped.
    public struct Selection: Equatable, Sendable {
        public let targets: [ProcessUsage]
        public let alsoEnds: [Dependant]
        public let left: [String]
        /// The processes `select` was asked to spare (`sparing`) and so neither target nor "Also ends": the sheet names
        /// them among those left running.
        public let spared: [Dependant]
    }

    /// What a warning's Pause and Stop leave alone, beyond kernel_task, launchd and Saur0n itself: the user's interactive
    /// session and its launch wrappers (`usersOwn`) wherever the walk reaches them, and the Apple services the line
    /// exempts (`WarningBar.Line.exempt`).
    public static func barSparing(exempt: Set<Int32>) -> (ProcessUsage) -> String? {
        { row in
            if row.usersOwn { return "your session and its launch wrappers are left running" }
            return exempt.contains(row.pid) ? "Apple services are left running" : nil
        }
    }

    /// `sparing` names a reason for each row an action must leave alone on top of the always-refused pids — a warning's
    /// Pause and Stop spare the user's interactive session and its launch wrappers. It is applied to the selected rows
    /// and again to everything the walk reaches below them, so a spared process cannot come back as a dependant; the
    /// Process menu passes none and keeps reaching everything under a row.
    public static func select(_ selected: [ProcessUsage], rows: [ProcessUsage],
                              ownPid: Int32 = ProcessInfo.processInfo.processIdentifier,
                              sparing: (ProcessUsage) -> String? = { _ in nil }) -> Selection {
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var left: [String] = []
        var spared: [Dependant] = []
        func note(_ reason: String) { if !left.contains(reason) { left.append(reason) } }
        let workable = selected.filter { refusal($0.pid, ownPid: ownPid) == nil }
        var targets: [ProcessUsage] = []
        for row in workable {
            if let reason = sparing(row) {
                note(reason)
                spared.append(dependant(row, parent: byPid[row.ppid]))
            } else {
                targets.append(row)
            }
        }
        let walked = dependants(of: targets.map(\.pid), rows: rows, stoppingAt: ownPid)
        for reason in (selected.map(\.pid) + walked.map(\.pid)).compactMap({ refusal($0, ownPid: ownPid) }) { note(reason) }
        var alsoEnds: [Dependant] = []
        for dependant in walked where refusal(dependant.pid, ownPid: ownPid) == nil {
            if let row = byPid[dependant.pid], let reason = sparing(row) {
                note(reason)
                spared.append(dependant)
            } else {
                alsoEnds.append(dependant)
            }
        }
        return Selection(targets: targets, alsoEnds: alsoEnds, left: left, spared: spared)
    }

    /// The rows of the latest table that `listed` still names: the same pid with the same start time. A pid taken by a
    /// new process, or listed without a start time, resolves to nothing — the sheet acts on what it showed.
    public static func resolve(_ listed: [Dependant], in rows: [ProcessUsage]) -> [ProcessUsage] {
        let byID = Dictionary(rows.map { (ProcessTable.rowID($0), $0) }, uniquingKeysWith: { a, _ in a })
        return listed.compactMap { byID[ProcessTable.RowID(pid: $0.pid, startMicroseconds: $0.startMicroseconds)] }
    }

    /// The fresh process list's entry for `id`: its pid with the same start time, else nil (gone, or reused).
    public static func verify(_ id: ProcessTable.RowID, in identities: [ProcessIdentity]) -> ProcessIdentity? {
        identities.first { $0.pid == id.pid && $0.startMicroseconds == id.startMicroseconds }
    }

    /// The process list now (one sysctl): what `perform` checks each row against.
    public static func currentIdentities() throws -> [ProcessIdentity] { try ProcessReaders.processList() }

    // MARK: - What goes down with it

    public struct Dependant: Equatable, Sendable {
        public enum Kind: String, Sendable, CaseIterable {
            case claudeSession, testRun, vm, shell, tmuxServer, terminalLogin, process

            /// One of them, as the sheet names it.
            public var label: String {
                switch self {
                case .claudeSession: "Claude Code session"
                case .testRun: "test run"
                case .vm: "VM"
                case .shell: "shell"
                case .tmuxServer: "tmux server"
                case .terminalLogin: "terminal login"
                case .process: "process"
                }
            }

            var plural: String { self == .process ? "processes" : label + "s" }
        }

        public let pid: Int32
        /// A session by its name, else the readable name, else the name.
        public let name: String
        public let kind: Kind
        /// With `pid`, the process as it was listed (`ProcessTable.RowID`): what the confirmed action acts on, so a pid
        /// a new process has taken since is not a target. 0 for a process known by pid alone (a "Used by" row from
        /// `nettop`), which is never acted on.
        public let startMicroseconds: UInt64

        public init(pid: Int32, name: String, kind: Kind, startMicroseconds: UInt64 = 0) {
            self.pid = pid
            self.name = name
            self.kind = kind
            self.startMicroseconds = startMicroseconds
        }
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh"]

    /// What the sheet calls `row`: a Claude Code session's own process (the topmost one of its session) by the
    /// session's name; a VM; a test run, as `ReadableName` names one; a shell; a tmux server; a terminal tab's `login`.
    static func dependant(_ row: ProcessUsage, parent: ProcessUsage?) -> Dependant {
        let base = row.name.hasPrefix("-") ? String(row.name.dropFirst()) : row.name    // a login shell's `-zsh`
        if let session = row.session, session.kind == .claude, parent?.session != session {
            return Dependant(pid: row.pid, name: session.name, kind: .claudeSession, startMicroseconds: row.startMicroseconds)
        }
        let readable = row.readableName
        let kind: Dependant.Kind
        if row.vm != nil {
            kind = .vm
        } else if let readable, ["test", "bench:", "doctest"].contains(where: readable.hasPrefix) {
            kind = .testRun
        } else if shells.contains(base) {
            kind = .shell
        } else if base == "tmux" {
            kind = .tmuxServer
        } else if base == "login" {
            kind = .terminalLogin
        } else {
            kind = .process
        }
        return Dependant(pid: row.pid, name: row.vm?.name ?? shownName(row), kind: kind,
                         startMicroseconds: row.startMicroseconds)
    }

    /// A row as the table's Name column shows it: the name, then its readable name in parentheses
    /// ("sleep (suspend execution for an interval of time)").
    public static func shownName(_ row: ProcessUsage) -> String {
        row.readableName.map { "\(row.name) (\($0))" } ?? row.name
    }

    /// Children by parent, each list by pid: the walks below go through them.
    static func children(_ rows: [ProcessUsage]) -> [Int32: [Int32]] {
        var out: [Int32: [Int32]] = [:]
        for row in rows where row.ppid != row.pid { out[row.ppid, default: []].append(row.pid) }
        return out.mapValues { $0.sorted() }
    }

    /// Every descendant of `pids` by ppid, parents before children (siblings by pid), the targets themselves left
    /// out; a ppid loop ends the walk.
    public static func dependants(of pids: [Int32], rows: [ProcessUsage]) -> [Dependant] {
        dependants(of: pids, rows: rows, stoppingAt: nil)
    }

    /// Selection names Saur0n as left running, but never infers its helpers as dependants of a selected ancestor.
    private static func dependants(of pids: [Int32], rows: [ProcessUsage], stoppingAt: Int32?) -> [Dependant] {
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let childrenOf = children(rows)
        let targets = Set(pids)
        var seen = targets, out: [Dependant] = []
        func walk(_ pid: Int32) {
            for child in childrenOf[pid] ?? [] where seen.insert(child).inserted {
                if let row = byPid[child] { out.append(dependant(row, parent: byPid[row.ppid])) }
                if child != stoppingAt { walk(child) }
            }
        }
        for pid in pids { walk(pid) }
        return out
    }

    /// "Also ends 4: 1 Claude Code session, 1 test run, 2 shells" — counts by kind in `Kind`'s order; empty for none.
    public static func summary(_ dependants: [Dependant]) -> String {
        guard !dependants.isEmpty else { return "" }
        let counts = Dependant.Kind.allCases.compactMap { kind -> String? in
            let n = dependants.filter { $0.kind == kind }.count
            return n == 0 ? nil : "\(n) \(n == 1 ? kind.label : kind.plural)"
        }
        return "Also ends \(dependants.count): " + counts.joined(separator: ", ")
    }

    /// The confirm button: the action alone for one process with nothing under it, "Quit all N" (targets plus
    /// dependants) otherwise.
    public static func confirmTitle(action: Action, targetCount: Int = 1, dependantCount: Int) -> String {
        let n = targetCount + dependantCount
        return n <= 1 ? action.title : "\(action.title) all \(n)"
    }

    /// The processes holding a TCP connection to a port `pid` listens on: an `Established` socket whose remote port
    /// is a listening one and whose remote host is the listener's own address, or — for a listener on every address
    /// (`*`) — loopback or any address this machine's sockets name as local. By pid; `pid` itself left out. A pid
    /// the rows lack keeps its `nettop` name. TCP only: Unix-domain sockets, Mach and XPC are not seen.
    public static func usedBy(_ pid: Int32, listing: SocketListing, rows: [ProcessUsage]) -> [Dependant] {
        let listeners = (listing.sockets[pid] ?? []).filter { $0.proto.hasPrefix("tcp") && $0.state == "Listen" }
            .map { Socket.endpoint($0.local) }.filter { $0.port != "*" && !$0.port.isEmpty }
        guard !listeners.isEmpty else { return [] }
        let loopback: Set<String> = ["127.0.0.1", "::1", "localhost"]
        let machine = loopback.union(listing.sockets.values.joined().map { Socket.endpoint($0.local).host }.filter { $0 != "*" })
        func reaches(_ remote: (host: String, port: String)) -> Bool {
            listeners.contains { listener in
                guard listener.port == remote.port else { return false }
                if listener.host == "*" { return machine.contains(remote.host) }
                return listener.host == remote.host || (loopback.contains(listener.host) && loopback.contains(remote.host))
            }
        }
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        return listing.sockets.keys.sorted().compactMap { other in
            guard other != pid, listing.sockets[other]!.contains(where: {
                $0.proto.hasPrefix("tcp") && $0.state == "Established" && reaches(Socket.endpoint($0.remote))
            }) else { return nil }
            guard let row = byPid[other] else {
                return Dependant(pid: other, name: listing.names[other] ?? "pid \(other)", kind: .process)
            }
            let shown = dependant(row, parent: byPid[row.ppid])
            return shown.kind == .claudeSession ? shown : Dependant(pid: other, name: shown.name, kind: .process)
        }
    }

    // MARK: - Signalling

    /// `pids` children first: each one after everything under it among `pids` (siblings by pid), so a group's
    /// parents and the target go last, even across unselected wrappers. A ppid loop ends the walk.
    public static func order(_ pids: [Int32], rows: [ProcessUsage]) -> [Int32] {
        order(pids, parent: Dictionary(rows.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a }))
    }

    private static func order(_ pids: [Int32], parent: [Int32: Int32]) -> [Int32] {
        let set = Set(pids)
        var selectedParent: [Int32: Int32] = [:], childrenOf: [Int32: [Int32]] = [:]
        for pid in set {
            var up = parent[pid], seen: Set<Int32> = [pid]
            while let ancestor = up, !set.contains(ancestor), seen.insert(ancestor).inserted {
                up = parent[ancestor]
            }
            guard let ancestor = up, ancestor != pid, set.contains(ancestor) else { continue }
            selectedParent[pid] = ancestor
            childrenOf[ancestor, default: []].append(pid)
        }
        let sortedChildren = childrenOf.mapValues { $0.sorted() }
        var seen: Set<Int32> = [], out: [Int32] = []
        func walk(_ pid: Int32) {
            guard seen.insert(pid).inserted else { return }
            for child in sortedChildren[pid] ?? [] { walk(child) }
            out.append(pid)
        }
        // Roots first (no selected ancestor), then anything a loop left unvisited.
        for pid in pids.sorted() where selectedParent[pid] == nil { walk(pid) }
        for pid in pids.sorted() { walk(pid) }
        return out
    }

    public struct Outcome: Equatable, Sendable {
        public let pid: Int32
        public let result: Result<Void, ProcessControlError>

        public init(pid: Int32, result: Result<Void, ProcessControlError>) {
            self.pid = pid
            self.result = result
        }

        public static func == (a: Outcome, b: Outcome) -> Bool {
            switch (a.result, b.result) {
            case (.success, .success): a.pid == b.pid
            case let (.failure(x), .failure(y)): a.pid == b.pid && x == y
            default: false
            }
        }
    }

    /// `action` on every row in `order`, each checked against `current` (a process list read just before) by pid and
    /// start time first, continuing past failures. On Quit and Force Quit a row inside the same app as a row above it
    /// is left to that app, which ends its own helpers (Activity Monitor quits an app as one). A pid `refusal` names
    /// is never signalled nor handed to the app terminator.
    public static func perform(_ action: Action, on rows: [ProcessUsage], current: [ProcessIdentity],
                               signaller: ProcessSignaller, terminator: AppTerminator,
                               ownPid: Int32 = ProcessInfo.processInfo.processIdentifier) -> [Outcome] {
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func leftToApp(_ row: ProcessUsage) -> Bool {
            guard action == .quit || action == .forceQuit, let app = row.app else { return false }
            var seen: Set<Int32> = [row.pid]
            var up = byPid[row.ppid]
            while let ancestor = up, seen.insert(ancestor.pid).inserted {
                if ancestor.app == app { return true }
                up = byPid[ancestor.ppid]
            }
            return false
        }
        // Fresh identities retain the ancestry of wrappers that selection spared; the selected rows keep their links.
        var parent = Dictionary(current.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        for row in rows { parent[row.pid] = row.ppid }
        return order(rows.map(\.pid), parent: parent).compactMap { pid in
            guard let row = byPid[pid], !leftToApp(row) else { return nil }
            if let reason = refusal(pid, ownPid: ownPid) { return Outcome(pid: pid, result: .failure(.refused(reason: reason))) }
            guard verify(ProcessTable.rowID(row), in: current) != nil else {
                return Outcome(pid: pid, result: .failure(current.contains { $0.pid == pid } ? .reused : .gone))
            }
            let answer: Bool?
            switch means(for: action, row: row) {
            case .terminateApp: answer = terminator.terminate(pid)
            case .forceTerminateApp: answer = terminator.forceTerminate(pid)
            case .signal: answer = nil
            }
            if let answer { return Outcome(pid: pid, result: answer ? .success(()) : .failure(.appRefused)) }
            do {
                try signaller.signal(action.signal, to: pid)
                return Outcome(pid: pid, result: .success(()))
            } catch let error as ProcessControlError {
                return Outcome(pid: pid, result: .failure(error))
            } catch {
                return Outcome(pid: pid, result: .failure(.failed(errno: EINVAL)))
            }
        }
    }

    /// What the sheet says when `error` stopped the action on `name` (pid `pid`).
    public static func message(_ error: ProcessControlError, name: String, pid: Int32) -> String {
        switch error {
        case .gone: "\(name) (pid \(pid)) is gone"
        case .reused: "pid \(pid) now belongs to another process"
        case .permissionDenied: "\(name) (pid \(pid)) belongs to root or another user; macOS refused"
        case .appRefused: "\(name) (pid \(pid)) did not take the request"
        case .refused(let reason): "\(name) (pid \(pid)): \(reason)"
        case .failed(let code): "\(name) (pid \(pid)): \(String(cString: strerror(code)))"
        }
    }

    // MARK: - Paused state, launchd, the administrator path

    /// Whether `pid` is stopped (`p_stat == SSTOP`, what `ps` shows as T), from one `KERN_PROC_PID` sysctl; nil when
    /// it cannot be read (gone).
    public static func isStopped(_ pid: Int32) -> Bool? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return Int32(info.kp_proc.p_stat) == SSTOP
    }

    /// Whether launchd started `pid` as a job — its parent is launchd and `launchctl list` (the user's domain) names
    /// its pid in the first column — so it may come back after a quit. Whether the job is kept alive is not read.
    public static func launchdManaged(_ pid: Int32, ppid: Int32, launchctlList: String) -> Bool {
        guard ppid == 1, pid > 0 else { return false }
        let wanted = String(pid)
        return launchctlList.split(whereSeparator: \.isNewline).contains {
            $0.split(separator: "\t", maxSplits: 1).first.map(String.init) == wanted
        }
    }

    /// `launchctl list` now; nil when it fails.
    public static func launchctlList() -> String? {
        try? ProcessReaders.run(ProcessReaders.Command(path: "/bin/launchctl", arguments: ["list"]).start())
    }

    /// An administrator action is either a complete command or an explanation; a refused pid never disappears into
    /// a partial command that the window could report as wholly successful.
    public struct AdministratorBatch {
        public let command: String?
        public let error: String?

        public init(signal: Int32, rows: [ProcessUsage],
                    ownPid: Int32 = ProcessInfo.processInfo.processIdentifier) {
            var commands: [String] = [], failures: [String] = []
            for row in rows {
                do {
                    commands.append(try administratorCommand(signal: signal, pid: row.pid, ownPid: ownPid))
                } catch let error as ProcessControlError {
                    failures.append(message(error, name: row.name, pid: row.pid))
                } catch {
                    failures.append("\(error)")
                }
            }
            if rows.isEmpty { failures.append("no processes remain for the administrator action") }
            command = failures.isEmpty ? commands.joined(separator: "; ") : nil
            error = failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
    }

    /// The command the administrator path runs as root: `kill -TERM 123` — the signal's name and the pid as an
    /// integer, nothing a name or path could inject. A pid `refusal` names throws `.refused` (as root, `kill -TERM 0`
    /// would signal the caller's process group and `kill -TERM -1` every process).
    public static func administratorCommand(signal: Int32, pid: Int32,
                                            ownPid: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> String {
        if let reason = refusal(pid, ownPid: ownPid) { throw ProcessControlError.refused(reason: reason) }
        let names: [Int32: String] = [SIGTERM: "TERM", SIGKILL: "KILL", SIGSTOP: "STOP", SIGCONT: "CONT"]
        return "kill -\(names[signal] ?? String(signal)) \(pid)"
    }
}
