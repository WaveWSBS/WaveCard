import Foundation
import SwiftUI
import AppKit
import Combine

/// Central application state manager for AirCard (macOS HIG).
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
    @Published public var isBackingUp: Bool = false
    @Published public var isRestoring: Bool = false
    @Published public var progress: Double = 0.0
    @Published public var statusText: String = "Ready"

    // MARK: - Backups State
    @Published public var backups: [CardBackup] = []

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

    // MARK: - Internal Timers & Processes
    private var devicePollTask: Task<Void, Never>?
    private var missedDevicePolls = 0
    private var scanProcess: Process?
    private let cardsStoreURL: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let aircardDir = appSupport.appendingPathComponent("AirCard", isDirectory: true)
        try? FileManager.default.createDirectory(at: aircardDir, withIntermediateDirectories: true)
        self.cardsStoreURL = aircardDir.appendingPathComponent("saved_cards.json")

        loadSavedCards()
        refreshBackups()
        startDevicePolling()
    }

    deinit {
        devicePollTask?.cancel()
        scanProcess?.terminate()
    }

    // MARK: - Device Polling

    private var isDeviceBusy: Bool {
        isProcessingArtworkQueue || !artworkFetchQueue.isEmpty || isFlashing || isBackingUp || isRestoring || isScanningCards
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
            }
        } else {
            missedDevicePolls += 1
            if missedDevicePolls >= 2, device != nil {
                log("Device disconnected.", level: .warning)
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
        }

        if let list = try? JSONDecoder().decode([StoredCard].self, from: data) {
            let kept = list.filter { CardHashScanner.isValid($0.id) }
            self.cards = kept.map { CardItem(id: $0.id, label: $0.label, isSelected: true) }
            self.selectedCardId = cards.first?.id
            if kept.count != list.count {
                saveCards()
            }
        }

        for card in cards {
            if let cached = CardAssetManager.shared.loadCachedOriginal(for: card.id) {
                originalImages[card.id] = cached
            }
        }
    }

    func saveCards() {
        struct StoredCard: Codable {
            let id: String
            let label: String
        }
        let list = cards.map { StoredCard(id: $0.id, label: $0.label) }
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

    func fetchAllOriginalArtworks() {
        guard let dev = device, dev.connected else { return }
        for card in cards {
            if originalImages[card.id] == nil {
                enqueueArtworkFetch(for: card.id)
            }
        }
    }

    func loadOriginalArtwork(for card: CardItem) {
        guard CardHashScanner.isValid(card.id) else { return }
        enqueueArtworkFetch(for: card.id)
    }

    private func enqueueArtworkFetch(for cardId: String) {
        // If already cached locally, load immediately into memory without hitting AirTraffic
        if let cached = CardAssetManager.shared.loadCachedOriginal(for: cardId) {
            originalImages[cardId] = cached
            return
        }
        guard !artworkFetchQueue.contains(cardId) else { return }
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

                // Process next in serial queue
                self.processArtworkQueue()
            }
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
                                   lower.contains("/cards/")

                    guard isWallet else { continue }

                    let detected = CardHashScanner.hashes(in: line)
                    guard !detected.isEmpty else { continue }

                    await MainActor.run {
                        guard self.scanProcess === proc else { return }
                        for candidate in detected where !self.cards.contains(where: { $0.id == candidate }) {
                            let newCard = CardItem(id: candidate, isSelected: true)
                            self.cards.append(newCard)
                            self.saveCards()
                            self.log("✓ Detected card: \(candidate)", level: .success)
                            NSSound(named: "Glass")?.play()
                            self.loadOriginalArtwork(for: newCard)
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

    // MARK: - Backup & Restore Operations

    func refreshBackups() {
        self.backups = CardBackupManager.shared.listBackups()
    }

    func backupCard(cardId: String) {
        guard let dev = device, dev.connected else {
            errorMessage = "No iPhone connected."
            return
        }
        guard let card = cards.first(where: { $0.id == cardId }) else { return }

        isBackingUp = true
        statusText = "Backing up original artwork for \(card.label)..."

        Task.detached(priority: .userInitiated) {
            let ok = await CardBackupManager.shared.backupCard(
                udid: dev.udid,
                cardHash: card.id,
                label: card.label,
                device: dev,
                onLog: { msg in
                    Task { @MainActor in self.log(msg, level: .info) }
                }
            )

            await MainActor.run {
                self.isBackingUp = false
                self.refreshBackups()
                if ok {
                    self.statusText = "Backup saved to Documents/AirCard/Backups"
                    self.successAlertTitle = "Backup Complete"
                    self.successAlertMessage = "Original card artwork for '\(card.label)' has been saved safely to your Mac.\n\nYou can restore it anytime with one click."
                    self.showSuccessAlert = true
                } else {
                    self.statusText = "Backup failed."
                    self.errorMessage = "Could not extract card files from device."
                }
            }
        }
    }

    func backupSelectedCards() {
        let selected = cards.filter { $0.isSelected }
        guard !selected.isEmpty else {
            errorMessage = "Select at least one card to back up."
            return
        }
        guard let dev = device, dev.connected else {
            errorMessage = "No iPhone connected."
            return
        }

        isBackingUp = true
        statusText = "Backing up \(selected.count) card(s)..."

        Task.detached(priority: .userInitiated) {
            var count = 0
            for card in selected {
                let ok = await CardBackupManager.shared.backupCard(
                    udid: dev.udid,
                    cardHash: card.id,
                    label: card.label,
                    device: dev,
                    onLog: { msg in
                        Task { @MainActor in self.log(msg, level: .info) }
                    }
                )
                if ok { count += 1 }
            }

            let savedCount = count
            await MainActor.run {
                self.isBackingUp = false
                self.refreshBackups()
                self.statusText = "Backed up \(savedCount)/\(selected.count) cards."
                self.successAlertTitle = "Backup Complete"
                self.successAlertMessage = "\(savedCount) card original(s) successfully backed up to Documents/AirCard/Backups."
                self.showSuccessAlert = true
            }
        }
    }

    func restoreCard(cardHash: String) {
        guard let dev = device, dev.connected else {
            errorMessage = "No iPhone connected."
            return
        }

        isRestoring = true
        statusText = "Restoring card \(cardHash.prefix(12))... to original state..."

        Task.detached(priority: .userInitiated) {
            let ok = await CardBackupManager.shared.restoreCard(
                udid: dev.udid,
                cardHash: cardHash,
                onLog: { msg in
                    Task { @MainActor in self.log(msg, level: .info) }
                }
            )

            await MainActor.run {
                self.isRestoring = false
                if ok {
                    if let idx = self.cards.firstIndex(where: { $0.id == cardHash }) {
                        self.cards[idx].customImageURL = nil
                        self.saveCards()
                    }
                    self.statusText = "Card restored to original!"
                    self.successAlertTitle = "Restoration Complete"
                    self.successAlertMessage = "Original artwork restored to Apple Wallet! Force-close the Wallet app on your iPhone to verify."
                    self.showSuccessAlert = true
                } else {
                    self.statusText = "Restoration failed."
                    self.errorMessage = "Failed to restore original pass files to device."
                }
            }
        }
    }
}
