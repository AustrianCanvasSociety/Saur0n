// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Bytes received and sent, cumulative: since the interface came up for the machine; over its open sockets for a
/// process (`nettop` drops a socket's bytes once it closes; probe 2026-10-21).
public struct NetworkBytes: Equatable, Sendable {
    public var received: UInt64
    public var sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }

    public static let zero = NetworkBytes(received: 0, sent: 0)
}

/// Bytes per second over one window, rounded to whole bytes.
public struct NetworkRate: Equatable, Sendable, Encodable {
    public var inBytesPerSecond: UInt64
    public var outBytesPerSecond: UInt64

    public init(inBytesPerSecond: UInt64, outBytesPerSecond: UInt64) {
        self.inBytesPerSecond = inBytesPerSecond
        self.outBytesPerSecond = outBytesPerSecond
    }

    public static let zero = NetworkRate(inBytesPerSecond: 0, outBytesPerSecond: 0)

    /// In plus out: what the NET column shows.
    public var totalBytesPerSecond: UInt64 { inBytesPerSecond &+ outBytesPerSecond }
}

/// A rate over the last window and the cumulative bytes at its end: the JSON's `network` on the snapshot, each
/// process and each group.
public struct NetworkUsage: Equatable, Sendable, Encodable {
    public var inBytesPerSecond: UInt64
    public var outBytesPerSecond: UInt64
    public var inBytes: UInt64
    public var outBytes: UInt64

    public init(rate: NetworkRate, bytes: NetworkBytes) {
        inBytesPerSecond = rate.inBytesPerSecond
        outBytesPerSecond = rate.outBytesPerSecond
        inBytes = bytes.received
        outBytes = bytes.sent
    }

    public static let zero = NetworkUsage(rate: .zero, bytes: .zero)

    public var rate: NetworkRate { NetworkRate(inBytesPerSecond: inBytesPerSecond, outBytesPerSecond: outBytesPerSecond) }
}

/// The machine's physical-interface counters at one moment, stamped as `MachineDiskSample` is.
public struct MachineNetworkSample: Equatable, Sendable {
    public let bytes: NetworkBytes
    public let uptimeNanoseconds: UInt64
    public let epochSeconds: Double

    public init(bytes: NetworkBytes, uptimeNanoseconds: UInt64, epochSeconds: Double = 0) {
        self.bytes = bytes
        self.uptimeNanoseconds = uptimeNanoseconds
        self.epochSeconds = epochSeconds
    }
}

/// When the machine's two network reads were taken, in seconds since the epoch: the JSON's `network.windowStart`
/// and `network.windowEnd`.
public struct NetworkWindow: Equatable, Sendable {
    public let start: Double
    public let end: Double

    public init(before: MachineNetworkSample, after: MachineNetworkSample) {
        start = before.epochSeconds
        end = after.epochSeconds
    }
}

public enum NetworkActivityError: Error, Equatable, Sendable {
    case unreadable
}

/// Network figures as pure rules over counter reads; `MachineNetworkReader` and `NettopRunner` take the reads.
/// No remainder line, unlike disk: a VPN or tunnel daemon re-sends other processes' bytes, so the rows may sum past
/// the machine by design (Phase 5 plan, user 2026-10-20).
public enum NetworkActivity {
    /// The Ethernet-type ports: Wi-Fi, Thunderbolt and USB Ethernet are all `en<N>`. By name, not link type:
    /// `bridge0` (bridges `en` ports already counted), `anpi*`, `awdl0` and `llw0` report the Ethernet type too.
    /// Tunnels (`utun*`), loopback and the rest are left out.
    static func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en") && name.count > 2 && name.dropFirst(2).allSatisfy { ("0"..."9").contains($0) }
    }

    /// The bytes of every physical interface.
    public static func physical(_ interfaces: [(name: String, bytes: NetworkBytes)]) -> NetworkBytes {
        interfaces.filter { isPhysical($0.name) }
            .reduce(NetworkBytes.zero) { NetworkBytes(received: $0.received &+ $1.bytes.received, sent: $0.sent &+ $1.bytes.sent) }
    }

    /// Bytes per second from `before` to `after` over `nanoseconds`; a counter that went backwards (an interface
    /// gone between the reads lowers the sum), or no time elapsed, reads 0.
    public static func rate(before: NetworkBytes, after: NetworkBytes, nanoseconds: UInt64) -> NetworkRate {
        func perSecond(_ then: UInt64, _ now: UInt64) -> UInt64 {
            guard nanoseconds > 0, now > then else { return 0 }
            return ProcessSample.roundedUInt64(Double(now - then) * 1e9 / Double(nanoseconds)) ?? 0
        }
        return NetworkRate(inBytesPerSecond: perSecond(before.received, after.received),
                           outBytesPerSecond: perSecond(before.sent, after.sent))
    }

    /// The machine's rate between two reads, over their own stamps, and its counters at the second.
    public static func usage(before: MachineNetworkSample, after: MachineNetworkSample) -> NetworkUsage {
        let elapsed = after.uptimeNanoseconds > before.uptimeNanoseconds ? after.uptimeNanoseconds - before.uptimeNanoseconds : 0
        return NetworkUsage(rate: rate(before: before.bytes, after: after.bytes, nanoseconds: elapsed), bytes: after.bytes)
    }

    /// Rates and cumulative bytes summed over the rows that have them.
    public static func sum(_ rows: [NetworkUsage?]) -> NetworkUsage {
        rows.compactMap { $0 }.reduce(NetworkUsage.zero) { total, row in
            NetworkUsage(rate: NetworkRate(inBytesPerSecond: total.inBytesPerSecond &+ row.inBytesPerSecond,
                                           outBytesPerSecond: total.outBytesPerSecond &+ row.outBytesPerSecond),
                         bytes: NetworkBytes(received: total.inBytes &+ row.inBytes, sent: total.outBytes &+ row.outBytes))
        }
    }

    /// Each pid's usage from two cumulative `nettop` reads: the rate is its counters' rise from `before` to `after`
    /// over the reads' own stamps (a counter that fell reads 0), its bytes are `after`'s. A pid in `after` only
    /// (sockets opened in the window) rates all of its bytes; a pid in `before` only is dropped, as an exited process
    /// is. A socket opened and closed between the reads leaves no trace: nettop counts open sockets only.
    public static func perProcess(before: NettopRead, after: NettopRead) -> [Int32: NetworkUsage] {
        let nanoseconds = after.uptimeNanoseconds > before.uptimeNanoseconds ? after.uptimeNanoseconds - before.uptimeNanoseconds : 0
        return after.counters.reduce(into: [:]) { out, entry in
            out[entry.key] = NetworkUsage(rate: rate(before: before.counters[entry.key] ?? .zero, after: entry.value,
                                                     nanoseconds: nanoseconds),
                                          bytes: entry.value)
        }
    }
}

/// One `nettop` read: each pid's bytes over its open sockets, stamped in uptime nanoseconds.
public struct NettopRead: Equatable, Sendable {
    public let counters: [Int32: NetworkBytes]
    public let uptimeNanoseconds: UInt64

    public init(counters: [Int32: NetworkBytes], uptimeNanoseconds: UInt64) {
        self.counters = counters
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    /// The first block of `text`; no block is `NetworkActivityError.unreadable`.
    public init(text: String, uptimeNanoseconds: UInt64) throws {
        guard let block = NettopParser.blocks(text).first else { throw NetworkActivityError.unreadable }
        self.init(counters: block, uptimeNanoseconds: uptimeNanoseconds)
    }
}

/// `nettop -P -x -n -J bytes_in,bytes_out` output as pure text rules.
public enum NettopParser {
    /// One map per block, pid → bytes. A block starts at a `,bytes_in,bytes_out,` line; a row is
    /// `<name>.<pid>,<in>,<out>,` read from the right (`columns`), the pid after the name's last dot (names hold dots,
    /// commas and spaces: `com.apple.WebKit.Networking.1234`, `Foo, Inc.ä.1234`; `kernel_task.0` is pid 0). A row
    /// without a trailing pid or with non-numeric counters is skipped, as is anything before the first header; a pid
    /// listed twice in a block sums.
    public static func blocks(_ text: String) -> [[Int32: NetworkBytes]] {
        var out: [[Int32: NetworkBytes]] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix(",bytes_in,bytes_out") {
                out.append([:])
                continue
            }
            guard !out.isEmpty, let (column, values) = columns(line, count: 2), let (_, pid) = namePid(column),
                  let received = UInt64(values[0]), let sent = UInt64(values[1]) else { continue }
            let sum = out[out.count - 1][pid] ?? .zero
            out[out.count - 1][pid] = NetworkBytes(received: sum.received &+ received, sent: sum.sent &+ sent)
        }
        return out
    }

    /// A `-J` line read from the right: its trailing comma dropped, the last `count` fields are the values and
    /// everything before them, commas included, is the name column. Nil when the line has no name column.
    static func columns(_ line: Substring, count: Int) -> (name: String, values: [Substring])? {
        var fields = line.split(separator: ",", omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count > count else { return nil }
        return (fields.dropLast(count).joined(separator: ","), Array(fields.suffix(count)))
    }

    /// `<name>.<pid>` → the name and the pid, the last `.`-separated field; nil without one.
    static func namePid(_ column: String) -> (name: String, pid: Int32)? {
        guard let dot = column.lastIndex(of: "."), let pid = Int32(column[column.index(after: dot)...]) else { return nil }
        return (String(column[..<dot]), pid)
    }
}

/// One open socket as `nettop -x -L 1 -n -J state` lists it under its process: `tcp4 127.0.0.1:8021<->*:*,Listen,`.
/// Hosts and ports stay text: IPv4 joins them with `:`, IPv6 with `.` (`::1.8021`), and a socket not yet bound reads `*`.
public struct Socket: Equatable, Sendable {
    /// `tcp4`, `tcp6`, `udp4`, `udp6`.
    public let proto: String
    public let local: String
    public let remote: String
    /// `Listen`, `Established`, … ; empty for UDP.
    public let state: String

    public init(proto: String, local: String, remote: String, state: String) {
        self.proto = proto
        self.local = local
        self.remote = remote
        self.state = state
    }

    /// `127.0.0.1:8021` → ("127.0.0.1", "8021"), `::1.8021` → ("::1", "8021"), `*:*` → ("*", "*"): split at the last
    /// `:` or `.`.
    public static func endpoint(_ address: String) -> (host: String, port: String) {
        guard let cut = address.lastIndex(where: { $0 == ":" || $0 == "." }) else { return (address, "") }
        return (String(address[..<cut]), String(address[address.index(after: cut)...]))
    }
}

/// Every process's open sockets from one `nettop` read without `-P`, which lists each socket under its process's
/// line (probe 2026-10-21): who listens on a port and who holds a connection to it — the confirmation sheet's
/// "Used by".
public struct SocketListing: Equatable, Sendable {
    /// Each pid's sockets in listed order; a process listed without sockets is absent.
    public let sockets: [Int32: [Socket]]
    /// Each listed pid's `nettop` name (`claude` for `claude.600`), for a pid the rows lack.
    public let names: [Int32: String]

    public init(sockets: [Int32: [Socket]], names: [Int32: String] = [:]) {
        self.sockets = sockets
        self.names = names
    }

    /// A process line `<name>.<pid>,,` opens a block; a socket line `<proto> <local><-><remote>,<state>,` joins it.
    /// Both are read from the right (`NettopParser.columns`), so a name may hold commas, dots and spaces. A socket
    /// line is a proto, one space and an address pair with no space in it. Blank and malformed lines, and sockets
    /// before any process line, are skipped; no process line at all is `NetworkActivityError.unreadable`.
    public init(text: String) throws {
        var sockets: [Int32: [Socket]] = [:], names: [Int32: String] = [:]
        var current: Int32?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (column, values) = NettopParser.columns(line, count: 1), !column.isEmpty else { continue }
            if let space = column.firstIndex(of: " "), let arrow = column.range(of: "<->"), space < arrow.lowerBound,
               !column[column.index(after: space)...].contains(" ") {
                guard let current else { continue }
                sockets[current, default: []].append(Socket(proto: String(column[..<space]),
                                                            local: String(column[column.index(after: space)..<arrow.lowerBound]),
                                                            remote: String(column[arrow.upperBound...]),
                                                            state: String(values[0])))
            } else if let (name, pid) = NettopParser.namePid(column) {
                current = pid
                names[pid] = name
            }
        }
        guard !names.isEmpty else { throw NetworkActivityError.unreadable }
        self.init(sockets: sockets, names: names)
    }
}

/// The CLI's per-process network reads: one single-sample `nettop` run at each end of the window. A `nettop` kept
/// alive between samples (`-L 2`, `-d`, `-L 0`) costs about 1.3 CPU-seconds per second it waits on this Mac — 7% of
/// the machine, whatever it is filtered to; one sample costs about 0.01 s (probes 2026-10-21; why it read 0.01 s for
/// `-L 2` too earlier that day is unverified).
public enum NettopRunner {
    /// Every process's cumulative bytes now; a failed child or no block throws.
    public static func read() throws -> NettopRead {
        let command = try ProcessReaders.Command(path: "/usr/bin/nettop", arguments: [
            "-P", "-x", "-L", "1", "-n", "-J", "bytes_in,bytes_out",
        ]).start()
        let text = try ProcessReaders.run(command)
        return try NettopRead(text: text, uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    /// Every process's open sockets now, one single sample as `read()` takes; a failed child or no process line throws.
    public static func sockets() throws -> SocketListing {
        let command = try ProcessReaders.Command(path: "/usr/bin/nettop", arguments: ["-x", "-L", "1", "-n", "-J", "state"]).start()
        return try SocketListing(text: ProcessReaders.run(command))
    }
}

/// Thin reader over the routing sysctl's interface list; the physical-interface rule is `NetworkActivity.physical`.
public enum MachineNetworkReader {
    /// The physical interfaces' counters now. `listing` is the routing sysctl by default; nil from it, or no physical
    /// interface at all, is `NetworkActivityError.unreadable`.
    public static func read(listing: () -> [(name: String, bytes: NetworkBytes)]? = interfaces) throws -> MachineNetworkSample {
        guard let interfaces = listing(), interfaces.contains(where: { NetworkActivity.isPhysical($0.name) }) else {
            throw NetworkActivityError.unreadable
        }
        return MachineNetworkSample(bytes: NetworkActivity.physical(interfaces), uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                    epochSeconds: Date().timeIntervalSince1970)
    }

    /// Every interface's name and 64-bit byte counters, as `netstat -ib` prints them: the interface MIB
    /// (`net.link.generic.ifdata.<index>.general`, an `ifmibdata` whose `ifmd_data` is an `if_data64`), one sysctl per
    /// interface `if_nameindex` lists. Not `getifaddrs`, whose `if_data` counters are 32-bit and wrap at 4 GB
    /// (`net/if_var.h`); nor the routing sysctl's `NET_RT_IFLIST2`, whose `if_data64` reaches a normal user wrapped
    /// at 4 GB too (probe 2026-10-21, macOS 27: `en0` read 2.94 GB there and 535.5 GB here and in `netstat -ib`).
    /// An interface gone between the listing and its read is skipped; nil when the listing fails.
    public static func interfaces() -> [(name: String, bytes: NetworkBytes)]? {
        guard let list = if_nameindex() else { return nil }
        defer { if_freenameindex(list) }
        var out: [(name: String, bytes: NetworkBytes)] = []
        var entry = list
        while entry.pointee.if_index != 0, let name = entry.pointee.if_name {
            defer { entry += 1 }
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(entry.pointee.if_index), IFDATA_GENERAL]
            var data = ifmibdata()
            var size = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, UInt32(mib.count), &data, &size, nil, 0) == 0 else { continue }
            out.append((String(cString: name), NetworkBytes(received: data.ifmd_data.ifi_ibytes, sent: data.ifmd_data.ifi_obytes)))
        }
        return out
    }
}
