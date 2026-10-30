// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Saur0nCore

/// `saur0n` — one-shot snapshot of the machine. Table by default, `--json` for machine consumers;
/// `--interval <seconds>` sets the CPU sampling window (default 1); `--by session` lists processes under the
/// session that started them instead of their repo, `--by command` under the command they run (Phase 6 Step 4);
/// `--count <n>` takes n samples back to back, 0 until interrupted, each with the warnings in force (Phase 6 Step 5).
/// `saur0n snapshots` lists the window's snapshot log and `saur0n snapshot <time>` prints the latest snapshot at or
/// before a local clock time, `--by` and `--json` as above (Phase 6 Step 7); they only read the log.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("saur0n: \(message)\n".utf8))
    exit(code)
}

enum Mode { case sample, snapshots, snapshot(String) }

let timeForms = "HH:MM[:SS] or YYYY-MM-DD HH:MM[:SS]"
var mode = Mode.sample
var json = false
var interval = 1.0
var count = 1
var sampling = false
var grouping = ProcessTable.Grouping.repo
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    // A lone `--` marks the end of options (POSIX Utility Syntax Guideline 10); `swift run saur0n -- <options>`
    // passes it through. What follows is still read as options and commands.
    case "--": continue
    case "snapshots": mode = .snapshots
    // The date and the time may come as one argument or two: `snapshot 2026-10-24 14:03`.
    case "snapshot":
        guard var time = args.popFirst(), !time.hasPrefix("-") else { fail("snapshot takes a time: \(timeForms)", code: 2) }
        if time.count == 10, time.filter({ $0 == "-" }).count == 2, let clock = args.first, clock.contains(":") {
            time += " " + clock
            args.removeFirst()
        }
        mode = .snapshot(time)
    case "--json": json = true
    case "--by":
        guard let by = args.popFirst().flatMap(ProcessTable.Grouping.init(rawValue:)), by != .repo else {
            fail("--by takes 'session' or 'command'", code: 2)
        }
        grouping = by
    case "--interval":
        guard let value = args.popFirst().flatMap(Double.init), (0.1...10).contains(value) else {
            fail("--interval must be between 0.1 and 10 seconds", code: 2)
        }
        interval = value
        sampling = true
    // As `top -l` counts samples, 0 for no end.
    case "--count":
        guard let value = args.popFirst().flatMap({ Int($0) }), value >= 0 else {
            fail("--count takes a whole number of samples, 0 for no end", code: 2)
        }
        count = value
        sampling = true
    default: fail("unknown option '\(arg)'", code: 2)
    }
}
if json && count != 1 { fail("--count works with the table only", code: 2) }

// On a terminal, rows are cut to its width, as `ps` does; piped output keeps them whole.
var size = winsize()
let onTerminal = isatty(STDOUT_FILENO) == 1 && ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0

/// Encodes `value` as the CLI's JSON (pretty, sorted keys) and prints it.
func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else { fail("cannot encode JSON", code: 1) }
    FileHandle.standardOutput.write(data)
    print()
}

/// The snapshot log's entries and the log they came from, read only; none before the window wrote one.
func snapshotEntries() -> (SnapshotLog?, [SnapshotLog.Entry]) {
    let url = SnapshotLog.defaultURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return (nil, []) }
    do {
        let log = try SnapshotLog(url: url, readOnly: true)
        return (log, try log.entries())
    } catch {
        fail("cannot read snapshots: \(error)", code: 1)
    }
}

if case .sample = mode {} else if sampling { fail("--interval and --count are for sampling, not snapshots", code: 2) }
switch mode {
case .sample: break
case .snapshots:
    let (_, entries) = snapshotEntries()
    if json {
        printJSON(entries)
    } else if entries.isEmpty {
        print("no snapshots yet")
    } else {
        for entry in entries { print(entry.text()) }
    }
    exit(0)
case .snapshot(let text):
    guard let time = SnapshotTime.parse(text) else { fail("'\(text)' is not a time: \(timeForms)", code: 2) }
    let (log, entries) = snapshotEntries()
    guard let log, let entry = SnapshotLog.entry(atOrBefore: time, in: entries) else {
        fail(entries.first.map { "no snapshot at or before \(text); the first is \(SnapshotTime.text($0.takenAt))" }
             ?? "no snapshots yet", code: 1)
    }
    let record: SnapshotRecord
    do { record = try log.record(entry.id) } catch { fail("cannot read snapshots: \(error)", code: 1) }
    if json {
        printJSON(record)
    } else {
        print(record.text(by: grouping, columns: onTerminal ? Int(size.ws_col) : nil))
    }
    exit(0)
}

/// Runs one step; a failure exits with `cannot <action>: <error>`, the action named from the error.
func attempt<T>(_ action: (Error) -> String, _ body: () throws -> T) -> T {
    do {
        return try body()
    } catch {
        fail("cannot \(action(error)): \(error)", code: 1)
    }
}

func attempt<T>(_ action: String, _ body: () throws -> T) -> T { attempt({ _ in action }, body) }

/// Runs one read; a failure exits naming what could not be read.
func reading<T>(_ what: (Error) -> String, _ body: () throws -> T) -> T { attempt({ "read \(what($0))" }, body) }

let topology = attempt("read core topology") { try SystemReaders.coreTopology() }

/// `ps` and `top` failures name their tool; anything else is the process list itself.
func processSource(_ error: Error) -> String {
    switch error {
    case ProcessReadError.command(let path, _, _), ProcessReadError.launch(let path, _),
         ProcessReadError.timedOut(let path, _):
        return "\(URL(fileURLWithPath: path).lastPathComponent) sample"
    case ProcessReadError.timebase: return "mach timebase"
    case ProcessSampleError.unparsable(let source, _): return "\(source.rawValue) sample"
    case ProcessSampleError.missingKernelTask: return "top sample"
    default: return "process list"
    }
}

/// The reads that open and close a window; each window's closing reads open the next, as the window's
/// `TickSampler` does, so samples run back to back with no gap between them.
struct Reads {
    let ticks: [CPUTicks]
    let processes: ProcessListSample
    let nettop: NettopRead
    let disk: MachineDiskSample
    let network: MachineNetworkSample
}

func uptimeSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

// top opens its own window as it starts, so it goes first; ticks and processes are read together at each end.
// After the first sample it runs on the window's schedule (every 30th sample, the last reading kept): a fresh `top`
// each second would cost about 3% of the machine.
var kernelTasks = ProcessReaders.KernelTaskSchedule()
var pendingTop: ProcessReaders.KernelTaskSampler? = reading(processSource) {
    try ProcessReaders.KernelTaskSampler.start(interval: interval)
}
// The machine's disk counters bracket the sleep alone: disk load swings by hundreds of MB/s from one second to the
// next, so a window that also spans a process scan cannot be lined up with `iostat`'s seconds (2026-10-21).
// One cumulative nettop read at each end of the sleep (a nettop left running between samples costs ~7% of the
// machine). The machine's network counters bracket the sleep with the disk's, for the same reason.
var before: Reads = {
    let ticks = attempt("read CPU load") { try SystemReaders.cpuTicks() }
    let processes = reading(processSource) { try ProcessReaders.sample() }
    let nettop = attempt("read per-process network (nettop)") { try NettopRunner.read() }
    let disk = attempt("read disk activity") { try MachineDiskReader.read() }
    let network = attempt("read network activity") { try MachineNetworkReader.read() }
    return Reads(ticks: ticks, processes: processes, nettop: nettop, disk: disk, network: network)
}()
var windowStart = uptimeSeconds()
var warnings = WarningEngine()
// The CLI has no app-defaults reader; resource alerts stay off until activation is separately approved.
var resources = ResourceLevelEngine(calibration: .pending)
var sample = 0

while count == 0 || sample < count {
    Thread.sleep(forTimeInterval: interval)
    let networkAfter = attempt("read network activity") { try MachineNetworkReader.read() }
    let diskAfter = attempt("read disk activity") { try MachineDiskReader.read() }
    let nettopAfter = attempt("read per-process network (nettop)") { try NettopRunner.read() }
    let ticksAfter = attempt("read CPU load") { try SystemReaders.cpuTicks() }
    let processesAfter = reading(processSource) { try ProcessReaders.sample(workingDirectories: true) }
    let windowEnd = uptimeSeconds()
    if let top = pendingTop {
        pendingTop = nil
        let kernelTask = reading(processSource) { try top.finish() }
        kernelTasks.record(kernelTask, atNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
    sample += 1
    if (count == 0 || sample < count) && ProcessReaders.KernelTaskSchedule.isDue(refresh: sample) {
        pendingTop = reading(processSource) { try ProcessReaders.KernelTaskSampler.start(interval: interval) }
    }
    let loadAverage = SystemReaders.loadAverage()
    let memory = try? SystemReaders.availableMemory()
    let launches = LaunchRate(before: before.processes, after: processesAfter)
    let perProcessNetwork = NetworkActivity.perProcess(before: before.nettop, after: nettopAfter)

    let load = attempt("read CPU load") { try CPULoad.compute(before: before.ticks, after: ticksAfter) }
    let processes = reading(processSource) {
        try ProcessSample.usage(before: before.processes, after: processesAfter, cpuCount: ticksAfter.count,
                                kernelTask: kernelTasks.latest,
                                describe: DescriptionSources.load(for: processesAfter).describe,
                                network: perProcessNetwork)
    }
    let resolver = RepoResolver()
    let grouped = RepoGroups.assign(processes, workingDirectories: processesAfter.workingDirectories,
                                    repoOfDirectory: resolver.repo(forDirectory:),
                                    repoOfExecutable: resolver.repo(forExecutable:))
    let sessions = SessionGroups.assign(grouped.rows,
                                        sources: SessionSources.read(rows: grouped.rows, sample: processesAfter))
    let commands = CommandGroups.assign(sessions.rows, arguments: processesAfter.arguments)
    let machineDisk = DiskActivity.usage(before: before.disk, after: diskAfter)
    let machineNetwork = NetworkActivity.usage(before: before.network, after: networkAfter)
    let brokenOut = CatchAllBreakout.apply(
        rows: commands.rows, repoGroups: grouped.groups, sessionGroups: sessions.groups,
        thresholds: CatchAllBreakout.Thresholds(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                                                machineDiskBytesPerSecond: machineDisk.rate.totalBytesPerSecond,
                                                machineNetworkBytesPerSecond: machineNetwork.rate.totalBytesPerSecond))
    // The first sample is `--interval` long; later ones also span the previous sample's scan and print.
    let seconds = sample == 1 ? interval : windowEnd - windowStart
    func snapshot(warnings: [Warning]?) -> Snapshot {
        attempt("match the core topology to the CPU load") {
            try Snapshot(topology: topology, load: load, intervalSeconds: seconds, processes: brokenOut.rows,
                         repoGroups: brokenOut.repoGroups, sessionGroups: brokenOut.sessionGroups,
                         commandGroups: commands.groups,
                         disk: machineDisk, diskWindow: DiskWindow(before: before.disk, after: diskAfter),
                         network: machineNetwork, networkWindow: NetworkWindow(before: before.network, after: networkAfter),
                         loadAverage: loadAverage, launches: launches, warnings: warnings, memory: memory)
        }
    }
    if json {
        FileHandle.standardOutput.write(attempt("encode JSON") { try snapshot(warnings: nil).json() })
        print()
    } else {
        let tick = WarningTick(snapshot: snapshot(warnings: nil), end: windowEnd)
        let inForce = warnings.next(tick)
        let reading = resources.next(tick)
        if sample > 1 { print() }
        print(snapshot(warnings: inForce).table(columns: onTerminal ? Int(size.ws_col) : nil, by: grouping))
        print()
        print(reading?.text ?? ResourceReading.unavailableText)
    }
    before = Reads(ticks: ticksAfter, processes: processesAfter, nettop: nettopAfter, disk: diskAfter,
                   network: networkAfter)
    windowStart = windowEnd
}
