// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Thread names and open files recorded from two running Lima VMs (research/2026-10-16-phase2-open.md
// § Q3), with documentation paths in place of real ones.

private let second: UInt64 = 1_000_000_000
private let vmPath = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

private func threads(cpus: Int) -> [String] {
    (0..<cpus).map { "com.apple.virtualization.thread.cpu-\($0)" }
        + (0..<8).map { "raw-disk-image-io-\($0)" } + ["virtual-clock", "", ""]
}

private func limaFiles(_ home: String, _ name: String) -> [String] {
    ["\(home)/\(name)/vz-efi", "\(home)/\(name)/serialv.log", "\(home)/\(name)/disk", "\(home)/\(name)/cidata.iso",
     "\(home)/_disks/\(name)/datadisk"]
}

private let limaFolders: Set<String> = ["/u/.lima/dev", "/u/.colima/_lima/colima"]
private func hasLima(_ folder: String) -> Bool { limaFolders.contains(folder) }

// MARK: naming and vCPUs

private func read(_ names: [String]) -> [(name: String, nanoseconds: UInt64)?] {
    names.map { (name: $0, nanoseconds: second) }
}

@Test func vcpuCount() {
    #expect(VirtualMachines.sample(name: "dev", threads: read(threads(cpus: 6)))?.vcpus == 6)
    #expect(VirtualMachines.sample(name: "dev", threads: read(threads(cpus: 8))) == VMSample(name: "dev", vcpus: 8, vcpuNanoseconds: 8 * second))
    #expect(VirtualMachines.sample(name: "dev", threads: read(["com.apple.virtualization.thread.cpu-x", "cpu-1"]))?.vcpus == 0)
}

@Test func unreadThreadMakesNoSample() {
    // A thread that could not be read may be a vCPU: undercounting the cores would inflate the share.
    var partial = read(threads(cpus: 6))
    partial[2] = nil
    #expect(VirtualMachines.sample(name: "dev", threads: partial) == nil)
}

@Test func limaName() {
    #expect(VirtualMachines.name(openFiles: limaFiles("/u/.lima", "dev"), hasLimaConfig: hasLima) == "dev")
    #expect(VirtualMachines.name(openFiles: limaFiles("/u/.colima/_lima", "colima"), hasLimaConfig: hasLima) == "colima")
}

@Test func genericName() {
    #expect(VirtualMachines.name(openFiles: ["/u/vms/box/disk", "/u/vms/box/vz-efi"], hasLimaConfig: hasLima) == "VM · box")
    #expect(VirtualMachines.name(openFiles: ["/dev/null", "/u/x.log"], hasLimaConfig: hasLima) == "VM")
    #expect(VirtualMachines.name(openFiles: [], hasLimaConfig: hasLima) == "VM")
}

// UTM's Apple engine keeps disks in `<name>.utm/Data/<UUID>.img`; Docker Desktop's VM holds `Docker.raw`
// (research/2026-10-17-utm-qemu-vms.md § Q1, § Q5).
@Test func appleEngineAndDockerNames() {
    let utm = "/u/Library/Containers/com.utmapp.UTM/Data/Documents/Example-Mac.utm/Data"
    #expect(VirtualMachines.name(openFiles: ["\(utm)/efi_vars.fd", "\(utm)/00000000-0000-4000-8000-000000000001.img"],
                                 hasLimaConfig: hasLima) == "Example-Mac")
    #expect(VirtualMachines.name(openFiles: ["/u/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"],
                                 hasLimaConfig: hasLima) == "Docker Desktop")
    #expect(VirtualMachines.name(openFiles: ["/u/vms/Data/disk"], hasLimaConfig: hasLima) == "VM · Data")
    // A UTM or Docker disk names the VM even when another image was opened first.
    #expect(VirtualMachines.name(openFiles: ["/u/iso/installer.img", "\(utm)/00000000-0000-4000-8000-000000000001.img"],
                                 hasLimaConfig: hasLima) == "Example-Mac")
    #expect(VirtualMachines.name(openFiles: ["/u/shared/cache.raw", "/u/docker/vms/0/data/Docker.raw"],
                                 hasLimaConfig: hasLima) == "Docker Desktop")
}

@Test func isVirtualMachine() {
    #expect(VirtualMachines.isVirtualMachine(path: vmPath))
    #expect(!VirtualMachines.isVirtualMachine(path: "/usr/bin/limactl"))
    #expect(!VirtualMachines.isVirtualMachine(path: nil))
}

// MARK: UTM QEMU VMs

// The shape of UTM 4.7.5's QEMU command lines for an x86_64 (TCG) and an aarch64 (HVF) guest, recorded
// with `ps -ww -o args=` (research/2026-10-17-utm-qemu-vms.md § Q1–Q3), with documentation paths.
private let utmApp = "/Applications/UTM.app/Contents"
private let launcherPath = "\(utmApp)/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMULauncher.app/Contents/MacOS/QEMULauncher"
private let documents = "/u/Library/Containers/com.utmapp.UTM/Data/Documents"

private func qemuArgv(arch: String, bundle: String, smp: String? = "cpus=6,sockets=1,cores=6,threads=1") -> [String] {
    let data = "\(documents)/\(bundle)/Data"
    return [launcherPath, "\(utmApp)/Frameworks/qemu-\(arch)-softmmu.framework/Versions/A/qemu-\(arch)-softmmu",
            "-L", "\(utmApp)/Resources/qemu", "-S", "-spice", "unix=on,addr=/u/Library/Group Containers/spice.sock,disable-ticketing=on",
            "-nodefaults", "-vga", "none", "-device", "virtio-net-pci,mac=00:00:5E:00:53:01,netdev=net0",
            "-cpu", "host", "-accel", "hvf", "-m", "8192"]
        + (smp.map { ["-smp", $0] } ?? [])
        + ["-drive", "if=pflash,format=raw,unit=0,file.filename=\(data)/efi_vars.fd,file.locking=off",
           "-drive", "if=none,media=disk,id=drive0,file.filename=\(data)/00000000-0000-4000-8000-000000000002.qcow2,discard=unmap",
           "-name", bundle.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".utm", with: ""),
           "-uuid", "00000000-0000-4000-8000-000000000003"]
}

@Test func qemuRecognition() {
    #expect(VirtualMachines.isQEMU(path: launcherPath, argv: qemuArgv(arch: "x86_64", bundle: "Example-Linux.utm")))
    #expect(VirtualMachines.isQEMU(path: launcherPath, argv: qemuArgv(arch: "aarch64", bundle: "Example-Windows.utm")))
    // UTM's TPM emulator runs from the same launcher.
    #expect(!VirtualMachines.isQEMU(path: launcherPath, argv: [launcherPath, "\(utmApp)/Frameworks/swtpm.0.framework/Versions/A/swtpm.0",
                                                               "socket", "--tpm2"]))
    #expect(!VirtualMachines.isQEMU(path: "/usr/bin/qemu-x86_64-softmmu", argv: qemuArgv(arch: "x86_64", bundle: "A.utm")))
    #expect(!VirtualMachines.isQEMU(path: launcherPath, argv: [launcherPath]))
    #expect(!VirtualMachines.isQEMU(path: nil, argv: []))
}

@Test func qemuSample() throws {
    let linux = try #require(VirtualMachines.qemu(argv: qemuArgv(arch: "x86_64", bundle: "Example-Linux.utm"), cpuNanoseconds: 42))
    #expect(linux == VMSample(name: "Example-Linux", vcpus: 6, vcpuNanoseconds: 42))
    let windows = try #require(VirtualMachines.qemu(argv: qemuArgv(arch: "aarch64", bundle: "Example-Windows.utm"), cpuNanoseconds: 7))
    #expect(windows == VMSample(name: "Example-Windows", vcpus: 6, vcpuNanoseconds: 7))
}

@Test func smpCount() {
    func count(_ argv: [String]) -> Int? { VirtualMachines.smpCount(argv: argv) }
    #expect(count(["q", "-smp", "4"]) == 4)
    #expect(count(["q", "-smp", "cpus=4,sockets=1"]) == 4)
    #expect(count(["q", "-smp", "sockets=2,cores=2,threads=1"]) == 4)
    #expect(count(["q", "-smp", "2,maxcpus=8"]) == 2)
    #expect(count(["q", "-smp", "maxcpus=8"]) == 8)
    #expect(count(["q", "-smp", "2", "-m", "1024", "-smp", "cpus=3"]) == 3)    // the last value wins, as in QEMU
    #expect(count(["q", "--smp", "3"]) == 3)
}

@Test func smpRepeatedMerges() {
    // QEMU merges every -smp key by key, the later value winning (system/vl.c keyval_merge).
    func count(_ argv: [String]) -> Int? { VirtualMachines.smpCount(argv: argv) }
    #expect(count(["q", "-smp", "4", "-smp", "sockets=1"]) == 4)
    #expect(count(["q", "-smp", "cores=2", "--smp", "threads=2"]) == 4)
    #expect(count(["q", "-smp", "cpus=x", "-smp", "2"]) == 2)    // values are read after the merge
    #expect(count(["q", "-smp", "2", "-smp", "cpus=x"]) == nil)
}

@Test func smpNumbersAsQEMUReadsThem() {
    // qemu_strtou64 with base 0: a sign, hex and octal as strtoull reads them.
    func count(_ argv: [String]) -> Int? { VirtualMachines.smpCount(argv: argv) }
    #expect(count(["q", "-smp", "+4"]) == 4)
    #expect(count(["q", "-smp", "cpus=0x10"]) == 16)
    #expect(count(["q", "-smp", "010"]) == 8)
    #expect(count(["q", "-smp", "08"]) == nil)
    #expect(count(["q", "-smp", "0x"]) == nil)
    #expect(count(["q", "-smp", "+"]) == nil)
}

@Test func smpMalformedIsNoVM() {
    func count(_ argv: [String]) -> Int? { VirtualMachines.smpCount(argv: argv) }
    #expect(count(["q", "-smp", "cpus=x"]) == nil)
    #expect(count(["q", "-smp", "cpus="]) == nil)
    #expect(count(["q", "-smp", "cpus=-2"]) == nil)
    #expect(count(["q", "-smp", "cpus=0"]) == nil)
    #expect(count(["q", "-smp"]) == nil)
    #expect(count(["q", "-m", "1024"]) == nil)
    #expect(VirtualMachines.qemu(argv: qemuArgv(arch: "x86_64", bundle: "A.utm", smp: nil), cpuNanoseconds: 1) == nil)
}

@Test func smpTopologyOverflowIsNoVM() {
    #expect(VirtualMachines.smpCount(argv: ["q", "-smp", "sockets=65536,dies=65536,cores=65536,threads=65536"]) == nil)
    #expect(VirtualMachines.smpCount(argv: ["q", "-smp", "sockets=\(Int.max),cores=2"]) == nil)
}

@Test func qemuName() {
    #expect(VirtualMachines.qemuName(argv: qemuArgv(arch: "x86_64", bundle: "A-B-C.utm")) == "A-B-C")
    // QEMU option values escape a comma as `,,`; UTM replaces commas in its own bundle names, but a
    // shortcut VM keeps whatever folder name it has.
    #expect(VirtualMachines.qemuName(argv: ["q", "-drive", "file.filename=/u/a,,b/Ex,,ample.utm/Data/d.qcow2,if=none"]) == "Ex,ample")
    #expect(VirtualMachines.qemuName(argv: ["q", "-drive", "file.filename=/u/vms/plain.qcow2"]) == "VM · QEMU")
    #expect(VirtualMachines.qemuName(argv: ["q", "-drive", "file.filename=/u/.utm/d.qcow2"]) == "VM · QEMU")
    // Only a bundle holding the drive in its Data folder names the VM, wherever it sits.
    #expect(VirtualMachines.qemuName(argv: ["q", "-name", "/u/Other.utm", "-drive", "file.filename=/u/Real.utm/Data/d.qcow2"]) == "Real")
    #expect(VirtualMachines.qemuName(argv: ["q", "/Top.utm/Data/d.qcow2"]) == "Top")
}

@Test func qemuShareUnclamped() throws {
    // QEMU's own I/O work counts with its vCPUs: 7 s of process time in 1 s on 6 cores reads above 100%.
    func sample(at uptime: UInt64, cpu: UInt64) throws -> ProcessListSample {
        let vm = ProcessIdentity(pid: 2112, ppid: 2100, uid: 501, user: "u", startMicroseconds: 7, comm: "QEMULauncher", path: launcherPath)
        let argv = qemuArgv(arch: "x86_64", bundle: "Example-Linux.utm")
        return ProcessListSample(uptimeNanoseconds: uptime, processes: [vm],
                                 taskInfo: [2112: ProcessCounters(cpuNanoseconds: cpu, residentBytes: 1 << 30)], ps: [:],
                                 arguments: [2112: ProcessArguments(argv: argv, environment: [:])],
                                 vms: [2112: try #require(VirtualMachines.qemu(argv: argv, cpuNanoseconds: cpu))])
    }
    let row = try vmRow(before: try sample(at: 10 * second, cpu: 3 * second), after: try sample(at: 11 * second, cpu: 10 * second))
    let vm = try #require(row.vm)
    #expect(vm.name == "Example-Linux" && vm.vcpus == 6)
    #expect(abs(vm.shareOfAllotted - 100.0 * 7 / 6) < 1e-9)
    #expect(abs(row.cpuPercent - 100.0 * 7 / 18) < 1e-9)
    #expect(row.readableName == "VM: Example-Linux · 6 cores")
}

// MARK: rows

private func vmSample(at uptime: UInt64, cpu: UInt64, vcpu: UInt64, cpus: Int = 6, present: Bool = true) -> ProcessListSample {
    let vm = ProcessIdentity(pid: 1221, ppid: 1, uid: 501, user: "u", startMicroseconds: 7, comm: "com.apple.Virtua", path: vmPath)
    return ProcessListSample(
        uptimeNanoseconds: uptime, processes: present ? [vm] : [],
        taskInfo: present ? [1221: ProcessCounters(cpuNanoseconds: cpu, residentBytes: 1 << 30)] : [:], ps: [:],
        vms: present ? [1221: VMSample(
            name: VirtualMachines.name(openFiles: limaFiles("/u/.colima/_lima", "colima"), hasLimaConfig: hasLima),
            vcpus: cpus, vcpuNanoseconds: vcpu)] : [:])
}

private func vmRow(before: ProcessListSample, after: ProcessListSample) throws -> ProcessUsage {
    try #require(ProcessSample.usage(before: before, after: after, cpuCount: 18, kernelTask: nil).first)
}

@Test func shareOfAllotted() throws {
    // Two of six vCPUs busy for one second; the process spent a little more on I/O and the clock.
    let row = try vmRow(before: vmSample(at: 10 * second, cpu: 5 * second, vcpu: 4 * second),
                        after: vmSample(at: 11 * second, cpu: 7 * second + second / 20, vcpu: 6 * second))
    let vm = try #require(row.vm)
    #expect(vm.name == "colima" && vm.vcpus == 6)
    #expect(abs(vm.shareOfAllotted - 100.0 * 2 / 6) < 1e-9)
    #expect(abs(row.cpuPercent - 100.0 * 2.05 / 18) < 1e-9)    // the whole process counts toward the machine
    #expect(row.readableName == "VM: colima · 6 cores")
}

@Test func timeWentBackwardsReadsZero() throws {
    let row = try vmRow(before: vmSample(at: 10 * second, cpu: 5 * second, vcpu: 6 * second),
                        after: vmSample(at: 11 * second, cpu: 5 * second, vcpu: 4 * second))
    #expect(row.vm?.shareOfAllotted == 0)
}

@Test func newVMCountsFromZero() throws {
    let row = try vmRow(before: vmSample(at: 10 * second, cpu: 0, vcpu: 0, present: false),
                        after: vmSample(at: 11 * second, cpu: second, vcpu: second))
    #expect(abs((row.vm?.shareOfAllotted ?? -1) - 100.0 / 6) < 1e-9)
}

@Test func vmUnreadInFirstSampleHasNoShare() throws {
    // Counting from 0 without the first reading would put the VM's whole lifetime into one window.
    let first = vmSample(at: 10 * second, cpu: 5 * second, vcpu: 4 * second)
    let unread = ProcessListSample(uptimeNanoseconds: first.uptimeNanoseconds, processes: first.processes,
                                   taskInfo: first.taskInfo, ps: [:], vms: [:])
    let row = try vmRow(before: unread, after: vmSample(at: 11 * second, cpu: 7 * second, vcpu: 600 * second))
    #expect(row.vm == nil)
    #expect(abs(row.cpuPercent - 100.0 * 2 / 18) < 1e-9)
}

@Test func vmExitingBetweenSamplesIsDropped() throws {
    let rows = try ProcessSample.usage(before: vmSample(at: 10 * second, cpu: 5 * second, vcpu: 4 * second),
                                       after: vmSample(at: 11 * second, cpu: 0, vcpu: 0, present: false),
                                       cpuCount: 18, kernelTask: nil)
    #expect(rows.isEmpty)
}

@Test func noVCPUThreadsIsNoVM() throws {
    let row = try vmRow(before: vmSample(at: 10 * second, cpu: 0, vcpu: 0, cpus: 0),
                        after: vmSample(at: 11 * second, cpu: second, vcpu: 0, cpus: 0))
    #expect(row.vm == nil)
}

@Test func vmTableAndJSON() throws {
    let row = try vmRow(before: vmSample(at: 10 * second, cpu: 5 * second, vcpu: 4 * second),
                        after: vmSample(at: 11 * second, cpu: 7 * second, vcpu: 6 * second))
    #expect(ProcessSample.table([row]).hasSuffix("com.apple.Virtualization.VirtualMachine  (VM: colima · 6 cores · 33.3% of its cores)"))

    let plain = ProcessUsage(pid: 9, ppid: 1, uid: 501, user: "u", path: nil, name: "p", cpuPercent: 0, residentBytes: 0, source: .ps)
    let snapshot = try Snapshot(topology: CoreTopology.singleLevel(logicalCPUCount: 1), load: CPULoad(perCPU: [0], total: 0),
                                intervalSeconds: 1, processes: [row, plain])
    let object = try #require(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
    let processes = try #require(object["processes"] as? [[String: Any]])
    let vm = try #require(processes[0]["vm"] as? [String: Any])
    #expect(Set(vm.keys) == ["name", "vcpus", "shareOfAllotted"])
    #expect(vm["name"] as? String == "colima")
    #expect(vm["vcpus"] as? Int == 6)
    #expect(vm["shareOfAllotted"] as? Double == 33.33)
    #expect(processes[1]["vm"] is NSNull)
}
