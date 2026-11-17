import AppKit
import Foundation

private actor FetchProbe {
    private var continuation: CheckedContinuation<Data?, Error>?
    private(set) var requests = 0
    var waiting: Bool { continuation != nil }
    func fetch() async throws -> Data? {
        requests += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func complete(_ result: Result<Data?, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

@main
struct AppViewModelTest {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wavecard-vm-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let recoveryRoot = root.appendingPathComponent("recovery")
        setenv("WAVECARD_RECOVERY_ROOT", recoveryRoot.path, 1)
        defer { unsetenv("WAVECARD_RECOVERY_ROOT") }
        let cwd = fm.currentDirectoryPath
        fm.changeCurrentDirectoryPath(root.path) // Never resolve real device helpers.
        defer { fm.changeCurrentDirectoryPath(cwd); try? fm.removeItem(at: root) }
        var failed = 0
        func expect(_ ok: Bool, _ message: String) {
            print("\(ok ? "ok" : "not ok") - \(message)")
            if !ok { failed += 1 }
        }
        func wait(_ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
            return predicate()
        }
        func waitForProbe(_ probe: FetchProbe) async {
            let deadline = Date().addingTimeInterval(3)
            while !(await probe.waiting), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        func model(_ name: String, _ probe: FetchProbe) -> AppViewModel {
            let vm = AppViewModel(storageDirectory: root.appendingPathComponent(name), startPolling: false, walletMetadataRoot: root.appendingPathComponent("wallet-metadata")) { _, _ in
                try await probe.fetch()
            }
            vm.device = DeviceInfo(udid: "mock-device", name: "Mock", product: "iPhone", version: "test", connected: true)
            vm.cards = [CardItem(id: UUID().uuidString.replacingOccurrences(of: "-", with: ""))]
            return vm
        }

        let probe = FetchProbe()
        let vm = model("normal", probe)
        let card = vm.cards[0]
        vm.loadOriginalArtwork(for: card)
        await waitForProbe(probe)
        expect(vm.isReadingArtwork && !vm.canStartDeviceOperation, "active read disables competing device operations")
        vm.flashSelectedCards()
        vm.restoreCard(cardHash: card.id)
        vm.restoreAllCards()
        vm.fetchAllOriginals()
        vm.startScanning()
        vm.checkDevice()
        vm.loadOriginalArtwork(for: card)
        try? await Task.sleep(nanoseconds: 30_000_000)
        expect(!vm.isFlashing && !vm.isRestoring && !vm.isScanningCards && !vm.isFetchingOriginals && !vm.isCheckingDevice,
               "all public entry points reject overlap before accessing helpers")
        expect(await probe.requests == 1, "repeated fetch cannot duplicate an active read")
        await probe.complete(.success(nil))
        expect(await wait { !vm.isReadingArtwork }, "failed single read finishes")
        expect(vm.canStartDeviceOperation, "verified read completion releases the device gate")

        vm.errorMessage = nil
        vm.fetchAllOriginals()
        await waitForProbe(probe)
        expect(vm.isFetchingOriginals, "explicit batch tracks pending requests")
        await probe.complete(.failure(AirliftReadFailure(message: "mock transport failure")))
        expect(await wait { !vm.isFetchingOriginals && !vm.isReadingArtwork }, "failed batch ends after attempts rather than waiting for artwork")
        expect(vm.progress == 1 && vm.loadingImages.isEmpty, "failed batch clears spinner and reaches completion")

        vm.loadOriginalArtwork(for: card)
        await waitForProbe(probe)
        vm.deleteCard(id: card.id)
        expect(vm.isReadingArtwork && vm.loadingImages.contains(card.id), "deleting an active card does not release its device ownership")
        await probe.complete(.success(nil))
        expect(await wait { !vm.isReadingArtwork }, "deleted card read can finish normally")
        expect(vm.originalImages[card.id] == nil && vm.loadingImages.isEmpty, "completion does not resurrect a deleted card")

        let fatalProbe = FetchProbe()
        let fatal = model("fatal", fatalProbe)
        fatal.fetchAllOriginals()
        await waitForProbe(fatalProbe)
        await fatalProbe.complete(.failure(AirliftReadFailure(message: "retained recovery snapshot", requiresRecovery: true)))
        expect(await wait { !fatal.isReadingArtwork }, "unverified cleanup ends the active request")
        expect(!fatal.canStartDeviceOperation && !fatal.isFetchingOriginals, "unverified cleanup pauses further operations and ends batch progress")
        fatal.restoreAllCards()
        fatal.flashSelectedCards()
        expect(!fatal.isRestoring && !fatal.isFlashing, "recovery pause applies to writes as well as reads")

        // A handshake failure means the phone's sync service is stuck: the
        // remaining queue is dropped instead of timing out card after card.
        let stuckProbe = FetchProbe()
        let stuck = model("stuck", stuckProbe)
        stuck.cards.append(CardItem(id: UUID().uuidString.replacingOccurrences(of: "-", with: "")))
        stuck.cards.append(CardItem(id: UUID().uuidString.replacingOccurrences(of: "-", with: "")))
        stuck.fetchAllOriginals()
        await waitForProbe(stuckProbe)
        await stuckProbe.complete(.failure(AirliftReadFailure(message: "ReadyForSync not observed", deviceUnresponsive: true)))
        expect(await wait { !stuck.isFetchingOriginals && !stuck.isReadingArtwork }, "unresponsive device ends the batch")
        try? await Task.sleep(nanoseconds: 50_000_000)
        expect(await stuckProbe.requests == 1, "unresponsive device stops the remaining reads")
        expect(stuck.errorMessage?.contains("restart") == true, "unresponsive device asks for an iPhone restart")
        expect(stuck.canStartDeviceOperation, "a handshake failure leaves nothing to recover and does not lock the device")

        // Fetch All skips passes the Mac already knows are non-payment.
        let skipProbe = FetchProbe()
        let skipping = model("skipping", skipProbe)
        let ticketID = "TTTTTTTTTTTTTTTTTTTTTTTTTTTT"
        let ticketPass = root.appendingPathComponent("wallet-metadata/Cards/\(ticketID).pkpass")
        try fm.createDirectory(at: ticketPass, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["organizationName": "Fixture", "eventTicket": [:]] as [String: Any])
            .write(to: ticketPass.appendingPathComponent("pass.json"))
        skipping.cards = [CardItem(id: ticketID)]
        skipping.fetchAllOriginals()
        try? await Task.sleep(nanoseconds: 50_000_000)
        expect(await skipProbe.requests == 0 && !skipping.isFetchingOriginals, "a batch of only non-payment passes never reads the phone")
        expect(skipping.showSuccessAlert && skipping.successAlertMessage.contains("non-payment"), "skipped passes are explained")
        let bankID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        skipping.cards.append(CardItem(id: bankID))
        skipping.showSuccessAlert = false
        skipping.fetchAllOriginals()
        await waitForProbe(skipProbe)
        expect(await skipProbe.requests == 1, "payment cards are still fetched next to skipped passes")
        await skipProbe.complete(.success(nil))
        expect(await wait { !skipping.isFetchingOriginals }, "mixed batch completes")
        expect(!skipping.successAlertMessage.contains(String(ticketID.prefix(8))), "skipped passes are not reported as failed fetches")
        try fm.removeItem(at: ticketPass)

        // A newly constructed controller must respect an on-disk recovery record.
        let record = recoveryRoot.appendingPathComponent("retained-operation")
        try fm.createDirectory(at: record, withIntermediateDirectories: true)
        try Data("mock-device".utf8).write(to: record.appendingPathComponent("device.udid"))
        let restartProbe = FetchProbe()
        let restarted = model("restarted", restartProbe)
        restarted.fetchAllOriginals()
        expect(!restarted.isFetchingOriginals && !restarted.canStartDeviceOperation,
               "a fresh controller blocks a device with retained recovery work")
        expect(await restartProbe.requests == 0, "startup recovery gate prevents new device reads")
        try fm.removeItem(at: record)

        // Reconnecting with a pass whose art is unknown must start detection
        // without scheduling an automatic device-artwork read.
        let bin = root.appendingPathComponent("build")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let helper = bin.appendingPathComponent("device_helper")
        let helperScript = """
        #!/bin/sh
        if [ "$1" = "list" ]; then
          printf '%s\\n' '[{"udid":"mock-device","name":"Mock iPhone","connected":true}]'
        elif [ "$1" = "syslog" ]; then
          [ "$WAVECARD_SYSLOG_JSON" = "1" ] || exit 65
          printf '%s\\n' 'WaveCard scanner: Connected to the unified device log stream.'
          printf '%s\\n' '{"line":"nfcd(NearField): passIDs[InSession]: {(\\n    \\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\"\\n)}"}'
          printf '%s\\n' '{"line":"nfcd(NearField): passIDs[InSession]: {(\\n    \\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\"\\n)}"}'
          printf '%s\\n' '{"line":"nfcd(NearField): setActivePaymentApplet: requestedApplet: {\\"identifier\\":\\"A00000000310100100000020\\"}"}'
          exec /bin/sleep 30
        else
          exit 64
        fi
        """
        try helperScript.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let connectProbe = FetchProbe()
        let connecting = model("connect", connectProbe)
        connecting.device = nil
        connecting.cards = [CardItem(id: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", label: "Known fixture")]
        connecting.checkDevice()
        expect(await wait { connecting.isScanningCards }, "reconnect starts scanning while unknown artwork stays unfetched")
        let automaticRequests = await connectProbe.requests
        expect(!connecting.isReadingArtwork && automaticRequests == 0,
               "connection does not automatically probe unknown pass formats")
        expect(await wait { connecting.logs.contains { $0.message.hasPrefix("Matched saved card:") } },
               "complete JSON records identify an already saved pass")
        try? await Task.sleep(nanoseconds: 100_000_000)
        expect(connecting.logs.filter { $0.message.hasPrefix("Matched saved card:") }.count == 1,
               "repeated records report a saved pass once per scan")
        expect(connecting.cards.count == 1, "an NFC applet identifier is not added as a pass hash")
        expect(connecting.logs.contains { $0.message.contains("Connected to the unified device log stream") },
               "helper connection diagnostics reach the app log")
        expect(!connecting.canRefreshDevice && !connecting.canStartDeviceOperation,
               "an active log stream owns its lockdown session and prevents background polling")
        connecting.stopScanning()
        expect(await wait { !connecting.isStoppingScanner }, "scanner releases its process before another operation starts")

        connecting.startScanning()
        expect(await wait { connecting.isScanningCards }, "scanner can restart before termination")
        connecting.stopBackgroundActivityForTermination()
        expect(await wait { !connecting.isScanningCards }, "termination closes scanner ownership without draining queued work")
        expect(await connectProbe.requests == 0, "termination does not schedule a device artwork operation")

        // Metadata names enrich known IDs without importing the Mac's inventory.
        let nameProbe = FetchProbe()
        let naming = model("naming", nameProbe)
        let namedID = "BBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        let customID = "CCCCCCCCCCCCCCCCCCCCCCCCCCCC"
        let extraID = "DDDDDDDDDDDDDDDDDDDDDDDDDDDD"
        naming.cards = [CardItem(id: namedID), CardItem(id: customID, label: "My custom name")]
        for id in [namedID, customID, extraID] {
            let pass = root.appendingPathComponent("wallet-metadata/Cards/\(id).pkpass")
            try fm.createDirectory(at: pass, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["organizationName": "Fixture Tickets", "description": "Admission", "eventTicket": [:]] as [String: Any])
                .write(to: pass.appendingPathComponent("pass.json"))
        }
        naming.refreshMetadataNames()
        expect(await wait { naming.cards[0].label.contains("Fixture Tickets") }, "known generic cards receive local Wallet metadata names")
        expect(naming.cards[1].label == "My custom name", "metadata never overwrites a user label")
        expect(naming.cards.count == 2, "metadata does not import unconfirmed cached passes")
        expect(await nameProbe.requests == 0, "metadata naming never reads artwork from a phone")

        let strip = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        strip.bitmapData!.initialize(repeating: 150, count: strip.bytesPerRow * strip.pixelsHigh)
        try strip.representation(using: .png, properties: [:])!.write(to:
            root.appendingPathComponent("wallet-metadata/Cards/\(namedID).pkpass/strip.png"))
        naming.refreshWalletPreviews()
        expect(await wait { naming.walletPreviews[namedID] != nil }, "a known ticket receives a display image from its real local assets")
        expect(naming.originalImages[namedID] == nil && !naming.hasOriginal(for: namedID),
               "a display preview is never promoted into a factory restoration backup")
        expect(await nameProbe.requests == 0, "local preview rendering never starts AirTraffic or device artwork reads")
        naming.deleteCard(id: namedID)
        expect(naming.walletPreviews[namedID] == nil, "deleting a card removes its display preview")

        // Validate local backup contents and failed-save reporting in an isolated store.
        let originals = root.appendingPathComponent("originals")
        let assets = CardAssetManager(originalsDirectory: originals, customCacheDirectory: root.appendingPathComponent("cache"))
        let hash = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: assets.originalFileURL(for: hash))
        expect(!assets.hasOriginal(for: hash), "a corrupt PNG header does not count as a backup")
        expect(!assets.saveOriginal(cardHash: hash, data: Data()), "invalid original data reports a failed save")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.bitmapData!.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = bitmap.representation(using: .png, properties: [:])!
        expect(assets.saveOriginal(cardHash: hash, data: png) && assets.hasOriginal(for: hash), "a valid original is stored and validated")
        expect(assets.originalPNGData(for: hash) == png, "saved backup retains original bytes")
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let blockedAssets = CardAssetManager(originalsDirectory: blocked, customCacheDirectory: root.appendingPathComponent("cache2"))
        expect(!blockedAssets.saveOriginal(cardHash: hash, data: png), "an unwritable backup location cannot report success")
        if failed > 0 { exit(1) }
    }
}
