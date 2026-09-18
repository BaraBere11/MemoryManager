import Foundation
import SwiftUI

@MainActor
final class DiskModel: ObservableObject {
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published var selectedVolumeID: String?
    @Published private(set) var result: DiskScanResult?
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var isScanning = false
    @Published private(set) var scanError: String?

    private var scanTask: Task<Void, Never>?
    private let cancelFlag = CancelFlag()

    var selectedVolume: VolumeInfo? {
        volumes.first { $0.id == selectedVolumeID } ?? volumes.first
    }

    /// The scan only covers the home folder and /Applications, which live on the boot
    /// volume; the breakdown is meaningless for anything else.
    var canScanSelectedVolume: Bool {
        selectedVolume?.isBoot ?? false
    }

    func loadVolumes() {
        volumes = VolumeSampler.mountedVolumes()
        if selectedVolumeID == nil || !volumes.contains(where: { $0.id == selectedVolumeID }) {
            selectedVolumeID = volumes.first?.id
        }
    }

    func refreshCapacity() {
        let previous = selectedVolumeID
        volumes = VolumeSampler.mountedVolumes()
        if volumes.contains(where: { $0.id == previous }) {
            selectedVolumeID = previous
        }
    }

    func startScan() {
        guard let volume = selectedVolume, !isScanning else { return }
        cancelFlag.reset()
        scanError = nil
        progress = ScanProgress()
        isScanning = true

        let used = volume.used
        let flag = cancelFlag
        let sink: @Sendable (ScanProgress) -> Void = { [weak self] update in
            Task { @MainActor in
                guard let self, self.isScanning else { return }
                self.progress = update
            }
        }

        scanTask = Task { [weak self] in
            let scan = await Self.runScan(volumeUsed: used, onProgress: sink, flag: flag)
            guard let self, !flag.isCancelled else { return }
            self.result = scan
            self.isScanning = false
            self.progress = nil
            if scan.unreadableFolders > 0 && scan.scannedBytes == 0 {
                self.scanError = "Could not read any folders. Grant Full Disk Access in "
                    + "System Settings › Privacy & Security to see the full breakdown."
            }
        }
    }

    /// The scan blocks its thread for a long time and fans out with `concurrentPerform`,
    /// so it runs on a Dispatch queue rather than starving the cooperative pool.
    private static func runScan(
        volumeUsed: UInt64,
        onProgress: @escaping @Sendable (ScanProgress) -> Void,
        flag: CancelFlag
    ) async -> DiskScanResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = DiskScanner.scanUserStorage(
                    volumeUsed: volumeUsed,
                    onProgress: onProgress,
                    isCancelled: { flag.isCancelled }
                )
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Removing items

    /// Bumped after the tree is mutated so the browser rebuilds; `ScanNode` is a plain
    /// class, so SwiftUI cannot see the change on its own.
    @Published private(set) var treeVersion = 0

    func remove(_ node: ScanNode, permanently: Bool) async -> RemoveOutcome {
        let url = node.url
        let outcome = await Task.detached(priority: .userInitiated) {
            permanently ? FileRemover.deleteImmediately(url) : FileRemover.moveToTrash(url)
        }.value

        switch outcome {
        case .trashed, .deleted, .missing:
            prune(node)
        default:
            break
        }
        return outcome
    }

    /// Drops the node from the tree and subtracts its size from every ancestor, so the
    /// browser and the breakdown stay consistent without rescanning.
    private func prune(_ node: ScanNode) {
        guard var scan = result else { return }
        let removed = node.size

        /// Subtracts from each level exactly once on the way back up the recursion.
        func detach(from parent: ScanNode) -> Bool {
            if let index = parent.children.firstIndex(where: { $0 === node }) {
                parent.children.remove(at: index)
                parent.size = parent.size > removed ? parent.size - removed : 0
                return true
            }
            for child in parent.children where detach(from: child) {
                parent.size = parent.size > removed ? parent.size - removed : 0
                return true
            }
            return false
        }

        var changed = false
        if let index = scan.roots.firstIndex(where: { $0 === node }) {
            scan.roots.remove(at: index)
            changed = true
        } else {
            for root in scan.roots where detach(from: root) {
                changed = true
                break
            }
        }
        guard changed else { return }

        scan.scannedBytes = scan.roots.reduce(0) { $0 &+ $1.size }
        // Trashed items still occupy the volume, so the used figure is re-read rather
        // than assumed; the breakdown is rebuilt from whatever it now reports.
        refreshCapacity()
        scan.categories = DiskScanner.categories(
            roots: scan.roots,
            volumeUsed: selectedVolume?.used ?? 0
        )
        result = scan
        treeVersion += 1
    }

    func cancelScan() {
        cancelFlag.cancel()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        progress = nil
    }
}

/// Polled from the scan's worker threads, set from the main actor.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        flag = false
        lock.unlock()
    }
}
