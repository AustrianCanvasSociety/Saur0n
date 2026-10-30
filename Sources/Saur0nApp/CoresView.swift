// SPDX-License-Identifier: GPL-3.0-or-later
import Charts
import Saur0nCore
import SwiftUI

/// Top to bottom: the graph row — CPU, Memory, Disk & Network, each over a sparkline (Backlog window-graph-area-space)
/// — and under it the one graph open, if any: the per-type graphs with the "Cores (N)" row that opens onto one strip per
/// core (the user's mockup E), used memory with its five largest processes, or the Disk and Network graphs with their
/// top-five strips (Phase 5); then the process table (Step 2). Every colour is the theme's (Backlog window-theme).
/// Accessibility identifiers are what `scripts/read-window.swift` reads; every number a check compares is a `Text`,
/// since a `Chart`'s accessibility value does not reach the AX tree (research 2026-10-19 Q4).
struct CoresView: View {
    @Bindable var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let history = model.history {
                // Backlog window-graph-area-space (option 6): one row of three cells, each its figures over a
                // 60-second sparkline; a cell pressed opens its full graph under the row, at most one at a time.
                SparkRow(model: model, history: history)
                switch model.openGraph {
                case .cpu:
                    // One row: the per-type graphs, then Load, User / System and Launched, all the same height and
                    // width (the user, 2026-10-22: the same row, no second one), their titles in one size.
                    let levels = Array(history.topology.levels.enumerated())
                    let titles = levels.map { i, level in TypeGraph.title(history: history, levelIndex: i, level: level) }
                        + MachineGraphs.titles(load: model.loadHistory, cpus: history.perCPU.count)
                    GeometryReader { geometry in
                        let columns = Double(titles.count)
                        let titleSize = GraphTitle.size(titles, width: (geometry.size.width - 12 * (columns - 1)) / columns)
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(levels, id: \.offset) { i, level in
                                TypeGraph(theme: model.theme, history: history, levelIndex: i, level: level,
                                          spikes: model.spikes.cpu, now: model.spikesEnd, titleSize: titleSize)
                            }
                            MachineGraphs(load: model.loadHistory, cpus: history.perCPU.count, titleSize: titleSize)
                        }
                    }
                    .frame(height: GraphTitle.height + 4 + 110)
                    CoresRow(model: model, history: history)
                case .memory:
                    MemoryGraph(theme: model.theme, history: model.memoryHistory, top: model.memoryTop)
                case .diskNetwork:
                    let disk = model.disk, network = model.network
                    HStack(alignment: .top, spacing: 12) {
                        RateGraph(theme: model.theme, kind: "disk", title: "Disk", series: (.diskRead, .diskWrite),
                                  figures: (("R", rate(disk?.readBytesPerSecond)), ("W", rate(disk?.writeBytesPerSecond))),
                                  hint: model.diskWindowHint, history: model.diskHistory, top: model.diskTop,
                                  spikes: model.spikes.disk, now: model.spikesEnd)
                        RateGraph(theme: model.theme, kind: "network", title: "Network", series: (.networkIn, .networkOut),
                                  figures: (("In", rate(network?.inBytesPerSecond)), ("Out", rate(network?.outBytesPerSecond))),
                                  hint: model.networkWindowHint, history: model.networkHistory, top: model.networkTop,
                                  spikes: model.spikes.network, now: model.spikesEnd)
                    }
                case .none:
                    EmptyView()
                }
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("error")
            }
            if !model.barLines.isEmpty {
                WarningBarView(model: model)
            }
            ProcessTableView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        // The value columns as the user left them with the table's spacing (622 pt by default) plus Name's 148 pt floor
        // plus the 32 pt padding: 802 pt by default (touchup 3; Phase 5 Step 3; Backlog resizable-columns).
        // 420 pt (580 while every graph showed): the graph row and the tallest graph under it — Disk & Network or
        // Memory with their strips, or CPU with its Cores row closed — leave the table its header and four rows.
        .frame(minWidth: model.columnWidths.windowMinWidth(scroller: model.scrollerWidth), minHeight: Self.minHeight, alignment: .topLeading)
        // The selected row's Quit, Force Quit and Pause / Resume (Phase 5 Step 5) are in the Process menu and the row's
        // context menu, not here (Phase 6 Step 7: the user, 2026-10-24, "yes"), so Snapshot now fits beside Refresh.
        .toolbar {
            ToolbarItem {
                HStack {
                    // Icon only, so paused the search field keeps its place at the minimum width (Backlog
                    // paused-toolbar-search-at-minimum-width; the user, 2026-10-23: "a"): the word is its tooltip and
                    // its accessibility label, and the button beside it reads Resume.
                    if model.paused {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(model.theme.color(.paused))
                            .help("Paused: the window is not refreshing")
                            .accessibilityLabel("Paused")
                            .accessibilityIdentifier("paused")
                    }
                    Button(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill") {
                        model.paused.toggle()
                    }
                    .help(model.paused ? "Resume refreshing" : "Stop refreshing; the window keeps what it shows")
                    .accessibilityIdentifier("pause")
                    // Beside Pause, as both drive the refresh: Safari's Reload symbol and its ⌘R. A reading now,
                    // re-sorted, greyed rows gone; while paused one reading, still paused.
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Read now and re-sort; ended processes leave the table")
                        .accessibilityIdentifier("refresh")
                    // Phase 6 Step 7, beside Refresh (the user, 2026-10-24: "yes"): icon only, no shortcut (⌘⇧S is
                    // Save As). The note beside it says it was kept, for 5 s.
                    Button("Snapshot now", systemImage: "camera") { model.snapshotNow() }
                        .labelStyle(.iconOnly)
                        .help("Snapshot now: keep what the window shows in the snapshot log (saur0n snapshots)")
                        .accessibilityIdentifier("snapshot-now")
                    if let note = model.snapshotNote {
                        Text(note.text)
                            .font(.caption)
                            .lineLimit(1)
                            .help(note.help)
                            .accessibilityIdentifier("snapshot-saved")
                    }
                }
            }
            ToolbarItem {
                // Touchup 5: folds every group while any is open, opens every group (catch-alls too) otherwise;
                // the reader's `fold` presses it by its identifier and `state` reads its title.
                let anyOpen = model.anyGroupOpen
                Button(anyOpen ? "Collapse all" : "Expand all",
                       systemImage: anyOpen ? "rectangle.compress.vertical" : "rectangle.expand.vertical") {
                    model.foldAll()
                }
                .help(anyOpen ? "Fold every group" : "Open every group")
                .accessibilityIdentifier("fold-all")
            }
            ToolbarItem {
                // No "Group by" label beside it (Backlog window-search): its segments say what they do, and the room
                // keeps the search field out of the toolbar's overflow menu at the 802 pt minimum width. Short segments
                // since the third (the user, 2026-10-23: "also do Repo / Sesh / Cmd"), so the paused toolbar still fits.
                // A segment's own accessibility label does not reach the segmented control (probe 2026-10-23: each
                // reads its text), so the full words are in the help, and the window reader goes by segment order.
                HStack {
                    Picker("Group by", selection: $model.grouping) {
                        Text("Repo").tag(ProcessTable.Grouping.repo)
                        Text("Sesh").tag(ProcessTable.Grouping.session)
                        Text("Cmd").tag(ProcessTable.Grouping.command)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Group the processes by repo, session or command")
                    .accessibilityIdentifier("grouping")
                }
            }
            ToolbarItem {
                // Backlog window-search: filters as the user types (`ProcessTable.filtered`); Escape clears it.
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onKeyPress(.escape) {
                        model.searchText = ""
                        return .handled
                    }
                    .help("Show the processes whose name, pid, user, session or group contains the text")
                    .accessibilityIdentifier("search-field")
            }
        }
        // The theme's accent on the window's buttons and controls (Backlog window-theme: "the flame red-orange on
        // buttons, selection and the open cell"). The toolbar's glyphs stay the system's: macOS draws them as template
        // symbols, which neither tint nor a foreground style reaches (probe 2026-10-21).
        .tint(model.theme.color(.accent))
    }

    /// The opening width: the minimum at the default column widths.
    static let minWidth = ProcessTable.ColumnWidths().windowMinWidth, minHeight: CGFloat = 420
}

/// The bar above the table (Phase 6 Step 6): one line per warning, `! <name>  <first condition>` (`warning-<i>`) with
/// Details (`warning-details-<i>`; opened, each condition a `warning-condition-<i>-<j>`), Pause / Resume
/// (`warning-pause-<i>`), Stop… (`warning-stop-<i>`, the confirmation sheet) and Ignore (`warning-ignore-<i>`); the
/// Machine line has Details only; each line's container carries its pids in its identifier
/// (`warning-pids-<i>:<pid>,<pid>…`). "!" carries the alarm without colour (WCAG 2.2 § 1.4.1); the accent edges the bar.
struct WarningBarView: View {
    @Bindable var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.barLines.enumerated()), id: \.element.id) { i, line in
                let open = model.expandedWarnings.contains(line.id)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(line.text).bold().lineLimit(1).truncationMode(.middle)
                            .accessibilityIdentifier(line.identifier)
                        Spacer(minLength: 8)
                        Button(open ? "Hide details" : "Details") { model.details(line) }
                            .help("Show what this warning tripped and select its group")
                            .accessibilityIdentifier("warning-details-\(i)")
                        if line.actionable {
                            let paused = model.barPaused(line)
                            Button(paused ? "Resume" : "Pause") { model.pauseFromBar(line) }
                                .help(paused ? "Resume what this line paused" : "Pause every process of this warning")
                                .accessibilityIdentifier("warning-pause-\(i)")
                            Button("Stop…") { model.stopFromBar(line) }
                                .help("Quit every process of this warning, after naming what goes down")
                                .accessibilityIdentifier("warning-stop-\(i)")
                        }
                        if line.ignoreKey != nil {
                            Button("Ignore") { model.ignore(line) }
                                .help("Stop warning about this; undo it in Settings")
                                .accessibilityIdentifier("warning-ignore-\(i)")
                        }
                    }
                    .controlSize(.small)
                    if let note = line.note {
                        // Why nothing is paused here on its own: the Apple services in it are left running
                        // (`acting.exempt.apple`, on by default, read every tick).
                        Text(note).foregroundStyle(.secondary).padding(.leading, 12)
                            .help("Apple's own services are warned about but not paused; turn this off with the acting.exempt.apple default")
                            .accessibilityIdentifier("warning-note-\(i)")
                    }
                    if open {
                        ForEach(Array(line.conditions.enumerated()), id: \.offset) { j, condition in
                            Text(condition).monospacedDigit().accessibilityIdentifier("warning-condition-\(i)-\(j)")
                        }
                        .padding(.leading, 12)
                    }
                    if let error = model.barErrors[line.id] {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("warning-error-\(i)")
                    }
                }
                // What Pause and Stop act on, for the checks: in the identifier, which VoiceOver does not speak (SwiftUI's
                // `accessibilityIdentifier`: "Use this value for testing. It isn't visible to the user.").
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("warning-pids-\(i):" + line.pids.map(String.init).joined(separator: ","))
            }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(model.theme.color(.accent), lineWidth: 1))
    }
}

/// The spike marks at the foot of a graph, newest first, one line each: "Spike 14:03:12 · node 48.0%"
/// (`spike-<kind>-<i>`), its name cut in the middle to the graph's width, as the strips are, so a line never reaches
/// the next graph (the gate's round 1); nothing when there are none. A Chart's marks do not reach accessibility, so
/// the names are texts too (research 2026-10-19 Q4). At most six marks a minute (`SpikeMarks.spacing`) stay under the
/// names' two rows at the plot's top.
struct SpikeList: View {
    let kind: String
    let marks: [SpikeMarks.Mark]
    /// The uptime of the reading the marks came with.
    let end: Double

    var body: some View {
        if !marks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(marks.reversed().enumerated()), id: \.offset) { i, mark in
                    // The time whole, the name cut in the middle (the user, 2026-10-25: the cut took the time).
                    let time = "Spike \(Self.clock(mark.end, now: end)) · ", name = mark.name ?? notYetRead
                    HStack(spacing: 0) {
                        Text(time).fixedSize()
                        Text(name).truncationMode(.middle)
                    }
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 3)
                    .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))    // over the lines
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(time + name)
                    .accessibilityIdentifier("spike-\(kind)-\(i)")
                }
            }
            .font(.caption)
        }
    }

    /// The wall-clock time of uptime `end`, the reading at `now` taken as just now.
    static func clock(_ end: Double, now: Double) -> String {
        SpikeMarks.clock(Date().addingTimeInterval(end - now))
    }

    /// Where a mark sits on a 60-second graph whose newest point, at `now`, is at the right edge.
    static func x(_ mark: SpikeMarks.Mark, now: Double) -> Int {
        CPUHistory.capacity - 1 - Int((now - mark.end).rounded())
    }
}

/// A dashed rule at each spike's second, in the text colour; `SpikeNames` names them.
struct SpikeRules: ChartContent {
    let marks: [SpikeMarks.Mark]
    let now: Double

    var body: some ChartContent {
        ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
            RuleMark(x: .value("Second", SpikeList.x(mark, now: now)))
                .foregroundStyle(Color.primary.opacity(0.6))    // the text colour, not the accent (as MachineGraph)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}

/// The top process's name at each spike, inside the plot from its top, under the graph's title (`spike-name-<kind>-<i>`,
/// newest first): at its rule, placed by `SpikeMarks.nameSlots` on one of two rows so no two names meet; a name with no
/// room is left to the list. Drawn in a chart overlay outside the chart's hidden subtree, so the live check reads each
/// frame (the gate's round 1: names drawn over the title as annotations, which accessibility never sees).
struct SpikeNames: View {
    let kind: String
    let marks: [SpikeMarks.Mark]
    let now: Double
    let proxy: ChartProxy

    static let font = NSFont.preferredFont(forTextStyle: .caption2)
    static let rowHeight = NSLayoutManager().defaultLineHeight(for: font).rounded(.up)

    /// `name` as drawn in `font`, a point over for rounding.
    static func width(_ name: String) -> Double {
        (name as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 1
    }

    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                let newest = Array(marks.reversed())
                let names = newest.map { $0.name ?? "" }
                let slots = SpikeMarks.nameSlots(xs: newest.map { Double(proxy.position(forX: SpikeList.x($0, now: now)) ?? 0) },
                                                 widths: names.map(Self.width), width: plot.width, rows: 2)
                ForEach(Array(zip(names, slots).enumerated()), id: \.offset) { i, item in
                    if let slot = item.1, !item.0.isEmpty {
                        Text(item.0)
                            .font(Font(Self.font as CTFont))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: slot.width, height: Self.rowHeight, alignment: .leading)
                            .background(.background.opacity(0.85))    // over the lines
                            .position(x: plot.minX + slot.x + slot.width / 2,
                                      y: plot.minY + (Double(slot.row) + 0.5) * Self.rowHeight)
                            .accessibilityIdentifier("spike-name-\(kind)-\(i)")
                    }
                }
            }
        }
    }
}

/// Before its first reading a figure reads "—", never a 0 nothing measured: the window opens whole, with every
/// figure in its place, and each fills in as its reading lands (the user, 2026-10-21: "it loades in pieces").
let notYetRead = "—"
func rate(_ bytesPerSecond: UInt64?) -> String { bytesPerSecond.map(RateHistory.rateText) ?? notYetRead }
func percent(_ value: Double?) -> String { value.map(CPUHistory.percentText) ?? notYetRead }

extension ChartContent {
    /// A series' first reading is one point, which a line cannot draw: a dot at the right edge until the second
    /// reading makes it a line, so a graph fills in with the window's first reading.
    func firstPoint(_ count: Int) -> some ChartContent {
        symbol(.circle).symbolSize(count == 1 ? 16 : 0)
    }
}

/// The graph row: CPU, Memory, and Disk & Network, each a button (`spark-cpu`, `spark-memory`, `spark-disk-network`)
/// whose accessibility value reads "open" or "closed"; the figures are texts the reader reads (`cpu-total`, which
/// keeps the refresh count as its hint; `spark-memory-text`; `spark-disk-network-text`), in the text colour. The open
/// cell takes a neutral fill and the accent as its border.
struct SparkRow: View {
    @Bindable var model: MonitorModel
    let history: CPUHistory

    var body: some View {
        let theme = model.theme
        HStack(alignment: .top, spacing: 8) {
            cell(.cpu) {
                // The hint carries the refresh count: a reader that sees the same count before and after its
                // reads read one refresh (scripts/read-window.swift).
                Text("CPU \(percent(history.total.last))")
                    .accessibilityIdentifier("cpu-total")
                    .accessibilityHint("refresh \(model.refreshes)")
                // Each core type's average, as the theme page draws the cell: the types the Mac reports, slowest
                // first, so Super's line lies on top.
                Sparkline(series: history.topology.levels.enumerated().reversed().map { i, level in
                    theme.line(.coreType(level.name), history.perLevel[i])
                }, ceiling: 100)
            }
            .frame(width: 130)
            cell(.memory) {
                Text(model.memoryHistory.latest?.text ?? "Memory \(notYetRead)")
                    .accessibilityIdentifier("spark-memory-text")
                Sparkline(series: [theme.line(.memory, model.memoryHistory.percent)], ceiling: 100)
            }
            .frame(width: 190)
            cell(.diskNetwork) {
                KeyedFigures(theme: theme, parts: diskNetworkFigures)
                    .minimumScaleFactor(0.75)
                    .accessibilityIdentifier("spark-disk-network-text")
                // Read, write, in and out, as the graphs draw them; disk and network each scaled to its own ceiling,
                // so a busy disk does not flatten the network's lines.
                let disk = model.diskHistory, network = model.networkHistory
                Sparkline(series: Self.scaled(disk, theme, .diskRead, .diskWrite)
                              + Self.scaled(network, theme, .networkIn, .networkOut),
                          ceiling: 1)
            }
        }
        // What the window draws with, for the live checks: "<shown> chosen <chosen> <light|dark>", the theme shown,
        // the one picked in Settings (they differ while Increase contrast puts Two-colour on) and the appearance the
        // window has. The row's label, since a group's value and hint do not reach accessibility (probe 2026-10-21).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theme")
        .accessibilityLabel("\(theme.theme.id.rawValue) chosen \(theme.chosen.rawValue) \(colorScheme == .dark ? "dark" : "light")")
    }

    @Environment(\.colorScheme) private var colorScheme

    /// "Disk R 12.3 M/s W 4.5 M/s · Network In 1.2 M/s Out 340.0 K/s", each figure after its line's key.
    var diskNetworkFigures: [KeyedFigures.Part] {
        let disk = model.disk, network = model.network
        return [(nil, "Disk"), (.diskRead, "R \(rate(disk?.readBytesPerSecond))"),
                (.diskWrite, "W \(rate(disk?.writeBytesPerSecond))"), (nil, "· Network"),
                (.networkIn, "In \(rate(network?.inBytesPerSecond))"),
                (.networkOut, "Out \(rate(network?.outBytesPerSecond))")]
    }

    /// A rate history's two lines as shares (0…1) of its graph's ceiling.
    static func scaled(_ history: RateHistory, _ theme: ThemeModel, _ first: Theme.Series,
                       _ second: Theme.Series) -> [SparkLine] {
        let ceiling = Double(RateHistory.ceiling(history.first + history.second))
        return [theme.line(first, history.first.map { Double($0) / ceiling }),
                theme.line(second, history.second.map { Double($0) / ceiling })]
    }

    /// The button sits behind the figures, not around them: a button's label texts reach accessibility as its title
    /// only, without their identifiers (probe 2026-10-21), and every window check reads `cpu-total`. The figures let
    /// clicks through to it.
    func cell(_ graph: OpenGraph, @ViewBuilder content: () -> some View) -> some View {
        let open = model.openGraph == graph
        let names: [OpenGraph: String] = [.cpu: "CPU", .memory: "Memory", .diskNetwork: "Disk and Network"]
        return VStack(alignment: .leading, spacing: 2) { content() }
            .font(.callout.monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .background {
                Button {
                    model.openGraph.press(graph)
                } label: {
                    // Open: a neutral fill a step deeper than a closed cell's, inside the accent's border.
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(open ? 0.12 : 0.06))
                        .overlay {
                            if open {
                                RoundedRectangle(cornerRadius: 6).strokeBorder(model.theme.color(.accent), lineWidth: 1.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Close the graph" : "Open the full graph under the row")
                .accessibilityLabel("\(names[graph] ?? "") graph")
                .accessibilityValue(open ? "open" : "closed")
                .accessibilityIdentifier("spark-\(graph.rawValue)")
            }
    }
}

/// Figures in the window's text colour, each that has a line after the line's key (Backlog window-theme: "colour on
/// the lines"); read through accessibility as one string, the parts joined by spaces.
struct KeyedFigures: View {
    typealias Part = (series: Theme.Series?, text: String)
    let theme: ThemeModel
    let parts: [Part]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if let series = part.series {
                    HStack(spacing: 3) {
                        theme.key(series)
                        Text(part.text)
                    }
                } else {
                    Text(part.text)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map(\.text).joined(separator: " "))
    }
}

/// One sparkline's values in its series' colour and dash pattern.
struct SparkLine {
    let values: [Double]
    let color: Color
    let dash: [CGFloat]
}

/// A 60-second line per series, newest at the right edge, on a fixed ceiling; no axes. Hidden from accessibility:
/// the cell's text carries the figures.
struct Sparkline: View {
    let series: [SparkLine]
    let ceiling: Double

    var body: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { k, line in
                let firstX = CPUHistory.firstX(pointCount: line.values.count)
                ForEach(Array(line.values.enumerated()), id: \.offset) { second, value in
                    LineMark(x: .value("Second", firstX + second), y: .value("Value", value), series: .value("Series", k))
                        .foregroundStyle(line.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: line.dash))
                        .firstPoint(line.values.count)
                }
            }
        }
        .chartXScale(domain: 0...(CPUHistory.capacity - 1))
        .chartYScale(domain: 0...max(ceiling, 1))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

/// The Memory cell's graph: used memory as a share of physical over 60 seconds (0…100%), its figures as the header
/// (`memory-total`), and the five largest processes by memory now under it (`memory-top-<i>`, "<name> · <group> ·
/// <bytes>", as the Disk and Network strips).
struct MemoryGraph: View {
    let theme: ThemeModel
    let history: MemoryHistory
    let top: [TopMovers.Mover]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(history.latest?.text ?? "Memory \(notYetRead)") · \(percent(history.percent.last))")
                .font(.headline.monospacedDigit())
                .accessibilityIdentifier("memory-total")
            let firstX = CPUHistory.firstX(pointCount: history.percent.count)
            Chart {
                ForEach(Array(history.percent.enumerated()), id: \.offset) { second, value in
                    LineMark(x: .value("Second", firstX + second), y: .value("Used", value))
                        .firstPoint(history.percent.count)
                        .foregroundStyle(theme.color(.memory))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: theme.dash(.memory)))
                }
            }
            .chartXScale(domain: 0...(CPUHistory.capacity - 1))
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(values: [50, 100]) { AxisGridLine() } }
            .frame(height: 110)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(top.enumerated()), id: \.offset) { i, mover in
                    Text("\(mover.readableName ?? mover.name) · \(mover.group) · \(MemoryHistory.bytesText(mover.bytes))")
                        .monospacedDigit()
                        .accessibilityIdentifier("memory-top-\(i)")
                }
            }
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The machine's disk or network over 60 seconds, its current rates as the header, and under it the strip of the
/// five processes that moved the most bytes in the last minute (the user's "strip", 2026-10-20). Read and write, or
/// in and out, in the theme's colours: Network no longer shares Disk's (Backlog window-theme).
struct RateGraph: View {
    let theme: ThemeModel
    /// "disk" or "network": the identifiers' prefix.
    let kind: String
    let title: String
    let series: (first: Theme.Series, second: Theme.Series)
    /// Each line's label and current rate: ("R", "12.3 M/s"), ("W", …) or ("In", …), ("Out", …).
    let figures: (first: (String, String), second: (String, String))
    /// When the header's rates were read (`MonitorModel.windowHint`), for the live checks.
    let hint: String
    let history: RateHistory
    let top: [TopMovers.Mover]
    /// The spike marks on this graph and the uptime of the reading they came with (Phase 6 Step 6).
    let spikes: [SpikeMarks.Mark]
    let now: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // "Disk · R 12.3 M/s · W 4.5 M/s", "Network · In 1.2 M/s · Out 340.0 K/s"; the reader parses the figures
            // after the labels.
            KeyedFigures(theme: theme, parts: [(nil, "\(title) ·"), (series.first, "\(figures.first.0) \(figures.first.1)"),
                                               (nil, "·"), (series.second, "\(figures.second.0) \(figures.second.1)")])
                .font(.headline.monospacedDigit())
                .accessibilityIdentifier("\(kind)-total")
                .accessibilityHint(hint)
            let firstX = CPUHistory.firstX(pointCount: history.first.count)
            let ceiling = RateHistory.ceiling(history.first + history.second)
            Chart {
                ForEach(Array(history.first.enumerated()), id: \.offset) { second, value in
                    LineMark(x: .value("Second", firstX + second), y: .value("Rate", value), series: .value("Series", "first"))
                        .firstPoint(history.first.count)
                        .foregroundStyle(theme.color(series.first))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: theme.dash(series.first)))
                }
                ForEach(Array(history.second.enumerated()), id: \.offset) { second, value in
                    LineMark(x: .value("Second", firstX + second), y: .value("Rate", value), series: .value("Series", "second"))
                        .firstPoint(history.second.count)
                        .foregroundStyle(theme.color(series.second))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: theme.dash(series.second)))
                }
                SpikeRules(marks: spikes, now: now)
            }
            .chartXScale(domain: 0...(CPUHistory.capacity - 1))
            .chartYScale(domain: 0...ceiling)
            .chartXAxis(.hidden)
            // One gridline at the ceiling, labelled, since the scale moves with the load.
            .chartYAxis {
                AxisMarks(values: [ceiling]) { _ in
                    AxisGridLine()
                    AxisValueLabel(RateHistory.rateText(ceiling))
                }
            }
            .frame(height: 110)
            .accessibilityHidden(true)
            .chartOverlay { proxy in SpikeNames(kind: kind, marks: spikes, now: now, proxy: proxy) }
            // Over the graph, not under it: a mark must not take the table's rows at the minimum height.
            .overlay(alignment: .bottomLeading) { SpikeList(kind: kind, marks: spikes, end: now) }
            VStack(alignment: .leading, spacing: 1) {
                if top.isEmpty {
                    Text("nothing moved in the last minute")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(kind)-top-empty")
                } else {
                    ForEach(Array(top.enumerated()), id: \.offset) { i, mover in
                        Text("\(mover.readableName ?? mover.name) · \(mover.group) · \(RateHistory.bytesText(mover.bytes))")
                            .monospacedDigit()
                            .accessibilityIdentifier("\(kind)-top-\(i)")
                    }
                }
            }
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Super · 6 cores · 71.0%" over 60 seconds of the type's average (bold, in the type's dash pattern) and each of its
/// cores (faint, solid).
struct TypeGraph: View {
    let theme: ThemeModel
    let history: CPUHistory
    let levelIndex: Int
    let level: PerfLevel
    /// The CPU spike marks, named and listed on the first type's graph only (Phase 6 Step 6), in its own column.
    let spikes: [SpikeMarks.Mark]
    let now: Double
    /// The row's one title size (`GraphTitle.size`).
    let titleSize: Double

    static func title(history: CPUHistory, levelIndex: Int, level: PerfLevel) -> String {
        "\(level.name) · \(history.topology.cpusByLevel[levelIndex].count) cores · \(percent(history.perLevel[levelIndex].last))"
    }

    var body: some View {
        let cpus = history.topology.cpusByLevel[levelIndex]
        let average = history.perLevel[levelIndex]
        let series = Theme.Series.coreType(level.name)
        let color = theme.color(series)
        let named = levelIndex == 0
        VStack(alignment: .leading, spacing: 4) {
            GraphTitle(text: Self.title(history: history, levelIndex: levelIndex, level: level), size: titleSize,
                       identifier: "core-type-\(level.index)")
            // Touchup 1: the newest second sits at the right edge; history extends left over a fixed 60 s.
            let firstX = CPUHistory.firstX(pointCount: average.count)
            Chart {
                ForEach(cpus, id: \.self) { cpu in
                    ForEach(Array(history.perCPU[cpu].enumerated()), id: \.offset) { second, value in
                        LineMark(x: .value("Second", firstX + second), y: .value("Busy", value), series: .value("CPU", "cpu\(cpu)"))
                            .foregroundStyle(color.opacity(0.25))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                ForEach(Array(average.enumerated()), id: \.offset) { second, value in
                    LineMark(x: .value("Second", firstX + second), y: .value("Busy", value), series: .value("CPU", "average"))
                        .firstPoint(average.count)
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: theme.dash(series)))
                }
                SpikeRules(marks: spikes, now: now)
            }
            .chartXScale(domain: 0...(CPUHistory.capacity - 1))
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            // Touchup 8: gridlines at 50 and 100, no labels; the header carries the number.
            .chartYAxis { AxisMarks(values: [50, 100]) { AxisGridLine() } }
            .frame(height: 110)
            // The header text carries the number; a chart's marks would add 60 AX nodes per line.
            .accessibilityHidden(true)
            .chartOverlay { proxy in
                if named { SpikeNames(kind: "cpu", marks: spikes, now: now, proxy: proxy) }
            }
            // Over the graph, not under it: a mark must not take the table's rows at the minimum height.
            .overlay(alignment: .bottomLeading) {
                if named { SpikeList(kind: "cpu", marks: spikes, end: now) }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The CPU graph's last three: "Load · 5.12 4.80 4.31 · 18 CPUs" over the 1-minute load with a gridline at the CPU
/// count, unlabelled since the title names it (the user, 2026-10-25: the label crowded the title), "User 30.1% ·
/// System 12.2%" over the system share, "Launched · 120/s" over launches a second. Each header is a `Text` the reader
/// reads (`load-average`, `cpu-split`, `launch-rate`); the lines are in the text colour, so no theme needs a colour for
/// them.
struct MachineGraphs: View {
    let load: LoadHistory
    let cpus: Int
    /// The row's one title size (`GraphTitle.size`).
    let titleSize: Double

    /// Load, User / System and Launched's titles, in that order.
    static func titles(load: LoadHistory, cpus: Int) -> [String] {
        ["Load · \(load.latestLoad?.text ?? notYetRead) · \(cpus) CPUs",
         "User \(percent(load.latestSplit?.user)) · System \(percent(load.latestSplit?.system))",
         "Launched · \(load.latestLaunches.map(Snapshot.launchesText) ?? notYetRead)/s"]
    }

    var body: some View {
        let titles = Self.titles(load: load, cpus: cpus)
        MachineGraph(title: titles[0], titleSize: titleSize, identifier: "load-average", values: load.oneMinute,
                     ceiling: load.loadCeiling(cpus: cpus), gridlines: [(Double(cpus), nil)])
        MachineGraph(title: titles[1], titleSize: titleSize, identifier: "cpu-split", values: load.systemPercent,
                     ceiling: 100, gridlines: [(50, nil), (100, nil)])
        let launchesCeiling = load.launchesCeiling
        // The hint, "launches <count> pids <first> <last>", lets the live check find its own starts in the shown count.
        MachineGraph(title: titles[2], titleSize: titleSize, identifier: "launch-rate", values: load.launchesPerSecond,
                     ceiling: launchesCeiling, gridlines: [(launchesCeiling, "\(Int(launchesCeiling))/s")],
                     hint: load.latestLaunches.map { "launches \($0.count) pids \($0.first.pid) \($0.last.pid)" } ?? "")
    }
}

/// A CPU graph's title in the row's one size (the user, 2026-10-25: "text size is still wonky" — each title had shrunk
/// on its own to four sizes): the headline's size and weight with even-width digits, or all five smaller together until
/// the longest fits its column (one size for one level of headings: the user's "every graph title uses one size"),
/// never under 60%; past that a title is cut at its tail. Its line keeps the full size's height, so the graphs below
/// stay level.
struct GraphTitle: View {
    let text: String
    let size: Double
    let identifier: String
    var hint = ""

    static let full = NSFont.preferredFont(forTextStyle: .headline).pointSize
    static func font(_ size: Double) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: .bold) }
    static let height = NSLayoutManager().defaultLineHeight(for: font(full)).rounded(.up)

    /// The one size for `titles` in columns `width` wide: the full size when the longest fits, else that size scaled
    /// down to fit, in half points, at least 60% of it.
    static func size(_ titles: [String], width: Double) -> Double {
        let widest = titles.map { ($0 as NSString).size(withAttributes: [.font: font(full)]).width }.max() ?? 0
        guard widest > width - 2 else { return full }
        return max(full * 0.6, (full * (width - 2) / widest * 2).rounded(.down) / 2)
    }

    var body: some View {
        Text(text)
            .font(Font(Self.font(size) as CTFont))
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityIdentifier(identifier)
            .accessibilityHint(hint)
            .frame(height: Self.height, alignment: .bottomLeading)
    }
}

/// One machine figure over 60 seconds, laid out as a per-type graph: its header, then the line, newest at the right
/// edge. The header in the row's one size (`GraphTitle`), since five or six graphs share the row at the minimum width.
struct MachineGraph: View {
    let title: String
    let titleSize: Double
    let identifier: String
    let values: [Double]
    let ceiling: Double
    /// Each gridline's value, and its label when it has one.
    let gridlines: [(value: Double, label: String?)]
    /// What the live checks read beside the header's figures; empty for none.
    var hint = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GraphTitle(text: title, size: titleSize, identifier: identifier, hint: hint)
            let firstX = CPUHistory.firstX(pointCount: values.count)
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { second, value in
                    LineMark(x: .value("Second", firstX + second), y: .value("Value", value))
                        .firstPoint(values.count)
                        // The text colour as a Color: a mark's `.primary` style is the system accent (green on a Mac
                        // set to green, the user's 2026-10-25 demo).
                        .foregroundStyle(Color.primary)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartXScale(domain: 0...(CPUHistory.capacity - 1))
            .chartYScale(domain: 0...max(ceiling, 1))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: gridlines.map(\.value)) { mark in
                    AxisGridLine()
                    if let label = gridlines[mark.index].label { AxisValueLabel(label) }
                }
            }
            .frame(height: 110)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// "Cores (18)" with each type's average on the right; opened, one strip per core in columns of up to six
/// under their core type. A plain button (an `AXButton` the reader can press), not a `DisclosureGroup`.
struct CoresRow: View {
    @Bindable var model: MonitorModel
    let history: CPUHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.coresOpen.toggle()
            } label: {
                HStack {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(model.coresOpen ? 90 : 0))
                    Text("Cores (\(history.perCPU.count))").bold()
                    Spacer()    // the whole row stays clickable; the per-type numbers live in the graph headers (touchup 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cores-row")
            if model.coresOpen {
                let columns = CoreColumns.layout(history.topology)
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { k, column in
                        let color = model.theme.color(.coreType(column.name))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(column.name).font(.caption.bold())
                            ForEach(column.cpus, id: \.self) { cpu in
                                CoreStrip(cpu: cpu, series: history.perCPU[cpu], color: color)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("core-column-\(column.level)-\(k)")
                    }
                }
            }
        }
    }
}

/// Core number, 60 seconds of its load, its current % as text.
struct CoreStrip: View {
    let cpu: Int
    let series: [Double]
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text("\(cpu)").font(.caption.monospacedDigit()).frame(width: 18, alignment: .trailing)
            let firstX = CPUHistory.firstX(pointCount: series.count)
            Chart {
                // A faint fill under a line in the full colour: the line carries the 3:1 (Backlog window-theme).
                ForEach(Array(series.enumerated()), id: \.offset) { second, value in
                    AreaMark(x: .value("Second", firstX + second), y: .value("Busy", value))
                        .foregroundStyle(color.opacity(0.3))
                    LineMark(x: .value("Second", firstX + second), y: .value("Busy", value))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartXScale(domain: 0...(CPUHistory.capacity - 1))
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 20)
            .accessibilityHidden(true)
            Text(CPUHistory.percentText(series.last ?? 0))
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
                .accessibilityIdentifier("core-\(cpu)")
        }
    }
}
