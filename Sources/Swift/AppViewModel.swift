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
    @Published public var walletPreviews: [String: WalletPreview] = [:]
    @Published public var loadingImages: Set<String> = []

    // MARK: - Scanning & Operations State
    @Published public var isScanningCards: Bool = false
    @Published public private(set) var isStoppingScanner = false
    @Published public private(set) var isReadingArtwork = false
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
    private var observedScanIDs: Set<String> = []
    private var metadataNameTask: Task<Void, Never>?
    private var walletPreviewTask: Task<Void, Never>?
    private let walletMetadataRoot: URL?
    private var scanWhenIdle = false
    private let cardsStoreURL: URL
    private let artworkFetcher: @Sendable (String, String) async throws -> Data?

    public init(storageDirectory: URL? = nil, startPolling: Bool = true, walletMetadataRoot: URL? = nil,
                artworkFetcher: @escaping @Sendable (String, String) async throws -> Data? = { udid, cardID in
                    try await CardAssetManager.shared.fetchOriginalArtworkData(udid: udid, cardHash: cardID)
                }) {
        self.artworkFetcher = artworkFetcher
        self.walletMetadataRoot = walletMetadataRoot ?? (storageDirectory == nil
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Passes") : nil)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let wavecardDir = storageDirectory ?? appSupport.appendingPathComponent("WaveCard", isDirectory: true)
        try? FileManager.default.createDirectory(at: wavecardDir, withIntermediateDirectories: true)
        self.cardsStoreURL = wavecardDir.appendingPathComponent("saved_cards.json")

        // Collapse the old cache + Backups dumps into one PNG per card before
        // anything reads them.
        if storageDirectory == nil {
            let migration = CardAssetManager.shared.migrateLegacyOriginalsOnce()
            if migration.migrated > 0 {
                log("Migrated \(migration.migrated) original(s) into ~/Documents/WaveCard/Originals.", level: .success)
            }
        }

        loadSavedCards()
        refreshWalletPreviews()
        if startPolling { startDevicePolling() }
    }

    deinit {
        metadataNameTask?.cancel()
        walletPreviewTask?.cancel()
        devicePollTask?.cancel()
        scanProcess?.terminate()
    }

    // MARK: - Device Polling

    /// Only work that already holds a lockdown session blocks a USB poll. Pending
    /// artwork queue entries hold nothing, and counting them wedges the poller:
    /// with no device connected the queue cannot drain, so `refreshDevice` would
    /// never notice a phone being plugged in later.
    private var isDeviceBusy: Bool {
        // `isFetchingOriginals` is a run flag, not a session: counting it would
        // stop the poller from seeing a disconnect mid-run, freezing the run.
        isReadingArtwork || isFlashing || isRestoring || isStoppingScanner || isScanningCards
    }

    public var canStartScanning: Bool {
        device?.connected == true && !isDeviceBusy && !isCheckingDevice && artworkFetchQueue.isEmpty && !artworkRecoveryRequired
    }

    /// App termination does not reliably deinitialize SwiftUI state objects.
    /// Close our read-only log child explicitly without starting queued work.
    func stopBackgroundActivityForTermination() {
        devicePollTask?.cancel()
        metadataNameTask?.cancel()
        walletPreviewTask?.cancel()
        scanWhenIdle = false
        let process = scanProcess
        scanProcess = nil
        isScanningCards = false
        if process?.isRunning == true { process?.terminate() }
    }

    public var canRefreshDevice: Bool { !isDeviceBusy && !isCheckingDevice }

    public var canStartDeviceOperation: Bool {
        device?.connected == true && !isDeviceBusy && !isScanningCards && !isCheckingDevice && !artworkRecoveryRequired
    }

    private func requireIdleDevice() -> Bool {
        guard let dev = device, dev.connected else {
            errorMessage = "No iPhone connected."
            return false
        }
        guard !isDeviceBusy, !isScanningCards, !isCheckingDevice else {
            errorMessage = "Please finish the current device operation or stop scanning first."
            return false
        }
        if !artworkRecoveryRequired { detectPendingRecovery(udid: dev.udid) }
        guard !artworkRecoveryRequired else {
            errorMessage = "Device operations paused. See Logs for retained recovery details."
            return false
        }
        return true
    }

    private func detectPendingRecovery(udid: String) {
        let pending = AirliftBridge.shared.pendingRecoveryDirectories(udid: udid)
        guard !pending.isEmpty else { return }
        artworkRecoveryRequired = true
        scanWhenIdle = false
        artworkFetchQueue.removeAll()
        for directory in pending { log("Unresolved recovery workspace: \(directory.path)", level: .error) }
        errorMessage = "A previous device operation has an unresolved recovery snapshot. Reads and writes are paused; see Logs."
    }

    @discardableResult
    private func handleDeviceFailures(_ failures: [AirliftReadFailure]) -> Bool {
        for failure in failures { log(failure.message, level: .error) }
        guard failures.contains(where: { $0.requiresRecovery }) else { return false }
        artworkRecoveryRequired = true
        scanWhenIdle = false
        artworkFetchQueue.removeAll()
        advanceFetchAllProgress()
        errorMessage = "Device operations paused: restoration or cleanup could not be verified. See Logs for retained recovery details."
        return true
    }

    private func startScannerWhenIdle() {
        guard scanWhenIdle, artworkFetchQueue.isEmpty, !isDeviceBusy,
              !isCheckingDevice, device?.connected == true, !artworkRecoveryRequired else { return }
        scanWhenIdle = false
        startScanning()
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
        if isDeviceBusy { return }
        guard !isCheckingDevice else { return }
        isCheckingDevice = true
        defer {
            isCheckingDevice = false
            processArtworkQueue()
            startScannerWhenIdle()
        }

        let list = await Task.detached(priority: .utility) {
            AirliftBridge.shared.listDevices()
        }.value
        guard !Task.isCancelled else { return }
        if isDeviceBusy { return }

        if let first = list.first {
            missedDevicePolls = 0
            if device?.udid != first.udid || device?.connected != first.connected {
                device = first
                log("Connected to device: \(first.name ?? "iPhone")", level: .info)
                artworkRecoveryRequired = false
                detectPendingRecovery(udid: first.udid)
                scanWhenIdle = !artworkRecoveryRequired
                loadStoredArtworks()
                refreshMetadataNames()
                refreshWalletPreviews()
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

    /// Display images can come from Wallet's local render cache. They are kept
    /// separate from factory artwork and never authorize a restore or flash.
    func refreshWalletPreviews() {
        guard let root = walletMetadataRoot else { return }
        walletPreviewTask?.cancel()
        let ids = Set(cards.map(\.id))
        let product = device?.product ?? ""
        walletPreviewTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            let previews = await Task.detached(priority: .utility) {
                var images = WalletPreviewLoader.load(root: root, cardIDs: ids)
                let payments = WalletPaymentPreviewLoader.load(walletRoot: root, product: product, cardIDs: ids)
                images.merge(payments) { local, _ in local }
                return images
            }.value
            guard !Task.isCancelled, let self else { return }
            let currentIDs = Set(self.cards.map(\.id))
            self.walletPreviews = previews.filter { currentIDs.contains($0.key) }
            if !previews.isEmpty {
                self.log("Loaded \(self.walletPreviews.count) Wallet preview(s) for display.", level: .info)
            }
        }
    }

    /// Names are hints from a matched local Wallet cache, never a phone
    /// inventory. Only known IDs receive names; user labels remain untouched.
    func refreshMetadataNames() {
        guard let root = walletMetadataRoot, let dev = device, dev.connected,
              let product = dev.product else { return }
        metadataNameTask?.cancel()
        let ids = Set(cards.map(\.id))
        metadataNameTask = Task { [weak self] in
            // Coalesce bursts of Wallet records without delaying detection.
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            let names = await Task.detached(priority: .utility) {
                WalletMetadataCatalog.names(root: root, product: product, confirmedIDs: ids)
            }.value
            guard !Task.isCancelled, let self, self.device?.udid == dev.udid,
                  self.device?.connected == true else { return }
            var count = 0
            for index in self.cards.indices {
                let id = self.cards[index].id
                guard self.cards[index].label == "Card \(id.prefix(8))",
                      let name = names[id], !name.isEmpty else { continue }
                self.cards[index].label = name
                count += 1
            }
            if count > 0 {
                self.saveCards()
                self.log("Named \(count) known card(s) using local Wallet metadata.", level: .info)
            }
        }
    }

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
        refreshWalletPreviews()
        refreshMetadataNames()
    }

    func deleteCard(id: String) {
        cards.removeAll(where: { $0.id == id })
        originalImages.removeValue(forKey: id)
        walletPreviews.removeValue(forKey: id)
        artworkFetchQueue.removeAll(where: { $0 == id })
        // An active read still owns the device even if its card is removed.
        fetchAllTargets.remove(id)
        advanceFetchAllProgress()
        CardAssetManager.shared.clearCachedCustom(cardHash: id)
        if selectedCardId == id {
            selectedCardId = cards.first?.id
        }
        saveCards()
        log("Removed card: \(id.prefix(12))...", level: .info)
    }

    // MARK: - Native Artwork Loading (Serial Queue to prevent AirTraffic collisions)

    private var artworkFetchQueue: [String] = []
    private var artworkRecoveryRequired = false
    /// The set an explicit "Fetch All Originals" run was asked to cover.
    private var fetchAllTargets: Set<String> = []

    /// Connecting starts detection promptly; only explicit fetch actions may
    /// read device artwork. Unknown pass formats must not delay the scanner.
    private func loadStoredArtworks() {
        for card in cards {
            if let stored = CardAssetManager.shared.loadOriginal(for: card.id) {
                originalImages[card.id] = stored
            }
        }
    }

    /// Toolbar action: pull the factory artwork of every card that has none
    /// stored yet, so each one becomes independently restorable and exportable.
    func fetchAllOriginals() {
        guard requireIdleDevice() else { return }
        guard !artworkRecoveryRequired else {
            errorMessage = "Artwork reads paused. See Logs for the retained recovery snapshot."
            return
        }
        guard let dev = device, dev.connected else {
            errorMessage = "No iPhone connected."
            return
        }

        let missing = cards.filter { !CardAssetManager.shared.hasOriginal(for: $0.id) }
        // Tickets, IDs and other non-payment passes never carry bank artwork;
        // each probe would only spend several AirTraffic syncs on the phone.
        let nonPayment = walletMetadataRoot.map {
            WalletMetadataCatalog.nonPaymentPassIDs(root: $0, ids: Set(missing.map(\.id)))
        } ?? []
        let pending = missing.filter { !nonPayment.contains($0.id) }
        if !nonPayment.isEmpty {
            log("Skipping \(nonPayment.count) non-payment pass(es) (tickets, IDs, etc.): they have no bank artwork.", level: .info)
        }
        guard !pending.isEmpty else {
            successAlertTitle = "Nothing to Fetch"
            successAlertMessage = nonPayment.isEmpty
                ? "All \(cards.count) card(s) already have their original artwork stored on this Mac."
                : "Every payment card already has its original artwork stored on this Mac. \(nonPayment.count) non-payment pass(es) (tickets, IDs, etc.) were skipped because they have no bank artwork."
            showSuccessAlert = true
            return
        }

        fetchAllTargets = Set(pending.map { $0.id })
        isFetchingOriginals = true
        progress = 0
        statusText = "Fetching \(pending.count) original(s) from iPhone..."
        log("Fetching \(pending.count) missing original(s) from iPhone...", level: .info)

        for card in pending where !artworkFetchQueue.contains(card.id) && !loadingImages.contains(card.id) {
            artworkFetchQueue.append(card.id)
        }
        processArtworkQueue()
    }

    func loadOriginalArtwork(for card: CardItem) {
        guard CardHashScanner.isValid(card.id) else { return }
        if let stored = CardAssetManager.shared.loadOriginal(for: card.id) {
            originalImages[card.id] = stored
            return
        }
        guard requireIdleDevice() else { return }
        enqueueArtworkFetch(for: card.id)
    }

    private func enqueueArtworkFetch(for cardId: String) {
        // An original already on disk is the backup; show it without hitting AirTraffic.
        if let stored = CardAssetManager.shared.loadOriginal(for: cardId) {
            originalImages[cardId] = stored
            return
        }
        guard !artworkRecoveryRequired else {
            errorMessage = "Artwork reads paused because restoration or cleanup could not be verified. See Logs for the retained recovery snapshot."
            return
        }
        guard !loadingImages.contains(cardId), !artworkFetchQueue.contains(cardId) else {
            processArtworkQueue()
            return
        }
        artworkFetchQueue.append(cardId)
        processArtworkQueue()
    }

    private func processArtworkQueue() {
        guard !isDeviceBusy, !isCheckingDevice, !isScanningCards, !artworkRecoveryRequired else { return }
        guard let dev = device, dev.connected else { return }
        guard !artworkFetchQueue.isEmpty else { return }

        let cardId = artworkFetchQueue.removeFirst()
        loadingImages.insert(cardId)
        isReadingArtwork = true

        let udid = dev.udid
        let label = cards.first(where: { $0.id == cardId })?.label ?? cardId

        log("Fetching card background from iPhone for [\(label)]...", level: .info)

        let fetchArtwork = artworkFetcher
        Task.detached(priority: .userInitiated) {
            let data: Data?
            var failure: String?
            var recoveryRequired = false
            var unresponsive = false
            do {
                data = try await fetchArtwork(udid, cardId)
            } catch {
                data = nil
                failure = error.localizedDescription
                recoveryRequired = (error as? AirliftReadFailure)?.requiresRecovery == true
                unresponsive = (error as? AirliftReadFailure)?.deviceUnresponsive == true
            }
            let fetchFailure = failure
            let pauseForRecovery = recoveryRequired
            let stopForUnresponsiveDevice = unresponsive
            // Small pause between AirTraffic operations so iOS finishes session
            try? await Task.sleep(nanoseconds: 400_000_000)

            await MainActor.run {
                self.loadingImages.remove(cardId)
                self.isReadingArtwork = false

                if !self.cards.contains(where: { $0.id == cardId }) {
                    self.log("Artwork read finished for a card removed from the library.", level: .info)
                } else if let data = data, let image = NSImage(data: data) {
                    self.originalImages[cardId] = image
                    self.log("✓ Successfully loaded artwork for [\(label)]", level: .success)
                } else {
                    self.log("Artwork fetch for [\(label)] ended: \(fetchFailure ?? "No supported background was returned; pass type is unknown.")", level: .warning)
                }

                if pauseForRecovery {
                    self.artworkRecoveryRequired = true
                    self.artworkFetchQueue.removeAll()
                    self.errorMessage = "Artwork reads paused: restoration or cleanup could not be verified. See Logs for recovery details."
                } else if stopForUnresponsiveDevice {
                    // Every remaining read would wait out the same handshake.
                    let dropped = self.artworkFetchQueue.count
                    self.artworkFetchQueue.removeAll()
                    self.log("iPhone did not respond to the AirTraffic sync; stopped \(dropped) remaining artwork read(s).", level: .error)
                    self.errorMessage = "Your iPhone's sync service is not responding, so artwork reads were stopped. Unlock the iPhone, restart it, reconnect, and try again."
                }
                self.advanceFetchAllProgress()

                // Process next in serial queue
                self.processArtworkQueue()
                self.startScannerWhenIdle()
            }
        }
    }

    /// Advances the "Fetch All Originals" progress bar. A target counts as done
    /// once it has been attempted, whether or not artwork was found.
    /// Failed reads must also finish the run.
    private func advanceFetchAllProgress() {
        guard isFetchingOriginals else { return }

        let pending = fetchAllTargets.filter { artworkFetchQueue.contains($0) || loadingImages.contains($0) }.count
        let done = fetchAllTargets.count - pending
        progress = fetchAllTargets.isEmpty ? 1.0 : min(1.0, Double(done) / Double(fetchAllTargets.count))

        guard pending == 0 else { return }
        let attempted = fetchAllTargets
        isFetchingOriginals = false
        fetchAllTargets = []
        progress = 1.0

        // Skipped non-payment passes were never targets and are not failures.
        let stillMissing = cards.filter { attempted.contains($0.id) && !CardAssetManager.shared.hasOriginal(for: $0.id) }
        statusText = stillMissing.isEmpty
            ? "Fetched all originals."
            : "Fetched with \(stillMissing.count) still missing."
        log(statusText, level: stillMissing.isEmpty ? .success : .warning)

        if !stillMissing.isEmpty {
            successAlertTitle = "Fetch Complete"
            successAlertMessage = "Original artwork could not be fetched for these passes. See Logs for read failures or unsupported backgrounds:\n\n"
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
        guard canStartScanning else {
            errorMessage = "Please finish the current device operation before scanning."
            return
        }
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
        var environment = ProcessInfo.processInfo.environment
        environment["WAVECARD_SYSLOG_JSON"] = "1"
        proc.environment = environment
        proc.standardOutput = pipe
        proc.standardError = pipe
        observedScanIDs.removeAll()
        self.scanProcess = proc

        do {
            try proc.run()
        } catch {
            scanProcess = nil
            isScanningCards = false
            statusText = "Scanner failed to launch."
            log("Syslog process failed: \(error.localizedDescription)", level: .error)
            return
        }

        Task.detached {
            let handle = pipe.fileHandleForReading
            var buffer = Data()

            while true {
                // read(upToCount:) can wait to fill the requested size on a
                // pipe. The filtered Wallet stream may stay below that size
                // for minutes; consume bytes as soon as the helper emits them.
                let chunk = handle.availableData
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
                    if line.hasPrefix("WaveCard scanner:") {
                        await MainActor.run {
                            guard self.scanProcess === proc else { return }
                            self.log(line, level: line.contains("Connected") ? .info : .warning)
                        }
                        continue
                    }
                    // Each wire line contains one complete device record. JSON
                    // preserves NFC lists and resource paths on continuation lines.
                    let record: String
                    if let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                       let completeRecord = object["line"] as? String {
                        record = completeRecord
                    } else {
                        record = line // Compatibility with older helper binaries.
                    }
                    let detected = CardHashScanner.detectedPassIDs(inRecord: record)
                    guard !detected.isEmpty else { continue }

                    await MainActor.run {
                        guard self.scanProcess === proc else { return }
                        var discoveredNewCard = false
                        for candidate in detected where self.observedScanIDs.insert(candidate).inserted {
                            if let saved = self.cards.first(where: { $0.id == candidate }) {
                                self.log("Matched saved card: \(saved.label) (\(candidate.prefix(8))…)", level: .success)
                                continue
                            }
                            let newCard = CardItem(id: candidate, isSelected: true)
                            self.cards.append(newCard)
                            discoveredNewCard = true
                            self.saveCards()
                            self.log("✓ Detected card: \(candidate)", level: .success)
                            NSSound(named: "Glass")?.play()
                            // Artwork reading skipped during scan for safety
                        }
                        if discoveredNewCard {
                            self.refreshMetadataNames()
                            self.refreshWalletPreviews()
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
        scanWhenIdle = false
        let proc = scanProcess
        scanProcess = nil
        isScanningCards = false
        statusText = "Ready"
        log("Scanner stopped.", level: .info)
        guard let proc, proc.isRunning else {
            processArtworkQueue()
            return
        }
        isStoppingScanner = true
        proc.terminate()
        Task.detached {
            proc.waitUntilExit()
            await MainActor.run {
                self.isStoppingScanner = false
                self.processArtworkQueue()
            }
        }
    }

    // MARK: - Flash Skins (Pure Swift Native)

    func flashSelectedCards() {
        guard requireIdleDevice() else { return }
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

                var operationFailures: [AirliftReadFailure] = []
                let writeOk = AirliftBridge.shared.writeFilesBatch(
                    udid: udid,
                    target: pkpassDir,
                    files: filesToWrite,
                    retries: 3,
                    onFailure: { operationFailures.append($0) }
                )

                if !writeOk {
                    anyFailed = true
                    let failures = operationFailures
                    await MainActor.run {
                        self.log("  ✗ Failed writing assets to \(card.label); remaining cards were not attempted.", level: .error)
                        self.handleDeviceFailures(failures)
                    }
                    break
                }

                await MainActor.run {
                    self.log("  Invalidating system render caches (.cache / .pkcache)...")
                }

                let cacheOk = AirliftBridge.shared.invalidateCache(udid: udid, cardHash: card.id,
                    onFailure: { operationFailures.append($0) })
                if !cacheOk {
                    anyFailed = true
                    let failures = operationFailures
                    await MainActor.run {
                        self.log("  ⚠ Artwork was written for \(card.label), but cache invalidation failed. Remaining cards were not attempted.", level: .warning)
                        self.handleDeviceFailures(failures)
                    }
                    break
                } else {
                    await MainActor.run {
                        self.log("  ✓ Successfully updated \(card.label)!", level: .success)
                    }
                }
            }

            let failed = anyFailed
            await MainActor.run {
                self.isFlashing = false
                self.processArtworkQueue()
                self.startScannerWhenIdle()
                self.progress = 1.0
                if failed {
                    self.statusText = "Flash completed with warnings. Check logs."
                    if !self.artworkRecoveryRequired {
                        self.errorMessage = "Flashing stopped after a failure. See Logs for the affected card and stage."
                    }
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
        guard !isScanningCards, !isFlashing, !isRestoring, !isStoppingScanner else {
            log("Original artwork is not stored yet; finish the current device operation before exporting.", level: .warning)
            return nil
        }

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
        guard requireIdleDevice() else { return }
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
            var operationFailures: [AirliftReadFailure] = []
            let ok = await CardRestoreManager.shared.restoreCard(
                udid: udid,
                cardHash: cardHash,
                onLog: { msg in Task { @MainActor in self.log(msg, level: .info) } },
                onFailure: { operationFailures.append($0) }
            )

            let failures = operationFailures
            await MainActor.run {
                self.isRestoring = false
                self.handleDeviceFailures(failures)
                self.processArtworkQueue()
                self.startScannerWhenIdle()
                guard ok else {
                    self.statusText = "Restoration failed."
                    if !self.artworkRecoveryRequired {
                        self.errorMessage = "Restoration of '\(label)' did not complete. See Logs for the failed stage."
                    }
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
        guard requireIdleDevice() else { return }
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

                var operationFailures: [AirliftReadFailure] = []
                let ok = await CardRestoreManager.shared.restoreCard(
                    udid: udid,
                    cardHash: card.id,
                    onLog: { msg in Task { @MainActor in self.log(msg, level: .info) } },
                    onFailure: { operationFailures.append($0) }
                )
                if ok { restored += 1 }
                else {
                    let failures = operationFailures
                    await MainActor.run {
                        self.handleDeviceFailures(failures)
                        self.log("Bulk restore stopped after a failure; remaining cards were not attempted.", level: .error)
                    }
                    break
                }
            }

            let finalCount = restored
            await MainActor.run {
                self.isRestoring = false
                self.processArtworkQueue()
                self.startScannerWhenIdle()
                self.progress = 1.0
                self.statusText = "Restore complete: \(finalCount)/\(restorable.count) cards."
                let complete = finalCount == restorable.count
                self.successAlertTitle = complete ? "Cards Restored" : "Restore Incomplete"
                self.successAlertMessage = "Restored \(finalCount)/\(restorable.count) card(s)."
                    + (complete ? " Force-close Wallet and reopen it to view the artwork." : " Remaining cards were not attempted. See Logs for failure details.")
                if !self.artworkRecoveryRequired { self.showSuccessAlert = true }
                self.log("Bulk restore finished (\(finalCount)/\(restorable.count) cards).", level: complete ? .success : .warning)
            }
        }
    }
}
