// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One process as the kernel's process table lists it (`sysctl KERN_PROC_ALL`), plus its executable path.
public struct ProcessIdentity: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let uid: UInt32
    public let user: String
    /// Start time in microseconds since the epoch; with `pid` it tells a reused pid from the original.
    public let startMicroseconds: UInt64
    /// `p_comm`, cut to 16 bytes by the kernel.
    public let comm: String
    /// nil when `proc_pidpath` cannot read it.
    public let path: String?
    /// The kernel's `P_EXEC`: the process has called exec. A child between fork and exec has not, and carries its
    /// parent's path and arguments under its own pid and start time (a forked bash subshell reads flags 0x4, its
    /// parent 0x4004; probe 2026-10-23).
    public let execed: Bool
    /// The process group (`e_pgid`), read with the parent for every process, root's too; nil when built by hand.
    public let processGroup: Int32?
    /// Whether it has a controlling terminal (`e_tdev` set), read in the same table read; false when built by hand.
    public let terminal: Bool
    /// The kernel's platform-binary bit (`csops`), read only for a process shaped like an Apple service — a service path,
    /// launchd for a parent, leading its own group (`ProcessReaders.processList`) — and false for any other, or when built
    /// by hand.
    public let platformBinary: Bool

    public init(pid: Int32, ppid: Int32, uid: UInt32, user: String, startMicroseconds: UInt64, comm: String, path: String?,
                execed: Bool = true, processGroup: Int32? = nil, terminal: Bool = false, platformBinary: Bool = false) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.user = user
        self.startMicroseconds = startMicroseconds
        self.comm = comm
        self.path = path
        self.execed = execed
        self.processGroup = processGroup
        self.terminal = terminal
        self.platformBinary = platformBinary
    }
}

/// A fact kept while the process lives, as sysinfo's `UpdateKind::OnlyIfNotSet` ("only update … if it was not
/// already set at least once"). Kept by pid, start time and executable path, so a reused pid and an exec into
/// another program are each read anew; a process not yet exec'd (`ProcessIdentity.execed`), or whose read failed,
/// is read every time. Arguments of shells and interpreters use `arguments(for:read:)` to also catch same-path execs.
public struct KeptPerProcess<Value: Sendable>: Sendable {
    private struct Key: Hashable {
        let start: UInt64
        let path: String?
    }

    private var kept: [Int32: (key: Key, value: Value)] = [:]

    public init() {}

    /// How many processes have a value kept.
    public var count: Int { kept.count }

    /// Each of `processes`' value, `read` for the ones not kept yet; the ones not listed leave, so only live
    /// processes are kept.
    public mutating func values(for processes: [ProcessIdentity], read: (Int32) -> Value?) -> [Int32: Value] {
        values(for: processes, refreshing: { _ in false }, read: read)
    }

    private mutating func values(for processes: [ProcessIdentity], refreshing: (ProcessIdentity) -> Bool,
                                 read: (Int32) -> Value?) -> [Int32: Value] {
        var next: [Int32: (key: Key, value: Value)] = [:]
        var values: [Int32: Value] = [:]
        for process in processes {
            let key = Key(start: process.startMicroseconds, path: process.path)
            if process.execed, !refreshing(process), let old = kept[process.pid], old.key == key {
                next[process.pid] = old
                values[process.pid] = old.value
                continue
            }
            guard let value = read(process.pid) else { continue }
            values[process.pid] = value
            if process.execed { next[process.pid] = (key, value) }
        }
        kept = next
        return values
    }
}

extension KeptPerProcess where Value == ProcessArguments {
    /// Shells and interpreters can exec another script without changing pid, start or path: read them each tick.
    /// Use command grouping's interpreter rule so every script-keyed process stays current; cache other executables.
    mutating func arguments(for processes: [ProcessIdentity], read: (Int32) -> ProcessArguments?) -> [Int32: ProcessArguments] {
        values(for: processes, refreshing: { CommandGroups.interpreter(ProcessSample.name($0, psComm: nil)) != nil },
               read: read)
    }
}

/// Cumulative CPU time and current resident size of one process, as one source reports them.
public struct ProcessCounters: Equatable, Sendable {
    public let cpuNanoseconds: UInt64
    public let residentBytes: UInt64

    public init(cpuNanoseconds: UInt64, residentBytes: UInt64) {
        self.cpuNanoseconds = cpuNanoseconds
        self.residentBytes = residentBytes
    }
}

/// One `ps -axo pid=,time=,rss=[,comm=]` row; `comm` is empty when not asked for (the window and CLI don't).
public struct PSRow: Equatable, Sendable {
    public let counters: ProcessCounters
    public let comm: String

    public init(counters: ProcessCounters, comm: String) {
        self.counters = counters
        self.comm = comm
    }
}

/// `kernel_task` (pid 0) as `top` reports it: Apple's 100%-per-core CPU over top's own window.
public struct KernelTaskSample: Equatable, Sendable {
    public let cpuPercentPerCore: Double
    public let residentBytes: UInt64

    public init(cpuPercentPerCore: Double, residentBytes: UInt64) {
        self.cpuPercentPerCore = cpuPercentPerCore
        self.residentBytes = residentBytes
    }
}

/// When, in uptime nanoseconds, a scan read each process's counters: task info and rusage per pid, each VM's
/// share per pid (a Virtualization.framework VM's thread read; a QEMU VM's task-info read), and the `ps` run (the midpoint of its start and end). On a loaded machine one scan can take
/// seconds, so a process read late in it ran for longer than the scan's own stamp says (Backlog
/// `per-process-sample-time`). An absent stamp means the scan's `uptimeNanoseconds`.
public struct ReadTimes: Sendable {
    public var taskInfo: [Int32: UInt64]
    public var rusage: [Int32: UInt64]
    public var vm: [Int32: UInt64]
    public var ps: UInt64?

    public init(taskInfo: [Int32: UInt64] = [:], rusage: [Int32: UInt64] = [:], vm: [Int32: UInt64] = [:], ps: UInt64? = nil) {
        self.taskInfo = taskInfo
        self.rusage = rusage
        self.vm = vm
        self.ps = ps
    }
}

/// Every process at one moment: the kernel's list, task info and arguments where they could be read
/// (own processes), and `ps`'s rows (everyone but `kernel_task`).
public struct ProcessListSample: Sendable {
    /// When the scan started: the window of a reading with no stamp of its own in `readAt`.
    public let uptimeNanoseconds: UInt64
    public let processes: [ProcessIdentity]
    public let taskInfo: [Int32: ProcessCounters]
    public let ps: [Int32: PSRow]
    public let arguments: [Int32: ProcessArguments]
    /// The user's own VMs: Virtualization.framework processes and QEMU (`VirtualMachines.qemu`).
    public let vms: [Int32: VMSample]
    /// The user's own processes' working directories, when this sample read them.
    public let workingDirectories: [Int32: String]
    /// The user's own processes' reaped-children CPU time in nanoseconds (`proc_pid_rusage`
    /// `ri_child_user_time + ri_child_system_time`): every child they waited for, and those children's own reaped children.
    public let childrenCPU: [Int32: UInt64]
    /// The same processes' own user + system time from the same `proc_pid_rusage` call as `childrenCPU`, read
    /// in the scan's first pass: a child's start reading that matches its collected time.
    public let rusageCPU: [Int32: UInt64]
    /// The same processes' disk bytes since they started, from the same `proc_pid_rusage` call; absent for the
    /// rows it could not read (root's and other users').
    public let diskBytes: [Int32: DiskBytes]
    public let readAt: ReadTimes
    /// The pid and start of this sample's `ps` child: two samples' readings give the processes launched between them
    /// (`LaunchRate`). nil in a sample built without one.
    public let psLaunch: PidReading?

    public init(uptimeNanoseconds: UInt64, processes: [ProcessIdentity],
                taskInfo: [Int32: ProcessCounters], ps: [Int32: PSRow], arguments: [Int32: ProcessArguments] = [:],
                vms: [Int32: VMSample] = [:], workingDirectories: [Int32: String] = [:],
                childrenCPU: [Int32: UInt64] = [:], rusageCPU: [Int32: UInt64] = [:], diskBytes: [Int32: DiskBytes] = [:],
                readAt: ReadTimes = ReadTimes(), psLaunch: PidReading? = nil) {
        self.diskBytes = diskBytes
        self.readAt = readAt
        self.psLaunch = psLaunch
        self.uptimeNanoseconds = uptimeNanoseconds
        self.processes = processes
        self.taskInfo = taskInfo
        self.ps = ps
        self.arguments = arguments
        self.vms = vms
        self.workingDirectories = workingDirectories
        self.childrenCPU = childrenCPU
        self.rusageCPU = rusageCPU
    }

    /// The name Saur0n shows for `process` (`ProcessSample.name`), from this sample's `ps` row.
    public func name(of process: ProcessIdentity) -> String {
        ProcessSample.name(process, psComm: ps[process.pid]?.comm)
    }
}

public enum ProcessSource: String, Encodable, Sendable {
    case libproc, ps, top
}

/// One row of the process table: CPU as a share of the whole machine over the sample window.
public struct ProcessUsage: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let uid: UInt32
    public let user: String
    public let path: String?
    public let name: String
    /// 0–100, where 100 = every CPU busy for the whole window.
    public let cpuPercent: Double
    public let residentBytes: UInt64
    public let source: ProcessSource
    /// CPU of its children that exited and were reaped by it in the window, 0–100 like `cpuPercent`
    /// and not part of it; nil when unreadable (root's and other users' processes).
    public var exitedChildrenCpuPercent: Double? = nil
    /// Disk read and write over its own rusage reads, and its bytes since it started; nil when unreadable (root's
    /// and other users' processes).
    public var disk: DiskUsage? = nil
    /// Network in and out over its open sockets (`nettop`), root's processes included; `.zero` for a process
    /// `nettop` did not list (no sockets), nil when no `nettop` map was given.
    public var network: NetworkUsage? = nil
    /// What the user calls it ("test: astar · my-crate"); nil when no rule names it.
    public var readableName: String? = nil
    /// Set on a VM process: its name and load against the vCPUs it was given.
    public var vm: VMUsage? = nil
    /// The repo it works in (`RepoGroups.assign`); nil in the two catch-all groups.
    public var repo: RepoInfo? = nil
    /// The session that started it (`SessionGroups.assign`); nil when none.
    public var session: SessionInfo? = nil
    /// The outermost `.app` bundle its executable lives in, without `.app` (`CatchAllBreakout.apply`); nil outside one.
    public var app: String? = nil
    /// Its command key, the script's name for a shell or interpreter running one (`CommandGroups.assign`); nil before.
    /// Not in JSON: `commandGroups` lists the pids.
    public internal(set) var command: String? = nil
    /// The folders its command line grants with `--add-dir` (`RepoGroups.addDirectories`), for grouping
    /// swarm members under their project; empty when none or unread. Not in JSON.
    var addDirectories: [String] = []
    /// Start time in microseconds since the epoch (`ProcessIdentity.startMicroseconds`); with `pid` it names
    /// the row across refreshes (`ProcessTable.RowID`). Not in JSON.
    public internal(set) var startMicroseconds: UInt64 = 0
    /// Its process group (`ProcessIdentity.processGroup`); nil when unread. Not in JSON.
    public internal(set) var processGroup: Int32? = nil
    /// An own-user process under launchd that does not lead its process group (`Orphans.isOrphan`): what `nohup … &`
    /// leaves once its shell exits. Its repo and session come through its group (Phase 6 Step 8).
    public internal(set) var orphaned = false
    /// Whether it has a controlling terminal (`ProcessIdentity.terminal`). Not in JSON.
    public internal(set) var terminal = false
    /// The kernel's platform-binary bit (`ProcessIdentity.platformBinary`); one of the four checks of an Apple service
    /// (`AppleServices`). Not in JSON.
    public internal(set) var platformBinary = false
    /// One of the user's own shells and sessions, which no warning line counts or holds (`CommandGroups.usersOwn`).
    /// Not in JSON.
    public internal(set) var usersOwn = false

    /// Its own CPU plus its exited children's (unread counts 0): what a row sorts by under CPU, as a group header's
    /// `RepoGroup.totalCpuPercent` (Phase 6 Step 3). Not in JSON.
    public var totalCpuPercent: Double { cpuPercent + (exitedChildrenCpuPercent ?? 0) }
}

extension ProcessUsage: Encodable {
    enum CodingKeys: String, CodingKey {
        case pid, ppid, uid, user, path, app, name, readableName, cpuPercent, exitedChildrenCpuPercent, residentBytes,
             source, vm, repo, session, orphaned, disk, network
    }

    /// `cpuPercent` and `exitedChildrenCpuPercent` to two decimals: most processes sit under 0.05%, and one decimal
    /// would round them all to 0 and bias any sum low. `path`, `app`, `readableName`, `exitedChildrenCpuPercent`, `vm`,
    /// `repo`, `session`, `disk` and `network` are null, never omitted, when absent; `orphaned` is always there.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        try container.encode(ppid, forKey: .ppid)
        try container.encode(uid, forKey: .uid)
        try container.encode(user, forKey: .user)
        try container.encode(path, forKey: .path)
        try container.encode(app, forKey: .app)
        try container.encode(name, forKey: .name)
        try container.encode(readableName, forKey: .readableName)
        try container.encode(TextFormat.rounded(cpuPercent, places: 2), forKey: .cpuPercent)
        try container.encode(exitedChildrenCpuPercent.map { TextFormat.rounded($0, places: 2) }, forKey: .exitedChildrenCpuPercent)
        try container.encode(residentBytes, forKey: .residentBytes)
        try container.encode(source, forKey: .source)
        try container.encode(vm, forKey: .vm)
        try container.encode(repo, forKey: .repo)
        try container.encode(session, forKey: .session)
        try container.encode(orphaned, forKey: .orphaned)
        try container.encode(disk, forKey: .disk)
        try container.encode(network, forKey: .network)
    }
}

public enum ProcessSampleError: Error, Equatable, Sendable {
    case noTimeElapsed
    case unparsable(source: ProcessSource, line: String)
    case missingKernelTask
}

/// `mach_timebase_info`: task-info CPU times are Mach absolute units, not nanoseconds (125/3 on Apple silicon).
public struct MachTimebase: Equatable, Sendable {
    public let numer: UInt32
    public let denom: UInt32

    public init(numer: UInt32, denom: UInt32) {
        self.numer = numer
        self.denom = denom
    }

    /// Reads it with `read` (the real `mach_timebase_info` by default). A failed read or a zero
    /// denominator throws: dividing by it would trap.
    init(reading read: (inout mach_timebase_info_data_t) -> kern_return_t = { mach_timebase_info(&$0) }) throws {
        var info = mach_timebase_info_data_t()
        let result = read(&info)
        guard result == KERN_SUCCESS else { throw ProcessReadError.timebase(kernReturn: result) }
        guard info.denom != 0 else { throw ProcessReadError.timebase(kernReturn: KERN_FAILURE) }
        self.init(numer: info.numer, denom: info.denom)
    }

    /// Split so `units × numer` cannot overflow for any realistic CPU time.
    public func nanoseconds(_ units: UInt64) -> UInt64 {
        let n = UInt64(numer), d = UInt64(denom)
        return units / d * n + units % d * n / d
    }
}

public enum ProcessSample {
    /// Rows for every process alive at `after`, sorted by own + exited CPU (one decimal) descending, then pid.
    /// Survivors (same pid and start time in both samples) count their CPU-time delta; a process
    /// started inside the window counts from 0; one that exited is dropped, as `top` does.
    /// Task info is preferred, then `ps`; `kernel_task` comes from `top`. A process that neither
    /// source covers at both ends has exited mid-read and is dropped too.
    /// Readable name: a VM's `VM: <name> · N cores`, else a test run's name from its arguments, else
    /// `describe(pid, name, path)`.
    /// Each row also carries `exitedChildren`'s figure, and its `network` from the `nettop` map when one is given
    /// (`.zero` for a pid it does not list); a Lima VM then takes its network helper's
    /// (`VirtualMachines.adoptLimaNetworks`, reading each instance's `lima.yaml` through `limaConfig`).
    /// Each row carries its process group, and is marked orphaned against `ownUID` (`Orphans.isOrphan`).
    public static func usage(before: ProcessListSample, after: ProcessListSample,
                             cpuCount: Int, kernelTask: KernelTaskSample?,
                             describe: ((Int32, String, String?) -> String?)? = nil,
                             network: [Int32: NetworkUsage]? = nil,
                             limaConfig: (String) -> String? = VirtualMachines.readLimaConfig,
                             ownUID: UInt32 = getuid()) throws -> [ProcessUsage] {
        guard after.uptimeNanoseconds > before.uptimeNanoseconds, cpuCount > 0 else {
            throw ProcessSampleError.noTimeElapsed
        }
        /// A share of every CPU for `nanoseconds` of CPU time over one process's own window for one source (`stamp`).
        func share(_ nanoseconds: UInt64, survivor: Bool, _ stamp: (ReadTimes) -> UInt64?) -> Double {
            100 * Double(nanoseconds)
                / (Double(window(survivor: survivor, before: before, after: after) { stamp($0.readAt) }) * Double(cpuCount))
        }
        let earlier = Dictionary(before.processes.map { ($0.pid, $0.startMicroseconds) }, uniquingKeysWith: { a, _ in a })

        // top's %CPU is per core, so it never reads past 100 × the CPU count.
        if let kernelTask, kernelTask.cpuPercentPerCore > 100 * Double(cpuCount) {
            throw ProcessSampleError.unparsable(source: .top, line: "kernel_task %CPU \(kernelTask.cpuPercentPerCore)")
        }

        let exited = exitedChildren(before: before, after: after, earlier: earlier)
        var rows: [ProcessUsage] = []
        for process in after.processes {
            let survivor = earlier[process.pid] == process.startMicroseconds
            let pid = process.pid
            let measured: (cpuPercent: Double, rss: UInt64, source: ProcessSource)
            if let c = inWindow(now: after.taskInfo[pid], then: before.taskInfo[pid], survivor: survivor) {
                measured = (share(c.cpuNanoseconds, survivor: survivor) { $0.taskInfo[pid] }, c.residentBytes, .libproc)
            } else if let c = inWindow(now: after.ps[pid]?.counters, then: before.ps[pid]?.counters, survivor: survivor) {
                measured = (share(c.cpuNanoseconds, survivor: survivor) { $0.ps }, c.residentBytes, .ps)
            } else if pid == 0, let kernelTask {
                measured = (kernelTask.cpuPercentPerCore / Double(cpuCount), kernelTask.residentBytes, .top)
            } else {
                continue
            }
            let (cpuPercent, rss, source) = measured
            assert(cpuPercent.isFinite && cpuPercent >= 0, "a share of a positive window")
            let rawName = after.name(of: process)
            // A survivor unread in the first sample has no window: counting from 0 would add its lifetime.
            let vm = after.vms[process.pid].flatMap { now -> VMUsage? in
                let then = survivor ? before.vms[process.pid] : nil
                guard !survivor || then != nil else { return nil }
                return VirtualMachines.usage(before: then, after: now,
                                             windowNanoseconds: window(survivor: survivor, before: before, after: after) {
                                                 $0.readAt.vm[pid]
                                             })
            }
            let readable = vm.map { "VM: \($0.name) · \($0.vcpus) cores" }
                ?? ReadableName.of(path: process.path, arguments: after.arguments[process.pid])
                ?? describe?(process.pid, rawName, process.path)
            rows.append(ProcessUsage(pid: process.pid, ppid: process.ppid, uid: process.uid, user: process.user,
                                     path: process.path, name: rawName, cpuPercent: cpuPercent, residentBytes: rss,
                                     source: source,
                                     exitedChildrenCpuPercent: exited[pid].map {
                                         share($0, survivor: survivor) { $0.rusage[pid] }
                                     },
                                     // A row whose task info failed reads like another user's: no disk figure, its
                                     // bytes left to the unattributed line (Phase 5 Step 1 lock 4).
                                     disk: source == .libproc ? disk(pid, survivor: survivor, before: before, after: after) : nil,
                                     network: network.map { $0[pid] ?? .zero },
                                     readableName: readable, vm: vm,
                                     addDirectories: RepoGroups.addDirectories(argv: after.arguments[pid]?.argv ?? []),
                                     startMicroseconds: process.startMicroseconds, processGroup: process.processGroup,
                                     orphaned: Orphans.isOrphan(uid: process.uid, ppid: process.ppid, pid: process.pid,
                                                                processGroup: process.processGroup, ownUID: ownUID),
                                     terminal: process.terminal, platformBinary: process.platformBinary))
        }
        if network != nil {
            rows = VirtualMachines.adoptLimaNetworks(rows, argv: { after.arguments[$0]?.argv }, limaConfig: limaConfig)
        }
        return rows.map { (shown: TextFormat.rounded($0.totalCpuPercent), row: $0) }
            .sorted { $0.shown != $1.shown ? $0.shown > $1.shown : $0.row.pid < $1.row.pid }
            .map(\.row)
    }

    /// CPU time, in nanoseconds, of the children each process reaped inside the window, for every process
    /// alive at `after` whose reaped-children time was read (`earlier`: `before`'s pid → start time, `usage`'s own
    /// index, so a sample builds it once). A process new in the window counts all of it. A
    /// survivor counts its delta (unread at the start: none) less what its descendants that exited in the window
    /// had already used at the start, floored at 0: each child in `before` gone from `after` (by pid and start
    /// time) with its own CPU (rusage, else task info, else `ps`) and own reaped children's, and the same for that child's
    /// exited children, down the tree — reaped-children time rolls up every waited-for descendant, so a pane
    /// shell reaping a long session and then exiting hands its parent the session's whole life. So a long-lived
    /// descendant reaped in the window counts only its in-window part. Children of a parent that exited
    /// themselves go to launchd, whose time is unreadable, and are charged to nobody.
    static func exitedChildren(before: ProcessListSample, after: ProcessListSample,
                               earlier: [Int32: UInt64]) -> [Int32: UInt64] {
        struct Key: Hashable { let pid: Int32, start: UInt64 }
        let later = Set(after.processes.map { Key(pid: $0.pid, start: $0.startMicroseconds) })
        let gone = before.processes.filter { !later.contains(Key(pid: $0.pid, start: $0.startMicroseconds)) }
        let goneChildren = Dictionary(grouping: gone.filter { $0.ppid != $0.pid }, by: \.ppid)
        var visited: Set<Int32> = []
        /// Start-of-window CPU of `pid`'s exited children and their exited descendants; a ppid loop ends.
        func exitedAtStart(_ pid: Int32) -> UInt64 {
            var sum: UInt64 = 0
            for child in goneChildren[pid] ?? [] where visited.insert(child.pid).inserted {
                let own = before.rusageCPU[child.pid]
                    ?? (before.taskInfo[child.pid] ?? before.ps[child.pid]?.counters)?.cpuNanoseconds ?? 0
                sum &+= own &+ (before.childrenCPU[child.pid] ?? 0) &+ exitedAtStart(child.pid)
            }
            return sum
        }
        var out: [Int32: UInt64] = [:]
        for process in after.processes {
            guard let now = after.childrenCPU[process.pid] else { continue }
            guard earlier[process.pid] == process.startMicroseconds else {
                out[process.pid] = now
                continue
            }
            guard let then = before.childrenCPU[process.pid] else { continue }
            let delta = now >= then ? now - then : 0
            let already = exitedAtStart(process.pid)
            out[process.pid] = delta >= already ? delta - already : 0
        }
        return out
    }

    /// `pid`'s disk rate over its own two rusage reads and its bytes at the second; nil when `after` could not read
    /// them. A process new in the window, or a survivor unread at the start, rates 0: its bytes since it started
    /// are not the window's.
    static func disk(_ pid: Int32, survivor: Bool, before: ProcessListSample, after: ProcessListSample) -> DiskUsage? {
        guard let now = after.diskBytes[pid] else { return nil }
        guard survivor, let then = before.diskBytes[pid] else { return DiskUsage(rate: .zero, bytes: now) }
        let nanoseconds = window(survivor: true, before: before, after: after) { $0.readAt.rusage[pid] }
        return DiskUsage(rate: DiskActivity.rate(before: then, after: now, nanoseconds: nanoseconds), bytes: now)
    }

    /// A reading's window in nanoseconds: from its read in `before` (for a process new in the window, the opening
    /// scan) to its read in `after`, an end without a stamp taking its scan's; the scans' window when that is not
    /// positive.
    static func window(survivor: Bool, before: ProcessListSample, after: ProcessListSample,
                       _ stamp: (ProcessListSample) -> UInt64?) -> UInt64 {
        let start = (survivor ? stamp(before) : nil) ?? before.uptimeNanoseconds
        let end = stamp(after) ?? after.uptimeNanoseconds
        return end > start ? end - start : after.uptimeNanoseconds - before.uptimeNanoseconds
    }

    /// One source's counters over the window: a survivor's CPU-time delta (a counter that went
    /// backwards reads 0), a process started inside the window from 0, and nil when the source lacks
    /// either end. Resident size is the latest.
    static func inWindow(now: ProcessCounters?, then: ProcessCounters?, survivor: Bool) -> ProcessCounters? {
        guard let now else { return nil }
        guard survivor else { return now }
        guard let then else { return nil }
        let ns = now.cpuNanoseconds >= then.cpuNanoseconds ? now.cpuNanoseconds - then.cpuNanoseconds : 0
        return ProcessCounters(cpuNanoseconds: ns, residentBytes: now.residentBytes)
    }

    /// Every row, in the order given: PID, PPID, USER, CPU, the exited-children cell when any row has one
    /// (`exitedText`), MEM, DISK when any row has a disk figure (`diskText`; group headers carry the group's), NET when
    /// any row has a network figure (`networkText`, the same way), NAME. USER is as wide as the longest
    /// name up to 12; longer names (`_installcoordinationd`) print in full and push their own row, as `ps aux` does.
    /// NAME is the raw name, then the readable one in parentheses when there is one; a VM's adds its
    /// load against its own cores. USER and NAME go through `TextFormat.displaySafe`, and USER pads to
    /// the escaped width. `columns` cuts every line to a terminal's width; nil prints lines in full.
    /// With `groups`, rows print under a header per group (`RepoGroups.assign`'s order): name, summed
    /// CPU and memory, process count; a name two groups share adds the group's root. A row in a
    /// linked worktree ends `[worktree <folder>]`; a full clone's header adds `(clone of <repo>)`. Repo names
    /// and folders are escaped like NAME. Under a catch-all with sub-groups (`CatchAllBreakout.apply`), each
    /// sub-group prints its own header two spaces in, its members and the lifted bare rows one level in.
    /// With `sessionGroups` too, a SESSION column (the row's session label, `-` for none) sits before
    /// NAME. `.session` prints under the session groups instead, rows in their tree order with NAME
    /// indented two spaces a level and no SESSION column; a name two sessions share adds the id. `.command` prints
    /// under the command groups (Phase 6 Step 4), titled `<key> × <copies>` from two copies, each copy with what it owns
    /// indented under it, the SESSION column kept. `members`, when given, prints only those rows; every header keeps its
    /// figures and count (a snapshot's top groups in full, the rest by their header: Phase 6 Step 7).
    static func table(_ rows: [ProcessUsage], columns: Int? = nil, groups: [RepoGroup]? = nil,
                      sessionGroups: [SessionGroup]? = nil, commandGroups: [CommandGroup]? = nil,
                      by grouping: ProcessTable.Grouping = .repo, members: Set<Int32>? = nil) -> String {
        let users = rows.map { TextFormat.displaySafe($0.user) }
        let userWidth = min(max(4, users.map(\.count).max() ?? 0), 12)
        let showSession = sessionGroups != nil && grouping != .session
        let sessions = rows.map { sessionText($0.session) }
        let sessionWidth = showSession ? min(max(7, sessions.map(\.count).max() ?? 0), sessionTextMax) : 0
        let exitedWidth = rows.map { exitedText($0).count }.max() ?? 0
        let showDisk = rows.contains { $0.disk != nil }
        let showNetwork = rows.contains { $0.network != nil }
        func fit(_ text: String) -> String { columns.map { TextFormat.fitted(text, columns: $0) } ?? text }
        func pad(_ text: String, _ width: Int) -> String { text + String(repeating: " ", count: max(0, width - text.count)) }
        func line(_ pid: String, _ ppid: String, _ user: String, _ cpu: String, _ exited: String, _ mem: String,
                  _ disk: String, _ network: String, _ session: String, _ name: String) -> String {
            fit(TextFormat.leftPad(pid, 7) + TextFormat.leftPad(ppid, 7) + "  " + pad(user, userWidth)
                + TextFormat.leftPad(cpu, 7) + (exitedWidth > 0 ? "  " + pad(exited, exitedWidth) : "")
                + TextFormat.leftPad(mem, 6) + (showDisk ? "  " + TextFormat.leftPad(disk, diskWidth) : "")
                + (showNetwork ? "  " + TextFormat.leftPad(network, networkWidth) : "")
                + "  " + (showSession ? pad(session, sessionWidth) + "  " : "") + name)
        }
        func rowLine(_ row: ProcessUsage, _ user: String, _ session: String, depth: Int = 0) -> String {
            let worktree = row.repo?.worktree.map { "  [worktree \(TextFormat.displaySafe(RepoResolver.basename($0)))]" } ?? ""
            return line(String(row.pid), String(row.ppid), user, TextFormat.percentText(row.cpuPercent), exitedText(row),
                        memoryText(row.residentBytes), diskText(row.disk), networkText(row.network), session,
                        String(repeating: "  ", count: depth) + TextFormat.displaySafe(row.name)
                            + (readableText(row).map { "  (\(TextFormat.displaySafe($0)))" } ?? "") + worktree
                            + (row.orphaned ? "  [orphaned]" : ""))
        }
        let header = line("PID", "PPID", "USER", "CPU", "", "MEM", "DISK", "NET", "SESSION", "NAME")
        let sections: [(title: String, cpu: Double, bytes: UInt64, disk: DiskUsage, network: NetworkUsage, pids: [Int32],
                        depths: [Int32: Int], subgroups: [CatchAllBreakout.Subgroup])]
        if grouping == .session, let sessionGroups {
            // One parent map for every group's depths (the gate's round 2), as the window's table.
            let parents = CommandGroups.parents(rows)
            sections = zip(sessionGroups, titles(sessionGroups)).map { group, title in
                (title, group.totalCpuPercent, group.residentBytes, group.disk, group.network, group.pids,
                 CommandGroups.depths(group.pids, parents: parents), group.subgroups)
            }
        } else if grouping == .command, let commandGroups {
            let parents = CommandGroups.parents(rows)
            sections = commandGroups.map { group in
                (TextFormat.copiesTitle(name: group.name, copies: group.copies), group.totalCpuPercent,
                 group.residentBytes, group.disk, group.network, group.pids,
                 CommandGroups.depths(group.pids, parents: parents), [])
            }
        } else if let groups {
            sections = zip(groups, titles(groups)).map { group, title in
                (title, group.totalCpuPercent, group.residentBytes, group.disk, group.network, group.pids, [:],
                 group.subgroups)
            }
        } else {
            return ([header] + rows.indices.filter { members?.contains(rows[$0].pid) ?? true }
                .map { rowLine(rows[$0], users[$0], sessions[$0]) }).joined(separator: "\n")
        }

        let index = Dictionary(rows.indices.map { (rows[$0].pid, $0) }, uniquingKeysWith: { a, _ in a })
        var lines = [header]
        func headerLine(_ title: String, _ cpu: Double, _ bytes: UInt64, _ disk: DiskUsage, _ network: NetworkUsage,
                        _ count: Int) -> String {
            let processes = count == 1 ? "1 process" : "\(count) processes"
            let disk = showDisk ? "  " + diskText(disk) : ""
            let network = showNetwork ? "  " + networkText(network) : ""
            return fit("\(title)  \(TextFormat.percentText(cpu))  \(memoryText(bytes))\(disk)\(network)  \(processes)")
        }
        func member(_ pid: Int32, depth: Int) {
            guard let i = index[pid], members?.contains(pid) ?? true else { return }
            lines.append(rowLine(rows[i], users[i], sessions[i], depth: depth))
        }
        for section in sections {
            lines.append(headerLine(section.title, section.cpu, section.bytes, section.disk, section.network,
                                    section.pids.count))
            // A catch-all's sub-groups print their own header two spaces in, their members one level in.
            guard !section.subgroups.isEmpty else {
                for pid in section.pids { member(pid, depth: section.depths[pid] ?? 0) }
                continue
            }
            for entry in CatchAllBreakout.entries(pids: section.pids, subgroups: section.subgroups) {
                switch entry {
                case .process(let pid): member(pid, depth: 1)
                case .subgroup(let subgroup):
                    lines.append(headerLine("  " + TextFormat.displaySafe(subgroup.name), subgroup.totalCpuPercent,
                                            subgroup.residentBytes, subgroup.disk, subgroup.network, subgroup.pids.count))
                    for pid in subgroup.pids { member(pid, depth: 1) }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Each repo group's header title, escaped: its name; the root too when two repo groups share the name;
    /// `  (clone of <repo>)` for a full clone.
    static func titles(_ groups: [RepoGroup]) -> [String] {
        let nameCounts = Dictionary(groups.filter { $0.root != nil }.map { ($0.name, 1) }, uniquingKeysWith: +)
        return groups.map { group in
            var title = TextFormat.displaySafe(group.name)
            if let root = group.root, (nameCounts[group.name] ?? 0) > 1 { title += " (\(TextFormat.displaySafe(root)))" }
            if let source = group.cloneOf { title += "  (clone of \(TextFormat.displaySafe(source)))" }
            return title
        }
    }

    /// Each session group's header title, escaped: its name; the id too when two sessions share the name.
    static func titles(_ groups: [SessionGroup]) -> [String] {
        let nameCounts = Dictionary(groups.filter { $0.id != nil }.map { ($0.name, 1) }, uniquingKeysWith: +)
        return groups.map { group in
            var title = TextFormat.displaySafe(group.name)
            if let id = group.id, (nameCounts[group.name] ?? 0) > 1 { title += " (\(TextFormat.displaySafe(id)))" }
            return title
        }
    }

    /// A row's exited-children cell, `+N.N% exited`; empty when unread or showing 0.0%.
    static func exitedText(_ row: ProcessUsage) -> String {
        guard let exited = row.exitedChildrenCpuPercent, TextFormat.rounded(exited) > 0 else { return "" }
        return "+\(TextFormat.percentText(exited)) exited"
    }

    /// The DISK column's width: `123.4 M/s`.
    static let diskWidth = 9

    /// A DISK cell: read plus write per second (`TextFormat.bytesPerSecondText`); `—` when unreadable.
    static func diskText(_ disk: DiskUsage?) -> String {
        disk.map { TextFormat.bytesPerSecondText($0.rate.totalBytesPerSecond) } ?? "—"
    }

    /// The NET column's width, as DISK's.
    static let networkWidth = 9

    /// A NET cell: in plus out per second; `—` when no `nettop` map was given.
    static func networkText(_ network: NetworkUsage?) -> String {
        network.map { TextFormat.bytesPerSecondText($0.rate.totalBytesPerSecond) } ?? "—"
    }

    /// The SESSION column's widest label; longer ones are cut with "…".
    static let sessionTextMax = 24

    /// A row's SESSION cell: its escaped label, cut to `sessionTextMax`; `-` with no session.
    static func sessionText(_ session: SessionInfo?) -> String {
        guard let session else { return "-" }
        let text = TextFormat.displaySafe(session.name)
        return text.count > sessionTextMax ? String(text.prefix(sessionTextMax - 1)) + "…" : text
    }

    static func readableText(_ row: ProcessUsage) -> String? {
        guard let vm = row.vm, let name = row.readableName else { return row.readableName }
        return name + " · \(TextFormat.percentText(vm.shareOfAllotted)) of its cores"
    }

    /// Binary units, B/K/M/G/T: whole bytes; one decimal below 9.95 scaled units, whole numbers
    /// from 9.95 up (`8.1G`, `10G`, `34M`). Promote a unit when its rounded value reaches 1024.
    static func memoryText(_ bytes: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytes), unit = 0
        while unit < units.count - 1, value.rounded() >= 1024 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes)B" }
        return String(format: value < 9.95 ? "%.1f%@" : "%.0f%@", value, units[unit])
    }

    /// Basename of the executable path; else `p_comm` (the kernel's name, cut to 16 bytes); else the
    /// basename of `ps`'s comm. macOS `ps` comm is argv[0], which a process can set to anything, and
    /// reads `<defunct>` for a zombie whose `p_comm` is still known.
    static func name(_ process: ProcessIdentity, psComm: String?) -> String {
        if let base = process.path.flatMap(basename) { return base }
        if !process.comm.isEmpty { return process.comm }
        return psComm.flatMap(basename) ?? ""
    }

    /// The last non-empty `/`-separated part of `path`; nil when it has none.
    static func basename(_ path: String) -> String? {
        path.split(separator: "/").last.map(String.init)
    }

    /// `ps -axo pid=,time=,rss=,comm=` output keyed by pid. `comm` is the rest of the line and may
    /// hold spaces; rss is KB. Blank lines are skipped; any other line that does not parse is an error.
    public static func parsePS(_ output: String) throws -> [Int32: PSRow] {
        var rows: [Int32: PSRow] = [:]
        for line in output.split(separator: "\n") where !line.allSatisfy(\.isWhitespace) {
            let unparsable = ProcessSampleError.unparsable(source: .ps, line: String(line))
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = Int32(fields[0]),
                  let cpu = psTimeNanoseconds(String(fields[1])), let rssKB = UInt64(fields[2]) else { throw unparsable }
            // rss is KB; a count past UInt64.max bytes is no real size.
            let (rss, overflow) = rssKB.multipliedReportingOverflow(by: 1024)
            guard !overflow else { throw unparsable }
            let comm = fields.count == 4 ? String(fields[3].drop { $0 == " " }) : ""
            rows[pid] = PSRow(counters: ProcessCounters(cpuNanoseconds: cpu, residentBytes: rss), comm: comm)
        }
        return rows
    }

    /// A `sysctl KERN_PROCARGS2` buffer: Int32 argc, the exec path and its NUL padding, argc argv
    /// strings, then `KEY=value` environment strings up to an empty one or the end. nil when argc is
    /// negative, the exec path lacks its closing NUL, or fewer than argc NUL-terminated argv strings are present.
    /// An unterminated final environment string is dropped; environment strings with no `=` are skipped
    /// (first of a repeated key wins). Only the environment keys in `keeping` are kept (nil keeps every key).
    static func parseProcArgs(_ bytes: [UInt8],
                              keeping keys: Set<String>? = ProcessArguments.environmentKeys) -> ProcessArguments? {
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        var i = 4
        /// The NUL-terminated string at `i`, moving past its NUL; nil at a string with no closing NUL.
        func next() -> String? {
            guard let end = bytes[i...].firstIndex(of: 0) else { return nil }
            defer { i = end + 1 }
            return String(decoding: bytes[i..<end], as: UTF8.self)
        }
        guard next() != nil else { return nil }    // exec path
        while i < bytes.count, bytes[i] == 0 { i += 1 }

        var argv: [String] = []
        while argv.count < Int(argc) {
            guard let arg = next() else { return nil }
            argv.append(arg)
        }
        var environment: [String: String] = [:]
        while let entry = next(), !entry.isEmpty {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            guard keys?.contains(key) ?? true, environment[key] == nil else { continue }
            environment[key] = String(entry[entry.index(after: eq)...])
        }
        return ProcessArguments(argv: argv, environment: environment)
    }

    /// `ps`'s cumulative `time`, `[[H:]M:]S.ss`, folded left: `223:18.46` = 223 min 18.46 s. Each
    /// part is decimal digits with at most one fraction (`Double` alone would take `0x1A`, `+5`,
    /// `1e300`, `inf`); a total past `UInt64` nanoseconds is nil.
    static func psTimeNanoseconds(_ text: String) -> UInt64? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard !text.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            let pieces = part.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count <= 2, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }),
                  let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return roundedUInt64(seconds * 1e9)
    }

    /// `value` rounded to the nearest whole number, as a UInt64 when it is finite, not negative and
    /// below 2^64; nil instead of a trap.
    static func roundedUInt64(_ value: Double) -> UInt64? {
        let whole = value.rounded()
        return whole.isFinite && whole >= 0 && whole < Double(UInt64.max) ? UInt64(whole) : nil
    }

    /// The last pid-0 row of `top -l 2 -pid 0 -stats pid,cpu,mem`; top's first sample covers no window.
    public static func parseTopKernelTask(_ output: String) throws -> KernelTaskSample {
        var last: KernelTaskSample?
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 3, fields[0] == "0" else { continue }
            guard let cpu = Double(fields[1]), cpu.isFinite, cpu >= 0, let bytes = topBytes(String(fields[2])) else {
                throw ProcessSampleError.unparsable(source: .top, line: String(line))
            }
            last = KernelTaskSample(cpuPercentPerCore: cpu, residentBytes: bytes)
        }
        guard let last else { throw ProcessSampleError.missingKernelTask }
        return last
    }

    /// `top`'s MEM column: a number with a B/K/M/G/T suffix; a trailing `+`/`-` (change marker) is ignored.
    /// Non-finite, negative or past-`UInt64` sizes (`nanM`, `-5K`, `1e30T`) are nil.
    static func topBytes(_ text: String) -> UInt64? {
        var text = Substring(text)
        if text.last == "+" || text.last == "-" { text = text.dropLast() }
        let shifts: [Character: UInt64] = ["B": 0, "K": 10, "M": 20, "G": 30, "T": 40]
        guard let unit = text.last, let shift = shifts[unit], let value = Double(text.dropLast()) else { return nil }
        return roundedUInt64(value * Double(UInt64(1) << shift))
    }
}

/// Turns successive process scans into sample windows, as `TickSampler` does for ticks: each scan closes one
/// window and opens the next, so a refresh costs one scan.
public struct ProcessScanner: Sendable {
    var last: ProcessListSample?

    public init() {}

    /// nil on the first scan (no window yet); afterwards the previous scan and this one.
    public mutating func next(_ sample: ProcessListSample) -> (before: ProcessListSample, after: ProcessListSample)? {
        defer { last = sample }
        return last.map { ($0, sample) }
    }
}
