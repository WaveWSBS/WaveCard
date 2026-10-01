import AppKit
import SwiftUI

struct BackupRowView: View {
    @ObservedObject var vm: AppViewModel
    let backup: CardBackup

    var body: some View {
        HStack(spacing: 16) {
            // Thumbnail
            ZStack {
                if let thumb = backup.thumbnailURL, let img = NSImage(contentsOf: thumb) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor))
                    Image(systemName: "creditcard")
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 80, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )

            // Metadata
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(backup.label)
                        .font(.system(size: 14, weight: .bold))
                    Text(backup.formattedDate)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Text("HASH: \(backup.cardHash)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    ForEach(backup.files, id: \.self) { file in
                        Text(file)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(4)
                    }
                }
            }

            Spacer()

            // Restore Action
            Button(action: {
                vm.restoreCard(cardHash: backup.cardHash)
            }) {
                Label("Restore to iPhone", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(vm.isRestoring || vm.device == nil)

            Button(action: {
                CardBackupManager.shared.revealBackupInFinder(cardHash: backup.cardHash)
            }) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .help("Show in Finder")

            Button(action: {
                CardBackupManager.shared.deleteBackup(cardHash: backup.cardHash)
                vm.refreshBackups()
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
            .buttonStyle(.bordered)
            .help("Delete Backup")
        }
        .padding(.vertical, 8)
    }
}

struct BackupsView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved Card Backups")
                        .font(.system(size: 16, weight: .bold))
                    Text("Restore your cards to their original factory artwork at any time.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: CardBackupManager.shared.backupsRootURL.path)
                }) {
                    Label("Open in Finder", systemImage: "folder")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            }
            .padding(16)

            Divider()

            if vm.backups.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .font(.system(size: 52))
                        .foregroundColor(.secondary.opacity(0.5))

                    VStack(spacing: 6) {
                        Text("No Backups Saved Yet")
                            .font(.system(size: 16, weight: .bold))
                        Text("When your iPhone is connected, select any card and click 'Backup' to preserve its factory artwork safely on your Mac.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                List(vm.backups, id: \CardBackup.cardHash) { backup in
                    BackupRowView(vm: vm, backup: backup)
                }
                .listStyle(.inset)
            }
        }
    }
}
