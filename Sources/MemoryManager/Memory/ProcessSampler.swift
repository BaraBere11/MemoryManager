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
            let (name, owner) = prettyName(path: path, fallback: proc.comm)

            let memory: UInt64
            let isEstimate: Bool
            if let exact = footprint(proc.pid) {
                memory = exact
                isEstimate = false
            } else if let rss = psInfo[proc.pid]?.rss {
                memory = rss
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
                    explanation: ProcessCatalog.explain(
                        name: name,
                        path: path,
                        owner: owner,
                        uid: proc.uid
                    )
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

    /// Physical footprint — the same number Activity Monitor puts in its Memory column.
    private static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    private struct PSEntry {
        let rss: UInt64
        let path: String
    }

    private static func psSnapshot() -> [pid_t: PSEntry] {
        guard let output = runPS() else { return [:] }
        var map: [pid_t: PSEntry] = [:]
        for line in output.split(separator: "\n") {
            // "  1234  56789 /path/with spaces/binary"
            let trimmed = line.drop { $0 == " " }
            guard let pidEnd = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[trimmed.startIndex..<pidEnd])
            else { continue }
            let afterPid = trimmed[pidEnd...].drop { $0 == " " }
            guard let rssEnd = afterPid.firstIndex(of: " "),
                  let rssKB = UInt64(afterPid[afterPid.startIndex..<rssEnd])
            else { continue }
            let path = String(afterPid[rssEnd...].drop { $0 == " " })
            map[pid] = PSEntry(rss: rssKB * 1024, path: path)
        }
        return map
    }

    private static func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axwwo", "pid=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func procPath(_ pid: pid_t) -> String {
        // PROC_PIDPATHINFO_MAXSIZE is a macro, so it doesn't reach Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    // MARK: - Naming

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

    private static let userNameCache = UserNameCache()

    private static func userName(_ uid: uid_t) -> String {
        userNameCache.name(for: uid)
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
