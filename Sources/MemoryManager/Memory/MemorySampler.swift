import Darwin
import Foundation

enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

/// One reading of system-wide RAM usage, sliced the way Activity Monitor slices it.
struct MemorySnapshot: Sendable, Equatable {
    var total: UInt64 = 0
    var appMemory: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cachedFiles: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: MemoryPressure = .normal

    /// "Memory Used" in Activity Monitor: everything that is not free and not reclaimable cache.
    var used: UInt64 { appMemory &+ wired &+ compressed }

    var free: UInt64 {
        let accounted = used &+ cachedFiles
        return total > accounted ? total - accounted : 0
    }

    var usedFraction: Double {
        total == 0 ? 0 : Double(used) / Double(total)
    }

    /// Activity Monitor's pressure graph tracks the non-reclaimable share of RAM.
    var pressureFraction: Double {
        total == 0 ? 0 : Double(wired &+ compressed) / Double(total)
    }
}

enum MemorySampler {
    static func sample() -> MemorySnapshot {
        var snapshot = MemorySnapshot()
        snapshot.total = physicalMemory()
        snapshot.pressure = pressureLevel()

        let (swapUsed, swapTotal) = swapUsage()
        snapshot.swapUsed = swapUsed
        snapshot.swapTotal = swapTotal

        guard let stats = vmStatistics() else { return snapshot }
        let page = pageSize()

        let purgeable = UInt64(stats.purgeable_count) &* page
        let external = UInt64(stats.external_page_count) &* page
        let anonymous = UInt64(stats.internal_page_count) &* page

        snapshot.wired = UInt64(stats.wire_count) &* page
        snapshot.compressed = UInt64(stats.compressor_page_count) &* page
        snapshot.cachedFiles = external &+ purgeable
        // App Memory is anonymous memory minus the part the kernel may drop on demand.
        snapshot.appMemory = anonymous > purgeable ? anonymous - purgeable : anonymous

        return snapshot
    }

    // MARK: - Primitives

    private static func physicalMemory() -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0 { return value }
        return ProcessInfo.processInfo.physicalMemory
    }

    private static func pageSize() -> UInt64 {
        var size: vm_size_t = 0
        if host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 {
            return UInt64(size)
        }
        return UInt64(vm_page_size)
    }

    private static func vmStatistics() -> vm_statistics64_data_t? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    private static func pressureLevel() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
              let pressure = MemoryPressure(rawValue: Int(level))
        else { return .normal }
        return pressure
    }

    private static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }
}
