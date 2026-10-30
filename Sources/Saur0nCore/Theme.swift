// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The window's colours (Backlog window-theme): one theme a dark and a light colour per graph series and per chrome
/// role, with a dash pattern on the series the high-contrast theme tells apart by line style. The hues are the theme
/// page's (amulet `saur0n-theme`, its theme table: `steel`, `two`), kept here as hex; the app turns them into SwiftUI
/// colours that follow the window's appearance. Figures are drawn in the window's text colour, so the series colours
/// are line colours: each at least 3:1 against the surfaces it is drawn on (the user, 2026-10-21: "ember and steel
/// needs more contrast").
public struct Theme: Equatable, Sendable {
    public enum ID: String, CaseIterable, Sendable {
        case emberSteel = "ember-steel", twoColour = "two-colour"

        /// A saved choice; anything unknown, or nothing, is Ember & Steel — Single-colour's `single-colour` too, since
        /// it left the choice (2026-10-21).
        public init(saved: String?) { self = saved.flatMap(ID.init(rawValue:)) ?? .emberSteel }
    }

    /// Light or dark: the Mac's (System, the default) or the one picked in Settings.
    public enum Appearance: String, CaseIterable, Sendable {
        case system, light, dark

        public var name: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        /// A saved choice; anything unknown, or nothing, is System.
        public init(saved: String?) { self = saved.flatMap(Appearance.init(rawValue:)) ?? .system }
    }

    /// The graph lines: the three core types, Disk read and write, Network in and out, Memory.
    public enum Series: CaseIterable, Sendable {
        case superCores, performance, efficiency, diskRead, diskWrite, networkIn, networkOut, memory

        /// A core type by the name the Mac reports (`hw.perflevelN.name`); a name not seen yet takes Efficiency's line.
        public static func coreType(_ name: String) -> Series {
            switch name {
            case "Super": .superCores
            case "Performance": .performance
            default: .efficiency
            }
        }
    }

    /// Buttons, selection and the open cell (`accent`), text on them (`onAccent`), the Paused badge (`paused`).
    public enum Chrome: CaseIterable, Sendable {
        case accent, onAccent, paused
    }

    /// One colour per appearance, as `#rrggbb`.
    public struct Pair: Equatable, Sendable {
        public let dark: String
        public let light: String

        public init(dark: String, light: String) {
            self.dark = dark
            self.light = light
        }
    }

    public struct RGB: Equatable, Sendable {
        public let red: Double, green: Double, blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// `#rrggbb`; anything else reads black.
        public init(hex: String) {
            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
                self.init(red: 0, green: 0, blue: 0)
                return
            }
            self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                      blue: Double(value & 0xff) / 255)
        }

        /// WCAG 2's relative luminance.
        public var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    /// WCAG 2's contrast ratio of two `#rrggbb` colours, 1…21: text wants 4.5, lines and borders 3.
    public static func contrast(_ a: String, _ b: String) -> Double {
        let la = RGB(hex: a).luminance, lb = RGB(hex: b).luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `top` drawn at `alpha` over `bottom`, as `#rrggbb`: what a shaded cell or a translucent text colour shows.
    public static func blend(_ top: String, over bottom: String, alpha: Double) -> String {
        let t = RGB(hex: top), b = RGB(hex: bottom)
        func mix(_ x: Double, _ y: Double) -> Int { Int(((x * alpha + y * (1 - alpha)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", mix(t.red, b.red), mix(t.green, b.green), mix(t.blue, b.blue))
    }

    /// The busy cells' shading (Phase 6 Step 6): `busy` behind the figure at one opacity per step, 1–4
    /// (`ProcessTable.Line.shade`); each step keeps the window's text at 4.5:1 over both row stripes.
    public static let busyOpacities = [0.12, 0.20, 0.28, 0.36]

    public let id: ID
    public let name: String
    public let series: [Series: Pair]
    public let chrome: [Chrome: Pair]
    /// The greyed (ended) row's text: dimmer than the window's text, 4.5:1 on both row shades (the system's tertiary
    /// label colour read 2.5:1 in dark and 1.7:1 in light).
    public let gone: Pair
    /// The busy cells' shading colour, drawn at `busyOpacities`: the theme's hot colour.
    public let busy: Pair
    private let dashes: [Series: [Double]]

    public static func == (a: Theme, b: Theme) -> Bool { a.id == b.id }

    /// The series' dash pattern for `StrokeStyle(dash:)`; empty is a solid line.
    public func dash(_ series: Series) -> [Double] { dashes[series] ?? [] }

    /// What the high-contrast theme draws: Network dashed, Performance dashed, Efficiency dotted.
    static let dashed = [6.0, 3], dotted = [2.0, 3]
    static let lineStyles: [Series: [Double]] = [.performance: dashed, .efficiency: dotted, .networkIn: dashed,
                                                  .networkOut: dashed]

    public static func named(_ id: ID) -> Theme {
        switch id {
        case .emberSteel: emberSteel
        case .twoColour: twoColour
        }
    }

    /// The theme the window shows: Two-colour while the Mac's Increase contrast is on and the Settings box asks for
    /// it (on by default), else the user's choice.
    public static func shown(chosen: ID, followContrast: Bool, increaseContrast: Bool) -> ID {
        followContrast && increaseContrast ? .twoColour : chosen
    }

    static let gone = Pair(dark: "#b0b0b0", light: "#595959")

    /// The chosen theme (2026-10-21, "lets use that"): flames on the hot series, steel blue on Efficiency and Disk read,
    /// teal on Network in, the flame red-orange on the chrome. The page's hues with OKLCH lightness moved — up in dark,
    /// down in light — only until a line reaches 3:1 on the surfaces it is drawn on, read from the window's pixels;
    /// Super (and Network out) a step past that in dark, which keeps it apart from Performance (and Disk write) on the
    /// shared sparklines.
    static let emberSteel = Theme(
        id: .emberSteel, name: "Ember & Steel",
        series: [.superCores: Pair(dark: "#ffa95c", light: "#ad6105"), .performance: Pair(dark: "#ff8465", light: "#9c2500"),
                 .efficiency: Pair(dark: "#7ea9e9", light: "#37649e"), .diskRead: Pair(dark: "#7ea9e9", light: "#37649e"),
                 .diskWrite: Pair(dark: "#ff8465", light: "#9c2500"), .networkIn: Pair(dark: "#32baaa", light: "#038182"),
                 .networkOut: Pair(dark: "#ffa95c", light: "#ad6105"), .memory: Pair(dark: "#f88a4d", light: "#8b3c02")],
        chrome: [.accent: Pair(dark: "#ff8564", light: "#d63c02"), .onAccent: Pair(dark: "#ffffff", light: "#ffffff"),
                 .paused: Pair(dark: "#ff992d", light: "#944003")],
        gone: gone, busy: Pair(dark: "#ff8465", light: "#9c2500"), dashes: [:])

    /// Blue for what comes in, orange for what goes out; Memory orange (the user's pick, 2026-10-21, though the page
    /// draws it blue); the core types the orange at three strengths — lighter for stronger in dark, darker in light,
    /// the faintest at 3:1.
    static let twoColour = Theme(
        id: .twoColour, name: "Two-colour",
        series: [.superCores: Pair(dark: "#fec698", light: "#834600"), .performance: Pair(dark: "#ffa95f", light: "#a75c00"),
                 .efficiency: Pair(dark: "#e7954d", light: "#c16c01"), .diskRead: Pair(dark: "#6eb6ff", light: "#005fa7"),
                 .diskWrite: Pair(dark: "#ff9215", light: "#834600"), .networkIn: Pair(dark: "#6eb6ff", light: "#005fa7"),
                 .networkOut: Pair(dark: "#ff9215", light: "#834600"), .memory: Pair(dark: "#ff9215", light: "#834600")],
        chrome: [.accent: Pair(dark: "#6eb6ff", light: "#005fa7"), .onAccent: Pair(dark: "#000000", light: "#ffffff"),
                 .paused: Pair(dark: "#ff9215", light: "#834600")],
        gone: gone, busy: Pair(dark: "#ff9215", light: "#834600"), dashes: lineStyles)
}
