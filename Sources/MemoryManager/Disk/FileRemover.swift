import Foundation

enum RemoveOutcome: Sendable, Equatable {
    /// Moved to the Trash; the URL is where it landed, when the system reported one.
    case trashed(String?)
    case deleted
    case notPermitted
    case missing
    case failed(String)
}

enum RemoveRisk: Sendable, Equatable {
    /// Never offered.
    case blocked
    /// Loses app settings, licences or saved state.
    case severe
    /// Safe enough, but worth knowing what happens.
    case caution
    case normal
}

struct RemoveAdvice: Sendable, Equatable {
    let risk: RemoveRisk
    let note: String?

    var allowsRemoval: Bool { risk != .blocked }
}

enum FileRemover {
    // MARK: - What must never be deleted

    /// System roots. Removing any of these breaks the installation.
    private static let systemRoots: Set<String> = [
        "/", "/System", "/Library", "/Users", "/Applications", "/private",
        "/usr", "/bin", "/sbin", "/etc", "/var", "/tmp", "/opt", "/cores", "/Volumes",
    ]

    /// The standard folders in a home directory. Their *contents* can go; the folders
    /// themselves are part of the account's structure.
    private static let standardHomeFolders: Set<String> = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music",
        "Pictures", "Public", "Applications", "Sites", ".Trash",
    ]

    static func advice(for url: URL) -> RemoveAdvice {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

        if systemRoots.contains(path) {
            return RemoveAdvice(
                risk: .blocked,
                note: "\(path) is part of the system and cannot be removed from this app."
            )
        }
        if path == home {
            return RemoveAdvice(
                risk: .blocked,
                note: "This is your home folder. Removing it would delete your whole account's data."
            )
        }
        // A direct child of home that is one of the standard folders.
        if url.deletingLastPathComponent().standardizedFileURL.path == home,
           standardHomeFolders.contains(url.lastPathComponent) {
            return RemoveAdvice(
                risk: .blocked,
                note: "\(url.lastPathComponent) is one of your account's standard folders. "
                    + "You can remove things inside it, but not the folder itself."
            )
        }

        if path.hasPrefix(home + "/Library/Caches/") {
            return RemoveAdvice(
                risk: .caution,
                note: "Caches are rebuilt automatically. The app that owns this may be slower "
                    + "the next time it starts."
            )
        }
        if path.hasPrefix(home + "/Library/") {
            return RemoveAdvice(
                risk: .severe,
                note: "This is application data. Removing it can lose settings, licences or "
                    + "saved state for the app that owns it."
            )
        }
        if url.pathExtension == "app" {
            return RemoveAdvice(
                risk: .caution,
                note: "This removes the application. You would need to reinstall it to use it again."
            )
        }
        return RemoveAdvice(risk: .normal, note: nil)
    }

    // MARK: - Removing

    /// Reversible: the item goes to the Trash and the space is not reclaimed until the
    /// Trash is emptied.
    static func moveToTrash(_ url: URL) -> RemoveOutcome {
        guard advice(for: url).allowsRemoval else { return .notPermitted }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }

        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return .trashed((resulting as URL?)?.path)
        } catch {
            return classify(error)
        }
    }

    /// Irreversible, and frees the space straight away.
    static func deleteImmediately(_ url: URL) -> RemoveOutcome {
        guard advice(for: url).allowsRemoval else { return .notPermitted }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }

        do {
            try FileManager.default.removeItem(at: url)
            return .deleted
        } catch {
            return classify(error)
        }
    }

    private static func classify(_ error: Error) -> RemoveOutcome {
        let nsError = error as NSError
        switch nsError.code {
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return .notPermitted
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .missing
        default:
            return .failed(nsError.localizedDescription)
        }
    }
}
