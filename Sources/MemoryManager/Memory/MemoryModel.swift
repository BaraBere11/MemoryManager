import Foundation
import SwiftUI

@MainActor
final class MemoryModel: ObservableObject {
    @Published private(set) var snapshot = MemorySnapshot()
    @Published private(set) var sample = ProcessSample()
    @Published private(set) var history: [Double] = []
    @Published private(set) var isSampling = false
    @Published var searchText = ""
    @Published var interval: TimeInterval = 3 {
        didSet { restart() }
    }

    static let intervals: [TimeInterval] = [1, 2, 3, 5, 10]
    private static let historyLength = 90

    private var task: Task<Void, Never>?

    var filteredRows: [ProcessRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sample.rows }
        return sample.rows.filter {
            $0.name.lowercased().contains(query)
                || ($0.owner?.lowercased().contains(query) ?? false)
                || $0.user.lowercased().contains(query)
                || $0.summary.lowercased().contains(query)
                || String($0.id).contains(query)
        }
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

    /// Sends the signal, then re-samples so the row disappears without waiting for the
    /// next tick. The admin path shows macOS's own password prompt.
    func terminate(_ row: ProcessRow, force: Bool, asAdmin: Bool) async -> KillOutcome {
        let pid = row.id
        let outcome = await Task.detached(priority: .userInitiated) {
            asAdmin
                ? ProcessKiller.terminateAsAdmin(pid: pid, force: force)
                : ProcessKiller.terminate(pid: pid, force: force)
        }.value

        if outcome == .success {
            // SIGTERM is a request; give the process a moment to act on it before
            // re-reading, or it will still be listed.
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refresh()
        }
        return outcome
    }

    private func restart() {
        stop()
        start()
    }

    private func refresh() async {
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }

        let reading = await Task.detached(priority: .utility) {
            (memory: MemorySampler.sample(), processes: ProcessSampler.sample())
        }.value

        snapshot = reading.memory
        sample = reading.processes
        history.append(reading.memory.pressureFraction)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }
}
