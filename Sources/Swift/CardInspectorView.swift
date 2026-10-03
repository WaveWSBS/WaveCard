import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CardInspectorView: View {
    @ObservedObject var vm: AppViewModel
    let cardId: String

    private var card: CardItem? {
        vm.cards.first(where: { $0.id == cardId })
    }

    private var originalImage: NSImage? {
        vm.originalImages[cardId] ?? CardAssetManager.shared.loadOriginal(for: cardId)
    }

    private var customImage: NSImage? {
        if let card = card, let url = card.customImageURL {
            return NSImage(contentsOf: url)
        }
        return CardAssetManager.shared.loadCachedCustom(for: cardId)
    }

    private var hasStoredOriginal: Bool {
        vm.hasOriginal(for: cardId)
    }

    var body: some View {
        Group {
            if let card = card {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // Header
                        HStack {
                            Text("Card Details")
                                .font(.system(size: 14, weight: .bold))
                            Spacer()
                            Button(action: { vm.selectedCardId = nil }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                        }

                        // Editable Label
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CARD NAME")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)

                            TextField("Card Label", text: Binding(
                                get: { card.label },
                                set: { newLabel in
                                    if let idx = vm.cards.firstIndex(where: { $0.id == cardId }) {
                                        vm.cards[idx].label = newLabel
                                        vm.saveCards()
                                    }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }

                        // Hash Identifier with Copy
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PASS HASH")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)

                            HStack {
                                Text(card.id)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundColor(.secondary)

                                Spacer()

                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(card.id, forType: .string)
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .help("Copy Hash")
                            }
                            .padding(8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                        }

                        Divider()

                        // Artwork Section: Original vs Custom
                        VStack(alignment: .leading, spacing: 12) {
                            Text("ORIGINAL APPLE PASS ARTWORK")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)

                            if let orig = originalImage {
                                Image(nsImage: orig)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                    )
                            } else if vm.loadingImages.contains(card.id) {
                                HStack {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Loading from iPhone...")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 90)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(8)
                            } else {
                                VStack(spacing: 6) {
                                    Text("Original not extracted yet")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Button("Fetch from iPhone") {
                                        vm.loadOriginalArtwork(for: card)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(vm.device == nil)
                                }
                                .frame(maxWidth: .infinity, minHeight: 90)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(8)
                            }
                        }

                        // Custom Skin Section
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("ASSIGNED CUSTOM SKIN")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.secondary)

                                Spacer()

                                if customImage != nil {
                                    Button("Clear") {
                                        vm.clearCustomSkin(for: card.id)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10))
                                    .foregroundColor(.red)
                                }
                            }

                            if let custom = customImage {
                                Image(nsImage: custom)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.purple.opacity(0.5), lineWidth: 1.5)
                                    )
                            } else {
                                Button(action: { pickSkin() }) {
                                    VStack(spacing: 6) {
                                        Image(systemName: "plus.circle")
                                            .font(.system(size: 20))
                                            .foregroundColor(.accentColor)
                                        Text("Choose Skin Image...")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 90)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Divider()

                        // Action Buttons
                        VStack(spacing: 10) {
                            Button(action: { vm.exportOriginalPNG(cardId: card.id) }) {
                                Label("Export Original as PNG", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .disabled(vm.isExporting)
                            .help("Save this card's original Apple artwork as a PNG file")

                            if hasStoredOriginal {
                                Button(action: { vm.restoreCard(cardHash: card.id) }) {
                                    Label("Restore Original to iPhone", systemImage: "arrow.counterclockwise")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(.green)
                                .controlSize(.regular)
                                .disabled(vm.isRestoring || vm.isScanningCards || vm.isFlashing)
                            }

                            Button(role: .destructive, action: { vm.deleteCard(id: card.id) }) {
                                Label("Remove Card from Library", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Select a card to view and customize")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func pickSkin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.prompt = "Choose Skin"

        if panel.runModal() == .OK, let url = panel.url {
            vm.setCustomSkin(for: cardId, imageURL: url)
        }
    }
}
