// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import os
import Saur0nCore
import SwiftUI

/// Two fixes on the `NSTableView` behind the window's `Table`, applied by this zero-size view, which finds the
/// table in its window (the pattern — reach an AppKit view from a placed representable — is SwiftUI-Introspect's,
/// MIT; this code is written fresh). Finding no table changes nothing and logs it.
///
/// 1. Automatic row heights off. The window crashed once inside AppKit's automatic row-height pass during a table
///    update (Backlog `table-row-height-crash`); every row is one line of text, so a fixed height does all the sizing
///    the table needs. SwiftUI's `Table` has no switch for it (only `defaultMinListRowHeight`), so it is set here,
///    and set again on a later refresh if SwiftUI turned it back on.
/// 2. The table's rows re-laid after the window changes width. When the Name column's width changes (touchup 3),
///    the headers and AppKit's cell frames move to the new columns, but some rows keep their SwiftUI content where
///    the old columns were: every closed `DisclosureTableRow`, always, and every row for the first width change after
///    an Expand all re-created them (probes 2026-10-21, Backlog `wide-window-group-row-alignment` — the totals of
///    collapsed groups sat mid-Name in a full-screen window). Reloading the rows makes SwiftUI lay them out
///    again at the new widths; a sort does the same on its own. Done on the next run-loop turn, after SwiftUI has
///    given the table its new column widths, once per turn however many width changes a drag delivers.
struct TableFixes: NSViewRepresentable {
    /// The model's refresh count: a new value makes SwiftUI call `updateNSView`, which re-checks the row height.
    let refresh: Int
    /// The table's width: a new value reloads the rows.
    let width: CGFloat
    /// Called after the user drags a header divider, with the dragged column's title and every column's width by
    /// header title (fix 3).
    let resized: (String, [String: Double]) -> Void
    /// Called with the width a full-width vertical scroll bar takes beside the rows when it changes (fix 4).
    let scroller: (Double) -> Void

    func makeNSView(context: Context) -> Finder { Finder() }

    func updateNSView(_ view: Finder, context: Context) {
        view.resized = resized
        view.apply()
        view.relayRows(width: width)
        view.measureScroller(report: scroller)
    }

    final class Finder: NSView {
        static let log = Logger(subsystem: "app.saur0n.monitor", category: "table")
        private weak var table: NSTableView?
        private var reportedMissing = false
        /// Times the height was fixed: once at the start, more only if SwiftUI turned automatic heights back on.
        private var fixes = 0
        /// The width the rows were last laid out for, and whether a reload is already queued for it.
        private var laidOutWidth: CGFloat = 0
        private var relayQueued = false
        var resized: (String, [String: Double]) -> Void = { _, _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func findTable() -> NSTableView? {
            if table == nil, let content = window?.contentView, let found = Self.firstTable(in: content) {
                table = found
                observeResizes(found)
            }
            if table == nil, window != nil, !reportedMissing {
                reportedMissing = true
                Self.log.error("no NSTableView found in the window; automatic row heights stay on")
            }
            return table
        }

        /// Fix 3: a column resized by the user's drag (the header view names the column being dragged; a width
        /// SwiftUI sets, as Name's on every window resize, names none) reports every column's width.
        /// A selector observer: the notification center drops it when this view goes.
        private func observeResizes(_ table: NSTableView) {
            NotificationCenter.default.addObserver(self, selector: #selector(columnDidResize(_:)),
                                                   name: NSTableView.columnDidResizeNotification, object: table)
        }

        @objc private func columnDidResize(_ notification: Notification) {
            guard let table, let dragged = table.headerView?.resizedColumn, dragged >= 0,
                  dragged < table.tableColumns.count else { return }
            resized(table.tableColumns[dragged].title,
                    Dictionary(table.tableColumns.map { ($0.title, Double($0.width)) }, uniquingKeysWith: { a, _ in a }))
        }

        /// Reloads the rows on the next run-loop turn after a width change (fix 2); nothing when the width
        /// is unchanged, and one reload for any number of changes before the turn comes.
        func relayRows(width: CGFloat) {
            guard width != laidOutWidth else { return }
            laidOutWidth = width
            guard !relayQueued else { return }
            relayQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.relayQueued = false
                guard let table = self.findTable(), table.numberOfRows > 0 else { return }
                // Every row, not only those in view: AppKit keeps rows just outside the view prepared, and a refresh
                // that re-sorts one into view showed it at the old widths (2026-10-21, after the window shrank in
                // height as it widened). Rows without a view cost nothing to reload.
                table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows),
                                 columnIndexes: IndexSet(0..<table.numberOfColumns))
            }
        }

        /// Fix 4: the scroll view's width less its visible area's is what a full-width vertical scroll bar takes (macOS
        /// shows those while a mouse is connected, or always if the user chose so; an overlay bar takes nothing). Name
        /// gives that width up, or the rows run under the bar and a sideways scroll bar appears (seen 2026-10-21).
        /// Measured on every refresh, so a mouse plugged in or the setting changed is followed within a second;
        /// reported on the next run-loop turn, outside SwiftUI's update.
        private var lastScroller = 0.0
        func measureScroller(report: @escaping (Double) -> Void) {
            guard let scroll = findTable()?.enclosingScrollView else { return }
            let width = max(0, Double(scroll.frame.width - scroll.contentView.frame.width))
            guard width != lastScroller else { return }
            lastScroller = width
            DispatchQueue.main.async { report(width) }
        }

        /// Fixes the row height at the first row's, once the table has a row; a no-op when it is already fixed.
        func apply() {
            guard let table = findTable() else { return }
            guard table.usesAutomaticRowHeights, table.numberOfRows > 0 else { return }
            let height = table.rect(ofRow: 0).height
            guard height > 0 else { return }
            fixes += 1
            if fixes == 1 {
                Self.log.info("row heights fixed at \(Double(height), privacy: .public) pt")
            } else if fixes == 2 {
                Self.log.info("automatic row heights were back on; fixed again (logged once)")
            }
            table.rowHeight = height
            table.usesAutomaticRowHeights = false
        }

        static func firstTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews {
                if let table = firstTable(in: child) { return table }
            }
            return nil
        }
    }
}

/// The process table under the Cores row (mockup E): one row per group with its summed CPU, memory, disk and
/// network, its members under it, "Unattributed CPU" last (with the disk no row holds); sorted by CPU, a header
/// click re-sorts. Name comes first, as Activity Monitor's Process Name does, so the disclosure triangle sits by the
/// group's name. Each cell a check reads is a `Text` with an identifier (`scripts/read-window.swift`).
struct ProcessTableView: View {
    @Bindable var model: MonitorModel

    var body: some View {
        // Touchup 3: Name is given the rest of the table's width, so every column fits the window at any size and no
        // sideways scroller appears. The width has to live in SwiftUI's own column model: a width set on the AppKit
        // column is put back on the next pass, and SwiftUI never shrinks a column when the window does (probe
        // 2026-10-20). The value columns are the user's to drag (Backlog resizable-columns; 470 pt together by
        // default), remembered in `MonitorModel.columnWidths`; the window's minimum width follows them, so Name
        // never drops below its 148 pt floor.
        GeometryReader { geometry in
        Table(of: ProcessTable.Line.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            // Name's own edge drags too (the user, 2026-10-21: "name-PID does not work"): its range runs from its floor
            // to the most the value columns can give, and a drag on it trades width with them
            // (`ColumnWidths.resizeName`); otherwise it holds the remainder.
            // A full-width vertical scroll bar's width is not the rows' (`MonitorModel.scrollerWidth`).
            let rows = geometry.size.width - model.scrollerWidth
            let name = model.columnWidths.nameWidth(tableWidth: rows)
            TableColumn("Name", value: \.name) { line in NameCell(model: model, line: line) }
                .width(min: ProcessTable.ColumnWidths.nameFloor, ideal: name,
                       max: max(name, model.columnWidths.nameWidthAtMost(tableWidth: rows)))
            TableColumn("PID", value: \.pidNumber) { line in
                cell(line.pid.map(String.init) ?? "", line.pid.map { _ in line.cellIdentifier("process") })
            }
            .width(min: limit(.pid).lowerBound, ideal: width(.pid), max: limit(.pid).upperBound)
            TableColumn("User", value: \.userText) { line in
                cell(line.userText, line.pid.map { _ in line.cellIdentifier("user") })
            }
            .width(min: limit(.user).lowerBound, ideal: width(.user), max: limit(.user).upperBound)
            TableColumn("CPU", value: \.cpuPercent) { line in
                CPUCell(line: line).background(model.theme.busy(line.shade(.cpu)), in: RoundedRectangle(cornerRadius: 3))
            }
                .width(min: limit(.cpu).lowerBound, ideal: width(.cpu), max: limit(.cpu).upperBound)
            TableColumn("Memory", value: \.residentBytes) { line in
                cell(line.kind == .unattributed ? "" : line.memoryText, memoryIdentifier(line))
            }
            .width(min: limit(.memory).lowerBound, ideal: width(.memory), max: limit(.memory).upperBound)
            TableColumn("Disk", value: \.diskBytesPerSecond) { line in
                cell(line.diskText, rateIdentifier("disk", line))
                    .background(model.theme.busy(line.shade(.disk)), in: RoundedRectangle(cornerRadius: 3))
            }
                .width(min: limit(.disk).lowerBound, ideal: width(.disk), max: limit(.disk).upperBound)
            TableColumn("Network", value: \.networkBytesPerSecond) { line in
                cell(line.networkText, rateIdentifier("network", line))
                    .background(model.theme.busy(line.shade(.network)), in: RoundedRectangle(cornerRadius: 3))
            }
            .width(min: limit(.network).lowerBound, ideal: width(.network), max: limit(.network).upperBound)
            TableColumn("Session", value: \.sessionText) { line in
                // The session view's groups are the sessions; the repo and command views say whose each row is.
                cell(model.grouping != .session ? line.sessionText : "", line.pid.map { _ in line.cellIdentifier("session") })
            }
            .width(min: limit(.session).lowerBound, ideal: width(.session), max: limit(.session).upperBound)
        } rows: {
            ForEach(model.shownLines) { line in
                if let children = line.children {
                    DisclosureTableRow(line, isExpanded: Binding(get: { model.isOpen(line) },
                                                                 set: { model.setOpen(line, $0) })) {
                        // A catch-all's sub-groups fold their members one level deeper.
                        ForEach(children) { child in
                            if let members = child.children {
                                DisclosureTableRow(child, isExpanded: Binding(get: { model.isOpen(child) },
                                                                              set: { model.setOpen(child, $0) })) {
                                    ForEach(members) { TableRow($0) }
                                }
                            } else {
                                TableRow(child)
                            }
                        }
                    }
                } else {
                    TableRow(line)
                }
            }
        }
        .alternatingRowBackgrounds(.enabled)    // touchup 6, as Activity Monitor and Finder stripe their rows
        .contextMenu(forSelectionType: ProcessTable.Line.ID.self) { ids in
            // The row right-clicked becomes the selection, so this menu and the Process menu act on the same line.
            if let id = ids.first, id != "unattributed" {
                ActionButtons(model: model, select: id)
            }
        }
        // The rows' width, not the view's: a full-width scroll bar that comes or goes as rows fill the view moves Name
        // too, and the rows must be re-laid for it (wide window, groups closed, 2026-10-21).
        .background(TableFixes(refresh: model.refreshes, width: geometry.size.width - model.scrollerWidth,
                               resized: { model.columnsResized(dragged: $0, $1,
                                                               tableWidth: geometry.size.width - model.scrollerWidth) },
                               scroller: { model.scrollerWidth = $0 }))
        }
        .sheet(item: $model.pending) { _ in ActionSheet(model: model) }
    }

    /// A value column's width as the user left it, and the range a drag may take it to (`ProcessTable.ColumnWidths`).
    func width(_ column: ProcessTable.Column) -> CGFloat { model.columnWidths[column] }
    func limit(_ column: ProcessTable.Column) -> ClosedRange<CGFloat> {
        let limit = ProcessTable.ColumnWidths.limits[column] ?? 0...0
        return limit.lowerBound...limit.upperBound
    }

    /// `disk-<pid>` / `network-<pid>` on a process, `disk-group-<n>` / `network-group-<n>` on a group,
    /// `disk-subgroup-<n>-<m>` / `network-subgroup-<n>-<m>` on a sub-group, and `disk-unattributed` on the unattributed
    /// line (which has no network figure). A greyed line's say `gone` (`ProcessTable.Line.cellIdentifier`).
    func rateIdentifier(_ kind: String, _ line: ProcessTable.Line) -> String? {
        switch line.kind {
        case .group, .subgroup: "\(kind)-\(line.identifier)"
        case .process: line.pid.map { _ in line.cellIdentifier(kind) }
        case .unattributed: kind == "disk" ? "disk-unattributed" : nil
        }
    }

    func cell(_ text: String, _ identifier: String?) -> some View {
        Text(text).monospacedDigit().accessibilityIdentifier(identifier ?? "")
    }

    func memoryIdentifier(_ line: ProcessTable.Line) -> String? {
        switch line.kind {
        case .group, .subgroup: "\(line.identifier)-memory"
        case .process: line.pid.map { _ in line.cellIdentifier("memory") }
        case .unattributed: nil
        }
    }
}

/// A group's or sub-group's title and process count (a click toggles it, as in mockup E); a process's raw name
/// (escaped), its readable one in parentheses and its worktree. Tree indentation follows the default session or
/// command order; a column sort makes the members flat. Also renders "Unattributed CPU".
struct NameCell: View {
    @Bindable var model: MonitorModel
    let line: ProcessTable.Line

    var body: some View {
        switch line.kind {
        case .group, .subgroup:
            HStack(spacing: 8) {
                Text(line.name).bold().foregroundStyle(nameStyle)
                    .accessibilityIdentifier(line.identifier)
                Text(line.countText)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(line.identifier)-count")
                // A warned group (Phase 6 Step 6): the badge glyph in the accent, never colour alone (WCAG 2.2 § 1.4.1);
                // after the title, which the readers take as the cell's first identifier. The title stays in the text
                // colour: the accent reads 4.2:1 as text on the dark rows.
                if !line.warnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(model.theme.color(.accent))
                        .help("A warning in force names this group; see the bar above the table")
                        .accessibilityLabel("Warning")
                        .accessibilityIdentifier("warned-\(line.identifier)")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.setOpen(line, !model.isOpen(line)) }
        case .process:
            HStack(spacing: 4) {
                if line.depth > 0 {
                    Text(String(repeating: "│ ", count: line.depth)).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                // Ended since an earlier refresh, kept in place under a fixed sort for a minute.
                Text(line.name).foregroundStyle(nameStyle)
                    .accessibilityIdentifier(line.cellIdentifier("name"))
                if let readable = line.readableName {
                    Text("(\(readable))").foregroundStyle(.secondary).accessibilityIdentifier(line.cellIdentifier("readable-name"))
                }
                if let worktree = line.worktree {
                    Text("[worktree \(worktree)]").foregroundStyle(.secondary).accessibilityIdentifier(line.cellIdentifier("worktree"))
                }
                if line.orphaned {
                    Text("[orphaned]").foregroundStyle(.secondary).accessibilityIdentifier(line.cellIdentifier("orphaned"))
                        .help("Left under launchd by the shell that started it; shown with its process group's repo and session")
                }
                if line.paused {
                    Text("paused").foregroundStyle(model.theme.color(.paused)).bold()
                        .accessibilityIdentifier(line.pausedIdentifier)
                }
            }
            .lineLimit(1)
        case .unattributed:
            HStack(spacing: 4) {
                Text(line.name).italic()
                // What is new under launchd (Phase 6 Step 8), from 5% unattributed.
                if let hint = line.readableName {
                    Text("— \(hint)").foregroundStyle(.secondary).accessibilityIdentifier("unattributed-hint")
                }
            }
            .lineLimit(1)
        }
    }

    /// A greyed (ended) line's name in the theme's grey (the high-contrast themes lift it to 4.5:1), else the text
    /// colour.
    var nameStyle: AnyShapeStyle { line.gone ? AnyShapeStyle(model.theme.gone) : AnyShapeStyle(.primary) }
}

/// CPU % of the whole machine; a process adds `+N.N% exited` when its reaped children used some.
struct CPUCell: View {
    let line: ProcessTable.Line

    var body: some View {
        HStack(spacing: 4) {
            Text(line.cpuText).monospacedDigit().bold(line.kind == .group || line.kind == .subgroup)
                .accessibilityIdentifier(identifier)
            if !line.exitedText.isEmpty {
                Text(line.exitedText).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier(line.cellIdentifier("exited"))
            }
        }
    }

    var identifier: String {
        switch line.kind {
        case .group, .subgroup: "\(line.identifier)-cpu"
        case .process: line.cellIdentifier("cpu")
        case .unattributed: "unattributed"
        }
    }
}

/// Quit, Force Quit and Pause (Resume on a paused selection), in the Process menu and in a row's context menu; each
/// opens the confirmation sheet. `select` is the right-clicked row, which the context menu's buttons select first.
/// Identifiers `quit-button`, `force-quit-button`, `pause-button` / `resume-button`; the live checks press the Process
/// menu's items by title.
struct ActionButtons: View {
    @Bindable var model: MonitorModel
    var select: ProcessTable.Line.ID? = nil

    var body: some View {
        let resume = select == nil ? model.selectionPaused : (model.selection == select && model.selectionPaused)
        button(.quit, image: "xmark.octagon", help: "Quit the selected process; an app may save first")
        button(.forceQuit, image: "xmark.octagon.fill", help: "End the selected process at once; unsaved work in it is lost")
        button(resume ? .resume : .pause, image: resume ? "play.circle" : "pause.circle",
               help: resume ? "Let the selected process run again" : "Stop the selected process until resumed; it keeps its memory")
    }

    func button(_ action: ProcessControl.Action, image: String, help: String) -> some View {
        Button(action.title, systemImage: image) {
            if let select { model.selection = select }
            model.request(action)
        }
        .disabled(!model.canAct(on: select))
        .help(help)
        .accessibilityIdentifier(Self.identifier(action))
    }

    static func identifier(_ action: ProcessControl.Action) -> String {
        switch action {
        case .quit: "quit-button"
        case .forceQuit: "force-quit-button"
        case .pause: "pause-button"
        case .resume: "resume-button"
        }
    }
}

/// The confirmation sheet: what is about to go down and what goes with it — everything under it by kind ("Also
/// ends"), the processes connected to a port it listens on ("Used by (TCP)"), a launchd job that may come back — then
/// Cancel and the confirm button ("Quit all N" when anything is listed), and after macOS refused, the administrator
/// path. Every text a check reads carries an identifier.
struct ActionSheet: View {
    @Bindable var model: MonitorModel

    var body: some View {
        if let sheet = model.pending {
            VStack(alignment: .leading, spacing: 10) {
                Text(sheet.title).font(.headline).accessibilityIdentifier("sheet-title")
                Text(sheet.subtitle).foregroundStyle(.secondary).accessibilityIdentifier("sheet-subtitle")
                if sheet.action == .forceQuit {
                    Text("Unsaved work in it is lost.").foregroundStyle(.red).accessibilityIdentifier("sheet-warning")
                }
                if sheet.targets.count > 1 {
                    // Exactly the processes the action goes to, each by name and pid (the sheet acts on these pids and
                    // start times, no others).
                    Text("\(sheet.action.title) \(sheet.targets.count)").bold().accessibilityIdentifier("targets-heading")
                    scrolling(count: sheet.targets.count) {
                        ForEach(Array(sheet.targets.enumerated()), id: \.offset) { i, row in
                            Text("\(ProcessControl.shownName(row)) · pid \(row.pid)").accessibilityIdentifier("target-\(i)")
                        }
                    }
                }
                if sheet.alsoEnds.isEmpty && sheet.usedByRows.isEmpty, case .read = sheet.usedBy {
                    Text("Nothing else depends on it").accessibilityIdentifier("also-ends-none")
                }
                if !sheet.alsoEnds.isEmpty {
                    Text(sheet.summary).bold().accessibilityIdentifier("also-ends-heading")
                    list(sheet.alsoEnds, prefix: "also-ends")
                }
                if !sheet.spared.isEmpty {
                    Text("Left running \(sheet.spared.count)").bold().accessibilityIdentifier("spared-heading")
                    list(sheet.spared, prefix: "spared")
                }
                switch sheet.usedBy {
                case .reading:
                    Text("reading connections…").foregroundStyle(.secondary).accessibilityIdentifier("used-by-reading")
                case .unreadable:
                    Text("connections unreadable").foregroundStyle(.secondary).accessibilityIdentifier("used-by-unreadable")
                case .read(let rows) where !rows.isEmpty:
                    Text("Used by (TCP) \(rows.count)").bold().accessibilityIdentifier("used-by-heading")
                    list(rows, prefix: "used-by")
                case .read:
                    EmptyView()
                }
                ForEach(Array(sheet.left.enumerated()), id: \.offset) { i, line in
                    Text(line).foregroundStyle(.secondary).accessibilityIdentifier("left-running-\(i)")
                }
                if sheet.keepAlive {
                    Text("launchd started it; it may come back").foregroundStyle(.secondary).accessibilityIdentifier("keep-alive")
                }
                if let error = sheet.error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("action-error")
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancelPending() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("cancel-action")
                    if !sheet.denied.isEmpty {
                        Button("\(sheet.action.title) as administrator…") { model.confirmAsAdministrator() }
                            .accessibilityIdentifier("admin-action")
                    }
                    Button(sheet.confirmTitle, role: sheet.action == .forceQuit ? .destructive : nil) { model.confirmPending() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("confirm-action")
                }
            }
            .padding(20)
            .frame(minWidth: 380, alignment: .leading)
        }
    }

    /// Every row, each "<name> · <kind>", in a scrolling list once it is long: the sheet names what it acts on, none
    /// summarised away.
    func list(_ rows: [ProcessControl.Dependant], prefix: String) -> some View {
        scrolling(count: rows.count) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                Text("\(row.name) · \(row.kind.label) · pid \(row.pid)").accessibilityIdentifier("\(prefix)-\(i)")
            }
        }
    }

    /// `content` as a column; past what 160 pt holds it scrolls. A ScrollView takes all the height it is offered up to
    /// its cap, so a one-row list stays out of one.
    @ViewBuilder
    private func scrolling<Content: View>(count: Int, @ViewBuilder content: () -> Content) -> some View {
        let column = VStack(alignment: .leading, spacing: 2) { content() }
        if count > 7 {
            ScrollView { column }.frame(maxHeight: 160).padding(.leading, 8)
        } else {
            column.padding(.leading, 8)
        }
    }
}
