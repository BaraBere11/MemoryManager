import AppKit
import SwiftUI

struct MemoryView: View {
    @EnvironmentObject private var model: MemoryModel
    @State private var highlighted: String?
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.memory, order: .reverse)]
    @State private var selection: ProcessRow.ID?
    @StateObject private var termination = TerminationCoordinator()

    private var segments: [BarSegment] {
        let snapshot = model.snapshot
        return [
            BarSegment("App Memory", snapshot.appMemory, Palette.app),
            BarSegment("Wired", snapshot.wired, Palette.wired),
            BarSegment("Compressed", snapshot.compressed, Palette.compressed),
            BarSegment("Cached Files", snapshot.cachedFiles, Palette.cached),
            BarSegment("Free", snapshot.free, Palette.free, isRemainder: true),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            SegmentedBar(segments: segments, highlighted: highlighted)
            LegendGrid(segments: segments, highlighted: $highlighted)
            tiles
            Divider()
            processHeader
            processTable
            detail
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .processTermination(termination)
        .onAppear {
            termination.onCompleted = { [weak model] in model?.refreshNow() }
            model.start()
        }
        .onDisappear { model.stop() }
    }

    // MARK: - Terminating

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.bigBytes(model.snapshot.used) + " used")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("of \(Fmt.bigBytes(model.snapshot.total)) physical memory · \(Fmt.percent(model.snapshot.usedFraction))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Pressure").font(.caption).foregroundStyle(.secondary)
                    PressureBadge(pressure: model.snapshot.pressure)
                }
                Sparkline(values: model.history, color: pressureColor)
                    .frame(width: 160, height: 28)
            }
            Picker("", selection: $model.interval) {
                ForEach(MemoryModel.intervals, id: \.self) { value in
                    Text("\(Int(value))s").tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .help("How often to re-read memory usage")
        }
    }

    private var pressureColor: Color {
        switch model.snapshot.pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            StatTile(
                title: "Swap Used",
                value: Fmt.bytes(model.snapshot.swapUsed),
                detail: model.snapshot.swapTotal > 0
                    ? "of \(Fmt.bytes(model.snapshot.swapTotal)) swap file" : "no swap file"
            )
            StatTile(
                title: "Compressed",
                value: Fmt.bytes(model.snapshot.compressed),
                detail: "RAM reclaimed by compression"
            )
            StatTile(
                title: "Cached Files",
                value: Fmt.bytes(model.snapshot.cachedFiles),
                detail: "reusable — counts as available"
            )
            StatTile(
                title: "Processes",
                value: "\(model.sample.rows.count)",
                detail: "\(Fmt.bytes(model.sample.totalMemory)) across all"
            )
        }
    }

    private var processHeader: some View {
        HStack(spacing: 10) {
            Text("Processes").font(.headline)
            if model.sample.estimatedCount > 0 {
                Text("\(model.sample.estimatedCount) estimated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(
                        "\(model.sample.estimatedCount) processes belong to other users, so their "
                        + "exact footprint is not readable. Those rows show resident size (~) "
                        + "reported by ps instead, which counts shared memory more than once."
                    )
            }
            Spacer()
            TextField("Filter", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Button {
                model.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now")
            .disabled(model.isSampling)
        }
    }

    private var rows: [ProcessRow] {
        model.filteredRows.sorted(using: sortOrder)
    }

    private var processTable: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Process", value: \.name) { row in
                HStack(spacing: 6) {
                    Text(row.name).lineLimit(1)
                    if let owner = row.owner {
                        Text(owner)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("What it is", value: \.summary) { row in
                Text(row.summary)
                    .foregroundStyle(row.explanation.isSpecific ? .secondary : .tertiary)
                    .lineLimit(1)
                    .help(row.summary)
            }
            .width(min: 180, ideal: 320)
            TableColumn("Memory", value: \.memory) { row in
                HStack(spacing: 2) {
                    Spacer(minLength: 0)
                    if row.isEstimate {
                        Text("~").foregroundStyle(.tertiary)
                    }
                    Text(Fmt.bytes(row.memory)).monospacedDigit()
                }
            }
            .width(min: 90, ideal: 100)
            TableColumn("User", value: \.user) { row in
                Text(row.user).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 80)
            TableColumn("PID", value: \.id) { row in
                Text(String(row.id)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 55)
        }
        .frame(minHeight: 200, maxHeight: .infinity)
        .contextMenu(forSelectionType: ProcessRow.ID.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Quit \(row.name)") { termination.request(row, force: false) }
                Button("Force Quit \(row.name)") { termination.request(row, force: true) }
                Divider()
                Button("Copy PID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(row.id), forType: .string)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected = rows.first(where: { $0.id == selection }) {
            ProcessDetail(row: selected) { force in
                termination.request(selected, force: force)
            }
            .transition(.opacity)
        }
    }
}

/// Expanded information for the selected row: what the process is, where it lives,
/// and how its memory figure was obtained.
private struct ProcessDetail: View {
    let row: ProcessRow
    let onQuit: (_ force: Bool) -> Void

    private var advice: KillAdvice { ProcessKiller.advice(for: row) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(row.name).font(.headline)
                if !row.explanation.kind.label.isEmpty {
                    Text(row.explanation.kind.label)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                if let owner = row.owner {
                    Text("part of \(owner)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Fmt.bytes(row.memory))
                    .font(.system(.body, design: .rounded))
                    .monospacedDigit()
            }

            Text(row.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !row.explanation.isSpecific {
                Text("This description is inferred from where the program is installed, "
                     + "not from a description of the program itself.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if row.isEstimate {
                Text("Memory shown is resident size, not exact footprint — this process "
                     + "belongs to another user, so its footprint is not readable.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !row.path.isEmpty {
                Text(row.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(row.path)
            }

            HStack(spacing: 8) {
                if advice.allowsTermination {
                    Button("Quit") { onQuit(false) }
                    Button("Force Quit") { onQuit(true) }
                    if advice.risk == .severe {
                        Label("Ends your session or loses unsaved work", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if advice.risk == .caution {
                        Label("System process", systemImage: "gearshape.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("This process cannot be quit", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
