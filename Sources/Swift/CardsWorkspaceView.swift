import SwiftUI
import UniformTypeIdentifiers

struct CardsWorkspaceView: View {
    @ObservedObject var vm: AppViewModel

    private let columns = [
        GridItem(.adaptive(minimum: 290, maximum: 320), spacing: 20)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Scanner Active Banner
            if vm.isScanningCards {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .stroke(Color.red.opacity(0.5), lineWidth: 6)
                                .scaleEffect(1.4)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listening for Apple Wallet Cards...")
                            .font(.system(size: 13, weight: .bold))
                        Text("Double-click iPhone Side button → Pass Face ID → Tap cards to detect.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: { vm.stopScanning() }) {
                        Text("Stop Scanner")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.1))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color.red.opacity(0.2)),
                    alignment: .bottom
                )
            }

            // Progress Banner when flashing, fetching originals, exporting, or restoring
            if vm.isFlashing || vm.isFetchingOriginals || vm.isRestoring || vm.isExporting {
                VStack(spacing: 6) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text(vm.statusText)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    if vm.progress > 0 {
                        ProgressView(value: vm.progress, total: 1.0)
                            .progressViewStyle(.linear)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color.accentColor.opacity(0.2)),
                    alignment: .bottom
                )
            }

            // Main Card Grid or Empty State
            ScrollView {
                if vm.cards.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "creditcard.and.123")
                            .font(.system(size: 56))
                            .foregroundColor(.secondary.opacity(0.6))

                        VStack(spacing: 6) {
                            Text("No Wallet Cards Added Yet")
                                .font(.system(size: 18, weight: .bold))

                            Text("Connect your iPhone via USB and click 'Scan Cards',\nthen double-click your iPhone's side button to summon Apple Pay.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        HStack(spacing: 12) {
                            Button(action: { vm.startScanning() }) {
                                Label("Start Scanning Cards", systemImage: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                            Button(action: { vm.showAddCardSheet = true }) {
                                Label("Add Hash Manually", systemImage: "plus")
                                    .font(.system(size: 13))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 350)
                    .padding(40)
                } else {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(vm.cards) { card in
                            CardItemView(
                                vm: vm,
                                card: card,
                                isSelectedForDetail: vm.selectedCardId == card.id,
                                onSelectForDetail: {
                                    vm.selectedCardId = card.id
                                }
                            )
                        }
                    }
                    .padding(24)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // Scanner Toggle Button
                Button(action: { vm.toggleScanning() }) {
                    Label(
                        vm.isScanningCards ? "Stop Scanning" : "Scan Cards",
                        systemImage: vm.isScanningCards ? "stop.circle.fill" : "antenna.radiowaves.left.and.right"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.isScanningCards ? .red : .accentColor)
                .help(vm.isScanningCards ? "Stop listening for cards" : "Scan device logs while opening Apple Wallet")

                // Add card manually
                Button(action: { vm.showAddCardSheet = true }) {
                    Label("Add Card", systemImage: "plus")
                }
                .help("Enter a card hash manually")
            }

            ToolbarItemGroup(placement: .principal) {
                // Bulk selection
                HStack(spacing: 6) {
                    Button(action: {
                        for idx in vm.cards.indices { vm.cards[idx].isSelected = true }
                    }) {
                        Text("Select All")
                            .font(.system(size: 11))
                    }
                    .disabled(vm.cards.isEmpty)

                    Button(action: {
                        for idx in vm.cards.indices { vm.cards[idx].isSelected = false }
                    }) {
                        Text("Deselect All")
                            .font(.system(size: 11))
                    }
                    .disabled(vm.cards.isEmpty)
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // Bulk Skin Import
                Button(action: { pickBulkSkin() }) {
                    Label("Set Skin for All...", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(vm.cards.isEmpty)
                .help("Assign a custom skin image to all selected cards")

                // Pull the factory artwork of every card that has none stored.
                Button(action: { vm.fetchAllOriginals() }) {
                    Label("Fetch All Originals", systemImage: "arrow.down.doc")
                }
                .disabled(vm.cards.isEmpty || vm.isScanningCards || vm.isFetchingOriginals || vm.isFlashing || vm.device == nil)
                .help(vm.isScanningCards
                      ? "Please finish or stop scanning first"
                      : "Read and store the original Apple artwork for every card missing one")

                // Bulk restore
                Button(action: { vm.showRestoreAllConfirm = true }) {
                    Label("Restore All", systemImage: "arrow.counterclockwise")
                }
                .disabled(vm.cards.isEmpty || vm.isRestoring || vm.device == nil || vm.isScanningCards)
                .help("Rebuild factory artwork on every card that has an original stored")

                // Flash Action (Prominent)
                Button(action: { vm.flashSelectedCards() }) {
                    Label("Flash to iPhone", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(vm.cards.isEmpty || vm.isFlashing || vm.device == nil)
                .help("Flash custom skins to selected cards via native Airlift")

                // Batch export of stored originals
                Button(action: { vm.exportSelectedOriginals() }) {
                    Label("Export PNGs...", systemImage: "square.and.arrow.up")
                }
                .disabled(vm.cards.isEmpty || vm.isExporting)
                .help("Save the original artwork of every selected card as a PNG file")
            }
        }
    }

    private func pickBulkSkin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic, .webP]
        panel.prompt = "Select Skin for Selected Cards"

        if panel.runModal() == .OK, let url = panel.url {
            vm.setBulkSkin(imageURL: url)
        }
    }
}
