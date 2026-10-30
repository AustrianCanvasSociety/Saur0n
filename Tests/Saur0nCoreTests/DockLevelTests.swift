// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the Dock icon's level (Phase 6 Step 9) — the tile's step from the machine's CPU (bars at 50, 65, 80 and 95%)
// and its memory pressure (warning step 3, critical step 5), the higher winning; the border at 80% (orange) and 90%
// (red); each held 10 s before it rises and cleared after 10 s below 7/8 of its bar, as the warnings are; the "!"
// badge while a warning the window would show is in force. Method: one reading a second, built in code.

/// Feeds `seconds` one-second readings at `cpu` and `pressure`, starting after `from`; returns the last state and the
/// time of the last reading.
@discardableResult
private func run(_ level: inout DockLevel, from: Double = 0, seconds: Int, cpu: Double,
                 pressure: MemoryPressure? = .normal) -> (state: DockLevel.State, end: Double) {
    var state = DockLevel.State()
    var end = from
    for _ in 0..<seconds {
        end += 1
        state = level.next(end: end, seconds: 1, cpuPercent: cpu, pressure: pressure)
    }
    return (state, end)
}

private func held(cpu: Double, pressure: MemoryPressure? = .normal) -> DockLevel.State {
    var level = DockLevel()
    return run(&level, seconds: 10, cpu: cpu, pressure: pressure).state
}

@Test func restIsStepOne() {
    let state = DockLevel.State()
    #expect(state.step == 1 && state.cpuStep == 1 && state.memoryStep == 1 && state.border == .none)
}

@Test func cpuStepsAtTheirBars() {
    #expect(held(cpu: 49).step == 1)
    #expect(held(cpu: 50).step == 2)
    #expect(held(cpu: 64.9).step == 2)
    #expect(held(cpu: 65).step == 3)
    #expect(held(cpu: 80).step == 4)
    #expect(held(cpu: 94).step == 4)
    #expect(held(cpu: 95).step == 5)
    #expect(held(cpu: 95).cpuStep == 5)
}

@Test func memoryPressureToStep() {
    #expect(held(cpu: 5, pressure: .normal).step == 1)
    #expect(held(cpu: 5, pressure: .warning).step == 3)
    #expect(held(cpu: 5, pressure: .warning).memoryStep == 3)
    #expect(held(cpu: 5, pressure: .critical).step == 5)
    #expect(held(cpu: 5, pressure: .critical).memoryStep == 5)
    #expect(held(cpu: 5, pressure: nil).step == 1)
}

@Test func theHigherOfCPUAndMemoryWins() {
    let a = held(cpu: 55, pressure: .warning)
    #expect(a.cpuStep == 2 && a.memoryStep == 3 && a.step == 3)
    let b = held(cpu: 85, pressure: .warning)
    #expect(b.cpuStep == 4 && b.memoryStep == 3 && b.step == 4)
    #expect(held(cpu: 55, pressure: .critical).step == 5)
}

@Test func borderAtEightyAndNinety() {
    #expect(held(cpu: 79).border == .none)
    #expect(held(cpu: 80).border == .orange)
    #expect(held(cpu: 89).border == .orange)
    #expect(held(cpu: 90).border == .red)
    // Memory alone draws no border.
    #expect(held(cpu: 5, pressure: .critical).border == .none)
}

@Test func aStepHoldsBeforeItRises() {
    var level = DockLevel()
    let nine = run(&level, seconds: 9, cpu: 70)
    #expect(nine.state.step == 1)
    let tenth = run(&level, from: nine.end, seconds: 1, cpu: 70)
    #expect(tenth.state.step == 3)

    // A dip under the bar inside the 10 s restarts the run.
    var dipped = DockLevel()
    var t = run(&dipped, seconds: 8, cpu: 70).end
    t = run(&dipped, from: t, seconds: 1, cpu: 40).end
    let after = run(&dipped, from: t, seconds: 9, cpu: 70)
    #expect(after.state.step == 1)
    #expect(run(&dipped, from: after.end, seconds: 1, cpu: 70).state.step == 3)
}

@Test func aStepClearsOnlyBelowItsLowerBar() {
    var level = DockLevel()
    var t = run(&level, seconds: 10, cpu: 55).end
    // 45% is under the 50% bar but over 7/8 of it (43.75%): the step stays.
    let above = run(&level, from: t, seconds: 30, cpu: 45)
    #expect(above.state.step == 2)
    t = above.end
    let nine = run(&level, from: t, seconds: 9, cpu: 43)
    #expect(nine.state.step == 2)
    #expect(run(&level, from: nine.end, seconds: 1, cpu: 43).state.step == 1)
}

@Test func theBorderClearsOnlyBelowItsLowerBar() {
    var level = DockLevel()
    var t = run(&level, seconds: 10, cpu: 82).end
    let stays = run(&level, from: t, seconds: 30, cpu: 71)
    #expect(stays.state.border == .orange)
    t = stays.end
    let nine = run(&level, from: t, seconds: 9, cpu: 69)
    #expect(nine.state.border == .orange)
    #expect(run(&level, from: nine.end, seconds: 1, cpu: 69).state.border == .none)
}

@Test func fallingFromRedPassesThroughOrange() {
    var level = DockLevel()
    var t = run(&level, seconds: 10, cpu: 92).end
    // 85% is under the 90% bar but over 7/8 of it (78.75%): red stays.
    let stays = run(&level, from: t, seconds: 15, cpu: 85)
    #expect(stays.state.border == .red)
    t = stays.end
    // 75%: under 78.75 for 10 s clears red; over 70 keeps orange.
    let orange = run(&level, from: t, seconds: 10, cpu: 75)
    #expect(orange.state.border == .orange)
    t = orange.end
    let none = run(&level, from: t, seconds: 10, cpu: 60)
    #expect(none.state.border == .none)
}

@Test func aJumpToFullLoadShowsAfterTenSeconds() {
    var level = DockLevel()
    let nine = run(&level, seconds: 9, cpu: 100)
    #expect(nine.state.step == 1 && nine.state.border == .none)
    let tenth = run(&level, from: nine.end, seconds: 1, cpu: 100)
    #expect(tenth.state.step == 5 && tenth.state.border == .red)
}

@Test func aGapRestartsEveryRun() {
    var level = DockLevel()
    let first = run(&level, seconds: 6, cpu: 70)
    // A missed read: the next window starts 3 s after the last ended.
    let second = run(&level, from: first.end + 3, seconds: 6, cpu: 70)
    #expect(second.state.step == 1)
}

@Test func memoryClearsAfterTenSecondsBackToNormal() {
    var level = DockLevel()
    var t = run(&level, seconds: 10, cpu: 5, pressure: .warning).end
    let nine = run(&level, from: t, seconds: 9, cpu: 5, pressure: .normal)
    #expect(nine.state.step == 3)
    t = nine.end
    #expect(run(&level, from: t, seconds: 1, cpu: 5, pressure: .normal).state.step == 1)
}

@Test func memoryHoldsBeforeItRises() {
    var level = DockLevel()
    let nine = run(&level, seconds: 9, cpu: 5, pressure: .critical)
    #expect(nine.state.step == 1)
    #expect(run(&level, from: nine.end, seconds: 1, cpu: 5, pressure: .critical).state.step == 5)
}

@Test func pressureLevelsFromTheKernel() {
    #expect(MemoryPressure(level: 1) == .normal)
    #expect(MemoryPressure(level: 2) == .warning)
    #expect(MemoryPressure(level: 4) == .critical)
    #expect(MemoryPressure(level: 0) == nil)
    #expect(MemoryPressure(level: 3) == nil)
    #expect(MemoryPressure(level: 7) == nil)
}

@Test func sameStepAndBorderCompareEqual() {
    var level = DockLevel()
    let a = run(&level, seconds: 10, cpu: 70)
    let b = run(&level, from: a.end, seconds: 1, cpu: 72)
    #expect(a.state == b.state)
    let c = run(&level, from: b.end, seconds: 10, cpu: 82)
    #expect(c.state != b.state)
}

@Test func badgeOnlyWhileAWarningIsInForce() {
    let warning = Warning(subject: .command("run.sh"), name: "run.sh × 30", since: 0, cpuPercent: 33,
                          conditions: [.copies(count: 30, growth: 30, percent: 33)])
    #expect(!DockLevel.badge([], ignoring: []))
    #expect(DockLevel.badge([warning], ignoring: []))
    #expect(!DockLevel.badge([warning], ignoring: [.command("run.sh")]))
    #expect(DockLevel.badge([warning], ignoring: [.command("other.sh")]))
}
