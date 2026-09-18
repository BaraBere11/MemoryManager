import Foundation

/// A node in the scanned folder tree. Built on a background thread and treated as
/// immutable once the scan that produced it finishes.
final class ScanNode: Identifiable, Hashable, @unchecked Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var size: UInt64
    var children: [ScanNode]

    init(url: URL, name: String, isDirectory: Bool, size: UInt64, children: [ScanNode] = []) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
    }

    var id: String { url.path }

    /// `OutlineGroup` wants nil, not an empty array, for leaves.
    var outlineChildren: [ScanNode]? { children.isEmpty ? nil : children }

    func child(named name: String) -> ScanNode? {
        children.first { $0.name == name }
    }

    static func == (lhs: ScanNode, rhs: ScanNode) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

struct StorageCategory: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let bytes: UInt64
    let colorIndex: Int
    /// Folder this category maps to, when it maps to exactly one.
    let path: String?
}

struct ScanProgress: Sendable {
    var items: Int = 0
    var bytes: UInt64 = 0
    var currentPath: String = ""
}

struct DiskScanResult: Sendable {
    var roots: [ScanNode] = []
    var categories: [StorageCategory] = []
    var scannedBytes: UInt64 = 0
    var itemCount: Int = 0
    var unreadableFolders: Int = 0
    var duration: TimeInterval = 0
}

enum DiskScanner {
    /// Folders below this size are rolled into their parent instead of being kept as
    /// separate nodes — it keeps the tree small enough to hold in memory and to browse.
    private static let pruneThreshold: UInt64 = 2 * 1024 * 1024
    private static let maxChildrenPerFolder = 400
    private static let maxDepth = 12

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey,
        .volumeIdentifierKey,
        .isPackageKey,
    ]

    /// Scans the home folder and /Applications. Blocking — call it off the main thread.
    /// - Parameters:
    ///   - volumeUsed: bytes in use on the volume, used to derive the "System & Other" remainder.
    ///   - onProgress: called periodically from a background thread.
    ///   - isCancelled: polled between folders.
    static func scanUserStorage(
        volumeUsed: UInt64,
        onProgress: @escaping @Sendable (ScanProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> DiskScanResult {
        let started = Date()
        let counter = ScanCounter(onProgress: onProgress)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let systemApps = URL(fileURLWithPath: "/Applications")

        var roots: [ScanNode] = []
        if let node = scanTree(systemApps, counter: counter, isCancelled: isCancelled) {
            roots.append(node)
        }
        if let node = scanTree(home, counter: counter, isCancelled: isCancelled) {
            roots.append(node)
        }

        var result = DiskScanResult()
        result.roots = roots
        result.scannedBytes = roots.reduce(0) { $0 &+ $1.size }
        result.itemCount = counter.items
        result.unreadableFolders = counter.unreadable
        result.duration = Date().timeIntervalSince(started)
        result.categories = categorize(
            applications: roots.first { $0.url == systemApps },
            home: roots.first { $0.url == home },
            volumeUsed: volumeUsed,
            scanned: result.scannedBytes
        )
        return result
    }

    // MARK: - Tree building

    private static func scanTree(
        _ root: URL,
        counter: ScanCounter,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> ScanNode? {
        guard let volumeID = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        else { return nil }

        let entries = children(of: root, counter: counter)
        guard !entries.isEmpty else {
            return ScanNode(url: root, name: displayName(root), isDirectory: true, size: 0)
        }

        // The top level is where the parallelism pays off: each home folder is an
        // independent subtree, and they differ wildly in size.
        var scanned = [ScanNode?](repeating: nil, count: entries.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: entries.count) { index in
            if isCancelled() { return }
            let node = scanEntry(
                entries[index],
                depth: 1,
                volumeID: volumeID,
                counter: counter,
                isCancelled: isCancelled
            )
            lock.lock()
            scanned[index] = node
            lock.unlock()
        }

        let kids = scanned.compactMap { $0 }
        let node = ScanNode(
            url: root,
            name: displayName(root),
            isDirectory: true,
            size: kids.reduce(0) { $0 &+ $1.size },
            children: prune(kids)
        )
        return node
    }

    /// `URLResourceValues.volumeIdentifier`'s existential type.
    typealias VolumeID = any NSCopying & NSSecureCoding & NSObjectProtocol

    private struct Entry {
        let url: URL
        let isDirectory: Bool
        let isPackage: Bool
        let size: UInt64
        let volumeID: VolumeID?
    }

    private static func children(of url: URL, counter: ScanCounter) -> [Entry] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: []
            )
        } catch {
            counter.noteUnreadable()
            return []
        }

        return contents.compactMap { child in
            guard let values = try? child.resourceValues(forKeys: Set(resourceKeys)) else {
                return nil
            }
            // Symlinks and aliases point at bytes counted elsewhere.
            if values.isSymbolicLink == true { return nil }
            let isDirectory = values.isDirectory ?? false
            let size = UInt64(max(0, values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0))
            return Entry(
                url: child,
                isDirectory: isDirectory,
                isPackage: isDirectory && (values.isPackage ?? false),
                size: size,
                volumeID: values.volumeIdentifier
            )
        }
    }

    private static func scanEntry(
        _ entry: Entry,
        depth: Int,
        volumeID: VolumeID,
        counter: ScanCounter,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> ScanNode? {
        if isCancelled() { return nil }

        guard entry.isDirectory else {
            counter.add(items: 1, bytes: entry.size, path: entry.url.path)
            return ScanNode(
                url: entry.url,
                name: entry.url.lastPathComponent,
                isDirectory: false,
                size: entry.size
            )
        }

        // Don't cross into another mounted volume — those get their own row.
        if let childVolume = entry.volumeID, !childVolume.isEqual(volumeID) { return nil }

        counter.add(items: 1, bytes: 0, path: entry.url.path)

        // An .app or .photoslibrary is one thing to a person, not a folder tree worth
        // opening — measure it whole and show it as a leaf.
        if entry.isPackage {
            return ScanNode(
                url: entry.url,
                name: displayName(entry.url),
                isDirectory: true,
                size: entry.size &+ packageSize(entry.url, volumeID: volumeID, counter: counter, isCancelled: isCancelled)
            )
        }

        var total: UInt64 = entry.size
        var kids: [ScanNode] = []
        for child in children(of: entry.url, counter: counter) {
            guard let node = scanEntry(
                child,
                depth: depth + 1,
                volumeID: volumeID,
                counter: counter,
                isCancelled: isCancelled
            ) else { continue }
            total &+= node.size
            if depth < maxDepth { kids.append(node) }
        }

        return ScanNode(
            url: entry.url,
            name: displayName(entry.url),
            isDirectory: true,
            size: total,
            children: prune(kids)
        )
    }

    /// Total bytes inside a bundle, without building nodes for its innards.
    private static func packageSize(
        _ url: URL,
        volumeID: VolumeID,
        counter: ScanCounter,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> UInt64 {
        if isCancelled() { return 0 }
        var total: UInt64 = 0
        for child in children(of: url, counter: counter) {
            if let childVolume = child.volumeID, !childVolume.isEqual(volumeID) { continue }
            total &+= child.size
            if child.isDirectory {
                total &+= packageSize(child.url, volumeID: volumeID, counter: counter, isCancelled: isCancelled)
                counter.add(items: 1, bytes: 0, path: child.url.path)
            } else {
                counter.add(items: 1, bytes: child.size, path: child.url.path)
            }
        }
        return total
    }

    private static func prune(_ nodes: [ScanNode]) -> [ScanNode] {
        guard !nodes.isEmpty else { return [] }
        let sorted = nodes.sorted { $0.size > $1.size }
        var kept = sorted.prefix(maxChildrenPerFolder).filter { $0.size >= pruneThreshold }
        // Always show something for a folder that has content, even if it's all small.
        if kept.isEmpty, let biggest = sorted.first, biggest.size > 0 {
            kept = [biggest]
        }
        return Array(kept)
    }

    private static func displayName(_ url: URL) -> String {
        if url == FileManager.default.homeDirectoryForCurrentUser { return "Home" }
        let last = url.lastPathComponent
        if last.hasSuffix(".app") { return String(last.dropLast(4)) }
        return last
    }

    // MARK: - Categories

    /// Recomputes the breakdown from an already-scanned tree, for use after something
    /// is deleted and the tree changes without a full rescan.
    static func categories(roots: [ScanNode], volumeUsed: UInt64) -> [StorageCategory] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return categorize(
            applications: roots.first { $0.url.path == "/Applications" },
            home: roots.first { $0.url == home },
            volumeUsed: volumeUsed,
            scanned: roots.reduce(0) { $0 &+ $1.size }
        )
    }

    private static func categorize(
        applications: ScanNode?,
        home: ScanNode?,
        volumeUsed: UInt64,
        scanned: UInt64
    ) -> [StorageCategory] {
        let library = home?.child(named: "Library")
        let mediaFolders = ["Pictures", "Movies", "Music"]
        let namedHomeFolders = Set(["Desktop", "Documents", "Downloads", "Library", "Applications"] + mediaFolders)

        var categories: [StorageCategory] = []
        var index = 0

        func add(_ name: String, _ bytes: UInt64, path: String?) {
            defer { index += 1 }
            guard bytes > 0 else { return }
            categories.append(
                StorageCategory(id: name, name: name, bytes: bytes, colorIndex: index, path: path)
            )
        }

        let userApps = home?.child(named: "Applications")
        add("Applications",
            (applications?.size ?? 0) &+ (userApps?.size ?? 0),
            path: applications?.url.path)
        add("Documents", home?.child(named: "Documents")?.size ?? 0, path: home?.child(named: "Documents")?.url.path)
        add("Desktop", home?.child(named: "Desktop")?.size ?? 0, path: home?.child(named: "Desktop")?.url.path)
        add("Downloads", home?.child(named: "Downloads")?.size ?? 0, path: home?.child(named: "Downloads")?.url.path)
        add("Photos & Media",
            mediaFolders.reduce(0) { $0 &+ (home?.child(named: $1)?.size ?? 0) },
            path: nil)

        let developer = library?.child(named: "Developer")
        let caches = library?.child(named: "Caches")
        add("Developer", developer?.size ?? 0, path: developer?.url.path)
        add("Caches", caches?.size ?? 0, path: caches?.url.path)

        let libraryRest = (library?.size ?? 0)
            &- min(library?.size ?? 0, (developer?.size ?? 0) &+ (caches?.size ?? 0))
        add("App Data", libraryRest, path: library?.url.path)

        let otherInHome = (home?.children ?? [])
            .filter { !namedHomeFolders.contains($0.name) }
            .reduce(0) { $0 &+ $1.size }
        add("Other in Home", otherInHome, path: home?.url.path)

        // Whatever the volume reports as used that we did not walk: /System, /usr,
        // other user accounts, and anything permissions kept us out of.
        let remainder = volumeUsed > scanned ? volumeUsed - scanned : 0
        add("System & Other", remainder, path: nil)

        return categories
    }
}

/// Thread-safe progress accumulator shared by the parallel scan branches.
private final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _items = 0
    private var _bytes: UInt64 = 0
    private var _unreadable = 0
    private var lastReport = Date.distantPast
    private let onProgress: @Sendable (ScanProgress) -> Void

    init(onProgress: @escaping @Sendable (ScanProgress) -> Void) {
        self.onProgress = onProgress
    }

    var items: Int { lock.withLock { _items } }
    var unreadable: Int { lock.withLock { _unreadable } }

    func add(items: Int, bytes: UInt64, path: String) {
        var report: ScanProgress?
        lock.lock()
        _items += items
        _bytes &+= bytes
        // Throttle: the UI cannot use more than a few updates a second anyway.
        if Date().timeIntervalSince(lastReport) > 0.15 {
            lastReport = Date()
            report = ScanProgress(items: _items, bytes: _bytes, currentPath: path)
        }
        lock.unlock()
        if let report { onProgress(report) }
    }

    func noteUnreadable() {
        lock.withLock { _unreadable += 1 }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
