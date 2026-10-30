// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// `--watch` (Phase 7 Step 1): the LaunchAgent's mode. The app starts as the watcher — the sample loop, the warning
/// engine, the snapshot log and the acting switch, with no window shown — and the window opens over the same engine
/// when the user asks for it: the Dock's icon, Finder's, or Window ▸ Open Saur0n, in this process (macOS runs one copy).
enum Saur0nLaunch {
    static let watch = CommandLine.arguments.contains("--watch")
}

/// Saur0n's window: the whole-machine CPU and its core types, refreshed once a second; and its Settings window.
///
/// The App comes in two shapes because a scene's launch behaviour is macOS 15's `defaultLaunchBehavior` and the
/// package's floor is macOS 14, which has no such switch: there the launch window is closed as it appears
/// (`WatchDelegate`). Both shapes show the same scenes; `Saur0nMain` picks one at launch.
@main
enum Saur0nMain {
    static func main() {
        if #available(macOS 15.0, *) {
            Saur0nApp.main()
        } else {
            Saur0nAppLegacy.main()
        }
    }
}

/// macOS 15 and later: `--watch` starts with the window suppressed and its restoration off — without the second, a
/// window the last run saved comes back at launch — and every other start shows the window as always.
@available(macOS 15.0, *)
struct Saur0nApp: App {
    @NSApplicationDelegateAdaptor(WatchDelegate.self) private var watchDelegate

    let model = MonitorModel()

    /// The menu-bar eye reads the model's completed-reading level and time; it never drives sampling.
    init() { MenuBarItem.shared.follow(model) }

    var body: some Scene {
        Window("Saur0n", id: "main") {
            CoresView(model: model)
        }
        // 760 × 640 until the Disk and Network columns and graphs raised the minimum; 860 keeps the table's rows.
        .defaultSize(width: CoresView.minWidth, height: 860)
        .defaultLaunchBehavior(Saur0nLaunch.watch ? .suppressed : .automatic)
        .restorationBehavior(Saur0nLaunch.watch ? .disabled : .automatic)
        // The selected row's Quit, Force Quit and Pause / Resume, as the row's context menu has them (Phase 6 Step 7,
        // off the toolbar: the user, 2026-10-24, "yes"; Apple's HIG puts every command in the menu bar).
        .commands {
            CommandMenu("Process") { ActionButtons(model: model) }
            // The window a suppressed launch leaves closed: `openWindow` presents it again, and the Dock's click
            // reaches this item through `WatchDelegate` (Phase 7 Step 1, calibration lock 1).
            CommandGroup(after: .singleWindowList) {
                Button("Open Saur0n") { openWindow(id: "main") }
            }
        }
        // Saur0n ▸ Settings… and ⌘, come with the scene (Backlog window-theme; Apple's guidance keeps settings out of
        // the window's toolbar).
        Settings {
            SettingsView(theme: model.theme)
        }
    }

    @Environment(\.openWindow) private var openWindow
}

/// macOS 14's shape: the same scenes, and `WatchDelegate` closes the window `--watch` must not show. The "Open
/// Saur0n" item is the Dock click's reopen path here as it is on 15: the closed launch window leaves the delegate
/// no window to order front.
struct Saur0nAppLegacy: App {
    @NSApplicationDelegateAdaptor(WatchDelegate.self) private var watchDelegate

    let model = MonitorModel()

    /// The menu-bar eye reads the model's completed-reading level and time; it never drives sampling.
    init() { MenuBarItem.shared.follow(model) }

    var body: some Scene {
        Window("Saur0n", id: "main") {
            CoresView(model: model)
        }
        .defaultSize(width: CoresView.minWidth, height: 860)
        .commands {
            CommandMenu("Process") { ActionButtons(model: model) }
            CommandGroup(after: .singleWindowList) {
                Button("Open Saur0n") { openWindow(id: "main") }
            }
        }
        Settings {
            SettingsView(theme: model.theme)
        }
    }

    @Environment(\.openWindow) private var openWindow
}

/// Watch mode's two joins to AppKit. At launch a macOS 14 start closes the window it created (15 and later suppress
/// it in the scene instead). On every shape a Dock click or a Finder open shows the window in this process: the
/// suppressed launch leaves no window to order front, so it is asked for through the app's own "Open Saur0n" item.
final class WatchDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The menu-bar eye, in the app's own process: it outlives the window, so closing the window — or watch mode's
        // suppressed launch — leaves it in place, and its click reuses the reopen route below (Backlog
        // background-menu-bar-icon).
        MenuBarItem.shared.install { WatchDelegate.openSaur0n(NSApp) }
        guard Saur0nLaunch.watch, #unavailable(macOS 15.0) else { return }
        // Restoration off first: a window the last run saved would otherwise come back after this close.
        for window in NSApp.windows { window.isRestorable = false }
        DispatchQueue.main.async {
            for window in NSApp.windows where window.title == "Saur0n" { window.close() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard Saur0nLaunch.watch else { return true }
        Self.openSaur0n(sender)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MenuBarItem.shared.uninstall()
    }

    /// Shows Saur0n's window in this process: the window it already has brought forward, or — when the launch left
    /// none — the app's own "Open Saur0n" item's action, which asks the scene to open it. The Dock click and the
    /// menu-bar item share this route, so both keep one process and one window.
    @MainActor
    static func openSaur0n(_ sender: NSApplication) {
        if let window = sender.windows.first(where: { $0.title == "Saur0n" }) {
            window.makeKeyAndOrderFront(nil)
        } else if let item = menuItem(in: sender.mainMenu, titled: "Open Saur0n"), let action = item.action {
            sender.sendAction(action, to: item.target, from: item)
        }
        sender.activate()
    }

    /// The first item titled `title` anywhere in `menu`'s tree.
    private static func menuItem(in menu: NSMenu?, titled title: String) -> NSMenuItem? {
        guard let menu else { return nil }
        for candidate in menu.items {
            if candidate.title == title { return candidate }
            if let found = menuItem(in: candidate.submenu, titled: title) { return found }
        }
        return nil
    }
}
