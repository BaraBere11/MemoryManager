import Darwin
import Foundation

/// Static facts about the processor, read once.
struct CPUHardware: Sendable, Equatable {
    var brand: String = "Unknown processor"
    var logicalCores: Int = 1
    var physicalCores: Int = 1
    /// Apple silicon splits cores into performance and efficiency tiers; both are 0
    /// on Intel, where every core is equivalent.
    var performanceCores: Int = 0
    var efficiencyCores: Int = 0

    var isHybrid: Bool { performanceCores > 0 && efficiencyCores > 0 }

    /// The tier a logical core index belongs to. Apple silicon reports performance
    /// cores first, then efficiency cores.
    func tier(forCore index: Int) -> String? {
        guard isHybrid else { return nil }
        return index < performanceCores ? "P" : "E"
    }
}

/// CPU usage over one interval. All fractions are 0...1 of total capacity.
struct CPUSnapshot: Sendable, Equatable {
    var user: Double = 0
    var system: Double = 0
    var idle: Double = 1
    var nice: Double = 0
    /// Busy fraction per logical core, in core order.
    var cores: [Double] = []
    var loadAverage: [Double] = [0, 0, 0]

    var busy: Double { min(1, max(0, user + system + nice)) }
}

/// Holds the previous tick counts, since CPU usage only exists as a delta between
/// two readings — a single sample tells you nothing about current load.
final class CPUSampler {
    private var previousTotal: [UInt32]?
    private var previousCores: [[UInt32]]?

    let hardware: CPUHardware

    init() {
        hardware = CPUSampler.readHardware()
    }

    /// Returns nil on the very first call, when there is no previous reading to
    /// compare against.
    func sample() -> CPUSnapshot? {
        var snapshot = CPUSnapshot()
        snapshot.loadAverage = CPUSampler.loadAverage()

        let totalDelta = hostTicksDelta()
        let coreDeltas = coreTicksDelta()
        guard let totalDelta else { return nil }

        snapshot.user = totalDelta.user
        snapshot.system = totalDelta.system
        snapshot.idle = totalDelta.idle
        snapshot.nice = totalDelta.nice
        snapshot.cores = coreDeltas ?? []
        return snapshot
    }

    // MARK: - Host-wide ticks

    private func hostTicksDelta() -> (user: Double, system: Double, idle: Double, nice: Double)? {
        guard let ticks = CPUSampler.hostTicks() else { return nil }
        defer { previousTotal = ticks }
        guard let previous = previousTotal else { return nil }
        return CPUSampler.fractions(from: previous, to: ticks)
    }

    private static func hostTicks() -> [UInt32]? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return [
            info.cpu_ticks.0,  // CPU_STATE_USER
            info.cpu_ticks.1,  // CPU_STATE_SYSTEM
            info.cpu_ticks.2,  // CPU_STATE_IDLE
            info.cpu_ticks.3,  // CPU_STATE_NICE
        ]
    }

    /// Tick counters are monotonic 32-bit counters, so subtraction uses wrapping
    /// arithmetic to stay correct across a wrap.
    private static func fractions(
        from previous: [UInt32],
        to current: [UInt32]
    ) -> (user: Double, system: Double, idle: Double, nice: Double)? {
        var deltas = [Double](repeating: 0, count: 4)
        var total: Double = 0
        for index in 0..<4 {
            let delta = Double(current[index] &- previous[index])
            deltas[index] = delta
            total += delta
        }
        guard total > 0 else { return nil }
        return (deltas[0] / total, deltas[1] / total, deltas[2] / total, deltas[3] / total)
    }

    // MARK: - Per-core ticks

    private func coreTicksDelta() -> [Double]? {
        guard let ticks = CPUSampler.coreTicks() else { return nil }
        defer { previousCores = ticks }
        guard let previous = previousCores, previous.count == ticks.count else { return nil }

        return zip(previous, ticks).map { before, after in
            guard let f = CPUSampler.fractions(from: before, to: after) else { return 0 }
            return min(1, max(0, f.user + f.system + f.nice))
        }
    }

    private static func coreTicks() -> [[UInt32]]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return nil }
        // host_processor_info allocates; we own the deallocation.
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        let states = Int(CPU_STATE_MAX)
        var cores: [[UInt32]] = []
        cores.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * states
            guard base + 3 < Int(infoCount) else { break }
            cores.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ])
        }
        return cores
    }

    // MARK: - Load average and hardware

    private static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return [0, 0, 0] }
        return loads
    }

    private static func readHardware() -> CPUHardware {
        var hardware = CPUHardware()
        hardware.brand = sysctlString("machdep.cpu.brand_string") ?? hardware.brand
        hardware.logicalCores = sysctlInt("hw.logicalcpu") ?? 1
        hardware.physicalCores = sysctlInt("hw.physicalcpu") ?? hardware.logicalCores
        // perflevel0 is the performance tier, perflevel1 the efficiency tier.
        hardware.performanceCores = sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        hardware.efficiencyCores = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        return hardware
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
