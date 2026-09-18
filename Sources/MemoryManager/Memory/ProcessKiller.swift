import Darwin
import Foundation

enum KillOutcome: Sendable, Equatable {
    case success
    /// The process belongs to another user; the same signal may work as an admin.
    case needsPrivileges
    /// Refused even with privileges, which normally means macOS protects it (SIP).
    case notPermitted
    case noSuchProcess
    case cancelled
    case failed(String)
}

enum KillRisk: Sendable, Equatable {
    /// Never offered — killing it takes the machine down.
    case blocked
    /// Ends your login session or loses unsaved work.
    case severe
    /// A system process; usually restarts, but can disrupt things.
    case caution
    /// An ordinary app or helper.
    case normal
}

struct KillAdvice: Sendable, Equatable {
    let risk: KillRisk
    let note: String?

    var allowsTermination: Bool { risk != .blocked }
}

enum ProcessKiller {
    // MARK: - Risk assessment

    /// Processes whose loss ends the login session or destroys unsaved work.
    private static let severe: [String: String] = [
        "WindowServer": "This draws everything on screen. Killing it logs you out immediately and you lose unsaved work in every open app.",
        "loginwindow": "This owns your login session. Killing it logs you out immediately and you lose unsaved work in every open app.",
        "SystemUIServer": "Killing this can leave the menu bar unusable until you log out.",
        "opendirectoryd": "This resolves user accounts. Killing it can make the system unable to authenticate you.",
        "configd": "This manages networking. Killing it drops your network configuration.",
        "securityd": "This handles the keychain. Killing it can lock apps out of your saved passwords.",
        "syspolicyd": "This is Gatekeeper. Killing it can stop apps from launching.",
        "tccd": "This enforces privacy permissions. Killing it can break permission prompts until you restart.",
        "coreaudiod": "All audio stops until it restarts, and playing apps may need restarting too.",
        "runningboardd": "This supervises process lifecycles. Killing it can destabilise running apps.",
        "amfid": "This verifies code signatures. Killing it can stop new apps from launching.",
    ]

    /// Processes macOS brings straight back, which is worth saying so the user is not alarmed.
    private static let relaunches: Set<String> = [
        "Dock", "Finder", "ControlCenter", "NotificationCenter", "Spotlight",
        "TextInputMenuAgent", "talagent", "UserEventAgent",
    ]

    static func advice(for row: ProcessRow) -> KillAdvice {
        if row.id <= 1 {
            return KillAdvice(
                risk: .blocked,
                note: "This is launchd, the process that starts and supervises everything else. "
                    + "Killing it panics the machine, so this app will not do it."
            )
        }
        if row.name == "kernel_task" {
            return KillAdvice(
                risk: .blocked,
                note: "This is the kernel itself. It cannot be killed."
            )
        }
        if let note = severe[row.name] {
            return KillAdvice(risk: .severe, note: note)
        }
        if relaunches.contains(row.name) {
            return KillAdvice(
                risk: .caution,
                note: "macOS restarts this automatically, usually within a second."
            )
        }
        if row.explanation.kind == .system || row.user == "root" {
            return KillAdvice(
                risk: .caution,
                note: "This is a macOS system process. It will usually be restarted automatically, "
                    + "but killing it can disrupt the system."
            )
        }
        return KillAdvice(
            risk: .normal,
            note: nil
        )
    }

    // MARK: - Terminating

    /// Sends the signal directly. Only works for processes this user owns.
    static func terminate(pid: pid_t, force: Bool) -> KillOutcome {
        guard pid > 1 else { return .notPermitted }
        let signalNumber = force ? SIGKILL : SIGTERM
        if kill(pid, signalNumber) == 0 { return .success }
        switch errno {
        case EPERM: return .needsPrivileges
        case ESRCH: return .noSuchProcess
        default: return .failed(String(cString: strerror(errno)))
        }
    }

    /// Re-sends the signal through an authenticated admin prompt. macOS shows its own
    /// password dialog; we never see or handle the password.
    static func terminateAsAdmin(pid: pid_t, force: Bool) -> KillOutcome {
        guard pid > 1 else { return .notPermitted }
        let signalName = force ? "KILL" : "TERM"
        // pid is an integer we produced, so there is nothing to escape into the script.
        let script = "do shell script \"/bin/kill -\(signalName) \(pid)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 0 { return .success }

        let message = String(data: errorData, encoding: .utf8) ?? ""
        // -128 is the documented code for the user dismissing the authentication dialog.
        if message.contains("-128") || message.lowercased().contains("user canceled") {
            return .cancelled
        }
        if message.contains("Operation not permitted") {
            return .notPermitted
        }
        if message.contains("No such process") {
            return .noSuchProcess
        }
        return .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isRunning(pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
