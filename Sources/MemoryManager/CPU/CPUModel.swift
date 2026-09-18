import Foundation
import SwiftUI

@MainActor
final class CPUModel: ObservableObject {
    @Published private(set) var snapshot = CPUSnapshot()
    @Published private(set) var rows: [ProcessRow] = []
    @Published private(set) var history: [Double] = []
    @Published private(set) var isSampling = false
    @Published private(set) var hasBaseline = false
    @Published var searchText = ""
    @Published var interval: TimeInterval = 2 {
        didSet { restart() }
    }

    static let intervals: [TimeInterval] = [1, 2, 3, 5]
    private static let historyLength = 90

    let hardware: CPUHardware

    private let sampler = CPUSampler()
    private var task: Task<Void, Never>?
    /// Cumulative CPU nanoseconds per process at the previous sample.
    private var previousCPU: [pid_t: UInt64] = [:]
    private var previousSampleTime: Date?

    init() {
        hardware = sampler.hardware
    }

    var filteredRows: [ProcessRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.name.lowercased().contains(query)
                || ($0.owner?.lowercased().contains(query) ?? false)
                || $0.user.lowercased().contains(query)
                || $0.summary.lowercased().contains(query)
                || String($0.id).contains(query)
        }
    }

    /// Total CPU currently attributed to processes, as a share of all cores.
    var totalProcessPercent: Double {
        rows.reduce(0) { $0 + $1.cpuPercent }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let seconds = await MainActor.run { self.interval }
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func refreshNow() {
        Task { await refresh() }
    }

    private func restart() {
        stop()
        start()
    }

    private func refresh() async {
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }

        let sampler = self.sampler
        let reading = await Task.detached(priority: .utility) {
            (cpu: sampler.sample(), processes: ProcessSampler.sample(), at: Date())
        }.value

        if let cpu = reading.cpu {
            snapshot = cpu
            hasBaseline = true
            history.append(cpu.busy)
            if history.count > Self.historyLength {
                history.removeFirst(history.count - Self.historyLength)
            }
        }

        rows = attributeCPU(to: reading.processes.rows, at: reading.at)
    }

    /// Turns cumulative CPU time into a percentage of one core, the way Activity
    /// Monitor does: 100% means one core fully busy, so a threaded process can exceed
    /// 100% up to `logicalCores * 100`.
    private func attributeCPU(to rows: [ProcessRow], at now: Date) -> [ProcessRow] {
        let elapsed = previousSampleTime.map { now.timeIntervalSince($0) } ?? 0
        let elapsedNanos = elapsed * 1_000_000_000

        var current: [pid_t: UInt64] = [:]
        current.reserveCapacity(rows.count)

        var result = rows
        for index in result.indices {
            let row = result[index]
            guard let cpuTime = row.cpuTime else {
                // Not readable — ps reports its own recent-CPU figure instead.
                result[index].cpuPercent = row.cpuFallbackPercent ?? 0
                continue
            }
            current[row.id] = cpuTime

            guard elapsedNanos > 0, let previous = previousCPU[row.id], cpuTime >= previous else {
                // First sighting of this process: no interval to measure over yet.
                result[index].cpuPercent = 0
                continue
            }
            result[index].cpuPercent = Double(cpuTime - previous) / elapsedNanos * 100
        }

        previousCPU = current
        previousSampleTime = now
        return result.sorted { $0.cpuPercent > $1.cpuPercent }
    }
}
