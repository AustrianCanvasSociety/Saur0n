// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: the window's themes (Backlog window-theme) — Ember & Steel by default, Two-colour and Single-colour for high
// contrast, each a dark and a light colour per series and per chrome role with the values the theme page settled
// (amulet saur0n-theme), dash patterns on the high-contrast ones, and which theme shows when the Mac's Increase
// contrast is on. Method: values against the page's table, choices in sequence.

@Test func emberAndSteelIsTheDefaultAndCarriesThePagesColours() {
    #expect(Theme.ID.allCases.map(\.rawValue) == ["ember-steel", "two-colour"])
    #expect(Theme.ID(saved: nil) == .emberSteel && Theme.ID(saved: "bogus") == .emberSteel)
    // Single-colour left the choice (the user, 2026-10-21): a copy that saved it opens in Ember & Steel.
    #expect(Theme.ID(saved: "single-colour") == .emberSteel)
    #expect(Theme.ID(saved: "two-colour") == .twoColour)
    let steel = Theme.named(.emberSteel)
    #expect(steel.name == "Ember & Steel")
    // The page's hues, lifted in dark and deepened in light to 3:1 (2026-10-21: "ember and steel needs more contrast").
    #expect(steel.series[.superCores] == Theme.Pair(dark: "#ffa95c", light: "#ad6105"))
    #expect(steel.series[.efficiency] == Theme.Pair(dark: "#7ea9e9", light: "#37649e"))
    #expect(steel.series[.networkIn] == Theme.Pair(dark: "#32baaa", light: "#038182"))
    #expect(steel.series[.memory] == Theme.Pair(dark: "#f88a4d", light: "#8b3c02"))
    #expect(steel.chrome[.accent] == Theme.Pair(dark: "#ff8564", light: "#d63c02"))
    #expect(steel.chrome[.paused] == Theme.Pair(dark: "#ff992d", light: "#944003"))
    // Ember & Steel draws every line solid.
    #expect(Theme.Series.allCases.allSatisfy { steel.dash($0).isEmpty })
}

// The surfaces the lines and the open cell's border are drawn on, read from the pixels of the demo copy's screenshots
// (2026-10-21, Pro): the window, a closed cell, the open cell, and one a few steps past the open cell for what the
// desktop behind the window adds.
let darkSurfaces = ["#424140", "#4b4948", "#515150", "#575756"]
let lightSurfaces = ["#f4f4f3", "#eeeeed", "#e9e8e8", "#e3e2e2"]

@Test func everyLineAndTheBorderReachThreeToOneOnWhatTheySitOn() {
    for id in Theme.ID.allCases {
        let theme = Theme.named(id)
        let colours = Theme.Series.allCases.map { ("\($0)", theme.series[$0]) } + [("accent", theme.chrome[.accent])]
        for (name, pair) in colours {
            guard let pair else { continue }
            for surface in darkSurfaces { #expect(Theme.contrast(pair.dark, surface) >= 3, "\(id) \(name) dark on \(surface)") }
            for surface in lightSurfaces { #expect(Theme.contrast(pair.light, surface) >= 3, "\(id) \(name) light on \(surface)") }
        }
    }
}

@Test func thePausedBadgeAndGreyedRowsReadAtFourAndAHalfToOne() {
    // Measured the same way: the toolbar behind the badge, and the table's two row shades.
    for id in Theme.ID.allCases {
        let theme = Theme.named(id)
        let paused = theme.chrome[.paused]!
        #expect(Theme.contrast(paused.dark, "#424140") >= 4.5, "\(id) paused dark")
        #expect(Theme.contrast(paused.light, "#f0efef") >= 4.5, "\(id) paused light")
        for row in ["#383635", "#444241"] { #expect(Theme.contrast(theme.gone.dark, row) >= 4.5, "\(id) gone dark on \(row)") }
        for row in ["#ffffff", "#f6f7f7"] { #expect(Theme.contrast(theme.gone.light, row) >= 4.5, "\(id) gone light on \(row)") }
    }
}

@Test func shadedCellsKeepTheirTextAndTheWarningBadgeReads() {
    // The table's two row shades in each appearance, as measured above; the window's text as white or black at 85%
    // over the shaded cell (the system's label colour is translucent).
    let rows = (dark: ["#383635", "#444241"], light: ["#ffffff", "#f6f7f7"])
    for id in Theme.ID.allCases {
        let theme = Theme.named(id)
        for (step, alpha) in Theme.busyOpacities.enumerated() {
            for row in rows.dark {
                let cell = Theme.blend(theme.busy.dark, over: row, alpha: alpha)
                let text = Theme.blend("#ffffff", over: cell, alpha: 0.85)
                #expect(Theme.contrast(text, cell) >= 4.5, "\(id) step \(step + 1) dark on \(row)")
            }
            for row in rows.light {
                let cell = Theme.blend(theme.busy.light, over: row, alpha: alpha)
                let text = Theme.blend("#000000", over: cell, alpha: 0.85)
                #expect(Theme.contrast(text, cell) >= 4.5, "\(id) step \(step + 1) light on \(row)")
            }
        }
        // The warned row's badge glyph is the accent: a graphic, 3:1 on both row shades (WCAG 2.2 § 1.4.11).
        let accent = theme.chrome[.accent]!
        for row in rows.dark { #expect(Theme.contrast(accent.dark, row) >= 3, "\(id) badge dark on \(row)") }
        for row in rows.light { #expect(Theme.contrast(accent.light, row) >= 3, "\(id) badge light on \(row)") }
    }
    #expect(Theme.blend("#ffffff", over: "#000000", alpha: 0.5) == "#808080")
}

@Test func lineColoursSharingAGraphStayApart() {
    // Super and Performance share the CPU cell's sparkline; in Ember & Steel Network out and Disk write share the
    // Disk & Network one in the same two colours. At the 3:1 floor in dark both turn light orange: Super stays lighter.
    let steel = Theme.named(.emberSteel)
    for mode in [\Theme.Pair.dark, \Theme.Pair.light] {
        let hot = steel.series[.superCores]![keyPath: mode], perf = steel.series[.performance]![keyPath: mode]
        #expect(Theme.contrast(hot, perf) >= 1.2, "\(hot) \(perf)")
    }
    // Two-colour's core types are its orange at three strengths: Super the strongest, Efficiency the faintest.
    let two = Theme.named(.twoColour)
    let strengths = [Theme.Series.superCores, .performance, .efficiency].map { two.series[$0]! }
    #expect(strengths.map { Theme.RGB(hex: $0.dark).luminance } == strengths.map { Theme.RGB(hex: $0.dark).luminance }.sorted(by: >))
    #expect(strengths.map { Theme.RGB(hex: $0.light).luminance } == strengths.map { Theme.RGB(hex: $0.light).luminance }.sorted())
}

@Test func everyThemeHasEverySeriesAndChromeRoleInBothModes() {
    for id in Theme.ID.allCases {
        let theme = Theme.named(id)
        for series in Theme.Series.allCases { #expect(theme.series[series] != nil, "\(id) \(series)") }
        for role in Theme.Chrome.allCases { #expect(theme.chrome[role] != nil, "\(id) \(role)") }
    }
}

@Test func twoColourDrawsMemoryOrangeAndTellsLinesApartByDash() {
    let two = Theme.named(.twoColour)
    // The user's pick (2026-10-21: "orange for memory"), though the page draws it blue: Disk write's orange.
    #expect(two.series[.memory] == two.series[.diskWrite])
    #expect(two.series[.memory] == Theme.Pair(dark: "#ff9215", light: "#834600"))
    #expect(two.series[.diskRead] == Theme.Pair(dark: "#6eb6ff", light: "#005fa7"))
    // Disk solid, Network dashed; Super solid, Performance dashed, Efficiency dotted; Memory solid.
    #expect(two.dash(.diskRead).isEmpty && two.dash(.diskWrite).isEmpty && two.dash(.memory).isEmpty)
    #expect(two.dash(.networkIn) == [6, 3] && two.dash(.networkOut) == [6, 3])
    #expect(two.dash(.superCores).isEmpty && two.dash(.performance) == [6, 3] && two.dash(.efficiency) == [2, 3])
}

@Test func appearanceIsTheMacsUnlessSettingsPicksLightOrDark() {
    #expect(Theme.Appearance.allCases.map(\.rawValue) == ["system", "light", "dark"])
    #expect(Theme.Appearance.allCases.map(\.name) == ["System", "Light", "Dark"])
    #expect(Theme.Appearance(saved: nil) == .system && Theme.Appearance(saved: "bogus") == .system)
    #expect(Theme.Appearance(saved: "dark") == .dark && Theme.Appearance(saved: "light") == .light)
}

@Test func coreTypesTakeTheirSeriesByTheNameTheMacReports() {
    #expect(Theme.Series.coreType("Super") == .superCores)
    #expect(Theme.Series.coreType("Performance") == .performance)
    #expect(Theme.Series.coreType("Efficiency") == .efficiency)
    // A name no Mac has reported yet still gets a line: the coolest one.
    #expect(Theme.Series.coreType("Ultra") == .efficiency)
}

@Test func increaseContrastShowsTwoColourWhileTheBoxIsTicked() {
    #expect(Theme.shown(chosen: .emberSteel, followContrast: true, increaseContrast: false) == .emberSteel)
    #expect(Theme.shown(chosen: .emberSteel, followContrast: true, increaseContrast: true) == .twoColour)
    #expect(Theme.shown(chosen: .twoColour, followContrast: true, increaseContrast: true) == .twoColour)
    #expect(Theme.shown(chosen: .emberSteel, followContrast: false, increaseContrast: true) == .emberSteel)
}

@Test func hexColoursReadAsComponents() {
    let rgb = Theme.RGB(hex: "#f24c18")
    #expect(rgb == Theme.RGB(red: 0xf2 / 255.0, green: 0x4c / 255.0, blue: 0x18 / 255.0))
    #expect(Theme.RGB(hex: "nonsense") == Theme.RGB(red: 0, green: 0, blue: 0))
}

@Test func contrastIsTheWCAGRatio() {
    #expect(Theme.contrast("#000000", "#ffffff") == 21)
    #expect(Theme.contrast("#ffffff", "#000000") == 21)
    #expect(Theme.contrast("#777777", "#777777") == 1)
    // #767676 is the familiar lightest grey at 4.5:1 on white.
    #expect(abs(Theme.contrast("#767676", "#ffffff") - 4.54) < 0.01)
}
