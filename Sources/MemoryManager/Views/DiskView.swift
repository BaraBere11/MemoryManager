import AppKit
import SwiftUI

struct DiskView: View {
    @EnvironmentObject private var model: DiskModel
    @State private var highlighted: String?
    @State private var expanded: Set<String> = []
    @State private var selection: String?
    @State private var pending: PendingRemoval?
    @State private var notice: RemovalNotice?

    private var segments: [BarSegment] {
        guard let volume = model.selectedVolume else { return [] }
        guard let categories = model.result?.categories, !categories.isEmpty else {
            return [
                BarSegment("Used", volume.used, Palette.app),
                BarSegment("Available", volume.available, Palette.free, isRemainder: true),
            ]
        }
        var result = categories.map {
            BarSegment($0.name, $0.bytes, Palette.category($0.colorIndex))
        }
        result.append(BarSegment("Available", volume.available, Palette.free, isRemainder: true))
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            SegmentedBar(segments: segments, highlighted: highlighted)
            LegendGrid(segments: segments, columns: 5, highlighted: $highlighted)
            scanBar
            Divider()
            actionBar
            browser
        }
        .padding(16)
        // Claim the whole window so the content sits at the top instead of being
        // centred in the leftover space.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(
            pending.map(confirmTitle) ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { removal in
            Button(removal.permanently ? "Delete Permanently" : "Move to Trash", role: .destructive) {
                perform(removal)
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(confirmMessage(removal))
        }
        .alert(
            "",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
            presenting: notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.text)
        }
        .onAppear { model.loadVolumes() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let volume = model.selectedVolume {
                    Text(Fmt.bigBytes(volume.used) + " used")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("of \(Fmt.bigBytes(volume.total)) · \(Fmt.bigBytes(volume.available)) available")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No volumes found").font(.title3)
                }
            }
            Spacer()
            Picker("Volume", selection: Binding(
                get: { model.selectedVolumeID ?? "" },
                set: { model.selectedVolumeID = $0 }
            )) {
                ForEach(model.volumes) { volume in
                    Text(volume.name).tag(volume.id)
                }
            }
            .frame(width: 240)
            Button {
                model.refreshCapacity()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Re-read volume capacity")
        }
    }

    @ViewBuilder
    private var scanBar: some View {
        if model.isScanning {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scanning… \(model.progress?.items ?? 0) items")
                        .font(.callout)
                    Text(shortPath(model.progress?.currentPath ?? ""))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Stop") { model.cancelScan() }
            }
        } else {
            HStack(spacing: 10) {
                Button(model.result == nil ? "Scan Home & Applications" : "Rescan") {
                    model.startScan()
                }
                .disabled(!model.canScanSelectedVolume)
                .keyboardShortcut("r", modifiers: .command)

                if let result = model.result {
                    Text("\(result.itemCount) items in \(String(format: "%.1f", result.duration))s"
                         + (result.unreadableFolders > 0
                            ? " · \(result.unreadableFolders) folders unreadable" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(result.unreadableFolders > 0
                              ? "Folders macOS protects are excluded. Granting Full Disk Access in "
                                + "System Settings › Privacy & Security includes them."
                              : "")
                } else if !model.canScanSelectedVolume {
                    Text("Breakdown is only available for the startup volume.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Scan to see which folders are using the space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = model.scanError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var browser: some View {
        if let roots = model.result?.roots, !roots.isEmpty {
            List {
                ForEach(roots) { root in
                    NodeRow(
                        node: root,
                        depth: 0,
                        share: 1,
                        expanded: $expanded,
                        selection: $selection,
                        onRemove: { node, permanently in
                            request(node, permanently: permanently)
                        }
                    )
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
            .id(model.treeVersion)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("No scan yet")
                    .foregroundStyle(.secondary)
                Text("Scanning walks your home folder and /Applications. Nothing is modified.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Removing

    private var selectedNode: ScanNode? {
        guard let selection, let roots = model.result?.roots else { return nil }
        func find(_ node: ScanNode) -> ScanNode? {
            if node.id == selection { return node }
            for child in node.children {
                if let hit = find(child) { return hit }
            }
            return nil
        }
        for root in roots {
            if let hit = find(root) { return hit }
        }
        return nil
    }

    @ViewBuilder
    private var actionBar: some View {
        if let node = selectedNode {
            let advice = FileRemover.advice(for: node.url)
            HStack(spacing: 10) {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name).lineLimit(1)
                    Text(shortPath(node.url.path))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(Fmt.bytes(node.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                if advice.allowsRemoval {
                    Button("Move to Trash") { request(node, permanently: false) }
                    Button("Delete…") { request(node, permanently: true) }
                } else {
                    Label("Protected", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(advice.note ?? "")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func confirmTitle(_ removal: PendingRemoval) -> String {
        removal.permanently
            ? "Permanently delete \(removal.node.name)?"
            : "Move \(removal.node.name) to the Trash?"
    }

    private func confirmMessage(_ removal: PendingRemoval) -> String {
        var parts: [String] = []
        let size = Fmt.bytes(removal.node.size)
        if removal.permanently {
            parts.append(
                "\(size) will be deleted immediately. This cannot be undone and the item "
                + "does not go to the Trash."
            )
        } else {
            parts.append(
                "\(size) will be moved to the Trash. The space is not freed until you "
                + "empty the Trash, and you can put it back until then."
            )
        }
        if let note = FileRemover.advice(for: removal.node.url).note {
            parts.append(note)
        }
        parts.append(removal.node.url.path)
        return parts.joined(separator: "\n\n")
    }

    private func request(_ node: ScanNode, permanently: Bool) {
        let advice = FileRemover.advice(for: node.url)
        guard advice.allowsRemoval else {
            notice = RemovalNotice(text: advice.note ?? "This item cannot be removed.")
            return
        }
        pending = PendingRemoval(node: node, permanently: permanently)
    }

    private func perform(_ removal: PendingRemoval) {
        Task {
            let freed = Fmt.bytes(removal.node.size)
            let outcome = await model.remove(removal.node, permanently: removal.permanently)
            selection = nil
            switch outcome {
            case .trashed:
                notice = RemovalNotice(
                    text: "\(removal.node.name) was moved to the Trash.\n\n"
                        + "\(freed) is not reclaimed until you empty the Trash."
                )
            case .deleted:
                notice = RemovalNotice(text: "\(removal.node.name) was deleted, freeing \(freed).")
            case .missing:
                notice = RemovalNotice(text: "\(removal.node.name) no longer exists.")
            case .notPermitted:
                notice = RemovalNotice(
                    text: "macOS would not let this app remove \(removal.node.name).\n\n"
                        + "Granting Full Disk Access in System Settings › Privacy & Security "
                        + "may help, or remove it in Finder."
                )
            case .failed(let reason):
                notice = RemovalNotice(text: "Could not remove \(removal.node.name).\n\n\(reason)")
            }
        }
    }
}

private struct PendingRemoval: Identifiable {
    let node: ScanNode
    let permanently: Bool
    var id: String { "\(node.id)-\(permanently)" }
}

private struct RemovalNotice: Identifiable {
    let text: String
    var id: String { text }
}

/// One row of the folder browser, with its own disclosure state so that expanding a
/// huge tree stays cheap — children are only built when a row opens.
private struct NodeRow: View {
    let node: ScanNode
    let depth: Int
    let share: Double
    @Binding var expanded: Set<String>
    @Binding var selection: String?
    let onRemove: (ScanNode, Bool) -> Void

    private var isExpanded: Bool { expanded.contains(node.id) }
    private var isSelected: Bool { selection == node.id }

    private func toggleExpanded() {
        guard !node.children.isEmpty else { return }
        if isExpanded { expanded.remove(node.id) } else { expanded.insert(node.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if isExpanded {
                ForEach(node.children) { child in
                    NodeRow(
                        node: child,
                        depth: depth + 1,
                        share: node.size == 0 ? 0 : Double(child.size) / Double(node.size),
                        expanded: $expanded,
                        selection: $selection,
                        onRemove: onRemove
                    )
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            Button {
                toggleExpanded()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(node.children.isEmpty ? 0 : 1)
                    .frame(width: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(node.children.isEmpty)

            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                .font(.caption)

            Text(node.name).lineLimit(1).truncationMode(.middle)

            Spacer(minLength: 12)

            // Relative bar makes it obvious which sibling dominates a folder.
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(1, geometry.size.width * share))
            }
            .frame(width: 70, height: 6)

            Text(Fmt.bytes(node.size))
                .monospacedDigit()
                .font(.callout)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = node.id }
        .onTapGesture(count: 2) { toggleExpanded() }
        .contextMenu {
            Button("Move to Trash") { onRemove(node, false) }
            Button("Delete Immediately…") { onRemove(node, true) }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
        }
    }
}
