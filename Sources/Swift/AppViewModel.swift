import Foundation
import SwiftUI
import AppKit
import Combine

/// Central application state manager for WaveCard (macOS HIG).
/// Pure Swift implementation handling USB device polling, real-time Apple Wallet card scanning,
/// artwork caching, skin flashing, and full pass backup/restore.
@MainActor
public final class AppViewModel: ObservableObject {
    // MARK: - Navigation & Tab State
    @Published public var selectedNav: NavigationTab = .cards
    @Published public var selectedTab: NavigationTab = .cards

    // MARK: - Connected Device State
    @Published public var device: DeviceInfo?
    @Published public var isPollingDevice: Bool = false
    @Published public var isCheckingDevice: Bool = false

    // MARK: - Card Library State
    @Published public var cards: [CardItem] = []
    @Published public var selectedCardId: String?
    @Published public var originalImages: [String: NSImage] = [:]
    @Published public var loadingImages: Set<String> = []

    // MARK: - Scanning & Operations State
    @Published public var isScanningCards: Bool = false
    @Published public var isFlashing: Bool = false
    @Published public var isFetchingOriginals: Bool = false
    @Published public var isRestoring: Bool = false
    @Published public var isExporting: Bool = false
    @Published public var progress: Double = 0.0
    @Published public var statusText: String = "Ready"

    // MARK: - Logs Console State
    @Published public var logs: [LogEntry] = []
    @Published public var logFilter: LogLevel?

    // MARK: - Alerts & Modals
    @Published public var errorMessage: String?
    @Published public var showSuccessAlert: Bool = false
    @Published public var successAlertTitle: String = ""
    @Published public var successAlertMessage: String = ""
    @Published public var showManualAddModal: Bool = false
    @Published public var showAddCardSheet: Bool = false
    @Published public var showRestoreAllConfirm: Bool = false

    // MARK: - Internal Timers & Processes
    private var devicePollTask: Task<Void, Never>?
    private var missedDevicePolls = 0
    private var scanProcess: Process?
    private let cardsStoreURL: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let wavecardDir = appSupport.appendingPathComponent("WaveCard", isDirectory: true)
        try? FileManager.default.createDirectory(at: wavecardDir, withIntermediateDirectories: true)
        self.cardsStoreURL = wavecardDir.appendingPathComponent("saved_cards.json")

        // Collapse the old cache + Backups dumps into one PNG per card before
        // anything reads them.
        let migration = CardAssetManager.shared.migrateLegacyOriginalsOnce()
        if migration.migrated > 0 {
            log("Migrated \(migration.migrated) original(s) into ~/Documents/WaveCard/Originals.", level: .success)
        }

        loadSavedCards()
        startDevicePolling()
    }

    deinit {
        devicePollTask?.cancel()
        scanProcess?.terminate()
    }

    // MARK: - Device Polling

    /// Only work that already holds a lockdown session blocks a USB poll. Pending
    /// artwork queue entries hold nothing, and counting them wedges the poller:
    /// with no device connected the queue cannot drain, so `refreshDevice` would
    /// never notice a phone being plugged in later.
    private var isDeviceBusy: Bool {
        isProcessingArtworkQueue || isFlashing || isFetchingOriginals || isRestoring
    }

    public func startDevicePolling() {
        devicePollTask?.cancel()
        devicePollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDevice()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Sidebar refresh. Returns immediately; the USB query runs off the main thread.
    public func checkDevice() {
        Task { await refreshDevice(userInitiated: true) }
    }

    private func refreshDevice(userInitiated: Bool = false) async {
        // Listing starts a lockdown session. Doing that while a read, flash, or
        // scan already holds the phone blocks inside AMDeviceStartSession.
        if isDeviceBusy && !userInitiated { return }
        guard !isCheckingDevice else { return }
        isCheckingDevice = true
        defer { isCheckingDevice = false }

        let list = await Task.detached(priority: .utility) {
            AirliftBridge.shared.listDevices()
        }.value
        guard !Task.isCancelled else { return }
        if isDeviceBusy && !userInitiated { return }

        if let first = list.first {
            missedDevicePolls = 0
            if device?.udid != first.udid || device?.connected != first.connected {
                device = first
                log("Connected to device: \(first.name ?? "iPhone")", level: .info)
                fetchAllOriginalArtworks()
                if !isScanningCards { startScanning() }
            }
        } else {
            missedDevicePolls += 1
            if missedDevicePolls >= 2, device != nil {
                log("Device disconnected.", level: .warning)
                stopScanning()
                device = nil
            }
        }
    }

    // MARK: - Logging

    public func log(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(level: level, message: message)
        logs.append(entry)
        if logs.count > 1000 {
            logs.removeFirst(100)
        }
    }

    public func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Card Library Persistence

    private func loadSavedCards() {
        guard FileManager.default.fileExists(atPath: cardsStoreURL.path),
              let data = try? Data(contentsOf: cardsStoreURL) else {
            return
        }

        struct StoredCard: Codable {
            let id: String
            let label: String
            let customImagePath: String?
        }

        if let list = try? JSONDecoder().decode([StoredCard].self, from: data) {
            let kept = list.filter { CardHashScanner.isValid($0.id) }
            self.cards = kept.map { stored in
                CardItem(
                    id: stored.id,
                    label: stored.label,
                    isSelected: true,
                    customImageURL: stored.customImagePath.map { URL(fileURLWithPath: $0) }
                )
            }
            self.selectedCardId = cards.first?.id
            if kept.count != list.count {
                saveCards()
            }
        }

        for card in cards {
            if let cached = CardAssetManager.shared.loadOriginal(for: card.id) {
                originalImages[card.id] = cached
            }
        }
    }

    func saveCards() {
        struct StoredCard: Codable {
            let id: String
            let label: String
            let customImagePath: String?
        }
        let list = cards.map {
            StoredCard(id: $0.id, label: $0.label, customImagePath: $0.customImageURL?.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(list) {
            try? data.write(to: cardsStoreURL)
        }
    }

    func addCardManually(id: String, label: String = "") {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanId = CardHashScanner.isValid(trimmed)
            ? trimmed
            : (CardHashScanner.hashes(in: trimmed).first ?? "")
        guard !cleanId.isEmpty else {
            errorMessage = "That is not a Wallet pass id. Paste the card hash, not the file path."
            return
        }
        guard !cards.contains(where: { $0.id == cleanId }) else {
            errorMessage = "Card already in library."
            return
        }
        let newCard = CardItem(id: cleanId, label: label, isSelected: true)
        cards.append(newCard)
        selectedCardId = cleanId
        saveCards()
        log("Added card manually: \(cleanId)", level: .info)
        loadOriginalArtwork(for: newCard)
    }

    func deleteCard(id: String) {
        cards.removeAll(where: { $0.id == id })
        originalImages.removeValue(forKey: id)
        artworkFetchQueue.removeAll(where: { $0 == id })
        loadingImages.remove(id)
        CardAssetManager.shared.clearCachedCustom(cardHash: id)
        if selectedCardId == id {
            selectedCardId = cards.first?.id
        }
        saveCards()
        log("Removed card: \(id.prefix(12))...", level: .info)
    }

    // MARK: - Native Artwork Loading (Serial Queue to prevent AirTraffic collisions)

    private var artworkFetchQueue: [String] = []
    private var isProcessingArtworkQueue = false
    /// The set an explicit "Fetch All Originals" run was asked to cover.
    private var fetchAllTargets: Set<String> = []

    func fetchAllOriginalArtworks() {
        guard let dev = device, dev.connected else { return }
        for card in cards {
            if originalImages[card.id] == nil {
                enqueueArtworkFetch(for: card.id)
            }
        }
        // Entries queued while no device was attached are still waiting here.
        processArtworkQueue()
    }

    /// Toolbar action: pull the factory artwork of every card that has none
    /// stored yet, so each one becomes independently restorable and exportable.
    func fetchAllOriginals() {
        guard let dev = device, dev.connected else {
            errorMessage = "No iPhone connected."
            return
        }

        let pending = cards.filter { !CardAssetManager.shared.hasOriginal(for: $0.id) }
        guard !pending.isEmpty else {
            successAlertTitle = "Nothing to Fetch"
            successAlertMessage = "All \(cards.count) card(s) already have their original artwork stored on this Mac."
            showSuccessAlert = true
            return
        }

        fetchAllTargets = Set(pending.map { $0.id })
        isFetchingOriginals = true
        progress = 0
        statusText = "Fetching \(pending.count) original(s) from iPhone..."
        log("Fetching \(pending.count) missing original(s) from iPhone...", level: .info)

        for card in pending {
            artworkFetchQueue.append(card.id)
        }
        processArtworkQueue()
    }

    func loadOriginalArtwork(for card: CardItem) {
        guard CardHashScanner.isValid(card.id) else { return }
        enqueueArtworkFetch(for: card.id)
    }

    private func enqueueArtworkFetch(for cardId: String) {
        // An original already on disk is the backup; show it without hitting AirTraffic.
        if let stored = CardAssetManager.shared.loadOriginal(for: cardId) {
            originalImages[cardId] = stored
            return
        }
        guard !artworkFetchQueue.contains(cardId) else {
            processArtworkQueue()
            return
        }
        artworkFetchQueue.append(cardId)
        processArtworkQueue()
    }

    private func processArtworkQueue() {
        guard !isProcessingArtworkQueue else { return }
        guard let dev = device, dev.connected else { return }
        guard !artworkFetchQueue.isEmpty else { return }

        let cardId = artworkFetchQueue.removeFirst()
        loadingImages.insert(cardId)
        isProcessingArtworkQueue = true

        let udid = dev.udid
        let label = cards.first(where: { $0.id == cardId })?.label ?? cardId

        log("Fetching card background from iPhone for [\(label)]...", level: .info)

        Task.detached(priority: .userInitiated) {
            let data = await CardAssetManager.shared.fetchOriginalArtworkData(udid: udid, cardHash: cardId)
            // Small pause between AirTraffic operations so iOS finishes session
            try? await Task.sleep(nanoseconds: 400_000_000)

            await MainActor.run {
                self.loadingImages.remove(cardId)
                self.isProcessingArtworkQueue = false

                if let data = data, let image = NSImage(data: data) {
                    self.originalImages[cardId] = image
                    self.log("✓ Successfully loaded artwork for [\(label)]", level: .success)
                } else {
                    self.log("Artwork not found on device for [\(label)] (or pass format is vector)", level: .warning)
                }

                self.advanceFetchAllProgress()

                // Process next in serial queue
                self.processArtworkQueue()
            }
        }
    }

    /// Advances the "Fetch All Originals" progress bar. Counts originals that
    /// actually landed rather than queue length, because other callers share the
    /// queue. Closes out once the queue drains so the banner never sticks.
    private func advanceFetchAllProgress() {
        guard isFetchingOriginals, !fetchAllTargets.isEmpty else { return }

        let done = fetchAllTargets.filter { CardAssetManager.shared.hasOriginal(for: $0) }.count
        progress = min(1.0, Double(done) / Double(fetchAllTargets.count))

        guard artworkFetchQueue.isEmpty, !isProcessingArtworkQueue, done >= fetchAllTargets.count else { return }
        isFetchingOriginals = false
        fetchAllTargets = []
        progress = 1.0

        let stillMissing = cards.filter { !CardAssetManager.shared.hasOriginal(for: $0.id) }
        statusText = stillMissing.isEmpty
            ? "Fetched all originals."
            : "Fetched with \(stillMissing.count) still missing."
        log(statusText, level: stillMissing.isEmpty ? .success : .warning)

        if !stillMissing.isEmpty {
            successAlertTitle = "Fetch Complete"
            successAlertMessage = "These cards have no bank artwork to extract:\n\n"
                + stillMissing.map { "• \($0.label) (\($0.id.prefix(8)))" }.joined(separator: "\n")
            showSuccessAlert = true
        }
    }

    // MARK: - Custom Skin Assignment

    func setCustomSkin(for cardId: String, imageURL: URL) {
        guard let idx = cards.firstIndex(where: { $0.id == cardId }) else { return }
        guard let image = NSImage(contentsOf: imageURL) else {
            errorMessage = "Could not load selected image."
            return
        }

        if let pngData = CardAssetManager.shared.renderAspectFill(image: image, targetSize: CardAssetManager.cardTargetSize3x).flatMap({ CardAssetManager.shared.cgImageToPNG(cgImage: $0) }) {
            CardAssetManager.shared.saveCachedCustom(cardHash: cardId, data: pngData)
        }

        cards[idx].customImageURL = imageURL
        saveCards()
        log("Assigned custom skin to [\(cards[idx].label)]", level: .info)
    }

    func clearCustomSkin(for cardId: String) {
        if let idx = cards.firstIndex(where: { $0.id == cardId }) {
            cards[idx].customImageURL = nil
            CardAssetManager.shared.clearCachedCustom(cardHash: cardId)
            saveCards()
            log("Cleared custom skin for [\(cards[idx].label)]", level: .info)
        }
    }

    func setCustomSkinForSelectedCards(imageURL: URL) {
        let selectedIndices = cards.indices.filter { cards[$0].isSelected }
        guard !selectedIndices.isEmpty else {
            errorMessage = "No cards selected. Select cards first."
            return
        }

        guard let image = NSImage(contentsOf: imageURL) else {
            errorMessage = "Could not load selected image."
            return
        }

        let renderData = CardAssetManager.shared.renderAspectFill(image: image, targetSize: CardAssetManager.cardTargetSize3x).flatMap { CardAssetManager.shared.cgImageToPNG(cgImage: $0) }

        for idx in selectedIndices {
            cards[idx].customImageURL = imageURL
            if let data = renderData {
                CardAssetManager.shared.saveCachedCustom(cardHash: cards[idx].id, data: data)
            }
        }
        saveCards()
        log("Assigned skin to \(selectedIndices.count) card(s)", level: .info)
    }

    func setBulkSkin(imageURL: URL) {
        setCustomSkinForSelectedCards(imageURL: imageURL)
    }

    func selectAllCards(_ select: Bool) {
        for idx in cards.indices {
            cards[idx].isSelected = select
        }
    }

    // MARK: - Real-Time Card Scanner (Syslog Tap Detection)

    func toggleScanning() {
        if isScanningCards {
            stopScanning()
        } else {
            startScanning()
        }
    }

    func startScanning() {
        guard let dev = device, dev.connected else {
            errorMessage = "Please connect your iPhone via USB first."
            return
        }
        guard scanProcess == nil else { return }
        guard let helper = AirliftBridge.findDeviceHelper() else {
            errorMessage = "Internal device helper binary not found."
            return
        }

        isScanningCards = true
        statusText = "Scanning active. Double-click iPhone Side button and tap your card..."
        log("Started real-time card scanner on \(dev.name ?? "iPhone")...", level: .info)

        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = helper
        proc.arguments = ["syslog", dev.udid]
        proc.standardOutput = pipe
        proc.standardError = pipe
        self.scanProcess = proc

        do {
            try proc.run()
        } catch {
            isScanningCards = false
            statusText = "Scanner failed to launch."
            log("Syslog process failed: \(error.localizedDescription)", level: .error)
            return
        }

        Task.detached {
            let handle = pipe.fileHandleForReading
            var buffer = Data()

            while true {
                let chunk = (try? handle.read(upToCount: 65536)) ?? Data()
                if chunk.isEmpty {
                    if buffer.isEmpty { break }
                    buffer.append(0x0A)
                } else {
                    buffer.append(chunk)
                }

                while let newlineRange = buffer.range(of: Data([0x0A])) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                    buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)

                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    let lower = line.lowercased()

                    let isWallet = lower.contains("passd") || lower.contains("passbook") ||
                                   lower.contains("passkit") || lower.contains("stockholm") ||
                                   lower.contains("nanopassd") || lower.contains("wallet") ||
                                   lower.contains("passids") || lower.contains("/cards/")

                    guard isWallet || CardHashScanner.quotedPassID(in: line) != nil else { continue }

                    let detected = CardHashScanner.hashes(in: line)
                    guard !detected.isEmpty else { continue }

                    await MainActor.run {
                        for candidate in detected where !self.cards.contains(where: { $0.id == candidate }) {
                            let newCard = CardItem(id: candidate, isSelected: true)
                            self.cards.append(newCard)
                            self.saveCards()
                            self.log("✓ Detected card: \(candidate)", level: .success)
                            NSSound(named: "Glass")?.play()
                            // Artwork reading skipped during scan for safety
                        }
                    }
                }
                if chunk.isEmpty { break }
            }

            proc.waitUntilExit()
            await MainActor.run {
                guard self.scanProcess === proc else { return }
                self.scanProcess = nil
                self.isScanningCards = false
                self.statusText = "Scanner stopped."
                self.log("Card scanner session ended.", level: .info)
            }
        }
    }

    func stopScanning() {
        let proc = scanProcess
        scanProcess = nil
        if let proc, proc.isRunning { proc.terminate() }
        isScanningCards = false
        statusText = "Ready"
        log("Scanner stopped.", level: .info)
    }

    // MARK: - Flash Skins (Pure Swift Native)

    func flashSelectedCards() {
        guard let dev = device, dev.connected else {
            errorMessage = "No iPhone connected."
            return
        }

        let readyCards = cards.filter { $0.isSelected && $0.customImageURL != nil }
        guard !readyCards.isEmpty else {
            errorMessage = "No selected cards have a custom skin assigned."
            return
        }

        isFlashing = true
        progress = 0.0
        statusText = "Flashing \(readyCards.count) card(s)..."
        log("Starting native skin flash for \(readyCards.count) card(s)...", level: .info)

        let udid = dev.udid
        Task.detached(priority: .userInitiated) {
            var anyFailed = false
            let total = Double(readyCards.count)

            for (idx, card) in readyCards.enumerated() {
                guard let imageURL = card.customImageURL,
                      let image = NSImage(contentsOf: imageURL) else {
                    anyFailed = true
                    await MainActor.run {
                        self.log("  ✗ Skin image is missing for \(card.label) (\(card.id.prefix(12))...), skipped", level: .error)
                    }
                    continue
                }

                await MainActor.run {
                    self.statusText = "[\(idx + 1)/\(readyCards.count)] Preparing assets for \(card.label)..."
                    self.progress = Double(idx) / total
                    self.log("Flashing card [\(idx + 1)/\(readyCards.count)]: \(card.label) (\(card.id.prefix(12))...)")
                }

                guard let assets = CardAssetManager.shared.prepareCardAssets(from: image) else {
                    await MainActor.run {
                        self.log("Failed to render assets for \(card.label)", level: .error)
                    }
                    anyFailed = true
                    continue
                }

                let pkpassDir = "/var/mobile/Library/Passes/Cards/\(card.id).pkpass"
                let filesToWrite: [(leaf: String, payload: Data)] = [
                    ("cardBackgroundCombined@3x.png", assets.png3x),
                    ("cardBackgroundCombined@2x.png", assets.png2x),
                    ("cardBackgroundCombined.pdf", assets.pdf)
                ]

                await MainActor.run {
                    self.log("  Writing 3 artwork assets via fast batch...")
                }

                let writeOk = AirliftBridge.shared.writeFilesBatch(
                    udid: udid,
                    target: pkpassDir,
                    files: filesToWrite,
                    retries: 3
                )

                if !writeOk {
                    anyFailed = true
                    await MainActor.run {
                        self.log("  ✗ Failed writing assets to \(card.label)", level: .error)
                    }
                    continue
                }

                await MainActor.run {
                    self.log("  Invalidating system render caches (.cache / .pkcache)...")
                }

                let cacheOk = AirliftBridge.shared.invalidateCache(udid: udid, cardHash: card.id)
                if !cacheOk {
                    await MainActor.run {
                        self.log("  ⚠ Cache invalidation warning for \(card.label). Pass was written but reboot may be needed.", level: .warning)
                    }
                } else {
                    await MainActor.run {
                        self.log("  ✓ Successfully updated \(card.label)!", level: .success)
                    }
                }
            }

            let failed = anyFailed
            await MainActor.run {
                self.isFlashing = false
                self.progress = 1.0
                if failed {
                    self.statusText = "Flash completed with warnings. Check logs."
                    self.errorMessage = "One or more cards could not be flashed completely."
                } else {
                    self.statusText = "Flash complete!"
                    self.successAlertTitle = "Skins Applied!"
                    self.successAlertMessage = "Your custom card skins were successfully flashed to Apple Wallet!\n\nPlease force-close the Wallet app on your iPhone (or lock & unlock) to view your new designs."
                    self.showSuccessAlert = true
                    self.log("🎉 All selected card skins successfully flashed!", level: .success)
                }
            }
        }
    }

    // MARK: - Original Artwork: Export & Restore

    /// A card is backed up exactly when its original PNG sits in Originals/.
    func hasOriginal(for cardId: String) -> Bool {
        CardAssetManager.shared.hasOriginal(for: cardId)
    }

    func revealOriginalsInFinder() {
        NSWorkspace.shared.selectFile(
            nil,
            inFileViewerRootedAtPath: CardAssetManager.shared.originalsRootURL.path
        )
    }

    // MARK: Export

    /// Single card: asks for a destination, then writes the stored PNG there.
    func exportOriginalPNG(cardId: String) {
        guard let card = cards.first(where: { $0.id == cardId }) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = CardExporter.proposedFilename(label: card.label, cardHash: card.id)
        panel.canCreateDirectories = true
        panel.prompt = "Export Original"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        statusText = "Exporting \(card.label)..."

        Task { @MainActor in
            let data = await originalPNG(for: card.id)
            isExporting = false

            guard let data = data else {
                statusText = "Export failed."
                errorMessage = "No bank artwork available for '\(card.label)'. Connect your iPhone and try again."
                return
            }

            guard CardExporter.write(png: data, to: url) else {
                statusText = "Export failed."
                errorMessage = "Could not write to \(url.path)."
                return
            }

            statusText = "Exported \(card.label)."
            successAlertTitle = "Export Complete"
            successAlertMessage = "Saved \(url.lastPathComponent)"
            showSuccessAlert = true
            log("✓ Exported original for [\(card.label)] → \(url.lastPathComponent)", level: .success)
        }
    }

    /// Batch: one PNG per selected card, dropped into a chosen folder.
    func exportSelectedOriginals() {
        let selected = cards.filter { $0.isSelected }
        guard !selected.isEmpty else {
            errorMessage = "Select at least one card to export."
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Export Folder"

        guard panel.runModal() == .OK, let directory = panel.url else { return }

        isExporting = true
        progress = 0

        Task { @MainActor in
            var written: [String] = []
            var missing: [String] = []

            for (idx, card) in selected.enumerated() {
                statusText = "Exporting \(card.label) (\(idx + 1)/\(selected.count))..."
                progress = Double(idx) / Double(selected.count)

                guard let data = await originalPNG(for: card.id) else {
                    missing.append(card.label)
                    continue
                }

                let filename = CardExporter.proposedFilename(label: card.label, cardHash: card.id)
                let destination = CardExporter.uniqueDestination(in: directory, filename: filename)
                if CardExporter.write(png: data, to: destination) {
                    written.append(destination.lastPathComponent)
                } else {
                    missing.append(card.label)
                }
            }

            isExporting = false
            progress = 1.0
            statusText = "Exported \(written.count)/\(selected.count) original(s)."

            if missing.isEmpty {
                successAlertTitle = "Export Complete"
                successAlertMessage = "Wrote \(written.count) PNG file(s) to:\n\(directory.path)"
            } else {
                successAlertTitle = "Exported with Warnings"
                successAlertMessage = "Wrote \(written.count) PNG file(s) to:\n\(directory.path)\n\nNo original available for:\n"
                    + missing.map { "• \($0)" }.joined(separator: "\n")
            }
            showSuccessAlert = true
            log(
                "✓ Exported \(written.count)/\(selected.count) original(s) to \(directory.lastPathComponent)",
                level: missing.isEmpty ? .success : .warning
            )
        }
    }

    /// Stored PNG if there is one, otherwise queued behind the serial artwork
    /// fetch. Going through the queue matters: AirTraffic sync cannot run two
    /// relocations against the same phone at once.
    private func originalPNG(for cardId: String) async -> Data? {
        if let stored = CardAssetManager.shared.originalPNGData(for: cardId) {
            return stored
        }
        guard device?.connected == true else { return nil }

        enqueueArtworkFetch(for: cardId)

        // AirTraffic round trips take seconds, not milliseconds. Bounded so a
        // card that never yields artwork cannot hang the export forever.
        for _ in 0..<600 {
            if let stored = CardAssetManager.shared.originalPNGData(for: cardId) {
                return stored
            }
            let stillWorking = artworkFetchQueue.contains(cardId) || loadingImages.contains(cardId)
            if !stillWorking { return nil }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return CardAssetManager.shared.originalPNGData(for: cardId)
    }

    // MARK: Restore

    func restoreCard(cardHash: String) {
        guard let dev = device, dev.connected else {
            errorMessage = "No iPhone connected."
            return
        }
        guard CardAssetManager.shared.hasOriginal(for: cardHash) else {
            errorMessage = "No original stored for this card yet. Fetch it first."
            return
        }

        isRestoring = true
        statusText = "Restoring card \(cardHash.prefix(12))... to original state..."

        let udid = dev.udid
        let label = cards.first(where: { $0.id == cardHash })?.label ?? String(cardHash.prefix(8))

        Task.detached(priority: .userInitiated) {
            let ok = await CardRestoreManager.shared.restoreCard(
                udid: udid,
                cardHash: cardHash,
                onLog: { msg in Task { @MainActor in self.log(msg, level: .info) } }
            )

            await MainActor.run {
                self.isRestoring = false
                guard ok else {
                    self.statusText = "Restoration failed."
                    self.errorMessage = "Failed to write original artwork for '\(label)' to the device."
                    return
                }

                if let idx = self.cards.firstIndex(where: { $0.id == cardHash }) {
                    self.cards[idx].customImageURL = nil
                    self.saveCards()
                }
                self.statusText = "Card restored to original!"
                self.successAlertTitle = "Restoration Complete"
                self.successAlertMessage = "Original artwork restored to Apple Wallet! Force-close the Wallet app on your iPhone to verify."
                self.showSuccessAlert = true
            }
        }
    }

    /// Rebuilds every card that has an original stored. Cards without one are
    /// skipped rather than failing the run.
    func restoreAllCards() {
        guard let dev = device, dev.connected else {
            errorMessage = "No iPhone connected."
            return
        }
        guard !isScanningCards else {
            errorMessage = "Please stop the card scanner before restoring."
            return
        }

        let restorable = cards.filter { CardAssetManager.shared.hasOriginal(for: $0.id) }
        guard !restorable.isEmpty else {
            errorMessage = "No cards have an original stored yet. Fetch originals first."
            return
        }

        isRestoring = true
        statusText = "Restoring \(restorable.count) card(s)..."
        log("Starting bulk restore of \(restorable.count) card(s)...", level: .info)

        let udid = dev.udid
        Task.detached(priority: .userInitiated) {
            var restored = 0

            for (idx, card) in restorable.enumerated() {
                await MainActor.run {
                    self.statusText = "Restoring [\(idx + 1)/\(restorable.count)]: \(card.label)..."
                    self.progress = Double(idx) / Double(restorable.count)
                }

                let ok = await CardRestoreManager.shared.restoreCard(
                    udid: udid,
                    cardHash: card.id,
                    onLog: { msg in Task { @MainActor in self.log(msg, level: .info) } }
                )
                if ok { restored += 1 }
            }

            let finalCount = restored
            await MainActor.run {
                self.isRestoring = false
                self.progress = 1.0
                self.statusText = "Restore complete: \(finalCount)/\(restorable.count) cards."
                self.successAlertTitle = "Cards Restored"
                self.successAlertMessage = "Successfully restored \(finalCount) card(s) to factory artwork on your iPhone!\n\nPlease force close the Wallet app on your iPhone (swipe up in app switcher) and reopen it."
                self.showSuccessAlert = true
                self.log("✓ Bulk restore finished (\(finalCount)/\(restorable.count) cards).", level: .success)
            }
        }
    }
}
