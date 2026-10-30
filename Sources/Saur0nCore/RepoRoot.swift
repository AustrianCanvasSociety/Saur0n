// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// The git repo a process works in. Linked worktrees of one repo share its `root`; `worktree` names
/// the one the process is in.
public struct RepoInfo: Equatable, Sendable {
    /// The repo folder's name (a bare repo's without `.git`), as `git clone` names the folder.
    public let name: String
    /// The folder holding the repo's common `.git`, or the bare repo itself: the group's identity.
    public let root: String
    /// A linked worktree's top folder; nil in the main checkout.
    public let worktree: String?
    /// The repo's `remote.origin.url` as written; nil when none. Table only (the "clone of" hint), not in JSON.
    public let origin: String?
    /// Discovery metadata for grouping, not part of the public value or its JSON.
    var commonGitDir: String?
    var groupKey: String { commonGitDir ?? root }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.root == rhs.root && lhs.worktree == rhs.worktree && lhs.origin == rhs.origin
    }

    public init(name: String, root: String, worktree: String?, origin: String? = nil) {
        self.name = name
        self.root = root
        self.worktree = worktree
        self.origin = origin
    }
}

extension RepoInfo: Encodable {
    enum CodingKeys: String, CodingKey { case name, root, worktree }

    /// `worktree` is null, never omitted, on the main checkout.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(root, forKey: .root)
        try container.encode(worktree, forKey: .worktree)
    }
}

/// Finds the repo git would find from a folder, walking up for `.git` as git's own discovery does,
/// without running git (research § Q1). One resolver per snapshot: every folder a walk passes is
/// cached with its answer, found or not, so processes in the same tree cost one walk.
public final class RepoResolver {
    /// nil: not looked at yet; `.some(nil)`: no repo.
    private var byFolder: [String: RepoInfo?] = [:]
    private var devices: [String: UInt64?] = [:]
    private var realPaths: [String: String?] = [:]
    private let device: (String) -> UInt64?
    private let owner: (String) -> UInt32?
    private let ownUID = getuid()
    /// The user's home folder, realpath'd when it exists.
    private let home: String

    /// `device` gives a folder's filesystem; the walk does not cross from one to another
    /// (`GIT_DISCOVERY_ACROSS_FILESYSTEM` is off by default). `home` bounds `repo(forExecutable:)`.
    public convenience init(device: @escaping (String) -> UInt64? = RepoResolver.statDevice, home: String = NSHomeDirectory()) {
        self.init(device: device, home: home, owner: Self.entryOwner)
    }

    init(device: @escaping (String) -> UInt64? = RepoResolver.statDevice, home: String = NSHomeDirectory(),
         owner: @escaping (String) -> UInt32?) {
        self.device = device
        self.owner = owner
        self.home = Self.resolveRealPath(home) ?? home
    }

    static func entryOwner(_ path: String) -> UInt32? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_uid
    }

    /// Reject unknown ownership too; never look past an untrusted entry to a parent repo.
    private func trustedOwner(_ path: String) -> Bool {
        guard let uid = owner(path) else { return false }
        return uid == ownUID || uid == 0
    }

    public static func statDevice(_ path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(UInt32(bitPattern: info.st_dev))
    }

    /// The repo of the folder holding an executable (a dev build run from elsewhere), only when that
    /// repo lies inside the home folder: a package manager kept as a git checkout outside it
    /// (Homebrew's `/opt/homebrew`) would otherwise collect every tool it installed (user, 2026-10-18:
    /// "ok, as long as it still reports accurately").
    public func repo(forExecutable path: String) -> RepoInfo? {
        guard let repo = repo(forDirectory: Self.parent(path)), repo.root.hasPrefix(home + "/") else { return nil }
        return repo
    }

    /// The repo `path` lies in; nil when none up to `/` or the filesystem's edge, or when the
    /// nearest `.git` is broken (git stops there with an error rather than looking further up).
    public func repo(forDirectory path: String) -> RepoInfo? {
        guard let start = realPath(path) else { return nil }
        var visited: [String] = []
        var folder = start
        var found: RepoInfo?
        while true {
            if let cached = byFolder[folder] {
                found = cached
                break
            }
            visited.append(folder)
            if let entry = gitEntry(in: folder) {
                found = entry
                break
            }
            let parent = Self.parent(folder)
            guard parent != folder, let here = deviceOf(folder), deviceOf(parent) == here else { break }
            folder = parent
        }
        for folder in visited { byFolder[folder] = .some(found) }
        return found
    }

    /// nil: no `.git` here, keep walking. `.some(nil)`: broken or untrusted metadata — stop.
    private func gitEntry(in folder: String) -> RepoInfo?? {
        let dotGit = Self.child(folder, ".git")
        var info = stat()
        guard lstat(dotGit, &info) == 0 else { return nil }
        guard trustedOwner(dotGit) else { return .some(nil) }
        if info.st_mode & S_IFMT == S_IFLNK {
            guard let target = realPath(dotGit), trustedOwner(target), stat(target, &info) == 0 else { return .some(nil) }
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            // A folder without HEAD is not a git dir (git's `is_git_directory`); look further up.
            guard Self.isRegularFile(Self.child(dotGit, "HEAD")) else { return nil }
            guard let gitDir = realPath(dotGit) else { return .some(nil) }
            return .some(repoInfo(root: folder, worktree: nil, gitDir: gitDir))
        case S_IFREG:
            return .some(linked(folder, gitFile: dotGit))
        default:
            return nil
        }
    }

    /// A `.git` file's `gitdir:` target: a linked worktree when it holds `commondir` (the repo is
    /// that common dir), else its own repo (submodule, `--separate-git-dir`).
    private func linked(_ folder: String, gitFile: String) -> RepoInfo? {
        guard let target = Self.firstLine(gitFile), target.hasPrefix("gitdir: ") else { return nil }
        let named = String(target.dropFirst("gitdir: ".count))
        guard let gitDir = realPath(named.hasPrefix("/") ? named : Self.child(folder, named)), trustedOwner(gitDir),
              Self.isRegularFile(Self.child(gitDir, "HEAD")) else { return nil }
        let commonFile = Self.child(gitDir, "commondir")
        guard let common = Self.firstLine(commonFile) else {
            guard !Self.isRegularFile(commonFile) else { return nil }
            return repoInfo(root: folder, worktree: nil, gitDir: gitDir)
        }
        guard let commonDir = realPath(common.hasPrefix("/") ? common : Self.child(gitDir, common)),
              trustedOwner(commonDir) else { return nil }
        if Self.basename(commonDir) == ".git" {
            return repoInfo(root: Self.parent(commonDir), worktree: folder, gitDir: commonDir)
        }
        let bare = Self.basename(commonDir)
        let name = bare.hasSuffix(".git") && bare.count > 4 ? String(bare.dropLast(4)) : bare
        return repoInfo(root: commonDir, worktree: folder, gitDir: commonDir, name: name)
    }

    private func repoInfo(root: String, worktree: String?, gitDir: String, name: String? = nil) -> RepoInfo {
        var repo = RepoInfo(name: name ?? Self.basename(root), root: root, worktree: worktree, origin: Self.origin(gitDir: gitDir))
        repo.commonGitDir = gitDir
        return repo
    }

    /// `remote.origin.url` from a git dir's `config`: the first `url` after the last empty value resets the list.
    /// Section name and key are case-insensitive; a key may follow its section header on the same line.
    /// A quoted value is unquoted, an unquoted one cut at `#` or `;`. `include` and `url.<base>.insteadOf` are not followed.
    static func origin(gitDir: String) -> String? {
        guard let data = DescriptionSources.regularFileContents(child(gitDir, "config"), limit: 1 << 16, followLinks: true)
        else { return nil }
        var inOrigin = false
        var firstURL: String?
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else { inOrigin = false; continue }
                let header = line[line.index(after: line.startIndex)..<close]
                let parts = header.split(separator: " ", maxSplits: 1)
                inOrigin = parts.count == 2 && parts[0].lowercased() == "remote" && parts[1] == "\"origin\""
                line = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            }
            guard inOrigin, let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "url" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                value = String(value.dropFirst().prefix { $0 != "\"" })
            } else if let comment = value.firstIndex(where: { $0 == "#" || $0 == ";" }) {
                value = value[..<comment].trimmingCharacters(in: .whitespaces)
            }
            if value.isEmpty { firstURL = nil } else if firstURL == nil { firstURL = value }
        }
        return firstURL
    }

    private func deviceOf(_ folder: String) -> UInt64? {
        if let known = devices[folder] { return known }
        let value = device(folder)
        devices[folder] = .some(value)
        return value
    }

    private func realPath(_ path: String) -> String? {
        if let known = realPaths[path] { return known }
        let value = Self.resolveRealPath(path)
        realPaths[path] = .some(value)
        return value
    }

    private static func resolveRealPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The first line of a small regular file, trailing whitespace dropped; nil when that line is blank.
    static func firstLine(_ path: String) -> String? {
        guard let data = DescriptionSources.regularFileContents(path, limit: 4096, followLinks: true),
              let line = String(decoding: data, as: UTF8.self)
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first else { return nil }
        let trimmed = line.reversed().drop { $0.isWhitespace }.reversed()
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    static func child(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    /// The folder above an absolute path; `/` for `/` itself.
    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    static func basename(_ path: String) -> String {
        ProcessSample.basename(path) ?? "/"
    }
}

/// The window's resolver, kept across refreshes so a folder is walked once, not every second (half of a refresh's
/// work on a fresh resolver, profile 2026-10-19), and replaced every `every`th refresh so a `.git` made or removed
/// shows within that many seconds. The CLI takes a fresh resolver per run.
public struct KeptResolver {
    public static let every = 10

    private var resolver: RepoResolver?
    private var used = 0
    private let make: () -> RepoResolver

    public init(make: @escaping () -> RepoResolver = { RepoResolver() }) { self.make = make }

    /// The resolver for this refresh: the kept one, or a new one on the first refresh and every `every`th after.
    public mutating func next() -> RepoResolver {
        defer { used += 1 }
        if used % Self.every == 0 || resolver == nil { resolver = make() }
        return resolver!
    }
}

/// The same unrounded totals for repo, session and command groups; unread fields add nothing.
struct GroupTotals {
    let cpuPercent: Double
    let exitedChildrenCpuPercent: Double
    let residentBytes: UInt64
    let disk: DiskUsage
    let network: NetworkUsage

    init(_ rows: [ProcessUsage]) {
        cpuPercent = rows.map(\.cpuPercent).reduce(0, +)
        exitedChildrenCpuPercent = rows.compactMap(\.exitedChildrenCpuPercent).reduce(0, +)
        residentBytes = rows.map(\.residentBytes).reduce(0, &+)
        disk = DiskActivity.sum(rows.map(\.disk))
        network = NetworkActivity.sum(rows.map(\.network))
    }
}

/// One group of the process table: a repo, the VMs, or one of the two catch-alls.
public struct RepoGroup: Equatable, Sendable {
    public let name: String
    /// nil for the VMs group and the catch-alls.
    public let root: String?
    /// The name of the group this repo is a full clone of (`RepoGroups.cloneOf`); table only, not in JSON.
    public var cloneOf: String? = nil
    /// Sum of its rows' own CPU.
    public let cpuPercent: Double
    /// Sum of its rows' exited-children CPU (unread rows add 0); the header shows `cpuPercent` plus this.
    public let exitedChildrenCpuPercent: Double
    public let residentBytes: UInt64
    /// Its rows' disk rates and bytes summed (`DiskActivity.sum`; unreadable rows add 0).
    public var disk: DiskUsage = .zero
    /// Its rows' network rates and bytes summed (`NetworkActivity.sum`), after a VM takes its Lima helper's.
    public var network: NetworkUsage = .zero
    /// In row order; a catch-all's lifted entries first, then its other line's (`CatchAllBreakout.apply`).
    public internal(set) var pids: [Int32]
    /// A catch-all's app and other lines (`CatchAllBreakout.apply`); empty on every other group.
    public internal(set) var subgroups: [CatchAllBreakout.Subgroup] = []

    /// What the group header shows and groups are ordered by: its rows' own CPU plus their exited children's.
    public var totalCpuPercent: Double { cpuPercent + exitedChildrenCpuPercent }
}

extension RepoGroup: Encodable {
    enum CodingKeys: String, CodingKey {
        case name, cpuPercent, exitedChildrenCpuPercent, residentBytes, disk, network, pids, subgroups
    }

    /// `cpuPercent` and `exitedChildrenCpuPercent` to two decimals, as each process's; `subgroups` on every group,
    /// `[]` where none.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(TextFormat.rounded(cpuPercent, places: 2), forKey: .cpuPercent)
        try container.encode(TextFormat.rounded(exitedChildrenCpuPercent, places: 2), forKey: .exitedChildrenCpuPercent)
        try container.encode(residentBytes, forKey: .residentBytes)
        try container.encode(disk, forKey: .disk)
        try container.encode(network, forKey: .network)
        try container.encode(pids, forKey: .pids)
        try container.encode(subgroups, forKey: .subgroups)
    }
}

public enum RepoGroups {
    public static let vms = "VMs"
    public static let notInARepo = "Not in a repo"
    public static let systemAndOtherUsers = "System and other users"

    /// Each row's repo, and the groups they form (research § Q4, § Q5). A readable working directory
    /// gives the repo; outside any repo, the last `--add-dir` that is one does (a swarm member works in
    /// an empty scratch folder and reaches its project by `--add-dir`), else the nearest ancestor's
    /// `--add-dir` repo (the member's children); else the executable's folder does, else the row is
    /// "Not in a repo". With no readable working directory (other users' and root's processes) the row
    /// takes its parent's repo, else its executable's, else it is "System and other users". A VM in no repo
    /// goes to "VMs" instead of a catch-all (Phase 5 Step 4). Every row lands in exactly one group; groups
    /// go by header total (own plus exited-children CPU, rounded to one decimal), then name and root;
    /// then "VMs", the two catch-alls last (`shownBefore`). A repo group that
    /// is a full clone of another carries `cloneOf` (`cloneOf(_:among:repoOfDirectory:)`). An orphan
    /// (`ProcessUsage.orphaned`) takes the repo its group's stand-ins have by these rules (`Orphans.StandIns`), over its
    /// own folder's; with none, its own (Phase 6 Step 8). Its children inherit it as from any parent.
    public static func assign(_ rows: [ProcessUsage], workingDirectories: [Int32: String],
                              repoOfDirectory: (String) -> RepoInfo?,
                              repoOfExecutable: (String) -> RepoInfo?) -> (rows: [ProcessUsage], groups: [RepoGroup]) {
        assign(rows, workingDirectories: workingDirectories, repoOfDirectory: repoOfDirectory,
               repoOfExecutable: repoOfExecutable, remembered: [:])
    }

    static func assign(_ rows: [ProcessUsage], workingDirectories: [Int32: String],
                       repoOfDirectory: (String) -> RepoInfo?, repoOfExecutable: (String) -> RepoInfo?,
                       remembered: [Int32: Orphans.Ownership]) -> (rows: [ProcessUsage], groups: [RepoGroup]) {
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let standIns = Orphans.StandIns(rows)
        struct Key: Hashable { let pid: Int32, viaGroup: Bool }
        var memo: [Key: (repo: RepoInfo?, byAddDir: Bool)] = [:]
        var inProgress: Set<Key> = []

        /// The row's repo, and whether it came through `--add-dir` (its own or an ancestor's): only
        /// those ties pass to children working outside any repo, so Step 1's rule stays for the rest.
        /// `viaGroup` false reads a stand-in's repo without the orphan rule, so a tie never runs through a second group.
        func tie(of row: ProcessUsage, viaGroup: Bool = true) -> (repo: RepoInfo?, byAddDir: Bool) {
            let key = Key(pid: row.pid, viaGroup: viaGroup)
            if let known = memo[key] { return known }
            // A ppid loop (a pid reused mid-read) ends here with no inherited repo.
            guard inProgress.insert(key).inserted else { return (nil, false) }
            defer { inProgress.remove(key) }
            var found: (repo: RepoInfo?, byAddDir: Bool) = (nil, false)
            let parent = row.ppid != row.pid ? byPid[row.ppid] : nil
            if viaGroup, row.orphaned,
               let repo = standIns.of(row).compactMap({ tie(of: $0, viaGroup: false).repo }).first
                    ?? row.processGroup.flatMap({ remembered[$0]?.repo }) {
                found.repo = repo
            } else if let cwd = workingDirectories[row.pid] {
                found.repo = repoOfDirectory(cwd)
                if found.repo == nil {
                    found.repo = row.addDirectories.reversed().lazy
                        .map { URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardized.path }
                        .compactMap(repoOfDirectory).first
                        ?? parent.map { tie(of: $0, viaGroup: viaGroup) }.flatMap { $0.byAddDir ? $0.repo : nil }
                    found.byAddDir = found.repo != nil
                }
            } else if let parent {
                found = tie(of: parent, viaGroup: viaGroup)
            }
            if found.repo == nil, let path = row.path { found.repo = repoOfExecutable(path) }
            memo[key] = found
            return found
        }

        let assigned = withMainCheckoutRoots(rows.map { row in
            var row = row
            row.repo = tie(of: row).repo
            return row
        })
        return (assigned, groups(assigned, workingDirectories: workingDirectories, repoOfDirectory: repoOfDirectory))
    }

    /// A separate git dir has no backlink to its main checkout. Prefer a main checkout present in
    /// this sample, after every row has resolved, so discovery order and the resolver cache do not matter.
    private static func withMainCheckoutRoots(_ rows: [ProcessUsage]) -> [ProcessUsage] {
        let mains = Dictionary(rows.compactMap(\.repo).filter { $0.worktree == nil }.map { ($0.groupKey, $0) },
                               uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            guard let repo = row.repo, let main = mains[repo.groupKey], repo.root != main.root else { return row }
            var row = row
            var canonical = RepoInfo(name: main.name, root: main.root, worktree: repo.worktree, origin: repo.origin)
            canonical.commonGitDir = repo.commonGitDir
            row.repo = canonical
            return row
        }
    }

    private static func groups(_ rows: [ProcessUsage], workingDirectories: [Int32: String],
                               repoOfDirectory: (String) -> RepoInfo?) -> [RepoGroup] {
        var members: [String: (name: String, root: String?, rows: [ProcessUsage])] = [:]
        var order: [String] = []
        for row in rows {
            let key: String, name: String
            if let repo = row.repo {
                (key, name) = ("repo:" + repo.groupKey, repo.name)
            } else if row.vm != nil {
                (key, name) = ("vms", vms)
            } else {
                name = workingDirectories[row.pid] == nil ? systemAndOtherUsers : notInARepo
                key = "catch-all:" + name
            }
            if members[key] == nil { order.append(key) }
            members[key, default: (name, row.repo?.root, [])].rows.append(row)
        }
        let repos = order.compactMap { members[$0]?.rows.first?.repo }
        let groups = order.compactMap { members[$0] }.map { member in
            let totals = GroupTotals(member.rows)
            return RepoGroup(name: member.name, root: member.root,
                             cloneOf: member.rows.first?.repo.flatMap { cloneOf($0, among: repos, repoOfDirectory: repoOfDirectory) },
                             cpuPercent: totals.cpuPercent, exitedChildrenCpuPercent: totals.exitedChildrenCpuPercent,
                             residentBytes: totals.residentBytes, disk: totals.disk, network: totals.network,
                             pids: member.rows.map(\.pid))
        }
        return groups.sorted(by: shownBefore)
    }

    /// The directories a `claude` command line grants with `--add-dir <directories...>` (every value up
    /// to the next flag) or `--add-dir=<dir>`, in order.
    public static func addDirectories(argv: [String]) -> [String] {
        var out: [String] = []
        var taking = false
        for arg in argv.dropFirst() {
            if arg == "--add-dir" {
                taking = true
            } else if arg.hasPrefix("--add-dir=") {
                taking = false
                out.append(String(arg.dropFirst("--add-dir=".count)))
            } else if arg.hasPrefix("-") {
                taking = false
            } else if taking {
                out.append(arg)
            }
        }
        return out
    }

    /// The name of the repo `repo` is a full clone of, among the groups' repos (research § Q2: shown as a
    /// hint, never merged — git treats each clone as its own repository). Its origin is a local path
    /// another group's repo resolves from (`git clone /path/src copy`); or it shares its origin's
    /// `remoteKey` with a group named as `git clone` names the folder (the URL's last part) while its own
    /// name differs — so a CI runner's `hostexecutor` checkout reads "clone of Saur0n", not the reverse.
    static func cloneOf(_ repo: RepoInfo, among repos: [RepoInfo], repoOfDirectory: (String) -> RepoInfo?) -> String? {
        guard let origin = repo.origin else { return nil }
        let others = repos.filter { $0.root != repo.root }
        guard let key = remoteKey(origin) else {
            var path = origin.hasPrefix("file://") ? String(origin.dropFirst("file://".count)) : origin
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard path.hasPrefix("/"), let source = repoOfDirectory(path) else { return nil }
            return others.first { $0.root == source.root }?.name
        }
        guard let humanish = key.split(separator: "/").last.map(String.init), repo.name.lowercased() != humanish else { return nil }
        return others.first { $0.name.lowercased() == humanish && $0.origin.flatMap(remoteKey) == key }?.name
    }

    /// A remote URL's identity: lowercased `host/owner/repo`, user, port, trailing `/` and `.git` dropped,
    /// for `scheme://[user@]host[:port]/path` and scp-style `[user@]host:path`; nil for a local path or
    /// `file://` URL.
    public static func remoteKey(_ url: String) -> String? {
        var host: Substring, path: Substring
        if let scheme = url.range(of: "://") {
            guard url[..<scheme.lowerBound] != "file" else { return nil }
            let rest = url[scheme.upperBound...]
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            host = rest[..<slash]
            path = rest[slash...]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            if let colon = host.firstIndex(of: ":") { host = host[..<colon] }
        } else {
            guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return nil }
            host = url[..<colon]
            path = url[url.index(after: colon)...]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        }
        var trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix(".git") { trimmed = String(trimmed.dropLast(4)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        guard !host.isEmpty, !trimmed.isEmpty else { return nil }
        return (host + "/" + trimmed).lowercased()
    }

    /// Repos by header total (own plus exited-children CPU, one decimal, as shown), then name and root;
    /// then "VMs", "Not in a repo", "System and other users".
    static func shownBefore(_ a: RepoGroup, _ b: RepoGroup) -> Bool {
        func rank(_ g: RepoGroup) -> Int { g.root != nil ? 0 : g.name == vms ? 1 : g.name == notInARepo ? 2 : 3 }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        let (x, y) = (TextFormat.rounded(a.totalCpuPercent), TextFormat.rounded(b.totalCpuPercent))
        if x != y { return x > y }
        return (a.name, a.root ?? "") < (b.name, b.root ?? "")
    }
}
