// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing
@testable import Saur0nCore

// Goal: what counts as an Apple service (research 2026-10-26 § 4) — all four checks, never an Apple signature alone —
// so the watcher can warn about one without pausing it, while `sleep`, a signed shell and a launchd job running a script
// stay actionable. Method: rows built to each service shape (documentation values only) through `isAppleService`;
// the platform bit read from the live kernel for launchd; its propagation from the process table to the row.

private let servicePath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/"
    + "Support/mdworker_shared"

/// An Apple service as the kernel reports it: platform bit set, under a service path, a child of launchd leading its own
/// process group, running its own binary. Arguments change one fact at a time.
private func service(_ pid: Int32 = 500, _ name: String = "mdworker_shared", path: String? = servicePath,
                     parent: Int32 = 1, group: Int32?? = .some(nil), platform: Bool = true,
                     command: String? = nil) -> ProcessUsage {
    var row = ProcessUsage(pid: pid, ppid: parent, uid: 501, user: "user", path: path, name: name, cpuPercent: 0.75,
                           residentBytes: 1 << 20, source: .libproc, exitedChildrenCpuPercent: 0)
    row.startMicroseconds = UInt64(pid) * 1_000
    row.processGroup = switch group {
    case .none: nil    // unread
    case .some(.none): pid    // leads its own group
    case .some(.some(let value)): value
    }
    row.platformBinary = platform
    row.command = command ?? name
    return row
}

@Test func anAppleServiceMeetsAllFourChecks() {
    #expect(service().isAppleService)
    for path in ["/System/Library/PrivateFrameworks/Example.framework/XPCServices/SetStoreUpdateService",
                 "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/com.apple.WebKit.WebContent",
                 "/usr/libexec/cfprefsd", "/usr/sbin/distnoted"] {
        #expect(service(path: path).isAppleService, "\(path)")
    }
}

@Test func theKernelsPlatformBitIsRequiredNotJustTheName() {
    #expect(!service(path: "/tmp/example/mdworker_shared").isAppleService)    // a forged namesake in a temp folder
    #expect(!service(platform: false).isAppleService)    // right path, but the kernel does not call the code Apple's
}

@Test func theToolsARunawayIsMadeOfAreNotAppleServices() {
    // `/bin/sleep` under launchd (the 2026-10-22 shape): platform bit set, but a tool path and no group of its own.
    #expect(!service(600, "sleep", path: "/bin/sleep", group: 4_000).isAppleService)
    // Even leading its own group, a path under /bin or /usr/bin is a tool.
    #expect(!service(600, "sleep", path: "/bin/sleep").isAppleService)
    #expect(!service(601, "perl", path: "/usr/bin/perl").isAppleService)
}

@Test func aLaunchdJobRunningAScriptIsNotAnAppleService() {
    // Condition 4: even from a service path, a shell or interpreter keyed by its script is not "the service".
    #expect(!service(700, "bash", path: "/usr/libexec/job-runner", command: "job.sh").isAppleService)
    // An interpreter with no script is not a service either.
    #expect(!service(701, "bash", path: "/usr/libexec/job-runner").isAppleService)
    #expect(!service(702, "python3.12", path: "/usr/libexec/py").isAppleService)
}

@Test func theParentAndTheGroupHaveToBeLaunchdsAndItsOwn() {
    #expect(!service(group: 4_000).isAppleService)    // led by someone else: an orphaned tool keeps its launcher's group
    #expect(!service(group: .none).isAppleService)    // unread
    #expect(!service(parent: 400).isAppleService)
}

@Test func aPathNoServiceHasDoesNotQualifyByPrefixLookalike() {
    #expect(!service(path: "/System/Library2/x/mdworker_shared").isAppleService)
    #expect(!service(path: "/usr/libexec").isAppleService)
    #expect(!service(path: nil).isAppleService)    // the /bin/ps fallback's rows carry no path: the safe side
}

@Test func theBitIsRejudgedWhenAPidIsReusedByAnUnsignedBinary() {
    #expect(service().isAppleService)
    // The service exits; the same pid comes back as an unsigned binary with a later start time.
    var reused = service(path: "/opt/example/bin/tool", platform: false)
    reused.startMicroseconds += 5_000_000
    #expect(!reused.isAppleService)
}

@Test func theKernelReportsLaunchdAsAPlatformBinaryAndAMissingPidAsNot() {
    #expect(ProcessReaders.platformBinary(1))
    #expect(!ProcessReaders.platformBinary(Int32.max))
}

@Test func theBitTravelsFromTheProcessTableToTheRow() throws {
    func list(_ uptime: UInt64, _ cpu: UInt64) -> ProcessListSample {
        let counters = ProcessCounters(cpuNanoseconds: cpu, residentBytes: 4096)
        return ProcessListSample(uptimeNanoseconds: uptime, processes: [identity(500, platform: true), identity(501, platform: false)],
                                 taskInfo: [500: counters, 501: counters], ps: [:], childrenCPU: [:], rusageCPU: [:])
    }
    let rows = try ProcessSample.usage(before: list(0, 0), after: list(1_000_000_000, 1), cpuCount: 4, kernelTask: nil)
    #expect(rows.first { $0.pid == 500 }?.platformBinary == true)
    #expect(rows.first { $0.pid == 501 }?.platformBinary == false)
}

@Test func theBitIsNotInTheCommandLinesJSON() throws {
    let data = try JSONEncoder().encode(service())
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["platformBinary"] == nil && object["isAppleService"] == nil)
}

private func identity(_ pid: Int32, platform: Bool) -> ProcessIdentity {
    ProcessIdentity(pid: pid, ppid: 1, uid: 501, user: "user", startMicroseconds: 1_000, comm: "proc", path: servicePath,
                    processGroup: pid, platformBinary: platform)
}
