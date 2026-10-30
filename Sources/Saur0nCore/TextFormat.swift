// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Number and text formatting shared by the core-type table, the process table and the JSON.
enum TextFormat {
    /// `value` to `places` decimals: one for every percentage shown, two for process CPU in JSON.
    static func rounded(_ value: Double, places: Int = 1) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    static func percentText(_ percent: Double) -> String { String(format: "%.1f%%", rounded(percent)) }

    /// A load average to two decimals, as `uptime` and `sysctl vm.loadavg` print it.
    static func loadText(_ load: Double) -> String { String(format: "%.2f", rounded(load, places: 2)) }

    /// SI units, as macOS shows storage (Finder and Activity Monitor since 10.6): `0`, `999 B/s`, then one decimal
    /// from 1 K up — `850.0 K/s`, `1.2 M/s`, `3.4 G/s`; a value that rounds to 1000 moves up a unit.
    static func bytesPerSecondText(_ bytesPerSecond: UInt64) -> String {
        if bytesPerSecond == 0 { return "0" }
        if bytesPerSecond < 1_000 { return "\(bytesPerSecond) B/s" }
        let units = ["K", "M", "G", "T"]
        var value = Double(bytesPerSecond) / 1_000, unit = 0
        while unit < units.count - 1, rounded(value) >= 1_000 {
            value /= 1_000
            unit += 1
        }
        return String(format: "%.1f %@/s", rounded(value), units[unit])
    }

    /// A byte count in the same SI units, shorter for the window's strips: `0`, `999 B`, one decimal under 10
    /// (`1.0 K`, `1.2 G`), whole from 10 up (`512 M`); a value that rounds to 1000 moves up a unit.
    static func bytesText(_ bytes: UInt64) -> String {
        if bytes == 0 { return "0" }
        if bytes < 1_000 { return "\(bytes) B" }
        let units = ["K", "M", "G", "T", "P"]
        var value = Double(bytes) / 1_000, unit = 0
        func shown(_ value: Double) -> Double { rounded(value) < 10 ? rounded(value) : value.rounded() }
        while unit < units.count - 1, shown(value) >= 1_000 {
            value /= 1_000
            unit += 1
        }
        let figure = shown(value)
        return figure < 10 ? String(format: "%.1f %@", figure, units[unit]) : String(format: "%.0f %@", figure, units[unit])
    }

    static func leftPad(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + text
    }

    /// A command group's title, escaped: `runaway.sh × 30`, the bare key for one copy (Phase 6 Step 4).
    static func copiesTitle(name: String, copies: Int) -> String {
        displaySafe(name) + (copies > 1 ? " × \(copies)" : "")
    }

    /// A warning line (Phase 6 Step 5): `! run.sh × 75  copies 75, up 75 in 5 min, 41.2% with what they started;
    /// system 54.0% of CPU time`. "!" is the Dock's warning badge, so the line carries the alarm without colour.
    static func warningText(_ warning: Warning) -> String {
        "! \(warning.name)  " + warning.conditions.map(conditionText).joined(separator: "; ")
    }

    /// The Unattributed line's hint (Phase 6 Step 8), from `launchdHintPercent` shown: `40 processes under launchd
    /// started in the last minute, most common: sleep × 40`, the name escaped; nil below it or with none new.
    static func launchdHint(_ newcomers: LaunchdNewcomers?, unattributedCpuPercent: Double) -> String? {
        guard let newcomers, newcomers.count > 0, rounded(unattributedCpuPercent) >= launchdHintPercent else { return nil }
        let processes = newcomers.count == 1 ? "1 process" : "\(newcomers.count) processes"
        return "\(processes) under launchd started in the last minute"
            + (newcomers.mostCommon.map { ", most common: " + copiesTitle(name: $0.name, copies: $0.count) } ?? "")
    }

    /// Where the hint starts: Unattributed CPU at rest reads 4.5–5.6% (research 2026-10-22, the live probe); a first
    /// guess, tuned at the demo as the warning thresholds are.
    static let launchdHintPercent = 5.0

    /// A `saur0n snapshots` line (Phase 6 Step 7): `2026-10-24 14:03:07  warning  run.sh × 30  CPU 96.1%  Unattributed
    /// 41.2%  1804 processes  38 K`; the detail escaped, left out when empty (Snapshot now).
    static func snapshotEntryText(_ entry: SnapshotLog.Entry, timeZone: TimeZone) -> String {
        ([SnapshotTime.text(entry.takenAt, timeZone: timeZone), entry.reason.rawValue]
         + (entry.detail.isEmpty ? [] : [displaySafe(entry.detail)])
         + ["CPU " + percentText(entry.cpuPercent)]
         + (entry.unattributedPercent.map { ["Unattributed " + percentText($0)] } ?? [])
         + ["\(entry.processes) processes", bytesText(UInt64(entry.bytes))]).joined(separator: "  ")
    }

    /// `available 8.1 G of 64 G  swap 1.2 G`: the CLI's Memory line (Phase 7 Step 2), swap left out when unread.
    static func availableMemoryText(_ memory: AvailableMemory) -> String {
        (["available \(bytesText(memory.availableBytes)) of \(bytesText(memory.physicalBytes))"]
         + (memory.swapUsedBytes.map { ["swap \(bytesText($0))"] } ?? [])).joined(separator: "  ")
    }

    /// A resource reading's CLI lines (Phase 7 Step 2): the level and its figures, then the ETA with the process that
    /// grew it, the notice's consumers, the triage's proposed target or the critical level's request.
    static func resourceText(_ reading: ResourceReading) -> String {
        let figures = [("memory", reading.memoryPercent), ("CPU", reading.cpuPercent)]
            .map { pair in pair.0 + " " + (pair.1.map(percentText) ?? "unread") }
        var lines = ["Levels  " + (reading.level?.rawValue ?? "unavailable (levels not calibrated)")
                     + "  (" + figures.joined(separator: ", ") + ")"]
        if let eta = reading.eta {
            let growth = reading.growthDriver.map {
                " — \(displaySafe($0.name)) +\(bytesText($0.growthBytes)) in \(windowText($0.window))"
            } ?? ""
            lines.append("Memory ETA  " + etaText(eta) + growth)
        }
        if !reading.topConsumers.isEmpty {
            lines.append("Consumers  " + reading.topConsumers.map(consumerText).joined(separator: ", "))
        }
        if let request = reading.pauseRequest {
            lines.append("Pause requested  " + consumerText(request.target) + " — " + request.reason)
        } else if let target = reading.triageTarget, reading.level == .triage {
            lines.append("Target  " + consumerText(target) + "; pause not requested")
        }
        return lines.joined(separator: "\n")
    }

    /// `node 8.1 G`.
    static func consumerText(_ consumer: ResourceConsumer) -> String {
        "\(displaySafe(consumer.name)) \(bytesText(consumer.residentBytes))"
    }

    /// `18 min to the floor (8.1 G available)`, or that it is already there.
    static func etaText(_ eta: MemoryProjection.ETA) -> String {
        guard eta.seconds > 0 else { return "at the floor (\(bytesText(eta.floorBytes)) available)" }
        return "\(windowText(eta.seconds)) to the floor (\(bytesText(eta.availableBytes)) available)"
    }

    /// A span as minutes from a minute up, else seconds: `18 min`, `45 s`.
    static func windowText(_ seconds: Double) -> String {
        seconds >= 60 ? "\(Int((seconds / 60).rounded())) min" : "\(Int(seconds.rounded())) s"
    }

    static func conditionText(_ condition: Warning.Condition) -> String {
        switch condition {
        case .unattributed(let percent):
            return "Unattributed CPU \(percentText(percent))"
        case .copies(let count, let growth, let percent):
            return "copies \(count), up \(growth) in 5 min, \(percentText(percent)) with what they started"
        case .load(let oneMinute, let cpus, let rising):
            let times = String(format: "%.1f", rounded(oneMinute / Double(max(cpus, 1))))
            return "load \(loadText(oneMinute)) on \(cpus) CPUs (\(times) ×)" + (rising ? ", rising" : "")
        case .systemShare(let percent):
            return "system \(percentText(percent)) of CPU time"
        case .group(let percent, let seconds):
            return "\(percentText(percent)) for \(Int(seconds / 60)) min"
        }
    }

    /// Text any process can set (names, users) made safe to print: control characters (Unicode Cc:
    /// U+0000–U+001F, U+007F–U+009F) as `\xHH`, as `ps` prints them; format characters (Cf: bidi
    /// overrides, zero-width marks) and line / paragraph separators (Zl, Zp) as `\uHHHH`
    /// (`\UHHHHHHHH` past U+FFFF); a backslash as `\\`, so text cannot pass for an escape Saur0n
    /// wrote. A name then cannot start a fake row, reorder the text after it, or drive the terminal.
    static func displaySafe(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control: out += String(format: "\\x%02X", scalar.value)
            case .format, .lineSeparator, .paragraphSeparator:
                out += String(format: scalar.value > 0xFFFF ? "\\U%08X" : "\\u%04X", scalar.value)
            default:
                if scalar == "\\" { out += "\\\\" } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// `line` cut to `columns` terminal columns, as `ps` cuts its rows to a terminal's width, so a
    /// long name cannot wrap into what looks like a row of its own. Every scalar of a character counts
    /// (combining marks and emoji modifiers too, since terminals differ on drawing them), two columns
    /// from U+1100 up: that overcounts some, and only cuts earlier.
    static func fitted(_ line: String, columns: Int) -> String {
        var used = 0
        var end = line.startIndex
        for index in line.indices {
            let width = line[index].unicodeScalars.reduce(0) { $0 + ($1.value >= 0x1100 ? 2 : 1) }
            guard used + width <= columns else { return String(line[..<end]) }
            used += width
            end = line.index(after: index)
        }
        return line
    }
}
