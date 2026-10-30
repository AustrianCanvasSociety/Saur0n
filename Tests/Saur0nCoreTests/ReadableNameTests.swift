// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Saur0nCore

// Goal: test runs named the way the user thinks of them. Method: each runner's launch shape (path,
// argv, environment) through `ReadableName.of`.

/// Launch shapes recorded from real test runs (research/2026-10-16-phase2-open.md § Q2), with
/// documentation paths in place of real ones.
private func name(_ path: String?, _ argv: [String] = [], env: [String: String] = [:]) -> String? {
    ReadableName.of(path: path, arguments: ProcessArguments(argv: argv, environment: env))
}

// MARK: Rust

@Test func rustUnitAndIntegration() {
    let env = ["CARGO_PKG_NAME": "my-crate"]
    #expect(name("/w/target/debug/deps/my_crate-e4a187bd42b117ee", ["/w/target/debug/deps/my_crate-e4a187bd42b117ee", "--quiet"], env: env)
            == "test: my_crate · my-crate")
    #expect(name("/w/target/debug/deps/astar-f93bb998ee1a2b3c", env: env) == "test: astar · my-crate")
}

@Test func rustCrateFallback() {
    #expect(name("/w/target/debug/deps/astar-f93bb998ee1a2b3c") == "test: astar · w")
    #expect(name("/w/build/deps/astar-f93bb998ee1a2b3c") == "test: astar")
    #expect(ReadableName.of(path: "/w/target/debug/deps/astar-f93bb998ee1a2b3c", arguments: nil) == "test: astar · w")
}

@Test func rustBench() {
    #expect(name("/w/target/release/deps/budget-3f2b8aca25e06c0b", ["budget", "--bench"], env: ["CARGO_PKG_NAME": "bench"])
            == "bench: budget · bench")
}

@Test func rustDoctest() {
    #expect(name("/var/folders/x/T/rustdoctest4EYeZ1/rust_out", env: ["CARGO_PKG_NAME": "my-crate"]) == "doctest · my-crate")
    #expect(name("/var/folders/x/T/rustdoctest4EYeZ1/rust_out") == "doctest")
    #expect(name("/w/rust_out") == nil)
}

// MARK: other languages

@Test func goTest() {
    #expect(name("/var/folders/x/T/go-build123/b001/inner.test", ["/var/folders/x/T/go-build123/b001/inner.test", "-test.paniconexit0"])
            == "test: inner")
}

@Test func swiftTest() {
    let helper = "/Library/Developer/CommandLineTools/usr/libexec/swift/pm/swiftpm-testing-helper"
    #expect(name(helper, [helper, "--test-bundle-path", "/w/Pkg/.build/out/Products/Debug/ProbeTests.xctest/Contents/MacOS/ProbeTests",
                          "--testing-library", "swift-testing"]) == "test: ProbeTests · Pkg")
    #expect(name(helper, [helper, "--test-bundle-path", "/w/ProbeTests.xctest/Contents/MacOS/ProbeTests"]) == "test: ProbeTests")
    #expect(name(helper, [helper]) == nil)
}

@Test func jsRunners() {
    #expect(name("/opt/homebrew/bin/bun", ["bun", "test", "./a.test.ts"]) == "test: bun")
    #expect(name("/opt/homebrew/bin/node", ["node", "--test", "f.test.js"]) == "test runner: node")
    // node:test children, recorded from Node 26.11 and 22.23: both set NODE_TEST_CONTEXT=child-v8;
    // only Node 26 passes --test-* flags, and Node 22's argv is the bare file.
    let child = ["NODE_TEST_CONTEXT": "child-v8"]
    #expect(name("/opt/homebrew/bin/node", ["node", "--test-timeout=0", "--test-concurrency=0", "/w/f.test.js"], env: child)
            == "test: f.test.js")
    #expect(name("/w/node-v22/bin/node", ["node", "a.test.mjs"], env: child) == "test: a.test.mjs")
    #expect(name("/opt/homebrew/bin/node", ["node", "--test-timeout=0", "--test-concurrency=4", "/w/f.test.js"]) == nil)
    #expect(name("/w/node-v22/bin/node", ["node", "server.js"]) == nil)
    // The runner itself may carry the concurrency flag; its last argument is then a flag or a file.
    #expect(name("/opt/homebrew/bin/node", ["node", "--test", "--test-concurrency=1"]) == "test runner: node")
    #expect(name("/opt/homebrew/bin/node", ["node", "--test-concurrency=4", "--test"]) == "test runner: node")
    #expect(name("/opt/homebrew/bin/node", ["node", "--test", "--test-concurrency=1", "a.test.js"]) == "test runner: node")
    #expect(name("/opt/homebrew/bin/node", ["node", "--test-concurrency=1", "--test-only"]) == nil)
    #expect(name("/opt/homebrew/bin/node", ["node", "/w/node_modules/vitest/vitest.mjs", "run"]) == "test runner: vitest")
    #expect(name("/opt/homebrew/bin/node", ["node", "--require", "/w/node_modules/vitest/suppress-warnings.cjs",
                                            "/w/node_modules/vitest/dist/workers/forks.js"]) == "test: vitest worker")
}

@Test func pytest() {
    #expect(name("/usr/bin/python3.12", ["python3.12", "-m", "pytest", "-q"]) == "test: pytest")
    // Framework Pythons (Homebrew, python.org, Command Line Tools) run as `…/Python.app/Contents/MacOS/Python`.
    #expect(name("/opt/homebrew/Cellar/python@3.14/3.14.8/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python",
                 ["/opt/homebrew/opt/python@3.14/bin/python3.14", "-m", "pytest"]) == "test: pytest")
    #expect(name("/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python",
                 ["/usr/bin/python3", "/u/venv/bin/pytest"]) == "test: pytest")
    #expect(name("/u/.cache/uv/archive-v0/a1/bin/python", ["/u/.cache/uv/archive-v0/a1/bin/python", "/u/.cache/uv/archive-v0/a1/bin/pytest", "-q"])
            == "test: pytest")
}

@Test func harnessParents() {
    #expect(name("/u/.rustup/toolchains/stable/bin/cargo", ["cargo", "test", "-q", "-p", "bench"]) == "test runner: cargo")
    #expect(name("/u/.rustup/toolchains/stable/bin/cargo", ["cargo", "+nightly", "test"]) == "test runner: cargo")
    #expect(name("/opt/homebrew/bin/go", ["go", "test", "./..."]) == "test runner: go")
    // A global flag's value is not the subcommand (flags from `cargo --help`, `go help`).
    let cargo = "/u/.rustup/toolchains/stable/bin/cargo"
    #expect(name(cargo, ["cargo", "--color", "always", "test"]) == "test runner: cargo")
    #expect(name(cargo, ["cargo", "+nightly", "-Z", "unstable-options", "--config", "k=1", "test"]) == "test runner: cargo")
    #expect(name(cargo, ["cargo", "-C", "test", "build"]) == nil)
    #expect(name("/opt/homebrew/bin/go", ["go", "-C", "./svc", "test", "./..."]) == "test runner: go")
    #expect(name("/opt/homebrew/bin/bun", ["bun", "--preload=./setup.ts", "test"]) == "test: bun")
    #expect(name("/Library/Developer/CommandLineTools/usr/bin/swift-test", ["swift-test", "-Xswiftc", "-plugin-path"]) == "test runner: swift")
}

// MARK: not tests

@Test func notATest() {
    #expect(name("/w/target/debug/deps/astar-f93bb998ee1a2b3") == nil)      // 15 hex
    #expect(name("/w/target/debug/deps/astar-f93bb998ee1a2b3cd") == nil)    // 17 hex
    #expect(name("/w/target/debug/deps/astar-F93BB998EE1A2B3C") == nil)     // uppercase
    #expect(name("/w/target/debug/astar-f93bb998ee1a2b3c") == nil)          // not in deps
    #expect(name("/u/.rustup/toolchains/stable/bin/cargo", ["cargo", "build"]) == nil)
    #expect(name("/opt/homebrew/bin/node", ["node", "server.js"]) == nil)
    #expect(name("/usr/bin/python3", ["python3", "app.py"]) == nil)
    #expect(name("/opt/homebrew/bin/bun", ["bun", "run", "dev"]) == nil)
}

@Test func nilInputs() {
    #expect(ReadableName.of(path: nil, arguments: nil) == nil)
    #expect(ReadableName.of(path: "/usr/libexec/trustd", arguments: nil) == nil)
}
