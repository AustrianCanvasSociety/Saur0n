// SPDX-License-Identifier: GPL-3.0-or-later
import os

/// The window's Pause and Refresh buttons, as the refresh loop sees them: set from the main actor without waiting,
/// waited on by the loop before each sample (`waitWhilePaused`) and between samples (`sleep`). Task Manager freezes
/// its list while Ctrl is held, htop pauses on Shift+Z, btop has a freeze key; here a paused window takes no samples
/// at all, apart from the one reading a Refresh asks for.
public final class RefreshPause: Sendable {
    private struct State {
        var paused = false
        var waiters: [CheckedContinuation<Bool, Never>] = []
        /// Waits a Refresh lets through while paused: the sample that closes its one reading.
        var passes = 0
        /// The loop's sleep between samples, numbered so a late timer cannot end a later sleep.
        var sleeper: (id: Int, waiter: CheckedContinuation<Void, Never>)?
        var sleeps = 0
        /// A Refresh that came while the loop was sampling: its next sleep returns at once.
        var wakePending = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Lets tests wait until the loop has parked rather than guess how long it takes.
    var waiterCount: Int { state.withLock { $0.waiters.count } }

    /// Pauses or resumes; resuming releases every waiting loop.
    public func setPaused(_ paused: Bool) {
        let released = state.withLock { state in
            state.paused = paused
            state.passes = 0
            guard !paused else { return [CheckedContinuation<Bool, Never>]() }
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in released { waiter.resume(returning: true) }
    }

    /// Returns at once while running (false); while paused, once resumed (true), so the caller knows its
    /// open sample window spans the pause — or at once (false) for the closing sample of a Refresh's reading.
    public func waitWhilePaused() async -> Bool {
        await withCheckedContinuation { waiter in
            let running = state.withLock { state in
                if state.paused, state.passes > 0 {
                    state.passes -= 1
                    return true
                }
                if state.paused { state.waiters.append(waiter) }
                return !state.paused
            }
            if running { waiter.resume(returning: false) }
        }
    }

    /// The loop's wait between samples: `seconds`, or until a Refresh.
    public func sleep(seconds: Double) async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let id: Int? = state.withLock { state in
                if state.wakePending {
                    state.wakePending = false
                    return nil
                }
                state.sleeps += 1
                state.sleeper = (state.sleeps, waiter)
                return state.sleeps
            }
            guard let id else { return waiter.resume() }
            Task { [self] in
                try? await Task.sleep(for: .seconds(seconds))
                wake(id)
            }
        }
    }

    /// The toolbar's Refresh: a reading now. Running, the loop's sleep ends (or its next one, when it is sampling).
    /// Paused, one reading and the window stays paused: a waiting loop is released as after a pause (its sample opens
    /// a new window) and the wait after its sleep lets the closing sample through; a sleeping one is woken into that
    /// closing sample.
    public func refreshNow() {
        let (released, sleeper) = state.withLock { state in
            var released: [CheckedContinuation<Bool, Never>] = []
            if state.paused {
                state.passes = 1
                swap(&released, &state.waiters)
            }
            guard released.isEmpty else { return (released, CheckedContinuation<Void, Never>?.none) }
            guard let sleeper = state.sleeper else {
                state.wakePending = true
                return (released, nil)
            }
            state.sleeper = nil
            return (released, sleeper.waiter)
        }
        for waiter in released { waiter.resume(returning: true) }
        sleeper?.resume()
    }

    /// Ends sleep `id` when its time is up, unless a Refresh ended it already.
    private func wake(_ id: Int) {
        let sleeper = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let sleeper = state.sleeper, sleeper.id == id else { return nil }
            state.sleeper = nil
            return sleeper.waiter
        }
        sleeper?.resume()
    }
}

/// The window's reading policy, separate from sampling and the watcher. A toolbar action invalidates readings
/// already in flight; Refresh shows one new reading without adding an extra graph point or strip tick.
public struct WindowReadingState: Sendable {
    public private(set) var ticket = 0
    private var paused = false
    private var requested = false

    public init() {}

    public mutating func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        requested = false
        ticket += 1
    }

    public mutating func refresh() {
        requested = true
        ticket += 1
    }

    /// nil rejects an old or paused reading; false shows its rows only; true also advances the histories.
    public mutating func accept(_ ticket: Int) -> Bool? {
        guard ticket == self.ticket, !paused || requested else { return nil }
        defer { requested = false }
        return !requested
    }
}

/// Counts applied process readings, not attempts: a failed scan or an opening sample has no new rows to show.
public struct RefreshProgress: Sendable {
    public private(set) var count = 0

    public init() {}

    public mutating func accept<Value>(_ reading: Result<Value?, Error>) throws -> Value? {
        guard let value = try reading.get() else { return nil }
        count += 1
        return value
    }
}

/// Whether anyone can see the window: quiet while the screen is locked or no part of the app is visible (covered,
/// minimised, on another Space). The readings go on while quiet — only the window stops updating — so each
/// reading's graph points are held, the graphs' last minute of them, and handed back when the window can be seen
/// again (Apple's Energy Efficiency Guide, "Notify Your App When Visibility Changes"; research 2026-10-23-overhead).
public struct QuietState<Point: Sendable>: Sendable {
    public enum Event: Sendable {
        case screenLocked, screenUnlocked
        /// `NSApplication.occlusionState` contains `.visible`, or no longer does.
        case visible(Bool)
    }

    private var screenLocked: Bool
    private var visible = true
    private var held: [Point] = []

    /// `screenLocked`: the session's lock at launch. An app launched behind the lock reads not visible and is sent no
    /// occlusion change, nor a lock notification (probe 2026-10-23), so the lock must be read once at the start.
    public init(screenLocked: Bool = false) { self.screenLocked = screenLocked }

    public var quiet: Bool { screenLocked || !visible }

    /// One reading's points while quiet; past the graphs' minute the oldest goes.
    public mutating func hold(_ point: Point) {
        held.append(point)
        if held.count > CPUHistory.capacity { held.removeFirst(held.count - CPUHistory.capacity) }
    }

    /// The state after `event`; when it ends a quiet spell, the points held during it, oldest first, else nil.
    public mutating func handle(_ event: Event) -> [Point]? {
        let wasQuiet = quiet
        switch event {
        case .screenLocked: screenLocked = true
        case .screenUnlocked: screenLocked = false
        case .visible(let shown):
            visible = shown
            // Seen means not behind the lock, so a missed unlock notification cannot hold the window quiet.
            if shown { screenLocked = false }
        }
        guard wasQuiet, !quiet else { return nil }
        defer { held = [] }
        return held
    }
}
