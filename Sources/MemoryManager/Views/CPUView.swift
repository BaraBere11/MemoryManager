import AppKit
import SwiftUI

struct CPUView: View {
    @EnvironmentObject private var model: CPUModel
    @StateObject private var termination = TerminationCoordinator()
    @State private var highlighted: String?
    @State private var selection: ProcessRow.ID?
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpuPercent, order: .reverse)]

    private var segments: [BarSegment] {
        // Scaled to 10,000 so the shared byte-based bar can carry fractions; the
        // legend below renders percentages rather than these raw values.
        let scale = 10_000.0
        return [
            BarSegment("User", UInt64(model.snapshot.user * scale), Palette.app),
            BarSegment("System", UInt64(model.snapshot.system * scale), Palette.wired),
            BarSegment("Nice", UInt64(model.snapshot.nice * scale), Palette.compressed),
            BarSegment("Idle", UInt64(model.snapshot.idle * scale), Palette.free, isRemainder: true),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            SegmentedBar(segments: segments, highlighted: highlighted)
            legend
            cores
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.0f%% busy", model.snapshot.busy * 100))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(hardwareSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Load average").font(.caption).foregroundStyle(.secondary)
                    Text(loadAverageText)
                        .font(.callout)
                        .monospacedDigit()
                        .help(
                            "Processes wanting to run, averaged over 1, 5 and 15 minutes. "
                            + "Compare against \(model.hardware.logicalCores) cores: a figure "
                            + "above that means work is queuing."
                        )
                }
                Sparkline(values: model.history, color: busyColor)
                    .frame(width: 160, height: 28)
            }
            Picker("", selection: $model.interval) {
                ForEach(CPUModel.intervals, id: \.self) { value in
                    Text("\(Int(value))s").tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .help("How often to re-read CPU usage")
        }
    }

    private var hardwareSummary: String {
        let hardware = model.hardware
        var parts = ["\(hardware.brand)"]
        if hardware.isHybrid {
            parts.append("\(hardware.performanceCores) performance + \(hardware.efficiencyCores) efficiency cores")
        } else {
            parts.append("\(hardware.logicalCores) cores")
        }
        return parts.joined(separator: " · ")
    }

    private var loadAverageText: String {
        model.snapshot.loadAverage
            .map { String(format: "%.2f", $0) }
            .joined(separator: "  ")
    }

    private var busyColor: Color {
        let busy = model.snapshot.busy
        if busy > 0.85 { return .red }
        if busy > 0.6 { return .orange }
        return .green
    }

    private var legend: some View {
        HStack(spacing: 18) {
            ForEach(segments) { segment in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(segment.color)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(segment.label).font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.1f%%", Double(segment.bytes) / 100))
                            .font(.system(.callout, design: .rounded))
                            .monospacedDigit()
                    }
                }
                .onHover { highlighted = $0 ? segment.label : nil }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var cores: some View {
        if !model.snapshot.cores.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Cores").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Array(model.snapshot.cores.enumerated()), id: \.offset) { index, load in
                        CoreMeter(
                            index: index,
                            load: load,
                            tier: model.hardware.tier(forCore: index)
                        )
                    }
                }
            }
        }
    }

    private var processHeader: some View {
        HStack(spacing: 10) {
            Text("Processes").font(.headline)
            Text(String(format: "%.0f%% attributed", model.totalProcessPercent))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(
                    "Percentages are of one core, so a threaded process can exceed 100%. "
                    + "With \(model.hardware.logicalCores) cores the ceiling is "
                    + "\(model.hardware.logicalCores * 100)%."
                )
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
                        Text(owner).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("CPU", value: \.cpuPercent) { row in
                HStack(spacing: 2) {
                    Spacer(minLength: 0)
                    if row.cpuTime == nil {
                        Text("~").foregroundStyle(.tertiary)
                    }
                    Text(String(format: "%.1f%%", row.cpuPercent))
                        .monospacedDigit()
                        .foregroundStyle(row.cpuPercent > 50 ? Color.orange : Color.primary)
                }
            }
            .width(min: 70, ideal: 80)
            TableColumn("What it is", value: \.summary) { row in
                Text(row.summary)
                    .foregroundStyle(row.explanation.isSpecific ? .secondary : .tertiary)
                    .lineLimit(1)
                    .help(row.summary)
            }
            .width(min: 160, ideal: 280)
            TableColumn("Memory", value: \.memory) { row in
                Text(Fmt.bytes(row.memory))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 90)
            TableColumn("PID", value: \.id) { row in
                Text(String(row.id)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 55)
        }
        .frame(minHeight: 180, maxHeight: .infinity)
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
            CPUProcessDetail(row: selected, cores: model.hardware.logicalCores) { force in
                termination.request(selected, force: force)
            }
        }
    }
}

/// A single core's load, drawn as a vertical meter.
private struct CoreMeter: View {
    let index: Int
    let load: Double
    let tier: String?

    private var color: Color {
        if load > 0.85 { return .red }
        if load > 0.6 { return .orange }
        return Palette.app
    }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.07))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(height: max(2, geometry.size.height * min(1, max(0, load))))
                }
            }
            .frame(width: 26, height: 40)
            Text(tier.map { "\($0)\(index)" } ?? "\(index)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .help(
            tier == "P" ? "Performance core \(index) — \(Int(load * 100))%"
                : tier == "E" ? "Efficiency core \(index) — \(Int(load * 100))%"
                : "Core \(index) — \(Int(load * 100))%"
        )
    }
}

private struct CPUProcessDetail: View {
    let row: ProcessRow
    let cores: Int
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
                Spacer()
                Text(String(format: "%.1f%% CPU", row.cpuPercent))
                    .font(.system(.body, design: .rounded))
                    .monospacedDigit()
            }

            Text(row.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if row.cpuPercent > 100 {
                Text("Above 100% means it is using more than one core. "
                     + "The ceiling on this Mac is \(cores * 100)%.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if row.cpuTime == nil {
                Text("CPU shown is the recent average reported by ps — this process belongs "
                     + "to another user, so its exact CPU time is not readable.")
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
            }

            HStack(spacing: 8) {
                if advice.allowsTermination {
                    Button("Quit") { onQuit(false) }
                    Button("Force Quit") { onQuit(true) }
                    if advice.risk == .severe {
                        Label("Ends your session or loses unsaved work", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
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
