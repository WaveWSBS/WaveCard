import AppKit
import Foundation

/// Rebuilds factory artwork from the single stored original PNG and flashes it
/// back into Apple Wallet.
///
/// The backup is deliberately just one PNG, so restore always regenerates the
/// full asset suite from it instead of replaying files off the device.
public final class CardRestoreManager {
    public static let shared = CardRestoreManager()

    private init() {}

    public func restoreCard(
        udid: String,
        cardHash: String,
        onLog: @escaping (String) -> Void,
        onFailure: ((AirliftReadFailure) -> Void)? = nil
    ) async -> Bool {
        guard let originalData = CardAssetManager.shared.originalPNGData(for: cardHash) else {
            onLog("No original stored for card \(cardHash.prefix(8)). Fetch it from the iPhone first.")
            return false
        }

        let files = Self.assetSuite(from: originalData)
        guard !files.isEmpty else {
            onLog("Could not render artwork assets from the stored original.")
            return false
        }

        let pkpassDir = "/var/mobile/Library/Passes/Cards/\(cardHash).pkpass"
        onLog("Writing \(files.count) restored file(s) to iPhone...")

        // pass.json is never written back: replacing it invalidates the pass
        // signature on iOS and the card stops opening in Wallet.
        let writeOk = AirliftBridge.shared.writeFilesBatch(
            udid: udid,
            target: pkpassDir,
            files: files,
            retries: 3,
            onFailure: onFailure
        )

        guard writeOk else {
            onLog("Failed to write restored files to device.")
            return false
        }

        onLog("Invalidating Passbook render cache...")
        let cacheOk = AirliftBridge.shared.invalidateCache(udid: udid, cardHash: cardHash, onFailure: onFailure)
        guard cacheOk else {
            onLog("Original artwork was written, but cache invalidation failed. Check recovery diagnostics before retrying.")
            return false
        }
        onLog("✓ Restore complete for card \(cardHash.prefix(8)).")
        return true
    }

    /// Renders @3x / @2x / .pdf at Apple's exact card dimensions. If the stored
    /// original will not decode, pass its bytes through unchanged rather than
    /// leaving the card skinless.
    private static func assetSuite(from originalData: Data) -> [(leaf: String, payload: Data)] {
        guard let image = NSImage(data: originalData) else { return [] }

        guard let rendered = CardAssetManager.shared.prepareCardAssets(from: image) else {
            return [
                ("cardBackgroundCombined@3x.png", originalData),
                ("cardBackgroundCombined@2x.png", originalData)
            ]
        }

        return [
            ("cardBackgroundCombined@3x.png", rendered.png3x),
            ("cardBackgroundCombined@2x.png", rendered.png2x),
            ("cardBackgroundCombined.pdf", rendered.pdf)
        ]
    }
}
