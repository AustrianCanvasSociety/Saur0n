// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The menu-bar item's presentation (Backlog background-menu-bar-icon; Delphi bdfd08ff): the compact monochrome eye,
/// the approved 80/90/95 badge for the engine's held level, and an appearance that tells an unavailable or stale
/// reading from a live one.
///
/// This is presentation only. The level arrives from the shared resource-level engine already held and calibrated;
/// nothing here compares a percentage, holds a level, or derives one from the CPU or memory columns or the Dock
/// ramp. The badge numerals name the approved levels, not a measured figure.
public struct MenuBarState: Equatable, Sendable {
    /// The engine's held level in the approved contract's reserved spelling, plus what the item draws for it.
    public enum Level: String, Sendable, Equatable, CaseIterable {
        case normal, notice, triage, critical

        /// The numeral beside the eye: none for normal, the approved level badge otherwise (Delphi bdfd08ff).
        public var badgeText: String? {
            switch self {
            case .normal: nil
            case .notice: "80"
            case .triage: "90"
            case .critical: "95"
            }
        }

        /// The level's name and numeral in words, for assistive technology and the tooltip — never colour alone.
        public var described: String {
            switch self {
            case .normal: "normal"
            case .notice: "notice level, 80 percent"
            case .triage: "triage level, 90 percent"
            case .critical: "critical level, 95 percent"
            }
        }
    }

    /// How far the shown level can be trusted: current, retained but older than the display cutoff, or absent.
    public enum Availability: Equatable, Sendable {
        case live
        case stale(seconds: Int)
        case unavailable
    }

    /// The approved display-freshness cutoff (live-status contract v1, Delphi `afe5b96c`): an age above 10 seconds
    /// is shown as stale. It is a presentation cutoff, not a warning hold or an alert threshold.
    public static let staleAfter: TimeInterval = 10

    public let availability: Availability
    /// The held level last supplied by the engine; nil when the engine has none (uncalibrated) or no reading exists.
    public let level: Level?

    /// - Parameters:
    ///   - level: the shared engine's held level; nil is unavailable, never normal.
    ///   - readingAge: seconds since the reading the level came from, or nil when no reading has completed. The
    ///     caller computes it from the model's stored sample time; nothing here advances or publishes that time.
    ///   - staleAfter: the display cutoff, overridable for tests of the boundary.
    public init(level: Level?, readingAge: TimeInterval?, staleAfter: TimeInterval = MenuBarState.staleAfter) {
        // No completed reading, no calibrated level, a future-dated, non-finite or unrepresentably large age:
        // unavailable, never normal. The last two conditions also keep the whole-seconds conversion below from
        // trapping on infinite or out-of-Int-range values.
        guard let readingAge, let level, readingAge.isFinite, readingAge >= 0, readingAge < Double(Int.max) else {
            availability = .unavailable
            self.level = nil
            return
        }
        if readingAge > staleAfter {
            availability = .stale(seconds: Int(readingAge.rounded(.up)))
            self.level = level
        } else {
            availability = .live
            self.level = level
        }
    }

    /// The monochrome glyph's SF Symbol name: the eye while a level is usable, the slashed eye when nothing usable
    /// can be shown (no reading, no calibrated level, or a stale reading whose last level was normal).
    public var symbolName: String {
        if availability == .unavailable { return "eye.slash" }
        if case .stale = availability, level == nil || level == .normal { return "eye.slash" }
        return "eye"
    }

    /// What sits beside the eye: the level numeral, a question mark added while stale, or nothing.
    public var badgeText: String? {
        switch availability {
        case .unavailable: nil
        case .live: level?.badgeText
        case .stale: level?.badgeText.map { "\($0)?" }
        }
    }

    /// What assistive technology reads: the level in words and numeral, or its absence. A stale reading says so with
    /// its sample age and never claims a live normal state.
    public var accessibilityLabel: String {
        switch availability {
        case .unavailable:
            return "Saur0n resources: unavailable"
        case .live:
            guard let level else { return "Saur0n resources: unavailable" }
            return "Saur0n resources: \(level.described)"
        case .stale(let seconds):
            let age = "\(seconds) second\(seconds == 1 ? "" : "s") old"
            guard let level, level != .normal else { return "Saur0n resources: stale, last reading \(age)" }
            return "Saur0n resources: \(level.described), stale, last reading \(age)"
        }
    }
}
