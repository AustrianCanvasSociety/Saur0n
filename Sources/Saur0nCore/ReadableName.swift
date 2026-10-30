// SPDX-License-Identifier: GPL-3.0-or-later
/// A process's arguments and environment as `sysctl KERN_PROCARGS2` returns them.
public struct ProcessArguments: Equatable, Sendable {
    public let argv: [String]
    /// The keys in `environmentKeys` only, as read.
    public let environment: [String: String]

    /// The environment keys Saur0n reads: test-run names (`ReadableName`) and Claude Code sessions
    /// (`SessionSources`). A reader of another key adds it here.
    public static let environmentKeys: Set<String> = ["CARGO_PKG_NAME", "NODE_TEST_CONTEXT", "CLAUDE_CODE_SESSION_ID"]

    public init(argv: [String], environment: [String: String]) {
        self.argv = argv
        self.environment = environment
    }
}

/// Names test runs the way the user thinks of them, from the full executable path, argv and
/// environment — never the kernel's short name, which stops at 16 characters. First match wins;
/// nil when nothing matches. Launch shapes: research/2026-10-16-phase2-open.md § Q2.
public enum ReadableName {
    public static func of(path: String?, arguments: ProcessArguments?) -> String? {
        guard let path else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard let base = parts.last else { return nil }
        let parent = parts.count > 1 ? parts[parts.count - 2] : ""
        let argv = arguments?.argv ?? []
        let env = arguments?.environment ?? [:]

        if parent == "deps", let target = rustTarget(base) {
            let targetOffset = [4, 5].first { parts.count > $0 && parts[parts.count - $0] == "target" }
            let folder = targetOffset.map { parts[parts.count - $0 - 1] }
            let crate = env["CARGO_PKG_NAME"] ?? folder
            let kind = argv.contains("--bench") ? "bench" : "test"
            return "\(kind): \(target)" + (crate.map { " · \($0)" } ?? "")
        }
        if base == "rust_out", parent.hasPrefix("rustdoctest") {
            return "doctest" + (env["CARGO_PKG_NAME"].map { " · \($0)" } ?? "")
        }
        if base.hasSuffix(".test"), numbered(parent, "b"), parts.count > 2, numbered(parts[parts.count - 3], "go-build") {
            return "test: \(base.dropLast(5))"
        }
        if base == "swiftpm-testing-helper" {
            guard let i = argv.firstIndex(of: "--test-bundle-path"), i + 1 < argv.count else { return nil }
            let bundle = argv[i + 1].split(separator: "/").map(String.init)
            guard let xctest = bundle.first(where: { $0.hasSuffix(".xctest") }) else { return nil }
            let package = bundle.firstIndex(of: ".build").flatMap { $0 > 0 ? bundle[$0 - 1] : nil }
            return "test: \(xctest.dropLast(7))" + (package.map { " · \($0)" } ?? "")
        }
        if base == "swift-test" { return "test runner: swift" }
        if base == "cargo", subcommand(argv, valueFlags: cargoValueFlags) == "test" { return "test runner: cargo" }
        if base == "go", subcommand(argv, valueFlags: ["-C"]) == "test" { return "test runner: go" }
        if base == "bun", subcommand(argv) == "test" { return "test: bun" }    // bun's value flags take `=`
        if base == "node" {
            if argv.contains(where: { $0.hasSuffix("/vitest/vitest.mjs") }) { return "test runner: vitest" }
            if argv.contains(where: { $0.contains("/vitest/dist/workers/") }) { return "test: vitest worker" }
            if argv.contains("--test") { return "test runner: node" }
            // A node:test child: the runner sets NODE_TEST_CONTEXT=child… (Node 22 and 26 both;
            // Node 22 gives no --test-* flags) and passes the file last.
            if env["NODE_TEST_CONTEXT"]?.hasPrefix("child") == true, let last = argv.last, !last.hasPrefix("-"),
               let file = ProcessSample.basename(last) {
                return "test: \(file)"
            }
        }
        // Framework Pythons (Homebrew, python.org, Command Line Tools) run as `…/MacOS/Python`.
        if base.lowercased().hasPrefix("python") {
            let viaModule = zip(argv, argv.dropFirst()).contains { $0 == "-m" && $1 == "pytest" }
            if viaModule || argv.dropFirst().first?.hasSuffix("/pytest") == true { return "test: pytest" }
        }
        return nil
    }

    /// `<target>` of cargo's `<target>-<16 lowercase hex>` test binaries.
    static func rustTarget(_ base: String) -> String? {
        guard let dash = base.lastIndex(of: "-"), dash > base.startIndex else { return nil }
        let hash = base[base.index(after: dash)...]
        guard hash.count == 16, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return String(base[..<dash])
    }

    /// `prefix` followed by one or more ASCII digits (`b001`, `go-build123`).
    static func numbered(_ text: String, _ prefix: String) -> Bool {
        guard text.hasPrefix(prefix) else { return false }
        let rest = text.dropFirst(prefix.count)
        return !rest.isEmpty && rest.allSatisfy { ("0"..."9").contains($0) }
    }

    /// cargo's global flags that take the next argument as their value (`cargo --help`).
    static let cargoValueFlags: Set<String> = ["--color", "--config", "--explain", "-C", "-Z"]

    /// The first argument after argv[0] that is not a flag, a flag's value (a `valueFlags` flag
    /// takes the argument after it) or a rustup `+toolchain`.
    static func subcommand(_ argv: [String], valueFlags: Set<String> = []) -> String? {
        var rest = argv.dropFirst()
        while let arg = rest.popFirst() {
            if valueFlags.contains(arg) {
                rest = rest.dropFirst()
            } else if !arg.hasPrefix("-"), !arg.hasPrefix("+") {
                return arg
            }
        }
        return nil
    }
}
