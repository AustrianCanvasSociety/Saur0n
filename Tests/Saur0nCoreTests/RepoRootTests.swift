// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Saur0nCore

// Goal: a directory resolves to the repo git would find from it — main checkout, linked worktree
// (one repo with its main checkout), submodule, worktree of a bare repo — or to none. Method: small
// `.git` trees built in a temp folder by hand (no `git` run), read through `RepoResolver`.

/// A fresh temp folder by its `realpath` (`/var` is a link to `/private/var`; Foundation's
/// `resolvingSymlinksInPath` gives the `/var` form back), removed after `body`.
private func withTree(_ body: (String) throws -> Void) throws {
    let fm = FileManager.default
    let url = fm.temporaryDirectory.appendingPathComponent("saur0n-repo-\(UUID().uuidString)")
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: url) }
    let real = try #require(realpath(url.path, nil))
    defer { free(real) }
    try body(String(cString: real))
}

private func mkdir(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func write(_ path: String, _ text: String) throws {
    try mkdir((path as NSString).deletingLastPathComponent)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

/// A main checkout at `root`: `.git` holding HEAD.
private func checkout(_ root: String) throws {
    try write(root + "/.git/HEAD", "ref: refs/heads/main\n")
}

/// A linked worktree of the repo whose git dir is `common`, at `path`, as `git worktree add` lays it out.
private func linkedWorktree(_ path: String, common: String, relative: Bool = false) throws {
    let name = (path as NSString).lastPathComponent
    let gitdir = common + "/worktrees/" + name
    try write(gitdir + "/HEAD", "ref: refs/heads/\(name)\n")
    try write(gitdir + "/commondir", "../..\n")
    try write(path + "/.git", "gitdir: \(relative ? relativePath(from: path, to: gitdir) : gitdir)\n")
}

/// `to` written relative to `from` (both absolute, sharing a prefix).
private func relativePath(from: String, to: String) -> String {
    let a = from.split(separator: "/"), b = to.split(separator: "/")
    let shared = zip(a, b).prefix { $0 == $1 }.count
    return (Array(repeating: "..", count: a.count - shared) + b.dropFirst(shared).map(String.init)).joined(separator: "/")
}

@Test func mainCheckoutFromADeepFolder() throws {
    try withTree { t in
        try checkout(t + "/r")
        try mkdir(t + "/r/src/a")
        #expect(RepoResolver().repo(forDirectory: t + "/r/src/a") == RepoInfo(name: "r", root: t + "/r", worktree: nil))
        #expect(RepoResolver().repo(forDirectory: t + "/r") == RepoInfo(name: "r", root: t + "/r", worktree: nil))
    }
}

@Test func linkedWorktreeIsItsMainRepo() throws {
    try withTree { t in
        try checkout(t + "/r")
        try linkedWorktree(t + "/r.wt/abs", common: t + "/r/.git")
        try linkedWorktree(t + "/r.wt/rel", common: t + "/r/.git", relative: true)
        try mkdir(t + "/r.wt/rel/deep")
        let resolver = RepoResolver()
        #expect(resolver.repo(forDirectory: t + "/r.wt/abs") == RepoInfo(name: "r", root: t + "/r", worktree: t + "/r.wt/abs"))
        #expect(resolver.repo(forDirectory: t + "/r.wt/rel/deep") == RepoInfo(name: "r", root: t + "/r", worktree: t + "/r.wt/rel"))
    }
}

@Test func separateGitDirGroupsWithItsMainCheckoutInEitherOrder() throws {
    try withTree { t in
        for store in [t + "/store", t + "/vault/.git"] {
            let main = t + "/checkout"
            try write(store + "/HEAD", "ref: refs/heads/main\n")
            try write(store + "/config", "[remote \"origin\"]\nurl = https://git.example/o/r.git\n")
            try write(main + "/.git", "gitdir: \(relativePath(from: main, to: store))\n")
            try linkedWorktree(t + "/linked", common: store, relative: true)
            try linkedWorktree(t + "/second", common: store)
            try write(store + "/worktrees/second/commondir", store + "\n")
            try mkdir(main + "/src")
            for pids: [Int32] in [[10, 11, 12], [12, 11, 10]] {
                let resolver = RepoResolver()
                let result = RepoGroups.assign(pids.map(repoRow),
                                               workingDirectories: [10: main + "/src", 11: t + "/linked", 12: t + "/second"],
                                               repoOfDirectory: resolver.repo(forDirectory:), repoOfExecutable: { _ in nil })
                #expect(result.groups.count == 1)
                #expect(result.groups.first?.root == main)
                #expect(result.groups.first?.name == "checkout")
                #expect(result.groups.first?.pids == pids)
                #expect(result.groups.first?.cpuPercent == 3)
                #expect(result.rows.allSatisfy { $0.repo?.root == main && $0.repo?.name == "checkout" })
                #expect(result.rows.allSatisfy { $0.repo?.origin == "https://git.example/o/r.git" })
                #expect(result.rows.first { $0.pid == 10 }?.repo?.worktree == nil)
                #expect(result.rows.first { $0.pid == 11 }?.repo?.worktree == t + "/linked")
                #expect(result.rows.first { $0.pid == 12 }?.repo?.worktree == t + "/second")
                let json = String(decoding: try JSONEncoder().encode(result.rows.compactMap(\.repo)), as: UTF8.self)
                #expect(!json.contains("commonGitDir"))
            }
        }
    }
}

@Test func separateGitDirWithoutAnObservedMainCheckoutUsesTheGitDir() throws {
    try withTree { t in
        try write(t + "/store/HEAD", "ref: refs/heads/main\n")
        try write(t + "/checkout/.git", "gitdir: \(t)/store\n")
        try linkedWorktree(t + "/linked", common: t + "/store")
        try linkedWorktree(t + "/second", common: t + "/store")
        let resolver = RepoResolver()
        let linkedOnly = RepoGroups.assign([repoRow(11), repoRow(12)],
                                           workingDirectories: [11: t + "/linked", 12: t + "/second"],
                                           repoOfDirectory: resolver.repo(forDirectory:), repoOfExecutable: { _ in nil })
        #expect(linkedOnly.groups.count == 1)
        #expect(linkedOnly.groups.first?.root == t + "/store")
        #expect(linkedOnly.groups.first?.name == "store")
        let withMain = RepoGroups.assign([repoRow(11), repoRow(10)],
                                         workingDirectories: [10: t + "/checkout", 11: t + "/linked"],
                                         repoOfDirectory: resolver.repo(forDirectory:), repoOfExecutable: { _ in nil })
        #expect(withMain.groups.count == 1)
        #expect(withMain.groups.first?.root == t + "/checkout")
        let afterMainLeaves = RepoGroups.assign([repoRow(11)], workingDirectories: [11: t + "/linked"],
                                               repoOfDirectory: resolver.repo(forDirectory:), repoOfExecutable: { _ in nil })
        #expect(afterMainLeaves.groups.first?.root == t + "/store")
    }
}

@Test func separateGitDirsWithTheSameNameStaySeparate() throws {
    try withTree { t in
        for name in ["one", "two"] {
            try write(t + "/\(name)/store/HEAD", "ref: refs/heads/main\n")
            try write(t + "/\(name)/checkout/.git", "gitdir: \(t)/\(name)/store\n")
            try linkedWorktree(t + "/\(name)/linked", common: t + "/\(name)/store")
        }
        let resolver = RepoResolver()
        let result = RepoGroups.assign([repoRow(10), repoRow(11), repoRow(12), repoRow(13)],
                                       workingDirectories: [10: t + "/one/checkout", 11: t + "/one/linked",
                                                            12: t + "/two/checkout", 13: t + "/two/linked"],
                                       repoOfDirectory: resolver.repo(forDirectory:), repoOfExecutable: { _ in nil })
        #expect(result.groups.count == 2)
        #expect(Set(result.groups.compactMap(\.root)) == [t + "/one/checkout", t + "/two/checkout"])
        #expect(result.groups.allSatisfy { $0.pids.count == 2 })
    }
}

@Test func submoduleIsItsOwnRepo() throws {
    try withTree { t in
        try checkout(t + "/r")
        try write(t + "/r/.git/modules/sub/HEAD", "0123\n")
        try write(t + "/r/sub/.git", "gitdir: ../.git/modules/sub\n")
        #expect(RepoResolver().repo(forDirectory: t + "/r/sub") == RepoInfo(name: "sub", root: t + "/r/sub", worktree: nil))
    }
}

@Test func worktreeOfABareRepo() throws {
    try withTree { t in
        try write(t + "/b.git/HEAD", "ref: refs/heads/main\n")
        try linkedWorktree(t + "/w", common: t + "/b.git")
        #expect(RepoResolver().repo(forDirectory: t + "/w") == RepoInfo(name: "b", root: t + "/b.git", worktree: t + "/w"))
    }
}

@Test func gitFileWithoutCommondirOrGitdirLine() throws {
    try withTree { t in
        // `git init --separate-git-dir`: the git dir lives elsewhere, the work tree is the repo.
        try write(t + "/store/HEAD", "ref: refs/heads/main\n")
        try write(t + "/sep/.git", "gitdir: \(t)/store\n")
        #expect(RepoResolver().repo(forDirectory: t + "/sep") == RepoInfo(name: "sep", root: t + "/sep", worktree: nil))
        // A malformed .git file inside a repo: git stops there with an error, so no repo — not the outer one.
        try checkout(t + "/outer")
        try write(t + "/outer/bad/.git", "not a gitfile\n")
        #expect(RepoResolver().repo(forDirectory: t + "/outer/bad") == nil)
        // A .git folder without HEAD is not a git dir; the walk goes on to the outer repo.
        try mkdir(t + "/outer/empty/.git")
        #expect(RepoResolver().repo(forDirectory: t + "/outer/empty")?.root == t + "/outer")
        // A gitdir that points nowhere is no repo either.
        try write(t + "/outer/gone/.git", "gitdir: \(t)/missing\n")
        #expect(RepoResolver().repo(forDirectory: t + "/outer/gone") == nil)
    }
}

@Test func firstLineDoesNotSkipLeadingBlankLines() throws {
    try withTree { t in
        for name in ["HEAD", "commondir", "gitdir"] {
            try write(t + "/" + name, "\nsecond line\n")
            #expect(RepoResolver.firstLine(t + "/" + name) == nil)
            try write(t + "/" + name, "first line  \r\nsecond line\n")
            #expect(RepoResolver.firstLine(t + "/" + name) == "first line")
        }
    }
}

@Test func linkedWorktreeRejectsLeadingBlankMetadata() throws {
    try withTree { t in
        try checkout(t + "/r")
        try linkedWorktree(t + "/w", common: t + "/r/.git")
        let gitdir = t + "/r/.git/worktrees/w"
        try write(t + "/w/.git", "\ngitdir: \(gitdir)\n")
        #expect(RepoResolver().repo(forDirectory: t + "/w") == nil)
        try write(t + "/w/.git", "gitdir: \(gitdir)\n")
        try write(gitdir + "/commondir", "\n../..\n")
        #expect(RepoResolver().repo(forDirectory: t + "/w") == nil)
    }
}

@Test func noRepoAndSymlinks() throws {
    try withTree { t in
        try mkdir(t + "/plain/x")
        #expect(RepoResolver().repo(forDirectory: t + "/plain/x") == nil)
        #expect(RepoResolver().repo(forDirectory: t + "/does-not-exist") == nil)
        try checkout(t + "/r")
        try mkdir(t + "/r/src")
        try FileManager.default.createSymbolicLink(atPath: t + "/link", withDestinationPath: t + "/r/src")
        #expect(RepoResolver().repo(forDirectory: t + "/link") == RepoInfo(name: "r", root: t + "/r", worktree: nil))
    }
}

@Test func realPathsCacheResolvedAndMissingFolders() throws {
    try withTree { t in
        try checkout(t + "/first")
        try checkout(t + "/second")
        let link = t + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: t + "/first")
        let resolver = RepoResolver()
        #expect(resolver.repo(forDirectory: link)?.root == t + "/first")
        #expect(resolver.repo(forDirectory: t + "/missing") == nil)
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: t + "/second")
        try checkout(t + "/missing")
        #expect(resolver.repo(forDirectory: link)?.root == t + "/first")
        #expect(resolver.repo(forDirectory: t + "/missing") == nil)
        #expect(RepoResolver().repo(forDirectory: link)?.root == t + "/second")
        #expect(RepoResolver().repo(forDirectory: t + "/missing")?.root == t + "/missing")
    }
}

@Test func untrustedGitEntryStopsBeforeAnOuterRepo() throws {
    try withTree { t in
        try checkout(t + "/outer")
        try checkout(t + "/outer/directory")
        try mkdir(t + "/outer/empty/.git")
        try write(t + "/store/HEAD", "ref: refs/heads/main\n")
        try write(t + "/outer/file/.git", "gitdir: \(t)/store\n")
        try mkdir(t + "/outer/link")
        try FileManager.default.createSymbolicLink(atPath: t + "/outer/link/.git", withDestinationPath: t + "/store")
        for name in ["directory", "empty", "file", "link"] {
            let folder = t + "/outer/" + name
            try mkdir(folder + "/deep")
            for rejectedOwner: UInt32? in [UInt32.max, nil] {
                let resolver = RepoResolver(owner: { $0 == folder + "/.git" ? rejectedOwner : getuid() })
                #expect(resolver.repo(forDirectory: t + "/outer")?.root == t + "/outer")
                #expect(resolver.repo(forDirectory: folder + "/deep") == nil)
                #expect(resolver.repo(forDirectory: folder) == nil)
            }
        }
    }
}

@Test func untrustedResolvedGitDirStopsBeforeAnOuterRepo() throws {
    try withTree { t in
        try checkout(t + "/outer")
        try write(t + "/store/HEAD", "ref: refs/heads/main\n")
        try FileManager.default.createSymbolicLink(atPath: t + "/alias", withDestinationPath: t + "/store")
        try write(t + "/outer/file/.git", "gitdir: ../../alias\n")
        try mkdir(t + "/outer/link")
        try FileManager.default.createSymbolicLink(atPath: t + "/outer/link/.git", withDestinationPath: t + "/store")
        for name in ["file", "link"] {
            for rejectedOwner: UInt32? in [UInt32.max, nil] {
                let resolver = RepoResolver(owner: { $0 == t + "/store" ? rejectedOwner : getuid() })
                #expect(resolver.repo(forDirectory: t + "/outer/" + name) == nil)
            }
        }
    }
}

@Test func untrustedCommonGitDirIsRejected() throws {
    try withTree { t in
        try checkout(t + "/outer")
        try checkout(t + "/r")
        try linkedWorktree(t + "/outer/linked", common: t + "/r/.git")
        for rejected in [t + "/r/.git", t + "/r/.git/worktrees/linked"] {
            for rejectedOwner: UInt32? in [UInt32.max, nil] {
                let resolver = RepoResolver(owner: { $0 == rejected ? rejectedOwner : getuid() })
                #expect(resolver.repo(forDirectory: t + "/outer/linked") == nil)
            }
        }
    }
}

@Test func trustedGitOwnersIncludeCurrentUserAndRoot() throws {
    try withTree { t in
        try checkout(t + "/r")
        try linkedWorktree(t + "/linked", common: t + "/r/.git")
        try write(t + "/store/HEAD", "ref: refs/heads/main\n")
        try write(t + "/separate/.git", "gitdir: \(t)/store\n")
        #expect(RepoResolver.entryOwner(t + "/r/.git") == getuid())
        #expect(RepoResolver.entryOwner(t + "/missing") == nil)
        for uid in [getuid(), 0] {
            let resolver = RepoResolver(owner: { _ in uid })
            #expect(resolver.repo(forDirectory: t + "/r")?.root == t + "/r")
            #expect(resolver.repo(forDirectory: t + "/linked")?.root == t + "/r")
            #expect(resolver.repo(forDirectory: t + "/separate")?.root == t + "/separate")
        }
    }
}

@Test func gitOwnerChecksAreCachedWithTheWalk() throws {
    try withTree { t in
        try checkout(t + "/r")
        try mkdir(t + "/r/a")
        try mkdir(t + "/r/b")
        var checked: [String] = []
        let resolver = RepoResolver(owner: { checked.append($0); return getuid() })
        #expect(resolver.repo(forDirectory: t + "/r/a")?.root == t + "/r")
        #expect(resolver.repo(forDirectory: t + "/r/b")?.root == t + "/r")
        #expect(resolver.repo(forDirectory: t + "/r")?.root == t + "/r")
        #expect(checked == [t + "/r/.git"])
        var deniedChecks = 0
        let denied = RepoResolver(owner: { _ in deniedChecks += 1; return UInt32.max })
        #expect(denied.repo(forDirectory: t + "/r/a") == nil)
        #expect(denied.repo(forDirectory: t + "/r/b") == nil)
        #expect(deniedChecks == 1)
    }
}

@Test func walksAreCachedPositiveAndNegative() throws {
    try withTree { t in
        try checkout(t + "/r")
        try mkdir(t + "/r/a/x")
        try mkdir(t + "/r/a/y")
        try mkdir(t + "/plain/x")
        var lookups = 0
        let resolver = RepoResolver(device: { path in lookups += 1; return RepoResolver.statDevice(path) })
        _ = resolver.repo(forDirectory: t + "/r/a/x")
        let afterFirst = lookups
        // A sibling stops at the shared, already-resolved parent: one new folder looked at.
        #expect(resolver.repo(forDirectory: t + "/r/a/y")?.root == t + "/r")
        #expect(lookups == afterFirst + 1)
        #expect(resolver.repo(forDirectory: t + "/r/a/x")?.root == t + "/r")
        #expect(lookups == afterFirst + 1)
        #expect(resolver.repo(forDirectory: t + "/plain/x") == nil)
        let afterNegative = lookups
        #expect(resolver.repo(forDirectory: t + "/plain/x") == nil)
        #expect(lookups == afterNegative)
    }
}

@Test func walkStopsAtAMountPoint() throws {
    try withTree { t in
        try checkout(t + "/r")
        try mkdir(t + "/r/mnt/inner")
        // `r/mnt` sits on another device than `r`: the walk from inside it never reaches r's .git.
        let resolver = RepoResolver(device: { $0.hasPrefix(t + "/r/mnt") ? 2 : 1 })
        #expect(resolver.repo(forDirectory: t + "/r/mnt/inner") == nil)
        #expect(resolver.repo(forDirectory: t + "/r") == RepoInfo(name: "r", root: t + "/r", worktree: nil))
    }
}

@Test func executablePathResolvesThroughItsFolder() throws {
    try withTree { t in
        try checkout(t + "/fixtures/r")
        try write(t + "/fixtures/r/.build/debug/tool", "")
        let resolver = RepoResolver(home: t + "/fixtures")
        #expect(resolver.repo(forExecutable: t + "/fixtures/r/.build/debug/tool")?.name == "r")
        #expect(resolver.repo(forExecutable: "/bin/ls") == nil)
    }
}

@Test func executableHomeResolvesSymlinksAndKeepsMissingPaths() throws {
    try withTree { t in
        try checkout(t + "/fixtures/r")
        try write(t + "/fixtures/r/bin/tool", "")
        try FileManager.default.createSymbolicLink(atPath: t + "/alias", withDestinationPath: t + "/fixtures")
        let linkedHome = RepoResolver(home: t + "/alias")
        #expect(linkedHome.repo(forExecutable: t + "/fixtures/r/bin/tool")?.root == t + "/fixtures/r")
        let missingHome = RepoResolver(home: t + "/later")
        try checkout(t + "/later/r")
        try write(t + "/later/r/bin/tool", "")
        #expect(missingHome.repo(forExecutable: t + "/later/r/bin/tool")?.root == t + "/later/r")
    }
}

/// A package manager kept as a git checkout outside home (Homebrew in /opt/homebrew) does not collect
/// the tools it installed; a process working inside it still lands there (user, 2026-10-18).
@Test func executablePathOutsideHomeTiesToNoRepo() throws {
    try withTree { t in
        try checkout(t + "/opt/brew")
        try write(t + "/opt/brew/Cellar/tool/1.0/bin/tool", "")
        let resolver = RepoResolver(home: t + "/fixtures")
        #expect(resolver.repo(forExecutable: t + "/opt/brew/Cellar/tool/1.0/bin/tool") == nil)
        #expect(resolver.repo(forDirectory: t + "/opt/brew/Cellar") == RepoInfo(name: "brew", root: t + "/opt/brew", worktree: nil))
        // A folder named like home but beside it is not inside it.
        try checkout(t + "/home2/r")
        try write(t + "/home2/r/bin/tool", "")
        #expect(resolver.repo(forExecutable: t + "/home2/r/bin/tool") == nil)
    }
}

// MARK: swarm members

// Goal: a swarm member — cwd an empty scratch folder, the project passed as `--add-dir` after
// `--add-dir /tmp` — and the processes it starts in its scratch folder group under the project.
// Method: rows built by hand with fake repos by folder prefix, through `RepoGroups.assign`.

private let project = RepoInfo(name: "proj", root: "/work/proj", worktree: nil)
private let projectWorktree = RepoInfo(name: "proj", root: "/work/proj", worktree: "/work/proj.wt/fix")
private let other = RepoInfo(name: "other", root: "/work/other", worktree: nil)

private func fakeRepo(_ folder: String) -> RepoInfo? {
    [projectWorktree, project, other].first { folder == ($0.worktree ?? $0.root) || folder.hasPrefix(($0.worktree ?? $0.root) + "/") }
}

private func member(_ pid: Int32, parent: Int32 = 1, argv: [String] = []) -> ProcessUsage {
    var row = ProcessUsage(pid: pid, ppid: parent, uid: 501, user: "alice", path: "/opt/bin/claude", name: "claude",
                           cpuPercent: 1, residentBytes: 1024, source: .libproc)
    row.addDirectories = RepoGroups.addDirectories(argv: argv)
    return row
}

private func assignMembers(_ rows: [ProcessUsage], cwd: [Int32: String]) -> [Int32: RepoInfo?] {
    let result = RepoGroups.assign(rows, workingDirectories: cwd, repoOfDirectory: fakeRepo, repoOfExecutable: { _ in nil })
    return Dictionary(uniqueKeysWithValues: result.rows.map { ($0.pid, $0.repo) })
}

@Test func addDirectoryArgumentForms() {
    #expect(RepoGroups.addDirectories(argv: ["claude", "-p", "x", "--add-dir", "/tmp", "--add-dir", "/work/proj", "--model", "m"])
        == ["/tmp", "/work/proj"])
    // `--add-dir <directories...>` takes every value up to the next flag; `--add-dir=<dir>` one.
    #expect(RepoGroups.addDirectories(argv: ["claude", "--add-dir", "/tmp", "/work/a", "-p", "--add-dir=/work/b"])
        == ["/tmp", "/work/a", "/work/b"])
    #expect(RepoGroups.addDirectories(argv: ["claude", "--add-dir"]) == [])
    #expect(RepoGroups.addDirectories(argv: []) == [])
}

@Test func swarmMemberGroupsUnderItsLastRepoAddDirectory() {
    let scratch = "/fixtures/alice/.local/state/swarm/w1/a1"
    let repos = assignMembers([member(10, argv: ["claude", "-p", "t", "--add-dir", "/tmp", "--add-dir", "/work/proj"]),
                               // The last add-dir that is a repo wins; a non-repo after it is passed over.
                               member(11, argv: ["claude", "--add-dir", "/work/other", "/work/proj.wt/fix", "/tmp"]),
                               // Only non-repos: no tie.
                               member(12, argv: ["claude", "--add-dir", "/tmp"])],
                              cwd: [10: scratch, 11: scratch, 12: scratch])
    #expect(repos[10] == project)
    #expect(repos[11] == projectWorktree)
    #expect(repos[12] == .some(nil))
}

@Test func relativeAddDirectoryIsReadFromTheMembersWorkingDirectory() {
    // `claude --add-dir proj` run from /work names /work/proj, whatever folder Saur0n runs in
    // (phase 3 gate round 1).
    let repos = assignMembers([member(15, argv: ["claude", "--add-dir", "../proj"]),
                               member(16, argv: ["claude", "--add-dir", "proj.wt/fix/"])],
                              cwd: [15: "/work/scratch", 16: "/work"])
    #expect(repos[15] == project)
    #expect(repos[16] == projectWorktree)
}

@Test func workingDirectoryInARepoBeatsAddDirectory() {
    let repos = assignMembers([member(20, argv: ["claude", "--add-dir", "/work/other"])], cwd: [20: "/work/proj/src"])
    #expect(repos[20] == project)
}

@Test func childrenOfAMemberInheritItsRepo() {
    let scratch = "/fixtures/alice/.local/state/swarm/w1/a1"
    let repos = assignMembers([member(30, argv: ["claude", "--add-dir", "/tmp", "--add-dir", "/work/proj"]),
                               member(31, parent: 30), member(32, parent: 31),
                               // A child that works inside a repo goes by its own working directory.
                               member(33, parent: 30)],
                              cwd: [30: scratch, 31: scratch, 32: "/tmp", 33: "/work/other"])
    #expect(repos[31] == project)
    #expect(repos[32] == project)
    #expect(repos[33] == other)
}

@Test func onlyAddDirectoryTiesAreInherited() {
    // A shell in /tmp under an ordinary session working in a repo stays "Not in a repo" (Step 1).
    let result = RepoGroups.assign([member(40), member(41, parent: 40)], workingDirectories: [40: "/work/proj", 41: "/tmp"],
                                   repoOfDirectory: fakeRepo, repoOfExecutable: { _ in nil })
    #expect(result.rows.map(\.repo) == [project, nil])
    #expect(result.groups.map(\.name) == ["proj", RepoGroups.notInARepo])
}

@Test func usageCarriesTheAddDirectories() throws {
    let process = ProcessIdentity(pid: 50, ppid: 1, uid: 501, user: "alice", startMicroseconds: 1, comm: "claude", path: nil)
    let counters = ProcessCounters(cpuNanoseconds: 0, residentBytes: 1)
    let before = ProcessListSample(uptimeNanoseconds: 0, processes: [process], taskInfo: [50: counters], ps: [:])
    let after = ProcessListSample(uptimeNanoseconds: 1_000_000_000, processes: [process], taskInfo: [50: counters], ps: [:],
                                  arguments: [50: ProcessArguments(argv: ["claude", "--add-dir", "/tmp", "--add-dir", "/work/proj"],
                                                                   environment: [:])])
    let rows = try ProcessSample.usage(before: before, after: after, cpuCount: 1, kernelTask: nil)
    #expect(rows.first?.addDirectories == ["/tmp", "/work/proj"])
}

// MARK: clones

// Goal: a full clone keeps its own group and names the repo it is a clone of — by a local source
// path, or by a remote URL shared with a group named as git names the folder. Method: `.git/config`
// files written by hand, read through `RepoResolver`; groups through `RepoGroups.assign`.

@Test func remoteURLFormsShareOneKey() {
    let keys = ["git@git.example:o/r.git", "ssh://git@git.example/o/r", "ssh://git@git.example:2222/o/r.git",
                "https://git.example/o/r.git", "https://user@Git.Example/o/r/"].map(RepoGroups.remoteKey)
    #expect(Set(keys).count == 1)
    #expect(keys[0] == "git.example/o/r")
    // Same basename, different owner: a different repo.
    #expect(RepoGroups.remoteKey("https://git.example/a/r") != RepoGroups.remoteKey("https://git.example/b/r"))
    #expect(RepoGroups.remoteKey("/local/path/r") == nil)
    #expect(RepoGroups.remoteKey("file:///local/path/r") == nil)
}

@Test func originIsReadFromTheRepoConfig() throws {
    try withTree { t in
        try checkout(t + "/r")
        try write(t + "/r/.git/config", """
            [core]
            \tbare = false
            [remote "upstream"]
            \turl = https://git.example/up/r.git
            [Remote "origin"]
            \tURL = "git@git.example:o/r.git"
            \turl = https://second.example/o/r
            """)
        try linkedWorktree(t + "/r.wt/w", common: t + "/r/.git")
        let resolver = RepoResolver()
        #expect(resolver.repo(forDirectory: t + "/r")?.origin == "git@git.example:o/r.git")
        // A linked worktree reads the common dir's config.
        #expect(resolver.repo(forDirectory: t + "/r.wt/w")?.origin == "git@git.example:o/r.git")
        try checkout(t + "/plain")
        #expect(resolver.repo(forDirectory: t + "/plain")?.origin == nil)
        // Origin is not part of the JSON.
        let json = String(decoding: try JSONEncoder().encode(resolver.repo(forDirectory: t + "/r")), as: UTF8.self)
        #expect(!json.contains("origin"))
    }
}

@Test func originUsesTheFirstURLAfterTheLastEmptyReset() throws {
    try withTree { t in
        let config = t + "/config"
        let first = "https://git.example/o/first.git"
        let second = "https://git.example/o/second.git"
        for (values, expected) in [
            (["", first, second], first),
            ([first, "", second], second),
            ([first, ""], nil),
            (["\"\"", first], first)
        ] as [([String], String?)] {
            try write(config, "[remote \"origin\"]\n" + values.map { "url = \($0)\n" }.joined())
            #expect(RepoResolver.origin(gitDir: t) == expected)
        }
    }
}

@Test func originReadsAKeyOnTheSectionHeaderLine() throws {
    try withTree { t in
        try write(t + "/config", """
            [remote "upstream"] url = https://git.example/o/upstream.git
            [Remote "origin"] URL = "https://git.example/o/r.git" # comment
            url = https://git.example/o/second.git
            """)
        #expect(RepoResolver.origin(gitDir: t) == "https://git.example/o/r.git")
    }
}

private func repoRow(_ pid: Int32) -> ProcessUsage {
    ProcessUsage(pid: pid, ppid: 1, uid: 501, user: "alice", path: nil, name: "p", cpuPercent: 1, residentBytes: 1, source: .libproc)
}

@Test func cloneOfALocalSourceRepo() {
    let src = RepoInfo(name: "src", root: "/t/src", worktree: nil)
    let copy = RepoInfo(name: "copy", root: "/t/copy", worktree: nil, origin: "/t/src/")
    let repos = ["/t/src": src, "/t/copy": copy]
    let result = RepoGroups.assign([repoRow(1), repoRow(2)], workingDirectories: [1: "/t/src", 2: "/t/copy"],
                                   repoOfDirectory: { path in repos[path.hasSuffix("/") ? String(path.dropLast()) : path] },
                                   repoOfExecutable: { _ in nil })
    let byName = Dictionary(uniqueKeysWithValues: result.groups.map { ($0.name, $0) })
    #expect(byName["copy"]?.cloneOf == "src")
    #expect(byName["src"]?.cloneOf == nil)
    #expect(result.groups.count == 2)
}

@Test func cloneSharingARemoteNamesTheConventionallyNamedGroup() {
    let main = RepoInfo(name: "Saur0n", root: "/u/Dev/Saur0n", worktree: nil, origin: "ssh://git@git.example:2222/o/Saur0n.git")
    let ci = RepoInfo(name: "hostexecutor", root: "/u/cache/x/hostexecutor", worktree: nil, origin: "https://git.example/o/Saur0n")
    let fork = RepoInfo(name: "Saur0n", root: "/u/forks/Saur0n", worktree: nil, origin: "https://git.example/someone/Saur0n")
    let repos = [main.root: main, ci.root: ci, fork.root: fork]
    let result = RepoGroups.assign([repoRow(1), repoRow(2), repoRow(3)],
                                   workingDirectories: [1: main.root, 2: ci.root, 3: fork.root],
                                   repoOfDirectory: { repos[$0] }, repoOfExecutable: { _ in nil })
    let byRoot = Dictionary(uniqueKeysWithValues: result.groups.map { ($0.root ?? "", $0) })
    #expect(byRoot[ci.root]?.cloneOf == "Saur0n")
    #expect(byRoot[main.root]?.cloneOf == nil)
    #expect(byRoot[fork.root]?.cloneOf == nil)
}

@Test func cloneHintShowsInTheTableNotTheJSON() throws {
    let src = RepoInfo(name: "src", root: "/t/src", worktree: nil)
    let copy = RepoInfo(name: "copy", root: "/t/copy", worktree: nil, origin: "/t/src")
    let repos = ["/t/src": src, "/t/copy": copy]
    let result = RepoGroups.assign([repoRow(1), repoRow(2)], workingDirectories: [1: "/t/src", 2: "/t/copy"],
                                   repoOfDirectory: { repos[$0] }, repoOfExecutable: { _ in nil })
    let table = ProcessSample.table(result.rows, groups: result.groups)
    #expect(table.split(separator: "\n").contains { $0.hasPrefix("copy  (clone of src)  ") })
    #expect(!table.contains("src  (clone of"))
    let json = String(decoding: try JSONEncoder().encode(result.groups), as: UTF8.self)
    #expect(!json.contains("clone"))
}

// MARK: the window's kept resolver

@Test func keptResolverWalksAFolderOncePerTenRefreshes() throws {
    try withTree { tmp in
        try mkdir(tmp + "/plain/sub")
        var walks = 0
        var kept = KeptResolver { RepoResolver(device: { _ in walks += 1; return 1 }) }
        _ = kept.next().repo(forDirectory: tmp + "/plain/sub")
        let firstWalk = walks
        #expect(firstWalk > 0)
        // The next nine refreshes answered from the kept resolver: no folder looked at again.
        for _ in 1..<KeptResolver.every { _ = kept.next().repo(forDirectory: tmp + "/plain/sub") }
        #expect(walks == firstWalk)
        try checkout(tmp + "/plain")
        #expect(kept.next().repo(forDirectory: tmp + "/plain/sub")?.root == tmp + "/plain")    // the 11th: a new walk
        #expect(walks > firstWalk)
    }
}

@Test func keptResolverIsTheSameUntilItsTurn() {
    var kept = KeptResolver()
    let first = kept.next()
    for _ in 1..<KeptResolver.every { #expect(kept.next() === first) }
    #expect(kept.next() !== first)
}
