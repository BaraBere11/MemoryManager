import Foundation

struct VolumeInfo: Identifiable, Sendable, Hashable {
    let id: String
    let url: URL
    let name: String
    let total: UInt64
    /// Space the system will actually let you use, counting purgeable caches it can evict.
    let available: UInt64
    let isBoot: Bool

    var used: UInt64 { total > available ? total - available : 0 }
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

enum VolumeSampler {
    private static let keys: Set<URLResourceKey> = [
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsBrowsableKey,
        .volumeIsInternalKey,
    ]

    static func mountedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        let bootURL = URL(fileURLWithPath: "/")
        var results: [VolumeInfo] = []
        var seen: Set<String> = []

        for url in urls {
            guard let info = describe(url, bootURL: bootURL) else { continue }
            guard seen.insert(info.id).inserted else { continue }
            results.append(info)
        }

        // Boot volume first, then biggest.
        results.sort {
            if $0.isBoot != $1.isBoot { return $0.isBoot }
            return $0.total > $1.total
        }
        return results
    }

    static func describe(_ url: URL, bootURL: URL = URL(fileURLWithPath: "/")) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }

        if values.volumeIsBrowsable == false { return nil }

        // `forImportantUsage` reflects what you can really write; fall back if unavailable.
        let available = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
            ?? UInt64(max(0, values.volumeAvailableCapacity ?? 0))

        let bootID = (try? bootURL.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        let thisID = (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        let isBoot: Bool = {
            guard let bootID, let thisID else { return url.path == "/" }
            return bootID.isEqual(thisID)
        }()

        return VolumeInfo(
            id: url.path,
            url: url,
            name: values.volumeName ?? url.lastPathComponent,
            total: UInt64(total),
            available: available,
            isBoot: isBoot
        )
    }
}
