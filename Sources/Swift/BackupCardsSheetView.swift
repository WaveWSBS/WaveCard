import SwiftUI

struct BackupCardsSheetView: View {
    @ObservedObject var vm: AppViewModel
    @State private var backupAllCards: Bool = false

    private var targetCards: [CardItem] {
        if backupAllCards {
            return vm.cards
        } else {
            let selected = vm.cards.filter { $0.isSelected }
            return selected.isEmpty ? vm.cards : selected
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backup Original Card Artwork")
                        .font(.system(size: 16, weight: .bold))
                    Text("Safely read and store factory artwork on your Mac before flashing custom skins.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            // Scan status notice
            if vm.isScanningCards {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Card scanner is currently active! Please stop scanning first before starting backups.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.orange)
                    Spacer()
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
            }

            // Scope selection
            VStack(alignment: .leading, spacing: 10) {
                Text("BACKUP SCOPE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                Picker("", selection: $backupAllCards) {
                    Text("All Cards (\(vm.cards.count))").tag(true)
                    Text("Selected Cards (\(vm.cards.filter { $0.isSelected }.count))").tag(false)
                }
                .pickerStyle(.segmented)
            }

            // Cards Preview List
            VStack(alignment: .leading, spacing: 8) {
                Text("CARDS TO BACKUP (\(targetCards.count))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(targetCards) { card in
                            HStack {
                                Image(systemName: "creditcard.fill")
                                    .foregroundColor(.secondary)
                                Text(card.label)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(card.id)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: 140, alignment: .trailing)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                    .padding(4)
                }
                .frame(height: 140)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }

            // Destination notice
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                Text("Stored safely at ~/Documents/AirCard/Backups")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }

            Divider()

            // Footer Actions
            HStack {
                Button("Cancel") {
                    vm.showBackupModal = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: {
                    vm.showBackupModal = false
                    if backupAllCards {
                        // Select all and backup
                        for idx in vm.cards.indices { vm.cards[idx].isSelected = true }
                    }
                    vm.backupSelectedCards()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc")
                        Text("Start Backup (\(targetCards.count) Cards)")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(targetCards.isEmpty || vm.isScanningCards || vm.isBackingUp || vm.device == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}
