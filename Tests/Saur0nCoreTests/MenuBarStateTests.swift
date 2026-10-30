// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the menu-bar item's pure presentation (Backlog background-menu-bar-icon; Delphi bdfd08ff) — the compact
// monochrome eye, the approved 80/90/95 badge for the engine's held level, and an unavailable/stale appearance that
// cannot be mistaken for a live normal reading. The mapping takes the held level and the age of the reading it came
// from; it holds no threshold and computes no percentage, so nothing here can become a second alarm.
// Method: recorded states injected directly, as the engine would supply them, one mapping per case.

private func label(_ level: MenuBarState.Level?, age: TimeInterval?) -> String {
    MenuBarState(level: level, readingAge: age).accessibilityLabel
}

@Test func normalDrawsTheEyeWithNoBadge() {
    let state = MenuBarState(level: .normal, readingAge: 1)
    #expect(state.availability == .live)
    #expect(state.symbolName == "eye")
    #expect(state.badgeText == nil)
    #expect(state.accessibilityLabel.contains("normal"))
}

@Test func heldLevelsCarryTheirApprovedNumerals() {
    #expect(MenuBarState(level: .notice, readingAge: 1).badgeText == "80")
    #expect(MenuBarState(level: .triage, readingAge: 1).badgeText == "90")
    #expect(MenuBarState(level: .critical, readingAge: 1).badgeText == "95")
}

@Test func everyHeldLevelIsNamedInWordsAndNumber() {
    let labels = [MenuBarState.Level.notice, .triage, .critical].map { label($0, age: 1) }
    #expect(Set(labels).count == 3)
    #expect(labels[0].contains("notice") && labels[0].contains("80"))
    #expect(labels[1].contains("triage") && labels[1].contains("90"))
    #expect(labels[2].contains("critical") && labels[2].contains("95"))
}

@Test func aDroppedLevelLosesItsBadge() {
    let held = MenuBarState(level: .critical, readingAge: 1)
    #expect(held.badgeText == "95")
    let recovered = MenuBarState(level: .normal, readingAge: 1)
    #expect(recovered.availability == .live)
    #expect(recovered.badgeText == nil)
    #expect(recovered.symbolName == "eye")
    #expect(recovered.accessibilityLabel.contains("normal"))
}

@Test func aNullLevelIsUnavailableAndNeverNormal() {
    let state = MenuBarState(level: nil, readingAge: 1)
    #expect(state.availability == .unavailable)
    #expect(state.symbolName == "eye.slash")
    #expect(state.badgeText == nil)
    #expect(state.accessibilityLabel == "Saur0n resources: unavailable")
    #expect(!state.accessibilityLabel.lowercased().contains("normal"))
}

@Test func noReadingIsUnavailableEvenWithALevel() {
    let state = MenuBarState(level: .notice, readingAge: nil)
    #expect(state.availability == .unavailable)
    #expect(state.symbolName == "eye.slash")
    #expect(state.badgeText == nil)
    #expect(state.accessibilityLabel == "Saur0n resources: unavailable")
}

@Test func anOldReadingIsStaleAndItsLevelIsMarked() {
    let state = MenuBarState(level: .triage, readingAge: 14)
    #expect(state.availability == .stale(seconds: 14))
    #expect(state.symbolName == "eye")
    #expect(state.badgeText == "90?")
    #expect(state.accessibilityLabel.contains("stale"))
    #expect(state.accessibilityLabel.contains("14 second"))
    #expect(!state.accessibilityLabel.contains("live"))
}

@Test func aStaleNormalNeverClaimsNormal() {
    let state = MenuBarState(level: .normal, readingAge: 11)
    #expect(state.availability == .stale(seconds: 11))
    #expect(state.symbolName == "eye.slash")
    #expect(state.badgeText == nil)
    #expect(!state.accessibilityLabel.lowercased().contains("normal"))
    #expect(state.accessibilityLabel.contains("stale"))
}

@Test func staleWithoutALevelIsUnavailable() {
    let state = MenuBarState(level: nil, readingAge: 30)
    #expect(state.availability == .unavailable)
    #expect(state.symbolName == "eye.slash")
    #expect(state.badgeText == nil)
    #expect(state.accessibilityLabel == "Saur0n resources: unavailable")
}

@Test func aFutureReadingIsUnavailable() {
    let state = MenuBarState(level: .critical, readingAge: -3)
    #expect(state.availability == .unavailable)
    #expect(state.symbolName == "eye.slash")
    #expect(state.badgeText == nil)
    #expect(state.accessibilityLabel == "Saur0n resources: unavailable")
}

@Test func tenSecondsIsFreshAndBeyondItIsStale() {
    #expect(MenuBarState(level: .notice, readingAge: 10).availability == .live)
    #expect(MenuBarState(level: .notice, readingAge: 10.5).availability == .stale(seconds: 11))
}

@Test func zeroIsLiveAndJustOverTenIsStale() {
    #expect(MenuBarState(level: .notice, readingAge: 0).availability == .live)
    #expect(MenuBarState(level: .notice, readingAge: 10.0001).availability == .stale(seconds: 11))
}

@Test func negativeZeroIsZeroNotFuture() {
    let state = MenuBarState(level: .notice, readingAge: -0.0)
    #expect(state.availability == .live)
    #expect(state.badgeText == "80")
}

@Test func invalidAgesAreUnavailableWithoutTrapping() {
    for age in [TimeInterval.infinity, -.infinity, .nan, 1e300] {
        let state = MenuBarState(level: .critical, readingAge: age)
        #expect(state.availability == .unavailable)
        #expect(state.symbolName == "eye.slash")
        #expect(state.badgeText == nil)
    }
}

@Test func everyHeldLevelMarksItsStaleBadge() {
    #expect(MenuBarState(level: .notice, readingAge: 11).badgeText == "80?")
    #expect(MenuBarState(level: .triage, readingAge: 11).badgeText == "90?")
    #expect(MenuBarState(level: .critical, readingAge: 11).badgeText == "95?")
}

@Test func aOneSecondAgeReadsAsASecond() {
    let state = MenuBarState(level: .notice, readingAge: 1, staleAfter: 0)
    #expect(state.availability == .stale(seconds: 1))
    #expect(state.accessibilityLabel.contains("1 second old"))
    #expect(!state.accessibilityLabel.contains("1 seconds"))
}

@Test func theContractReservedSpellingsRoundTrip() {
    #expect(MenuBarState.Level(rawValue: "normal") == .normal)
    #expect(MenuBarState.Level(rawValue: "notice") == .notice)
    #expect(MenuBarState.Level(rawValue: "triage") == .triage)
    #expect(MenuBarState.Level(rawValue: "critical") == .critical)
    #expect(MenuBarState.Level(rawValue: "warning") == nil)
    #expect(MenuBarState.Level.allCases.map(\.rawValue) == ["normal", "notice", "triage", "critical"])
}

@Test func theBadgeTextCarriesNoThresholdOfItsOwn() {
    for level in MenuBarState.Level.allCases {
        let state = MenuBarState(level: level, readingAge: 1)
        #expect(state.badgeText == level.badgeText)
    }
    #expect(MenuBarState.Level.normal.badgeText == nil)
    #expect(MenuBarState.Level.notice.badgeText == "80")
    #expect(MenuBarState.Level.triage.badgeText == "90")
    #expect(MenuBarState.Level.critical.badgeText == "95")
}
