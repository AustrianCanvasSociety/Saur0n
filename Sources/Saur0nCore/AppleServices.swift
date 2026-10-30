// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What counts as an Apple service (research 2026-10-26 § 4): a process the watcher warns about and never pauses on its
/// own, because pausing a launchd service can freeze a browser tab, a build's compiler service or Spotlight with no
/// obvious owner to resume it. All four checks hold, each read from the live process every tick — an Apple signature
/// alone is not enough, since `sleep`, `bash`, `perl` and `python3` are Apple's too and a runaway is made of them:
///
/// 1. the kernel's platform-binary bit is set (`ProcessReaders.platformBinary`, from `csops`);
/// 2. its path is under a service folder (`servicePrefixes`), not `/bin` or `/usr/bin`;
/// 3. its parent is launchd and it leads its own process group — a script started from a terminal or `nohup … &` keeps
///    its launcher's group;
/// 4. its command key is its own executable's name, and it is not a shell or interpreter (which a launchd job running
///    `/bin/bash job.sh` would be).
public enum AppleServices {
    /// Where launchd's own jobs live: frameworks and private frameworks, the WebKit cryptex, `/usr/libexec`, `/usr/sbin`.
    static let servicePrefixes = ["/System/Library/", "/System/Volumes/Preboot/Cryptexes/", "/usr/libexec/", "/usr/sbin/"]

    /// Check 2: `path` is under a service folder. A process whose path is unread (the `/bin/ps` fallback's rows) is not.
    static func isServicePath(_ path: String?) -> Bool {
        guard let path else { return false }
        return servicePrefixes.contains { path.hasPrefix($0) && path.count > $0.count }
    }

    /// Whether `row` is an Apple service. The platform bit rides on the row as the process table read it.
    static func isService(_ row: ProcessUsage) -> Bool {
        guard row.platformBinary, isServicePath(row.path), row.ppid == 1, row.processGroup == row.pid else { return false }
        return CommandGroups.interpreter(row.name) == nil && (row.command ?? row.name) == row.name
    }
}

extension ProcessUsage {
    /// Whether it is an Apple service (`AppleServices`): warned about, and withheld from automatic Pause while
    /// `acting.exempt.apple` is on. Not in JSON.
    public var isAppleService: Bool { AppleServices.isService(self) }
}
