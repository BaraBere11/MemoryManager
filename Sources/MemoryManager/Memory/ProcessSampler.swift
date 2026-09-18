import Darwin
import Foundation

struct ProcessRow: Identifiable, Sendable, Hashable {
    let id: pid_t
    let name: String
    /// Owning application for helper processes ("Visual Studio Code" for "Code Helper").
    let owner: String?
    let user: String
    let memory: UInt64
    /// True when the number is an RSS estimate from `ps` because this process's
    /// footprint is not readable without elevated privileges.
    let isEstimate: Bool
    /// Full path to the executable, shown in the detail pane.
    let path: String
    /// Cumulative CPU time in nanoseconds, or nil when the process is not readable.
    /// Percentages come from the delta between two samples, so a single sample alone
    /// says nothing about current load.
    let cpuTime: UInt64?
    /// `ps` recent-CPU percentage, used when `cpuTime` is unavailable.
    let cpuFallbackPercent: Double?
    /// Filled in by whoever is diffing samples; 100 means one core fully busy.
    var cpuPercent: Double = 0
    let explanation: ProcessExplanation

    var pid: pid_t { id }
    var summary: String { explanation.summary }
}

struct ProcessSample: Sendable {
    var rows: [ProcessRow] = []
    var exactCount: Int = 0
    var estimatedCount: Int = 0
    var totalMemory: UInt64 = 0
}

enum ProcessSampler {
    static func sample() -> ProcessSample {
        let kernelProcs = kernelProcesses()
        // `ps` is setuid-root, so it can report RSS for processes whose task port we
        // cannot open. We use it for names (full paths) and as the memory fallback.
        let psInfo = psSnapshot()

        var sample = ProcessSample()
        sample.rows.reserveCapacity(kernelProcs.count)

        for proc in kernelProcs {
            let path = psInfo[proc.pid]?.path ?? procPath(proc.pid)
            let identity = identityCache.identity(path: path, comm: proc.comm, uid: proc.uid)
            let name = identity.name
            let owner = identity.owner

            let memory: UInt64
            let isEstimate: Bool
            let cpuTime: UInt64?
            if let usage = resourceUsage(proc.pid) {
                memory = usage.footprint
                cpuTime = usage.cpuTime
                isEstimate = false
            } else if let rss = psInfo[proc.pid]?.rss {
                memory = rss
                cpuTime = nil
                isEstimate = true
            } else {
                continue
            }

            if isEstimate { sample.estimatedCount += 1 } else { sample.exactCount += 1 }
            sample.totalMemory &+= memory
            sample.rows.append(
                ProcessRow(
                    id: proc.pid,
                    name: name,
                    owner: owner,
                    user: userName(proc.uid),
                    memory: memory,
                    isEstimate: isEstimate,
                    path: path,
                    cpuTime: cpuTime,
                    cpuFallbackPercent: psInfo[proc.pid]?.cpu,
                    cpuPercent: 0,
                    explanation: identity.explanation
                )
            )
        }

        sample.rows.sort { $0.memory > $1.memory }
        return sample
    }

    // MARK: - Process list

    private struct KernelProc {
        let pid: pid_t
        let uid: uid_t
        let comm: String
    }

    private static func kernelProcesses() -> [KernelProc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // The table can grow between the sizing call and the read, so leave headroom.
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = buffer.count * stride
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [] }

        let count = min(size / stride, buffer.count)
        return (0..<count).compactMap { index in
            let entry = buffer[index]
            let pid = entry.kp_proc.p_pid
            guard pid > 0 else { return nil }
            let comm = withUnsafeBytes(of: entry.kp_proc.p_comm) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            return KernelProc(pid: pid, uid: entry.kp_eproc.e_ucred.cr_uid, comm: comm)
        }
    }

    // MARK: - Per-process memory

    /// One `proc_pid_rusage` call yields both the physical footprint — the number
    /// Activity Monitor shows as Memory — and the cumulative CPU time.
    private static func resourceUsage(_ pid: pid_t) -> (footprint: UInt64, cpuTime: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time
        return (info.ri_phys_footprint, machTicksToNanoseconds(ticks))
    }

    /// `ri_user_time` and `ri_system_time` are mach absolute time units, not
    /// nanoseconds. The two are identical on Intel, where the timebase is 1:1, but on
    /// Apple silicon one tick is 125/3 ns — so skipping this conversion reports CPU
    /// usage roughly 42x too low.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        if info.numer == 0 || info.denom == 0 { return mach_timebase_info_data_t(numer: 1, denom: 1) }
        return info
    }()

    private static func machTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks / UInt64(timebase.denom) &* UInt64(timebase.numer)
            &+ (ticks % UInt64(timebase.denom)) &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    private struct PSEntry {
        let rss: UInt64
        let cpu: Double
        let path: String
    }

    private static func psSnapshot() -> [pid_t: PSEntry] {
        guard let output = runPS() else { return [:] }
        var map: [pid_t: PSEntry] = [:]
        for line in output.split(separator: "\n") {
            // "  1234  56789   3.2 /path/with spaces/binary"
            var rest = line.drop { $0 == " " }

            func nextField() -> Substring? {
                guard let end = rest.firstIndex(of: " ") else { return nil }
                let field = rest[rest.startIndex..<end]
                rest = rest[end...].drop { $0 == " " }
                return field
            }

            guard let pidField = nextField(), let pid = pid_t(pidField),
                  let rssField = nextField(), let rssKB = UInt64(rssField),
                  let cpuField = nextField()
            else { continue }
            map[pid] = PSEntry(
                rss: rssKB * 1024,
                cpu: Double(cpuField) ?? 0,
                path: String(rest)
            )
        }
        return map
    }

    /// Foundation's `Process` costs roughly 110 ms per launch here, most of it
    /// overhead rather than `ps` itself; `posix_spawn` does the same job in about a
    /// third of that, which matters when this runs every couple of seconds.
    private static func runPS() -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        defer { posix_spawn_file_actions_destroy(&actions) }

        let argumentStrings = ["ps", "-axwwo", "pid=,rss=,pcpu=,comm="]
        var arguments: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
        arguments.append(nil)
        defer { for argument in arguments where argument != nil { free(argument) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/ps", &actions, nil, &arguments, environ)
        close(fds[1])
        guard spawned == 0 else {
            close(fds[0])
            return nil
        }

        // Drain the pipe before waiting, or a large listing would deadlock on a full buffer.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let read = Darwin.read(fds[0], &buffer, buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        close(fds[0])

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return String(data: data, encoding: .utf8)
    }

    private static func procPath(_ pid: pid_t) -> String {
        // PROC_PIDPATHINFO_MAXSIZE is a macro, so it doesn't reach Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    // MARK: - Naming

    private static let identityCache = ProcessIdentityCache()
    private static let userNameCache = UserNameCache()

    private static func userName(_ uid: uid_t) -> String {
        userNameCache.name(for: uid)
    }
}

/// Naming and describing a process means splitting its path and walking the catalogue.
/// Both depend only on the executable, not on the moment, so the result is cached per
/// binary — with ~900 processes sharing ~650 distinct executables, and the whole table
/// rebuilt every couple of seconds, that work is otherwise repeated for no reason.
private final class ProcessIdentityCache: @unchecked Sendable {
    struct Identity {
        let name: String
        let owner: String?
        let explanation: ProcessExplanation
    }

    private let lock = NSLock()
    private var entries: [String: Identity] = [:]

    func identity(path: String, comm: String, uid: uid_t) -> Identity {
        // uid participates because it affects how an unrecognised process is classified.
        let key = "\(path)\u{0}\(comm)\u{0}\(uid)"

        lock.lock()
        if let cached = entries[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let (name, owner) = ProcessIdentityCache.prettyName(path: path, fallback: comm)
        let identity = Identity(
            name: name,
            owner: owner,
            explanation: ProcessCatalog.explain(name: name, path: path, owner: owner, uid: uid)
        )

        lock.lock()
        // Bounded so a machine churning through short-lived binaries cannot grow it forever.
        if entries.count > 4096 { entries.removeAll(keepingCapacity: true) }
        entries[key] = identity
        lock.unlock()
        return identity
    }

    /// Turns an executable path into a name a person recognises, plus the app it belongs to.
    private static func prettyName(path: String, fallback: String) -> (name: String, owner: String?) {
        guard !path.isEmpty else { return (fallback, nil) }
        let components = path.split(separator: "/").map(String.init)
        let bundles = components.filter { $0.hasSuffix(".app") }

        guard let innermost = bundles.last else {
            return (components.last ?? fallback, nil)
        }
        let name = String(innermost.dropLast(4))
        guard let outermost = bundles.first, outermost != innermost else {
            return (name, nil)
        }
        return (name, String(outermost.dropLast(4)))
    }
}

/// `getpwuid` is not cheap to hit once per process per refresh, and sampling can move
/// between threads, so the lookup table gets its own lock.
private final class UserNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [uid_t: String] = [:]

    func name(for uid: uid_t) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = names[uid] { return cached }
        var name = String(uid)
        if let entry = getpwuid(uid), let cName = entry.pointee.pw_name {
            name = String(cString: cName)
        }
        names[uid] = name
        return name
    }
}
