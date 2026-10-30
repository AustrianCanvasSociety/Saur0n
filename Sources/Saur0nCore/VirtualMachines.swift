// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One Virtualization.framework VM process as read at one moment: its name, the vCPUs it was given
/// (one `com.apple.virtualization.thread.cpu-N` thread each) and those threads' CPU time.
public struct VMSample: Equatable, Sendable {
    public let name: String
    public let vcpus: Int
    /// Summed user + system time of the vCPU threads, in nanoseconds (thread times are not Mach units).
    /// A QEMU VM leaves its vCPU threads unnamed, so this is its whole process's time.
    public let vcpuNanoseconds: UInt64

    public init(name: String, vcpus: Int, vcpuNanoseconds: UInt64) {
        self.name = name
        self.vcpus = vcpus
        self.vcpuNanoseconds = vcpuNanoseconds
    }
}

/// A VM row's measure against what it was given: 100 = every allotted vCPU busy for the whole window.
public struct VMUsage: Equatable, Encodable, Sendable {
    public let name: String
    public let vcpus: Int
    public let shareOfAllotted: Double

    enum CodingKeys: String, CodingKey { case name, vcpus, shareOfAllotted }

    /// `shareOfAllotted` to two decimals, like `cpuPercent`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(vcpus, forKey: .vcpus)
        try container.encode((shareOfAllotted * 100).rounded() / 100, forKey: .shareOfAllotted)
    }
}

/// VMs run as `com.apple.Virtualization.VirtualMachine`, a child of launchd rather than of the tool
/// that started them, so they are named from the files they hold open
/// (research/2026-10-16-phase2-open.md § Q3).
public enum VirtualMachines {
    static let executable = "com.apple.Virtualization.VirtualMachine"
    static let vcpuThreadPrefix = "com.apple.virtualization.thread.cpu-"

    static func isVirtualMachine(path: String?) -> Bool {
        path?.split(separator: "/").last.map(String.init) == executable
    }

    /// The VM's vCPU threads counted and their times summed; nil when any thread could not be read,
    /// since a missing vCPU would undercount the cores and inflate the share.
    static func sample(name: String, threads: [(name: String, nanoseconds: UInt64)?]) -> VMSample? {
        var vcpus = 0
        var nanoseconds: UInt64 = 0
        for thread in threads {
            guard let thread else { return nil }
            if isVCPUThread(thread.name) {
                vcpus += 1
                nanoseconds += thread.nanoseconds
            }
        }
        return VMSample(name: name, vcpus: vcpus, vcpuNanoseconds: nanoseconds)
    }

    static func isVCPUThread(_ name: String) -> Bool {
        guard name.hasPrefix(vcpuThreadPrefix) else { return false }
        let index = name.dropFirst(vcpuThreadPrefix.count)
        return !index.isEmpty && index.allSatisfy { ("0"..."9").contains($0) }
    }

    /// The Lima instance whose `disk` or `vz-efi` the VM holds (the folder holding `lima.yaml`, under
    /// any Lima home — Colima's included); else, by its disk image, the UTM bundle `<name>.utm/Data`
    /// holds it in, `Docker Desktop` for `Docker.raw`, or `VM · <folder>`; else `VM`.
    static func name(openFiles: [String], hasLimaConfig: (String) -> Bool) -> String {
        // Each file's folder as a path and as its non-empty components, and its base name.
        let files = openFiles.map { path in
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            let dirs = parts.dropLast()
            return (folder: dirs.joined(separator: "/"), dirs: dirs.filter { !$0.isEmpty }, base: parts.last.map(String.init) ?? "")
        }
        for file in files where (file.base == "disk" || file.base == "vz-efi") && hasLimaConfig(file.folder) {
            return file.dirs.last.map(String.init) ?? "VM"
        }
        // A UTM or Docker disk wins over any other image opened before it.
        let images = [".img", ".raw", ".asif"]
        let disks = files.filter { $0.base == "disk" || images.contains(where: $0.base.hasSuffix) }
        for file in disks {
            if file.base == "Docker.raw" { return "Docker Desktop" }
            if file.dirs.last == "Data", let bundle = file.dirs.dropLast().last.flatMap(utmBundleName) { return bundle }
        }
        return disks.lazy.compactMap(\.dirs.last).first.map { "VM · \($0)" } ?? "VM"
    }

    /// `X` for a path component `X.utm`; nil for anything else.
    static func utmBundleName(_ component: Substring) -> String? {
        component.hasSuffix(".utm") && component.count > 4 ? String(component.dropLast(4)) : nil
    }

    // UTM runs each QEMU VM as `QEMULauncher` with the QEMU binary as argv[1]; the same launcher also
    // runs its TPM emulator `swtpm.0` (research/2026-10-17-utm-qemu-vms.md § Q1).
    static let qemuLauncherSuffix = "/QEMULauncher.app/Contents/MacOS/QEMULauncher"

    static func isQEMU(path: String?, argv: [String]) -> Bool {
        guard let path, path.hasSuffix(qemuLauncherSuffix), argv.count > 1 else { return false }
        return argv[1].split(separator: "/").last?.hasSuffix("-softmmu") ?? false
    }

    /// A UTM QEMU VM read from its command line: named after its `.utm` bundle, with the `-smp` count
    /// as its cores and the whole process's time as its busy time; nil without a readable `-smp`.
    static func qemu(argv: [String], cpuNanoseconds: UInt64) -> VMSample? {
        smpCount(argv: argv).map { VMSample(name: qemuName(argv: argv), vcpus: $0, vcpuNanoseconds: cpuNanoseconds) }
    }

    /// The vCPUs present at boot, as QEMU reads `-smp`: every `-smp` merged key by key, the later
    /// value winning (system/vl.c, `keyval_merge`); then `cpus` (or a leading bare number), else
    /// `maxcpus`, else the product of the topology members given. Any value that is not a positive
    /// whole number, no such value at all, or a product that overflows, is nil.
    static func smpCount(argv: [String]) -> Int? {
        var texts: [String: Substring] = [:]
        var index = 0
        while index < argv.count {
            defer { index += 1 }
            guard argv[index] == "-smp" || argv[index] == "--smp" else { continue }
            guard index + 1 < argv.count else { return nil }
            index += 1
            for item in argv[index].split(separator: ",", omittingEmptySubsequences: false) {
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                texts[pair.count == 2 ? String(pair[0]) : "cpus"] = pair.last ?? ""
            }
        }
        guard !texts.isEmpty else { return nil }
        var values: [String: Int] = [:]
        for (key, text) in texts {
            guard let value = qemuNumber(text), value > 0 else { return nil }
            values[key] = value
        }
        if let cpus = values["cpus"] ?? values["maxcpus"] { return cpus }
        let topology = ["drawers", "books", "sockets", "dies", "clusters", "modules", "cores", "threads"].compactMap { values[$0] }
        guard !topology.isEmpty else { return nil }
        var product = 1
        for value in topology {
            let (next, overflow) = product.multipliedReportingOverflow(by: value)
            if overflow { return nil }
            product = next
        }
        return product
    }

    /// A whole number as QEMU's `qemu_strtou64` reads it with base 0: an optional `+`, then `0x` for
    /// hex, a leading `0` for octal, else decimal; nil for anything else.
    static func qemuNumber(_ text: Substring) -> Int? {
        let digits = text.hasPrefix("+") ? text.dropFirst() : text
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") { return Int(digits.dropFirst(2), radix: 16) }
        if digits.count > 1, digits.hasPrefix("0") { return Int(digits.dropFirst(), radix: 8) }
        return digits.first == "+" || digits.first == "-" ? nil : Int(digits, radix: 10)
    }

    /// The `.utm` bundle the VM's drives sit in, `<name>.utm/Data/…` (UTM names it after the VM;
    /// `-name` is stripped of punctuation and not used), with QEMU's `,,` read back as `,`; else
    /// `VM · QEMU`.
    static func qemuName(argv: [String]) -> String {
        for argument in argv.dropFirst() {
            let components = argument.split(separator: "/")
            for (component, next) in zip(components, components.dropFirst()) where next == "Data" {
                if let name = utmBundleName(component) { return name.replacingOccurrences(of: ",,", with: ",") }
            }
        }
        return "VM · QEMU"
    }

    /// A Lima VM's traffic leaves through its network's `limactl usernet` helper, not through the VM process
    /// (`nettop` does not list the VM at all; research 2026-10-20 § Q1). When exactly one VM row's instance lists the
    /// helper's network, that VM takes the helper's figures and the helper reads `.zero`. When several share it
    /// (Colima's `colima` and `colima-ci` both on `user-v2`), the bytes cannot be split: the helper keeps them and is
    /// named `Lima network <net> · shared by <instances>`. The per-instance `limactl hostagent` is not adopted: it
    /// carries port forwards, the host's own traffic. A VM row's instance is its name under the helper's Lima home
    /// (`name(openFiles:hasLimaConfig:)` names it after its instance folder); `limaConfig` reads a `lima.yaml`.
    static func adoptLimaNetworks(_ rows: [ProcessUsage], argv: (Int32) -> [String]?,
                                  limaConfig: (String) -> String?) -> [ProcessUsage] {
        var out = rows
        for helper in rows.indices {
            guard let found = argv(rows[helper].pid).flatMap(usernet) else { continue }
            let users = rows.indices.filter { i in
                guard let name = rows[i].vm?.name, !name.contains("/"),
                      let config = limaConfig("\(found.home)/\(name)/lima.yaml") else { return false }
                return limaNetworks(config: config).contains(found.network)
            }
            if users.count == 1, let vm = users.first {
                guard let traffic = rows[helper].network else { continue }
                out[vm].network = NetworkActivity.sum([out[vm].network, traffic])
                out[helper].network = .zero
            } else if users.count > 1 {
                let names = users.compactMap { rows[$0].vm?.name }.sorted().joined(separator: ", ")
                out[helper].readableName = "Lima network \(found.network) · shared by \(names)"
            }
        }
        return out
    }

    /// A `limactl usernet` command line's Lima home and network, from its `<home>/_networks/<net>/…` paths; nil for
    /// any other command line.
    static func usernet(argv: [String]) -> (home: String, network: String)? {
        guard argv.count > 1, argv[0].split(separator: "/").last == "limactl", argv[1] == "usernet" else { return nil }
        for argument in argv.dropFirst(2) {
            guard let marker = argument.range(of: "/_networks/") else { continue }
            let network = argument[marker.upperBound...].prefix { $0 != "/" }
            guard !network.isEmpty else { continue }
            return (String(argument[..<marker.lowerBound]), String(network))
        }
        return nil
    }

    /// The `- lima: <net>` entries of a `lima.yaml`'s top-level `networks:` block, by line scan (no YAML parser):
    /// the block runs from `networks:` to the next unindented line.
    static func limaNetworks(config: String) -> [String] {
        var inBlock = false
        var out: [String] = []
        for line in config.split(whereSeparator: \.isNewline) {
            if let first = line.first, first != " ", first != "\t", first != "-" {
                inBlock = line.hasPrefix("networks:")
                continue
            }
            guard inBlock else { continue }
            let item = line.drop { $0 == " " || $0 == "\t" || $0 == "-" }
            guard item.hasPrefix("lima:") else { continue }
            let network = item.dropFirst("lima:".count).trimmingCharacters(in: .whitespaces)
            if !network.isEmpty { out.append(network.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))) }
        }
        return out
    }

    /// A `lima.yaml`'s text; nil when unreadable.
    public static func readLimaConfig(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    /// The VM's measure over the window, or nil when it has no vCPU threads. A VM that started
    /// inside the window counts from 0; time going backwards reads 0.
    static func usage(before: VMSample?, after: VMSample, windowNanoseconds: UInt64) -> VMUsage? {
        guard after.vcpus > 0, windowNanoseconds > 0 else { return nil }
        let then = before?.vcpuNanoseconds ?? 0
        let busy = after.vcpuNanoseconds >= then ? after.vcpuNanoseconds - then : 0
        return VMUsage(name: after.name, vcpus: after.vcpus,
                       shareOfAllotted: 100 * Double(busy) / (Double(after.vcpus) * Double(windowNanoseconds)))
    }
}
