// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// The acting switch (Phase 7 Step 1, calibration lock 3): one `UserDefaults` key per rung, read on every tick so a
/// change takes effect live. Acting ships on only for the copies storm — the Phase 6 condition proven in the field,
/// and Pause undoes it; the memory floor (Step 2) and the throttle (the next phase) stay off until their dry-run logs
/// earn them on each machine (plan § Decisions: "Acting ships off").
public struct ActingSwitches: Equatable, Sendable {
    public static let pauseCopiesKey = "acting.pause.copies"
    public static let pauseMemoryKey = "acting.pause.memory"
    public static let throttleKey = "acting.throttle"
    public static let exemptAppleKey = "acting.exempt.apple"

    /// A copies storm is paused — on by default.
    public var pauseCopies: Bool
    /// The memory floor's rung (the condition Step 2 adds): dry run first.
    public var pauseMemory: Bool
    /// The CPU aggregates' throttle (the next phase).
    public var throttle: Bool
    /// Apple services (`AppleServices`) are warned about and never acted on — on by default, as LuLu's "Allow Apple
    /// Programs" is a visible setting with a trace. It is a subtraction: it takes no rung's targets in, only out.
    public var exemptApple: Bool

    public init(pauseCopies: Bool = true, pauseMemory: Bool = false, throttle: Bool = false, exemptApple: Bool = true) {
        self.pauseCopies = pauseCopies
        self.pauseMemory = pauseMemory
        self.throttle = throttle
        self.exemptApple = exemptApple
    }

    /// The four keys as `lookup` reads them — `UserDefaults.standard.object(forKey:)` in the app. A key never set
    /// (nil) keeps its default, which `UserDefaults.bool(forKey:)` cannot tell: it reads an unset key as false. A
    /// value reads as `bool(forKey:)` reads it, so a launch argument (`-acting.pause.copies NO`, a string in the
    /// argument domain) switches a rung off for that process alone.
    public static func read(_ lookup: (String) -> Any?) -> ActingSwitches {
        ActingSwitches(pauseCopies: flag(lookup(pauseCopiesKey)) ?? true,
                       pauseMemory: flag(lookup(pauseMemoryKey)) ?? false,
                       throttle: flag(lookup(throttleKey)) ?? false,
                       exemptApple: flag(lookup(exemptAppleKey)) ?? true)
    }

    private static func flag(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String: NSString(string: value).boolValue
        default: nil
        }
    }
}

/// What the watcher has paused and must not leave paused (Phase 7 Step 1, calibration lock 9): each process by pid and
/// start time, when it was paused, its subject and why. Kept as `pause-ledger.json` in the snapshot log's folder, so a
/// restart — the app quit, a crash, a login — resumes everything the last run held: a daemon must never leave processes
/// frozen across a restart (the crash-protect lesson).
public struct PauseLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let pid: Int32
        /// With `pid`, what names the process across refreshes (`ProcessTable.RowID`).
        public let startMicroseconds: UInt64
        /// Epoch seconds.
        public let since: Double
        /// The warning's subject key (`command:runaway.sh`).
        public let subject: String
        /// The warning's line, figures and all.
        public let reason: String

        public init(pid: Int32, startMicroseconds: UInt64, since: Double, subject: String, reason: String) {
            self.pid = pid
            self.startMicroseconds = startMicroseconds
            self.since = since
            self.subject = subject
            self.reason = reason
        }
    }

    public static let fileName = "pause-ledger.json"

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    /// The snapshot log's folder (`SnapshotLog.defaultURL`), so `SAUR0N_SNAPSHOT_DIR` moves the ledger with the log.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        SnapshotLog.defaultURL(environment: environment, home: home).deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }

    /// The ledger at `url`; an absent, unreadable or unusable file reads as none — a start never throws over a stale
    /// ledger.
    public static func load(_ url: URL?) -> PauseLedger {
        guard let url, let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(PauseLedger.self, from: data) else { return PauseLedger() }
        return ledger
    }

    /// Writes the whole ledger through a temporary file and a rename, so a crash mid-write leaves the last one whole.
    public func save(_ url: URL?) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + "." + UUID().uuidString)
        try JSONEncoder().encode(self).write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// Records a pause; a pid has one entry — the newest says when and why.
    public mutating func add(_ entry: Entry) {
        entries.removeAll { $0.pid == entry.pid }
        entries.append(entry)
    }

    /// `SIGCONT` to every entry still there by pid and start time — never to a pid that is gone or now belongs to
    /// another process; the resumed pids. The ledger is left empty: what was paused is no longer the watcher's. A nil
    /// `current` — the process list could not be read — leaves the ledger as it is: nothing is known about those
    /// processes, so the record of them is not discarded (they resume on the next start).
    @discardableResult
    public mutating func resumeAll(current: [ProcessIdentity]?, signaller: ProcessSignaller) -> [Int32] {
        guard let current else { return [] }
        var resumed: [Int32] = []
        for entry in entries {
            guard ProcessControl.verify(ProcessTable.RowID(pid: entry.pid, startMicroseconds: entry.startMicroseconds),
                                        in: current) != nil else { continue }
            guard (try? signaller.signal(SIGCONT, to: entry.pid)) != nil else { continue }
            resumed.append(entry.pid)
        }
        entries = []
        return resumed
    }
}

/// The window's paused badges and each warning's Resume targets, shared by manual and watcher actions.
public struct ProcessPauseState: Sendable {
    public private(set) var rows: Set<ProcessTable.RowID> = []
    public var barRows: [String: Set<ProcessTable.RowID>] = [:]

    public init() {}

    public mutating func record(_ action: ProcessControl.Action, _ row: ProcessUsage) {
        switch action {
        case .pause: rows.insert(ProcessTable.rowID(row))
        case .resume: rows.remove(ProcessTable.rowID(row))
        case .quit, .forceQuit: break
        }
    }

    /// Apply successful watcher pauses before a reading can be held while the window is hidden.
    public mutating func recordWatcher(_ actions: [WatcherModel.Action], rows: [ProcessUsage]) {
        for action in actions where action.acted && !action.paused.isEmpty {
            let pids = Set(action.paused)
            let paused = Set(rows.filter { pids.contains($0.pid) }.map(ProcessTable.rowID))
            self.rows.formUnion(paused)
            barRows[action.subject.key, default: []].formUnion(paused)
        }
    }

    /// A badge stays only while the process still reads as stopped.
    public mutating func refresh(isStopped: (Int32) -> Bool?) {
        rows = rows.filter { isStopped($0.pid) == true }
    }

    public func barPaused(_ subject: String) -> Bool {
        !(barRows[subject]?.isDisjoint(with: rows) ?? true)
    }
}

/// The watcher (Phase 7 Step 1): the warning engine and the acting decision the app's sample loop drives, with or
/// without a window, and the pause ledger behind them. There is no second process and no XPC (calibration 2026-10-25,
/// the user's "a"): the app in `--watch` is the watcher, started by the LaunchAgent at login, and its window is one of
/// its scenes. Saur0nCore imports no AppKit, so nothing here can depend on a window existing.
public struct WatcherModel: Sendable {
    /// The rung an action rides. This step's copies storm pauses; Step 2 adds the memory floor, the next phase the
    /// throttle (`ActingSwitches` carries their keys already).
    public enum Rung: String, Equatable, Sendable { case pauseCopies }

    /// One warning's action as the snapshot log keeps it: `would act:` while the rung's switch is off, `acted:` when
    /// it paused the warning's processes.
    public struct Action: Equatable, Sendable {
        public let subject: Warning.Subject
        public let name: String
        public let rung: Rung
        public let acted: Bool
        /// The processes paused; empty while the switch is off.
        public let paused: [Int32]
        /// What the log's detail says: the action, the subject and the warning's figures.
        public let detail: String

        /// The entry the snapshot log takes — the log and write path an ordinary warning snapshot uses (calibration
        /// lock 5). The reason stays `warning`: the entry is a warning's, and its detail says what was done about it.
        public var trigger: SnapshotTrigger { SnapshotTrigger(reason: .warning, detail: detail) }
    }

    public static let wouldActPrefix = "would act: ", actedPrefix = "acted: "

    /// Where the pause ledger is kept; nil keeps it in memory only.
    public let ledgerURL: URL?
    public private(set) var ledger: PauseLedger
    /// Why the last write of the ledger failed, nil while it succeeds: processes paused and not on disk are the one
    /// state a restart cannot recover, so the loop reports it.
    public private(set) var ledgerError: String?
    /// The subjects whose warning has already been acted on (or logged) this raise: one action per raise, not one a
    /// second. A subject that clears is forgotten, so a re-raise acts again — re-pausing a stopped pid is a no-op
    /// (calibration lock 4; Step 3's latch narrows this further).
    private var raised: Set<Warning.Subject> = []
    /// The Apple services a raised warning named and the exemption held back, by pid and start time: if
    /// `acting.exempt.apple` goes off while that warning lasts, these — and only these — become targets on the next tick.
    /// What was already paused is not repeated, and a pid that now belongs to another process is not one of them.
    private var withheld: [Warning.Subject: Set<ProcessTable.RowID>] = [:]
    private var engine: WarningEngine

    public init(ledgerURL: URL? = nil, thresholds: WarningThresholds = WarningThresholds()) {
        self.ledgerURL = ledgerURL
        ledger = PauseLedger.load(ledgerURL)
        engine = WarningEngine(thresholds: thresholds)
    }

    /// The engine, one window at a time: the warnings in force, the ignored ones left out — as the window's bar has
    /// them, so an Ignore holds the watcher back too.
    public mutating func warnings(_ tick: WarningTick, ignoring: Set<Warning.Subject> = []) -> [Warning] {
        engine.next(tick, ignoring: ignoring)
    }

    /// The subjects whose warning is raised, ignored or not: the window's Ignore lasts while its subject is here.
    public var raisedSubjects: Set<Warning.Subject> { engine.raisedSubjects }

    /// What the last run left paused resumes before the first tick; the resumed pids. Throws when the ledger cannot be
    /// written back, so a record that may be stale is never taken for a saved one.
    @discardableResult
    public mutating func resumeOnStart(current: [ProcessIdentity]?, signaller: ProcessSignaller) throws -> [Int32] {
        let resumed = ledger.resumeAll(current: current, signaller: signaller)
        if current != nil { try ledger.save(ledgerURL) }
        return resumed
    }

    /// This tick's new warnings, each acted on or logged. A warning carrying the copies condition rides the pause rung:
    /// with `acting.pause.copies` on, its processes go through the window's own Pause path — `ProcessControl.perform`
    /// with `.pause`, each checked against a fresh process list by pid and start time — and every one it paused is
    /// written to the ledger. With the switch off, nothing is signalled and the warning's figures are logged for the
    /// dry run. `current` reads the process list only when a signal is to be sent; a failed read leaves the warning
    /// for the next tick.
    ///
    /// Two sets never become targets: the user's own interactive session and its launch wrappers (`usersOwn`), and —
    /// while `acting.exempt.apple` is on — the Apple services (`ProcessUsage.isAppleService`), which are warned about
    /// but left running. A warning of Apple services alone is logged `would act:` with "(not paused: Apple service)";
    /// a mixed one pauses its other members. The services held back are remembered by pid and start time: if the
    /// switch goes off while the warning lasts they are paused then, once, and nothing already paused is paused again.
    public mutating func decide(warnings: [Warning], rows: [ProcessUsage], switches: ActingSwitches,
                                current: () throws -> [ProcessIdentity], signaller: ProcessSignaller,
                                ownPid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                at now: Double = Date().timeIntervalSince1970) -> [Action] {
        raised.formIntersection(Set(warnings.map(\.subject)))
        withheld = withheld.filter { raised.contains($0.key) }
        var actions: [Action] = []
        for warning in warnings {
            // Only the copies storm has a rung in this step: a load, system-share, group or unattributed line is not
            // something pause is the answer to.
            guard warning.conditions.contains(where: { $0.kind == .copies }) else { continue }
            let pids = Set(warning.pids)
            let named = pauseReach(pids, rows: rows, ownPid: ownPid)
            let figures = warning.conditions.map(\.text).joined(separator: "; ")
            if raised.contains(warning.subject) {
                // Services that join the warning after the raise are held back the same way as the first ones.
                if switches.exemptApple, switches.pauseCopies {
                    let late = named.filter(\.isAppleService).map(ProcessTable.rowID)
                    if !late.isEmpty { withheld[warning.subject, default: []].formUnion(late) }
                }
                guard !switches.exemptApple, switches.pauseCopies, let held = withheld[warning.subject], !held.isEmpty else {
                    continue
                }
                let identities: [ProcessIdentity]
                do { identities = try current() } catch { continue }    // the next tick tries again
                withheld[warning.subject] = nil
                let targets = named.filter { held.contains(ProcessTable.rowID($0)) }
                guard !targets.isEmpty else { continue }
                let paused = pause(targets, for: warning, current: identities, signaller: signaller, ownPid: ownPid, at: now)
                actions.append(Action(subject: warning.subject, name: warning.name, rung: .pauseCopies, acted: true,
                                      paused: paused, detail: "\(Self.actedPrefix)\(warning.name) — paused "
                                          + "\(paused.count) of \(targets.count) Apple services, the exemption now off "
                                          + "— \(figures)"))
                continue
            }
            raised.insert(warning.subject)
            guard switches.pauseCopies else {
                actions.append(Action(subject: warning.subject, name: warning.name, rung: .pauseCopies, acted: false,
                                      paused: [], detail: "\(Self.wouldActPrefix)\(warning.name) — \(figures) "
                                          + "(acting.pause.copies is off)"))
                continue
            }
            let exempt = switches.exemptApple ? named.filter(\.isAppleService) : []
            let exemptPids = Set(exempt.map(\.pid))
            let targets = named.filter { !exemptPids.contains($0.pid) }
            if !exempt.isEmpty { withheld[warning.subject] = Set(exempt.map(ProcessTable.rowID)) }
            if targets.isEmpty, !exempt.isEmpty {
                actions.append(Action(subject: warning.subject, name: warning.name, rung: .pauseCopies, acted: false,
                                      paused: [], detail: "\(Self.wouldActPrefix)\(warning.name) — \(figures) "
                                          + "(not paused: Apple service)"))
                continue
            }
            let identities: [ProcessIdentity]
            do { identities = try current() } catch {
                raised.remove(warning.subject)    // no process list this tick: the next one tries again
                withheld[warning.subject] = nil
                continue
            }
            let paused = pause(targets, for: warning, current: identities, signaller: signaller, ownPid: ownPid, at: now)
            let left = exempt.isEmpty ? "" : " (\(exempt.count) Apple service\(exempt.count == 1 ? "" : "s") left running)"
            actions.append(Action(subject: warning.subject, name: warning.name, rung: .pauseCopies, acted: true,
                                  paused: paused, detail: "\(Self.actedPrefix)\(warning.name) — paused "
                                      + "\(paused.count) of \(targets.count)\(left) — \(figures)"))
        }
        return actions
    }

    /// Reach the warning's workload through the bar's selection path, sparing session wrappers even below a target.
    /// Apple services are withheld by `decide` after the walk, so turning their exemption off still pauses each once.
    private func pauseReach(_ pids: Set<Int32>, rows: [ProcessUsage], ownPid: Int32) -> [ProcessUsage] {
        let reach = ProcessControl.select(rows.filter { pids.contains($0.pid) }, rows: rows, ownPid: ownPid,
                                          sparing: ProcessControl.barSparing(exempt: []))
        return reach.targets + ProcessControl.resolve(reach.alsoEnds, in: rows)
    }

    /// Pause on `targets` through the window's own path, each checked against `current` by pid and start time; the pids it
    /// paused, each written to the ledger.
    private mutating func pause(_ targets: [ProcessUsage], for warning: Warning, current: [ProcessIdentity],
                                signaller: ProcessSignaller, ownPid: Int32, at now: Double) -> [Int32] {
        let outcomes = ProcessControl.perform(.pause, on: targets, current: current, signaller: signaller,
                                              terminator: AppTerminator(terminate: { _ in nil },
                                                                        forceTerminate: { _ in nil }),
                                              ownPid: ownPid)
        let paused = outcomes.compactMap { outcome -> Int32? in
            if case .success = outcome.result { return outcome.pid }
            return nil
        }
        for pid in paused {
            guard let row = targets.first(where: { $0.pid == pid }) else { continue }
            ledger.add(PauseLedger.Entry(pid: pid, startMicroseconds: row.startMicroseconds, since: now,
                                         subject: warning.subject.key, reason: warning.text))
        }
        do {
            try ledger.save(ledgerURL)
            ledgerError = nil
        } catch {
            ledgerError = "\(error)"
        }
        return paused
    }
}
