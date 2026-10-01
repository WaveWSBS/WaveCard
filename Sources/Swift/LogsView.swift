import SwiftUI

struct LogsView: View {
    @ObservedObject var vm: AppViewModel
    @State private var filterText: String = ""

    private var filteredLogs: [LogEntry] {
        if filterText.isEmpty {
            return vm.logs
        }
        return vm.logs.filter {
            $0.message.localizedCaseInsensitiveContains(filterText) ||
            $0.level.rawValue.localizedCaseInsensitiveContains(filterText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Log Toolbar
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Filter logs...", text: $filterText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .frame(maxWidth: 240)

                Spacer()

                Button(action: {
                    let text = vm.logs.map { "[\($0.formattedTime)] [\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }) {
                    Label("Copy All", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .disabled(vm.logs.isEmpty)

                Button(action: { vm.clearLogs() }) {
                    Label("Clear", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .disabled(vm.logs.isEmpty)
            }
            .padding(12)

            Divider()

            // Console Output
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredLogs) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.formattedTime)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)

                                Text("[\(entry.level.rawValue)]")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(color(for: entry.level))
                                    .frame(width: 65, alignment: .leading)

                                Text(entry.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(12)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: vm.logs.count) { _, _ in
                    if let last = vm.logs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
