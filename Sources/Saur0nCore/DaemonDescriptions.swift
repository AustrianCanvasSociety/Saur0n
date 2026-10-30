// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The one-line description a man page's source gives for its program, read without `man`.
/// Shapes handled (research/2026-10-16-phase2-open.md § Q1): mdoc `.Nd` (continuation lines
/// joined), man and Pod::Man `NAME` sections (`name \- text`), and the first DESCRIPTION
/// sentence for pages whose NAME section holds only `.Nm`.
enum DaemonDescriptions {
    static func oneLiner(page: String, name: String) -> String? {
        let lines = withoutDefinitions(page.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripComment(String($0)) })

        if let nd = lines.firstIndex(where: { macro($0) == "Nd" }) {
            let first = lines[nd].dropFirst(3).trimmingCharacters(in: .whitespaces)
            let inner = first.dropFirst().dropLast()
            let quoted = first.count >= 2 && first.hasPrefix("\"") && first.hasSuffix("\"") && !inner.contains("\"")
            var parts = [quoted ? String(inner) : first]
            for line in lines[(nd + 1)...] {
                if endsParagraph(line) { break }
                parts.append(render(line, name: name))
            }
            if let text = clean(parts.joined(separator: " ")) { return text }
        }
        if let body = section("NAME", in: lines, name: name), let dash = body.range(of: " - ") {
            if let text = clean(String(body[dash.upperBound...])) { return text }
        }
        if let body = section("DESCRIPTION", in: lines, name: name) {
            let sentence = body.range(of: ". ").map { String(body[..<$0.lowerBound]) + "." } ?? body
            return clean(sentence)
        }
        return nil
    }

    /// The rendered, unescaped text of section `title` (`.Sh` / `.SH`, quoted or not), or nil.
    static func section(_ title: String, in lines: [String], name: String) -> String? {
        func isHeader(_ line: String) -> Bool { macro(line) == "Sh" || macro(line) == "SH" }
        guard let start = lines.firstIndex(where: {
            isHeader($0) && $0.dropFirst(3).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: ["\""]) == title
        }) else { return nil }
        let body = lines[(start + 1)...].prefix { !isHeader($0) }.map { render($0, name: name) }
        return clean(body.joined(separator: " "))
    }

    /// The macro name of a request line (`.Nd text` → `Nd`, a bare `.` → empty), or nil for a text line.
    static func macro(_ line: String) -> String? {
        guard line.hasPrefix(".") else { return nil }
        return line.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    }

    static func endsParagraph(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
            || ["Sh", "SH", "Ss", "SS", "Pp", "PP", "LP", "P"].contains(macro(line) ?? "")
    }

    /// Text lines as they are; inline mdoc macros as their arguments (`.Xr launchd 8` → `launchd(8)`,
    /// a bare `.Nm` → the page's name); every other request (`.IX`, `.Dd`, …) as nothing.
    static func render(_ line: String, name: String) -> String {
        guard let macro = macro(line) else { return line }
        let args = line.dropFirst().split(separator: " ").dropFirst().map { $0.trimmingCharacters(in: ["\""]) }
        switch macro {
        case "Xr" where args.count >= 2: return "\(args[0])(\(args[1]))" + args.dropFirst(2).map { " " + $0 }.joined()
        case "Nm": return args.isEmpty ? name : args.joined(separator: " ")
        case "Ar", "Pa", "Ql", "Em", "Sy", "Cm", "Li", "B", "I": return args.joined(separator: " ")
        default: return ""
        }
    }

    /// Lines with every macro definition (`.de`, `.de1`, `.am`, …) and ignored block (`.ig`) removed,
    /// from its request through its closing `..`. Their bodies are roff code, not page text, and
    /// rst2man writes its definitions inside the NAME section.
    static func withoutDefinitions(_ lines: [String]) -> [String] {
        var out: [String] = [], inBlock = false
        for line in lines {
            if inBlock {
                if line.hasPrefix("..") { inBlock = false }
                continue
            }
            if let macro = macro(line), ["de", "de1", "dei", "am", "am1", "ami", "ig"].contains(macro) {
                inBlock = true
                continue
            }
            out.append(line)
        }
        return out
    }

    /// Everything from a `\"` comment to the end of the line removed.
    static func stripComment(_ line: String) -> String {
        line.range(of: "\\\"").map { String(line[..<$0.lowerBound]) } ?? line
    }

    /// Escapes resolved, whitespace collapsed; nil when nothing is left.
    static func clean(_ text: String) -> String? {
        let words = unescape(text).split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Named characters and strings the Mac's pages use, by their two-letter roff name.
    static let named = ["em": "—", "en": "–", "aq": "'", "lq": "\"", "rq": "\"", "dq": "\"", "--": "—", "L\"": "\"", "R\"": "\""]

    static func unescape(_ text: String) -> String {
        var out = ""
        var chars = text.makeIterator()
        while let c = chars.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let e = chars.next() else { break }
            switch e {
            case "-": out.append("-")
            case "e": out.append("\\")
            case " ": out.append(" ")
            case "&": break
            case "f":    // font change: \fB, \f(CW, \f[B]
                switch chars.next() {
                case "(": _ = chars.next(); _ = chars.next()
                case "[": while let x = chars.next(), x != "]" {}
                default: break    // \fB: its one letter was read by the switch
                }
            case "(", "*":    // special character \(em, string \*(--; a one-letter \*x reads as nothing
                var key = ""
                if e == "*" {
                    guard chars.next() == "(" else { break }
                }
                if let a = chars.next() { key.append(a) }
                if let b = chars.next() { key.append(b) }
                out += Self.named[key] ?? ""
            default: out.append(e)
            }
        }
        return out
    }
}

/// Which programs a man page may describe: the system's pages (in SIP-protected folders) describe
/// system programs; a `<root>/share/man` page describes programs under `<root>` (`/usr/local`).
enum ManScope: Equatable, Sendable {
    case system
    case under(String)

    /// The scope of the page at `page`; nil for a page outside any `<root>/share/man`.
    init?(page: String) {
        if DescriptionSources.isSystemProgram(page) {
            self = .system
        } else if let share = page.range(of: "/share/man/") {
            self = .under(String(page[..<share.lowerBound]))
        } else {
            return nil
        }
    }
}

/// A man page's one-liner and the programs it may describe.
struct ManLine: Equatable, Sendable, ExpressibleByStringLiteral {
    let text: String
    let scope: ManScope

    init(text: String, scope: ManScope) {
        self.text = text
        self.scope = scope
    }

    /// A system page's line.
    init(stringLiteral text: String) { self.init(text: text, scope: .system) }
}

/// Where descriptions come from, in the order they win: our own table, the man page's one-liner,
/// the app the process belongs to, its launchd label. The first two go by name, which any program
/// can take, so they apply only to programs in the folders they describe; the last two go by the
/// program's own path. `load(for:)` (in SystemReaders) reads each page and Info.plist the running
/// processes need, once, and `extend(for:)` adds only what later processes bring; tests pass their own.
public struct DescriptionSources: Sendable {
    /// Process name → its man page's one-liner.
    private(set) var manLines: [String: ManLine]
    /// Bundle root → its display name.
    private(set) var bundleNames: [String: String]
    /// Executable path → launchd `Label`.
    let launchdLabels: [String: String]
    /// Program name → its man page's path (`manIndex`), read once.
    let manPages: [String: String]
    /// Names and bundle roots already looked up, found or not, so no page or Info.plist is read twice.
    private var seenNames: Set<String> = []
    private var seenRoots: Set<String> = []

    init(manLines: [String: ManLine] = [:], bundleNames: [String: String] = [:], launchdLabels: [String: String],
         manPages: [String: String] = [:]) {
        self.manLines = manLines
        self.bundleNames = bundleNames
        self.launchdLabels = launchdLabels
        self.manPages = manPages
    }

    /// Adds the man-page one-liner of each process name in `sample` with no table entry, and the display name of
    /// each bundle, for names and bundles no earlier sample brought: the window calls it every refresh, and
    /// re-reading every page each second would cost about 0.6% of the machine (research 2026-10-19 Q3).
    /// `oneLiner(name, page)` and `bundleName(root)` read the files (SystemReaders); tests pass their own.
    public mutating func extend(for sample: ProcessListSample) {
        extend(for: sample, oneLiner: Self.readOneLiner, bundleName: Self.bundleDisplayName)
    }

    mutating func extend(for sample: ProcessListSample, oneLiner: (String, String) -> ManLine?,
                         bundleName: (String) -> String?) {
        for process in sample.processes {
            let name = sample.name(of: process)
            if DescriptionTable.byName[name] == nil, seenNames.insert(name).inserted, let page = manPages[name] {
                manLines[name] = oneLiner(name, page)
            }
            if let root = process.path.flatMap(Self.bundleRoot), seenRoots.insert(root).inserted {
                bundleNames[root] = bundleName(root)
            }
        }
    }

    public func describe(pid: Int32, name: String, path: String?) -> String? {
        // No readable path: the kernel (pid 0), or a program that exited or whose file was deleted.
        let system = path.map(Self.isSystemProgram) ?? (pid == 0)
        if system, let text = DescriptionTable.byName[name] { return text }
        if let line = manLines[name] {
            switch line.scope {
            case .system where system: return line.text
            case .under(let root) where path?.hasPrefix(root + "/") == true: return line.text
            default: break
            }
        }
        guard let path else { return nil }
        if let root = Self.bundleRoot(path), let app = bundleNames[root], app != name { return "part of \(app)" }
        return launchdLabels[path]
    }

    /// A path in the folders System Integrity Protection guards: `/System`, `/usr` but not
    /// `/usr/local`, `/bin`, `/sbin`, `/Library/Apple` (each carries the `restricted` flag that
    /// `ls -ldO` shows; `/usr/local` does not).
    static func isSystemProgram(_ path: String) -> Bool {
        if path.hasPrefix("/usr/local/") { return false }
        return ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    /// The outermost `.app` holding `path`, else the first `.xpc` / `.appex` / `.bundle`.
    static func bundleRoot(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let index = parts.firstIndex { $0.hasSuffix(".app") }
            ?? parts.firstIndex { $0.hasSuffix(".xpc") || $0.hasSuffix(".appex") || $0.hasSuffix(".bundle") }
        return index.map { parts[...$0].joined(separator: "/") }
    }

    /// A launchd plist's program: `Program`, else `ProgramArguments[0]`.
    static func launchdProgram(_ plist: [String: Any]) -> String? {
        plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
    }
}
