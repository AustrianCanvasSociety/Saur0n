// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: a plain one-line description for a process, from Saur0n's table, its man page, its app or
// its launchd label. Method: synthetic page sources written for these tests, in the shapes the Mac's pages take
// (research/2026-10-16-phase2-open.md § Q1) — no text from any real page.

private func line(_ page: String, _ name: String = "exampled") -> String? {
    DaemonDescriptions.oneLiner(page: page, name: name)
}

// MARK: page parser

@Test func ndOneLine() {
    #expect(line("""
    .Dd May 1, 2020
    .Dt EXAMPLED 8
    .Sh NAME
    .Nm exampled
    .Nd example settings server
    .Sh SYNOPSIS
    """) == "example settings server")
}

@Test func ndContinuedByXr() {
    #expect(line("""
    .Sh NAME
    .Nm exampled
    .Nd is a
    .Xr launchd 8
    job that serves examples
    .Sh SYNOPSIS
    """) == "is a launchd(8) job that serves examples")
}

// A bare `.` is troff's empty request, not text; a quoted `.Nd` argument loses its quotes.
@Test func ndEmptyRequestAndQuotes() {
    #expect(line("""
    .Sh NAME
    .Nm exampled
    .Nd shows example processes
    .
    .Sh SYNOPSIS
    """) == "shows example processes")
    #expect(line("""
    .Sh NAME
    .Nm exampled
    .Nd "Example and Sample"
    .Sh SYNOPSIS
    """) == "Example and Sample")
    #expect(line("""
    .Sh NAME
    .Nm exampled
    .Nd "first part" "second part"
    .Sh SYNOPSIS
    """) == #""first part" "second part""#)
}

@Test func manNameSection() {
    #expect(line(".TH EXAMPLED 8\n.SH NAME\nexampled \\- serves examples to other processes\n.SH SYNOPSIS\n")
            == "serves examples to other processes")
    #expect(line(".SH \"NAME\"\nExampleServer \\- Example window and event daemon.\n.SH \"SYNOPSIS\"\n", "ExampleServer")
            == "Example window and event daemon.")
    #expect(line(".SH NAME\nexampled - plain dash form\n.SH DESCRIPTION\n") == "plain dash form")
}

/// rst2man puts its macro definitions inside NAME; their bodies are not page text.
@Test func macroDefinitionsAreNotText() {
    #expect(line("""
    .SH NAME
    exampled \\- serves examples
    .
    .nr rst2man-indent-level 0
    .
    .de1 rstReportMargin
    \\\\$1 \\\\n[an-margin]
    level \\\\n[rst2man-indent-level]
    ..
    .de UNINDENT
    .RE
    ..
    .ig
    ignored text
    ..
    .SH SYNOPSIS
    """) == "serves examples")
}

@Test func crlfAndComments() {
    #expect(line(".\\\" a comment line\r\n.Sh NAME   \\\" trailing comment\r\n.Nm exampled\r\n.Nd example daemon  \\\" note\r\n.Sh SYNOPSIS\r\n")
            == "example daemon")
}

@Test func escapes() {
    #expect(line(".Sh NAME\n.Nd \\fBbold\\fR and \\f[I]italic\\f[R] \\(em a\\-b \\&c \\(aqq\\(aq\n.Sh X\n")
            == "bold and italic — a-b c 'q'")
}

@Test func templateFallsToDescription() {
    #expect(line("""
    .Sh NAME                 \\" Section Header - required
    .Nm exampled
    .Sh SYNOPSIS
    .Nm
    .Sh DESCRIPTION
    .Nm
    is a daemon used for example purposes.
    .Nm
    was introduced long ago.
    """) == "exampled is a daemon used for example purposes.")
}

@Test func emptyPage() {
    #expect(line(".Sh NAME\n.Nm exampled\n.Sh SYNOPSIS\n.Nm\n") == nil)
    #expect(line("") == nil)
}

// MARK: man index

@Test func manIndex() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("saur0n-man-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    for dir in ["a/man1", "a/man8", "b/man8"] {
        try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    for file in ["a/man1/oddd.8", "a/man1/both.1", "a/man8/both.8", "a/man8/Spaced Agent.8", "b/man8/both.8", "b/man8/onlyb.8",
                 "a/man1/zipped.1.gz"] {
        try Data().write(to: root.appendingPathComponent(file))
    }
    let index = DescriptionSources.manIndex(folders: [root.appendingPathComponent("a").path,
                                                      root.appendingPathComponent("missing").path,
                                                      root.appendingPathComponent("b").path])
    #expect(index["oddd"]?.hasSuffix("a/man1/oddd.8") == true)
    #expect(index["both"]?.hasSuffix("a/man8/both.8") == true)
    #expect(index["Spaced Agent"]?.hasSuffix("a/man8/Spaced Agent.8") == true)
    #expect(index["onlyb"]?.hasSuffix("b/man8/onlyb.8") == true)
    // A compressed page would be read as its compressed bytes, so it is not indexed at all.
    #expect(index["zipped.1"] == nil)
    #expect(index["zipped"] == nil)
}

// MARK: layered lookup

private let sources = DescriptionSources(
    manLines: ["exampled": "example settings server", "mds_stores": "page text that the table overrides",
               "localtool": ManLine(text: "a tool from /usr/local", scope: .under("/usr/local"))],
    bundleNames: ["/Applications/Firefox.app": "Firefox", "/Applications/Same.app": "samehelper"],
    launchdLabels: ["/usr/libexec/labelledd": "com.example.labelled"])

/// Anyone can name a program kernel_task or exampled; only one in a SIP-protected folder (or with
/// the kernel's pid 0, which has no path) gets the system's description.
@Test func systemLabelsOnlyForSystemPrograms() {
    let impostor = NSTemporaryDirectory() + "kernel_task"
    #expect(sources.describe(pid: 9, name: "kernel_task", path: impostor) == nil)
    #expect(sources.describe(pid: 0, name: "kernel_task", path: nil) == "the macOS kernel")
    // A program whose file was deleted has no path either: it is not the kernel.
    #expect(sources.describe(pid: 9, name: "kernel_task", path: nil) == nil)
    #expect(sources.describe(pid: 9, name: "exampled", path: nil) == nil)
    #expect(sources.describe(pid: 9, name: "exampled", path: "/fixtures/example/bin/exampled") == nil)
    #expect(sources.describe(pid: 9, name: "exampled", path: "/usr/local/bin/exampled") == nil)
    #expect(sources.describe(pid: 9, name: "exampled", path: "/usr/sbin/exampled") == "example settings server")
    #expect(sources.describe(pid: 9, name: "mds_stores", path: "/opt/example/mds_stores") == nil)
    // A /usr/local page describes /usr/local programs only.
    #expect(sources.describe(pid: 9, name: "localtool", path: "/usr/local/bin/localtool") == "a tool from /usr/local")
    #expect(sources.describe(pid: 9, name: "localtool", path: "/usr/bin/localtool") == nil)
    #expect(sources.describe(pid: 9, name: "localtool", path: "/fixtures/example/localtool") == nil)
    // Labels found by the program's own path are not names anyone can borrow.
    #expect(sources.describe(pid: 9, name: "crashhelper", path: "/fixtures/example/Firefox.app/Contents/MacOS/crashhelper") == nil)
}

@Test func systemProgramPaths() {
    for path in ["/System/Library/CoreServices/launchservicesd", "/usr/libexec/trustd", "/bin/zsh", "/sbin/launchd",
                 "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtect"] {
        #expect(DescriptionSources.isSystemProgram(path), "\(path)")
    }
    for path in ["/usr/local/bin/tool", "/opt/homebrew/bin/node", "/fixtures/example/bin/trustd", "/private/tmp/kernel_task",
                 "/Library/LaunchDaemons/x", "/usrx/bin/tool", "/Systemd/x"] {
        #expect(!DescriptionSources.isSystemProgram(path), "\(path)")
    }
}

@Test func manPageScope() {
    #expect(ManScope(page: "/usr/share/man/man8/trustd.8") == .system)
    #expect(ManScope(page: "/System/Cryptexes/App/usr/share/man/man1/example.1") == .system)
    #expect(ManScope(page: "/usr/local/share/man/man1/tool.1") == .under("/usr/local"))
    #expect(ManScope(page: "/opt/example/man/man1/tool.1") == nil)    // no <root>/share/man: not used
}

@Test func layers() {
    #expect(sources.describe(pid: 9, name: "mds_stores", path: "/System/Library/mds_stores")?.contains("Spotlight") == true)
    #expect(sources.describe(pid: 9, name: "exampled", path: "/usr/libexec/exampled") == "example settings server")
    #expect(sources.describe(pid: 9, name: "crashhelper", path: "/Applications/Firefox.app/Contents/MacOS/crashhelper") == "part of Firefox")
    #expect(sources.describe(pid: 9, name: "labelledd", path: "/usr/libexec/labelledd") == "com.example.labelled")
    #expect(sources.describe(pid: 9, name: "unknownd", path: "/usr/libexec/unknownd") == nil)
    #expect(sources.describe(pid: 9, name: "unknownd", path: nil) == nil)
}

@Test func bundleNameSameAsProcess() {
    #expect(sources.describe(pid: 9, name: "samehelper", path: "/Applications/Same.app/Contents/MacOS/samehelper") == nil)
}

@Test func bundleRoot() {
    #expect(DescriptionSources.bundleRoot("/Applications/Firefox.app/Contents/MacOS/crashhelper") == "/Applications/Firefox.app")
    #expect(DescriptionSources.bundleRoot("/A/Outer.app/Contents/Frameworks/Inner.app/Contents/MacOS/x") == "/A/Outer.app")
    #expect(DescriptionSources.bundleRoot("/S/WebKit.framework/XPCServices/com.example.Web.xpc/Contents/MacOS/w")
            == "/S/WebKit.framework/XPCServices/com.example.Web.xpc")
    #expect(DescriptionSources.bundleRoot("/usr/libexec/trustd") == nil)
}

// Any user's bundle can be named by a process path, so its Info.plist may be a pipe or a huge file.
@Test func bundleDisplayNameReadsOnlySmallRegularFiles() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("saur0n-bundle-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    func bundle(_ name: String) throws -> String {
        let contents = root.appendingPathComponent("\(name).app/Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        return contents.deletingLastPathComponent().path
    }
    let plain = try bundle("Plain")
    try #"{ CFBundleName = "Plain Example"; }"#.write(toFile: plain + "/Contents/Info.plist", atomically: true, encoding: .utf8)
    #expect(DescriptionSources.bundleDisplayName(plain) == "Plain Example")

    let huge = try bundle("Huge")
    let padding = String(repeating: " ", count: 2 << 20)
    try #"{ CFBundleName = "Huge Example"; }\#(padding)"#.write(toFile: huge + "/Contents/Info.plist", atomically: true, encoding: .utf8)
    #expect(DescriptionSources.bundleDisplayName(huge) == nil)

    let piped = try bundle("Piped")
    #expect(mkfifo(piped + "/Contents/Info.plist", 0o600) == 0)
    #expect(DescriptionSources.bundleDisplayName(piped) == nil)

    // Never followed: a link could open a serial device as whoever runs Saur0n. No real bundle uses one.
    let linked = try bundle("Linked")
    try fm.createSymbolicLink(atPath: linked + "/Contents/Info.plist", withDestinationPath: plain + "/Contents/Info.plist")
    #expect(DescriptionSources.bundleDisplayName(linked) == nil)

    // System man pages and launchd plists may be links; followed, they still must reach a small regular file.
    #expect(DescriptionSources.plistDictionary(linked + "/Contents/Info.plist", followLinks: true)?["CFBundleName"]
            as? String == "Plain Example")
    #expect(DescriptionSources.regularFileContents(piped + "/Contents/Info.plist", followLinks: true) == nil)
    #expect(DescriptionSources.regularFileContents(huge + "/Contents/Info.plist", followLinks: true) == nil)
}

@Test func launchdProgram() {
    #expect(DescriptionSources.launchdProgram(["Label": "com.example.a", "Program": "/usr/libexec/a"]) == "/usr/libexec/a")
    #expect(DescriptionSources.launchdProgram(["Label": "com.example.b", "ProgramArguments": ["/usr/libexec/b", "-x"]]) == "/usr/libexec/b")
    #expect(DescriptionSources.launchdProgram(["Label": "com.example.c"]) == nil)
}

@Test func usageDescribes() throws {
    let second: UInt64 = 1_000_000_000
    let test = ProcessIdentity(pid: 42, ppid: 1, uid: 501, user: "u", startMicroseconds: 1, comm: "astar",
                               path: "/w/target/debug/deps/astar-f93bb998ee1a2b3c")
    let daemon = ProcessIdentity(pid: 43, ppid: 1, uid: 0, user: "root", startMicroseconds: 1, comm: "exampled",
                                 path: "/usr/libexec/exampled")
    let counters: [Int32: ProcessCounters] = [42: ProcessCounters(cpuNanoseconds: 0, residentBytes: 0), 43: ProcessCounters(cpuNanoseconds: 0, residentBytes: 0)]
    let before = ProcessListSample(uptimeNanoseconds: second, processes: [test, daemon], taskInfo: counters, ps: [:])
    let after = ProcessListSample(uptimeNanoseconds: 2 * second, processes: [test, daemon], taskInfo: counters, ps: [:])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil, describe: sources.describe)
    #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.readableName) })
            == [42: "test: astar · w", 43: "example settings server"])
}
