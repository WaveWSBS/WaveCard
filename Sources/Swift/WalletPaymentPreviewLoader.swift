import AppKit
import Foundation
import ImageIO

/// Exact remote Wallet thumbnails, for display only. These are not backups.
public enum WalletPaymentPreviewLoader {
    public static func load(
        walletRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Passes"),
        thumbnailRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/PassKit/RemoteCards"),
        product: String,
        cardIDs: Set<String>
    ) -> [String: WalletPreview] {
        let hashes = WalletMetadataCatalog.paymentManifestHashes(root: walletRoot, product: product, confirmedIDs: cardIDs)
        guard !hashes.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(at: thumbnailRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]),
              files.count <= 10_000 else { return [:] }
        var result: [String: WalletPreview] = [:]
        for (id, hash) in hashes {
            let prefix = hash.map { String(format: "%02x", $0) }.joined() + "#"
            // Prefer the largest requested thumbnail, but decode and validate its
            // real dimensions. The requested dimensions are only cache keys.
            let candidates = files.compactMap { file -> (URL, Int)? in
                guard file.lastPathComponent.hasPrefix(prefix) else { return nil }
                let size = file.lastPathComponent.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
                guard size.count == 2, let w = Int(size[0]), let h = Int(size[1]),
                      w > 0, h > 0, w <= 8192, h <= 8192 else { return nil }
                return (file, w * h)
            }.sorted { $0.1 > $1.1 }
            for (file, _) in candidates {
                guard let bytes = read(file, beneath: thumbnailRoot),
                      let image = decode(bytes) else { continue }
                result[id] = WalletPreview(image: NSImage(cgImage: image, size: .zero), source: .remotePaymentThumbnail)
                break
            }
        }
        return result
    }

    private static func read(_ file: URL, beneath root: URL) -> Data? {
        let root = root.standardizedFileURL
        let file = file.standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        var current = file
        while true {
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink == false else { return nil }
            if current == root { break }
            let parent = current.deletingLastPathComponent()
            guard parent != current else { return nil }
            current = parent
        }
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 16 * 1024 * 1024 + 1), bytes.count <= 16 * 1024 * 1024 else { return nil }
        return bytes
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard data.starts(with: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) || data.starts(with: Data([0xff, 0xd8, 0xff])),
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int,
              let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 16_777_216 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
