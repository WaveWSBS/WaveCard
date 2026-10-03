import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CardItemView: View {
    @ObservedObject var vm: AppViewModel
    let card: CardItem
    let isSelectedForDetail: Bool
    let onSelectForDetail: () -> Void

    @State private var isHovered = false
    @State private var isDropTargeted = false

    private var displayImage: NSImage? {
        if let customURL = card.customImageURL, let img = CardAssetManager.shared.cachedImage(at: customURL) {
            return img
        }
        if let cachedCustom = CardAssetManager.shared.loadCachedCustom(for: card.id) {
            return cachedCustom
        }
        if let memOrig = vm.originalImages[card.id] {
            return memOrig
        }
        return CardAssetManager.shared.loadOriginal(for: card.id)
    }

    private var hasCustomSkin: Bool {
        card.customImageURL != nil || CardAssetManager.shared.loadCachedCustom(for: card.id) != nil
    }

    private var hasStoredOriginal: Bool {
        vm.hasOriginal(for: card.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Realistic Card Canvas
            ZStack(alignment: .topLeading) {
                // Background Artwork or Elegant Gradient
                if let img = displayImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 290, height: 183)
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(NSColor.controlBackgroundColor),
                                    Color(NSColor.windowBackgroundColor).opacity(0.85)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 290, height: 183)

                    // Empty State Card Pattern
                    VStack(spacing: 8) {
                        if vm.loadingImages.contains(card.id) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Reading artwork from iPhone...")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        } else {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 30))
                                .foregroundColor(isDropTargeted ? .accentColor : .secondary.opacity(0.6))
                            Text("Drop custom skin here")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.primary)
                            Text("or click to select")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)

                            if vm.device?.connected == true {
                                Button(action: { vm.loadOriginalArtwork(for: card) }) {
                                    Label("Fetch from iPhone", systemImage: "arrow.down.circle")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .buttonStyle(.borderless)
                                .foregroundColor(.accentColor)
                                .padding(.top, 2)
                            }
                        }
                    }
                    .frame(width: 290, height: 183)
                }

                // Apple Wallet Glass / Metallic Sheen
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.18),
                        Color.white.opacity(0.04),
                        Color.clear,
                        Color.black.opacity(0.15)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .allowsHitTesting(false)

                // EMV Chip & Contactless Wave Overlays
                VStack(alignment: .leading) {
                    HStack(alignment: .top) {
                        // Checkbox for batch operations
                        Toggle("", isOn: Binding(
                            get: { card.isSelected },
                            set: { newVal in
                                if let idx = vm.cards.firstIndex(where: { $0.id == card.id }) {
                                    vm.cards[idx].isSelected = newVal
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        Spacer()

                        // Status Badges
                        HStack(spacing: 4) {
                            if hasCustomSkin {
                                Label("Custom Skin", systemImage: "sparkles")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.purple.opacity(0.85))
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            } else if displayImage != nil {
                                Label("Original Pass", systemImage: "applelogo")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.ultraThinMaterial)
                                    .foregroundColor(.primary)
                                    .clipShape(Capsule())
                            }

                            if hasStoredOriginal {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.green)
                                    .help("Original artwork stored on this Mac")
                            }
                        }
                    }

                    Spacer()

                    // Card Bottom Info
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.label)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                                .lineLimit(1)

                            Text("HASH: \(card.id.prefix(12))...")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                        }

                        Spacer()

                        Image(systemName: "wave.3.forward")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.75))
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    }
                }
                .padding(12)

                // Hover Action Bar
                if isHovered {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Button(action: { pickImage() }) {
                                Label("Set Skin", systemImage: "photo")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.accentColor)
                            .controlSize(.small)

                            if hasCustomSkin {
                                Button(action: { vm.clearCustomSkin(for: card.id) }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Clear custom skin")
                            }

                            Button(action: { vm.exportOriginalPNG(cardId: card.id) }) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(vm.isExporting)
                            .help("Export the original artwork as a PNG file")

                            if hasStoredOriginal {
                                Button(action: { vm.restoreCard(cardHash: card.id) }) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(vm.isRestoring || vm.isScanningCards || vm.isFlashing)
                                .help("Restore factory artwork to this card")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)
                        .shadow(radius: 6)
                        .padding(.bottom, 12)
                    }
                    .frame(width: 290, height: 183)
                }
            }
            .frame(width: 290, height: 183)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelectedForDetail ? Color.accentColor : (isDropTargeted ? Color.accentColor : Color.white.opacity(0.15)),
                        lineWidth: isSelectedForDetail ? 2.5 : (isDropTargeted ? 2 : 1)
                    )
            )
            .shadow(color: .black.opacity(isSelectedForDetail ? 0.25 : 0.12), radius: isSelectedForDetail ? 10 : 5, x: 0, y: 3)
            .onHover { isHovered = $0 }
            .onTapGesture {
                onSelectForDetail()
            }
            .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.prompt = "Choose Skin"

        if panel.runModal() == .OK, let url = panel.url {
            vm.setCustomSkin(for: card.id, imageURL: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async {
                        self.vm.setCustomSkin(for: self.card.id, imageURL: url)
                    }
                }
                return true
            }
        }
        return false
    }
}
