// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import Saur0nCore
import SwiftUI

/// The window's theme (Backlog window-theme): the user's choice, the appearance and the high-contrast box from
/// Settings, kept in the app's defaults, and the Mac's Increase contrast, read at launch and again whenever an
/// accessibility display option changes. No SwiftUI macros build here (CLAUDE.md § Toolchain), so the state lives in
/// this `@Observable` model.
@MainActor @Observable
final class ThemeModel {
    static let themeKey = "theme", followContrastKey = "highContrastFollowsMac", appearanceKey = "appearance"

    var chosen: Theme.ID {
        didSet { UserDefaults.standard.set(chosen.rawValue, forKey: Self.themeKey) }
    }
    /// System, Light or Dark: the whole app's, windows and Settings alike, as Mail and Notes set it.
    var appearance: Theme.Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
            Self.apply(appearance)
        }
    }
    /// "Use high contrast when the Mac's Increase contrast is on": on by default.
    var followContrast: Bool {
        didSet { UserDefaults.standard.set(followContrast, forKey: Self.followContrastKey) }
    }
    private(set) var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    /// The warnings the user ignored, by subject key (`Warning.Subject.key`), kept with the other settings and undone
    /// from Settings (Phase 6 Step 6).
    static let ignoredWarningsKey = "ignoredWarnings"
    var ignoredWarnings: [String] {
        didSet { UserDefaults.standard.set(ignoredWarnings, forKey: Self.ignoredWarningsKey) }
    }

    /// What the window draws.
    var theme: Theme {
        Theme.named(Theme.shown(chosen: chosen, followContrast: followContrast, increaseContrast: increaseContrast))
    }

    init() {
        chosen = Theme.ID(saved: UserDefaults.standard.string(forKey: Self.themeKey))
        followContrast = UserDefaults.standard.object(forKey: Self.followContrastKey) as? Bool ?? true
        appearance = Theme.Appearance(saved: UserDefaults.standard.string(forKey: Self.appearanceKey))
        ignoredWarnings = UserDefaults.standard.stringArray(forKey: Self.ignoredWarningsKey) ?? []
        Self.apply(appearance)
        // The shared workspace posts it when any accessibility display option changes (no userInfo); the model lives
        // as long as the app, so the observer is never removed.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            }
        }
    }

    func color(_ series: Theme.Series) -> Color { Self.color(theme.series[series]) }
    func color(_ role: Theme.Chrome) -> Color { Self.color(theme.chrome[role]) }
    func dash(_ series: Theme.Series) -> [CGFloat] { theme.dash(series).map { CGFloat($0) } }
    /// A sparkline's values drawn as the series.
    func line(_ series: Theme.Series, _ values: [Double]) -> SparkLine {
        SparkLine(values: values, color: color(series), dash: dash(series))
    }
    /// A short sample of the series' line, to sit before its figure where one graph draws several lines.
    func key(_ series: Theme.Series) -> LineKey { LineKey(color: color(series), dash: dash(series)) }
    /// A greyed (ended) row's text.
    var gone: Color { Self.color(theme.gone) }
    /// A busy cell's shading at `step` 1–4 (`ProcessTable.Line.shade`); clear at 0.
    func busy(_ step: Int) -> Color {
        guard step > 0 else { return .clear }
        return Self.color(theme.busy).opacity(Theme.busyOpacities[min(step, Theme.busyOpacities.count) - 1])
    }

    /// nil follows the Mac.
    static func apply(_ appearance: Theme.Appearance) {
        NSApplication.shared.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// A pair as one colour that follows the window's appearance.
    static func color(_ pair: Theme.Pair?) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in nsColor(isDark(appearance) ? pair?.dark : pair?.light) })
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }

    static func nsColor(_ hex: String?) -> NSColor {
        let rgb = Theme.RGB(hex: hex ?? "")
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

/// Saur0n ▸ Settings… (⌘,): one General pane, as the theme page draws it, with the app icon as its header, the theme
/// (each with its colours beside its name), the appearance — System, Light or Dark — and the high-contrast box.
/// Identifiers `settings-theme`, `settings-appearance` and `settings-high-contrast`.
struct SettingsView: View {
    @Bindable var theme: ThemeModel

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460)
        .tint(theme.color(.accent))    // as the theme page draws Settings: its controls in the theme's accent
    }

    var general: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saur0n").font(.title2.bold())
                    // In the text colour, as the notes below: the system's secondary grey read 3:1 in light.
                    Text("Process monitor · the whole machine as 100%")
                }
            }
            Picker("Theme:", selection: $theme.chosen) {
                ForEach(Theme.ID.allCases, id: \.self) { id in
                    HStack(spacing: 8) {
                        Swatch(theme: Theme.named(id))
                        Text(Theme.named(id).name)
                    }
                    .tag(id)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings-theme")
            Text("Graph lines, buttons, the open graph's border and the Paused badge follow the theme; figures stay in "
                 + "the text colour.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Appearance:", selection: $theme.appearance) {
                ForEach(Theme.Appearance.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .accessibilityIdentifier("settings-appearance")
            Toggle("Use high contrast when the Mac's Increase contrast is on", isOn: $theme.followContrast)
                .accessibilityIdentifier("settings-high-contrast")
            Text("Shows Two-colour while System Settings ▸ Accessibility ▸ Display ▸ Increase contrast is on, and the "
                 + "theme above again when it is off.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            // Phase 6 Step 6: what the warning bar's Ignore keeps, each undone here.
            Text("Ignored warnings:")
            if theme.ignoredWarnings.isEmpty {
                Text("None").foregroundStyle(.secondary).accessibilityIdentifier("settings-ignored-none")
            } else {
                ForEach(Array(theme.ignoredWarnings.enumerated()), id: \.element) { i, key in
                    HStack {
                        Text(Warning.Subject(key: key)?.title ?? key).accessibilityIdentifier("settings-ignored-\(i)")
                        Spacer()
                        Button("Stop ignoring") { theme.ignoredWarnings.removeAll { $0 == key } }
                            .accessibilityIdentifier("settings-unignore-\(i)")
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A theme's eight series as bars, as the theme page's cards show them: Super, Performance, Efficiency, Disk read
/// and write, Network in and out, Memory.
struct Swatch: View {
    let theme: Theme

    var body: some View {
        let order: [Theme.Series] = [.superCores, .performance, .efficiency, .diskRead, .diskWrite, .networkIn,
                                     .networkOut, .memory]
        let heights: [CGFloat] = [0.6, 0.9, 0.45, 0.7, 1, 0.55, 0.8, 0.65]
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(order.enumerated()), id: \.offset) { i, series in
                RoundedRectangle(cornerRadius: 1)
                    .fill(ThemeModel.color(theme.series[series]))
                    .frame(width: 5, height: 16 * heights[i])
            }
        }
        .frame(height: 16, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// A 12 pt stretch of a line in its colour and dash pattern, 2 pt thick as the graphs draw it: the key beside a figure
/// where one graph draws several lines, as a chart legend's symbol sits beside its label.
struct LineKey: View {
    let color: Color
    let dash: [CGFloat]

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 1))
            path.addLine(to: CGPoint(x: 12, y: 1))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dash))
        .frame(width: 12, height: 2)
        .accessibilityHidden(true)
    }
}
