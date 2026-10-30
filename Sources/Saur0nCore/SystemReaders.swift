// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit

/// Thin readers over sysctl, the IO registry and Mach host statistics. All decisions live in the pure types they feed.
public enum SystemReaders {
    /// The Mac's core topology: perf levels from sysctl, CPU → level from the IO registry.
    public static func coreTopology() throws -> CoreTopology {
        try CoreTopology.read(sysctlInt: sysctlInt, sysctlString: sysctlString, clusterTypeByCPU: clusterTypeByCPU)
    }

    /// `cluster-type` of each `IODeviceTree:/cpus/cpuN`, keyed by N (which equals the
    /// `host_processor_info` index — research/2026-10-16-phase1-topup.md § Q2).
    static func clusterTypeByCPU() -> [Int: String] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [:] }
        defer { IOObjectRelease(cpus) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var entries: [(name: String?, clusterType: Data?)] = []
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            var nameBuf = [CChar](repeating: 0, count: 128)
            let name = IORegistryEntryGetName(child, &nameBuf) == KERN_SUCCESS ? cString(nameBuf) : nil
            let raw = IORegistryEntryCreateCFProperty(child, "cluster-type" as CFString,
                                                      kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
            entries.append((name, raw))
        }
        return clusterTypes(entries)
    }

    /// Letter of each `cpuN` child, keyed by N; other children are skipped. A child whose name, or a
    /// CPU whose `cluster-type`, cannot be read empties the map — the registry-unreadable error —
    /// rather than leaving a CPU out of its group.
    static func clusterTypes(_ entries: [(name: String?, clusterType: Data?)]) -> [Int: String] {
        var out: [Int: String] = [:]
        for (name, raw) in entries {
            guard let name else { return [:] }
            guard name.hasPrefix("cpu"), let index = Int(name.dropFirst(3)) else { continue }
            guard let raw else { return [:] }
            out[index] = cString(raw)
        }
        return out
    }

    /// Cumulative per-CPU ticks from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, indexed by CPU.
    public static func cpuTicks() throws -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { throw CPULoadError.unreadable(kernReturn: result) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        return try cpuTicks(UnsafeBufferPointer(start: info, count: Int(infoCount)), cpuCount: Int(cpuCount))
    }

    /// `CPU_STATE_MAX` counters per CPU; a buffer shorter than `cpuCount` of those is an error.
    static func cpuTicks(_ info: UnsafeBufferPointer<integer_t>, cpuCount: Int) throws -> [CPUTicks] {
        let stride = Int(CPU_STATE_MAX)
        guard info.count >= cpuCount * stride else {
            throw CPULoadError.shortTickBuffer(values: info.count, cpus: cpuCount)
        }
        func counter(_ cpu: Int, _ state: Int32) -> UInt32 { UInt32(bitPattern: info[cpu * stride + Int(state)]) }
        return (0..<cpuCount).map { cpu in
            CPUTicks(user: counter(cpu, CPU_STATE_USER), system: counter(cpu, CPU_STATE_SYSTEM),
                     idle: counter(cpu, CPU_STATE_IDLE), nice: counter(cpu, CPU_STATE_NICE))
        }
    }

    /// The kernel's 1-, 5- and 15-minute load averages from `getloadavg`; nil unless all three were read.
    public static func loadAverage() -> LoadAverage? {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return nil }
        return LoadAverage(oneMinute: values[0], fiveMinutes: values[1], fifteenMinutes: values[2])
    }

    struct MemoryUnreadable: Error { let kernReturn: kern_return_t }

    /// The Mach host port, taken once: each `mach_host_self()` call adds a send right to it.
    static let host = mach_host_self()

    /// Used memory from `host_statistics64(HOST_VM_INFO64)` — active, wired and compressed pages times the kernel's
    /// page size — against `hw.memsize`; the same read `availableMemory()` makes (`memorySample()`).
    public static func memoryUsage() throws -> MemoryUsage {
        try memorySample().usage
    }

    struct SysctlUnreadable: Error { let name: String }

    /// The memory counters one watcher tick reads (`AvailableMemory`): the available-page composite the floor
    /// projects, the used figures the live status carries, and swap as a confirmer. The same read `memoryUsage()`
    /// makes (`memorySample()`).
    public static func availableMemory() throws -> AvailableMemory {
        try memorySample().available
    }

    /// One memory read, both figures (Delphi 40d78a09): the available-page composite the floor projects and the used
    /// figures the Memory column shows, built from one `host_statistics64(HOST_VM_INFO64)` and one page-size result.
    /// The one entry point a caller needs when it wants both; the two single-figure readers forward here.
    public static func memorySample() throws -> (available: AvailableMemory, usage: MemoryUsage) {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { throw MemoryUnreadable(kernReturn: result) }
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        guard pageResult == KERN_SUCCESS else { throw MemoryUnreadable(kernReturn: pageResult) }
        let physical = ProcessInfo.processInfo.physicalMemory
        let available = AvailableMemory(freePages: UInt64(info.free_count), inactivePages: UInt64(info.inactive_count),
                                         speculativePages: UInt64(info.speculative_count),
                                         purgeablePages: UInt64(info.purgeable_count),
                                         activePages: UInt64(info.active_count), wiredPages: UInt64(info.wire_count),
                                         compressedPages: UInt64(info.compressor_page_count), pageSize: UInt64(pageSize),
                                         physicalBytes: physical, swapUsedBytes: swapUsed())
        let usage = MemoryUsage(activePages: UInt64(info.active_count), wiredPages: UInt64(info.wire_count),
                                compressedPages: UInt64(info.compressor_page_count), pageSize: UInt64(pageSize),
                                physicalBytes: physical)
        return (available, usage)
    }

    /// Used swap in bytes from `vm.swapusage`; nil when it cannot be read.
    static func swapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    /// An integer sysctl: nil when the key does not exist (ENOENT), an error when it exists but
    /// cannot be read or is not 4 or 8 bytes.
    static func sysctlInt(_ name: String) throws -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else {
            if errno == ENOENT { return nil }
            throw SysctlUnreadable(name: name)
        }
        switch size {
        case 4:
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { throw SysctlUnreadable(name: name) }
            return Int(value)
        case 8:
            var value: Int64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { throw SysctlUnreadable(name: name) }
            return Int(value)
        default:
            throw SysctlUnreadable(name: name)
        }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return cString(buf)
    }

    /// NUL-terminated C bytes as a String, up to the first NUL (or all of them, when none).
    static func cString<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func cString(_ buf: [CChar]) -> String { buf.withUnsafeBytes { cString($0) } }
}

/// Readers behind `DescriptionSources`: man page folders, launchd plists, bundle Info.plists.
extension DescriptionSources {
    /// Descriptions for the processes in `sample`: the man page of each process name with no table
    /// entry and the Info.plist of each bundle, each read once, from the Mac's own man folders
    /// (`/etc/manpaths`, then the cryptex that holds newer system pages); the launchd plists in full.
    public static func load(for sample: ProcessListSample) -> DescriptionSources {
        let configured = ((try? String(contentsOfFile: "/etc/manpaths", encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var sources = DescriptionSources(
            launchdLabels: launchdIndex(folders: ["/System/Library/LaunchDaemons", "/System/Library/LaunchAgents",
                                                  "/Library/LaunchDaemons", "/Library/LaunchAgents"]),
            manPages: manIndex(folders: configured + ["/System/Cryptexes/App/usr/share/man"]))
        sources.extend(for: sample)
        return sources
    }

    /// The one-liner of `name`'s man page at `page`, scoped to the folder it describes; nil when unreadable.
    static func readOneLiner(name: String, page: String) -> ManLine? {
        guard let scope = ManScope(page: page), let source = regularFileContents(page, followLinks: true),
              let text = DaemonDescriptions.oneLiner(page: String(decoding: source, as: UTF8.self), name: name) else {
            return nil
        }
        return ManLine(text: text, scope: scope)
    }

    /// Program name → page path over each folder's `man8` then `man1`, whatever a file's suffix
    /// (some `.8` pages sit in `man1`); the name is the filename up to its last dot. First wins.
    /// Compressed pages (`.gz`, `.bz2`, `.xz`, `.Z`) are left out: Saur0n reads page source as is.
    static func manIndex(folders: [String]) -> [String: String] {
        let compressed = [".gz", ".bz2", ".xz", ".Z"]
        var index: [String: String] = [:]
        for folder in folders {
            for section in ["man8", "man1"] {
                let dir = folder + "/" + section
                for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                where !compressed.contains(where: file.hasSuffix) {
                    guard let dot = file.lastIndex(of: "."), dot > file.startIndex else { continue }
                    let name = String(file[..<dot])
                    if index[name] == nil { index[name] = dir + "/" + file }
                }
            }
        }
        return index
    }

    /// Executable path → `Label` over every plist in `folders`; first wins.
    static func launchdIndex(folders: [String]) -> [String: String] {
        var index: [String: String] = [:]
        for folder in folders {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where file.hasSuffix(".plist") {
                guard let plist = plistDictionary(folder + "/" + file, followLinks: true),
                      let label = plist["Label"] as? String, let program = launchdProgram(plist),
                      index[program] == nil else { continue }
                index[program] = label
            }
        }
        return index
    }

    /// `CFBundleDisplayName`, else `CFBundleName`, from the bundle's `Contents/Info.plist`.
    static func bundleDisplayName(_ root: String) -> String? {
        guard let info = plistDictionary(root + "/Contents/Info.plist") else { return nil }
        return info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
    }

    /// A property-list file's top-level dictionary, read through `regularFileContents`.
    static func plistDictionary(_ path: String, followLinks: Bool = false) -> [String: Any]? {
        guard let data = regularFileContents(path, followLinks: followLinks) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// The bytes of a regular file of at most `limit` bytes, else nil. Any user's process path can
    /// name a bundle, so its Info.plist may be a pipe (open would block), endless (`/dev/zero`) or a
    /// link to a device (opening a serial port can reset the board on it). Without `followLinks`,
    /// `O_NOFOLLOW` refuses a link as the file itself; links among the folders above it are still
    /// followed. Either way, whatever is reached must be a regular file. Real Info.plists are tens of
    /// kilobytes and never links; the system's man pages and launchd plists include a few links
    /// (`cupsdisable.8` → `cupsenable.8`), so those reads follow them — after `stat` finds a regular
    /// file at the end, since `/usr/local`'s pages are the user's to link anywhere.
    static func regularFileContents(_ path: String, limit: Int = 1 << 20, followLinks: Bool = false) -> Data? {
        var target = stat()
        if followLinks, stat(path, &target) != 0 || target.st_mode & S_IFMT != S_IFREG { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | (followLinks ? 0 : O_NOFOLLOW))
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { return nil }
        return try? handle.read(upToCount: limit)
    }
}

/// Readers behind `SessionSources`: the Claude Code session registry, tmux panes, terminal ttys.
extension SystemReaders {
    /// `~/.claude/sessions`: one `<pid>.json` per live Claude Code session.
    public static let sessionRegistryFolder = NSHomeDirectory() + "/.claude/sessions"

    /// The bytes of each `*.json` regular file (links not followed, at most 1 MiB) in `folder`; a
    /// missing or unreadable folder or file is left out, never an error.
    public static func sessionRegistry(folder: String = sessionRegistryFolder) -> [Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
            .compactMap { DescriptionSources.regularFileContents(folder + "/" + $0) }
    }

    /// `tmux list-panes -a` → pane pid → session name; `[:]` when tmux is not installed, has no
    /// server, fails, or takes over 2 seconds (the client Saur0n started is then terminated). The
    /// output is read after exit: a few dozen bytes per pane, far inside a pipe's buffer.
    public static func tmuxPanes(deadline seconds: Double = 2) -> [Int32: String] {
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [:] }
        let command = ProcessReaders.Command(path: tmux, arguments: ["list-panes", "-a", "-F", "#{pane_pid} #{session_name}"])
        guard (try? command.start()) != nil else { return [:] }
        guard command.exited.wait(timeout: .now() + seconds) == .success else {
            command.process.terminate()
            command.exited.wait()
            return [:]
        }
        guard command.process.terminationStatus == 0 else { return [:] }
        let data = command.stdout.fileHandleForReading.readDataToEndOfFile()
        return SessionGroups.parseTmuxPanes(String(decoding: data, as: UTF8.self))
    }

    /// The controlling terminal's name (`ttys003`) of `pid`; nil when it has none or cannot be read.
    public static func ttyName(pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        let text = String(cString: name)
        return text.isEmpty || text == "??" ? nil : text
    }
}
