import SwiftUI

struct PendingKill: Identifiable {
    let row: ProcessRow
    let force: Bool
    let advice: KillAdvice
    /// Second stage: the direct signal was refused, so retry through authentication.
    let asAdmin: Bool

    var id: String { "\(row.id)-\(force)-\(asAdmin)" }
}

struct KillNotice: Identifiable {
    let text: String
    var id: String { text }
}

/// Owns the confirm-then-terminate flow so the Memory and CPU tabs behave identically
/// without either one reimplementing the warnings.
@MainActor
final class TerminationCoordinator: ObservableObject {
    @Published var pending: PendingKill?
    @Published var notice: KillNotice?

    /// Called after a process actually goes away, so the owning tab can re-sample.
    var onCompleted: (() -> Void)?

    func request(_ row: ProcessRow, force: Bool) {
        let advice = ProcessKiller.advice(for: row)
        guard advice.allowsTermination else {
            notice = KillNotice(text: advice.note ?? "This process cannot be terminated.")
            return
        }
        pending = PendingKill(row: row, force: force, advice: advice, asAdmin: false)
    }

    func perform(_ kill: PendingKill) {
        Task {
            let pid = kill.row.id
            let force = kill.force
            let asAdmin = kill.asAdmin
            let outcome = await Task.detached(priority: .userInitiated) {
                asAdmin
                    ? ProcessKiller.terminateAsAdmin(pid: pid, force: force)
                    : ProcessKiller.terminate(pid: pid, force: force)
            }.value

            switch outcome {
            case .success:
                // SIGTERM is a request; give it a moment to be acted on before re-reading.
                try? await Task.sleep(nanoseconds: 400_000_000)
                onCompleted?()
            case .needsPrivileges:
                // Let the first alert finish dismissing before raising the second.
                try? await Task.sleep(nanoseconds: 250_000_000)
                pending = PendingKill(
                    row: kill.row, force: kill.force, advice: kill.advice, asAdmin: true
                )
            case .notPermitted:
                notice = KillNotice(
                    text: "macOS would not quit \(kill.row.name). It is protected by the system "
                        + "and cannot be terminated, even by an administrator."
                )
            case .noSuchProcess:
                notice = KillNotice(text: "\(kill.row.name) had already exited.")
                onCompleted?()
            case .cancelled:
                break
            case .failed(let reason):
                notice = KillNotice(text: "Could not quit \(kill.row.name).\n\n\(reason)")
            }
        }
    }

    func title(for kill: PendingKill) -> String {
        if kill.asAdmin { return "Authenticate to quit \(kill.row.name)?" }
        return kill.force ? "Force quit \(kill.row.name)?" : "Quit \(kill.row.name)?"
    }

    func message(for kill: PendingKill) -> String {
        var parts: [String] = []
        if kill.asAdmin {
            parts.append(
                "\(kill.row.name) belongs to \(kill.row.user), so quitting it needs an "
                + "administrator. macOS will ask for your password."
            )
        } else if kill.force {
            parts.append(
                "Force quitting ends the process immediately. It will not get a chance to "
                + "save open work."
            )
        } else {
            parts.append("This asks the process to quit, giving it a chance to save open work.")
        }
        if let note = kill.advice.note { parts.append(note) }
        return parts.joined(separator: "\n\n")
    }
}

extension View {
    /// Attaches the confirmation and result alerts for process termination.
    func processTermination(_ coordinator: TerminationCoordinator) -> some View {
        self
            .alert(
                coordinator.pending.map(coordinator.title) ?? "",
                isPresented: Binding(
                    get: { coordinator.pending != nil },
                    set: { if !$0 { coordinator.pending = nil } }
                ),
                presenting: coordinator.pending
            ) { kill in
                Button(kill.force ? "Force Quit" : "Quit", role: .destructive) {
                    coordinator.perform(kill)
                }
                Button("Cancel", role: .cancel) {}
            } message: { kill in
                Text(coordinator.message(for: kill))
            }
            .alert(
                "",
                isPresented: Binding(
                    get: { coordinator.notice != nil },
                    set: { if !$0 { coordinator.notice = nil } }
                ),
                presenting: coordinator.notice
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { notice in
                Text(notice.text)
            }
    }
}
