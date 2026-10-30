// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Saur0nCore

/// Saur0n's menu-bar item (Backlog background-menu-bar-icon; Delphi bdfd08ff): one persistent item in the app's own
/// process — the compact monochrome eye, the held level's 80/90/95 badge, and a click that brings up the window this
/// process already has. Closing the window leaves the item in place; no second sampler or window is created.
///
/// Presentation only. `feed` supplies the shared engine's held level and the age of the reading behind it; the
/// one-second refresh recomputes only that age and never advances a sample time, publishes a heartbeat or starts a
/// sampler. The rendering itself is a reviewable proposal until the user's rendering review.
@MainActor
final class MenuBarItem: NSObject {
    /// The app's one item, installed at launch and removed at quit.
    static let shared = MenuBarItem()

    /// What the item draws, read read-only from the shared model: the engine's held level, and the seconds since the
    /// reading it came from (nil when no reading has completed). The default is unavailable — never normal — until
    /// the app's model is attached.
    var feed: @MainActor () -> (level: MenuBarState.Level?, readingAge: TimeInterval?) = { (nil, nil) }

    private var statusItem: NSStatusItem?
    private var refresh: Timer?
    private var openWindow: (@MainActor () -> Void)?
    private var shown: MenuBarState?

    private override init() { super.init() }

    /// Puts the item in the menu bar where it stays while Saur0n runs, and makes a click open the window through
    /// `openWindow` — the app's existing reopen route, in this process.
    func install(openWindow: @escaping @MainActor () -> Void) {
        guard statusItem == nil else { return }
        self.openWindow = openWindow
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.setAccessibilityIdentifier("menu-bar-eye")
        statusItem = item
        // Display freshness only: it re-reads the model's stored sample age, so a paused or failed sampling shows as
        // stale instead of freezing a level that looks live. It writes nothing and samples nothing.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refresh = timer
        render()
    }

    /// Reads the model's current status and draws it; an unchanged state is not redrawn.
    func render() {
        let (level, readingAge) = feed()
        show(MenuBarState(level: level, readingAge: readingAge))
    }

    private func show(_ state: MenuBarState) {
        guard let button = statusItem?.button else { return }
        // The glyph and badge are the visible state; while a reading is stale only its age moves, so the item is not
        // redrawn for that. Assistive technology and the tooltip still carry the age.
        if state.symbolName != shown?.symbolName || state.badgeText != shown?.badgeText {
            button.image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            button.title = state.badgeText ?? ""
        }
        let label = state.accessibilityLabel
        if label != shown?.accessibilityLabel {
            button.setAccessibilityLabel(label)
            button.setAccessibilityHelp(label + ". Click to open Saur0n.")
            button.toolTip = label + " — click to open Saur0n"
        }
        shown = state
    }

    @objc private func clicked() { openWindow?() }

    /// Wires the item to the app's model, read-only: the level the last completed reading named, from the engine,
    /// and when that reading was taken. The age is computed here at read time; nothing is written to the model and
    /// no sampler, file or default is consulted.
    func follow(_ model: MonitorModel) {
        feed = { [model] in
            (model.resourceLevel.map(MenuBarState.Level.init),
             model.lastReadingAt.map { Date.now.timeIntervalSince($0) })
        }
    }

    /// Takes the item and its display refresh out of the menu bar; the app calls it as it quits.
    func uninstall() {
        refresh?.invalidate()
        refresh = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        shown = nil
    }
}

extension MenuBarState.Level {
    /// The engine's held level in the menu's presentation vocabulary, mapped explicitly: the same four reserved
    /// values, with no threshold or percentage consulted.
    init(_ level: ResourceLevel) {
        switch level {
        case .normal: self = .normal
        case .notice: self = .notice
        case .triage: self = .triage
        case .critical: self = .critical
        }
    }
}
