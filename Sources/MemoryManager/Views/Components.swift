import SwiftUI

struct BarSegment: Identifiable, Hashable {
    let id: String
    let label: String
    let bytes: UInt64
    let color: Color
    var isRemainder: Bool = false

    init(_ label: String, _ bytes: UInt64, _ color: Color, isRemainder: Bool = false) {
        self.id = label
        self.label = label
        self.bytes = bytes
        self.color = color
        self.isRemainder = isRemainder
    }
}

/// A single horizontal bar split into proportional, labelled segments.
struct SegmentedBar: View {
    let segments: [BarSegment]
    var height: CGFloat = 26
    var highlighted: String?

    private var total: Double {
        max(1, segments.reduce(0.0) { $0 + Double($1.bytes) })
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    let fraction = Double(segment.bytes) / total
                    Rectangle()
                        .fill(segment.color)
                        .opacity(highlighted == nil || highlighted == segment.label ? 1 : 0.35)
                        .frame(width: max(0, geometry.size.width * fraction))
                        .help("\(segment.label) — \(Fmt.bytes(segment.bytes))")
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .animation(.easeOut(duration: 0.25), value: segments)
    }
}

struct LegendGrid: View {
    let segments: [BarSegment]
    var columns: Int = 5
    @Binding var highlighted: String?

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns),
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(segments) { segment in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(segment.color)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(segment.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(Fmt.bytes(segment.bytes))
                            .font(.system(.callout, design: .rounded))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onHover { inside in
                    highlighted = inside ? segment.label : nil
                }
            }
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded))
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

/// Recent history of a 0–1 value, drawn as a filled line.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let count = max(values.count, 2)
            let step = width / CGFloat(count - 1)

            let points: [CGPoint] = values.enumerated().map { index, value in
                CGPoint(
                    x: CGFloat(index) * step,
                    y: height - CGFloat(max(0, min(1, value))) * height
                )
            }

            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: height))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.18))

                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

struct PressureBadge: View {
    let pressure: MemoryPressure

    private var color: Color {
        switch pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(pressure.label).font(.callout)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}
