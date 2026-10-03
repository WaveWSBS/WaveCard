import SwiftUI

struct AppSidebarView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // App Branding Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)

                    Image(systemName: "creditcard.and.123")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("WaveCard")
                            .font(.system(size: 15, weight: .bold))
                        Text("2.0")
                            .font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2))
                            .foregroundColor(.accentColor)
                            .clipShape(Capsule())
                    }
                    Text("Apple Wallet Theming Engine")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 12)

            // Connected Device Status Box
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(vm.device != nil ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                            .overlay(
                                Circle()
                                    .stroke(vm.device != nil ? Color.green.opacity(0.4) : Color.clear, lineWidth: 4)
                            )

                        Text(vm.device != nil ? "USB Connected" : "No Device")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(vm.device != nil ? .primary : .secondary)
                    }

                    Spacer()

                    Button(action: { vm.checkDevice() }) {
                        if vm.isCheckingDevice {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Refresh connected device")
                }

                if let dev = vm.device {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dev.name ?? "iPhone")
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)

                        Text("\(dev.product ?? "iOS Device") · iOS \(dev.version ?? "Unknown")")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Connect your iPhone via USB cable and unlock it.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Navigation List
            List(selection: $vm.selectedNav) {
                Section("LIBRARY") {
                    NavigationLink(value: NavigationTab.cards) {
                        HStack {
                            Label("Wallet Cards", systemImage: "creditcard.fill")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            if !vm.cards.isEmpty {
                                Text("\(vm.cards.count)")
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                Section("SYSTEM") {
                    NavigationLink(value: NavigationTab.logs) {
                        HStack {
                            Label("Activity Console", systemImage: "terminal.fill")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            if !vm.logs.isEmpty {
                                Text("\(vm.logs.count)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Button(action: { vm.revealOriginalsInFinder() }) {
                        HStack {
                            Label("Originals Folder", systemImage: "folder")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("\(vm.cards.filter { vm.hasOriginal(for: $0.id) }.count)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.primary)
                    .help("Reveal ~/Documents/WaveCard/Originals in Finder")
                }
            }
            .listStyle(.sidebar)

            Spacer()

            // Bottom Device Helper Info
            HStack(spacing: 8) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                Text("Native Airlift Engine · Zero Python")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 230, idealWidth: 250, maxWidth: 280)
    }
}
