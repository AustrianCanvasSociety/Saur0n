// SPDX-License-Identifier: GPL-3.0-or-later
// Reads Saur0n's window through accessibility and prints it as the CLI's `--json` shape, so the live checks
// keep their comparisons and swap only their source (research/2026-10-19-phase4-open.md Q4).
// Compiled by scripts/check-live.sh: swiftc -O scripts/read-window.swift -o .build/read-window
//
// Usage: read-window <pid> json | state | press-cores | totals <n> | snapshot [--expand <group>]… | rows
//                        | group-by repo|session
// json, snapshot and rows press the toolbar's Pause first, so the whole read is one refresh, and Resume on
// every way out (done, failed, or stopped by SIGINT / SIGTERM / SIGHUP); a window the user already paused
// stays paused. The refresh count must not move while paused.
//   json         the total and core types (the CPU graph and its Cores row must be open): {totalBusyPercent, coreTypes[…]}
//   state        {"coresOpen": bool, "windows": <the app's window count>, "paused": bool, "refresh": <count>},
//                read without pausing
//   press-cores  presses the "Cores (N)" row once
//   totals <n>   the total read once a second, n times: {"totals": […]}
//   snapshot     one refresh's total, groups (repoGroups or sessionGroups, as the picker shows), the members of
//                each --expand group only (`processes`), unattributedCpuPercent
//   rows         every group's members, closed groups opened for the read (not one refresh)
//                (snapshot and rows carry each group's and process's `disk` / `network` {bytesPerSecond}, null for
//                an unreadable "—", and `unattributedDisk`; Phase 5 Step 3)
//   rates        the Disk and Network graph headers: {diskTotal: {readBytesPerSecond, writeBytesPerSecond,
//                windowStart, windowEnd}, networkTotal: {inBytesPerSecond, outBytesPerSecond, …}, refresh, at},
//                read without pausing; `at` is the read's epoch time
//   strips       the top-five strips under them: {disk: [{text, name, group, bytes}], network: […], diskEmpty,
//                networkEmpty}, read without pausing
//   load         the CPU graph's Load, User / System and Launched headers: {loadAverage: {oneMinute, fiveMinutes,
//                fifteenMinutes, cpus}, userBusyPercent, systemBusyPercent, launchesPerSecond, launches: {count,
//                firstPid, lastPid}, refresh, at}, read without pausing (Phase 6 Step 2)
//   group-by     turns the toolbar picker to By repo / By session
//   layout       the window's size, the table's and its scroll view's frames, whether the table is wider than
//                its view or shows a horizontal scroll bar, the last row's frame and whether it lies inside
//                the view, the fold button's title, the open-group and group counts, any percent texts on the
//                Cores row, whether a column header reads "Memory", each column header's x and width, and the
//                identified cells (x and width) of the first twelve rows (Phase 4 Step 4 touchups 2–5, 7;
//                Backlog wide-window-group-row-alignment), and the open graph's titles, spike names and spike lines
//                with every pair that intersects and every title taller than one line (`graphText`, the Phase 6 gate's
//                round 1); read without pausing. `layout --min` first sizes the
//                window to its minimum (asked for 1 × 1; 802 × 580 at the default column widths), `--wide` to the main display's width × 700, `--size <w> <h>`
//                to that; each restores the size afterwards.
//   graph-text   the open graph's titles, spike names and spike lines alone, as `layout`'s `graphText`
//   fold         presses the toolbar's Collapse all / Expand all button once
//   act <quit|force-quit|pause|resume> <pid> [--cancel]
//                selects pid's shown row, presses the toolbar button, reads the confirmation sheet, then cancels or
//                confirms: {title, subtitle, warning, alsoEndsHeading, alsoEnds: [{name, kind}], usedBy: […],
//                nothingElse, usedByUnreadable, keepAlive, confirmTitle, cancelled, error[, admin]} (Phase 5 Step 5)
//   warning-stop-sheet <i> [--cancel]
//                presses bar line i's Stop…, reads the sheet, then confirms or cancels: {title, subtitle,
//                targetsHeading, targets: ["<name> · pid <n>"], targetPids, sparedHeading, spared:
//                ["<name> · <kind> · pid <n>"], sparedPids, confirmTitle, cancelled, error} (safe runaway controls)
//   row <pid>    pid's row as `rows` gives it, from the shown rows only (no group opened), or null: {row, refresh}
//                (rows and row carry `paused`, the row's badge)
//   sort <title> presses the column header titled <title> once (a second press reverses it)
//   order        the shown rows in table order, one refresh's (paused for the read): {refresh, rows:
//                ["group:<title>", "subgroup:<name>", "pid:<pid>:<name>", "gone:<pid>:<name>" (greyed: ended),
//                "unattributed"], counts: {<title>: "N processes" / "N of M processes"}} (Backlog
//                stable-rows-under-fixed-sort)
//   refresh [--paused]
//                presses the toolbar's Refresh and waits for the refresh it takes; --paused pauses first and reads
//                2 s later whether another came: {before, after, seconds[, later, paused]}
//   search <text> | search --clear     (never takes the user's focus: the text set through accessibility)
//                types <text> into the toolbar's search field (Escape first if it holds text), or clears it with
//                Escape: {search: <the field's text>} (Backlog window-search)
//   spark        the graph row (Backlog window-graph-area-space): {cells: {cpu: {text, open}, memory: …,
//                "disk-network": …}, open: <cell or "none">}, read without pausing
//   open-graph <cpu|memory|disk-network|none>
//                presses the graph row's cells until that graph is open (none: every graph closed), then prints
//                `spark`. json and press-cores need the CPU graph open, rates and strips Disk & Network's,
//                memory Memory's: closed, each says so and exits 4.
//   memory       the Memory graph: {total: <header text>, top: [{text, name, group, bytes}]}
//   settings [<title>]
//                opens Saur0n ▸ Settings…, presses the theme or appearance titled so if given, and reads
//                {themes: {<title>: picked}, appearances: {System|Light|Dark: picked}, highContrast,
//                window: {theme, themeChosen, appearance}} (Backlog window-theme)
//   warnings     the bar above the table (Phase 6 Step 6): {lines: [{text, details, pause, stop, ignore (button titles,
//                null when absent), conditions (shown while Details is open), error}], groups: [{id, title, warned}]
//                (the first five group rows, `warned` their badge), refresh}, read without pausing
//   warning-press <i> <details|pause|stop|ignore>
//                presses that button on bar line i
//   contrast [--margin <points>] <id>…
//                captures the window by its window id and reads each element's frame grown by the margin (1 pt):
//                {<id>: {background, figure, ratio}, scale} — the most common colour, the one most unlike it, and
//                their WCAG contrast; needs the terminal's Screen Recording grant
//   dock-badge <bundle path>
//                with the Dock's pid in place of the app's: the Dock item of that bundle, read from the Dock (no window
//                needed, so after the app quits too): {found, label (its badge; null when none), running} (Phase 6
//                Step 9)
// state also carries `openGroups`, `groups`, `foldButton`, `openGraph`, and `theme`, `themeChosen` and `appearance` —
// the theme the window shows, the one picked in Settings, and the window's light or dark.
// The table's fields are the ones the window shows: no uid, source, repo root or session kind and id.
// Exit: 0 ok · 1 window or element missing · 2 usage · 3 the terminal lacks the Accessibility grant · 4 the graph a
// read needs is closed
import AppKit
import ApplicationServices
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("read-window: \(message)\n".utf8))
    releaseRefreshes()
    exit(code)
}

let args = CommandLine.arguments.dropFirst()
guard let pidArg = args.first, let pid = pid_t(pidArg), let command = args.dropFirst().first else {
    fail("usage: read-window <pid> json|state|press-cores|totals <n>|snapshot [--expand <group>]…|rows|group-by repo|session", code: 2)
}
guard AXIsProcessTrusted() else {
    fail("this terminal has no Accessibility permission (System Settings → Privacy & Security → Accessibility)", code: 3)
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

/// An element's children `depth` levels below a walk's root. The window's tree is far shallower than the cap;
/// a probe's unbounded walk overflowed its stack while rows came and went (churn probe 2026-10-19), so a walk
/// this deep stops with a message instead.
func children(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
    guard depth < 100 else { fail("accessibility tree deeper than 100 levels — the window changed mid-read; try again") }
    return children(element)
}

/// The app's window titled "Saur0n", waiting up to 10 s for it to appear. While the screen is locked,
/// accessibility answers for each window with the application element itself (probe 2026-10-19: every app's
/// windows, Finder's and Terminal's too), so a window list without one `AXWindow` waits, then says so.
func window() -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    var sawApplication = false
    for _ in 0..<100 {
        let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        if let found = windows.first(where: {
            attribute($0, kAXRoleAttribute) as? String == kAXWindowRole && attribute($0, kAXTitleAttribute) as? String == "Saur0n"
        }) { return found }
        sawApplication = sawApplication || windows.contains { attribute($0, kAXRoleAttribute) as? String == kAXApplicationRole }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if sawApplication { fail("accessibility shows pid \(pid)'s windows as the app itself — is the screen locked?") }
    fail("no window titled Saur0n for pid \(pid)")
}

/// Every element with an AX identifier, by identifier; `parents` holds each one's nearest identified ancestor.
struct Identified {
    var elements: [String: AXUIElement] = [:]
    var parents: [String: String] = [:]
}

/// The identified elements outside the process table (whose rows `tableRows` reads on its own): walking a
/// table's hundreds of rows each time the total is wanted would take seconds.
func identified(_ root: AXUIElement) -> Identified {
    var found = Identified()
    func walk(_ element: AXUIElement, under parent: String?, depth: Int = 0) {
        var parent = parent
        if let id = attribute(element, "AXIdentifier") as? String, !id.isEmpty {
            found.elements[id] = element
            if let parent { found.parents[id] = parent }
            parent = id
        }
        guard attribute(element, kAXRoleAttribute) as? String != kAXOutlineRole else { return }
        for child in children(element, depth: depth) { walk(child, under: parent, depth: depth + 1) }
    }
    walk(root, under: nil)
    return found
}

/// A static text's string: its value, else its description.
func text(_ element: AXUIElement) -> String? {
    (attribute(element, kAXValueAttribute) as? String) ?? (attribute(element, kAXDescriptionAttribute) as? String)
}

/// The number in "CPU 42.3%" / "Super · 6 cores · 71.0%" / "42.3%": the last `<digits>[.<digits>]%`. Decimal, so the
/// JSON carries 42.3 as the window shows it, not its nearest binary double.
typealias Percent = NSDecimalNumber

func percent(_ string: String) -> Percent? {
    guard let range = string.range(of: #"[0-9]+(\.[0-9]+)?(?=%)"#, options: [.regularExpression, .backwards]) else { return nil }
    return NSDecimalNumber(string: String(string[range]), locale: Locale(identifier: "en_US_POSIX"))
}

func required(_ found: Identified, _ id: String) -> AXUIElement {
    guard let element = found.elements[id] else { fail("no element \(id)") }
    return element
}

func total(_ found: Identified) -> Percent {
    let element = required(found, "cpu-total")
    guard let value = text(element).flatMap(percent) else { fail("cpu-total reads '\(text(element) ?? "")'") }
    return value
}

/// The refresh the window last applied, from the total's hint "refresh N" (MonitorModel.refreshes).
func refreshCount(_ found: Identified) -> Int {
    let element = required(found, "cpu-total")
    let hint = (attribute(element, kAXHelpAttribute) as? String) ?? ""
    guard hint.hasPrefix("refresh "), let n = Int(hint.dropFirst("refresh ".count)) else { fail("cpu-total's hint reads '\(hint)'") }
    return n
}

// --- The process table (ProcessTableView): one AXRow per shown line, in table order ---

func table(_ root: AXUIElement) -> AXUIElement {
    func find(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if attribute(element, kAXRoleAttribute) as? String == kAXOutlineRole { return element }
        for child in children(element, depth: depth) { if let found = find(child, depth: depth + 1) { return found } }
        return nil
    }
    guard let found = find(root) else { fail("no process table in the window") }
    return found
}

/// One row's identified texts by identifier, and the row itself; `texts` stays empty for a member row that
/// was not read.
struct Row {
    let element: AXUIElement
    var texts: [String: String] = [:]
}

/// The table's rows in order. Group rows and the unattributed line (outline level 0) are read in full; a
/// member row only when `members` says so for its group's title — reading one costs ~15 ms (probe 2026-10-19:
/// 158 rows in 2.3 s), so a read of every row spans several refreshes, while a member row skipped costs one
/// attribute.
func tableRows(_ table: AXUIElement, members: (String) -> Bool) -> [Row] {
    var group = ""
    return ((attribute(table, kAXRowsAttribute) as? [AXUIElement]) ?? []).map { element in
        var row = Row(element: element)
        let level = (attribute(element, "AXDisclosureLevel") as? Int) ?? 0
        guard level == 0 || members(group) else { return row }
        func walk(_ e: AXUIElement, depth: Int = 0) {
            if let id = attribute(e, "AXIdentifier") as? String, !id.isEmpty { row.texts[id] = text(e) ?? "" }
            for child in children(e, depth: depth) { walk(child, depth: depth + 1) }
        }
        walk(element)
        if level == 0, let title = groupTitle(row) { group = title }
        return row
    }
}

/// A group row's `group-<n>` identifier and title, else nil.
func groupCell(_ row: Row) -> (key: String, value: String)? {
    row.texts.first { $0.key.hasPrefix("group-") && Int($0.key.dropFirst(6)) != nil }
}

/// A group row's title (its `group-<n>` text), else nil.
func groupTitle(_ row: Row) -> String? {
    groupCell(row)?.value
}

/// Whether `id` is a sub-group line's name cell, `subgroup-<n>-<m>` (Phase 5 Step 4).
func isSubgroupID(_ id: String) -> Bool {
    let parts = id.split(separator: "-")
    return parts.count == 3 && parts[0] == "subgroup" && Int(parts[1]) != nil && Int(parts[2]) != nil
}

/// A sub-group row's `subgroup-<n>-<m>` identifier and name, else nil.
func subgroupCell(_ row: Row) -> (key: String, value: String)? {
    row.texts.first { isSubgroupID($0.key) }
}

/// The first identifier under a row, depth first: its Name cell's (`group-<n>`, `subgroup-<n>-<m>`, `name-<pid>`).
/// Cheaper than reading the whole row when only its kind is wanted.
func firstIdentifier(_ element: AXUIElement, depth: Int = 0) -> String? {
    if let id = attribute(element, "AXIdentifier") as? String, !id.isEmpty { return id }
    for child in children(element, depth: depth) {
        if let id = firstIdentifier(child, depth: depth + 1) { return id }
    }
    return nil
}

/// The sub-group rows on show (outline level 1 whose Name cell is `subgroup-<n>-<m>`), each with its group's
/// title, its own identifier and whether it is disclosed.
func subgroupRows(_ table: AXUIElement) -> [(group: String, id: String, element: AXUIElement, open: Bool)] {
    var group = "", out: [(group: String, id: String, element: AXUIElement, open: Bool)] = []
    for element in (attribute(table, kAXRowsAttribute) as? [AXUIElement]) ?? [] {
        let level = (attribute(element, "AXDisclosureLevel") as? Int) ?? 0
        guard level <= 1, let id = firstIdentifier(element) else { continue }
        if level == 0 {
            if id.hasPrefix("group-") { group = text(firstElement(element, id) ?? element) ?? "" }
        } else if isSubgroupID(id) {
            out.append((group, id, element, (attribute(element, "AXDisclosing") as? Bool) ?? false))
        }
    }
    return out
}

/// The element under `element` whose identifier is `id`.
func firstElement(_ element: AXUIElement, _ id: String, depth: Int = 0) -> AXUIElement? {
    if attribute(element, "AXIdentifier") as? String == id { return element }
    for child in children(element, depth: depth) {
        if let found = firstElement(child, id, depth: depth + 1) { return found }
    }
    return nil
}

/// Opens (or closes) the sub-groups under the groups named in `names` — every one when `only` is nil, else the
/// identifiers in it — and waits up to 10 s for the table to show it. Returns the identifiers it changed.
@discardableResult
func setSubgroupsOpen(under names: Set<String>, _ open: Bool, only: Set<String>? = nil, in table: AXUIElement) -> Set<String> {
    var changed = Set<String>()
    for row in subgroupRows(table) where names.contains(row.group) && row.open != open && (only?.contains(row.id) ?? true) {
        guard AXUIElementSetAttributeValue(row.element, "AXDisclosing" as CFString, open as CFBoolean) == .success else {
            fail("cannot \(open ? "open" : "close") sub-group \(row.id)")
        }
        changed.insert(row.id)
    }
    for _ in 0..<100 {
        let shown = subgroupRows(table).filter { changed.contains($0.id) }
        if shown.count == changed.count && shown.allSatisfy({ $0.open == open }) { return changed }
        Thread.sleep(forTimeInterval: 0.1)
    }
    fail("sub-groups \(changed.sorted()) did not turn open=\(open)")
}

/// `34M` / `8.1G` / `512B` (ProcessSample.memoryText) as bytes, to the precision shown.
func bytes(_ shown: String) -> Int? {
    let units: [Character: Double] = ["B": 1, "K": 1024, "M": 1024 * 1024, "G": 1024 * 1024 * 1024, "T": 1024 * 1024 * 1024 * 1024]
    guard let unit = shown.last, let scale = units[unit], let value = Double(shown.dropLast()) else { return nil }
    return Int((value * scale).rounded())
}

/// An SI figure as the window shows it (TextFormat): `0`, `999 B/s`, `1.2 M/s` with `suffix` "/s", `512 M` with ""
/// — in bytes, to the precision shown; nil for anything else (`—` included).
func siBytes(_ shown: String, suffix: String = "/s") -> Int? {
    if shown == "0" { return 0 }
    let units: [String: Double] = ["B": 1, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "P": 1e15]
    let parts = shown.split(separator: " ")
    guard parts.count == 2, parts[1].hasSuffix(suffix), let value = Double(parts[0]),
          let scale = units[String(parts[1].dropLast(suffix.count))] else { return nil }
    return Int((value * scale).rounded())
}

/// A rate cell as `{bytesPerSecond}`, or null for `—` (unreadable); nil when the cell is missing or unparsable.
func rateCell(_ shown: String?) -> Any? {
    guard let shown else { return nil }
    if shown == "—" { return NSNull() }
    return siBytes(shown).map { ["bytesPerSecond": $0] }
}

/// The first `<digits>.<digit>%` in a string ("5.2%", "+1.0% exited").
func firstPercent(_ string: String) -> Percent? {
    guard let range = string.range(of: #"[0-9]+(\.[0-9]+)?(?=%)"#, options: .regularExpression) else { return nil }
    return NSDecimalNumber(string: String(string[range]), locale: Locale(identifier: "en_US_POSIX"))
}

/// Why `readTable` last returned nil.
var torn = ""

/// The table read once: groups (and which are open), the members read (`tableRows`) under their group, the
/// unattributed line. Groups in the CLI's group shape (`cpuPercent` = the shown total, own plus exited
/// children; `exitedChildrenCpuPercent` 0), plus `count` and `open`, with `name` the title the table shows
/// (root, clone or session id suffixes included); `pids` only for groups whose members were read. A process's
/// `repo.name` is its group's title in the repo view; in the session view the window shows no repo, so `repo`
/// is null, as the CLI's JSON has it for an unknown repo. nil when a row reads half-drawn (a refresh landed
/// mid-read: a cell still empty), with the reason in `torn`. Disk and network (Phase 5 Step 3) are the window's
/// current rates only, `{bytesPerSecond}` (null for an unreadable `—`), and `unattributedDisk` the same. A catch-all's
/// sub-group lines (Phase 5 Step 4) are its `subgroups` in the same shape (`pids` only when their members were read),
/// and each process carries `subgroup`: the sub-group it sits under, null for none.
func readTable(_ rows: [Row], repoView: Bool = true)
    -> (groups: [[String: Any]], processes: [[String: Any]], unattributed: Percent?, unattributedDisk: Any?)? {
    var groups: [[String: Any]] = [], processes: [[String: Any]] = [], unattributed: Percent?, unattributedDisk: Any?
    var current: (index: Int, name: String)?
    var currentSubgroup: (index: Int, name: String)?
    /// A group or sub-group line's figures, read from the cells `id` names; nil when one is missing (torn).
    func summary(_ row: Row, _ id: String, _ title: String) -> [String: Any]? {
        guard let cpu = row.texts["\(id)-cpu"].flatMap(firstPercent), let memory = row.texts["\(id)-memory"].flatMap(bytes),
              let count = row.texts["\(id)-count"].flatMap({ Int($0.split(separator: " ").first ?? "") }),
              let disk = rateCell(row.texts["disk-\(id)"]), let network = rateCell(row.texts["network-\(id)"]) else { return nil }
        let open = (attribute(row.element, "AXDisclosing") as? Bool) ?? false
        return ["name": title, "cpuPercent": cpu, "exitedChildrenCpuPercent": 0, "residentBytes": memory,
                "count": count, "open": open, "pids": NSNull(), "disk": disk, "network": network]
    }
    for row in rows {
        let level = (attribute(row.element, "AXDisclosureLevel") as? Int) ?? 0
        if let (id, title) = groupCell(row) {
            guard var group = summary(row, id, title) else {
                torn = "group row \(id) reads \(row.texts)"
                return nil
            }
            group["subgroups"] = [[String: Any]]()
            groups.append(group)
            current = (groups.count - 1, title)
            currentSubgroup = nil
        } else if let (id, name) = subgroupCell(row) {
            guard let current else { torn = "sub-group \(id) sits under no group"; return nil }
            guard let subgroup = summary(row, id, name) else {
                torn = "sub-group row \(id) reads \(row.texts)"
                return nil
            }
            var list = groups[current.index]["subgroups"] as! [[String: Any]]
            list.append(subgroup)
            groups[current.index]["subgroups"] = list
            currentSubgroup = (list.count - 1, name)
        } else if let pidText = row.texts.first(where: { $0.key.hasPrefix("process-") })?.value, let pid = Int(pidText) {
            // A process one level in is a group's member or a catch-all's lifted bare row; two levels in, a sub-group's.
            if level < 2 { currentSubgroup = nil }
            guard let current else { torn = "process \(pid) sits under no group"; return nil }
            guard let cpu = row.texts["cpu-\(pid)"].flatMap(firstPercent), let memory = row.texts["memory-\(pid)"].flatMap(bytes),
                  let disk = rateCell(row.texts["disk-\(pid)"]), let network = rateCell(row.texts["network-\(pid)"]) else {
                torn = "process row \(pid) reads \(row.texts)"
                return nil
            }
            var process: [String: Any] = ["pid": pid, "name": row.texts["name-\(pid)"] ?? "", "cpuPercent": cpu,
                                          "exitedChildrenCpuPercent": row.texts["exited-\(pid)"].flatMap(firstPercent) ?? 0,
                                          "residentBytes": memory, "user": row.texts["user-\(pid)"] ?? "", "group": current.name,
                                          "subgroup": currentSubgroup.map { $0.name as Any } ?? NSNull(),
                                          "disk": disk, "network": network]
            let readable = row.texts["readable-name-\(pid)"].map { String($0.dropFirst().dropLast()) }   // "(…)"
            process["readableName"] = readable ?? NSNull()
            process["paused"] = row.texts["paused-\(pid)"] != nil    // the badge (Phase 5 Step 5)
            process["vm"] = readable.flatMap(vm) ?? NSNull()
            let session = row.texts["session-\(pid)"] ?? ""
            process["session"] = session.isEmpty ? NSNull() : ["name": session]
            let worktree = row.texts["worktree-\(pid)"].map { String($0.dropFirst("[worktree ".count).dropLast()) }
            process["repo"] = repoView ? ["name": current.name, "worktree": worktree.map { $0 as Any } ?? NSNull()] as [String: Any]
                                       : NSNull()
            processes.append(process)
            groups[current.index]["pids"] = ((groups[current.index]["pids"] as? [Int]) ?? []) + [pid]
            if let currentSubgroup {
                var list = groups[current.index]["subgroups"] as! [[String: Any]]
                list[currentSubgroup.index]["pids"] = ((list[currentSubgroup.index]["pids"] as? [Int]) ?? []) + [pid]
                groups[current.index]["subgroups"] = list
            }
        } else if let value = row.texts["unattributed"] {
            unattributed = firstPercent(value)
            unattributedDisk = rateCell(row.texts["disk-unattributed"])
        }
    }
    return (groups, processes, unattributed, unattributedDisk)
}

/// "VM: colima · 4 cores · 12.3% of its cores" as the CLI's `vm` object.
func vm(_ readable: String) -> [String: Any]? {
    let regex = try! NSRegularExpression(pattern: #"^VM: (.*) · ([0-9]+) cores · ([0-9]+(\.[0-9]+)?)% of its cores$"#)
    guard let m = regex.firstMatch(in: readable, range: NSRange(readable.startIndex..., in: readable)) else { return nil }
    func group(_ i: Int) -> String { String(readable[Range(m.range(at: i), in: readable)!]) }
    return ["name": group(1), "vcpus": Int(group(2))!, "shareOfAllotted": NSDecimalNumber(string: group(3))]
}

/// The group rows alone, as `readTable` gives them; nil when torn.
func groups(_ table: AXUIElement) -> [[String: Any]]? { readTable(tableRows(table, members: { _ in false }))?.groups }

/// Opens (or closes) the group rows named in `names`, then waits up to 10 s for the table to show it.
func setOpen(_ names: Set<String>, _ open: Bool, in table: AXUIElement) {
    for row in tableRows(table, members: { _ in false }) {
        guard let title = groupTitle(row), names.contains(title), (attribute(row.element, "AXDisclosing") as? Bool) != open else { continue }
        guard AXUIElementSetAttributeValue(row.element, "AXDisclosing" as CFString, open as CFBoolean) == .success else {
            fail("cannot \(open ? "open" : "close") group '\(title)'")
        }
    }
    // Opening "System and other users" draws ~800 rows; the table can take seconds to show them.
    for _ in 0..<100 {
        let shown = (groups(table) ?? []).filter { names.contains($0["name"] as! String) }
        if shown.count == names.count && shown.allSatisfy({ $0["open"] as! Bool == open }) { return }
        Thread.sleep(forTimeInterval: 0.1)
    }
    fail("groups \(names.sorted()) did not turn open=\(open)")
}

/// The picker's segments in order, as `ProcessTable.Grouping` lists them. By place, not text: the segments read
/// "Repo", "Sesh", "Cmd" since Phase 6 Step 4, and a segment carries no label of its own.
let groupingKeys = ["repo", "session", "command"]

/// Which grouping the toolbar picker shows: "repo", "session" or "command".
func grouping(_ found: Identified) -> (current: String, buttons: [String: AXUIElement]) {
    let picker = required(found, "grouping")
    var buttons: [String: AXUIElement] = [:]
    var current = ""
    func walk(_ e: AXUIElement, depth: Int = 0) {
        if attribute(e, kAXRoleAttribute) as? String == kAXRadioButtonRole {
            guard buttons.count < groupingKeys.count else { fail("the grouping picker has more than \(groupingKeys.count) segments") }
            let key = groupingKeys[buttons.count]
            buttons[key] = e
            if (attribute(e, kAXValueAttribute) as? Int) == 1 { current = key }
        }
        for child in children(e, depth: depth) { walk(child, depth: depth + 1) }
    }
    walk(picker)
    return (current, buttons)
}

// --- The toolbar's Pause (MonitorModel.paused): a paused window takes no samples and keeps its rows ---

/// The window this reader paused, so every way out can resume it; nil when it paused nothing.
var pausedWindow: AXUIElement?

/// Presses Pause / Resume until the window shows `paused` (its "Paused" label), waiting up to 2 s.
func setPaused(_ paused: Bool, in root: AXUIElement) {
    let found = identified(root)
    guard (found.elements["paused"] != nil) != paused else { return }
    guard AXUIElementPerformAction(required(found, "pause"), kAXPressAction as CFString) == .success else {
        fail("cannot press \(paused ? "Pause" : "Resume")")
    }
    for _ in 0..<20 {
        if (identified(root).elements["paused"] != nil) == paused { return }
        Thread.sleep(forTimeInterval: 0.1)
    }
    fail("the window did not turn \(paused ? "paused" : "running")")
}

/// Pauses the window for one read, unless the user already paused it.
func holdRefreshes(_ root: AXUIElement) {
    guard identified(root).elements["paused"] == nil else { return }
    setPaused(true, in: root)
    pausedWindow = root
}

/// Resumes the window if this reader paused it. Cleared first, so a failed Resume does not loop through `fail`.
func releaseRefreshes() {
    guard let root = pausedWindow else { return }
    pausedWindow = nil
    setPaused(false, in: root)
}

// Stopped mid-read: resume, then exit as the signal would. Handled off the main thread, which is busy reading.
let stopSignals: [DispatchSourceSignal] = [SIGINT, SIGTERM, SIGHUP].map { signo in
    signal(signo, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signo, queue: .global())
    source.setEventHandler {
        releaseRefreshes()
        exit(128 + signo)
    }
    source.resume()
    return source
}

func print(json: Any) {
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

// --- Layout (Phase 4 Step 4): frames through AXPosition / AXSize, top-left origin, y down ---

func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

func rectJSON(_ r: CGRect?) -> Any {
    guard let r else { return NSNull() }
    return ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
}

func setPosition(_ element: AXUIElement, _ point: CGPoint) {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point),
          AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success else { fail("cannot set the window's position") }
}

func setFullScreen(_ element: AXUIElement, _ on: Bool) {
    guard AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse) == .success else {
        fail("cannot \(on ? "enter" : "leave") full screen")
    }
}

func setSize(_ element: AXUIElement, _ size: CGSize) {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size),
          AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success else { fail("cannot set the window's size") }
}

/// The table's group rows (outline level 0 with a `group-<n>` cell) and how many of them are disclosed.
func groupCounts(_ table: AXUIElement) -> (groups: Int, open: Int) {
    var groups = 0, open = 0
    for element in (attribute(table, kAXRowsAttribute) as? [AXUIElement]) ?? [] {
        guard (attribute(element, "AXDisclosureLevel") as? Int) ?? 0 == 0 else { continue }
        var row = Row(element: element)
        func walk(_ e: AXUIElement, depth: Int = 0) {
            if let id = attribute(e, "AXIdentifier") as? String, id.hasPrefix("group-") { row.texts[id] = text(e) ?? "" }
            for child in children(e, depth: depth) { walk(child, depth: depth + 1) }
        }
        walk(element)
        guard groupCell(row) != nil else { continue }
        groups += 1
        if (attribute(element, "AXDisclosing") as? Bool) == true { open += 1 }
    }
    return (groups, open)
}

/// A button's title as the window shows it (SwiftUI exposes a toolbar button's label as its title or description).
func buttonTitle(_ element: AXUIElement) -> String {
    (attribute(element, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? (attribute(element, kAXDescriptionAttribute) as? String) ?? text(element) ?? ""
}

/// Every static text under `element` (the Cores row's children, for the legend check).
func texts(under element: AXUIElement, depth: Int = 0) -> [String] {
    var out: [String] = []
    if attribute(element, kAXRoleAttribute) as? String == kAXStaticTextRole, let t = text(element) { out.append(t) }
    for child in children(element, depth: depth) { out += texts(under: child, depth: depth + 1) }
    return out
}

/// The Disk and Network graph headers ("Disk · R 12.3 M/s · W 4.5 M/s", "Network · In 1.2 M/s · Out 340.0 K/s") as
/// `{diskTotal: {readBytesPerSecond, writeBytesPerSecond, windowStart, windowEnd}, networkTotal: {in…, out…, …}}`;
/// the window is when the app took the two machine reads behind the rates (the header's hint), null before its
/// first rates. nil, with the reason in `torn`, when a header is missing or does not parse.
func rates(_ found: Identified) -> [String: Any]? {
    func header(_ id: String, _ labels: (String, String), _ keys: (String, String)) -> [String: Any]? {
        guard let element = found.elements[id], let shown = text(element) else { torn = "no \(id)"; return nil }
        let parts = shown.components(separatedBy: " · ")
        guard parts.count == 3, parts[1].hasPrefix(labels.0 + " "), parts[2].hasPrefix(labels.1 + " "),
              let first = siBytes(String(parts[1].dropFirst(labels.0.count + 1))),
              let second = siBytes(String(parts[2].dropFirst(labels.1.count + 1))) else {
            torn = "\(id) reads '\(shown)'"
            return nil
        }
        let window = ((attribute(element, kAXHelpAttribute) as? String) ?? "").split(separator: " ")
        let stamps = window.count == 3 && window[0] == "window" ? (Double(window[1]), Double(window[2])) : (nil, nil)
        return [keys.0: first, keys.1: second, "windowStart": stamps.0 ?? NSNull(), "windowEnd": stamps.1 ?? NSNull()]
    }
    guard let disk = header("disk-total", ("R", "W"), ("readBytesPerSecond", "writeBytesPerSecond")),
          let network = header("network-total", ("In", "Out"), ("inBytesPerSecond", "outBytesPerSecond")) else { return nil }
    return ["diskTotal": disk, "networkTotal": network]
}

/// The CPU graph's last three headers (Phase 6 Step 2) — "Load · 5.12 4.80 4.31 · 18 CPUs", "User 30.1% · System
/// 12.2%", "Launched · 120/s" — as the CLI's JSON names them: `{loadAverage: {oneMinute, fiveMinutes, fifteenMinutes,
/// cpus}, userBusyPercent, systemBusyPercent, launchesPerSecond}`, a figure not read yet ("—") as null. nil, with the
/// reason in `torn`, when a header is missing or reads otherwise.
func machineFigures(_ found: Identified) -> [String: Any]? {
    func shown(_ id: String) -> [String]? {
        guard let text = found.elements[id].flatMap(text) else { torn = "no \(id)"; return nil }
        return text.components(separatedBy: " · ")
    }
    // Decimal, as `percent` reads, so the JSON carries 19.39 as the window shows it.
    func number(_ text: String) -> Any {
        Double(text) == nil ? NSNull() : NSDecimalNumber(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
    guard let load = shown("load-average"), let split = shown("cpu-split"), let launched = shown("launch-rate") else { return nil }
    let averages = load.count == 3 ? load[1].split(separator: " ").map(String.init) : []
    let cpus = load.count == 3 ? Int(load[2].replacingOccurrences(of: " CPUs", with: "")) : nil
    guard load.count == 3, load[0] == "Load", let cpus, split.count == 2, split[0].hasPrefix("User "),
          split[1].hasPrefix("System "), launched.count == 2, launched[0] == "Launched", launched[1].hasSuffix("/s") else {
        torn = "the headers read '\(load.joined(separator: " · "))', '\(split.joined(separator: " · "))', "
            + "'\(launched.joined(separator: " · "))'"
        return nil
    }
    let loadAverage: Any = averages.count == 3
        ? ["oneMinute": number(averages[0]), "fiveMinutes": number(averages[1]), "fifteenMinutes": number(averages[2]),
           "cpus": cpus] as [String: Any]
        : NSNull()
    // The Launched header's hint, "launches <count> pids <first> <last>": the shown rate's count and the two `ps` pids
    // it runs between, as the CLI's JSON `launches` carries them; null before the first rate.
    let hint = found.elements["launch-rate"].flatMap { attribute($0, kAXHelpAttribute) as? String }?
        .split(separator: " ").map(String.init) ?? []
    let launches: Any = hint.count == 5 && hint[0] == "launches" && hint[2] == "pids"
        ? ["count": Int(hint[1]) ?? NSNull(), "firstPid": Int(hint[3]) ?? NSNull(), "lastPid": Int(hint[4]) ?? NSNull()]
            as [String: Any]
        : NSNull()
    return ["loadAverage": loadAverage,
            "userBusyPercent": percent(String(split[0].dropFirst("User ".count))) ?? NSNull(),
            "systemBusyPercent": percent(String(split[1].dropFirst("System ".count))) ?? NSNull(),
            "launchesPerSecond": number(String(launched[1].dropLast(2))), "launches": launches]
}

/// The strips under the two graphs: `{disk: [{text, name, group, bytes}], network: […], diskEmpty, networkEmpty}`,
/// each row "<readable name or name> · <group> · <bytes>" split from the right (a readable name may hold " · ").
func strips(_ found: Identified) -> [String: Any] {
    var out: [String: Any] = [:]
    for kind in ["disk", "network"] {
        out[kind] = (0..<5).compactMap { i -> [String: Any]? in
            guard let shown = found.elements["\(kind)-top-\(i)"].flatMap(text) else { return nil }
            let parts = shown.components(separatedBy: " · ")
            guard parts.count >= 3 else { return ["text": shown, "name": NSNull(), "group": NSNull(), "bytes": NSNull()] }
            return ["text": shown, "name": parts.dropLast(2).joined(separator: " · "), "group": parts[parts.count - 2],
                    "bytes": siBytes(parts[parts.count - 1], suffix: "") ?? NSNull()]
        }
        out["\(kind)Empty"] = found.elements["\(kind)-top-empty"] != nil
    }
    return out
}

/// The graph row's cells (Backlog window-graph-area-space), by the name `open-graph` takes.
let sparkCells = ["cpu", "memory", "disk-network"]

/// The graph row: `{cells: {cpu: {text, open}, memory: …, "disk-network": …}, open: <cell or "none">}`; each cell's
/// text is its figures (`cpu-total`, `spark-memory-text`, `spark-disk-network-text`), `open` its AX value.
func spark(_ found: Identified) -> [String: Any] {
    let textIDs = ["cpu": "cpu-total", "memory": "spark-memory-text", "disk-network": "spark-disk-network-text"]
    var cells: [String: Any] = [:], open = "none"
    for name in sparkCells {
        guard let cell = found.elements["spark-\(name)"] else { continue }
        let isOpen = (attribute(cell, kAXValueAttribute) as? String) == "open"
        if isOpen { open = name }
        let shown: Any = found.elements[textIDs[name]!].flatMap(text) ?? NSNull()
        cells[name] = ["text": shown, "open": isOpen]
    }
    return ["cells": cells, "open": open]
}

/// The theme the window draws with (Backlog window-theme), from the graph row's `theme` label, "<shown> chosen
/// <chosen> <light|dark>": `theme`, the one shown, and `themeChosen`, the one picked in Settings — they differ while
/// the Mac's Increase contrast puts Two-colour on — and `appearance`, the window's. Null each when the label is
/// missing or reads otherwise.
func theme(_ found: Identified) -> [String: Any] {
    let label = found.elements["theme"].flatMap { attribute($0, kAXDescriptionAttribute) as? String } ?? ""
    let parts = label.split(separator: " ").map(String.init)
    guard parts.count == 4, parts[1] == "chosen" else {
        return ["theme": NSNull(), "themeChosen": NSNull(), "appearance": NSNull()]
    }
    return ["theme": parts[0], "themeChosen": parts[2], "appearance": parts[3]]
}

/// The Memory graph's header and strip (`memory-total`, `memory-top-<i>`: "<name> · <group> · 8.1G", the bytes as the
/// Memory column shows them), or null while it is closed.
func memory(_ found: Identified) -> Any {
    guard let total = found.elements["memory-total"].flatMap(text) else { return NSNull() }
    let top = (0..<5).compactMap { i -> [String: Any]? in
        guard let shown = found.elements["memory-top-\(i)"].flatMap(text) else { return nil }
        let parts = shown.components(separatedBy: " · ")
        guard parts.count >= 3 else { return ["text": shown, "name": NSNull(), "group": NSNull(), "bytes": NSNull()] }
        return ["text": shown, "name": parts.dropLast(2).joined(separator: " · "), "group": parts[parts.count - 2],
                "bytes": bytes(parts[parts.count - 1]) ?? NSNull()]
    }
    return ["total": total, "top": top]
}

/// The graphs' reads below need their graph open: says which, and exits 4, when it is closed.
func requireOpen(_ found: Identified, _ graph: String) {
    guard spark(found)["open"] as? String == graph else {
        fail("the \(graph) graph is closed — `open-graph \(graph)` first", code: 4)
    }
}

/// The open graph's text with its frames — each title, each spike name on a plot (`spike-name-<kind>-<i>`) and each
/// spike line at a graph's foot (`spike-<kind>-<i>`) — every pair that intersects by more than half a point each way,
/// and every title taller than one and a half lines of the headline font (the gate's round 1: names drawn over the
/// first title, a title wrapped to two lines, spike lines running under the next graph).
func graphText(_ found: Identified) -> [String: Any] {
    let headers: Set<String> = ["load-average", "cpu-split", "launch-rate", "disk-total", "network-total", "memory-total"]
    func frames(_ wanted: (String) -> Bool) -> [(id: String, frame: CGRect)] {
        found.elements.filter { wanted($0.key) }.compactMap { id, element in frame(element).map { (id, $0) } }
            .sorted { $0.id < $1.id }
    }
    let titles = frames { $0.hasPrefix("core-type-") || headers.contains($0) }
    let names = frames { $0.hasPrefix("spike-name-") }
    let lines = frames { $0.range(of: #"^spike-(cpu|disk|network)-[0-9]+$"#, options: .regularExpression) != nil }
    let all = titles + names + lines
    var overlaps: [String] = []
    for i in all.indices {
        for j in all.indices where j > i {
            let shared = all[i].frame.intersection(all[j].frame)
            if !shared.isNull, shared.width > 0.5, shared.height > 0.5 { overlaps.append("\(all[i].id) × \(all[j].id)") }
        }
    }
    let lineHeight = NSLayoutManager().defaultLineHeight(for: NSFont.preferredFont(forTextStyle: .headline))
    func json(_ items: [(id: String, frame: CGRect)]) -> [[String: Any]] {
        items.map { ["id": $0.id, "text": found.elements[$0.id].flatMap(text) ?? "", "frame": rectJSON($0.frame)] }
    }
    return ["titles": json(titles), "names": json(names), "lines": json(lines), "overlaps": overlaps,
            "tallTitles": titles.filter { $0.frame.height > lineHeight * 1.5 }.map { "\($0.id) \($0.frame.height) pt" },
            "lineHeight": lineHeight]
}

func layout(_ root: AXUIElement) -> [String: Any] {
    let found = identified(root)
    let table = table(root)
    let scroll = attribute(table, kAXParentAttribute).flatMap { $0 as! AXUIElement? }
    let scrollFrame = scroll.flatMap(frame), tableFrame = frame(table)
    let bar = scroll.flatMap { attribute($0, kAXHorizontalScrollBarAttribute) }.map { $0 as! AXUIElement }
    let barFrame = bar.flatMap(frame)
    var barAttributes: CFArray?
    if let bar { AXUIElementCopyAttributeNames(bar, &barAttributes) }
    let rows = (attribute(table, kAXRowsAttribute) as? [AXUIElement]) ?? []
    let vbar = scroll.flatMap { attribute($0, kAXVerticalScrollBarAttribute) }.map { $0 as! AXUIElement }
    // Cells are measured where the user would see them (an element scrolled out of view has no frame): the
    // first rows with the table scrolled to the top, the last row with it scrolled to the bottom (the vertical
    // scroll bar's AXValue is the 0…1 scroll position).
    func scrollTo(_ position: Double) {
        guard let vbar else { return }
        AXUIElementSetAttributeValue(vbar, kAXValueAttribute as CFString, position as CFNumber)
        Thread.sleep(forTimeInterval: 0.3)
    }
    func inside(_ row: CGRect?) -> Bool {
        guard let row, let scrollFrame else { return false }
        return row.maxY <= scrollFrame.maxY + 0.5 && row.minY >= scrollFrame.minY - 0.5
    }
    scrollTo(0)
    // Every identified cell of the first rows in view (up to twelve: the closed groups, or a group and its
    // first members), with its frame: a value is aligned when its cell starts inside its header column.
    var cells: [[String: Any]] = []
    /// Reads up to `wanted` rows in view from `start`, skipping rows already read.
    func read(from start: Int = 0, _ wanted: Int) {
        var wanted = wanted
        for row in rows[start...] where wanted > 0 {
            let rowFrame = frame(row)
            guard inside(rowFrame) else { continue }
            var ids: [[String: Any]] = []
            func walk(_ e: AXUIElement, depth: Int = 0) {
                if let id = attribute(e, "AXIdentifier") as? String, !id.isEmpty, let f = frame(e) {
                    ids.append(["id": id, "x": f.minX, "w": f.width])
                }
                for child in children(e, depth: depth) { walk(child, depth: depth + 1) }
            }
            walk(row)
            guard !ids.isEmpty else { continue }
            let first = ids[0]["id"] as! String
            guard !cells.contains(where: { (($0["cells"] as! [[String: Any]])[0]["id"] as! String) == first }) else { continue }
            cells.append(["level": (attribute(row, "AXDisclosureLevel") as? Int) ?? 0, "cells": ids, "frame": rectJSON(rowFrame)])
            wanted -= 1
        }
    }
    if !rows.isEmpty { read(12) }
    // The first sub-group line and the rows under it, scrolled into view, so its cells are held to the headers too
    // (Phase 5 Step 4); none while every catch-all is closed.
    let subgroups = subgroupRows(table)
    if let first = subgroups.first, let index = rows.firstIndex(where: { CFEqual($0, first.element) }),
       let rowHeight = frame(rows[0])?.height, let view = scrollFrame {
        // Scrolled so the row sits two rows below the view's top: the bar's value is the share of the scrollable
        // height, and the row's measured place corrects the guess (a refresh can add rows above it meanwhile).
        let scrollable = max(1, Double(rows.count) * rowHeight - view.height)
        var offset = max(0, Double(index - 2) * rowHeight)
        for _ in 0..<3 {
            scrollTo(min(1, offset / scrollable))
            guard let placed = frame(first.element), !inside(placed) else { break }
            offset = max(0, offset + placed.minY - (view.minY + 2 * rowHeight))
        }
        read(from: index, 3)
    }
    // The last row read fresh after the scroll: a refresh that lands between the two can add rows below the
    // one scrolled to, so up to three tries.
    var lastRow: CGRect?
    for _ in 0..<3 {
        scrollTo(1)
        lastRow = ((attribute(table, kAXRowsAttribute) as? [AXUIElement]) ?? []).last.flatMap(frame)
        if inside(lastRow) { break }
    }
    let lastVisible = inside(lastRow)
    let counts = groupCounts(table)
    let legend = found.elements["cores-row"].map { texts(under: $0).filter { $0.hasSuffix("%") } } ?? []
    let header = attribute(table, kAXHeaderAttribute) as! AXUIElement?
    let headers = header.map { texts(under: $0) + children($0).map(buttonTitle) } ?? []
    let columns: [[String: Any]] = header.map { children($0).map { ["title": buttonTitle($0), "x": frame($0)?.minX ?? -1, "w": frame($0)?.width ?? -1] } } ?? []
    // A sideways scroll: rows wider than the view, or a horizontal scroll bar in the tree. Full-width scroll bars (macOS
    // shows them while a mouse is connected, or always if the user chose so) sit beside the rows, so rows that run
    // under the vertical bar fit the view yet scroll sideways; the horizontal bar is in the tree only then (probe
    // 2026-10-21, this Mac on full-width bars: 755.5 pt rows in a 770 pt view had a 757 pt horizontal bar; fitted
    // rows had none). The 2026-10-20 note that the bar is always there was most likely read while rows overflowed.
    let sideways = (lastRow?.width ?? 0) > (scrollFrame?.width ?? 0) + 1 || bar != nil
    return ["window": rectJSON(frame(root)), "scrollView": rectJSON(scrollFrame), "table": rectJSON(tableFrame),
            "tableWiderThanView": (tableFrame?.width ?? 0) > (scrollFrame?.width ?? 0) + 1,
            "rowWiderThanView": sideways,
            "horizontalScrollBar": bar != nil, "horizontalScrollBarFrame": rectJSON(barFrame),
            "horizontalScrollBarAttributes": (barAttributes as? [String]) ?? [],
            "lastRow": rectJSON(lastRow), "lastRowVisible": lastVisible,
            "foldButton": found.elements["fold-all"].map(buttonTitle) ?? "", "openGroups": counts.open, "groups": counts.groups,
            "subgroups": subgroups.count, "openSubgroups": subgroups.filter(\.open).count,
            "legendTexts": legend, "memoryHeader": headers.contains("Memory"), "columns": columns, "rows": cells,
            // The rate headers and strips only while Disk & Network is open; `spark` says which graph is.
            "rates": spark(found)["open"] as? String == "disk-network" ? (rates(found) ?? ["unreadable": torn]) : NSNull(),
            "strips": spark(found)["open"] as? String == "disk-network" ? strips(found) : NSNull(),
            "spark": spark(found), "memory": memory(found), "graphText": graphText(found),
            // A toolbar item that does not fit goes to the overflow menu and leaves the AX tree (Backlog window-search).
            "searchField": found.elements["search-field"] != nil, "refreshButton": found.elements["refresh"] != nil]
}

/// What the toolbar keeps while the window is paused, its "Paused" label shown (Phase 6 Step 4: with the picker's third
/// segment, the picker and the search field fell into the overflow menu at the default width): `grouping`,
/// `searchField`. Pauses the window for the read and resumes it, unless it was already paused.
func pausedToolbar(_ root: AXUIElement) -> [String: Any] {
    holdRefreshes(root)
    Thread.sleep(forTimeInterval: 0.5)    // the toolbar re-lays its items around the label
    let found = identified(root)
    releaseRefreshes()
    return ["paused": found.elements["paused"] != nil, "grouping": found.elements["grouping"] != nil,
            "searchField": found.elements["search-field"] != nil]
}

// --- Quit, Force Quit, Pause and Resume (Phase 5 Step 5) ---

/// The table's row showing `pid` (its PID cell `process-<pid>`), among the rows shown: a closed group's members are
/// not rows. nil when no shown row has it.
func processRow(_ table: AXUIElement, pid: Int) -> AXUIElement? {
    tableRows(table, members: { _ in true }).first { $0.texts["process-\(pid)"] != nil }?.element
}

/// Each shown row as `order` prints it, from its first identified cell only (the Name cell), and each group's and
/// sub-group's count text by its title. A greyed process row (an ended process kept in place under a fixed sort,
/// `gone-name-<pid>`) reads `gone:<pid>:<name>`; a greyed group or sub-group row `gone-group:<title>` /
/// `gone-subgroup:<name>`.
func rowOrder(_ table: AXUIElement) -> (rows: [String], counts: [String: String]) {
    var counts: [String: String] = [:]
    let rows = ((attribute(table, kAXRowsAttribute) as? [AXUIElement]) ?? []).compactMap { row -> String? in
        guard let id = firstIdentifier(row) else { return nil }
        let shown = firstElement(row, id).flatMap(text) ?? ""
        if id.hasPrefix("group-") || isSubgroupID(id) {
            counts[shown] = firstElement(row, "\(id)-count").flatMap(text) ?? ""
            return "\(id.hasPrefix("group-") ? "group" : "subgroup"):\(shown)"
        }
        if id.hasPrefix("name-") { return "pid:\(id.dropFirst(5)):\(shown)" }
        if id.hasPrefix("gone-name-") { return "gone:\(id.dropFirst(10)):\(shown)" }
        // By title, as live groups: a greyed group's number moves when one above it leaves.
        if id.hasPrefix("gone-group-") { return "gone-group:\(shown)" }
        if id.hasPrefix("gone-"), isSubgroupID(String(id.dropFirst(5))) { return "gone-subgroup:\(shown)" }
        return id
    }
    return (rows, counts)
}

/// One key press posted to the app (its key window's focused field gets it); `text` replaces the key's character.
func press(key: CGKeyCode, text: String? = nil) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { fail("cannot make a key event") }
        if let text {
            let units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        event.postToPid(pid)
    }
}

/// The toolbar's search field (`search-field`), driven without taking the user's focus: Saur0n stays behind the app
/// the user is in, where key events do not reach its field. Cleared with Escape posted to Saur0n, as a user clears it —
/// `escape` true — which lands only while Saur0n is the active app; otherwise the field's value is emptied through
/// accessibility, `escape` false. Then `text` set as the field's value through accessibility, as dictation and
/// VoiceOver set it. Waits up to 3 s for the field to read `text`, then half a second for the table to follow.
func search(_ text: String) -> (value: String, escape: Bool?) {
    let field = required(identified(root), "search-field")
    func value() -> String { (attribute(field, kAXValueAttribute) as? String) ?? "" }
    func set(_ string: String) {
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, string as CFString) == .success else {
            fail("cannot set the search field's text")
        }
    }
    guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
        fail("cannot focus the search field")
    }
    Thread.sleep(forTimeInterval: 0.2)
    var escape: Bool?
    if !value().isEmpty {
        press(key: 53)    // Escape
        escape = wait(1, until: { value().isEmpty })
        if escape == false { set("") }
        guard wait(3, until: { value().isEmpty }) else { fail("the search field still reads '\(value())'") }
    }
    if !text.isEmpty { set(text) }
    guard wait(3, until: { value() == text }) else { fail("the search field reads '\(value())', not '\(text)'") }
    Thread.sleep(forTimeInterval: 0.5)
    return (value(), escape)
}

/// Polls `until` every 0.1 s for up to `seconds`; false when it never held.
func wait(_ seconds: Double, until: () -> Bool) -> Bool {
    for _ in 0..<Int(seconds * 10) {
        if until() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return until()
}

/// The menu bar's `menu` menu's item titled `title`, read without opening the menu; nil when there is none.
func menuItem(_ menu: String, _ title: String) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    guard let bar = attribute(app, kAXMenuBarAttribute).map({ $0 as! AXUIElement }),
          let barItem = children(bar).first(where: { attribute($0, kAXTitleAttribute) as? String == menu }) else { return nil }
    return children(barItem).flatMap(children).first { attribute($0, kAXTitleAttribute) as? String == title }
}

/// Selects `pid`'s row by setting the table's selected rows to it (probe 2026-10-21: settable on SwiftUI's `Table`),
/// presses the Process menu's item for `action` once it turns enabled (Phase 6 Step 7 moved Quit, Force Quit and
/// Pause / Resume from the toolbar to that menu and the row's context menu; the user, 2026-10-24: "yes"), waits for the
/// sheet and its connection read, reads it, then presses Cancel (`cancel`) or the confirm button and waits for the
/// sheet to close. A confirm that fails leaves the sheet open with its error: it is read, then cancelled.
func act(_ action: String, pid: Int, cancel: Bool) -> [String: Any] {
    let titles = ["quit": "Quit", "force-quit": "Force Quit", "pause": "Pause", "resume": "Resume"]
    guard let title = titles[action] else { fail("act takes quit, force-quit, pause or resume", code: 2) }
    let processTable = table(root)
    // A refresh can replace the row between finding and selecting it: find it again, up to five times.
    var selected = false
    for _ in 0..<5 where !selected {
        guard let row = processRow(processTable, pid: pid) else { fail("no shown row for pid \(pid) (is its group open?)") }
        selected = AXUIElementSetAttributeValue(processTable, kAXSelectedRowsAttribute as CFString, [row] as CFArray) == .success
    }
    guard selected else { fail("cannot select pid \(pid)'s row (5 tries)") }
    var button: AXUIElement?
    guard wait(3, until: {
        button = menuItem("Process", title)
        return button.map { (attribute($0, kAXEnabledAttribute) as? Bool) == true } ?? false
    }), let button else { fail("Process ▸ \(title) did not turn enabled after selecting pid \(pid)") }
    guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
        fail("cannot press Process ▸ \(title)")
    }
    var sheet = Identified()
    guard wait(5, until: { sheet = identified(root); return sheet.elements["sheet-title"] != nil }) else {
        fail("no sheet after pressing Process ▸ \(title)")
    }
    // "Used by" fills in once the socket read lands.
    _ = wait(10, until: { sheet = identified(root); return sheet.elements["used-by-reading"] == nil })
    func shown(_ id: String) -> String? { sheet.elements[id].flatMap(text) }
    func list(_ prefix: String) -> [[String: Any]] {
        (0...).lazy.map { shown("\(prefix)-\($0)") }.prefix { $0 != nil }.map { line -> [String: Any] in
            let parts = line!.components(separatedBy: " · ")
            return ["name": parts.dropLast().joined(separator: " · "), "kind": parts.last ?? ""]
        }
    }
    var result: [String: Any] = [
        "title": shown("sheet-title") ?? "", "subtitle": shown("sheet-subtitle") ?? "",
        "warning": shown("sheet-warning") ?? NSNull(), "alsoEndsHeading": shown("also-ends-heading") ?? NSNull(),
        "alsoEnds": list("also-ends"), "usedBy": list("used-by"), "nothingElse": sheet.elements["also-ends-none"] != nil,
        "usedByUnreadable": sheet.elements["used-by-unreadable"] != nil, "keepAlive": sheet.elements["keep-alive"] != nil,
        "confirmTitle": sheet.elements["confirm-action"].map(buttonTitle) ?? "", "cancelled": cancel,
        "error": shown("action-error") ?? NSNull(),
    ]
    func press(_ id: String) {
        guard let element = identified(root).elements[id], AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            fail("cannot press \(id)")
        }
    }
    press(cancel ? "cancel-action" : "confirm-action")
    let closed = wait(5, until: { identified(root).elements["sheet-title"] == nil })
    if !closed {
        // Confirmed and refused: the sheet shows why; read it, then close the sheet.
        result["error"] = identified(root).elements["action-error"].flatMap(text) ?? "the sheet stayed open"
        result["admin"] = identified(root).elements["admin-action"] != nil
        press("cancel-action")
        guard wait(5, until: { identified(root).elements["sheet-title"] == nil }) else { fail("the sheet did not close") }
    }
    return result
}

/// Presses bar line `line`'s Stop…, waits for the sheet, reads exactly what it lists — the heading, every target
/// (`target-<i>`: "<name> · pid <n>") and every process left running (`spared-<i>`: "<name> · <kind> · pid <n>") — then
/// presses Cancel (`cancel`) or the confirm button and waits for the sheet to close. A confirm that fails leaves the
/// sheet open with its error: it is read, then cancelled.
func stopSheet(line: Int, cancel: Bool) -> [String: Any] {
    guard let stop = identified(root).elements["warning-stop-\(line)"],
          AXUIElementPerformAction(stop, kAXPressAction as CFString) == .success else { fail("cannot press warning-stop-\(line)") }
    var sheet = Identified()
    guard wait(5, until: { sheet = identified(root); return sheet.elements["sheet-title"] != nil }) else {
        fail("no sheet after pressing warning-stop-\(line)")
    }
    func shown(_ id: String) -> String? { sheet.elements[id].flatMap(text) }
    func lines(_ prefix: String) -> [String] { (0...).lazy.map { shown("\(prefix)-\($0)") }.prefix { $0 != nil }.map { $0! } }
    // The sheet groups digits ("pid 95,201").
    func pid(_ line: String) -> Int? { line.components(separatedBy: "pid ").last.flatMap { Int($0.replacingOccurrences(of: ",", with: "")) } }
    let targets = lines("target"), spared = lines("spared")
    var result: [String: Any] = [
        "title": shown("sheet-title") ?? "", "subtitle": shown("sheet-subtitle") ?? "",
        "targetsHeading": shown("targets-heading") ?? NSNull(), "targets": targets, "targetPids": targets.compactMap(pid),
        "sparedHeading": shown("spared-heading") ?? NSNull(), "spared": spared, "sparedPids": spared.compactMap(pid),
        "confirmTitle": sheet.elements["confirm-action"].map(buttonTitle) ?? "", "cancelled": cancel,
        "error": shown("action-error") ?? NSNull(),
    ]
    func press(_ id: String) {
        guard let element = identified(root).elements[id], AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            fail("cannot press \(id)")
        }
    }
    press(cancel ? "cancel-action" : "confirm-action")
    if !wait(5, until: { identified(root).elements["sheet-title"] == nil }) {
        result["error"] = identified(root).elements["action-error"].flatMap(text) ?? "the sheet stayed open"
        press("cancel-action")
        guard wait(5, until: { identified(root).elements["sheet-title"] == nil }) else { fail("the sheet did not close") }
    }
    return result
}

/// The shown rows the table has selected, each by its first identifier (`name-<pid>` for a process row). The
/// Process menu acts on the selection, so it must stay on the process selected while the table re-sorts (Phase 6
/// Step 7's demo; the user, 2026-10-24: "i selected Resilio, but it cycled as the list got reordered").
func selectedRows(_ table: AXUIElement) -> [String] {
    ((attribute(table, kAXSelectedRowsAttribute) as? [AXUIElement]) ?? []).compactMap { firstIdentifier($0) }
}

// --- The warning bar (Phase 6 Step 6) ---

/// The bar's lines (`warning-<i>`): text, the buttons' titles (null when the line has none), the conditions Details
/// shows and any error; and the first five group rows in order, each with whether it carries the warning badge
/// (`warned-group-<n>`). Each line's `pids` come from its container's identifier (`warning-pids-<i>:<pid>,…`; null when
/// none is found), with `spoken`: that container's title, description, value and help, what VoiceOver would read.
/// Read without pausing.
func warnings(_ root: AXUIElement) -> [String: Any] {
    let found = identified(root)
    func shown(_ id: String) -> String? { found.elements[id].flatMap(text) }
    func title(_ id: String) -> Any { found.elements[id].map(buttonTitle) ?? NSNull() }
    let lines = (0...).lazy.map { i in shown("warning-\(i)").map { (i, $0) } }.prefix { $0 != nil }.map { entry -> [String: Any] in
        let (i, text) = entry!
        let conditions = (0...).lazy.map { shown("warning-condition-\(i)-\($0)") }.prefix { $0 != nil }.map { $0! }
        let prefix = "warning-pids-\(i):"
        let container = found.elements.first { $0.key.hasPrefix(prefix) }
        let pids: Any = container.map { $0.key.dropFirst(prefix.count).split(separator: ",").compactMap { Int($0) } } ?? NSNull()
        let spoken = container.map { element in
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute].compactMap {
                attribute(element.value, $0 as String).map { "\($0)" }
            }.joined(separator: " ")
        }
        return ["text": text, "details": title("warning-details-\(i)"), "pause": title("warning-pause-\(i)"),
                "stop": title("warning-stop-\(i)"), "ignore": title("warning-ignore-\(i)"),
                "conditions": Array(conditions), "error": shown("warning-error-\(i)") ?? NSNull(),
                "pids": pids, "spoken": spoken ?? NSNull()]
    }
    // Only the first rows: By command holds hundreds of groups, and reading each row costs ~15 ms.
    let rows = ((attribute(table(root), kAXRowsAttribute) as? [AXUIElement]) ?? []).prefix(12)
    let groups = rows.compactMap { element -> [String: Any]? in
        guard let id = firstIdentifier(element), id.hasPrefix("group-"), Int(id.dropFirst(6)) != nil else { return nil }
        return ["id": id, "title": firstElement(element, id).flatMap(text) ?? "",
                "warned": firstElement(element, "warned-\(id)") != nil]
    }
    return ["lines": Array(lines), "groups": Array(groups.prefix(5)), "refresh": refreshCount(found)]
}

/// The element identified `id`, in the window or under a group row of the table (a Name cell's badge).
func element(_ root: AXUIElement, _ id: String) -> AXUIElement? {
    if let found = identified(root).elements[id] { return found }
    for row in (attribute(table(root), kAXRowsAttribute) as? [AXUIElement]) ?? [] {
        if let found = firstElement(row, id) { return found }
    }
    return nil
}

/// WCAG 2's contrast of two sRGB colours, 0–1 a channel.
func contrastRatio(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
    func luminance(_ c: (Double, Double, Double)) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2)
    }
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// For each `id`, the colours inside its frame grown by `margin` points, from one capture of the app's window by its
/// window id (`screencapture -l`: no focus taken, lesson window-probes-never-take-focus): the most common colour as
/// the background and the colour that differs most from it as the figure or glyph, with their contrast.
func contrast(_ root: AXUIElement, ids: [String], margin: CGFloat) -> [String: Any] {
    let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    let mine = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    func bounds(_ info: [String: Any]) -> CGRect {
        (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
    }
    guard let main = mine.max(by: { bounds($0).width * bounds($0).height < bounds($1).width * bounds($1).height }),
          let number = main[kCGWindowNumber as String] as? Int else { fail("no on-screen window to capture") }
    let path = NSTemporaryDirectory() + "saur0n-contrast-\(getpid()).png"
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(number), path]
    do { try capture.run() } catch { fail("cannot start screencapture: \(error)") }
    capture.waitUntilExit()
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard capture.terminationStatus == 0, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("screencapture failed — grant this terminal Screen Recording in System Settings")
    }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot read the capture") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let window = bounds(main), scale = CGFloat(width) / max(window.width, 1)
    var out: [String: Any] = ["scale": scale]
    for id in ids {
        guard let element = element(root, id), let rect = frame(element)?.insetBy(dx: -margin, dy: -margin) else {
            out[id] = NSNull()
            continue
        }
        let x0 = max(0, Int((rect.minX - window.minX) * scale)), x1 = min(width, Int((rect.maxX - window.minX) * scale))
        let y0 = max(0, Int((rect.minY - window.minY) * scale)), y1 = min(height, Int((rect.maxY - window.minY) * scale))
        var counts: [UInt32: Int] = [:]
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) {
                let i = (y * width + x) * 4
                counts[UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]), default: 0] += 1
            }
        }
        func rgb(_ v: UInt32) -> (Double, Double, Double) {
            (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key,
              let figure = counts.keys.max(by: { contrastRatio(rgb($0), rgb(background)) < contrastRatio(rgb($1), rgb(background)) })
        else {
            out[id] = NSNull()
            continue
        }
        out[id] = ["background": String(format: "#%06x", background), "figure": String(format: "#%06x", figure),
                   "ratio": (contrastRatio(rgb(figure), rgb(background)) * 100).rounded() / 100]
    }
    return out
}

/// The Dock's item (the Dock is `pid` here) for the app bundle at `path`, matched by its `AXURL`, not its title — an
/// installed Saur0n may sit in the Dock beside the checked one: {found, label (the badge, `AXStatusLabel`; null when
/// none), running}. Read from the Dock's own accessibility, so it works after the app has quit (Phase 6 Step 9).
func dockBadge(bundle path: String) -> [String: Any] {
    let want = URL(fileURLWithPath: path).standardizedFileURL.path
    for list in children(AXUIElementCreateApplication(pid)) {
        for item in children(list) {
            guard let url = attribute(item, "AXURL") as? URL, url.standardizedFileURL.path == want else { continue }
            return ["found": true, "label": (attribute(item, "AXStatusLabel") as? String).map { $0 as Any } ?? NSNull(),
                    "running": (attribute(item, "AXIsApplicationRunning") as? Bool) ?? false]
        }
    }
    return ["found": false, "label": NSNull(), "running": false]
}

if command == "dock-badge" {
    guard let path = args.dropFirst(2).first else { fail("dock-badge <bundle path>  (the pid is the Dock's)", code: 2) }
    print(json: dockBadge(bundle: path))
    exit(0)
}

let root = window()

switch command {
case "warnings":
    print(json: warnings(root))

case "warning-press":
    // Presses a bar line's button: warning-press <i> <details|pause|stop|ignore>.
    let rest = Array(args.dropFirst(2))
    guard rest.count == 2, let i = Int(rest[0]), ["details", "pause", "stop", "ignore"].contains(rest[1]) else {
        fail("warning-press <i> <details|pause|stop|ignore>", code: 2)
    }
    let id = "warning-\(rest[1])-\(i)"
    guard let button = identified(root).elements[id], AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
        fail("cannot press \(id)")
    }
    print(json: ["pressed": id])

case "warning-stop-sheet":
    // warning-stop-sheet <i> [--cancel]: presses the bar's Stop…, reads the sheet's targets and spared, then confirms
    // (or cancels): prints the sheet as JSON.
    let rest = Array(args.dropFirst(2))
    guard rest.count == 1 || (rest.count == 2 && rest[1] == "--cancel"), let i = Int(rest[0]) else {
        fail("warning-stop-sheet <i> [--cancel]", code: 2)
    }
    print(json: stopSheet(line: i, cancel: rest.count == 2))

case "contrast":
    // contrast [--margin <points>] <id>…: background, figure and their contrast inside each element's frame.
    var rest = Array(args.dropFirst(2)), margin: CGFloat = 1
    if rest.first == "--margin", rest.count > 1, let points = Double(rest[1]) {
        margin = CGFloat(points)
        rest.removeFirst(2)
    }
    guard !rest.isEmpty else { fail("contrast [--margin <points>] <id>…", code: 2) }
    print(json: contrast(root, ids: rest, margin: margin))

case "act":
    let rest = Array(args.dropFirst(2))
    guard rest.count == 2 || (rest.count == 3 && rest[2] == "--cancel"), let target = Int(rest[1]) else {
        fail("act <quit|force-quit|pause|resume> <pid> [--cancel]", code: 2)
    }
    print(json: act(rest[0], pid: target, cancel: rest.count == 3))

case "select":
    // select <pid>: selects its row as `act` does; prints {"selected": [<first identifiers>]}.
    guard let target = args.dropFirst(2).first.flatMap(Int.init) else { fail("select <pid>", code: 2) }
    let processTable = table(root)
    guard let row = processRow(processTable, pid: target) else { fail("no shown row for pid \(target) (is its group open?)") }
    guard AXUIElementSetAttributeValue(processTable, kAXSelectedRowsAttribute as CFString, [row] as CFArray) == .success else {
        fail("cannot select pid \(target)'s row")
    }
    print(json: ["selected": selectedRows(processTable)])

case "selected":
    // The selected rows now: {"selected": [<first identifiers>]}, read without pausing.
    print(json: ["selected": selectedRows(table(root))])

case "row":
    // One process's row as `rows` shows it, read from the shown rows without opening any group, paused for the read:
    // {"row": {…} or null, "refresh": n}.
    guard let target = args.dropFirst(2).first.flatMap(Int.init) else { fail("row <pid>", code: 2) }
    holdRefreshes(root)
    let processTable = table(root)
    let picker = grouping(identified(root)).current
    var read: (groups: [[String: Any]], processes: [[String: Any]], unattributed: Percent?, unattributedDisk: Any?)?
    for _ in 0..<5 where read == nil {
        read = readTable(tableRows(processTable, members: { _ in true }), repoView: picker == "repo")
    }
    let refresh = refreshCount(identified(root))
    releaseRefreshes()
    guard let read else { fail("the table read half-drawn 5 times: \(torn)") }
    let found: Any = read.processes.first { $0["pid"] as? Int == target } ?? NSNull()
    print(json: ["row": found, "refresh": refresh])

case "state":
    let found = identified(root)
    let windows = (attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
    let processTable = table(root)
    let counts = groupCounts(processTable)
    let subgroups = subgroupRows(processTable)
    print(json: ["coresOpen": found.elements.keys.contains { $0.hasPrefix("core-column-") }, "windows": windows.count,
                 "paused": found.elements["paused"] != nil,
                 "refresh": found.elements["cpu-total"] == nil ? 0 : refreshCount(found),
                 "openGroups": counts.open, "groups": counts.groups,
                 "subgroups": subgroups.count, "openSubgroups": subgroups.filter(\.open).count,
                 "foldButton": found.elements["fold-all"].map(buttonTitle) ?? "",
                 "openGraph": spark(found)["open"] ?? NSNull()].merging(theme(found)) { a, _ in a })

case "spark":
    print(json: spark(identified(root)))

case "open-graph":
    // Presses cells until the wanted graph is open (or none is), then waits up to 2 s for the window to show it.
    guard let wanted = args.dropFirst(2).first, sparkCells.contains(wanted) || wanted == "none" else {
        fail("open-graph takes \(sparkCells.joined(separator: ", ")) or none", code: 2)
    }
    if let open = spark(identified(root))["open"] as? String, open != wanted {
        let cell = required(identified(root), "spark-\(wanted == "none" ? open : wanted)")
        guard AXUIElementPerformAction(cell, kAXPressAction as CFString) == .success else { fail("cannot press the \(wanted) cell") }
    }
    guard wait(2, until: { spark(identified(root))["open"] as? String == wanted }) else {
        fail("the graph row did not open \(wanted): \(spark(identified(root)))")
    }
    print(json: spark(identified(root)))

case "press-cores":
    requireOpen(identified(root), "cpu")
    let row = required(identified(root), "cores-row")
    guard AXUIElementPerformAction(row, kAXPressAction as CFString) == .success else { fail("cannot press cores-row") }

case "fold":
    let button = required(identified(root), "fold-all")
    guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { fail("cannot press fold-all") }

case "sort":
    guard let title = args.dropFirst(2).first else { fail("sort <column title>", code: 2) }
    let header = attribute(table(root), kAXHeaderAttribute).map { $0 as! AXUIElement }
    guard let column = header.flatMap({ children($0).first { buttonTitle($0) == title } }) else { fail("no column header '\(title)'") }
    guard AXUIElementPerformAction(column, kAXPressAction as CFString) == .success else { fail("cannot press the '\(title)' header") }

case "order":
    // Paused for the read, so it is one refresh's order; the caller reads again after the next refresh.
    holdRefreshes(root)
    let refresh = refreshCount(identified(root))
    let order = rowOrder(table(root))
    releaseRefreshes()
    print(json: ["refresh": refresh, "rows": order.rows, "counts": order.counts])

case "refresh":
    // Presses the toolbar's Refresh (`refresh`) and waits up to 5 s for the next refresh; with --paused, pauses the
    // window first and, after that refresh, watches 2 s more for another (a paused window takes the one reading only):
    // {"before": n, "after": n, "later": n, "paused": bool, "seconds": s} — `later` and `paused` read 2 s after.
    let whilePaused = args.dropFirst(2).first == "--paused"
    guard args.count == 2 || (args.count == 3 && whilePaused) else { fail("refresh [--paused]", code: 2) }
    if whilePaused { holdRefreshes(root) }
    let before = refreshCount(identified(root))
    let start = Date()
    guard AXUIElementPerformAction(required(identified(root), "refresh"), kAXPressAction as CFString) == .success else {
        releaseRefreshes()
        fail("cannot press refresh")
    }
    var after = before
    _ = wait(5, until: { after = refreshCount(identified(root)); return after > before })
    let seconds = Date().timeIntervalSince(start)
    var result: [String: Any] = ["before": before, "after": after, "seconds": (seconds * 100).rounded() / 100]
    if whilePaused {
        Thread.sleep(forTimeInterval: 2)
        let found = identified(root)
        result["later"] = refreshCount(found)
        result["paused"] = found.elements["paused"] != nil
        releaseRefreshes()
    }
    print(json: result)

case "search":
    guard let text = args.dropFirst(2).first else { fail("search <text> | search --clear", code: 2) }
    let result = search(text == "--clear" ? "" : text)
    print(json: ["search": result.value, "escape": result.escape.map { $0 as Any } ?? NSNull()])

case "layout":
    let option = Array(args.dropFirst(2))
    let size: CGSize? = switch option.first {
    // The app's own minimum: asked for 1 × 1, the window stops at its minimum size, which follows the user's column
    // widths (802 × 580 at the defaults; Backlog resizable-columns). `window` in the result is that size.
    case "--min": CGSize(width: 1, height: 1)
    case "--wide": CGSize(width: CGDisplayBounds(CGMainDisplayID()).width, height: 700)
    case "--size":
        if option.count == 3, let w = Double(option[1]), let h = Double(option[2]) { CGSize(width: w, height: h) }
        else { fail("layout --size takes <width> <height>", code: 2) }
    case nil: nil
    default: fail("layout takes --min, --wide or --size <width> <height>", code: 2)
    }
    if let size {
        // A window that opened into a full-screen space (macOS puts a second copy of an app beside a tiled first
        // one, probe 2026-10-21) cannot be moved or widened past its tile: leave the space first. The window is
        // the check's own, so the space is not restored.
        if attribute(root, "AXFullScreen") as? Bool == true {
            setFullScreen(root, false)
            Thread.sleep(forTimeInterval: 2.5)    // past the animation
        }
        guard let before = frame(root) else { fail("cannot read the window's frame") }
        // From the screen's top-left corner, so a wide size is not clamped by the screen's right edge.
        setPosition(root, CGPoint(x: 0, y: 0))
        setSize(root, size)
        Thread.sleep(forTimeInterval: 1.5)    // past one refresh, so the table has re-laid its columns
        var result = layout(root)
        result["pausedToolbar"] = pausedToolbar(root)
        setPosition(root, before.origin)
        setSize(root, before.size)
        print(json: result)
    } else {
        var result = layout(root)
        result["pausedToolbar"] = pausedToolbar(root)
        print(json: result)
    }

case "graph-text":
    print(json: graphText(identified(root)))

case "rates":
    let found = identified(root)
    requireOpen(found, "disk-network")
    guard var result = rates(found) else { fail("the graph headers read wrong: \(torn)") }
    result["refresh"] = refreshCount(found)
    result["at"] = Date().timeIntervalSince1970
    print(json: result)

case "strips":
    let found = identified(root)
    requireOpen(found, "disk-network")
    print(json: strips(found))

case "load":
    let found = identified(root)
    requireOpen(found, "cpu")
    guard var result = machineFigures(found) else { fail("the CPU graph's figures read wrong: \(torn)") }
    result["refresh"] = refreshCount(found)
    result["at"] = Date().timeIntervalSince1970
    print(json: result)

case "memory":
    let found = identified(root)
    requireOpen(found, "memory")
    print(json: memory(found))

case "totals":
    guard let n = args.dropFirst(2).first.flatMap(Int.init), n > 0 else { fail("totals takes a count", code: 2) }
    var totals: [Percent] = []
    for i in 0..<n {
        if i > 0 { Thread.sleep(forTimeInterval: 1) }
        totals.append(total(identified(root)))
    }
    print(json: ["totals": totals])

case "json":
    requireOpen(identified(root), "cpu")
    // Paused, no refresh lands mid-read; still read until the total and every core read the same before and
    // after, for a window the user paused while it was being drawn.
    holdRefreshes(root)
    for _ in 0..<5 {
        let found = identified(root)
        let columns = found.elements.keys.filter { $0.hasPrefix("core-column-") }
        guard !columns.isEmpty else { fail("the Cores row is closed (press-cores first)") }
        let before = total(found)
        // core-<N> → (level, column) through its column container's identifier core-column-<level>-<k>.
        var cpusByLevel: [Int: [Int]] = [:]
        var columnSizes: [Int: [Int: Int]] = [:]
        var busy: [Int: Percent] = [:]
        for (id, element) in found.elements {
            guard id.hasPrefix("core-"), let cpu = Int(id.dropFirst("core-".count)) else { continue }
            guard let column = found.parents[id], column.hasPrefix("core-column-") else { fail("\(id) sits in no core column") }
            let parts = column.split(separator: "-")
            guard parts.count == 4, let level = Int(parts[2]), let k = Int(parts[3]) else { fail("bad column id \(column)") }
            guard let value = text(element).flatMap(percent) else { fail("\(id) reads '\(text(element) ?? "")'") }
            cpusByLevel[level, default: []].append(cpu)
            columnSizes[level, default: [:]][k, default: 0] += 1
            busy[cpu] = value
        }
        var coreTypes: [[String: Any]] = []
        for level in cpusByLevel.keys.sorted() {
            let header = required(found, "core-type-\(level)")
            guard let headerText = text(header), let average = percent(headerText),
                  let name = headerText.components(separatedBy: " · ").first else {
                fail("core-type-\(level) reads '\(text(header) ?? "")'")
            }
            let cpus = cpusByLevel[level]!.sorted()
            coreTypes.append(["level": level, "name": name, "cpus": cpus,
                              "busyPercent": cpus.map { busy[$0]! }, "averageBusyPercent": average,
                              "columns": columnSizes[level]!.keys.sorted().map { columnSizes[level]![$0]! }])
        }
        let again = identified(root)
        let after = total(again)
        let steady = cpusByLevel.values.joined().allSatisfy { cpu in
            again.elements["core-\(cpu)"].flatMap(text).flatMap(percent) == busy[cpu]
        }
        if before == after && steady {
            releaseRefreshes()
            print(json: ["totalBusyPercent": before, "coreTypes": coreTypes])
            exit(0)
        }
    }
    fail("the window refreshed during every one of 5 reads")

case "snapshot", "rows":
    // snapshot: one refresh's total, groups, unattributed line and the members of each --expand group. rows:
    // every member of every group, opening the closed ones; either opens the sub-groups too. Both read paused, so the whole read is one
    // refresh: the refresh count before and after must match, and a move fails the read (Pause did not
    // hold). A row read half-drawn (opened groups still drawing) is read again, at most 5 times. Either way
    // the groups this command opened are closed again, unless it fails while opening or reading them.
    holdRefreshes(root)
    var expand = Set<String>()
    var rest = args.dropFirst(2)
    while let flag = rest.popFirst() {
        guard command == "snapshot", flag == "--expand", let name = rest.popFirst() else { fail("snapshot [--expand <group>]…", code: 2) }
        expand.insert(name)
    }
    let processTable = table(root)
    var shown: [[String: Any]]?
    for _ in 0..<5 where shown == nil { shown = groups(processTable) }
    guard let shown else { fail("the table read half-drawn 5 times: \(torn)") }
    let names = Set(shown.map { $0["name"] as! String })
    if command == "rows" { expand = names }
    guard expand.isSubset(of: names) else { fail("no group named \(expand.subtracting(names).sorted())") }
    let opened = Set(shown.filter { expand.contains($0["name"] as! String) && !($0["open"] as! Bool) }.map { $0["name"] as! String })
    if !opened.isEmpty { setOpen(opened, true, in: processTable) }
    // A catch-all's sub-groups open with it, so every member is read (Phase 5 Step 4).
    let openedSubgroups = setSubgroupsOpen(under: expand, true, in: processTable)
    let picker = grouping(identified(root)).current
    var result: [String: Any]?
    var tries = 0
    for _ in 0..<5 where result == nil {
        tries += 1
        let before = refreshCount(identified(root))
        guard let read = readTable(tableRows(processTable, members: expand.contains), repoView: picker == "repo") else { continue }
        let after = identified(root)
        guard refreshCount(after) == before else {
            guard pausedWindow == nil && after.elements["paused"] == nil else {
                fail("the window refreshed while paused (refresh \(before) → \(refreshCount(after)))")
            }
            torn = "refresh \(before) → \(refreshCount(after))"
            continue
        }
        result = ["refresh": before, "grouping": picker, "totalBusyPercent": total(after), "tries": tries,
                  picker == "session" ? "sessionGroups" : picker == "command" ? "commandGroups" : "repoGroups": read.groups,
                  "processes": read.processes, "unattributedCpuPercent": read.unattributed ?? NSNull(),
                  "unattributedDisk": read.unattributedDisk ?? NSNull()]
    }
    if !openedSubgroups.isEmpty { setSubgroupsOpen(under: expand, false, only: openedSubgroups, in: processTable) }
    if !opened.isEmpty { setOpen(opened, false, in: processTable) }
    releaseRefreshes()
    guard let result else { fail("5 reads each spanned a refresh or read half-drawn (last: \(torn))") }
    print(json: result)

case "group-by":
    guard let want = args.dropFirst(2).first, ["repo", "session", "command"].contains(want) else {
        fail("group-by repo|session|command", code: 2)
    }
    let picker = grouping(identified(root))
    guard picker.current != want else { exit(0) }
    guard let button = picker.buttons[want], AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
        fail("cannot press 'By \(want)'")
    }
    for _ in 0..<20 {
        if grouping(identified(root)).current == want { exit(0) }
        Thread.sleep(forTimeInterval: 0.1)
    }
    fail("the picker did not turn to 'By \(want)'")

case "settings":
    // Opens Settings through the app menu's "Settings…" (as ⌘, does), reads its theme choices and the high-contrast
    // box, presses the theme titled <title> when given, and reads the main window's theme after it.
    let app = AXUIElementCreateApplication(pid)
    func first(_ element: AXUIElement, depth: Int = 0, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(element) { return element }
        for child in children(element, depth: depth) {
            if let found = first(child, depth: depth + 1, where: match) { return found }
        }
        return nil
    }
    func settingsWindow() -> AXUIElement? {
        ((attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).first { attribute($0, kAXTitleAttribute) as? String == "General" }
    }
    if settingsWindow() == nil {
        guard let bar = attribute(app, kAXMenuBarAttribute).map({ $0 as! AXUIElement }),
              let item = first(bar, where: { attribute($0, kAXTitleAttribute) as? String == "Settings…" })
        else { fail("no Settings… item in the app menu") }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    }
    var settings: AXUIElement?
    for _ in 0..<30 where settings == nil {
        settings = settingsWindow()
        if settings == nil { Thread.sleep(forTimeInterval: 0.1) }
    }
    guard let settings else { fail("Settings… opened no window titled General") }
    // Each radio group's buttons by title, picked or not.
    func radios(_ id: String) -> [String: AXUIElement] {
        let buttons = (identified(settings).elements[id].map(children) ?? [])
            .filter { attribute($0, kAXRoleAttribute) as? String == kAXRadioButtonRole }
        return Dictionary(buttons.map { (buttonTitle($0), $0) }, uniquingKeysWith: { a, _ in a })
    }
    func read() -> (themes: [String: Bool], appearances: [String: Bool], box: Bool?) {
        func picked(_ id: String) -> [String: Bool] {
            radios(id).mapValues { (attribute($0, kAXValueAttribute) as? Int) == 1 }
        }
        let box = identified(settings).elements["settings-high-contrast"].flatMap { attribute($0, kAXValueAttribute) as? Int }
        return (picked("settings-theme"), picked("settings-appearance"), box.map { $0 == 1 })
    }
    if let wanted = args.dropFirst(2).first {
        let all = radios("settings-theme").merging(radios("settings-appearance")) { a, _ in a }
        guard let radio = all[wanted] else { fail("no theme or appearance titled '\(wanted)' in \(all.keys.sorted())") }
        AXUIElementPerformAction(radio, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.5)
    }
    let after = read()
    print(json: ["themes": after.themes, "appearances": after.appearances, "highContrast": after.box ?? NSNull(),
                 "window": theme(identified(root))] as [String: Any])

default:
    fail("unknown command '\(command)'", code: 2)
}
