// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os
import Testing
@testable import Saur0nCore

// Goal: the window's Pause — while paused, the refresh loop takes no samples; resumed, it picks up again and
// knows it was held, so its first sample after a pause only opens a new window.
// Method: a loop shaped like MonitorModel's (wait, tick, short sleep) counting its ticks in real time.

/// Ticks of a loop that waits on `pause` before each one; each tick records whether its wait was held.
private final class TickLog: Sendable {
    private let ticks = OSAllocatedUnfairLock(initialState: [Bool]())
    var all: [Bool] { ticks.withLock { $0 } }
    func append(_ held: Bool) { ticks.withLock { $0.append(held) } }
}

private func startLoop(_ pause: RefreshPause, _ log: TickLog) -> Task<Void, Never> {
    Task.detached {
        while !Task.isCancelled {
            log.append(await pause.waitWhilePaused())
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Waits up to 2 s for `condition`.
private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
}

@Test func runningPauseNeverHolds() async {
    let pause = RefreshPause()
    #expect(await pause.waitWhilePaused() == false)
}

@Test func pausedLoopTakesNoTicksUntilResumed() async throws {
    let pause = RefreshPause()
    pause.setPaused(true)
    let log = TickLog()
    let loop = startLoop(pause, log)
    defer { loop.cancel(); pause.setPaused(false) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(log.all.isEmpty)

    pause.setPaused(false)
    try await eventually { log.all.count >= 3 }
    #expect(log.all.first == true)                       // the first tick after a pause knows it was held
    #expect(log.all.dropFirst().allSatisfy { !$0 })

    pause.setPaused(true)
    try await Task.sleep(for: .milliseconds(50))         // a tick already past its wait may still land
    let frozen = log.all.count
    try await Task.sleep(for: .milliseconds(200))
    #expect(log.all.count == frozen)
}

// MARK: - Refresh (the toolbar's Refresh button, ⌘R)

/// MonitorModel's loop: wait, tick, then `pause.sleep` for `seconds`, which Refresh cuts short.
private func startRefreshLoop(_ pause: RefreshPause, _ log: TickLog, seconds: Double) -> Task<Void, Never> {
    Task.detached {
        while !Task.isCancelled {
            log.append(await pause.waitWhilePaused())
            await pause.sleep(seconds: seconds)
        }
    }
}

@Test func refreshEndsTheLoopsSleepAtOnce() async throws {
    let pause = RefreshPause()
    let log = TickLog()
    let loop = startRefreshLoop(pause, log, seconds: 30)
    defer { loop.cancel() }
    try await eventually { log.all.count == 1 }
    try await Task.sleep(for: .milliseconds(50))    // into its 30 s sleep
    pause.refreshNow()
    try await eventually { log.all.count == 2 }
    #expect(log.all == [false, false])
}

@Test func refreshBetweenSleepsEndsTheNextOneAtOnce() async {
    // Pressed while the loop is sampling: its next sleep returns at once, and only that one.
    let pause = RefreshPause()
    pause.refreshNow()
    let start = Date()
    await pause.sleep(seconds: 30)
    #expect(Date().timeIntervalSince(start) < 1)
    await pause.sleep(seconds: 0.2)
    #expect(Date().timeIntervalSince(start) >= 0.2)
}

@Test func refreshWhilePausedLetsOneReadingThroughAndStaysPaused() async throws {
    let pause = RefreshPause()
    pause.setPaused(true)
    let log = TickLog()
    let loop = startRefreshLoop(pause, log, seconds: 0.05)
    defer { loop.cancel(); pause.setPaused(false) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(log.all.isEmpty)
    // One sample to open a window after the pause (held), one to close it a sleep later: the one reading.
    pause.refreshNow()
    try await eventually { log.all.count >= 2 }
    try await Task.sleep(for: .milliseconds(200))
    #expect(log.all == [true, false])
    // Refresh again: one more reading, the loop still paused after it.
    pause.refreshNow()
    try await eventually { log.all.count >= 4 }
    try await Task.sleep(for: .milliseconds(200))
    #expect(log.all == [true, false, true, false])
    pause.setPaused(false)
    try await eventually { log.all.count >= 6 }
    #expect(log.all[4] == true)
}

@Test func resumeReleasesEveryWaiter() async throws {
    let pause = RefreshPause()
    pause.setPaused(true)
    let first = Task { await pause.waitWhilePaused() }
    let second = Task { await pause.waitWhilePaused() }
    try await Task.sleep(for: .milliseconds(50))
    pause.setPaused(false)
    #expect(await first.value == true)
    #expect(await second.value == true)
}

// MARK: Quiet — no window updates while the screen is locked or the app can't be seen

@Test func quietWhileLockedOrHidden() {
    var state = QuietState<Int>()
    #expect(!state.quiet)
    #expect(state.handle(.screenLocked) == nil)
    #expect(state.quiet)
    #expect(state.handle(.visible(false)) == nil)
    // Unlocked behind another Space or a covering window: still nobody sees it.
    #expect(state.handle(.screenUnlocked) == nil)
    #expect(state.quiet)
    #expect(state.handle(.visible(true)) == [])
    #expect(!state.quiet)
}

@Test func launchedBehindTheLockStartsQuiet() {
    // Probe 2026-10-23: an app launched behind the lock reads not visible and gets no occlusion change.
    var state = QuietState<Int>(screenLocked: true)
    #expect(state.quiet)
    state.hold(1)
    #expect(state.handle(.screenUnlocked) == [1])
}

@Test func visibilityAloneMakesItQuiet() {
    // The lock notification may never come: hiding alone is enough.
    var state = QuietState<Int>()
    #expect(state.handle(.visible(false)) == nil)
    #expect(state.quiet)
    state.hold(1)
    #expect(state.handle(.visible(true)) == [1])
}

@Test func seenAgainEndsALockWhoseUnlockNeverCame() {
    // A visible app is not behind the lock: the window must not stay quiet waiting for an unlock name.
    var state = QuietState<Int>()
    _ = state.handle(.screenLocked)
    _ = state.handle(.visible(false))
    state.hold(1)
    #expect(state.handle(.visible(true)) == [1])
    #expect(!state.quiet)
}

@Test func leavingQuietHandsBackTheHeldPointsInOrder() {
    var state = QuietState<Int>()
    _ = state.handle(.screenLocked)
    for point in 1...3 { state.hold(point) }
    #expect(state.handle(.screenUnlocked) == [1, 2, 3])
    // Handed back once: the next quiet spell starts empty.
    _ = state.handle(.screenLocked)
    #expect(state.handle(.screenUnlocked) == [])
}

@Test func quietHoldsOnlyTheGraphsMinute() {
    var state = QuietState<Int>()
    _ = state.handle(.screenLocked)
    for point in 1...150 { state.hold(point) }
    #expect(state.handle(.screenUnlocked) == Array(91...150))
}

@Test func repeatedEventsChangeNothing() {
    var state = QuietState<Int>()
    #expect(state.handle(.visible(true)) == nil)
    #expect(state.handle(.screenUnlocked) == nil)
    _ = state.handle(.screenLocked)
    state.hold(1)
    #expect(state.handle(.screenLocked) == nil)
    #expect(state.handle(.screenUnlocked) == [1])
}
