// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// `int csops(pid_t, unsigned int, void *, size_t)` from `<sys/codesign.h>`, which the Darwin module does not export.
@_silgen_name("csops")
private func csops(_ pid: Int32, _ operation: UInt32, _ buffer: UnsafeMutableRawPointer?, _ size: Int) -> Int32

public enum ProcessReadError: Error, Equatable, Sendable {
    case processList(errno: Int32)
    case launch(path: String, reason: String)
    /// `stderr`: the end of what the tool printed there, so the failure says why.
    case command(path: String, status: Int32, stderr: String)
    case timebase(kernReturn: Int32)
    /// The tool had not finished `seconds` after its read began: it was killed, or it had exited while a child of it
    /// still held its stdout open.
    case timedOut(path: String, seconds: Double)
}

/// Readers over `sysctl KERN_PROC_ALL`, libproc, `/bin/ps` and `/usr/bin/top`; the scan drops processes
/// confirmed gone after a failed rusage read and routes Apple VMs and QEMU to their respective readers.
/// CPU math, VM recognition and readable naming live in `ProcessSample`, `VirtualMachines` and `ReadableName`.
public enum ProcessReaders {
    /// Every process at this moment: the kernel's list with paths, task info where permitted, the
    /// arguments and reaped-children CPU of the user's own processes and the threads and open files of their VMs, then one
    /// `ps` run. `workingDirectories` adds the user's own processes' working directories (only the
    /// closing sample needs them).
    public static func sample(workingDirectories readCwd: Bool = false) throws -> ProcessListSample {
        var fresh = KeptPerProcess<ProcessArguments>()
        return try sample(workingDirectories: readCwd, keptArguments: &fresh)
    }

    /// `sample`, keeping arguments across refreshes except for shells and interpreters: they can exec another
    /// script under the same executable path. Other processes retain the cache (research 2026-10-23-overhead).
    public static func sample(workingDirectories readCwd: Bool = false,
                              keptArguments: inout KeptPerProcess<ProcessArguments>) throws -> ProcessListSample {
        let timebase = try MachTimebase()
        let uptime = DispatchTime.now().uptimeNanoseconds
        let listed = try processList()
        let me = getuid()
        // First, before the slower reads: each own process's own and collected time, from one rusage call. Read
        // late in the scan, a parent's counter could already hold the whole life of a child listed and read as
        // alive earlier in it (live 2026-10-19: one cargo charged 8.8 s in a 1 s window).
        // Each reading is stamped as it is taken: on a loaded Mac a scan can stall for seconds, and a process read
        // late in it must be divided by its own window, not the scan's (Backlog `per-process-sample-time`).
        var readAt = ReadTimes()
        var children: [Int32: UInt64] = [:]
        var rusageCPU: [Int32: UInt64] = [:]
        var disk: [Int32: DiskBytes] = [:]
        for process in listed where process.uid == me {
            guard let info = rusageInfo(process.pid, timebase: timebase) else { continue }
            readAt.rusage[process.pid] = DispatchTime.now().uptimeNanoseconds
            children[process.pid] = info.children
            rusageCPU[process.pid] = info.own
            disk[process.pid] = info.disk
        }
        let processes = present(listed, me: me, rusageRead: Set(children.keys)) { kill($0, 0) == 0 || errno != ESRCH }
        var taskInfo: [Int32: ProcessCounters] = [:]
        for process in processes {
            guard let counters = self.taskInfo(process.pid, timebase: timebase) else { continue }
            readAt.taskInfo[process.pid] = DispatchTime.now().uptimeNanoseconds
            taskInfo[process.pid] = counters
        }
        var vms: [Int32: VMSample] = [:]
        var cwds: [Int32: String] = [:]
        var buffer: [UInt8] = []
        let own = processes.filter { $0.uid == me }
        let arguments = keptArguments.arguments(for: own) { pid in
            if buffer.isEmpty { buffer = [UInt8](repeating: 0, count: argumentsMax()) }
            return self.arguments(pid, buffer: &buffer).flatMap { ProcessSample.parseProcArgs($0) }
        }
        for process in own {
            if readCwd { cwds[process.pid] = workingDirectory(process.pid) }
            if VirtualMachines.isVirtualMachine(path: process.path) {
                vms[process.pid] = vm(process.pid)
                readAt.vm[process.pid] = DispatchTime.now().uptimeNanoseconds
            } else if let argv = arguments[process.pid]?.argv, VirtualMachines.isQEMU(path: process.path, argv: argv),
                      let time = taskInfo[process.pid]?.cpuNanoseconds {
                vms[process.pid] = VirtualMachines.qemu(argv: argv, cpuNanoseconds: time)
                readAt.vm[process.pid] = readAt.taskInfo[process.pid]    // its share is its task-info time
            }
        }
        let psStarted = DispatchTime.now().uptimeNanoseconds
        let (ps, psLaunch) = try psRows()
        readAt.ps = psStarted + (DispatchTime.now().uptimeNanoseconds - psStarted) / 2
        return ProcessListSample(uptimeNanoseconds: uptime, processes: processes, taskInfo: taskInfo, ps: ps,
                                 arguments: arguments, vms: vms, workingDirectories: cwds, childrenCPU: children,
                                 rusageCPU: rusageCPU, diskBytes: disk, readAt: readAt, psLaunch: psLaunch)
    }

    /// The listed processes less the own ones the rusage pass could not read that no longer `exist`: those
    /// exited during the scan, maybe reaped into a parent's counter already, so the sample takes them as gone.
    static func present(_ processes: [ProcessIdentity], me: uid_t, rusageRead: Set<Int32>,
                        exists: (Int32) -> Bool) -> [ProcessIdentity] {
        processes.filter { $0.uid != me || rusageRead.contains($0.pid) || exists($0.pid) }
    }

    /// `proc_pid_rusage(RUSAGE_INFO_V4)`'s own and reaped-children user + system time in nanoseconds, converted
    /// from Mach absolute units like task info's (on Apple silicon, 125/3 ns each; children checked against
    /// `getrusage(RUSAGE_CHILDREN)`); nil when not permitted or exited. `exec` resets the children's time to 0 (a
    /// shell that reaped 1 s, then `exec sleep`, reads 0; probe 2026-10-19), so a process that execs in the
    /// window reads low, never high. The same call's `ri_diskio_bytesread` / `ri_diskio_byteswritten` are the
    /// process's disk bytes since it started: charged as it issues them, page-cached writes included (a 512 MB
    /// `dd` reads 536.9 MB written while alive; probe 2026-10-20).
    static func rusageInfo(_ pid: Int32, timebase: MachTimebase) -> (own: UInt64, children: UInt64, disk: DiskBytes)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        return (timebase.nanoseconds(info.ri_user_time + info.ri_system_time),
                timebase.nanoseconds(info.ri_child_user_time + info.ri_child_system_time),
                DiskBytes(read: info.ri_diskio_bytesread, written: info.ri_diskio_byteswritten))
    }

    /// `proc_pidinfo(PROC_PIDVNODEPATHINFO)`'s current directory; nil when not permitted or exited.
    static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { SystemReaders.cString($0) }
        return path.isEmpty ? nil : path
    }

    /// A VM process's name (from its open files), vCPU count and vCPU-thread time; nil when unreadable.
    static func vm(_ pid: Int32) -> VMSample? {
        guard let threads = threads(pid) else { return nil }
        let name = VirtualMachines.name(openFiles: openFilePaths(pid, limit: 32)) {
            FileManager.default.fileExists(atPath: $0 + "/lima.yaml")
        }
        return VirtualMachines.sample(name: name, threads: threads)
    }

    /// Every thread's name and user + system time (`PROC_PIDTHREADINFO` times are nanoseconds), nil
    /// for a thread that could not be read; nil when the list cannot be read whole.
    static func threads(_ pid: Int32) -> [(name: String, nanoseconds: UInt64)?]? {
        var ids = [UInt64](repeating: 0, count: 512)
        var bytes: Int32 = 0
        // A full buffer may have cut the list short: grow it, up to 64Ki threads.
        while true {
            bytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &ids, Int32(ids.count * MemoryLayout<UInt64>.size))
            guard bytes > 0 else { return nil }
            if Int(bytes) < ids.count * MemoryLayout<UInt64>.size { break }
            guard ids.count < 1 << 16 else { return nil }
            ids = [UInt64](repeating: 0, count: ids.count * 2)
        }
        return ids.prefix(Int(bytes) / MemoryLayout<UInt64>.size).map { id in
            var info = proc_threadinfo()
            let size = Int32(MemoryLayout<proc_threadinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTHREADINFO, id, &info, size) == size else { return nil }
            let name = withUnsafeBytes(of: info.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return (name, info.pth_user_time + info.pth_system_time)
        }
    }

    /// Paths of the first `limit` open files that are readable vnodes; a VM can hold tens of thousands of
    /// fds, but its disk and firmware files are among the first (research § Q3).
    static func openFilePaths(_ pid: Int32, limit: Int) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
        let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard read > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(read) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == PROX_FDTYPE_VNODE && paths.count < limit {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            paths.append(withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
        }
        return paths
    }

    /// `KERN_ARGMAX`: the most bytes one process's arguments and environment can take; when it
    /// cannot be read, the SDK's compile-time `ARG_MAX` (1 MiB in `sys/syslimits.h`).
    static func argumentsMax() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, u_int(mib.count), &value, &size, nil, 0) == 0, value > 0 else { return Int(ARG_MAX) }
        return Int(value)
    }

    /// The raw `KERN_PROCARGS2` bytes, read into `buffer`; nil when not permitted or exited.
    static func arguments(_ pid: Int32, buffer: inout [UInt8]) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    /// `sysctl KERN_PROC_ALL`: every pid with its ppid, effective uid, start time and `p_comm`; path from `proc_pidpath`.
    static func processList() throws -> [ProcessIdentity] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs: [kinfo_proc] = []
        var size = 0
        for _ in 0..<3 {    // the table can grow between the size query and the read
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
                throw ProcessReadError.processList(errno: errno)
            }
            size += size / 8
            procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            if sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 { break }
            guard errno == ENOMEM else { throw ProcessReadError.processList(errno: errno) }
            size = 0
        }
        // Size 0 here: three reads in a row found the table grown (a real ENOMEM). A read that
        // succeeds empty cannot happen — this process is in the table.
        guard size > 0 else { throw ProcessReadError.processList(errno: ENOMEM) }

        var users: [uid_t: String] = [:]
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))    // PROC_PIDPATHINFO_MAXSIZE
        return procs.prefix(size / stride).map { kp in
            let pid = kp.kp_proc.p_pid
            let uid = kp.kp_eproc.e_ucred.cr_uid
            let start = kp.kp_proc.p_un.__p_starttime
            let comm = withUnsafeBytes(of: kp.kp_proc.p_comm) { SystemReaders.cString($0) }
            let user = users[uid] ?? userName(uid)
            users[uid] = user
            let executable = path(pid, buffer: &pathBuffer)
            // The bit is asked only of a process shaped like an Apple service (`AppleServices`: a service path, launchd's
            // child, leader of its own group): the other three checks decide the rest, so the syscall is spared the
            // other thousand.
            let serviceShaped = kp.kp_eproc.e_ppid == 1 && kp.kp_eproc.e_pgid == pid && AppleServices.isServicePath(executable)
            return ProcessIdentity(pid: pid, ppid: kp.kp_eproc.e_ppid, uid: uid, user: user,
                                   startMicroseconds: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec),
                                   comm: comm, path: executable,
                                   execed: kp.kp_proc.p_flag & P_EXEC != 0, processGroup: kp.kp_eproc.e_pgid,
                                   terminal: kp.kp_eproc.e_tdev != -1,    // NODEV: no controlling terminal
                                   platformBinary: serviceShaped && platformBinary(pid))
        }
    }

    /// `csops(CS_OPS_STATUS)`: whether the kernel marks the running process's code as Apple's platform code
    /// (`CS_PLATFORM_BINARY`, 0x04000000, XNU's `bsd/sys/codesign.h`). A syscall of a few microseconds that works for
    /// every process, root's included; false when the pid is gone or the call fails.
    static func platformBinary(_ pid: Int32) -> Bool {
        var flags: UInt32 = 0
        guard csops(pid, 0 /* CS_OPS_STATUS */, &flags, MemoryLayout<UInt32>.size) == 0 else { return false }
        return flags & 0x0400_0000 != 0
    }

    static func userName(_ uid: uid_t) -> String {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return String(uid) }
        return String(cString: name)
    }

    /// `proc_pidpath` into `buffer`, which the caller reuses across processes.
    static func path(_ pid: Int32, buffer: inout [CChar]) -> String? {
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return buffer.withUnsafeBytes { SystemReaders.cString($0.prefix(Int(length))) }
    }

    /// `proc_pidinfo(PROC_PIDTASKINFO)`; nil when not permitted (another user's or root's process) or exited.
    static func taskInfo(_ pid: Int32, timebase: MachTimebase) -> ProcessCounters? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return ProcessCounters(cpuNanoseconds: timebase.nanoseconds(info.pti_total_user + info.pti_total_system),
                               residentBytes: info.pti_resident_size)
    }

    /// Without `comm`: reading every process's arguments for it took 40% of `ps`'s time (21 of 52 ms a run, probe
    /// 2026-10-19), and a row's name comes from its path or `p_comm` first (`ProcessSample.name`). With the rows, the
    /// `ps` child's own pid and start: a free reading of the kernel's pid counter (`LaunchRate`).
    static func psRows() throws -> (rows: [Int32: PSRow], launch: PidReading) {
        let command = try Command(path: "/bin/ps", arguments: ["-axo", "pid=,time=,rss="]).start()
        let launch = PidReading(pid: command.process.processIdentifier, uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                epochSeconds: Date().timeIntervalSince1970)
        return (try ProcessSample.parsePS(run(command)), launch)
    }

    /// `kernel_task`'s load over `interval` seconds, rounded up to whole seconds (`top -s` takes no fraction),
    /// from setuid `top`, which can see pid 0. Start it before
    /// the first sample, finish it after the last.
    public struct KernelTaskSampler {
        let command: Command

        public static func start(interval: Double) throws -> KernelTaskSampler {
            KernelTaskSampler(command: try Command(path: "/usr/bin/top", arguments: [
                "-l", "2", "-s", String(Int(interval.rounded(.up))), "-pid", "0", "-stats", "pid,cpu,mem",
            ]).start())
        }

        public func finish() throws -> KernelTaskSample {
            try ProcessSample.parseTopKernelTask(run(command))
        }
    }

    /// When the window reads `kernel_task`, and the last reading with its time: a fresh `top` each second
    /// would cost about 3% of the machine on its own (research 2026-10-19 Q3), so it is started every
    /// `every`th refresh, finished on the next, and its reading shown with its age until the next one. 30, not 10:
    /// one `top -l 2` run costs 0.55–0.6 s of CPU, ≈ 0.3% of the machine every 10th refresh and ≈ 0.1% every 30th;
    /// a long-running `top` stream costs 0.59% (probes 2026-10-19, Phase 4 Step 3).
    public struct KernelTaskSchedule: Sendable {
        public static let every = 30

        public private(set) var latest: KernelTaskSample?
        /// Uptime, in nanoseconds, when `latest` was taken.
        public private(set) var readAtNanoseconds: UInt64?

        public init() {}

        /// Whether refresh number `refresh` (0 first) starts a reading.
        public static func isDue(refresh: Int) -> Bool { refresh % every == 0 }

        public mutating func record(_ sample: KernelTaskSample, atNanoseconds uptime: UInt64) {
            latest = sample
            readAtNanoseconds = uptime
        }

        /// Whole seconds since the last reading at uptime `now`; nil before the first.
        public func ageSeconds(atNanoseconds now: UInt64) -> Int? {
            readAtNanoseconds.map { Int((now >= $0 ? now - $0 : 0) / 1_000_000_000) }
        }
    }

    /// A child process whose stdout is collected in full before its exit status is checked. Its
    /// stderr goes to an unlinked scratch file, read only on failure: a second pipe would have to be
    /// drained alongside stdout, or a chatty tool could block on it. `exited` is signalled when the tool exits:
    /// `waitUntilExit` hears of the exit only through the run loop of the thread that started the tool, so a
    /// tool started on one refresh and finished on the next (the window's `top`, on whatever thread the task
    /// resumed on) would wait forever.
    struct Command {
        let process = Process()
        let stdout = Pipe()
        let stderr: FileHandle?
        let exited = DispatchSemaphore(value: 0)

        init(path: String, arguments: [String]) {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = stdout
            stderr = Self.scratchFile()
            process.standardError = stderr ?? FileHandle.nullDevice
            process.terminationHandler = { [exited] _ in exited.signal() }
        }

        /// An open temp file already removed from its folder, so nothing is left behind.
        static func scratchFile() -> FileHandle? {
            var template = Array((NSTemporaryDirectory() + "saur0n-stderr.XXXXXX").utf8CString)
            let fd = mkstemp(&template)
            guard fd >= 0 else { return nil }
            unlink(template)
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }

        func start() throws -> Command {
            do {
                try process.run()
            } catch {
                throw ProcessReadError.launch(path: process.executableURL?.path ?? "?", reason: error.localizedDescription)
            }
            return self
        }

        /// The last 200 characters the tool wrote to stderr, trimmed; empty when there were none.
        func stderrTail() -> String {
            guard let stderr, (try? stderr.seek(toOffset: 0)) != nil, let data = try? stderr.readToEnd() else { return "" }
            return String(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))
        }
    }

    /// How long `run` waits for a tool, in seconds: a hung `nettop`, `ps`, `top`, `tmux` or `launchctl` costs the
    /// refresh that figure (its callers keep the previous values), not the refresh loop.
    static let timeout: Double = 5

    /// The tool's stdout once it exited with status 0. Past `timeout` seconds from the call, the tool is sent SIGKILL
    /// by the pid it was started with and `ProcessReadError.timedOut` is thrown.
    static func run(_ command: Command, timeout: Double = timeout) throws -> String {
        let deadline = DispatchTime.now() + timeout
        // Stdout still open at the deadline (the tool hung, or a child of it holds stdout) is a timeout.
        guard let data = readToEnd(command.stdout.fileHandleForReading.fileDescriptor, until: deadline),
              command.exited.wait(timeout: deadline) == .success else {
            if command.process.isRunning { kill(command.process.processIdentifier, SIGKILL) }
            command.exited.wait()
            throw ProcessReadError.timedOut(path: command.process.executableURL?.path ?? "?", seconds: timeout)
        }
        guard command.process.terminationStatus == 0 else {
            throw ProcessReadError.command(path: command.process.executableURL?.path ?? "?",
                                           status: command.process.terminationStatus, stderr: command.stderrTail())
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Everything on `fd` up to its end, read on the calling thread so the deadline holds while the tool writes; nil
    /// when the end has not come by `deadline` or the pipe could not be read (never half the output taken for all of
    /// it). Not on a pool thread: with every one of this process's worker threads
    /// busy, Dispatch starts no new one, and a read queued there began only when they finished, seconds past the
    /// deadline of a tool that had exited at once (flake, 2026-10-26).
    static func readToEnd(_ fd: Int32, until deadline: DispatchTime) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { return nil }
            let milliseconds = Int32(min((deadline.uptimeNanoseconds - now + 999_999) / 1_000_000, UInt64(Int32.max)))
            let polled = poll(&ready, 1, milliseconds)
            if polled < 0 && errno != EINTR { return nil }
            guard polled > 0 else { continue }
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count > 0 {
                data.append(contentsOf: buffer[..<count])
            } else if errno != EINTR {
                return nil
            }
        }
    }
}
