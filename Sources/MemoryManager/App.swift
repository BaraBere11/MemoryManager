import SwiftUI

@main
struct MemoryManagerApp: App {
    @StateObject private var memory = MemoryModel()
    @StateObject private var cpu = CPUModel()
    @StateObject private var disk = DiskModel()

    var body: some Scene {
        Window("Memory Manager - MacOS", id: "main") {
            RootView()
                .environmentObject(memory)
                .environmentObject(cpu)
                .environmentObject(disk)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 1000, height: 720)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    memory.refreshNow()
                    cpu.refreshNow()
                }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case memory = "Memory"
    case cpu = "CPU"
    case storage = "Storage"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .memory: return "memorychip"
        case .cpu: return "cpu"
        case .storage: return "internaldrive"
        }
    }
}

struct RootView: View {
    @State private var tab: AppTab = .memory

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(AppTab.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            .padding(.vertical, 10)

            Divider()

            switch tab {
            case .memory: MemoryView()
            case .cpu: CPUView()
            case .storage: DiskView()
            }
        }
    }
}
