// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The system's memory pressure, as Activity Monitor's Memory Pressure graph colours it (plan § Decisions: memory
/// steps the Dock icon by pressure, not used bytes — a Mac keeps memory full on purpose).
public enum MemoryPressure: Sendable {
    case normal, warning, critical

    /// The kernel's `kern.memorystatus_vm_pressure_level`, which on macOS returns the dispatch levels with no
    /// privilege check (xnu `bsd/kern/kern_memorystatus_notify.c`; `DISPATCH_MEMORYPRESSURE_NORMAL` / `_WARN` /
    /// `_CRITICAL` are 1, 2 and 4 in `dispatch/source.h`); nil for any other value. Stats reads the same sysctl.
    public init?(level: Int) {
        switch level {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }

    /// One sysctl a reading; nil when it cannot be read or holds an unknown level.
    public static func read() -> MemoryPressure? {
        (try? SystemReaders.sysctlInt("kern.memorystatus_vm_pressure_level")).flatMap(MemoryPressure.init(level:))
    }
}

/// The starting figures (plan § Decisions, "The Dock icon is the background signal"), tuned at the Step 9 demo by value.
public struct DockThresholds: Sendable {
    /// CPU, as a share of the whole machine, at which steps 2–5 begin; below the first the tile stays at rest.
    public var cpuSteps = [50.0, 65, 80, 95]
    public var orangeBorder = 80.0, redBorder = 90.0
    public var memoryWarningStep = 3, memoryCriticalStep = 5
    /// As the warnings: on after `hold` seconds at or above a bar, off after `clearHold` seconds below 7/8 of it
    /// (`WarningThresholds`; netdata's load alarm).
    public var hold = 10.0, clearRatio = 7.0 / 8, clearHold = 10.0
    /// A window starting more than this after the last one ended restarts every run (a read was missed).
    public var gap = 1.0

    public init() {}
}

/// The Dock icon's level (Phase 6 Step 9): the tile's step on the "Red only" ramp, the higher of the CPU step and the
/// memory-pressure step, and the CPU border. Each CPU bar, each border and each pressure level is its own latch on the
/// warnings' rule (`WarningEngine.Hold`), so the icon never flickers. Pure: a reading in, the state out.
public struct DockLevel: Sendable {
    public enum Border: String, Sendable { case none, orange, red }

    public struct State: Equatable, Sendable {
        /// 1 (the normal black) to 5 (`#a30a0e`).
        public var step = 1
        public var cpuStep = 1
        public var memoryStep = 1
        public var border = Border.none

        public init() {}
    }

    public let thresholds: DockThresholds
    var cpu: [WarningEngine.Hold]
    var orange = WarningEngine.Hold(), red = WarningEngine.Hold()
    var warning = WarningEngine.Hold(), critical = WarningEngine.Hold()
    var lastEnd: Double?

    public init(thresholds: DockThresholds = DockThresholds()) {
        self.thresholds = thresholds
        cpu = Array(repeating: WarningEngine.Hold(), count: thresholds.cpuSteps.count)
    }

    /// One reading: the window ending at `end`, `seconds` long, with the machine's CPU over it and the pressure at its end.
    public mutating func next(end: Double, seconds: Double, cpuPercent: Double, pressure: MemoryPressure?) -> State {
        let t = thresholds, start = end - seconds
        if let lastEnd, start > lastEnd + t.gap {
            for i in cpu.indices { cpu[i].restart() }
            for keyPath in [\DockLevel.orange, \.red, \.warning, \.critical] { self[keyPath: keyPath].restart() }
        }
        lastEnd = end
        func step(_ hold: inout WarningEngine.Hold, bar: Double) {
            hold.step(start: start, end: end, above: cpuPercent >= bar, belowClear: cpuPercent < bar * t.clearRatio,
                      hold: t.hold, clearHold: t.clearHold)
        }
        for (i, bar) in t.cpuSteps.enumerated() { step(&cpu[i], bar: bar) }
        step(&orange, bar: t.orangeBorder)
        step(&red, bar: t.redBorder)
        let atWarning = pressure == .warning || pressure == .critical, atCritical = pressure == .critical
        warning.step(start: start, end: end, above: atWarning, belowClear: !atWarning, hold: t.hold, clearHold: t.clearHold)
        critical.step(start: start, end: end, above: atCritical, belowClear: !atCritical, hold: t.hold,
                      clearHold: t.clearHold)

        var state = State()
        state.cpuStep = 1 + cpu.filter(\.raised).count
        state.memoryStep = critical.raised ? t.memoryCriticalStep : warning.raised ? t.memoryWarningStep : 1
        state.step = max(state.cpuStep, state.memoryStep)
        state.border = red.raised ? .red : orange.raised ? .orange : .none
        return state
    }

    /// The "!" badge: while a warning the window would show is in force — the ignored ones left out, so an Ignore
    /// clears it at once. No hold of its own: each warning already holds before it fires.
    public static func badge(_ warnings: [Warning], ignoring: Set<Warning.Subject>) -> Bool {
        warnings.contains { !ignoring.contains($0.subject) }
    }
}
