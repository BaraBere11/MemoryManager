import Foundation
import SwiftUI

enum Fmt {
    /// Finder-style sizes (base 10), which is what macOS shows everywhere in the UI.
    private static let file: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    private static let fileNoDecimal: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB, .useTB]
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func bytes(_ v: UInt64) -> String {
        file.string(fromByteCount: Int64(clamping: v))
    }

    static func bytes(_ v: Int64) -> String {
        file.string(fromByteCount: v)
    }

    /// Coarser variant for headline numbers.
    static func bigBytes(_ v: UInt64) -> String {
        fileNoDecimal.string(fromByteCount: Int64(clamping: v))
    }

    static func percent(_ fraction: Double) -> String {
        let clamped = max(0, min(1, fraction))
        return String(format: "%.0f%%", clamped * 100)
    }
}

/// Palette shared by the memory and storage breakdowns so the two tabs read as one app.
enum Palette {
    static let app = Color(red: 0.31, green: 0.51, blue: 0.93)
    static let wired = Color(red: 0.55, green: 0.40, blue: 0.86)
    static let compressed = Color(red: 0.90, green: 0.55, blue: 0.24)
    static let cached = Color(red: 0.30, green: 0.70, blue: 0.62)
    static let free = Color(nsColor: .quaternaryLabelColor)

    /// Categories, in the order they appear in the storage bar.
    static let categories: [Color] = [
        Color(red: 0.31, green: 0.51, blue: 0.93),
        Color(red: 0.55, green: 0.40, blue: 0.86),
        Color(red: 0.90, green: 0.55, blue: 0.24),
        Color(red: 0.30, green: 0.70, blue: 0.62),
        Color(red: 0.85, green: 0.35, blue: 0.45),
        Color(red: 0.40, green: 0.65, blue: 0.30),
        Color(red: 0.25, green: 0.62, blue: 0.80),
        Color(red: 0.75, green: 0.60, blue: 0.20),
        Color(red: 0.60, green: 0.45, blue: 0.40),
        Color(red: 0.50, green: 0.50, blue: 0.58),
    ]

    static func category(_ index: Int) -> Color {
        categories[index % categories.count]
    }
}
